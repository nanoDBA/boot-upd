BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $invokePath = Join-Path $repoRoot 'Invoke-BootUpdateCycle.ps1'
    $deployPath = Join-Path $repoRoot 'Deploy-BootUpdateCycle.ps1'

    function Get-ScriptAst {
        param([Parameter(Mandatory)][string]$Path)
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        return $ast
    }

    function Get-FunctionText {
        param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$Name)
        $function = $Ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        }, $true)
        $function | Should -Not -BeNullOrEmpty -Because "production function '$Name' must exist"
        return $function.Extent.Text
    }

    $invokeAst = Get-ScriptAst $invokePath
    $deployAst = Get-ScriptAst $deployPath
    $invokeSource = Get-Content $invokePath -Raw

    foreach ($functionName in @(
        'Update-BootUpdateStateForBootSession',
        'Resolve-BootUpdateCompletionDisposition',
        'Stop-BootUpdateAtRebootLimit',
        'Stop-BootUpdateAtRetryLimit',
        'Update-BootUpdateStagedRetryCount',
        'Get-NextMaintenanceWindowStart',
        'Test-WindowsUpdateConvergence',
        'Format-NativeExitCode',
        'Get-InstallerExitSummary',
        'Get-WingetOutputSummary'
    )) {
        . ([scriptblock]::Create((Get-FunctionText $invokeAst $functionName)))
    }
    function Write-Log { param([string]$Message, [string]$Level) }
    function Set-BootUpdateState { param($State) }
    function Write-EventLogEntry { param($EventId, $EntryType, $Message) }
    function Send-CompletionNotification { param($Kind, $Title, $Message) }
    function Show-CycleBanner { param($Title, $AnsiColor, $Info) }
    function Unregister-BootUpdateTask {
        $script:UnregisterCalls++
        if ($script:FailUnregister) { throw 'simulated task removal failure' }
    }
    function Invoke-BootUpdateBackgroundOperation { param($Name, $Status, $TimeoutMinutes, $ScriptBlock, $ArgumentList) }
}

Describe 'Concise provider diagnostics' {
    It 'extracts package failures and inventory notes from noisy Winget output' {
        $lines = @(
            '1 package(s) have pins that prevent upgrade.',
            '(1/4) Found Logitech G HUB [Logitech.GHUB] Version 2026.4',
            'Successfully installed',
            '(2/4) Found Pandoc [JohnMacFarlane.Pandoc] Version 3.10',
            '   Uninstall failed with exit code: 1605',
            '(3/4) Found Windows PC Health Check [Microsoft.WindowsPCHealthCheck] Version 4.0',
            'Uninstall failed with exit code: 1612',
            '(4/4) Found Corsair iCUE5 Software [Corsair.iCUE.5] Version 5.48',
            'Installer failed with exit code: 3221226525',
            '4 package(s) have version numbers that cannot be determined.',
            '1 package(s) have upgrades blocked because newer versions use a different install technology than the current installation.'
        )
        $summary = Get-WingetOutputSummary -Lines $lines
        $summary.Attempted | Should -Be 4
        $summary.Updated | Should -Be 1
        $summary.Failures.Count | Should -Be 3
        $summary.Failures[0].Id | Should -Be 'JohnMacFarlane.Pandoc'
        $summary.Failures[0].Summary | Should -Be 'product is not currently installed'
        $summary.Failures[1].Summary | Should -Be 'installation source is unavailable'
        $summary.Failures[2].Hex | Should -Be '0xC000041D'
        $summary.Pinned | Should -Be 1
        $summary.Unknown | Should -Be 4
        $summary.TechnologyBlocked | Should -Be 1
    }

    It 'renders signed provider HRESULTs in recognizable hexadecimal form' {
        Format-NativeExitCode -Code -1978335188 | Should -Be '0x8A15002C'
    }

    It 'keeps raw provider chatter out of the primary structured log path' {
        $winget = Get-FunctionText $invokeAst 'Update-WingetPackages'
        $choco = Get-FunctionText $invokeAst 'Update-ChocolateyPackages'
        $winget | Should -Match 'Write-WingetScopeSummary'
        $choco | Should -Match 'Write-ProviderTranscript'
        $winget | Should -Not -Match 'foreach \(\$line in \$jr\.Lines\)[\s\S]*?Write-Log \$line'
        $choco | Should -Not -Match 'Write-Log \$_'
    }

    It 'fails closed when a parallel Winget child process cannot start' {
        $winget = Get-FunctionText $invokeAst 'Update-WingetPackages'
        $winget | Should -Match 'StartFailed = \$startFailed'
        $winget | Should -Match 'if \(\$jr\.StartFailed\)[\s\S]*?\$anyTimeout = \$true[\s\S]*?continue'
    }
}

Describe 'BitLocker reboot targeting' {
    It 'queries and suspends only the Windows OS volume' {
        $text = Get-FunctionText $invokeAst 'Suspend-BitLockerForReboot'
        $text | Should -Match '\$osDrive = \[IO\.Path\]::GetPathRoot\(\$env:SystemRoot\)'
        $text | Should -Match 'Get-BitLockerVolume -MountPoint \$osDrive'
        $text | Should -Match '\$osVolume \| Suspend-BitLocker -RebootCount 1'
        $text | Should -Match 'protection is not currently On'
        $text | Should -Not -Match 'foreach \(\$vol in \$protectedVolumes\)'
    }
}

Describe 'Delayed and explicit reboot evidence' {
    It 'requires two clean registry probes separated by an animated settle interval' {
        $text = Get-FunctionText $invokeAst 'Get-ConfirmedPendingReboot'
        ([regex]::Matches($text, 'Test-PendingReboot')).Count | Should -Be 2
        $text | Should -Match 'RebootSignalSettleSeconds'
        $text | Should -Match 'Wait-BootUpdateUiInterval'
        $text | Should -Match 'Watching for delayed Windows reboot signals'
    }

    It 'preserves native 3010 and 1641 as successful reboot requests' {
        $text = Get-FunctionText $invokeAst 'Invoke-PackageManagerWithTimeout'
        $text | Should -Match 'BOOTUPDATE_NATIVE_EXIT'
        $text | Should -Match '\$effectiveExitCode -in @\(1641, 3010\)'
        $text | Should -Match '\$script:ExplicitRebootRequests\.Add'
        $text | Should -Match 'notin @\(0, 1641, 3010\)'
    }

    It 'uses confirmed reboot evidence for the final decision' {
        (Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle') |
            Should -Match '\$pending = if \(\$WhatIfPreference\) \{ @\(\) \} else \{ Get-ConfirmedPendingReboot \}'
    }

    It 'also requires two clean probes before the first mutating phase' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $text | Should -Match '\$pending = @\(Get-ConfirmedPendingReboot\)'
        $text.IndexOf('$pending = @(Get-ConfirmedPendingReboot)') |
            Should -BeLessThan $text.IndexOf('Update-WingetPackages')
    }
}

Describe 'Truthful reboot safety limit' {
    It 'checks the reboot budget only after confirmed pending evidence exists' {
        $cycle = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $guard = Get-FunctionText $invokeAst 'Stop-BootUpdateAtRebootLimit'
        $cycle | Should -Not -Match '\$state\.Iteration -gt \$MaxIterations'
        ([regex]::Matches($cycle, 'Stop-BootUpdateAtRebootLimit')).Count | Should -Be 2
        $guard | Should -Match '\$State\.RebootCount -lt \$script:MaxIterations'
        $guard | Should -Match "Phase = 'LimitReached'"
        $guard | Should -Match 'LimitRebootSignals = \$evidence'
        $guard | Should -Not -Match 'Clear-BootUpdateState|Invoke-Hook'
    }

    It 'allows the final reboot to converge and preserves exact evidence only when still pending' {
        $script:MaxIterations = 5
        $script:StatePath = 'C:\ProgramData\BootUpdateCycle\BootUpdateCycle.state.json'
        $script:UnregisterCalls = 0
        $script:FailUnregister = $false
        $signal = [pscustomobject]@{ Source='CBS'; Detail='RebootPending key present' }
        $state = [pscustomobject]@{
            RebootCount=4; Phase='Rebooting'; StartTime='2026-07-20T09:00:00Z'
            LastRebootSignals=$null; LimitReachedAt=$null; LimitReason=$null; LimitRebootSignals=@()
        }

        (Stop-BootUpdateAtRebootLimit -State $state -PendingSignals @($signal) -Context 'before update phases') |
            Should -BeFalse
        $state.RebootCount = 5
        (Stop-BootUpdateAtRebootLimit -State $state -PendingSignals @($signal) -Context 'before update phases') |
            Should -BeTrue
        $state.Phase | Should -Be 'LimitReached'
        $state.LimitRebootSignals | Should -HaveCount 1
        $state.LimitRebootSignals[0].Source | Should -Be 'CBS'
        $state.LimitReason | Should -Match 'CBS: RebootPending key present'
        $script:UnregisterCalls | Should -Be 1
    }

    It 'bounds same-boot failure recovery separately from completed reboots' {
        $script:MaxRetryPasses = 3
        $script:UnregisterCalls = 0
        $script:FailUnregister = $false
        $state = [pscustomobject]@{
            ConsecutiveRetryCount=2; Phase='RetryPending'; StartTime='2026-07-20T09:00:00Z'
            LimitReachedAt=$null; LimitReason=$null
        }
        (Stop-BootUpdateAtRetryLimit -State $state -IncompletePhases @('Defender')) | Should -BeFalse
        $state.ConsecutiveRetryCount = 3
        (Stop-BootUpdateAtRetryLimit -State $state -IncompletePhases @('Defender')) | Should -BeTrue
        $state.Phase | Should -Be 'RetryLimitReached'
        $state.LimitReason | Should -Match 'incomplete phases: Defender'
        $script:UnregisterCalls | Should -Be 1
    }

    It 'charges repeated same-boot pending-reboot requests against the retry budget' {
        $cycle = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        ([regex]::Matches($cycle, '\$state\.ConsecutiveRetryCount\s*=\s*\[int\]\$state\.ConsecutiveRetryCount \+ 1')).Count |
            Should -BeGreaterOrEqual 3
        ([regex]::Matches($cycle, 'Pending reboot: \$_')).Count | Should -Be 2
        foreach ($restartCall in @(
            "Start-BootUpdateRestart -State `$state -Reason 'A reboot was already pending",
            'Start-BootUpdateRestart -State $state -Reason "Iteration'
        )) {
            $restart = $cycle.IndexOf($restartCall)
            $guard = $cycle.LastIndexOf('Stop-BootUpdateAtRetryLimit', $restart)
            $guard | Should -BeGreaterThan 0
            $guard | Should -BeLessThan $restart
        }
    }

    It 'does not mutate or enforce the retry budget during WhatIf' {
        $cycle = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        ([regex]::Matches($cycle, '(?s)if \(-not \$WhatIfPreference\) \{\s*\$state\.ConsecutiveRetryCount.*?Pending reboot: \$_.*?Stop-BootUpdateAtRetryLimit')).Count |
            Should -Be 2
    }

    It 'does not charge successful staged advancement against the retry budget' {
        $state = [pscustomobject]@{ ConsecutiveRetryCount=0 }
        foreach ($phase in 1..8) {
            Update-BootUpdateStagedRetryCount -State $state -TargetAttempted $true -TargetComplete $true |
                Should -Be 0
        }
        foreach ($failure in 1..3) {
            Update-BootUpdateStagedRetryCount -State $state -TargetAttempted $true -TargetComplete $false |
                Should -Be $failure
        }
        Update-BootUpdateStagedRetryCount -State $state -TargetAttempted $true -TargetComplete $true |
            Should -Be 0
    }

    It 'checks a stuck staged target before registering its next near-term retry' {
        $cycle = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $stagedStart = $cycle.IndexOf('$stagedRetryCount = Update-BootUpdateStagedRetryCount')
        $stagedStop = $cycle.IndexOf('Stop-BootUpdateAtRetryLimit', $stagedStart)
        $stagedRegister = $cycle.IndexOf('Register-BootUpdateTaskForReboot -RetrySoon', $stagedStart)
        $stagedStart | Should -BeGreaterThan 0
        $stagedStop | Should -BeGreaterThan $stagedStart
        $stagedStop | Should -BeLessThan $stagedRegister
    }

    It 'verifies both continuation tasks are absent before claiming they were removed' {
        $text = Get-FunctionText $invokeAst 'Unregister-BootUpdateTask'
        ([regex]::Matches($text, 'Get-ScheduledTask')).Count | Should -BeGreaterOrEqual 2
        $text | Should -Match 'Could not verify removal of scheduled task'
        $guard = Get-FunctionText $invokeAst 'Stop-BootUpdateAtRebootLimit'
        $guard.IndexOf('Unregister-BootUpdateTask') | Should -BeLessThan $guard.IndexOf('Send-CompletionNotification')
        $guard | Should -Match "Phase = 'LimitDisarmFailed'"
    }

    It 'retains a distinct terminal state when task disarming cannot be verified' {
        $script:MaxIterations = 1
        $script:FailUnregister = $true
        $state = [pscustomobject]@{
            RebootCount=1; Phase='Rebooting'; StartTime='2026-07-20T09:00:00Z'
            LastRebootSignals=$null; LimitReachedAt=$null; LimitReason=$null; LimitRebootSignals=@()
        }
        $signal = [pscustomobject]@{ Source='WU'; Detail='RebootRequired key present' }
        (Stop-BootUpdateAtRebootLimit -State $state -PendingSignals @($signal) -Context 'after update phases') |
            Should -BeTrue
        $state.Phase | Should -Be 'LimitDisarmFailed'
        $state.LimitReason | Should -Match 'simulated task removal failure'
        $script:FailUnregister = $false
    }
}

Describe 'Durable resume chain' {
    It 'uses ARSO user resume plus a delayed SYSTEM safety net' {
        $text = Get-FunctionText $invokeAst 'Register-BootUpdateTaskForReboot'
        $text | Should -Match 'New-ScheduledTaskTrigger -AtLogOn'
        $text | Should -Match 'BootUpdateCycleFallback'
        $text | Should -Match "Delay = 'PT3M'"
        $text | Should -Match 'fallbackRetryTrigger.*retryTime\.AddMinutes\(3\)'
        $text | Should -Match 'fallbackTriggers = if \(\$fallbackRetryTrigger\)'
    }

    It 'retries failures, rejects overlap, and verifies task registration' {
        foreach ($ast in @($invokeAst, $deployAst)) {
            $name = if ($ast -eq $invokeAst) { 'Register-BootUpdateTaskForReboot' } else { 'Register-ScheduledTaskNow' }
            $text = Get-FunctionText $ast $name
            $text | Should -Match '-RestartCount 3'
            $text | Should -Match '-RestartInterval'
            $text | Should -Match '-MultipleInstances IgnoreNew'
            $text | Should -Match 'Get-ScheduledTask'
            $text | Should -Match "State -eq 'Disabled'"
        }
    }

    It 'keeps resumed state after a transient preflight failure' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $text | Should -Match 'Resume checkpoint preserved.*retry.*triggers are armed'
        $text.IndexOf('$state.Iteration++') | Should -BeGreaterThan $text.IndexOf('Test-PreFlightChecks')
    }

    It 'uses process-unique checkpoint temporary files' {
        $text = Get-FunctionText $invokeAst 'Set-BootUpdateState'
        $text | Should -Match '\$PID'
        $text | Should -Match '\[guid\]::NewGuid'
        $text | Should -Match '\[System\.IO\.File\]::Move'
    }

    It 'arms the resume checkpoint before any mutating update phase' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $checkpoint = $text.IndexOf("Resume checkpoint armed before update phases")
        $firstPhase = $text.IndexOf('Update-WingetPackages')
        $checkpoint | Should -BeGreaterThan 0
        $checkpoint | Should -BeLessThan $firstPhase
    }

    It 'arms a dated watchdog before a cancelable delayed restart' {
        $text = Get-FunctionText $invokeAst 'Start-BootUpdateRestart'
        $text | Should -Match 'restartWatchdog'
        $text | Should -Match 'Register-BootUpdateTaskForReboot -RetryAt'
        $text | Should -Match 'shutdown\.exe'
        $text | Should -Match '\$LASTEXITCODE -ne 0'
    }

    It 'round-trips structured arrays and behavior-changing resume switches' {
        $text = Get-FunctionText $invokeAst 'Register-BootUpdateTaskForReboot'
        $text | Should -Match 'ExcludePatternsBase64'
        $text | Should -Match 'IncludePatternsBase64'
        foreach ($switchName in @('SkipBitLocker','AllowMetered','DisableSelfUpdate','UpdateWsl','UpdateContainers')) {
            $text | Should -Match ([regex]::Escape("-$switchName"))
        }
    }
}

Describe 'Behavioral reboot state transitions' {
    It 'does not consume or clear reboot evidence in the same boot' {
        $state = [pscustomobject]@{ LastBootSessionId='boot-a'; Phase='Rebooting'; RebootCount=2; ExplicitRebootRequests=@('3010') }
        $actual = Update-BootUpdateStateForBootSession -State $state -CurrentBootSessionId 'boot-a'
        $actual.RebootCount | Should -Be 2
        $actual.ExplicitRebootRequests | Should -HaveCount 1
    }

    It 'counts exactly one completed reboot and clears evidence after boot identity changes' {
        $state = [pscustomobject]@{ LastBootSessionId='boot-a'; Phase='Rebooting'; RebootCount=2; ExplicitRebootRequests=@('3010') }
        $actual = Update-BootUpdateStateForBootSession -State $state -CurrentBootSessionId 'boot-b'
        $actual.RebootCount | Should -Be 3
        $actual.ExplicitRebootRequests | Should -BeNullOrEmpty
        $again = Update-BootUpdateStateForBootSession -State $actual -CurrentBootSessionId 'boot-b'
        $again.RebootCount | Should -Be 3
    }

    It 'counts a surprise reboot persisted by native 1641 evidence before the post-phase checkpoint' {
        $state = [pscustomobject]@{
            LastBootSessionId='boot-a'; Phase='Chocolatey'; RebootCount=2
            ExplicitRebootRequests=@([pscustomobject]@{ Source='Chocolatey-exit-1641'; Detail='restart initiated' })
        }
        $actual = Update-BootUpdateStateForBootSession -State $state -CurrentBootSessionId 'boot-b'
        $actual.RebootCount | Should -Be 3
        $actual.ExplicitRebootRequests | Should -BeNullOrEmpty
        $actual.ConsecutiveRetryCount | Should -Be 0
    }

    It 'counts persisted native reboot evidence even if the post-phase marker was not reached' {
        $state = [pscustomobject]@{ LastBootSessionId='boot-a'; Phase='RetryPending'; RebootCount=2; ExplicitRebootRequests=@('3010') }
        $actual = Update-BootUpdateStateForBootSession -State $state -CurrentBootSessionId 'boot-b'
        $actual.RebootCount | Should -Be 3
        $actual.ExplicitRebootRequests | Should -BeNullOrEmpty
    }
}

Describe 'Behavioral completion disposition' {
    It 'retries ordinary incomplete phases before considering completion' {
        $result = Resolve-BootUpdateCompletionDisposition -IncompletePhases @(
            [pscustomobject]@{ Name='WindowsUpdate'; UserCompletionDeferred=$false },
            [pscustomobject]@{ Name='Scoop'; UserCompletionDeferred=$true }
        )
        $result.Kind | Should -Be 'Retry'
        $result.Phases.Name | Should -Contain 'WindowsUpdate'
    }

    It 'retains a user-context pass when only user-scoped work remains' {
        $result = Resolve-BootUpdateCompletionDisposition -IncompletePhases @(
            [pscustomobject]@{ Name='Scoop'; UserCompletionDeferred=$true }
        )
        $result.Kind | Should -Be 'UserContext'
    }

    It 'completes only an empty incomplete set' {
        (Resolve-BootUpdateCompletionDisposition).Kind | Should -Be 'Complete'
    }
}

Describe 'Behavioral dated retries' {
    BeforeEach {
        $script:MaintenanceWindowStart = 22
    }

    It 'uses today when the maintenance start is still ahead' {
        (Get-NextMaintenanceWindowStart -Now ([datetime]'2026-07-20T10:00:00')) |
            Should -Be ([datetime]'2026-07-20T22:00:00')
    }

    It 'uses tomorrow when the maintenance start has passed' {
        (Get-NextMaintenanceWindowStart -Now ([datetime]'2026-07-20T23:00:00')) |
            Should -Be ([datetime]'2026-07-21T22:00:00')
    }
}

Describe 'Behavioral Windows Update convergence' {
    BeforeEach {
        $script:ExcludePatterns = @('SQL')
        $script:PackageTimeoutMinutes = 30
        Mock Get-Module { [pscustomobject]@{ Name='PSWindowsUpdate' } }
        Mock Write-Log {}
    }

    It 'verifies zero applicable updates' {
        Mock Invoke-BootUpdateBackgroundOperation { [pscustomobject]@{ Output=@(); Failed=$false; TimedOut=$false } }
        $result = Test-WindowsUpdateConvergence
        $result.Verified | Should -BeTrue
        $result.Count | Should -Be 0
    }

    It 'reports remaining applicable updates' {
        Mock Invoke-BootUpdateBackgroundOperation { [pscustomobject]@{ Output=@('BOOTUPDATE_APPLICABLE|KB1|Update'); Failed=$false; TimedOut=$false } }
        $result = Test-WindowsUpdateConvergence
        $result.Verified | Should -BeTrue
        $result.Count | Should -Be 1
    }

    It 'withholds verification after a scan error' {
        Mock Invoke-BootUpdateBackgroundOperation { [pscustomobject]@{ Output=@('BOOTUPDATE_ERROR|offline'); Failed=$false; TimedOut=$false } }
        (Test-WindowsUpdateConvergence).Verified | Should -BeFalse
    }
}

Describe 'Evidence-backed completion' {
    It 'queues a near-term retry instead of congratulating an incomplete phase set' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $text | Should -Match '\$incompletePhases'
        $text | Should -Match 'Register-BootUpdateTaskForReboot -RetrySoon'
        $text | Should -Match 'R E C O V E R Y   P A S S   Q U E U E D'
        $text.IndexOf('$incompletePhases') | Should -BeLessThan $text.IndexOf('C O N F I G U R E D   P A T C H   P A S S   V E R I F I E D')
    }

    It 'returns success after the retry checkpoint transaction is durably armed' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $retryStart = $text.IndexOf("if (-not `$WhatIfPreference -and `$disposition.Kind -eq 'Retry')")
        $nextDisposition = $text.IndexOf("if (-not `$WhatIfPreference -and `$disposition.Kind -eq 'UserContext')", $retryStart)
        $retryBranch = $text.Substring($retryStart, $nextDisposition - $retryStart)

        $retryBranch | Should -Match 'Set-BootUpdateState'
        $retryBranch | Should -Match 'Register-BootUpdateTaskForReboot -RetrySoon'
        $retryBranch | Should -Match 'R E C O V E R Y   P A S S   Q U E U E D'
        $retryBranch | Should -Match 'No action needed.*window may close'
        $retryBranch | Should -Match 'exit\s+0'
        $retryBranch | Should -Match 'Stop-BootUpdateAtRetryLimit[\s\S]*exit\s+3'
    }

    It 'continues treating Defender native exit code 2 as a retryable phase failure' {
        $text = Get-FunctionText $invokeAst 'Update-DefenderSignatures'
        $text | Should -Match '\$exitCode -ne 0'
        $text | Should -Match 'exited with code \$exitCode'
        $text | Should -Match 'Success = \$false'
    }

    It 'congratulates only the verified green path and reports its evidence' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $text | Should -Match 'YOU DID IT.*CONFIGURED PATCH PASS IS VERIFIED.*NICE WORK'
        $text | Should -Match 'configured phases completed'
        $text | Should -Match 'Reboot state clean twice'
        $text | Should -Match 'critical service\(s\) healthy'
        $text | Should -Not -Match 'FULLY PATCHED'
    }

    It 'cleans and verifies terminal artifacts before success notification and banner' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $cleanup = $text.LastIndexOf('Unregister-BootUpdateTask')
        $verify = $text.LastIndexOf('Terminal cleanup verification failed')
        $notify = $text.LastIndexOf("Send-CompletionNotification -Title 'Boot Update Cycle Complete'")
        $banner = $text.LastIndexOf('Show-CycleBanner -Title $completionTitle')
        $cleanup | Should -BeLessThan $verify
        $verify | Should -BeLessThan $notify
        $notify | Should -BeLessThan $banner
    }

    It 'requires completed thread jobs and structured success' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $text | Should -Match "jobState -ne 'Completed'"
        $text | Should -Match 'phaseSucceeded = \$jobState -eq ''Completed''.*jr\.Success'
    }
}

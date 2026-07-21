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
        'Get-BootUpdateLaunchContract',
        'Get-BootUpdateBootSessionId',
        'Get-ActionablePendingFileRenameOperations',
        'Resolve-BootUpdateCompletionDisposition',
        'Stop-BootUpdateAtRebootLimit',
        'Stop-BootUpdateAtRetryLimit',
        'Update-BootUpdateStagedRetryCount',
        'Get-NextMaintenanceWindowStart',
        'Get-WindowsUpdateVerificationScope',
        'Get-WindowsUpdateEnvironmentFingerprint',
        'Remove-WindowsUpdateAssessmentCache',
        'Set-WindowsUpdateAssessmentCache',
        'Invoke-WindowsUpdateOfflineAssessment',
        'Test-WindowsUpdateAssessmentRecord',
        'Test-WindowsUpdateAssessmentCache',
        'Test-WindowsUpdateZeroEvidence',
        'Get-WindowsUpdateInstallOutputSummary',
        'Test-WindowsUpdateConvergence',
        'Format-NativeExitCode',
          'Get-InstallerExitSummary',
          'Get-WingetOutputSummary',
          'Get-WingetRemediationCommand',
          'Complete-WingetFailureClassification',
          'Register-WingetAggressiveRepairAttempt',
          'Invoke-WingetFailureQuarantine',
          'Get-WingetQuarantineRecords',
          'Set-WingetQuarantineRecords',
          'Set-BootUpdateClipboardText',
          'Stop-BootUpdateForManualAttention',
          'Write-BootUpdateRepairPlan'
    )) {
        . ([scriptblock]::Create((Get-FunctionText $invokeAst $functionName)))
    }
    function Write-Log { param([string]$Message, [string]$Level) }
    function Set-BootUpdateState { param($State) }
    function Write-ProviderTranscript { param($Provider, $Scope, $Lines) }
    function Invoke-PackageManagerWithTimeout { param($Name, $ScriptBlock, $ArgumentList, $IdleTimeoutMinutes, $HardTimeoutMinutes) }
    function Write-EventLogEntry { param($EventId, $EntryType, $Message) }
    function Send-CompletionNotification { param($Kind, $Title, $Message) }
    function Enable-BootUpdateNtfsCompression { param($Path) }
    function Show-CycleBanner { param($Title, $AnsiColor, $Info) }
    function Unregister-BootUpdateTask {
        $script:UnregisterCalls++
        if ($script:FailUnregister) { throw 'simulated task removal failure' }
    }
    function Invoke-BootUpdateBackgroundOperation { param($Name, $Status, $TimeoutMinutes, $ScriptBlock, $ArgumentList) }
}

Describe 'Concise provider diagnostics' {
    It 'records a sanitized normalized launch contract for every session' {
        $script:AggressiveRepair = $true
        $script:StagedRollout = $false
        $script:IncludeDriverUpdates = $false
        $script:IncludeFirmwareUpdates = $false
        $script:UpdateWsl = $false
        $script:UpdateContainers = $false
        $script:AllowMetered = $false
        $script:DisableSelfUpdate = $false
        $script:OutputMode = 'Normal'
        $script:IncludePatterns = @()
        $script:ExcludePatterns = @()
        foreach ($name in @('SkipPip','SkipNpm','SkipOffice365','SkipAwsTooling','SkipPowerShellModules','SkipScoop','SkipDotnetTools','SkipVscode','SkipDefender','SkipRestorePoint','SkipHealthCheck','SkipBitLocker')) {
            Set-Variable -Scope Script -Name $name -Value $false
        }
        $Force = $true

        $contract = Get-BootUpdateLaunchContract -IsFirstIteration $false -IsSystem $true

        $contract | Should -Be 'Launch contract | Mode: aggressive-repair | Origin: resume-system | Scope: machine | Output: Normal | Flags: Force,AggressiveRepair | Skips: none | Filters: include=0,exclude=0'
        $contract | Should -Not -Match '(?i)user(name)?|domain|[A-Z]:\\'
    }

    It 'serializes Winget scopes because App Installer state is shared' {
        $invokeSource | Should -Match '\$runWingetScopesInParallel\s*=\s*\$false'
        $invokeSource | Should -Match '0x8A150001'
    }

    It 'learns repeated blank Winget execution failures as terminal' {
        $state = [pscustomobject]@{}
        $first = Complete-WingetFailureClassification -State $state -ExecutionFailures @('machine:-1978335231:no-output')
        $second = Complete-WingetFailureClassification -State $state -ExecutionFailures @('machine:-1978335231:no-output')

        $first.TerminalFailure | Should -BeFalse
        $second.TerminalFailure | Should -BeTrue
        $second.Signature | Should -Be 'execution:machine:-1978335231:no-output'
    }

    It 'keeps the VS Code url.parse deprecation out of the primary log replay' {
        $invokeSource | Should -Match "Write-ProviderTranscript -Provider Vscode"
        $invokeSource | Should -Match "DEP0169.*url\\\.parse"
    }

    It 'clears a stale Winget repair plan without relying on an undefined install path' {
        $script:InstallDir = $TestDrive
        $state = [pscustomobject]@{}
        { Complete-WingetFailureClassification -State $state -Failures @() } | Should -Not -Throw
        $state.WingetFailureSignature | Should -Be ''
    }

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

    It 'creates paste-ready remediation only from safe package identifiers' {
        Get-WingetRemediationCommand -PackageId 'JohnMacFarlane.Pandoc' |
            Should -Be 'winget install --id JohnMacFarlane.Pandoc -e --source winget --force --accept-source-agreements --accept-package-agreements'
        Get-WingetRemediationCommand -PackageId 'Microsoft.WindowsPCHealthCheck' -Code 1612 |
            Should -Be 'winget repair --id Microsoft.WindowsPCHealthCheck -e --source winget --force --accept-source-agreements --accept-package-agreements'
        Get-WingetRemediationCommand -PackageId 'Corsair.iCUE.5' -Code 3221226525 |
            Should -Be 'winget install --id Corsair.iCUE.5 -e --source winget --force --accept-source-agreements --accept-package-agreements'
        Get-WingetRemediationCommand -PackageId 'safe; Remove-Item C:\' | Should -BeNullOrEmpty
    }

    It 'escalates only an identical Winget failure signature that repeats' {
        $state = [pscustomobject]@{ WingetFailureSignature=''; WingetFailureRepeatCount=0 }
        $failure = [pscustomobject]@{ Name='Health Check'; Id='Microsoft.WindowsPCHealthCheck'; Code=1612; Hex='0x0000064C' }
        (Complete-WingetFailureClassification -State $state -Failures @($failure)).TerminalFailure | Should -BeFalse
        (Complete-WingetFailureClassification -State $state -Failures @($failure)).TerminalFailure | Should -BeTrue
        $changed = [pscustomobject]@{ Name='iCUE'; Id='Corsair.iCUE.5'; Code=3221226525; Hex='0xC000041D' }
        (Complete-WingetFailureClassification -State $state -Failures @($changed)).TerminalFailure | Should -BeFalse
    }

    It 'registers each aggressive Winget repair signature only once' {
        $state = [pscustomobject]@{ WingetAggressiveRepairSignatures=@() }

        Register-WingetAggressiveRepairAttempt -State $state -Signature 'Corsair.iCUE.5:3221226525' |
            Should -BeTrue
        Register-WingetAggressiveRepairAttempt -State $state -Signature 'Corsair.iCUE.5:3221226525' |
            Should -BeFalse
        Register-WingetAggressiveRepairAttempt -State $state -Signature 'Microsoft.WindowsPCHealthCheck:1612' |
            Should -BeTrue
        @($state.WingetAggressiveRepairSignatures).Count | Should -Be 2
    }

    It 'classifies Winget failures before deciding whether to run aggressive repair' {
        $winget = Get-FunctionText $invokeAst 'Update-WingetPackages'
        foreach ($repairIndex in [regex]::Matches($winget, 'Invoke-WingetAggressiveRepair') | ForEach-Object Index) {
            $classificationIndex = $winget.LastIndexOf('Complete-WingetFailureClassification', $repairIndex)
            $classificationIndex | Should -BeGreaterThan -1
            $classificationIndex | Should -BeLessThan $repairIndex
        }
        $winget | Should -Match 'identical failure signature already attempted; verification only'
    }

    It 'quarantines every persistent Winget failure with reversible blocking pins' {
        $script:WingetQuarantinePath = Join-Path $TestDrive 'all-pinned-quarantine.json'
        $state = [pscustomobject]@{ WingetQuarantines=@() }
        $failures = @(
            [pscustomobject]@{ Name='Health Check'; Id='Microsoft.WindowsPCHealthCheck'; Code=1612 },
            [pscustomobject]@{ Name='iCUE'; Id='Corsair.iCUE.5'; Code=3221226525 }
        )
        $script:pinArguments = @()
        Mock Invoke-PackageManagerWithTimeout {
            $script:pinArguments += ,@($ArgumentList)
            [pscustomobject]@{ ExitCode=0; TimedOut=$false; Failed=$false; Output=@('Pin added') }
        }
        Mock Write-ProviderTranscript { }

        $result = Invoke-WingetFailureQuarantine -WingetPath 'C:\winget.exe' -State $state `
            -Signature 'Corsair.iCUE.5:3221226525|Microsoft.WindowsPCHealthCheck:1612' -Failures $failures

        $result.AllPinned | Should -BeTrue
        @($result.PinnedIds).Count | Should -Be 2
        @($state.WingetQuarantines).Count | Should -Be 2
        @((Get-WingetQuarantineRecords)).Count | Should -Be 2
        @($script:pinArguments | ForEach-Object { $_[1] }) | Should -Contain 'Corsair.iCUE.5'
        @($script:pinArguments | ForEach-Object { $_[1] }) | Should -Contain 'Microsoft.WindowsPCHealthCheck'
        foreach ($record in $state.WingetQuarantines) {
            $record.PinCommand | Should -Be "winget pin add --id $($record.PackageId) -e --blocking --force --disable-interactivity"
            $record.UnpinCommand | Should -Be "upd uq $($record.PackageId)"
            $record.NativeUnpinCommand | Should -Be "winget pin remove --id $($record.PackageId) -e --disable-interactivity"
            $record.FailureSignature | Should -Not -BeNullOrEmpty
            $record.PinnedAt | Should -Not -BeNullOrEmpty
        }
        Assert-MockCalled Invoke-PackageManagerWithTimeout -Times 2 -Exactly
    }

    It 'withholds Winget quarantine success if any terminal failure was not pinned' {
        $script:WingetQuarantinePath = Join-Path $TestDrive 'partial-quarantine.json'
        $state = [pscustomobject]@{ WingetQuarantines=@() }
        $failures = @(
            [pscustomobject]@{ Name='Health Check'; Id='Microsoft.WindowsPCHealthCheck'; Code=1612 },
            [pscustomobject]@{ Name='iCUE'; Id='Corsair.iCUE.5'; Code=3221226525 }
        )
        Mock Invoke-PackageManagerWithTimeout {
            if ($ArgumentList[1] -eq 'Corsair.iCUE.5') {
                return [pscustomobject]@{ ExitCode=1; TimedOut=$false; Failed=$true; Output=@('Pin failed') }
            }
            [pscustomobject]@{ ExitCode=0; TimedOut=$false; Failed=$false; Output=@('Pin added') }
        }
        Mock Write-ProviderTranscript { }

        $result = Invoke-WingetFailureQuarantine -WingetPath 'C:\winget.exe' -State $state `
            -Signature 'repeat' -Failures $failures

        $result.AllPinned | Should -BeFalse
        @($state.WingetQuarantines).Count | Should -Be 1
        $state.WingetQuarantines[0].PackageId | Should -Be 'Microsoft.WindowsPCHealthCheck'
    }

    It 'writes a durable plan with explanations outside a valid cmd copy block' {
        $script:InstallDir = $TestDrive
        Mock Set-BootUpdateClipboardText { $true }
        $items = @(
            [pscustomobject]@{ Name='Health Check'; Id='Microsoft.WindowsPCHealthCheck'; Code=1612; Hex='0x0000064C'; Command='winget repair --id Microsoft.WindowsPCHealthCheck -e --force' },
            [pscustomobject]@{ Name='iCUE'; Id='Corsair.iCUE.5'; Code=3221226525; Hex='0xC000041D'; Command='winget install --id Corsair.iCUE.5 -e --force' }
        )
        $result = Write-BootUpdateRepairPlan -Items $items
        $path = $result.Path
        $result.ClipboardCopied | Should -BeTrue
        Test-Path -LiteralPath $path | Should -BeTrue
        $lines = Get-Content -LiteralPath $path
        $blockStart = [array]::IndexOf($lines,'COPY/PASTE BLOCK — ELEVATED COMMAND PROMPT') + 1
        $block = @($lines | Select-Object -Skip $blockStart)
        @($block | Where-Object { $_ -notmatch '^(?:REM(?:\s|$)|winget\s|upd$)' }).Count | Should -Be 0
        ($block -join "`n") | Should -Match 'winget repair --id Microsoft\.WindowsPCHealthCheck'
        ($block -join "`n") | Should -Match 'winget install --id Corsair\.iCUE\.5'
    }

    It 'times out a blocked clipboard helper and disposes it without losing the repair plan' {
        $fakeInput = [pscustomobject]@{}
        $fakeInput | Add-Member ScriptMethod WriteLine { param($value) }
        $fakeInput | Add-Member ScriptMethod Close { }
        $fake = [pscustomobject]@{ StandardInput=$fakeInput; ExitCode=0; Killed=$false; Disposed=$false }
        $fake | Add-Member ScriptMethod WaitForExit { param($milliseconds) return $false }
        $fake | Add-Member ScriptMethod Kill { param($tree) $this.Killed = $true }
        $fake | Add-Member ScriptMethod Dispose { $this.Disposed = $true }

        Set-BootUpdateClipboardText -Value 'C:\repair-plan.txt' -TimeoutMilliseconds 100 -ProcessFactory { $fake } |
            Should -BeFalse
        $fake.Killed | Should -BeTrue
        $fake.Disposed | Should -BeTrue
    }

    It 'reports a durable repair plan even when clipboard delivery is unavailable' {
        $script:InstallDir = $TestDrive
        Mock Set-BootUpdateClipboardText { $false }
        $item = [pscustomobject]@{ Name='iCUE'; Id='Corsair.iCUE.5'; Code=1; Hex='0x00000001'; Command='winget install --id Corsair.iCUE.5 -e' }
        $result = Write-BootUpdateRepairPlan -Items @($item)

        Test-Path -LiteralPath $result.Path | Should -BeTrue
        $result.ClipboardCopied | Should -BeFalse
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
    It 'ignores only Chocolatey prototype delete-on-reboot entries and preserves real rename pairs' {
        $priorWindir = $env:windir
        try {
            $env:windir = 'C:\Windows'
            $entries = @(
                '\??\C:\Windows\SystemTemp\ChocolateyPrototype-2.8.5.130\1', '',
                '\??\C:\Program Files\Vendor\old.dll', '\??\C:\Program Files\Vendor\new.dll',
                '\??\C:\Windows\System32\pending.tmp', ''
            )
            $operations = @(Get-ActionablePendingFileRenameOperations -Entries $entries)
            $operations.Count | Should -Be 2
            $operations[0].Source | Should -Be 'C:\Program Files\Vendor\old.dll'
            $operations[0].Destination | Should -Be 'C:\Program Files\Vendor\new.dll'
            $operations[1].Source | Should -Be 'C:\Windows\System32\pending.tmp'
            $operations[1].Destination | Should -BeNullOrEmpty
        } finally { $env:windir = $priorWindir }
    }

    It 'does not ignore a Chocolatey prototype rename with a real destination' {
        $priorWindir = $env:windir
        try {
            $env:windir = 'C:\Windows'
            $operations = @(Get-ActionablePendingFileRenameOperations -Entries @(
                '\??\C:\Windows\SystemTemp\ChocolateyPrototype-2.8.5.130\1',
                '\??\C:\Windows\System32\not-disposable.dll'
            ))
            $operations.Count | Should -Be 1
        } finally { $env:windir = $priorWindir }
    }

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
        foreach ($switchName in @('SkipBitLocker','AllowMetered','DisableSelfUpdate','UpdateWsl','UpdateContainers','AggressiveRepair')) {
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

    It 'stops automatic retries for a persistent terminal provider failure' {
        $result = Resolve-BootUpdateCompletionDisposition -IncompletePhases @(
            @{ Name='Winget'; UserCompletionDeferred=$false; TerminalFailure=$true; AttentionDetails=@('iCUE') }
        )
        $result.Kind | Should -Be 'Attention'
        $cycle = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $cycle | Should -Match "disposition\.Kind -eq 'Attention'[\s\S]*?Stop-BootUpdateForManualAttention"
    }

    It 'still disarms and presents the durable repair path when checkpoint persistence fails' {
        $script:UnregisterCalls = 0
        $script:FailUnregister = $false
        $script:StatePath = 'C:\ProgramData\BootUpdateCycle\BootUpdateCycle.state.json'
        $script:LogPath = 'C:\ProgramData\BootUpdateCycle\BootUpdateCycle.log'
        Mock Set-BootUpdateState { throw 'simulated checkpoint write failure' }
        Mock Write-BootUpdateRepairPlan {
            [pscustomobject]@{ Path='C:\ProgramData\BootUpdateCycle\BootUpdateCycle-repair-plan.txt'; ClipboardCopied=$false }
        }
        Mock Show-CycleBanner { }
        $state = [pscustomobject]@{ Phase='RetryPending'; LimitReachedAt=$null; LimitReason=$null }
        $phase = [pscustomobject]@{
            Name='Winget'; AttentionDetails=@([pscustomobject]@{ Name='iCUE'; Id='Corsair.iCUE.5'; Code=1; Hex='0x00000001' })
        }

        { Stop-BootUpdateForManualAttention -State $state -Phases @($phase) } | Should -Not -Throw
        $script:UnregisterCalls | Should -Be 1
        Should -Invoke Show-CycleBanner -Times 1 -ParameterFilter {
            ($Info -join "`n") -match 'clipboard unavailable' -and
            ($Info -join "`n") -match 'diagnostic state could not be saved'
        }
    }

    It 'still presents terminal attention when repair-plan generation throws' {
        $script:UnregisterCalls = 0
        $script:FailUnregister = $false
        $script:StatePath = 'C:\ProgramData\BootUpdateCycle\BootUpdateCycle.state.json'
        $script:LogPath = 'C:\ProgramData\BootUpdateCycle\BootUpdateCycle.log'
        Mock Set-BootUpdateState { }
        Mock Write-BootUpdateRepairPlan { throw 'simulated repair-plan failure' }
        Mock Show-CycleBanner { }
        $state = [pscustomobject]@{ Phase='RetryPending'; LimitReachedAt=$null; LimitReason=$null }
        $phase = [pscustomobject]@{ Name='Winget'; AttentionDetails=@() }

        { Stop-BootUpdateForManualAttention -State $state -Phases @($phase) } | Should -Not -Throw
        $script:UnregisterCalls | Should -Be 1
        Should -Invoke Show-CycleBanner -Times 1 -ParameterFilter {
            ($Info -join "`n") -match 'Repair-plan creation failed'
        }
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
        $script:CurrentState = $null
        Mock Get-Module { [pscustomobject]@{ Name='PSWindowsUpdate' } }
        Mock Get-BootUpdateBootSessionId { 'boot-a' }
        Mock Write-Log {}
        Mock Set-WindowsUpdateAssessmentCache {}
    }

    It 'verifies zero applicable updates' {
        Mock Invoke-BootUpdateBackgroundOperation { [pscustomobject]@{ Output=@('BOOTUPDATE_SCAN_COMPLETE|0'); Failed=$false; TimedOut=$false } }
        $result = Test-WindowsUpdateConvergence
        $result.Verified | Should -BeTrue
        $result.Count | Should -Be 0
    }

    It 'accepts only exact post-search zero evidence and does not count zero download/install summaries' {
        $summary = Get-WindowsUpdateInstallOutputSummary -Lines @(
            'Downloaded [0] Updates',
            'Installed [0] Updates',
            'Found [0] Updates in post search criteria'
        )
        $summary.Installed | Should -Be 0
        $summary.PostSearchZero | Should -BeTrue

        (Get-WindowsUpdateInstallOutputSummary -Lines @('Found [0] Updates in pre search criteria')).PostSearchZero | Should -BeFalse
        (Get-WindowsUpdateInstallOutputSummary -Lines @('Found [1] Updates in post search criteria')).PostSearchZero | Should -BeFalse
    }

    It 'counts the installed aggregate without double-counting downloaded updates' {
        $summary = Get-WindowsUpdateInstallOutputSummary -Lines @('Downloaded [3] Updates','Installed [2] Updates')
        $summary.Installed | Should -Be 2
    }

    It 'does not count the legacy empty applicable marker as an update' {
        Mock Invoke-BootUpdateBackgroundOperation { [pscustomobject]@{ Output=@('BOOTUPDATE_APPLICABLE||','BOOTUPDATE_SCAN_COMPLETE|0'); Failed=$false; TimedOut=$false } }
        $result = Test-WindowsUpdateConvergence
        $result.Verified | Should -BeTrue
        $result.Count | Should -Be 0
        Assert-MockCalled Write-Log -Times 0 -ParameterFilter { $Message -like 'Final WU scan:*' }
    }

    It 'reports remaining applicable updates' {
        Mock Get-WindowsUpdateEnvironmentFingerprint { 'fingerprint' }
        Mock Set-WindowsUpdateAssessmentCache {}
        Mock Invoke-BootUpdateBackgroundOperation { [pscustomobject]@{ Output=@('BOOTUPDATE_APPLICABLE|id-1|7|Update','BOOTUPDATE_SCAN_COMPLETE|1'); Failed=$false; TimedOut=$false } }
        $result = Test-WindowsUpdateConvergence
        $result.Verified | Should -BeTrue
        $result.Count | Should -Be 1
    }

    It 'withholds verification after a scan error' {
        Mock Invoke-BootUpdateBackgroundOperation { [pscustomobject]@{ Output=@('BOOTUPDATE_ERROR|offline'); Failed=$false; TimedOut=$false } }
        (Test-WindowsUpdateConvergence).Verified | Should -BeFalse
    }

    It 'withholds verification when the child exits without a completion marker' {
        Mock Invoke-BootUpdateBackgroundOperation { [pscustomobject]@{ Output=@(); Failed=$false; TimedOut=$false } }
        (Test-WindowsUpdateConvergence).Verified | Should -BeFalse
    }

    It 'withholds verification when the completion count disagrees with update records' {
        Mock Invoke-BootUpdateBackgroundOperation { [pscustomobject]@{
            Output=@('BOOTUPDATE_APPLICABLE|id-1|7|Update','BOOTUPDATE_SCAN_COMPLETE|0')
            Failed=$false; TimedOut=$false
        } }
        (Test-WindowsUpdateConvergence).Verified | Should -BeFalse
    }

    It 'reuses exact post-search zero evidence only on the same boot and scope' {
        $verificationScope = Get-WindowsUpdateVerificationScope
        $evidence = [pscustomobject]@{
            BootSessionId='boot-a'; ScopeSignature=$verificationScope.Signature
            Source='PSWindowsUpdate-post-search-zero'; ObservedAt=[datetime]::UtcNow.ToString('o')
        }
        $script:CurrentState = [pscustomobject]@{ WindowsUpdateZeroEvidence = $evidence }
        Mock Invoke-BootUpdateBackgroundOperation { throw 'redundant scan should not run' }
        $result = Test-WindowsUpdateConvergence
        $result.Verified | Should -BeTrue
        $result.Count | Should -Be 0
        Assert-MockCalled Invoke-BootUpdateBackgroundOperation -Times 0
    }

    It 'invalidates cached zero evidence after a boot change and performs the scan' {
        $verificationScope = Get-WindowsUpdateVerificationScope
        $evidence = [pscustomobject]@{
            BootSessionId='old-boot'; ScopeSignature=$verificationScope.Signature
            Source='PSWindowsUpdate-post-search-zero'; ObservedAt=[datetime]::UtcNow.ToString('o')
        }
        $script:CurrentState = [pscustomobject]@{ WindowsUpdateZeroEvidence = $evidence }
        Mock Invoke-BootUpdateBackgroundOperation { [pscustomobject]@{ Output=@('BOOTUPDATE_SCAN_COMPLETE|0'); Failed=$false; TimedOut=$false } }
        (Test-WindowsUpdateConvergence).Verified | Should -BeTrue
        $script:CurrentState.WindowsUpdateZeroEvidence | Should -BeNullOrEmpty
        Assert-MockCalled Invoke-BootUpdateBackgroundOperation -Times 1
    }

    It 'invalidates cached zero evidence when exclusions change' {
        $oldScope = Get-WindowsUpdateVerificationScope
        $evidence = [pscustomobject]@{
            BootSessionId='boot-a'; ScopeSignature=$oldScope.Signature
            Source='PSWindowsUpdate-post-search-zero'; ObservedAt=[datetime]::UtcNow.ToString('o')
        }
        $script:CurrentState = [pscustomobject]@{ WindowsUpdateZeroEvidence = $evidence }
        $script:ExcludePatterns = @('SQL','Preview')
        Mock Invoke-BootUpdateBackgroundOperation { [pscustomobject]@{ Output=@('BOOTUPDATE_SCAN_COMPLETE|0'); Failed=$false; TimedOut=$false } }
        (Test-WindowsUpdateConvergence).Verified | Should -BeTrue
        Assert-MockCalled Invoke-BootUpdateBackgroundOperation -Times 1
    }

}

Describe 'Cross-session Windows Update assessment cache' {
    BeforeEach {
        $script:WindowsUpdateAssessmentPath = Join-Path $TestDrive 'wu-assessment.json'
        $script:WindowsUpdateOnlineAssessmentTtlHours = 6
        $script:ExcludePatterns = @('SQL')
        Mock Get-WindowsUpdateEnvironmentFingerprint { 'same-environment' }
    }

    It 'accepts a fresh assessment across a boot boundary when scope and environment match' {
        $verificationScope = Get-WindowsUpdateVerificationScope
        $record = [pscustomobject]@{ SchemaVersion=1; ObservedAtUtc=[datetime]::UtcNow.AddHours(-1).ToString('o');
           BootSessionId='previous-boot'; ScopeSignature=$verificationScope.Signature;
           EnvironmentFingerprint='same-environment'; ApplicableUpdates=@() }
        Test-WindowsUpdateAssessmentRecord -Record $record -Scope $verificationScope -EnvironmentFingerprint 'same-environment' -TtlHours 6 | Should -BeTrue
    }

    It 'requires an online assessment when the TTL expires' {
        $verificationScope = Get-WindowsUpdateVerificationScope
        $record = [pscustomobject]@{ SchemaVersion=1; ObservedAtUtc=[datetime]::UtcNow.AddHours(-7).ToString('o');
           BootSessionId='previous-boot'; ScopeSignature=$verificationScope.Signature;
           EnvironmentFingerprint='same-environment'; ApplicableUpdates=@() }
        Test-WindowsUpdateAssessmentRecord -Record $record -Scope $verificationScope -EnvironmentFingerprint 'same-environment' -TtlHours 6 | Should -BeFalse
    }

    It 'requires online work when the local catalog still has applicable updates' {
        $verificationScope = Get-WindowsUpdateVerificationScope
        @{ SchemaVersion=1; ObservedAtUtc=[datetime]::UtcNow.AddMinutes(-20).ToString('o');
           BootSessionId='previous-boot'; ScopeSignature=$verificationScope.Signature;
           EnvironmentFingerprint='same-environment'; ApplicableUpdates=@() } |
            ConvertTo-Json | Set-Content $script:WindowsUpdateAssessmentPath
        $offline = [pscustomobject]@{ Verified=$true; Updates=@([pscustomobject]@{UpdateID='id';RevisionNumber=2}); Error=$null }
        (Test-WindowsUpdateAssessmentCache -Scope $verificationScope -Path $script:WindowsUpdateAssessmentPath -TtlHours 6 -EnvironmentFingerprint 'same-environment' -OfflineAssessmentResult $offline) | Should -BeFalse
    }

    It 'bounds offline WUA work and requires a count-matched completion contract' {
        $text = Get-FunctionText $invokeAst 'Invoke-WindowsUpdateOfflineAssessment'
        $text | Should -Match 'Invoke-BootUpdateBackgroundOperation'
        $text | Should -Match 'TimeoutMinutes'
        $text | Should -Match 'BOOTUPDATE_SCAN_COMPLETE'
        $text | Should -Match '\$declared -ne \$records.Count'
    }

    It 'fingerprints registered update services as well as policy and history' {
        $text = Get-FunctionText $invokeAst 'Get-WindowsUpdateEnvironmentFingerprint'
        $text | Should -Match 'Microsoft.Update.ServiceManager'
        $text | Should -Match 'ServerSelection'
        $text | Should -Match 'ServiceID'
    }

    It 'uses a count-preserving identity fallback for PSWindowsUpdate result shapes' {
        $text = Get-FunctionText $invokeAst 'Test-WindowsUpdateConvergence'
        $text | Should -Match '\$_.Identity'
        $text | Should -Match 'identity-unavailable'
        $text | Should -Match 'RevisionNumber'
    }

    It 'does not delete assessment evidence during WhatIf' {
        (Get-FunctionText $invokeAst 'Remove-WindowsUpdateAssessmentCache') | Should -Match '\$WhatIfPreference -and -not \$Force'
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

    It 'reports durable Winget quarantine as degraded completion rather than fully patched' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $text | Should -Match 'COMPLETE WITH WINGET QUARANTINE'
        $text | Should -Match 'this is not a fully-patched claim'
        $text | Should -Match 'Boot Update Cycle Complete with Quarantine'
        $text | Should -Match 'WingetQuarantinePath'
        (Get-FunctionText $invokeAst 'Clear-BootUpdateState') | Should -Not -Match 'WingetQuarantine'
    }

    It 'requires completed thread jobs and structured success' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $text | Should -Match "jobState -ne 'Completed'"
        $text | Should -Match 'phaseSucceeded = \$jobState -eq ''Completed''.*jr\.Success'
    }
}

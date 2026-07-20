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
        'Get-NextMaintenanceWindowStart',
        'Test-WindowsUpdateConvergence'
    )) {
        . ([scriptblock]::Create((Get-FunctionText $invokeAst $functionName)))
    }
    function Write-Log { param([string]$Message, [string]$Level) }
    function Invoke-BootUpdateBackgroundOperation { param($Name, $Status, $TimeoutMinutes, $ScriptBlock, $ArgumentList) }
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

Describe 'Durable resume chain' {
    It 'uses ARSO user resume plus a delayed SYSTEM safety net' {
        $text = Get-FunctionText $invokeAst 'Register-BootUpdateTaskForReboot'
        $text | Should -Match 'New-ScheduledTaskTrigger -AtLogOn'
        $text | Should -Match 'BootUpdateCycleFallback'
        $text | Should -Match "Delay = 'PT3M'"
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

    It 'clears stale explicit evidence without inventing a reboot count outside Rebooting' {
        $state = [pscustomobject]@{ LastBootSessionId='boot-a'; Phase='RetryPending'; RebootCount=2; ExplicitRebootRequests=@('3010') }
        $actual = Update-BootUpdateStateForBootSession -State $state -CurrentBootSessionId 'boot-b'
        $actual.RebootCount | Should -Be 2
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

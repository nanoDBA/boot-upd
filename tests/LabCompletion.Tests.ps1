BeforeAll {
    $path = Join-Path $PSScriptRoot 'integration/lab/Invoke-LabRow.ps1'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Lab harness must parse before extracting its completion predicate.' }
    $fn = $ast.Find({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Test-LabCompletionEvidence'
    }, $true)
    . ([scriptblock]::Create($fn.Extent.Text))
    $waitFn = $ast.Find({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Test-LabSavedUserWaitEvidence'
    }, $true)
    . ([scriptblock]::Create($waitFn.Extent.Text))
    foreach ($name in @('New-LabStageEvidence','Get-LabPowerShellRuntimeHandoffEvidence','Test-LabShouldStopAfterContinuationRuntime','Test-LabRebootAfterBootstrap','Get-LabRuntimeEventTimestampUtc')) {
        $helper = $ast.Find({ param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        if ($helper) { . ([scriptblock]::Create($helper.Extent.Text)) }
    }
}

Describe 'A parked saved-user cycle needs checkpoint and scheduler evidence' {
    BeforeEach {
        $waitEvidence=@{Phase='UserContextPending';ResumeUser='LAB\test';TaskNames=@('BootUpdateCycle');PrimaryTriggerTypes=@('MSFT_TaskLogonTrigger');LogonOnlyVerified=$true}
    }
    It 'recognizes a saved-user wait without declaring completion' {
        Test-LabSavedUserWaitEvidence @waitEvidence | Should -BeTrue
        Test-LabCompletionEvidence -Passes 3 -CompletionRecords 0 -TasksRemaining 1 -StateFileExists $true | Should -BeFalse
    }
    It 'rejects a stale log record when the SYSTEM fallback still exists' {
        $waitEvidence.TaskNames=@('BootUpdateCycle','BootUpdateCycleFallback')
        Test-LabSavedUserWaitEvidence @waitEvidence | Should -BeFalse
    }
    It 'rejects a dated retry or watchdog still attached to the task' {
        $waitEvidence.PrimaryTriggerTypes+= 'MSFT_TaskTimeTrigger'
        Test-LabSavedUserWaitEvidence @waitEvidence | Should -BeFalse
    }
    It 'rejects missing checkpoint ownership' {
        $waitEvidence.ResumeUser=''
        Test-LabSavedUserWaitEvidence @waitEvidence | Should -BeFalse
    }
    It 'rejects a pending checkpoint before successful task verification' {
        $waitEvidence.LogonOnlyVerified=$false
        Test-LabSavedUserWaitEvidence @waitEvidence | Should -BeFalse
    }
}

Describe 'Lab completion requires observed cleanup' {
    It 'recognizes the progress-aware reboot stop as a terminal outcome' {
        $source = Get-Content (Join-Path $PSScriptRoot 'integration/lab/Invoke-LabRow.ps1') -Raw
        $source | Should -Match 'recovery limit\|Reboot limit\|No-progress reboot limit'
    }

    It 'keeps watching when task removal precedes state removal' {
        Test-LabCompletionEvidence -Passes 5 -CompletionRecords 1 -TasksRemaining 0 -StateFileExists $true |
            Should -BeFalse
    }

    It 'does not turn an empty clean machine into a completed run' {
        Test-LabCompletionEvidence -Passes 0 -CompletionRecords 0 -TasksRemaining 0 -StateFileExists $false |
            Should -BeFalse
    }

    It 'rejects remaining continuation tasks' {
        Test-LabCompletionEvidence -Passes 2 -CompletionRecords 1 -TasksRemaining 1 -StateFileExists $false |
            Should -BeFalse
    }

    It 'accepts a started and completed run only after both cleanup facts hold' {
        Test-LabCompletionEvidence -Passes 2 -CompletionRecords 1 -TasksRemaining 0 -StateFileExists $false |
            Should -BeTrue
    }

    It 'does not retain an earlier positive when the collected snapshot contradicts it' {
        $completed = Test-LabCompletionEvidence -Passes 2 -CompletionRecords 1 -TasksRemaining 0 -StateFileExists $false
        $completed | Should -BeTrue
        $completed = Test-LabCompletionEvidence -Passes 2 -CompletionRecords 1 -TasksRemaining 0 -StateFileExists $true
        $completed | Should -BeFalse
    }
}

Describe 'Lab runtime handoff stage evidence' {
    It 'compares guest boot time and host stage time in UTC' {
        $bootstrap = [datetime]'2026-11-14T19:18:45Z'

        Test-LabRebootAfterBootstrap -BootTimeUtc '2026-11-14T19:19:40.0000000Z' -BootstrapObservedAtUtc $bootstrap | Should -BeTrue
        Test-LabRebootAfterBootstrap -BootTimeUtc '2026-11-14T19:18:44.0000000Z' -BootstrapObservedAtUtc $bootstrap | Should -BeFalse
    }

    It 'orders a delayed poll by the guest runtime event time, not the host observation time' {
        $event = [pscustomobject]@{ TimestampUtc='2026-11-14T19:43:47.0000000Z' }
        $runtimeTime = Get-LabRuntimeEventTimestampUtc -RuntimeEvent $event

        Test-LabRebootAfterBootstrap -BootTimeUtc '2026-11-14T19:44:02.0000000Z' -BootstrapObservedAtUtc $runtimeTime | Should -BeTrue
    }

    It 'records the elapsed phase time with the observed facts' {
        $start = [datetime]'2026-11-14T12:00:00Z'
        $observed = [datetime]'2026-11-14T12:00:03.500Z'
        $facts = [pscustomobject]@{ Runtime='PowerShell 7.7'; MSI=@('7.6.10.0'); MSIX=@('7.7.0.0') }

        $stage = New-LabStageEvidence -Name 'bootstrap-done' -StartedAtUtc $start -ObservedAtUtc $observed -Facts $facts

        $stage.Name | Should -Be 'bootstrap-done'
        $stage.DurationSeconds | Should -Be 3.5
        $stage.Facts.Runtime | Should -Be 'PowerShell 7.7'
    }

    It 'passes only when upd and the SYSTEM continuation use 7.7 while both installs remain' {
        $runtimeLines = @(
            '[2026-11-14 14:18:45] [Info] PowerShell runtime | Version: 7.7.0 | Install folder: C:\Program Files\WindowsApps\Microsoft.PowerShell_7.7.0.0_x64__8wekyb3d8bbwe\pwsh.exe | Account: SYSTEM | Launched by: upd',
            '[2026-11-14 14:19:49] [Info] PowerShell runtime | Version: 7.7.0 | Install folder: C:\Program Files\WindowsApps\Microsoft.PowerShell_7.7.0.0_x64__8wekyb3d8bbwe\pwsh.exe | Account: SYSTEM | Launched by: continuation'
        )

        $evidence = Get-LabPowerShellRuntimeHandoffEvidence -RuntimeLines $runtimeLines `
            -MsiVersions @('7.6.10.0') -MsixVersions @('7.7.0.0') -RebootSeen $true

        $evidence.Passed | Should -BeTrue
        $evidence.ContinuationRuntimeLine | Should -Be $runtimeLines[1]
    }

    It 'rejects a fallback launch or a missing MSI instead of overstating the row' {
        $runtimeLines = @(
            'PowerShell runtime | Version: 7.7.0 | Install folder: C:\Program Files\WindowsApps\Microsoft.PowerShell_7.7.0.0_x64__8wekyb3d8bbwe\pwsh.exe | Account: SYSTEM | Launched by: upd',
            'PowerShell runtime | Version: 7.7.0 | Install folder: C:\Program Files\WindowsApps\Microsoft.PowerShell_7.7.0.0_x64__8wekyb3d8bbwe\pwsh.exe | Account: SYSTEM | Launched by: fallback'
        )

        $evidence = Get-LabPowerShellRuntimeHandoffEvidence -RuntimeLines $runtimeLines `
            -MsiVersions @() -MsixVersions @('7.7.0.0') -RebootSeen $true

        $evidence.Passed | Should -BeFalse
    }

    It 'does not call a continuation handoff a pass without a reboot between launches' {
        $runtimeLines = @(
            '[2026-11-14 14:18:45] [Info] PowerShell runtime | Version: 7.7.0 | Install folder: C:\Program Files\WindowsApps\Microsoft.PowerShell_7.7.0.0_x64__8wekyb3d8bbwe\pwsh.exe | Account: SYSTEM | Launched by: upd',
            '[2026-11-14 14:19:49] [Info] PowerShell runtime | Version: 7.7.0 | Install folder: C:\Program Files\WindowsApps\Microsoft.PowerShell_7.7.0.0_x64__8wekyb3d8bbwe\pwsh.exe | Account: SYSTEM | Launched by: continuation'
        )

        $evidence = Get-LabPowerShellRuntimeHandoffEvidence -RuntimeLines $runtimeLines `
            -MsiVersions @('7.6.10.0') -MsixVersions @('7.7.0.0') -RebootSeen $false

        $evidence.Passed | Should -BeFalse
    }

    It 'accepts the SYSTEM fallback task as the headless continuation path' {
        $runtimeLines = @(
            '[2026-11-14 14:18:45] [Info] PowerShell runtime | Version: 7.7.0 | Install folder: C:\Program Files\WindowsApps\Microsoft.PowerShell_7.7.0.0_x64__8wekyb3d8bbwe\pwsh.exe | Account: SYSTEM | Launched by: upd',
            '[2026-11-14 14:19:49] [Info] PowerShell runtime | Version: 7.7.0 | Install folder: C:\Program Files\WindowsApps\Microsoft.PowerShell_7.7.0.0_x64__8wekyb3d8bbwe\pwsh.exe | Account: SYSTEM | Launched by: fallback'
        )

        $evidence = Get-LabPowerShellRuntimeHandoffEvidence -RuntimeLines $runtimeLines `
            -MsiVersions @('7.6.10.0') -MsixVersions @('7.7.0.0') -RebootSeen $true

        $evidence.Passed | Should -BeTrue
        $evidence.ContinuationRuntimeLine | Should -Be $runtimeLines[1]
    }

    It 'stops only after the qualifying continuation runtime has been observed' {
        Test-LabShouldStopAfterContinuationRuntime -Enabled $true -Evidence ([pscustomobject]@{ Passed=$false }) | Should -BeFalse
        Test-LabShouldStopAfterContinuationRuntime -Enabled $true -Evidence ([pscustomobject]@{ Passed=$true }) | Should -BeTrue
        Test-LabShouldStopAfterContinuationRuntime -Enabled $false -Evidence ([pscustomobject]@{ Passed=$true }) | Should -BeFalse
    }
}

BeforeAll {
    $path = Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-BootUpdateCycle.ps1'
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    $errors | Should -BeNullOrEmpty
    foreach ($name in @('New-BootUpdateStateV2','Update-BootUpdateStateSchema',
        'ConvertTo-BootUpdateTimestampString','Test-CrashRecovery','Set-BootUpdateRebootCheckpoint',
        'ConvertTo-SsmsVersion','Get-SsmsPendingUpdate','Save-SsmsPendingUpdate',
        'Confirm-SsmsPendingUpdate','Complete-SsmsUpdateAccounting','Reset-SsmsPendingVerification',
        'Apply-RemoteConfig')) {
        $node = $ast.Find({ param($n)
            $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
        }, $true)
        . ([scriptblock]::Create($node.Extent.Text))
    }
    function Write-Log { param($Message, $Level, $Visibility) }
    function Set-BootUpdateState { param($State) }
    function Update-SsmsInstances { $script:SsmsActionCalls++; return @{Success=$true;Count=1} }
    $script:BootUpdateStateSchemaVersion = 6
    $script:MaxRetryPasses = 5
}

Describe 'SSMS durable phase lifecycle' {
    BeforeEach { $script:CurrentState = New-BootUpdateStateV2; $SkipSsms = $false }
    It 'invokes the native provider by default in the serial dispatch table after Chocolatey' {
        $assignment=$ast.Find({param($n)
            $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$allPhases'
        },$true)
        $phases=@(& ([scriptblock]::Create($assignment.Right.Extent.Text)))
        $names=@($phases.Name)
        $index=[array]::IndexOf($names,'Ssms')
        $index | Should -BeGreaterThan 0
        $names[$index-1] | Should -Be 'Chocolatey'
        $phase=$phases[$index]
        $phase.Skip | Should -BeFalse
        $phase.Flag | Should -Be 'SsmsDone'
        $phase.Key | Should -Be 'Ssms'
        $script:SsmsActionCalls=0
        (& $phase.Action).Count | Should -Be 1
        $script:SsmsActionCalls | Should -Be 1
    }

    It 'skips only native SSMS servicing when requested' {
        $SkipSsms = $true
        $assignment=$ast.Find({param($n)
            $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$allPhases'
        },$true)
        $phase=@(& ([scriptblock]::Create($assignment.Right.Extent.Text)) | Where-Object Name -eq 'Ssms')[0]
        $phase.Skip | Should -BeTrue
        $phase.Action.ToString() | Should -Match 'Update-SsmsInstances'
    }

    It 'keeps an explicit SkipSsms false value ahead of remote configuration' {
        $script:SkipSsms = $false
        Apply-RemoteConfig -RemoteConfig ([pscustomobject]@{ SkipSsms = $true }) `
            -UserBoundParams @{ SkipSsms = [switch]$false }
        $script:SkipSsms | Should -BeFalse

        Apply-RemoteConfig -RemoteConfig ([pscustomobject]@{ SkipSsms = $true }) -UserBoundParams @{}
        $script:SkipSsms | Should -BeTrue
    }
    It 'migrates a published checkpoint and summary without skipping the new provider' {
        $old = New-BootUpdateStateV2
        $old.PSObject.Properties.Remove('SsmsDone')
        $old.Summary.PSObject.Properties.Remove('Ssms')
        $old.PSObject.Properties.Remove('SsmsPendingUpdates')
        $old.ChocolateyDone = $true
        $old.Summary.Chocolatey = 2
        $restored = $old | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        Update-BootUpdateStateSchema -State $restored
        $restored.SsmsDone | Should -BeFalse
        $restored.Summary.Ssms | Should -Be 0
        $restored.SsmsPendingUpdates.Count | Should -Be 0
        $restored.ChocolateyDone | Should -BeTrue
        $restored.Summary.Chocolatey | Should -Be 2
    }

    It 'charges a killed native phase once without consuming the reboot budget' {
        $state = New-BootUpdateStateV2
        $state.Phase = 'Ssms'; $state.LastPhaseStarted = 'Ssms'; $state.Iteration = 2
        $state.ChocolateyDone = $true
        Test-CrashRecovery -State $state | Should -BeTrue
        Test-CrashRecovery -State $state | Should -BeTrue
        $state.ConsecutiveRetryCount | Should -Be 1
        $state.RebootCount | Should -Be 0
        $state.ChocolateyDone | Should -BeTrue
        $state.UnobservedStops.Count | Should -Be 1
        $state.UnobservedStops[0].Phase | Should -Be 'Ssms'
    }

    It 'preserves an unfinished SSMS phase and explicit reboot evidence across JSON checkpointing' {
        $state = New-BootUpdateStateV2
        $state.Phase = 'Ssms'; $state.LastPhaseStarted = 'Ssms'
        $state.ChocolateyDone = $true
        $state.ExplicitRebootRequests = @([pscustomobject]@{Source='SSMS-exit-3010'; Status='Pending'})
        $null = Set-BootUpdateRebootCheckpoint -State $state -SignalKey 'SSMS-exit-3010'
        $restored = $state | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $restored.SsmsDone | Should -BeFalse
        $restored.ChocolateyDone | Should -BeTrue
        $restored.ExplicitRebootRequests[0].Source | Should -Be 'SSMS-exit-3010'
        Test-CrashRecovery -State $restored | Should -BeTrue
        $restored.ConsecutiveRetryCount | Should -Be 0
    }

    It 'does not rerun a completed native phase after an unrelated provider restarts Windows' {
        $state = New-BootUpdateStateV2
        $state.SsmsDone = $true; $state.Summary.Ssms = 1
        $null = Set-BootUpdateRebootCheckpoint -State $state -SignalKey 'WindowsUpdate'
        $restored = $state | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        Update-BootUpdateStateSchema -State $restored
        $restored.SsmsDone | Should -BeTrue
        $restored.Summary.Ssms | Should -Be 1
    }

    It 'retains a before-version through reboot and retires it with its count in one checkpoint' {
        $instance = [pscustomobject]@{
            InstanceId='ssms-a'; InstallationPath='C:\SSMS22'; InstallationVersion=[version]'22.9.11519.84'
            ChannelId='SSMS.22.SSMS.Release'; ChannelUri='https://example.invalid/channel'
        }
        Save-SsmsPendingUpdate -Instance $instance
        $script:CurrentState = $script:CurrentState | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $instance.InstallationVersion = [version]'22.10.12210.168'
        $count = Confirm-SsmsPendingUpdate -Instance $instance
        $count | Should -Be 1
        $script:CurrentState.SsmsPendingUpdates.Count | Should -Be 1
        $script:CurrentState.Summary.Ssms += $count
        Complete-SsmsUpdateAccounting -State $script:CurrentState
        $script:CurrentState = $script:CurrentState | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $script:CurrentState.Summary.Ssms | Should -Be 1
        $script:CurrentState.SsmsPendingUpdates.Count | Should -Be 0
        Confirm-SsmsPendingUpdate -Instance $instance | Should -Be 0
    }

    It 'keeps a verified baseline until the dispatcher commits even if another instance starts' {
        $one = [pscustomobject]@{
            InstanceId='a'; InstallationPath='C:\SSMS-A'; InstallationVersion=[version]'22.9.11519.84'
            ChannelId='SSMS.22.SSMS.Release'; ChannelUri='https://example.invalid/channel'
        }
        $two = [pscustomobject]@{
            InstanceId='b'; InstallationPath='C:\SSMS-B'; InstallationVersion=[version]'22.9.11519.84'
            ChannelId='SSMS.22.SSMS.Release'; ChannelUri='https://example.invalid/channel'
        }
        Save-SsmsPendingUpdate -Instance $one
        $one.InstallationVersion = [version]'22.10.12210.168'
        Confirm-SsmsPendingUpdate -Instance $one | Should -Be 1
        Save-SsmsPendingUpdate -Instance $two
        # Simulate a kill after the second intent checkpoint, before phase Count commits.
        $script:CurrentState = $script:CurrentState | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $script:CurrentState.Summary.Ssms | Should -Be 0
        Confirm-SsmsPendingUpdate -Instance $one | Should -Be 1
        $script:CurrentState.Summary.Ssms += 1
        Complete-SsmsUpdateAccounting -State $script:CurrentState
        $script:CurrentState.SsmsPendingUpdates.Count | Should -Be 1
        $script:CurrentState.SsmsPendingUpdates[0].InstanceId | Should -Be 'b'
    }

    It 'withholds pending verification when the configured source changes' {
        $instance = [pscustomobject]@{
            InstanceId='a'; InstallationPath='C:\SSMS-A'; InstallationVersion=[version]'22.9.11519.84'
            ChannelId='SSMS.22.SSMS.Release'; ChannelUri='https://example.invalid/Original'
        }
        Save-SsmsPendingUpdate -Instance $instance
        $instance.ChannelUri = 'https://example.invalid/original'
        { Get-SsmsPendingUpdate -Instance $instance } | Should -Throw '*identity or source changed*'
    }

    It 'retains a previously verified baseline when the next invocation fails before inventory verification' {
        $instance = [pscustomobject]@{
            InstanceId='a'; InstallationPath='C:\SSMS-A'; InstallationVersion=[version]'22.9.11519.84'
            ChannelId='SSMS.22.SSMS.Release'; ChannelUri='https://example.invalid/channel'
        }
        Save-SsmsPendingUpdate -Instance $instance
        $instance.InstallationVersion = [version]'22.10.12210.168'
        Confirm-SsmsPendingUpdate -Instance $instance | Should -Be 1
        $script:CurrentState = $script:CurrentState | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        Reset-SsmsPendingVerification
        # This pass returns Count=0 on discovery failure; dispatcher still commits.
        Complete-SsmsUpdateAccounting -State $script:CurrentState
        $script:CurrentState.SsmsPendingUpdates.Count | Should -Be 1
        $script:CurrentState.Summary.Ssms | Should -Be 0
        Confirm-SsmsPendingUpdate -Instance $instance | Should -Be 1
    }
}

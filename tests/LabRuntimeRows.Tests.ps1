Describe 'PowerShell runtime lab row definitions' {
    BeforeAll {
        $labRoot = Join-Path $PSScriptRoot 'integration\lab'
        . (Join-Path $labRoot 'PowerShellRuntimeRows.ps1')
    }

    It 'defines Row A to remove the MSI through upd bootstrap and verify the continuation alias' {
        $row = Get-PowerShellRuntimeLabRow -Row A

        $row.Launcher | Should -Be 'upd'
        $row.PrepareAction.ToString() | Should -Match 'bootstrap'
        $row.PrepareAction.ToString() | Should -Match 'MsiEntriesRemaining'
        $row.InjectAction.ToString() | Should -Match 'WindowsApps'
    }

    It 'defines Row B to keep Terminal open across removal and verify its restarted profile' {
        $row = Get-PowerShellRuntimeLabRow -Row B

        $row.PrepareAction.ToString() | Should -Match 'Register-ScheduledTask -TaskName ''Lab-Terminal-Launch'''
        $row.PrepareAction.ToString() | Should -Match 'Stop-Process -Name WindowsTerminal'
        $row.PrepareAction.ToString() | Should -Match 'ChildPath'
        $row.PrepareAction.ToString() | Should -Match '7958c974571f795a42f387c59fb6bb0178e9d29e95d8398abeb496a3fbf6cd0c'
        $row.PrepareAction.ToString() | Should -Match 'Lab-InstallWindowsTerminal'
    }

    It 'defines Row C to preserve a stored-password task and report its replacement path' {
        $row = Get-PowerShellRuntimeLabRow -Row C

        $row.PrepareAction.ToString() | Should -Match 'Register-ScheduledTask.*-Password \$Password'
        $row.PrepareAction.ToString() | Should -Match 'StoredPasswordTaskUnchanged'
        $row.PrepareAction.ToString() | Should -Match 'StatusReportsReplacement'
    }

    It 'defines Row D with SYSTEM setup and a post-upgrade launch proof' {
        $row = Get-PowerShellRuntimeLabRow -Row D

        $row.VMName | Should -Be 'lab-b'
        $row.Checkpoint | Should -Be 'baseline-no-autologon'
        $row.SystemContext | Should -BeTrue
        $row.PrepareAction | Should -Not -BeNullOrEmpty
        $row.InjectWhen | Should -Match 'PowerShell runtime: checking'
        $row.InjectAction | Should -Not -BeNullOrEmpty
        $row.InjectAction.ToString() | Should -Match 'Start-ScheduledTask'
        $row.InjectAction.ToString() | Should -Match 'TaskLaunchVersion'
    }

    It 'defines Row E with an outside upgrade before upd startup repair' {
        $row = Get-PowerShellRuntimeLabRow -Row E

        $row.VMName | Should -Be 'lab-b'
        $row.Checkpoint | Should -Be 'baseline-clean'
        $row.Launcher | Should -Be 'upd'
        $row.DeployArgs | Should -Be 'run --no-update'
        $row.PrepareAction | Should -Not -BeNullOrEmpty
        $row.PrepareAction.ToString() | Should -Match 'Add-AppxPackage -Path \$newBundle'
        $row.InjectWhen | Should -Match 'BOOT UPDATE CYCLE STARTED'
        $row.InjectAction.ToString() | Should -Match 'did not repoint the SYSTEM task'
    }

    It 'pins both lab package downloads to release SHA256 digests' {
        $source = Get-Content (Join-Path $PSScriptRoot 'integration\lab\PowerShellRuntimeRows.ps1') -Raw

        $source | Should -Match '911e652739e19de80c325fd0cbcc99b00c865536299ed5813844a4083a6d0268'
        $source | Should -Match 'e00c349858c2d273f29485541ece91617b435accdd5e3f156d68d5cb97740022'
    }
}

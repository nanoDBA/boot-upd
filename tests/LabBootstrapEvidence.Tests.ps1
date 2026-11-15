BeforeAll {
    $harnessPath = Join-Path $PSScriptRoot 'integration/lab/Invoke-LabRow.ps1'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($harnessPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Lab harness must parse before extracting bootstrap evidence logic.' }
    $script:bootstrapEvidenceFunction = $ast.Find({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Test-LabBootstrapEvidence'
    }, $true)
    $script:probeOutputFunction = $ast.Find({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'ConvertFrom-LabPwshProbeOutput'
    }, $true)
    if ($script:bootstrapEvidenceFunction) {
        . ([scriptblock]::Create($script:bootstrapEvidenceFunction.Extent.Text))
    }
    if ($script:probeOutputFunction) {
        . ([scriptblock]::Create($script:probeOutputFunction.Extent.Text))
    }
}

Describe 'PowerShell launch probe output' {
    It 'reads version and install folder from separate command output lines' {
        $script:probeOutputFunction | Should -Not -BeNullOrEmpty
        $probe = ConvertFrom-LabPwshProbeOutput -ExitCode 0 -Output @(
            '7.7.0'
            'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.7.0.0_x64__8wekyb3d8bbwe'
        )
        $probe.Success | Should -BeTrue
        $probe.Version | Should -Be '7.7.0'
        $probe.PSHome | Should -Be 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.7.0.0_x64__8wekyb3d8bbwe'
    }

    It 'keeps the error output when the runtime exits unsuccessfully' {
        $probe = ConvertFrom-LabPwshProbeOutput -ExitCode 1 -Output @('ParserError: invalid command')
        $probe.Success | Should -BeFalse
        $probe.ExitCode | Should -Be 1
        $probe.Output | Should -Contain 'ParserError: invalid command'
    }
}

Describe 'Bootstrap-only lab evidence' {
    BeforeEach {
        $before = [pscustomobject]@{
            MsiVersion = '7.6.10.0'
            MsixVersion = $null
        }
        $after = [pscustomobject]@{
            MsiVersion = '7.6.10.0'
            MsixVersion = '7.7.0.0'
            MsiFolder = 'C:\Program Files\PowerShell\7'
            MsixFolder = 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.7.0.0_x64__8wekyb3d8bbwe'
            MsiPwshLaunch = [pscustomobject]@{ Success=$true; Version='7.6.10'; PSHome='C:\Program Files\PowerShell\7' }
            MsixPwshLaunch = [pscustomobject]@{ Success=$true; Version='7.7.0'; PSHome='C:\Program Files\WindowsApps\Microsoft.PowerShell_7.7.0.0_x64__8wekyb3d8bbwe' }
        }
    }

    It 'passes when the MSI remains, the MSIX is installed, both runtimes launch from their own folders, and no reboot occurred' {
        $script:bootstrapEvidenceFunction | Should -Not -BeNullOrEmpty
        Test-LabBootstrapEvidence -Before $before -After $after -UpgradeCompleted $true -BootChanged $false -CycleStarted $false |
            Should -BeTrue
    }

    It 'fails if the MSI was removed or changed' {
        $after.MsiVersion = $null
        Test-LabBootstrapEvidence -Before $before -After $after -UpgradeCompleted $true -BootChanged $false -CycleStarted $false |
            Should -BeFalse
    }

    It 'fails if the MSIX was already present before bootstrap' {
        $before.MsixVersion = '7.7.0.0'
        Test-LabBootstrapEvidence -Before $before -After $after -UpgradeCompleted $true -BootChanged $false -CycleStarted $false |
            Should -BeFalse
    }

    It 'fails when either runtime did not start from its install folder' {
        $after.MsixPwshLaunch.PSHome = 'C:\Program Files\PowerShell\7'
        Test-LabBootstrapEvidence -Before $before -After $after -UpgradeCompleted $true -BootChanged $false -CycleStarted $false |
            Should -BeFalse
    }

    It 'fails if the bootstrap upgrade did not finish, a reboot occurred, or a cycle started' {
        Test-LabBootstrapEvidence -Before $before -After $after -UpgradeCompleted $false -BootChanged $false -CycleStarted $false |
            Should -BeFalse
        Test-LabBootstrapEvidence -Before $before -After $after -UpgradeCompleted $true -BootChanged $true -CycleStarted $false |
            Should -BeFalse
        Test-LabBootstrapEvidence -Before $before -After $after -UpgradeCompleted $true -BootChanged $false -CycleStarted $true |
            Should -BeFalse
    }
}

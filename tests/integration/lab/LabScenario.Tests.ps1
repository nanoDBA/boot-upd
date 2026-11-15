BeforeAll {
    . (Join-Path $PSScriptRoot 'LabScenario.ps1')
    $repoRoot = $PSScriptRoot
    1..3 | ForEach-Object { $repoRoot = Split-Path -Parent $repoRoot }
    $sourcePath = Join-Path $repoRoot 'Invoke-BootUpdateCycle.ps1'
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
    if ($errors) { throw ($errors -join [Environment]::NewLine) }
    $parser = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-WingetInventoryPackageIds' }, $true)
    if (-not $parser) { throw 'Production Winget inventory parser is missing.' }
    . ([scriptblock]::Create($parser.Extent.Text))
}

Describe 'Lab scenario contracts' {
    It 'limits the hard-timeout scenario to one pass with a fake Winget command' {
        $scenario = Get-LabScenarioContract -Scenario HardTimeout

        $scenario.Mode | Should -Be 'hang'
        $scenario.RepeatCycles | Should -Be 1
        $scenario.WingetPath | Should -Be 'C:\Lab\boot-upd\tests\integration\lab\fixtures\bin'
        $scenario.ModulePath | Should -Be 'C:\Lab\boot-upd\tests\integration\lab\fixtures\modules'
    }

    It 'runs two repeated-failure cycles with Windows Update stubbed by a test module' {
        $scenario = Get-LabScenarioContract -Scenario RepeatedWingetFailure

        $scenario.Mode | Should -Be 'repeat-failure'
        $scenario.RepeatCycles | Should -Be 2
        $scenario.ModulePath | Should -Be 'C:\Lab\boot-upd\tests\integration\lab\fixtures\modules'
    }

    It 'adds scenario overrides only to the lab task process' {
        $scenario = Get-LabScenarioContract -Scenario RepeatedWingetFailure
        $prefix = Get-LabScenarioEnvironmentPrefix -Scenario $scenario

        $prefix | Should -Match 'BOOTUPD_LAB_WINGET_MODE'
        $prefix | Should -Match 'PSModulePath'
        $prefix | Should -Match 'PATH'
    }

    It 'starts exactly the next cycle after one completed failure cycle and then completes at two' {
        Get-LabScenarioCycleAction -Completed 0 -Started 1 -Expected 2 | Should -Be 'Wait'
        Get-LabScenarioCycleAction -Completed 1 -Started 1 -Expected 2 | Should -Be 'StartNext'
        Get-LabScenarioCycleAction -Completed 1 -Started 2 -Expected 2 | Should -Be 'Wait'
        Get-LabScenarioCycleAction -Completed 2 -Started 2 -Expected 2 | Should -Be 'Complete'
    }

    It 'parses the fake Winget fixture inventory with the production parser' {
        $header = '{0,-20}{1,-19}{2,-8}{3,-10}{4}' -f 'Name','Id','Version','Available','Source'
        $row = '{0,-20}{1,-19}{2,-8}{3,-10}{4}' -f 'BootUpd Test','BootUpd.TestFixture','1.0','2.0','winget'
        $inventory = Get-WingetInventoryPackageIds -Lines @($header,'--------------------------------------------------------------',$row)

        $inventory.HeaderRecognized | Should -BeTrue
        $inventory.PackageIds | Should -Contain 'BootUpd.TestFixture'
        $inventory.PackageRecords[0].AvailableVersion | Should -Be '2.0'
    }

    It 'runs the fake provider only in its repeat-failure mode and returns a fixed installer code' {
        $scriptPath = Join-Path $PSScriptRoot 'fixtures/bin/winget-fixture.ps1'
        $logPath = Join-Path $TestDrive 'winget-fixture.jsonl'
        $oldMode = $env:BOOTUPD_LAB_WINGET_MODE
        $oldLog = $env:BOOTUPD_LAB_FIXTURE_LOG
        try {
            $env:BOOTUPD_LAB_WINGET_MODE = 'repeat-failure'
            $env:BOOTUPD_LAB_FIXTURE_LOG = $logPath
            $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
            $inventoryLines = @(& $pwsh -NoProfile -File $scriptPath list --upgrade-available --scope machine 2>&1)
            $inventoryExitCode = $LASTEXITCODE
            $inventoryExitCode | Should -Be 0
            (Get-WingetInventoryPackageIds -Lines $inventoryLines).PackageIds | Should -Contain 'BootUpd.TestFixture'

            $failureLines = @(& $pwsh -NoProfile -File $scriptPath upgrade --all --scope machine 2>&1)
            $failureExitCode = $LASTEXITCODE
            $failureExitCode | Should -Be 1603
            $failureLines | Should -Contain 'Installer failed with exit code: 1603'
            @(Get-Content -LiteralPath $logPath).Count | Should -Be 2
        } finally {
            if ($null -eq $oldMode) { Remove-Item Env:BOOTUPD_LAB_WINGET_MODE -ErrorAction SilentlyContinue } else { $env:BOOTUPD_LAB_WINGET_MODE = $oldMode }
            if ($null -eq $oldLog) { Remove-Item Env:BOOTUPD_LAB_FIXTURE_LOG -ErrorAction SilentlyContinue } else { $env:BOOTUPD_LAB_FIXTURE_LOG = $oldLog }
        }
    }

    It 'provides a no-op Windows Update module for the isolated repeat-failure scenario' {
        $manifest = Join-Path $PSScriptRoot 'fixtures/modules/PSWindowsUpdate/99.0.0/PSWindowsUpdate.psd1'
        $oldLog = $env:BOOTUPD_LAB_FIXTURE_LOG
        $env:BOOTUPD_LAB_FIXTURE_LOG = Join-Path $TestDrive 'windows-update-fixture.jsonl'
        $module = Import-Module $manifest -Force -PassThru
        try {
            @(Get-WindowsUpdate -AcceptAll -Download).Count | Should -Be 0
            (Get-Content -LiteralPath $env:BOOTUPD_LAB_FIXTURE_LOG -Raw | ConvertFrom-Json).Provider | Should -Be 'WindowsUpdate'
        } finally {
            Remove-Module $module.Name -Force
            if ($null -eq $oldLog) { Remove-Item Env:BOOTUPD_LAB_FIXTURE_LOG -ErrorAction SilentlyContinue } else { $env:BOOTUPD_LAB_FIXTURE_LOG = $oldLog }
        }
    }
}

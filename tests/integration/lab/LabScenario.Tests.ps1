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
    It 'parses every PowerShell file used by the lab scenario harness' {
        $paths = @(
            (Join-Path $PSScriptRoot 'Invoke-LabRow.ps1'),
            (Join-Path $PSScriptRoot 'LabScenario.ps1'),
            (Join-Path $PSScriptRoot 'fixtures/bin/npm-fixture.ps1'),
            (Join-Path $PSScriptRoot 'fixtures/bin/winget-fixture.ps1')
        )
        foreach ($path in $paths) {
            $tokens = $null
            $errors = $null
            [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
            $errors | Should -BeNullOrEmpty -Because $path
        }
    }

    It 'persists fixture mode, evidence path, and Winget PATH in the guest machine environment for continuations' {
        $harness = Get-Content (Join-Path $PSScriptRoot 'Invoke-LabRow.ps1') -Raw

        $harness | Should -Match 'SetEnvironmentVariable\(''BOOTUPD_LAB_WINGET_MODE''.*?''Machine''\)'
        $harness | Should -Match 'SetEnvironmentVariable\(''BOOTUPD_LAB_FIXTURE_LOG''.*?''Machine''\)'
        $harness | Should -Match 'SetEnvironmentVariable\(''Path''.*?''Machine''\)'
        $harness | Should -Match '(?s)\$FixturePath.*\$machinePath'
        $harness | Should -Match 'PackageTimeoutMinutes 1 -SkipWindowsUpdate'
    }

    It 'limits the hard-timeout scenario to one pass with a fake Winget command' {
        $scenario = Get-LabScenarioContract -Scenario HardTimeout

        $scenario.Mode | Should -Be 'hang'
        $scenario.RepeatCycles | Should -Be 1
        $scenario.WingetPath | Should -Be 'C:\Lab\boot-upd\tests\integration\lab\fixtures\bin'
        $scenario.ModulePath | Should -Be 'C:\Lab\boot-upd\tests\integration\lab\fixtures\modules'
        $scenario.WindowsUpdateModuleTarget | Should -Be 'C:\Program Files\WindowsPowerShell\Modules\PSWindowsUpdate\99.0.0'
    }

    It 'runs three repeated-failure cycles with Windows Update stubbed by a test module' {
        $scenario = Get-LabScenarioContract -Scenario RepeatedWingetFailure

        $scenario.Mode | Should -Be 'repeat-failure'
        $scenario.Version | Should -Be '2.0'
        $scenario.RepeatCycles | Should -Be 3
        $scenario.ModulePath | Should -Be 'C:\Lab\boot-upd\tests\integration\lab\fixtures\modules'
    }

    It 'keeps the failed offer unchanged for cycle two and changes to a successful newer offer for cycle three' {
        $scenario = Get-LabScenarioContract -Scenario RepeatedWingetFailure
        $first = Get-LabScenarioCycleFixture -Scenario $scenario -CycleNumber 1
        $second = Get-LabScenarioCycleFixture -Scenario $scenario -CycleNumber 2
        $third = Get-LabScenarioCycleFixture -Scenario $scenario -CycleNumber 3

        $first.Mode | Should -Be 'repeat-failure'
        $second.Mode | Should -Be $first.Mode
        $second.Version | Should -Be $first.Version
        $third.Mode | Should -Be 'success'
        $third.Version | Should -Be '3.0'
    }

    It 'adds scenario overrides only to the lab task process' {
        $scenario = Get-LabScenarioContract -Scenario RepeatedWingetFailure
        $prefix = Get-LabScenarioEnvironmentPrefix -Scenario $scenario

        $prefix | Should -Match 'GetEnvironmentVariable\("BOOTUPD_LAB_WINGET_MODE","Machine"\)'
        $prefix | Should -Match 'GetEnvironmentVariable\("BOOTUPD_LAB_WINGET_VERSION","Machine"\)'
        $prefix | Should -Match 'GetEnvironmentVariable\("BOOTUPD_LAB_FIXTURE_PATH","Machine"\)'
        $prefix | Should -Match 'PSModulePath'
    }

    It 'defines a guest-only npm fixture for the SYSTEM-to-user row' {
        $scenario = Get-LabScenarioContract -Scenario SystemNpm
        $prefix = Get-LabScenarioEnvironmentPrefix -Scenario $scenario
        $harness = Get-Content (Join-Path $PSScriptRoot 'Invoke-LabRow.ps1') -Raw

        $scenario.NpmPath | Should -Be 'C:\Lab\boot-upd\tests\integration\lab\fixtures\bin'
        $scenario.NpmEvidenceFile | Should -Be 'C:\ProgramData\BootUpdateCycle\LabNpmFixture.jsonl'
        $prefix | Should -Match 'GetEnvironmentVariable\("BOOTUPD_LAB_NPM_FIXTURE_LOG","Machine"\)'
        $prefix | Should -Match 'GetEnvironmentVariable\("BOOTUPD_LAB_FIXTURE_PATH","Machine"\)'
        $harness | Should -Match 'SetEnvironmentVariable\(''BOOTUPD_LAB_NPM_FIXTURE_LOG''.*?''Machine''\)'
        $harness | Should -Match 'LabNpmFixture'
        $harness | Should -Match 'NpmFixtureRuns'
        $harness | Should -Match 'NpmFixtureContexts'
        $harness | Should -Match 'npm-fixture-summary.json'
    }

    It 'records the fake npm caller and arguments and exits successfully' {
        $npmCommand = Join-Path $PSScriptRoot 'fixtures/bin/npm.cmd'
        $logPath = Join-Path $TestDrive 'npm-fixture.jsonl'
        $oldLog = $env:BOOTUPD_LAB_NPM_FIXTURE_LOG
        try {
            $env:BOOTUPD_LAB_NPM_FIXTURE_LOG = $logPath
            & $npmCommand outdated -g --json | Out-Null
            $LASTEXITCODE | Should -Be 0
            $records = @(Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json })
            $records.Count | Should -Be 1
            $records[0].Identity | Should -Be ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
            $records[0].Arguments | Should -Be @('outdated','-g','--json')
        } finally {
            if ($null -eq $oldLog) { Remove-Item Env:BOOTUPD_LAB_NPM_FIXTURE_LOG -ErrorAction SilentlyContinue } else { $env:BOOTUPD_LAB_NPM_FIXTURE_LOG = $oldLog }
        }
    }

    It 'starts exactly the next cycle after one completed failure cycle and then completes at two' {
        Get-LabScenarioCycleAction -Completed 0 -Started 1 -Expected 2 | Should -Be 'Wait'
        Get-LabScenarioCycleAction -Completed 1 -Started 1 -Expected 2 | Should -Be 'StartNext'
        Get-LabScenarioCycleAction -Completed 1 -Started 2 -Expected 2 | Should -Be 'Wait'
        Get-LabScenarioCycleAction -Completed 2 -Started 2 -Expected 2 | Should -Be 'Complete'
    }

    It 'starts a fresh cycle after manual attention and advances through all three fixture cycles' {
        Get-LabScenarioCycleAction -Completed 0 -ManualAttentionCount 1 -Started 1 -Expected 3 | Should -Be 'StartNext'
        Get-LabScenarioCycleAction -Completed 0 -ManualAttentionCount 1 -Started 2 -Expected 3 | Should -Be 'Wait'
        Get-LabScenarioCycleAction -Completed 1 -ManualAttentionCount 1 -Started 2 -Expected 3 | Should -Be 'StartNext'
        Get-LabScenarioCycleAction -Completed 1 -ManualAttentionCount 1 -Started 3 -Expected 3 | Should -Be 'Wait'
        Get-LabScenarioCycleAction -Completed 3 -ManualAttentionCount 1 -Started 3 -Expected 3 | Should -Be 'Complete'
    }

    It 'recognizes the updater known-failure manual-attention log line' {
        Test-LabManualAttentionEvidence -Lines @('[Error] Persistent non-transient failure requires manual attention: Winget') |
            Should -BeTrue
        Test-LabManualAttentionEvidence -Lines @('[Info] Winget: one automatic verification pass remains; manual commands are withheld unless the same failure repeats.') |
            Should -BeFalse
    }

    It 'counts a manual stop as a settled row cycle and still requires the final cycle to complete' {
        $harness = Get-Content (Join-Path $PSScriptRoot 'Invoke-LabRow.ps1') -Raw
        $harness | Should -Match 'manualAttentionCount = @\(\$evidence\.Log'
        $harness | Should -Match 'Get-LabScenarioCycleAction -Completed \$completedScenarioCycles'
        $harness | Should -Match 'if \(\$r\.ManualAttention -ge 1 -and \$r\.Tasks -eq 0 -and \$LabScenario -ne ''RepeatedWingetFailure''\)'
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

    It 'installs the changed fixture offer successfully and removes it from upgrade inventory' {
        $scriptPath = Join-Path $PSScriptRoot 'fixtures/bin/winget-fixture.ps1'
        $logPath = Join-Path $TestDrive 'winget-fixture-success.jsonl'
        $oldMode = $env:BOOTUPD_LAB_WINGET_MODE
        $oldVersion = $env:BOOTUPD_LAB_WINGET_VERSION
        $oldLog = $env:BOOTUPD_LAB_FIXTURE_LOG
        try {
            $env:BOOTUPD_LAB_WINGET_MODE = 'success'
            $env:BOOTUPD_LAB_WINGET_VERSION = '3.0'
            $env:BOOTUPD_LAB_FIXTURE_LOG = $logPath
            $pwsh = (Get-Command pwsh -ErrorAction Stop).Source

            $beforeLines = @(& $pwsh -NoProfile -File $scriptPath list --upgrade-available --scope machine 2>&1)
            $LASTEXITCODE | Should -Be 0
            (Get-WingetInventoryPackageIds -Lines $beforeLines).PackageRecords[0].AvailableVersion | Should -Be '3.0'

            $installLines = @(& $pwsh -NoProfile -File $scriptPath upgrade --all --scope machine 2>&1)
            $LASTEXITCODE | Should -Be 0
            $installLines | Should -Contain 'Successfully installed BootUpd Test Fixture [BootUpd.TestFixture] Version 3.0'

            $afterLines = @(& $pwsh -NoProfile -File $scriptPath list --upgrade-available --scope machine 2>&1)
            $LASTEXITCODE | Should -Be 0
            (Get-WingetInventoryPackageIds -Lines $afterLines).PackageIds | Should -Not -Contain 'BootUpd.TestFixture'
            $records = @(Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json })
            $records.Version | Should -Be @('3.0','3.0','3.0')
            $records[1].Arguments | Should -Be @('upgrade','--all','--scope','machine')
        } finally {
            if ($null -eq $oldMode) { Remove-Item Env:BOOTUPD_LAB_WINGET_MODE -ErrorAction SilentlyContinue } else { $env:BOOTUPD_LAB_WINGET_MODE = $oldMode }
            if ($null -eq $oldVersion) { Remove-Item Env:BOOTUPD_LAB_WINGET_VERSION -ErrorAction SilentlyContinue } else { $env:BOOTUPD_LAB_WINGET_VERSION = $oldVersion }
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
            @(Get-WindowsUpdate -AcceptAll -Install -Confirm:$false).Count | Should -Be 0
            $records = @(Get-Content -LiteralPath $env:BOOTUPD_LAB_FIXTURE_LOG | ForEach-Object { $_ | ConvertFrom-Json })
            $records.Provider | Should -Be @('WindowsUpdate', 'WindowsUpdate')
            $records.Install | Should -Be @($false, $true)
        } finally {
            Remove-Module $module.Name -Force
            if ($null -eq $oldLog) { Remove-Item Env:BOOTUPD_LAB_FIXTURE_LOG -ErrorAction SilentlyContinue } else { $env:BOOTUPD_LAB_FIXTURE_LOG = $oldLog }
        }
    }
}

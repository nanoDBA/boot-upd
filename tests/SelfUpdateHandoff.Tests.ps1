BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $scriptPath = Join-Path $repoRoot 'Invoke-BootUpdateCycle.ps1'
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    $parseErrors | Should -BeNullOrEmpty

    function Get-ProductionFunctionText {
        param([Parameter(Mandatory)][string]$Name)

        $functionAst = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $Name
        }, $true)
        $functionAst | Should -Not -BeNullOrEmpty -Because "production function '$Name' must exist"
        return $functionAst.Extent.Text
    }

    . ([scriptblock]::Create((Get-ProductionFunctionText -Name 'Test-SelfUpdateHandoff')))

    $markerName = 'BOOT_UPDATE_SELF_UPDATE_HANDOFF'
    $originalMarker = [Environment]::GetEnvironmentVariable($markerName, 'Process')
}

AfterAll {
    [Environment]::SetEnvironmentVariable($markerName, $originalMarker, 'Process')
}

Describe 'Test-SelfUpdateHandoff' {
    BeforeEach {
        [Environment]::SetEnvironmentVariable($markerName, $null, 'Process')
        $script:MockThisParentPid = 4242
        $script:MockParentName = 'pwsh.exe'
        $script:MockParentCommandLine =
            'pwsh -NoProfile -File C:\ProgramData\BootUpdateCycle\Invoke-BootUpdateCycle.ps1'

        Mock Get-CimInstance {
            if ($Filter -eq "ProcessId=$PID") {
                return [pscustomobject]@{ ParentProcessId = $script:MockThisParentPid }
            }
            return [pscustomobject]@{
                Name = $script:MockParentName
                CommandLine = $script:MockParentCommandLine
            }
        }
    }

    It 'accepts and consumes a nonced capability inherited from the actual updater parent' {
        [Environment]::SetEnvironmentVariable(
            $markerName,
            'v1:4242:0123456789abcdef0123456789abcdef',
            'Process'
        )

        Test-SelfUpdateHandoff | Should -BeTrue
        [Environment]::GetEnvironmentVariable($markerName, 'Process') | Should -BeNullOrEmpty
    }

    It 'rejects an ordinary invocation with no handoff capability' {
        Test-SelfUpdateHandoff | Should -BeFalse
    }

    It 'rejects and consumes a malformed nonce' {
        [Environment]::SetEnvironmentVariable($markerName, 'v1:4242:not-a-nonce', 'Process')

        Test-SelfUpdateHandoff | Should -BeFalse
        [Environment]::GetEnvironmentVariable($markerName, 'Process') | Should -BeNullOrEmpty
    }

    It 'rejects a marker naming a process other than the actual parent' {
        [Environment]::SetEnvironmentVariable(
            $markerName,
            'v1:9999:0123456789abcdef0123456789abcdef',
            'Process'
        )

        Test-SelfUpdateHandoff | Should -BeFalse
    }

    It 'rejects a non-pwsh parent' {
        $script:MockParentName = 'cmd.exe'
        [Environment]::SetEnvironmentVariable(
            $markerName,
            'v1:4242:0123456789abcdef0123456789abcdef',
            'Process'
        )

        Test-SelfUpdateHandoff | Should -BeFalse
    }

    It 'rejects pwsh when its parent command line is not the updater' {
        $script:MockParentCommandLine = 'pwsh -NoProfile'
        [Environment]::SetEnvironmentVariable(
            $markerName,
            'v1:4242:0123456789abcdef0123456789abcdef',
            'Process'
        )

        Test-SelfUpdateHandoff | Should -BeFalse
    }

    It 'fails closed when process inspection fails' {
        Mock Get-CimInstance { throw 'mock CIM failure' }
        [Environment]::SetEnvironmentVariable(
            $markerName,
            'v1:4242:0123456789abcdef0123456789abcdef',
            'Process'
        )

        Test-SelfUpdateHandoff | Should -BeFalse
    }
}

Describe 'Test-LegacySelfUpdateHandoff compatibility' {
    BeforeAll {
        $legacyText = Get-ProductionFunctionText -Name 'Test-LegacySelfUpdateHandoff'
    }

    It 'retains the complete pre-2.5.17 parent and replacement validation heuristic' {
        $legacyText | Should -Match 'Test-Path -LiteralPath \$bakPath'
        $legacyText | Should -Match "parentProcess\.Name -notin @\('pwsh\.exe', 'pwsh'\)"
        $legacyText | Should -Match 'LastWriteTimeUtc -lt \[datetime\]::UtcNow\.AddMinutes\(-5\)'
        $legacyText | Should -Match 'liveVersion -gt \$bakVersion'
    }

    It 'remains the fallback after authenticated handoff validation' {
        $source = Get-Content -LiteralPath $scriptPath -Raw
        $source | Should -Match (
            '(?s)if \(Test-SelfUpdateHandoff\).*?elseif \(Test-LegacySelfUpdateHandoff\)'
        )
    }
}

Describe 'Update-OrchestratorSelf mutex handoff structure' {
    BeforeAll {
        $source = Get-Content -LiteralPath $scriptPath -Raw
        $updateSelfText = Get-ProductionFunctionText -Name 'Update-OrchestratorSelf'
    }

    It 'evaluates authenticated handoff before the legacy compatibility heuristic' {
        $source | Should -Match (
            '(?s)if \(Test-SelfUpdateHandoff\).*?elseif \(Test-LegacySelfUpdateHandoff\)'
        )
    }

    It 'never releases the parent mutex before or while the replacement runs' {
        $updateSelfText | Should -Not -Match '\bRelease-BootUpdateMutex\b'
    }

    It 'waits synchronously for the child before restoring the handoff environment' {
        $updateSelfText | Should -Match (
            '(?s)SetEnvironmentVariable\(\$handoffName, \$handoffMarker, ''Process''\)' +
            '.*?& pwsh -NoProfile -File \$livePath @relaunchArgs.*?finally.*?' +
            'SetEnvironmentVariable\(\$handoffName, \$previousHandoff, ''Process''\)'
        )
    }
}

Describe 'Self-update mutex handoff process integration' -Skip:(-not $IsWindows) {
    BeforeAll {
        function Wait-TestPath {
            param(
                [Parameter(Mandatory)][string]$Path,
                [int]$TimeoutSeconds = 15
            )

            $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
            while ([datetime]::UtcNow -lt $deadline) {
                if (Test-Path -LiteralPath $Path) { return }
                Start-Sleep -Milliseconds 50
            }
            throw "Timed out waiting for '$Path'."
        }
        $integrationRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
            'BootUpdateMutex-' + [guid]::NewGuid().ToString('N')
        )
        $null = New-Item -ItemType Directory -Path $integrationRoot -Force

        $functionPath = Join-Path $integrationRoot 'HandoffFunctions.ps1'
        @(
            (Get-ProductionFunctionText -Name 'Test-SelfUpdateHandoff')
            (Get-ProductionFunctionText -Name 'Enter-BootUpdateMutex')
        ) -join "`r`n`r`n" | Set-Content -LiteralPath $functionPath -Encoding utf8

        <# Start-Process flattens ArgumentList without preserving quotes. Copy the
           fixtures to the space-free integration path so every argument arrives
           byte-for-byte even when the repository itself lives in Google Drive. #>
        $fixtureRoot = Join-Path $PSScriptRoot 'fixtures'
        $childPath = Join-Path $integrationRoot 'MutexHandoffChild.ps1'
        $parentPath = Join-Path $integrationRoot 'Invoke-BootUpdateCycle.ps1'
        Copy-Item -LiteralPath (Join-Path $fixtureRoot 'MutexHandoffChild.ps1') `
            -Destination $childPath -Force
        Copy-Item -LiteralPath (Join-Path $fixtureRoot 'Invoke-BootUpdateCycle.ps1') `
            -Destination $parentPath -Force
    }

    AfterAll {
        if (Test-Path -LiteralPath $integrationRoot) {
            Remove-Item -LiteralPath $integrationRoot -Recurse -Force
        }
    }

    It 'keeps parent ownership, admits only its replacement, and excludes an unrelated contender' {
        $mutexName = 'Global\BootUpdateCycle-Pester-' + [guid]::NewGuid().ToString('N')
        $readyPath = Join-Path $integrationRoot 'parent-ready.json'
        $goPath = Join-Path $integrationRoot 'launch-replacement.signal'
        $contenderResultPath = Join-Path $integrationRoot 'contender.json'
        $replacementResultPath = Join-Path $integrationRoot 'replacement.json'
        $parentErrorPath = Join-Path $integrationRoot 'parent-error.txt'

        $parent = Start-Process pwsh -PassThru -WindowStyle Hidden `
            -RedirectStandardError $parentErrorPath -ArgumentList @(
                '-NoProfile', '-File', $parentPath,
                '-MutexName', $mutexName,
                '-FunctionPath', $functionPath,
                '-ChildPath', $childPath,
                '-ReadyPath', $readyPath,
                '-GoPath', $goPath,
                '-ReplacementResultPath', $replacementResultPath
            )

        try {
            Wait-TestPath -Path $readyPath
            $owner = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
            $owner.OwnsMutex | Should -BeTrue
            $owner.ProcessId | Should -Be $parent.Id

            $contender = Start-Process pwsh -PassThru -Wait -WindowStyle Hidden -ArgumentList @(
                '-NoProfile', '-File', $childPath,
                '-MutexName', $mutexName,
                '-FunctionPath', $functionPath,
                '-ResultPath', $contenderResultPath
            )
            $contender.ExitCode | Should -Be 0
            $ordinary = Get-Content -LiteralPath $contenderResultPath -Raw | ConvertFrom-Json
            $ordinary.Granted | Should -BeFalse
            $ordinary.OwnsMutex | Should -BeFalse

            New-Item -ItemType File -Path $goPath -Force | Out-Null
            Wait-TestPath -Path $replacementResultPath
            $replacement = Get-Content -LiteralPath $replacementResultPath -Raw | ConvertFrom-Json
            $replacement.Granted | Should -BeTrue
            $replacement.OwnsMutex | Should -BeFalse
            $replacement.HandoffConsumed | Should -BeTrue

            $parent.WaitForExit(15000) | Should -BeTrue
            $parent.ExitCode | Should -Be 0 -Because (
                Get-Content -LiteralPath $parentErrorPath -Raw -ErrorAction SilentlyContinue
            )
        } finally {
            if (-not $parent.HasExited) { $parent.Kill() }
            $parent.Dispose()
        }
    }
}

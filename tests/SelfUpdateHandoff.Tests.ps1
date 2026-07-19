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

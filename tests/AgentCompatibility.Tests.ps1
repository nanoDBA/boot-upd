BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $claudePath = Join-Path $repoRoot 'CLAUDE.md'
    $settingsPath = Join-Path $repoRoot '.claude\settings.json'
    $skillsRoot = Join-Path $repoRoot '.claude\skills'
    $rulesRoot = Join-Path $repoRoot '.claude\rules'
}

Describe 'Claude Code project compatibility' {
    It 'imports the shared agent instructions instead of duplicating them' {
        $source = Get-Content $claudePath -Raw
        $source | Should -Match '(?m)^@AGENTS\.md\s*$'
        @($source -split '\r?\n').Count | Should -BeLessThan 200
        $source | Should -Not -Match 'upd\.cmd is intentionally NOT auto-updated'
    }

    It 'tracks shared settings while leaving machine-local settings ignored' {
        Test-Path $settingsPath | Should -BeTrue
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        @($settings.permissions.deny).Count | Should -BeGreaterOrEqual 1
        $gitignore = Get-Content (Join-Path $repoRoot '.gitignore') -Raw
        $gitignore | Should -Match '(?m)^\.claude/settings\.local\.json\r?$'
        $gitignore | Should -Not -Match '(?m)^\.claude/\r?$'
    }

    It 'denies common credential-file classes without pre-approving mutation commands' {
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        ($settings.permissions.deny -join "`n") | Should -Match 'Read\(\./\.env\)'
        ($settings.permissions.deny -join "`n") | Should -Match '\*\.pfx'
        $settings.permissions.PSObject.Properties.Name | Should -Not -Contain 'allow'
    }

    It 'publishes valid project skills for verification and lifecycle review' {
        $skillPaths = @(Get-ChildItem $skillsRoot -Filter SKILL.md -File -Recurse)
        $skillPaths.Count | Should -BeGreaterOrEqual 2
        $names = foreach ($path in $skillPaths) {
            $source = Get-Content $path.FullName -Raw
            $source | Should -Match '(?s)^---\r?\n.*?description:\s*.+?\r?\n.*?---\r?\n'
            if ($source -match '(?m)^name:\s*([^\r\n]+)') { $Matches[1].Trim() }
        }
        $names | Should -Contain 'test-gates'
        $names | Should -Contain 'reboot-resilience-review'
        $reviewSkill = Get-Content (Join-Path $skillsRoot 'reboot-resilience-review\SKILL.md') -Raw
        $reviewSkill | Should -Match '(?i)description:.*provider exit-code reconciliation'
        $reviewSkill | Should -Match '(?i)use after.*provider-parser'
    }

    It 'publishes path-scoped rules for updater, launcher, and public-repository work' {
        $rulePaths = @(Get-ChildItem $rulesRoot -Filter *.md -File -Recurse)
        $rulePaths.Count | Should -BeGreaterOrEqual 3
        foreach ($path in $rulePaths) {
            $source = Get-Content $path.FullName -Raw
            $source | Should -Match '(?s)^---\r?\npaths:\r?\n(?:\s+-\s+.+\r?\n)+---\r?\n'
        }

        $updaterRule = Get-Content (Join-Path $rulesRoot 'powershell-updater-safety.md') -Raw
        $launcherRule = Get-Content (Join-Path $rulesRoot 'batch-launcher-safety.md') -Raw
        $privacyRule = Get-Content (Join-Path $rulesRoot 'public-repository-privacy.md') -Raw
        $updaterRule | Should -Match 'Invoke-BootUpdateCycle\.ps1'
        $launcherRule | Should -Match '\*\.cmd'
        $launcherRule | Should -Match 'Repair-LineEndings\.ps1'
        $privacyRule | Should -Match '(?i)repository is public'
        $privacyRule | Should -Match '(?i)screenshots.*console transcripts.*sanitization'
    }

    It 'gives Claude and release gates an automatic batch-line-ending repair path' {
        $claude = Get-Content $claudePath -Raw
        $launcherRule = Get-Content (Join-Path $rulesRoot 'batch-launcher-safety.md') -Raw
        $testGate = Get-Content (Join-Path $repoRoot 'tools\Invoke-TestGates.ps1') -Raw
        $releaseGate = Get-Content (Join-Path $repoRoot 'tools\New-Release.ps1') -Raw
        Test-Path (Join-Path $repoRoot 'tools\Repair-LineEndings.ps1') | Should -BeTrue
        $claude | Should -Match '\.claude/rules/'
        $launcherRule | Should -Match 'Repair-LineEndings\.ps1'
        $testGate | Should -Match 'Repair-LineEndings\.ps1'
        $releaseGate | Should -Match 'Repair-LineEndings\.ps1'
    }

    It 'isolates the published-launcher gate from test-runner process state' {
        $testGate = Get-Content (Join-Path $repoRoot 'tools\Invoke-TestGates.ps1') -Raw
        $testGate | Should -Match 'Invoke-PublishedLauncherUpgradeGate\.ps1'
        $testGate | Should -Match '(?s)\$engine\s*=.*?-NoProfile\s+-NonInteractive\s+-File\s+\$gatePath'
        $testGate | Should -Match '\$gateExitCode\s*=\s*\$LASTEXITCODE'
    }

    It 'leaves Claude a durable Winget 1605 convergence breadcrumb' {
        $claude = Get-Content $claudePath -Raw
        $updaterRule = Get-Content (Join-Path $rulesRoot 'powershell-updater-safety.md') -Raw
        $reviewSkill = Get-Content (Join-Path $skillsRoot 'reboot-resilience-review\SKILL.md') -Raw
        foreach ($source in @($updaterRule, $reviewSkill)) {
            $source | Should -Match '1605'
            $source | Should -Match '0x8A15002C'
            $source | Should -Match '(?i)never.*(?:count|increment).*update'
        }
        $updaterRule | Should -Match 'RebootResilience\.Tests\.ps1'
        $claude | Should -Match '(?m)^@AGENTS\.md\s*$'
        $claude | Should -Match '/memory'
    }
}

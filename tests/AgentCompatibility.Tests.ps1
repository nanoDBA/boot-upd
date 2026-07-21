BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $claudePath = Join-Path $repoRoot 'CLAUDE.md'
    $settingsPath = Join-Path $repoRoot '.claude\settings.json'
    $skillsRoot = Join-Path $repoRoot '.claude\skills'
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
    }
}

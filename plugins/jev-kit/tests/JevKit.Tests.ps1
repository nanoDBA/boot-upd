# ------------------------------------------------------------------------------
# File:        JevKit.Tests.ps1
# Description: 🧪 Offline Pester checks for the jev-kit plugin
# Purpose:     Guards the parts that break silently: skill frontmatter, rubric
#              question limits, routing references, and the key-never-leaks
#              contract.  No network, no API key, no live calls.
# Created:     2026-09-24
# Modified:    2026-09-24
# ------------------------------------------------------------------------------

BeforeAll {
    $pluginRoot = Split-Path -Parent $PSScriptRoot
    $skillsRoot = Join-Path $pluginRoot 'skills'
    Import-Module (Join-Path $skillsRoot 'jev/scripts/JevClient.psm1') -Force
}

Describe 'jev-kit skills' {
    It 'ships valid frontmatter for <_>' -ForEach @('jev', 'jev-triage', 'jev-skill-router') {
        $source = Get-Content (Join-Path $skillsRoot "$_/SKILL.md") -Raw
        $source | Should -Match "(?s)\A---\r?\nname: $_\r?\ndescription: .{80,}?\r?\n---\r?\n"
    }

    It 'parses every script without syntax errors' {
        foreach ($file in Get-ChildItem $pluginRoot -Include *.ps1, *.psm1 -Recurse -File) {
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
            $errors | Should -BeNullOrEmpty -Because $file.Name
        }
    }

    It 'keeps plugin and marketplace manifests in sync' {
        $plugin = Get-Content (Join-Path $pluginRoot '.claude-plugin/plugin.json') -Raw | ConvertFrom-Json
        $market = Get-Content (Join-Path $pluginRoot '../../.claude-plugin/marketplace.json') -Raw | ConvertFrom-Json
        $entry = $market.plugins | Where-Object name -eq $plugin.name
        $entry | Should -Not -BeNullOrEmpty
        $entry.version | Should -Be $plugin.version
    }
}

Describe 'rubrics' {
    BeforeDiscovery { $rubrics = Get-ChildItem (Join-Path (Split-Path -Parent $PSScriptRoot) 'skills/jev-triage/rubrics') -Filter *.json }

    It '<_.Name> has valid questions and routes only to real questions' -ForEach $rubrics {
        $rubric = Get-Content $_.FullName -Raw | ConvertFrom-Json -AsHashtable
        Test-JevQuestionSet -Questions $rubric.questions | Should -BeNullOrEmpty
        $conditions = @($rubric.route.rules | ForEach-Object { @($_.when) }) + @($rubric.route.reviewWhen | Where-Object { $_ })
        foreach ($c in $conditions) {
            $rubric.questions.Keys | Should -Contain $c.question
            if ($c.Contains('choiceIn')) {
                foreach ($opt in $c.choiceIn) { $rubric.questions[$c.question].criteria.Keys | Should -Contain $opt }
            }
        }
    }
}

Describe 'Test-JevQuestionSet' {
    It 'rejects <Name>' -ForEach @(
        @{ Name = 'unknown type'; Q = @{ a = @{ type = 'text'; instructions = 'x' } } }
        @{ Name = 'missing instructions'; Q = @{ a = @{ type = 'noul' } } }
        @{ Name = 'one-level score'; Q = @{ a = @{ type = 'score'; instructions = 'x'; criteria = @('only') } } }
        @{ Name = 'eleven-level score'; Q = @{ a = @{ type = 'score'; instructions = 'x'; criteria = 1..11 } } }
        @{ Name = 'empty choice'; Q = @{ a = @{ type = 'choice'; instructions = 'x'; criteria = @{} } } }
        @{ Name = 'empty set'; Q = @{} }
    ) {
        Test-JevQuestionSet -Questions $Q | Should -Not -BeNullOrEmpty
    }
}

Describe 'Invoke-JevEvaluation' {
    It 'never puts the API key in an error message' {
        $env:TYPESAFE_API_KEY = 'sk-test-SENTINEL'
        try {
            { Invoke-JevEvaluation -State 'x' -Questions @{ a = @{ type = 'noul'; instructions = 'x' } } `
                -BaseUrl 'http://127.0.0.1:1' -MaxAttempts 1 -TimeoutSec 2 } |
                Should -Throw -ExpectedMessage '*transport*'
            try { Invoke-JevEvaluation -State 'x' -Questions @{ a = @{ type = 'noul'; instructions = 'x' } } -BaseUrl 'http://127.0.0.1:1' -MaxAttempts 1 -TimeoutSec 2 }
            catch { $_.Exception.Message | Should -Not -Match 'SENTINEL' }
        }
        finally { Remove-Item Env:TYPESAFE_API_KEY -ErrorAction SilentlyContinue }
    }

    It 'refuses empty state before spending a call' {
        { Invoke-JevEvaluation -State ' ' -Questions @{ a = @{ type = 'noul'; instructions = 'x' } } -ApiKey 'k' } |
            Should -Throw -ExpectedMessage '*empty*'
    }
}

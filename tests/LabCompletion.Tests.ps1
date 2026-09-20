BeforeAll {
    $path = Join-Path $PSScriptRoot 'integration/lab/Invoke-LabRow.ps1'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Lab harness must parse before extracting its completion predicate.' }
    $fn = $ast.Find({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Test-LabCompletionEvidence'
    }, $true)
    . ([scriptblock]::Create($fn.Extent.Text))
}

Describe 'Lab completion requires observed cleanup' {
    It 'keeps watching when task removal precedes state removal' {
        Test-LabCompletionEvidence -Passes 5 -CompletionRecords 1 -TasksRemaining 0 -StateFileExists $true |
            Should -BeFalse
    }

    It 'does not turn an empty clean machine into a completed run' {
        Test-LabCompletionEvidence -Passes 0 -CompletionRecords 0 -TasksRemaining 0 -StateFileExists $false |
            Should -BeFalse
    }

    It 'rejects remaining continuation tasks' {
        Test-LabCompletionEvidence -Passes 2 -CompletionRecords 1 -TasksRemaining 1 -StateFileExists $false |
            Should -BeFalse
    }

    It 'accepts a started and completed run only after both cleanup facts hold' {
        Test-LabCompletionEvidence -Passes 2 -CompletionRecords 1 -TasksRemaining 0 -StateFileExists $false |
            Should -BeTrue
    }

    It 'does not retain an earlier positive when the collected snapshot contradicts it' {
        $completed = Test-LabCompletionEvidence -Passes 2 -CompletionRecords 1 -TasksRemaining 0 -StateFileExists $false
        $completed | Should -BeTrue
        $completed = Test-LabCompletionEvidence -Passes 2 -CompletionRecords 1 -TasksRemaining 0 -StateFileExists $true
        $completed | Should -BeFalse
    }
}

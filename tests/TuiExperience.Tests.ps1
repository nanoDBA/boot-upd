BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $invokePath = Join-Path $repoRoot 'Invoke-BootUpdateCycle.ps1'
    $deployPath = Join-Path $repoRoot 'Deploy-BootUpdateCycle.ps1'

    function Get-ScriptAst {
        param([Parameter(Mandatory)][string]$Path)
        $tokens = $null
        $errors = $null
        $parsed = [Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref]$tokens, [ref]$errors
        )
        $errors | Should -BeNullOrEmpty
        return $parsed
    }

    function Get-FunctionText {
        param(
            [Parameter(Mandatory)]$Ast,
            [Parameter(Mandatory)][string]$Name
        )
        $function = $Ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $Name
        }, $true)
        $function | Should -Not -BeNullOrEmpty -Because "production function '$Name' must exist"
        return $function.Extent.Text
    }

    $invokeAst = Get-ScriptAst -Path $invokePath
    $deployAst = Get-ScriptAst -Path $deployPath
    $invokeSource = Get-Content -LiteralPath $invokePath -Raw
    $deploySource = Get-Content -LiteralPath $deployPath -Raw
}

Describe 'Concise output modes' {
    It 'defaults to Normal and exposes four validated modes' {
        $invokeSource | Should -Match "ValidateSet\('Quiet','Normal','Verbose','Debug'\)"
        $invokeSource | Should -Match '\[string\]\$OutputMode\s*=\s*''Normal'''
    }

    It 'always logs before filtering informational console output' {
        $text = Get-FunctionText -Ast $invokeAst -Name 'Write-Log'
        $text.IndexOf('Add-Content') | Should -BeLessThan $text.IndexOf("switch (`$Level)")
        $text | Should -Match 'Test-BootUpdateOutputAtLeast -Minimum \$Visibility'
        $text | Should -Match "(?s)'Warn'.*?Minimum Normal"
        $text | Should -Match "(?s)'Error'.*?Write-Host"
    }

    It 'preserves the splash in the default view and hides it only in Quiet mode' {
        $invokeSource | Should -Match 'Test-BootUpdateOutputAtLeast -Minimum Normal\) \{\s*Show-StartupArt'
        $invokeSource | Should -Match '\$PreviewSplash'
    }
}

Describe 'Interactive verbosity cycling' {
    It 'polls v without blocking and cycles the mode list' {
        $text = Get-FunctionText -Ast $invokeAst -Name 'Read-BootUpdateUiKeys'
        $text | Should -Match '\[Console\]::KeyAvailable'
        $text | Should -Match '\[Console\]::ReadKey\(\$true\)'
        $text | Should -Match "KeyChar -notin @\('v', 'V'\)"
        $text | Should -Match '% \$script:OutputModes.Count'
    }

    It 'disables key polling for SYSTEM and redirected consoles' {
        $text = Get-FunctionText -Ast $invokeAst -Name 'Initialize-BootUpdateConsole'
        $text | Should -Match "S-1-5-18"
        $text | Should -Match 'IsInputRedirected'
        $text | Should -Match 'IsOutputRedirected'
        $text | Should -Match "ConsoleHost"
    }
}

Describe 'Native progress rendering' {
    It 'uses minimal Write-Progress with spinner frames and no Spectre dependency' {
        $initialize = Get-FunctionText -Ast $invokeAst -Name 'Initialize-BootUpdateConsole'
        $progress = Get-FunctionText -Ast $invokeAst -Name 'Write-BootUpdateProgress'
        $initialize | Should -Match "Progress.View = 'Minimal'"
        $progress | Should -Match 'Write-Progress @progressArgs'
        $progress | Should -Match 'TuiSpinnerFrames'
        $invokeSource | Should -Not -Match 'Spectre\.Console'
    }

    It 'connects phase, monitored-process, and parallel-cohort progress' {
        (Get-FunctionText -Ast $invokeAst -Name 'Write-PhaseHeader') |
            Should -Match 'Write-BootUpdateProgress'
        (Get-FunctionText -Ast $invokeAst -Name 'Wait-ProcessWithIdleTimeout') |
            Should -Match 'Wait-BootUpdateUiInterval'
        $invokeSource | Should -Match "-Activity 'Parallel update cohort'"
    }

    It 'persists OutputMode through deployment and scheduled resumes' {
        $deploySource | Should -Match "OutputMode\s*=\s*'Normal'"
        $deploySource | Should -Match 'OutputMode\s*=\s*\$Config\.OutputMode'
        (Get-FunctionText -Ast $deployAst -Name 'Register-ScheduledTaskNow') |
            Should -Match '-OutputMode \$\(\$Config\.OutputMode\)'
        (Get-FunctionText -Ast $invokeAst -Name 'Register-BootUpdateTaskForReboot') |
            Should -Match '-OutputMode \$\(\$script:OutputMode\)'
    }
}

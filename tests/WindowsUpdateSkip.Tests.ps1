Describe 'Skip Windows Update for a run' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $cyclePath = Join-Path $repoRoot 'Invoke-BootUpdateCycle.ps1'
        $deployPath = Join-Path $repoRoot 'Deploy-BootUpdateCycle.ps1'
        $cycleTokens = $null
        $cycleErrors = $null
        $deployTokens = $null
        $deployErrors = $null
        $cycleAst = [Management.Automation.Language.Parser]::ParseFile($cyclePath, [ref]$cycleTokens, [ref]$cycleErrors)
        $deployAst = [Management.Automation.Language.Parser]::ParseFile($deployPath, [ref]$deployTokens, [ref]$deployErrors)
        $cycleText = Get-Content -LiteralPath $cyclePath -Raw
        $deployText = Get-Content -LiteralPath $deployPath -Raw
        $cycleParamText = $cycleAst.ParamBlock.Extent.Text
        $deployParamText = $deployAst.ParamBlock.Extent.Text

        function Get-FunctionSource {
            param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$Name)
            $node = $Ast.Find({
                param($candidate)
                $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -eq $Name
            }, $true)
            if (-not $node) { throw "Function '$Name' was not found." }
            $node.Extent.Text
        }
    }

    It 'accepts the switch, excludes Windows Update work, preserves the choice on resume, and reports the skip' {
        $cycleErrors | Should -BeNullOrEmpty
        $cycleParamText | Should -Match '\[switch\]\$SkipWindowsUpdate'
        $cycleText | Should -Match '\$script:SkipWindowsUpdate\s*=\s*\$SkipWindowsUpdate'
        $cycleText | Should -Match 'Name=''WindowsUpdate''.*?Skip=\[bool\]\$script:SkipWindowsUpdate'

        $cycleFunction = Get-FunctionSource $cycleAst 'Invoke-BootUpdateCycle'
        $prefetchStart = $cycleFunction.IndexOf('Windows Update prefetch')
        $phaseStart = $cycleFunction.IndexOf("Name='WindowsUpdate'", $prefetchStart)
        $prefetch = $cycleFunction.Substring($prefetchStart, $phaseStart - $prefetchStart)
        $prefetch | Should -Match '\$script:SkipWindowsUpdate'
        $prefetch | Should -Match 'Windows Update: skipped by request'
        $cycleFunction | Should -Match 'if \(-not \$WhatIfPreference -and -not \$pending -and \[bool\]\$state\.WindowsUpdateDone -and -not \$script:SkipWindowsUpdate\)'
        $cycleFunction | Should -Match 'Name=''DriverFirmware''.*?Skip=\(\$script:SkipWindowsUpdate -or'
        $cycleFunction | Should -Match '\$state\.WindowsUpdateDone = \$false'

        $taskFunction = Get-FunctionSource $cycleAst 'Register-BootUpdateTaskForReboot'
        $taskFunction | Should -Match '\$script:SkipWindowsUpdate\)\s*\{\s*\$taskArgs \+= ''-SkipWindowsUpdate'''
        $launchFunction = Get-FunctionSource $cycleAst 'Get-BootUpdateLaunchContract'
        $launchFunction | Should -Match 'if \(\$script:SkipWindowsUpdate\)\s*\{\s*''WindowsUpdate''\s*\}'

        $cycleText | Should -Match 'WindowsUpdateDisposition\s*=\s*if \(\$script:SkipWindowsUpdate\) \{ ''SkippedByRequest'' \} else \{ ''Included'' \}'
        $cycleText | Should -Match '\[SKIPPED\] Windows Update skipped by request; no discovery, download, or install ran\.'
    }

    It 'exposes the switch through deployment and passes it to the first run' {
        $deployErrors | Should -BeNullOrEmpty
        $deployParamText | Should -Match '\[switch\]\$SkipWindowsUpdate'
        $deployText | Should -Match 'SkipWindowsUpdate\s*=\s*\$false'
        $deployText | Should -Match "'SkipWindowsUpdate'"
        $deployText | Should -Match 'SkipWindowsUpdate\s*=\s*\$Config\.SkipWindowsUpdate'
        $deployText | Should -Match 'if \(\$Config\.SkipWindowsUpdate\)\s+\{ \$taskArgs \+= ''-SkipWindowsUpdate'' \}'
    }
}

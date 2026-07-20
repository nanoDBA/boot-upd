BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $invokePath = Join-Path $repoRoot 'Invoke-BootUpdateCycle.ps1'
    $deployPath = Join-Path $repoRoot 'Deploy-BootUpdateCycle.ps1'

    function Get-ScriptAst {
        param([Parameter(Mandatory)][string]$Path)
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        return $ast
    }

    function Get-FunctionText {
        param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$Name)
        $function = $Ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        }, $true)
        $function | Should -Not -BeNullOrEmpty -Because "production function '$Name' must exist"
        return $function.Extent.Text
    }

    $invokeAst = Get-ScriptAst $invokePath
    $deployAst = Get-ScriptAst $deployPath
    $invokeSource = Get-Content $invokePath -Raw
}

Describe 'Delayed and explicit reboot evidence' {
    It 'requires two clean registry probes separated by an animated settle interval' {
        $text = Get-FunctionText $invokeAst 'Get-ConfirmedPendingReboot'
        ([regex]::Matches($text, 'Test-PendingReboot')).Count | Should -Be 2
        $text | Should -Match 'RebootSignalSettleSeconds'
        $text | Should -Match 'Wait-BootUpdateUiInterval'
        $text | Should -Match 'Watching for delayed Windows reboot signals'
    }

    It 'preserves native 3010 and 1641 as successful reboot requests' {
        $text = Get-FunctionText $invokeAst 'Invoke-PackageManagerWithTimeout'
        $text | Should -Match 'BOOTUPDATE_NATIVE_EXIT'
        $text | Should -Match '\$effectiveExitCode -in @\(1641, 3010\)'
        $text | Should -Match '\$script:ExplicitRebootRequests\.Add'
        $text | Should -Match 'notin @\(0, 1641, 3010\)'
    }

    It 'uses confirmed reboot evidence for the final decision' {
        (Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle') |
            Should -Match '\$pending = if \(\$WhatIfPreference\) \{ @\(\) \} else \{ Get-ConfirmedPendingReboot \}'
    }
}

Describe 'Durable resume chain' {
    It 'uses ARSO user resume plus a delayed SYSTEM safety net' {
        $text = Get-FunctionText $invokeAst 'Register-BootUpdateTaskForReboot'
        $text | Should -Match 'New-ScheduledTaskTrigger -AtLogOn'
        $text | Should -Match 'BootUpdateCycleFallback'
        $text | Should -Match "Delay = 'PT3M'"
    }

    It 'retries failures, rejects overlap, and verifies task registration' {
        foreach ($ast in @($invokeAst, $deployAst)) {
            $name = if ($ast -eq $invokeAst) { 'Register-BootUpdateTaskForReboot' } else { 'Register-ScheduledTaskNow' }
            $text = Get-FunctionText $ast $name
            $text | Should -Match '-RestartCount 3'
            $text | Should -Match '-RestartInterval'
            $text | Should -Match '-MultipleInstances IgnoreNew'
            $text | Should -Match 'Get-ScheduledTask'
            $text | Should -Match "State -eq 'Disabled'"
        }
    }

    It 'keeps resumed state after a transient preflight failure' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $text | Should -Match 'Resume checkpoint and scheduled tasks preserved'
        $text.IndexOf('$state.Iteration++') | Should -BeGreaterThan $text.IndexOf('Test-PreFlightChecks')
    }

    It 'arms the resume checkpoint before any mutating update phase' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $checkpoint = $text.IndexOf("Resume checkpoint armed before update phases")
        $firstPhase = $text.IndexOf('Update-WingetPackages')
        $checkpoint | Should -BeGreaterThan 0
        $checkpoint | Should -BeLessThan $firstPhase
    }
}

Describe 'Evidence-backed completion' {
    It 'queues a near-term retry instead of congratulating an incomplete phase set' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $text | Should -Match '\$incompletePhases'
        $text | Should -Match 'Register-BootUpdateTaskForReboot -RetrySoon'
        $text | Should -Match 'R E C O V E R Y   P A S S   Q U E U E D'
        $text.IndexOf('$incompletePhases') | Should -BeLessThan $text.IndexOf('P A T C H   C Y C L E   V E R I F I E D')
    }

    It 'congratulates only the verified green path and reports its evidence' {
        $text = Get-FunctionText $invokeAst 'Invoke-BootUpdateCycle'
        $text | Should -Match 'YOU DID IT.*THIS MACHINE IS GREEN.*NICE WORK'
        $text | Should -Match 'configured phases completed'
        $text | Should -Match 'Reboot state clean twice'
        $text | Should -Match 'critical service\(s\) healthy'
        $text | Should -Not -Match 'FULLY PATCHED'
    }
}

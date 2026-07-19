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

Describe 'Resilient rich progress rendering' {
    It 'keeps native key-responsive progress while enabling optional Spectre phase rendering' {
        $initialize = Get-FunctionText -Ast $invokeAst -Name 'Initialize-BootUpdateConsole'
        $progress = Get-FunctionText -Ast $invokeAst -Name 'Write-BootUpdateProgress'
        $initialize | Should -Match "Progress.View = 'Minimal'"
        $progress | Should -Match 'Write-Progress @progressArgs'
        $progress | Should -Match 'TuiSpinnerFrames'
        (Get-FunctionText -Ast $invokeAst -Name 'Write-BootUpdateSpectreText') |
            Should -Match 'PwshSpectreConsole\\Write-SpectreHost'
    }

    It 'installs a pinned stable module only for eligible interactive runs' {
        $text = Get-FunctionText -Ast $invokeAst -Name 'Initialize-BootUpdateSpectreConsole'
        $invokeSource | Should -Match "SpectreInstallVersion = \[version\]'2\.6\.3'"
        $text | Should -Match '-not \$script:TuiInteractive'
        $text | Should -Match '\$WhatIfPreference'
        $text | Should -Match "PSVersion -lt \[version\]'7\.4'"
        $text | Should -Match 'Install-PSResource'
        $text | Should -Match 'Install-Module'
        $text | Should -Match 'Scope AllUsers'
        $text | Should -Match 'Repository PSGallery'
        $invokeSource | Should -Match 'Join-Path \$env:ProgramFiles ''PowerShell\\Modules'''
        $pathCheck = Get-FunctionText -Ast $invokeAst -Name 'Test-BootUpdateSpectreModulePath'
        $pathCheck | Should -Match 'SpectreTrustedRoots'
        $pathCheck | Should -Match 'OrdinalIgnoreCase'
        $pathCheck | Should -Match 'ReparsePoint'
        $pathCheck | Should -Match 'broadWriteSids'
        $text | Should -Match 'using native console rendering'
    }

    It 'initializes Spectre only after preview exit, mutex acquisition, and the splash' {
        $bootstrapCall = $invokeSource.LastIndexOf('Initialize-BootUpdateSpectreConsole')
        $previewExit = $invokeSource.LastIndexOf('if ($PreviewSplash)')
        $mutexCall = $invokeSource.LastIndexOf('if (-not (Enter-BootUpdateMutex))')
        $splashCall = $invokeSource.LastIndexOf('Show-StartupArt')
        $bootstrapCall | Should -BeGreaterThan $previewExit
        $bootstrapCall | Should -BeGreaterThan $mutexCall
        $bootstrapCall | Should -BeGreaterThan $splashCall
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

Describe 'Spectre bootstrap behavior' {
    BeforeAll {
        . ([scriptblock]::Create((Get-FunctionText -Ast $invokeAst -Name 'Test-BootUpdateSpectreModulePath')))
        . ([scriptblock]::Create((Get-FunctionText -Ast $invokeAst -Name 'Initialize-BootUpdateSpectreConsole')))
        function Write-Log { param($Message, $Level, $Visibility) }
    }

    BeforeEach {
        $script:TuiInteractive = $false
        $script:SpectreEnabled = $false
        $script:SpectreModuleName = 'PwshSpectreConsole'
        $script:SpectreInstallVersion = [version]'2.6.3'
        $script:SpectreTrustedRoots = @((Join-Path $env:ProgramFiles 'PowerShell\Modules'))
        Mock Get-Module { return $null }
        Mock Install-PSResource { }
        Mock Import-Module { }
    }

    It 'does not discover, install, or import from a non-interactive session' {
        Initialize-BootUpdateSpectreConsole
        Should -Invoke Get-Module -Times 0
        Should -Invoke Install-PSResource -Times 0
        Should -Invoke Import-Module -Times 0
    }

    It 'does not install a missing module under WhatIf' {
        $script:TuiInteractive = $true
        $savedWhatIf = $WhatIfPreference
        try {
            $WhatIfPreference = $true
            Initialize-BootUpdateSpectreConsole
        } finally {
            $WhatIfPreference = $savedWhatIf
        }
        Should -Invoke Get-Module -Times 1
        Should -Invoke Install-PSResource -Times 0
        Should -Invoke Import-Module -Times 0
    }

    It 'rejects a module manifest outside protected Program Files roots' {
        $manifest = Join-Path $TestDrive 'PwshSpectreConsole.psd1'
        Set-Content -LiteralPath $manifest -Value '@{}'
        Test-BootUpdateSpectreModulePath -Path $manifest | Should -BeFalse
    }
}

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $invokePath = Join-Path $repoRoot 'Invoke-BootUpdateCycle.ps1'
    $deployPath = Join-Path $repoRoot 'Deploy-BootUpdateCycle.ps1'
    $demoPath = Join-Path $repoRoot 'tools\Show-BootUpdateProgressDemo.ps1'

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
    $demoAst = Get-ScriptAst -Path $demoPath
    $invokeSource = Get-Content -LiteralPath $invokePath -Raw
    $deploySource = Get-Content -LiteralPath $deployPath -Raw
    $demoSource = Get-Content -LiteralPath $demoPath -Raw
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

    It 'keeps the complete splash implementation byte-stable after newline normalization' {
        $splash = (Get-FunctionText -Ast $invokeAst -Name 'Show-StartupArt') -replace "`r`n", "`n"
        $hash = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($splash))
        ).ToLowerInvariant()
        $hash | Should -Be '514ae36a2fa40dca864da70b36b8f5a4f479f7f978ffc8cc1bf81d811b5e3d69'
    }
}

Describe 'Splash theme selection' {
    BeforeAll {
        . ([scriptblock]::Create((Get-FunctionText -Ast $invokeAst -Name 'Test-BootUpdateVirtualTerminal')))
        . ([scriptblock]::Create((Get-FunctionText -Ast $invokeAst -Name 'Resolve-BootUpdateSplashTheme')))
    }

    It 'recognizes a modern ConsoleHost when the host flag under-reports VT support' {
        Test-BootUpdateVirtualTerminal -UseSuppliedCapabilities `
            -HostReportsSupport:$false -OutputRedirected:$false -HostName ConsoleHost `
            -OsBuild 26200 -WindowsPlatform:$true | Should -BeTrue
    }

    It 'defaults a VT-capable console to neon theme 0' {
        Resolve-BootUpdateSplashTheme -VirtualTerminalSupported $true | Should -Be 0
        Resolve-BootUpdateSplashTheme -VirtualTerminalSupported $true -RequestedTheme 'invalid' | Should -Be 0
    }

    It 'honors explicit themes but preserves the genuine non-VT fallback' {
        Resolve-BootUpdateSplashTheme -VirtualTerminalSupported $true -RequestedTheme '1' | Should -Be 1
        Resolve-BootUpdateSplashTheme -VirtualTerminalSupported $true -RequestedTheme '2' | Should -Be 2
        Resolve-BootUpdateSplashTheme -VirtualTerminalSupported $false -RequestedTheme '0' | Should -Be 2
    }

    It 'does not emit VT styling into redirected output or legacy Windows consoles' {
        Test-BootUpdateVirtualTerminal -UseSuppliedCapabilities `
            -HostReportsSupport:$true -OutputRedirected:$true -HostName ConsoleHost `
            -OsBuild 26200 -WindowsPlatform:$true | Should -BeFalse
        Test-BootUpdateVirtualTerminal -UseSuppliedCapabilities `
            -HostReportsSupport:$false -OutputRedirected:$false -HostName ConsoleHost `
            -OsBuild 14393 -WindowsPlatform:$true | Should -BeFalse
    }
}

Describe 'Interactive verbosity cycling' {
    It 'polls v without blocking and cycles the mode list' {
        $text = Get-FunctionText -Ast $invokeAst -Name 'Read-BootUpdateUiKeys'
        $text | Should -Match '\[Console\]::KeyAvailable'
        $text | Should -Match '\[Console\]::ReadKey\(\$true\)'
        $text | Should -Match "KeyChar -notin @\('v', 'V'\)"
        $text | Should -Match 'Switch-BootUpdateOutputMode'
        (Get-FunctionText -Ast $invokeAst -Name 'Switch-BootUpdateOutputMode') |
            Should -Match '% \$script:OutputModes.Count'
    }

    It 'disables key polling for SYSTEM and redirected consoles' {
        $text = Get-FunctionText -Ast $invokeAst -Name 'Initialize-BootUpdateConsole'
        $text | Should -Match "S-1-5-18"
        $text | Should -Match 'IsInputRedirected'
        $text | Should -Match 'IsOutputRedirected'
        $text | Should -Match "ConsoleHost"
        $keys = Get-FunctionText -Ast $invokeAst -Name 'Read-BootUpdateUiKeys'
        $keys | Should -Match '(?s)catch\s*\{.*?Clear-BootUpdateProgressLine.*?TuiInteractive\s*=\s*\$false'
    }
}

Describe 'Resilient rich progress rendering' {
    It 'uses one dependency-free custom live-row owner and native phase rendering' {
        $initialize = Get-FunctionText -Ast $invokeAst -Name 'Initialize-BootUpdateConsole'
        $progress = Get-FunctionText -Ast $invokeAst -Name 'Write-BootUpdateProgress'
        $writer = Get-FunctionText -Ast $invokeAst -Name 'Write-BootUpdateLiveText'
        $clear = Get-FunctionText -Ast $invokeAst -Name 'Clear-BootUpdateProgressLine'
        $initialize | Should -Match 'SupportsVirtualTerminal'
        $progress | Should -Match 'Write-BootUpdateLiveText'
        $progress | Should -Match 'TuiSpinnerFrames'
        $writer | Should -Match '\[Console\]::Write'
        $writer | Should -Match '\[2K'
        $writer | Should -Match 'TuiRenderedConsoleWidth -ne \$availableWidth'
        $writer | Should -Match '\$Text\$\('' '' \* \$paddingCount\)'
        $writer | Should -Not -Match '\[Console\]::Write\("`r\$escape\[2K'
        $writer | Should -Not -Match 'ValidateRange\(0,1000000\)'
        $clear | Should -Match '\[2K'
        $clear | Should -Match '(?s)finally.*CursorVisible'
        $progress | Should -Not -Match 'Write-Progress'
        $invokeSource | Should -Not -Match '\$PSStyle\.Progress\.View'
        $invokeSource | Should -Not -Match '(?i)PwshSpectreConsole|Write-SpectreHost|Spectre\.Console'
        (Get-FunctionText -Ast $invokeAst -Name 'Write-PhaseHeader') | Should -Match 'Write-Host'
        (Get-FunctionText -Ast $invokeAst -Name 'Write-PhaseResult') | Should -Match 'Write-Host'
    }

    It 'connects phase, monitored-process, and parallel-cohort progress without committing the live row' {
        $phaseHeader = Get-FunctionText -Ast $invokeAst -Name 'Write-PhaseHeader'
        $phaseHeader | Should -Match 'Write-BootUpdateProgress'
        $phaseHeader.IndexOf('Clear-BootUpdateProgressLine') |
            Should -BeLessThan $phaseHeader.IndexOf('Write-Host ""')
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

Describe 'README console gallery' {
    It 'embeds raster assets so GitHub opens graphics instead of SVG source' {
        $readme = Get-Content (Join-Path $repoRoot 'README.md') -Raw
        $sources = @([regex]::Matches($readme, 'src="(docs/img/[^"]+\.png)"') | ForEach-Object { $_.Groups[1].Value })
        $sources.Count | Should -BeGreaterOrEqual 5
        foreach ($source in $sources) {
            $path = Join-Path $repoRoot $source
            Test-Path -LiteralPath $path | Should -BeTrue -Because "$source must be committed"
            $signature = [IO.File]::ReadAllBytes($path)[0..7]
            ($signature -join ',') | Should -Be '137,80,78,71,13,10,26,10'
        }
    }

}

Describe 'Duplicate log compression visibility' {
    BeforeAll {
        function Clear-BootUpdateProgressLine { }
        function Read-BootUpdateUiKeys { }
        function Invoke-BootUpdateLogRotation { param([string]$Path) }
        function Enable-BootUpdateNtfsCompression { param([string]$Path) }
        . ([scriptblock]::Create((Get-FunctionText -Ast $invokeAst -Name 'Test-BootUpdateOutputAtLeast')))
        . ([scriptblock]::Create((Get-FunctionText -Ast $invokeAst -Name 'Write-Log')))
    }

    BeforeEach {
        $script:LogPath = Join-Path $TestDrive "repeat-$([guid]::NewGuid()).log"
        $script:LastLogMessage = $null
        $script:LastLogRepeatCount = 0
        $script:LastLogLevel = 'Info'
        $script:LastLogVisibility = 'Verbose'
        $script:OutputModes = @('Quiet', 'Normal', 'Verbose', 'Debug')
        $script:OutputMode = 'Verbose'
        Mock Clear-BootUpdateProgressLine { }
        Mock Read-BootUpdateUiKeys { }
        Mock Write-Host { }
    }

    It 'retains repeat summaries in the file without printing them in Verbose' {
        Write-Log 'installer heartbeat'
        Write-Log 'installer heartbeat'
        Write-Log 'installer heartbeat'
        Write-Log 'installer completed'

        (Get-Content -LiteralPath $script:LogPath -Raw) |
            Should -Match 'previous line repeated 2 more times'
        Should -Invoke Write-Host -Times 0 -ParameterFilter {
            [string]$Object -match 'previous line repeated'
        }
    }

    It 'exposes one repeat summary in Debug for troubleshooting' {
        $script:OutputMode = 'Debug'
        Write-Log 'installer heartbeat'
        Write-Log 'installer heartbeat'
        Write-Log 'installer completed'

        Should -Invoke Write-Host -Times 1 -ParameterFilter {
            [string]$Object -match 'previous line repeated 1 more time'
        }
    }

    It 'keeps repeated warnings and errors visible in Normal' {
        $script:OutputMode = 'Normal'
        Write-Log 'installer contention' -Level Warn
        Write-Log 'installer contention' -Level Warn
        Write-Log 'fatal installer result' -Level Error
        Write-Log 'fatal installer result' -Level Error
        Write-Log 'next event'

        Should -Invoke Write-Host -Times 1 -ParameterFilter {
            [string]$Object -match '\[Warn\] \(previous line repeated 1 more time\)'
        }
        Should -Invoke Write-Host -Times 1 -ParameterFilter {
            [string]$Object -match '\[Error\] \(previous line repeated 1 more time\)'
        }
    }

    It 'keeps logging mechanics and duplicated lifecycle narration out of Verbose' {
        $writeLog = Get-FunctionText -Ast $invokeAst -Name 'Write-Log'
        $writeLog | Should -Match '(?s)LastLogRepeatCount.*?Test-BootUpdateOutputAtLeast -Minimum Debug'
        $invokeSource | Should -Match 'Write-Log ">>> \[\$phaseNum/.*? - STARTING" -Visibility Debug'
        $invokeSource | Should -Match 'Write-Log "<<< \[\$phaseNum/.*? - \$phaseLabel .*? -Visibility Debug'
        $invokeSource | Should -Match 'Write-Log "<<< \[parallel\].*? -Visibility Debug'
        (Get-FunctionText -Ast $invokeAst -Name 'Wait-ProcessWithIdleTimeout') |
            Should -Match 'exited normally .* -Visibility Debug'
        (Get-FunctionText -Ast $invokeAst -Name 'Invoke-PackageManagerWithTimeout') |
            Should -Match 'Starting \(idle: .* -Visibility Debug'
    }
}

Describe 'Deferred phase result rendering' {
    BeforeAll {
        function Clear-BootUpdateProgressLine { }
        function Write-BootUpdateProgress { param($Activity, $Status, $PercentComplete) }
        . ([scriptblock]::Create((Get-FunctionText -Ast $invokeAst -Name 'Test-BootUpdateOutputAtLeast')))
        . ([scriptblock]::Create((Get-FunctionText -Ast $invokeAst -Name 'Write-PhaseResult')))
    }

    BeforeEach {
        $script:OutputModes = @('Quiet', 'Normal', 'Verbose', 'Debug')
        $script:OutputMode = 'Normal'
        Mock Clear-BootUpdateProgressLine { }
        Mock Write-BootUpdateProgress { }
        Mock Write-Host { }
    }

    It 'renders a planned user-context continuation as deferred, not failed' {
        Write-PhaseResult -Num 1 -Total 2 -Name Winget -Success $false -Deferred -Minutes 0.2 -Count 3

        Should -Invoke Write-Host -Times 1 -ParameterFilter {
            [string]$Object -match 'machine done; user pass deferred' -and
            [string]$Object -notmatch 'FAILED'
        }
    }

    It 'keeps a deferred result quiet in Quiet mode' {
        $script:OutputMode = 'Quiet'
        Write-PhaseResult -Num 1 -Total 2 -Name Winget -Success $false -Deferred -Minutes 0.2
        Should -Invoke Write-Host -Times 0
    }
}

Describe 'Animated progress behavior' {
    BeforeAll {
        foreach ($functionName in @(
            'New-BootUpdateNeonGradient',
            'New-BootUpdateDepthGradient',
            'Limit-BootUpdateConsoleText',
            'Get-BootUpdateProgressText',
            'Clear-BootUpdateProgressLine',
            'Write-BootUpdateLiveText',
            'Write-BootUpdateProgress',
            'Wait-BootUpdateUiInterval',
            'Wait-BootUpdateJobsWithProgress',
            'Get-ProcessTreeActivity',
            'Wait-ProcessWithIdleTimeout',
            'Invoke-PackageManagerWithTimeout',
            'Invoke-BootUpdateBackgroundOperation'
        )) {
            . ([scriptblock]::Create((Get-FunctionText -Ast $invokeAst -Name $functionName)))
        }
        function Read-BootUpdateUiKeys { $script:UiKeyPollCount++ }
        function Write-Log { param($Message, $Level, $Visibility) }
    }

    BeforeEach {
        $script:TuiInteractive = $true
        $script:OutputMode = 'Normal'
        $script:TuiProgressActive = $false
        $script:TuiSpinnerIndex = 0
        $script:TuiSpinnerFrames = @('|', '/', '-', '\')
        $script:TuiNeonPalette = New-BootUpdateNeonGradient
        $script:TuiDepthPalette = New-BootUpdateDepthGradient
        $script:TuiColorIndex = 0
        $script:TuiRenderedConsoleWidth = 0
        $script:TuiRefreshMilliseconds = 50
        $script:TuiInProgressTick = $false
        $script:UiKeyPollCount = 0
        $script:ClearCount = 0
        $script:ProgressCaptures = [System.Collections.Generic.List[object]]::new()
        Mock Write-BootUpdateLiveText {
            $script:ProgressCaptures.Add([pscustomobject]@{
                At = [datetime]::UtcNow
                Text = $Text
                Status = $Text
                PaletteIndex = $PaletteIndex
            })
            $script:TuiProgressActive = $true
            $script:TuiRenderedWidth = $Text.Length
        }
        Mock Clear-BootUpdateProgressLine {
            if ($script:TuiProgressActive) { $script:ClearCount++ }
            $script:TuiProgressActive = $false
            $script:TuiRenderedWidth = 0
            $script:TuiRenderedConsoleWidth = 0
            $script:TuiCursorHidden = $false
        }
    }

    It 'rotates the classic fixed-width ASCII propeller at the established line-spinner cadence' {
        1..12 | ForEach-Object {
            Write-BootUpdateProgress -Activity 'Demo' -Status 'Animating' -PercentComplete 25
        }
        $capturedFrames = @($script:ProgressCaptures | ForEach-Object {
            [regex]::Match($_.Text, 'BOOT//PULSE \[([^\]]+)\]').Groups[1].Value
        })
        $script:TuiSpinnerFrames | Should -Be @('|', '/', '-', '\')
        $capturedFrames | Should -Be @($script:TuiSpinnerFrames * 3)
        @($script:TuiSpinnerFrames | ForEach-Object Length | Select-Object -Unique) | Should -Be @(1)
        ($script:TuiSpinnerFrames -join '').ToCharArray() | ForEach-Object { [int]$_ | Should -BeLessOrEqual 127 }
        $script:TuiSpinnerIndex | Should -Be 0
        $invokeSource | Should -Match 'TuiRefreshMilliseconds\s*=\s*100'
    }

    It 'crossfades gradually around a closed splash-palette loop independent of propeller motion' {
        $script:TuiNeonPalette.Count | Should -Be 48
        $colors = @($script:TuiNeonPalette | ForEach-Object {
            ,([int[]]($_ -split ';'))
        })
        $largestStep = 0
        for ($i = 0; $i -lt $colors.Count; $i++) {
            $next = $colors[($i + 1) % $colors.Count]
            for ($channel = 0; $channel -lt 3; $channel++) {
                $largestStep = [math]::Max($largestStep, [math]::Abs($next[$channel] - $colors[$i][$channel]))
            }
        }
        $largestStep | Should -BeLessOrEqual 15

        1..12 | ForEach-Object {
            Write-BootUpdateProgress -Activity 'Fade test' -Status 'Glowing'
        }
        @($script:ProgressCaptures.PaletteIndex) | Should -Be @(0..11)
        $script:TuiSpinnerIndex | Should -Be 0
        $script:TuiColorIndex | Should -Be 12
    }

    It 'adds a gradual theme-zero dark cyan and violet depth layer to the glow' {
        $script:TuiDepthPalette.Count | Should -Be 48
        $colors = @($script:TuiDepthPalette | ForEach-Object { ,([int[]]($_ -split ';')) })
        $colors[0] | Should -Be @(0, 20, 28)
        $colors[24] | Should -Be @(25, 10, 41)
        $largestStep = 0
        for ($i = 0; $i -lt $colors.Count; $i++) {
            $next = $colors[($i + 1) % $colors.Count]
            for ($channel = 0; $channel -lt 3; $channel++) {
                $largestStep = [math]::Max($largestStep, [math]::Abs($next[$channel] - $colors[$i][$channel]))
            }
        }
        $largestStep | Should -BeLessOrEqual 2
        (Get-FunctionText -Ast $invokeAst -Name 'Write-BootUpdateLiveText') |
            Should -Match '38;2;\$\{rgb\};48;2;\$\{depthRgb\}'
    }

    It 'keeps the visual demo on the production gradient and independent color counter' {
        $demoGradient = & {
            . ([scriptblock]::Create((Get-FunctionText -Ast $demoAst -Name 'New-NeonGradient')))
            New-NeonGradient
        }
        @($demoGradient) | Should -Be @($script:TuiNeonPalette)
        $demoDepth = & {
            . ([scriptblock]::Create((Get-FunctionText -Ast $demoAst -Name 'New-DepthGradient')))
            New-DepthGradient
        }
        @($demoDepth) | Should -Be @($script:TuiDepthPalette)
        $demoFrames = '$frames = @(''|'', ''/'', ''-'', ''\'')'
        $demoSource | Should -Match ([regex]::Escape($demoFrames))
        $demoSource | Should -Match '\$colorIndex\s*=\s*\(\$colorIndex \+ 1\) % \$palette\.Count'
        $demoSource | Should -Not -Match '\$palette\[\$index'
        $demoSource | Should -Match '\$renderedConsoleWidth -ne \$width'
        $demoSource | Should -Not -Match '\[Console\]::Write\("`r\$escape\[2K\$escape\[1;38'
    }

    It 'preserves the photographed status text code point for code point' {
        $status = 'Finishing background downloads'
        $text = Get-BootUpdateProgressText -Frame '/' -Activity 'Windows Update prefetch' `
            -Status $status -PercentComplete 20 -MaxWidth 160
        $text | Should -Match ([regex]::Escape($status))
        $text | Should -Not -Match 'Ehmhrghmf'
        $text | Should -Match 'BOOT//PULSE'
        $text | Should -Match '\[##--------\] 20%'
        $text | Should -Match 'v:NORMAL'
    }

    It 'sanitizes controls and non-ASCII glyphs before cell-safe truncation' {
        $text = Get-BootUpdateProgressText -Frame '/' -Activity "Phase`r`nThree" `
            -Status "Updating e$([char]0x301)$([char]0x9b)$([char]0x202e) package`tquietly" -MaxWidth 42
        $text.Length | Should -BeLessOrEqual 42
        @($text.ToCharArray() | Where-Object {
            $code = [int]$_
            $code -lt 32 -or $code -gt 126
        }) | Should -BeNullOrEmpty
        $text | Should -Match '\.\.\.$'
    }

    It 'pumps multiple distinct frames at a bounded cadence during a wait' {
        $script:TuiRefreshMilliseconds = 100
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        Wait-BootUpdateUiInterval -Seconds 1.05 -Activity 'Cadence test' -Status 'Working' -PercentComplete 40
        $stopwatch.Stop()

        $script:ProgressCaptures.Count | Should -BeGreaterOrEqual 8
        @($script:ProgressCaptures.Status | Select-Object -Unique).Count | Should -Be 4
        @($script:ProgressCaptures.PaletteIndex | Select-Object -Unique).Count | Should -BeGreaterOrEqual 8
        $stopwatch.Elapsed.TotalMilliseconds | Should -BeGreaterOrEqual 900
        $stopwatch.Elapsed.TotalMilliseconds | Should -BeLessThan 2000
        $gaps = for ($i = 1; $i -lt $script:ProgressCaptures.Count; $i++) {
            ($script:ProgressCaptures[$i].At - $script:ProgressCaptures[$i - 1].At).TotalMilliseconds
        }
        ($gaps | Measure-Object -Maximum).Maximum | Should -BeLessThan 300
        $script:UiKeyPollCount | Should -Be $script:ProgressCaptures.Count
    }

    It 'animates while a real background job is running and returns on completion' {
        $job = Start-ThreadJob -ScriptBlock { Start-Sleep -Milliseconds 450 }
        try {
            $completed = Wait-BootUpdateJobsWithProgress -Jobs @($job) -TimeoutSeconds 3 `
                -Activity 'Job test' -Status 'Background job running'
            $completed | Should -BeTrue
            $script:ProgressCaptures.Count | Should -BeGreaterOrEqual 5
            @($script:ProgressCaptures.Status | Select-Object -Unique).Count | Should -Be 4
            @($script:ProgressCaptures.PaletteIndex | Select-Object -Unique).Count |
                Should -Be $script:ProgressCaptures.Count
        } finally {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns false at the job deadline while continuing to animate until timeout' {
        $fakeJob = [pscustomobject]@{ State = 'Running' }
        $completed = Wait-BootUpdateJobsWithProgress -Jobs @($fakeJob) -TimeoutSeconds 0.3 `
            -Activity 'Timeout test' -Status 'Still running'
        $completed | Should -BeFalse
        $script:ProgressCaptures.Count | Should -BeGreaterOrEqual 4
    }

    It 'keeps animating through the production background-operation adapter' {
        $result = Invoke-BootUpdateBackgroundOperation -Name 'Adapter test' `
            -Status 'Silent operation running' -TimeoutMinutes 1 `
            -ScriptBlock { Start-Sleep -Milliseconds 450; 'adapter-complete' }
        $result.Failed | Should -BeFalse
        $result.TimedOut | Should -BeFalse
        $result.Output | Should -Contain 'adapter-complete'
        $script:ProgressCaptures.Count | Should -BeGreaterOrEqual 5
        @($script:ProgressCaptures.Status | Select-Object -Unique).Count | Should -Be 4
        @($script:ProgressCaptures.PaletteIndex | Select-Object -Unique).Count |
            Should -Be $script:ProgressCaptures.Count
    }

    It 'keeps animating while a silent external process produces no output' {
        $pwshPath = (Get-Process -Id $PID).Path
        $result = Invoke-BootUpdateBackgroundOperation -Name 'External process test' `
            -Status 'Silent executable running' -TimeoutMinutes 1 `
            -ScriptBlock {
                param($Path)
                & $Path -NoProfile -NonInteractive -Command 'Start-Sleep -Milliseconds 450; "external-complete"'
            } -ArgumentList @($pwshPath)
        $result.Failed | Should -BeFalse
        $result.Output | Should -Contain 'external-complete'
        $script:ProgressCaptures.Count | Should -BeGreaterOrEqual 5
        @($script:ProgressCaptures.Status | Select-Object -Unique).Count | Should -Be 4
        @($script:ProgressCaptures.PaletteIndex | Select-Object -Unique).Count |
            Should -Be $script:ProgressCaptures.Count
    }

    It 'reports a failed background operation without freezing the renderer' {
        $result = Invoke-BootUpdateBackgroundOperation -Name 'Failure test' `
            -Status 'Failing operation running' -TimeoutMinutes 1 `
            -ScriptBlock { Start-Sleep -Milliseconds 250; throw 'synthetic failure' }
        $result.Failed | Should -BeTrue
        $result.TimedOut | Should -BeFalse
        ($result.Output -join "`n") | Should -Match 'BOOTUPDATE_ERROR\|synthetic failure'
        $script:ProgressCaptures.Count | Should -BeGreaterOrEqual 2
    }

    It 'surfaces a native 3010 result as successful explicit reboot evidence' {
        $script:ExplicitRebootRequests = [System.Collections.Generic.List[object]]::new()
        $result = Invoke-PackageManagerWithTimeout -Name 'RebootExitProbe' -ScriptBlock {
            & cmd.exe /d /c exit 3010
        } -IdleTimeoutMinutes 1 -HardTimeoutMinutes 1 -Status 'Testing reboot exit propagation'

        $result.Failed | Should -BeFalse
        $result.RebootRequired | Should -BeTrue
        $result.ExitCode | Should -Be 3010
        $script:ExplicitRebootRequests.Count | Should -Be 1
        $script:ExplicitRebootRequests[0].Source | Should -Be 'RebootExitProbe-exit-3010'
    }

    It 'captures partial output and kills a silent native process tree at timeout' {
        $pwshPath = (Get-Process -Id $PID).Path
        $result = Invoke-BootUpdateBackgroundOperation -Name 'Process-tree timeout test' `
            -Status 'Waiting for forced cleanup' -TimeoutMinutes 0.02 `
            -ScriptBlock {
                param($Path)
                & $Path -NoProfile -NonInteractive -Command '"CHILD_PID|$PID"; Start-Sleep -Seconds 30'
            } -ArgumentList @($pwshPath)
        $result.TimedOut | Should -BeTrue
        $result.Failed | Should -BeTrue
        $pidLine = $result.Output | Where-Object { $_ -match '^CHILD_PID\|(\d+)$' } | Select-Object -First 1
        $pidLine | Should -Not -BeNullOrEmpty
        $childPid = [int]([regex]::Match($pidLine, '\d+').Value)
        Get-Process -Id $childPid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        $script:ProgressCaptures.Count | Should -BeGreaterOrEqual 5
    }

    It 'clears the owned live row idempotently on completion' {
        Write-BootUpdateProgress -Activity 'Cleanup test' -Status 'Working'
        Write-BootUpdateProgress -Activity 'Cleanup test' -Completed
        Write-BootUpdateProgress -Activity 'Cleanup test' -Completed
        $script:TuiProgressActive | Should -BeFalse
        $script:ClearCount | Should -Be 1
        $script:ProgressCaptures.Count | Should -Be 1
    }

    It 'polls keys but does not render progress in Quiet mode' {
        $script:OutputMode = 'Quiet'
        Write-BootUpdateProgress -Activity 'Quiet test' -Status 'Hidden'
        $script:UiKeyPollCount | Should -Be 1
        $script:ProgressCaptures.Count | Should -Be 0
    }

    It 'does not render or poll keys when the host is non-interactive' {
        $script:TuiInteractive = $false
        Wait-BootUpdateUiInterval -Seconds 0.05 -Activity 'Redirected test'
        $script:UiKeyPollCount | Should -Be 0
        $script:ProgressCaptures.Count | Should -Be 0
    }

    It 'cycles Normal through every mode, clears Quiet, and resumes animation' {
        . ([scriptblock]::Create((Get-FunctionText -Ast $invokeAst -Name 'Switch-BootUpdateOutputMode')))
        $script:OutputModes = @('Quiet', 'Normal', 'Verbose', 'Debug')
        $script:OutputMode = 'Normal'
        $script:ScriptBoundParams = @{}
        $script:TuiProgressActive = $true
        Mock Write-Host { }

        $observed = foreach ($null in 1..4) {
            Switch-BootUpdateOutputMode
            $script:OutputMode
        }
        $observed | Should -Be @('Verbose','Debug','Quiet','Normal')
        $script:ScriptBoundParams.OutputMode | Should -Be 'Normal'
        $script:ClearCount | Should -Be 1
        $invokeSource | Should -Not -Match 'Write-Progress'
    }
}

Describe 'Progress coverage across blocking paths' {
    It 'pumps the UI during every parent-thread background-job wait' {
        foreach ($functionName in @(
            'Update-WingetPackages',
            'Install-WindowsUpdates',
            'Update-PowerShellModules',
            'Send-EmailNotification'
        )) {
            (Get-FunctionText -Ast $invokeAst -Name $functionName) |
                Should -Match 'Wait-BootUpdateJobsWithProgress' -Because "$functionName can block for seconds or minutes"
        }
    }

    It 'pumps at 100 ms inside long monitor intervals and the parallel cohort loop' {
        $invokeSource | Should -Match 'TuiRefreshMilliseconds = 100'
        (Get-FunctionText -Ast $invokeAst -Name 'Wait-ProcessWithIdleTimeout') |
            Should -Match 'Wait-BootUpdateUiInterval'
        $cohortWait = '(?s)Parallel update cohort.*?Wait-BootUpdateUiInterval -Seconds 1'
        $invokeSource | Should -Match $cohortWait
    }

    It 'uses animated waits for installer retry delays' {
        $winget = Get-FunctionText -Ast $invokeAst -Name 'Update-WingetPackages'
        $winget | Should -Not -Match 'Start-Sleep -Seconds 30'
        $winget | Should -Match 'Another installer is active; waiting to retry'
    }

    It 'isolates every potentially long built-in phase operation behind a progress pump' {
        foreach ($functionName in @(
            'Update-ChocolateyPackages',
            'Initialize-BootUpdateWindowsUpdateModule',
            'Install-WindowsUpdates',
            'Install-DriverFirmwareUpdates',
            'Update-DefenderSignatures',
            'Update-WslKernelAndDistros',
            'Update-ContainerImages',
            'Update-PipPackages',
            'Update-NpmPackages',
            'Update-Office365',
            'Update-ScoopPackages',
            'Update-DotnetTools',
            'Update-VscodeExtensions',
            'Repair-AwsTooling'
        )) {
            (Get-FunctionText -Ast $invokeAst -Name $functionName) |
                Should -Match 'Invoke-BootUpdateBackgroundOperation' -Because "$functionName must not freeze the UI thread"
        }
    }

    It 'uses process-tree isolation while keeping bearer webhook URLs out of child arguments' {
        $adapter = Get-FunctionText -Ast $invokeAst -Name 'Invoke-BootUpdateBackgroundOperation'
        $adapter | Should -Match 'Invoke-PackageManagerWithTimeout'
        $adapter | Should -Not -Match 'Start-ThreadJob'
        (Get-FunctionText -Ast $invokeAst -Name 'Wait-ProcessWithIdleTimeout') |
            Should -Match 'Kill\(\$true\)'
        (Get-FunctionText -Ast $invokeAst -Name 'Send-WebhookNotification') |
            Should -Not -Match 'Invoke-BootUpdateBackgroundOperation'
    }

    It 'does not install PSWindowsUpdate under WhatIf' {
        $initializer = Get-FunctionText -Ast $invokeAst -Name 'Initialize-BootUpdateWindowsUpdateModule'
        $initializer.IndexOf('$WhatIfPreference') | Should -BeLessThan $initializer.IndexOf('Invoke-BootUpdateBackgroundOperation')
    }

    It 'clears progress in staged-return and top-level finally paths' {
        $invokeSource | Should -Match '(?s)Staged rollout:.*?Write-BootUpdateProgress -Completed\s+return'
        $invokeSource | Should -Match '(?s)try \{\s*Invoke-BootUpdateCycle\s*\} finally \{.*?Write-BootUpdateProgress -Completed'
    }
}

Describe 'Plain-language toast outcomes' {
    It 'routes every toast through one notification-level-aware helper' {
        $toast = Get-FunctionText -Ast $invokeAst -Name 'Send-BootUpdateToast'
        $toast | Should -Match 'Test-NotificationAllowed'
        $toast | Should -Match 'S-1-5-18'
        $toast | Should -Match 'New-BurntToastNotification'
        (Get-FunctionText -Ast $invokeAst -Name 'Send-CompletionNotification') |
            Should -Match 'Send-BootUpdateToast'
        (Get-FunctionText -Ast $invokeAst -Name 'Send-RebootWarning') |
            Should -Match 'Send-BootUpdateToast'
    }

    It 'distinguishes completion, retry, user continuation, and reboot states' {
        $cycle = Get-FunctionText -Ast $invokeAst -Name 'Invoke-BootUpdateCycle'
        $cycle | Should -Match 'Updates complete.*no restart required'
        $cycle | Should -Match 'Another update pass is scheduled.*no restart required'
        $cycle | Should -Match 'User update pass pending.*no restart required'
        (Get-FunctionText -Ast $invokeAst -Name 'Send-RebootWarning') |
            Should -Match 'Restart required.*updates will continue automatically'
    }

    It 'keeps public toast fixtures synthetic and free of local identity data' {
        $fixtureText = @(
            Get-FunctionText -Ast $invokeAst -Name 'Send-BootUpdateToast'
            Get-FunctionText -Ast $invokeAst -Name 'Send-RebootWarning'
        ) -join "`n"
        $fixtureText | Should -Not -Match '(?i)OneDrive|Google Drive|Dropbox|[A-Z]:\\Users\\|@example\.(com|org)'
    }
}

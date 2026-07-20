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
        $hash | Should -Be '2d5cd129d268aa97144d5da1fb84cec3035fa8541aae3eff0a53ed313290811c'
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

Describe 'Animated progress behavior' {
    BeforeAll {
        foreach ($functionName in @(
            'New-BootUpdateNeonGradient',
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

    It 'keeps the visual demo on the production gradient and independent color counter' {
        $demoGradient = & {
            . ([scriptblock]::Create((Get-FunctionText -Ast $demoAst -Name 'New-NeonGradient')))
            New-NeonGradient
        }
        @($demoGradient) | Should -Be @($script:TuiNeonPalette)
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
            'Test-PostUpdateHealth',
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

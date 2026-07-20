BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $cmdPath = Join-Path $repoRoot 'upd.cmd'
    $launcherPath = Join-Path $repoRoot 'tools\Invoke-UpdLauncher.ps1'
    $deployPath = Join-Path $repoRoot 'Deploy-BootUpdateCycle.ps1'
    $invokePath = Join-Path $repoRoot 'Invoke-BootUpdateCycle.ps1'
    $releasePath = Join-Path $repoRoot 'tools\New-Release.ps1'

    function Get-ParsedScript {
        param([Parameter(Mandatory)][string]$Path)
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
        $errors | Should -BeNullOrEmpty
        return $ast
    }

    $null = Get-ParsedScript $launcherPath
    $null = Get-ParsedScript $deployPath
    $null = Get-ParsedScript $invokePath
    $launcherSource = Get-Content -LiteralPath $launcherPath -Raw
    $deploySource = Get-Content -LiteralPath $deployPath -Raw
    $invokeSource = Get-Content -LiteralPath $invokePath -Raw
    $releaseSource = Get-Content -LiteralPath $releasePath -Raw
    $cmdSource = Get-Content -LiteralPath $cmdPath -Raw

    function Invoke-UpdCommand {
        param([Parameter(Mandatory)][string]$Arguments)
        $output = & cmd.exe /d /c "`"$cmdPath`" $Arguments" 2>&1
        $text = [regex]::Replace(($output -join "`n"), "`e\[[0-9;]*m", '')
        return [pscustomobject]@{ ExitCode=$LASTEXITCODE; Text=$text }
    }
}

Describe 'Friendly launcher help' {
    It 'accepts <alias> without elevation or side effects' -ForEach @(
        @{ Alias='/?' }, @{ Alias='?' }, @{ Alias='/help' }, @{ Alias='help' },
        @{ Alias='--help' }, @{ Alias='-h' }, @{ Alias='usage' }, @{ Alias='--usage' }
    ) {
        $result = Invoke-UpdCommand $Alias
        $result.ExitCode | Should -Be 0
        $result.Text | Should -Match 'UPD // Boot Update Cycle'
        $result.Text | Should -Match 'upd demo'
        $result.Text | Should -Match 'RUN OPTIONS'
    }

    It 'rejects an unknown command and points back to help' {
        $result = Invoke-UpdCommand 'definitely-not-a-command'
        $result.ExitCode | Should -Not -Be 0
        $result.Text | Should -Match "Unknown command 'definitely-not-a-command'"
        $result.Text | Should -Match 'upd help'
    }
}

Describe 'Safe fun and planning commands' {
    It 'routes demo and fun only to preview tools, before the elevated run branch' {
        $launcherSource | Should -Match '''demo''\s*\{(?s:.*?)& \$demoPath'
        $launcherSource | Should -Match '''fun''\s*\{(?s:.*?)-PreviewSplash(?s:.*?)& \$demoPath'
        $launcherSource.IndexOf("'demo' {") | Should -BeLessThan $launcherSource.IndexOf("'run' {")
        $launcherSource.IndexOf("'fun' {") | Should -BeLessThan $launcherSource.IndexOf("'run' {")
    }

    It 'prints a rich plan without elevation, deployment, tasks, or reboots' {
        $result = Invoke-UpdCommand 'plan --delay 120 --drivers --firmware --wsl --containers --allow-metered --restore-point --dotnet-tools --aws-tooling --skip-office365 --output-mode Verbose --max-iterations 7 --timeout 45 --exclude Teams,OneDrive --include Git'
        $result.ExitCode | Should -Be 0
        $result.Text | Should -Match 'RebootDelaySec\s+: 120'
        $result.Text | Should -Match 'IncludeDriverUpdates\s+: True'
        $result.Text | Should -Match 'EnableDotnetTools\s+: True'
        $result.Text | Should -Match 'OutputMode\s+: Verbose'
        $result.Text | Should -Match 'PLAN ONLY.*no elevation.*reboots'
    }

    It 'supports compact command and option aliases' {
        $result = Invoke-UpdCommand 'p -r 90 -drv -fw -w -c -m -s -o Quiet -n 6 -t 40 -x Teams -i Git'
        $result.ExitCode | Should -Be 0
        $result.Text | Should -Match 'RebootDelaySec\s+: 90'
        $result.Text | Should -Match 'IncludeDriverUpdates\s+: True'
        $result.Text | Should -Match 'StagedRollout\s+: True'
        $result.Text | Should -Match 'OutputMode\s+: Quiet'
        $result.Text | Should -Match 'MaxIterations\s+: 6'
    }

    It 'allows splash preview before enforcing the administrator boundary' {
        $preview = $invokeSource.IndexOf('if ($PreviewSplash)')
        $adminGuard = $invokeSource.LastIndexOf("requires administrator access")
        $invokeSource | Should -Not -Match '#requires -RunAsAdministrator'
        $preview | Should -BeGreaterThan 0
        $preview | Should -BeLessThan $adminGuard
    }
}

Describe 'Checksummed launcher self-update handoff' {
    It 'requires checksum sidecars for every executable bundle asset' {
        foreach ($asset in @('Invoke-BootUpdateCycle.ps1','Deploy-BootUpdateCycle.ps1','Invoke-UpdLauncher.ps1','Show-BootUpdateProgressDemo.ps1','Repair-AwsTooling.ps1','upd.cmd')) {
            $launcherSource | Should -Match ([regex]::Escape("Name='$asset'"))
        }
        $launcherSource | Should -Match '\$\(\$spec\.Name\)\.sha256'
        $launcherSource | Should -Match "expected -notmatch '\^\[0-9A-F\]\{64\}\$'"
        $launcherSource | Should -Match 'SHA256 mismatch'
    }

    It 'stages the running batch file and adopts it only after PowerShell exits' {
        $launcherSource | Should -Match 'Name=''upd\.cmd''.*StageBatch=\$true'
        $cmdSource | Should -Match 'set "UPD_LAUNCHER=.*Invoke-UpdLauncher\.ps1"'
        $cmdSource | Should -Match 'pwsh .*"%UPD_LAUNCHER%" %\*'
        $cmdSource.IndexOf('set "UPD_EXIT=%errorlevel%"') | Should -BeLessThan $cmdSource.IndexOf('upd.cmd.next')
        $cmdSource | Should -Match 'adopt-staged-batch'
        $launcherSource | Should -Match 'Get-FileHash -LiteralPath \$staged'
        $launcherSource | Should -Match '\$stagedVersion -ne \$coreVersion'
        $launcherSource | Should -Match '\[IO\.File\]::Replace'
    }

    It 'publishes the complete executable bundle with sidecars' {
        foreach ($asset in @('Deploy-BootUpdateCycle.ps1','Invoke-BootUpdateCycle.ps1','upd.cmd','tools/Invoke-UpdLauncher.ps1','tools/Show-BootUpdateProgressDemo.ps1','Repair-AwsTooling.ps1')) {
            $releaseSource | Should -Match ([regex]::Escape($asset))
        }
        $releaseSource | Should -Match '"\$name\.sha256"'
    }

    It 'installs the PowerShell launcher before handling upd.cmd in the compatibility bridge' {
        $launcherIndex = $deploySource.IndexOf("Name='Invoke-UpdLauncher.ps1'")
        $batchIndex = $deploySource.IndexOf("Name='upd.cmd'")
        $launcherIndex | Should -BeGreaterThan 0
        $launcherIndex | Should -BeLessThan $batchIndex
        $deploySource | Should -Match '\$destination = "\$target\.next"'
        $deploySource | Should -Match '"\$destination\.sha256"'
    }

    It 'rolls back a failed bundle commit and fails closed after mutation begins' {
        $launcherSource | Should -Match 'Bundle commit failed and was rolled back'
        $launcherSource | Should -Match '\$Explicit -or \$commitStarted'
        $deploySource | Should -Match 'source bundle commit failed and was rolled back'
        $deploySource | Should -Match 'if \(\$sourceMutationStarted\) \{ throw \}'
    }

    It 'fails ambiguous dashed short commands before the run switch' {
        $guard = $launcherSource.IndexOf('Short commands do not take a dash')
        $run = $launcherSource.IndexOf("'run' {")
        $guard | Should -BeGreaterThan 0
        $guard | Should -BeLessThan $run
        foreach ($alias in @('-v','-d','-f','-st')) {
            $result = Invoke-UpdCommand $alias
            $result.ExitCode | Should -Not -Be 0
            $result.Text | Should -Match 'Short commands do not take a dash'
        }
    }

    It 'supports launcher/core recovery and focused AWS tooling updates' {
        $cmdSource | Should -Match '"%~1"=="repair"'
        $cmdSource | Should -Match 'Invoke-UpdLauncher\.ps1\.sha256'
        $launcherSource | Should -Match 'Get-UpdVersion -AllowUnknown'
        $launcherSource | Should -Match "'aws'\s*\{(?s:.*?)Repair-AwsTooling\.ps1"
    }

    It 'behaviorally adopts only a checksum- and version-matched staged batch' {
        $root = Join-Path $TestDrive 'adopt-good'
        $tools = Join-Path $root 'tools'
        $null = New-Item -ItemType Directory -Path $tools
        Copy-Item $launcherPath (Join-Path $tools 'Invoke-UpdLauncher.ps1')
        Copy-Item $invokePath (Join-Path $root 'Invoke-BootUpdateCycle.ps1')
        Copy-Item $cmdPath (Join-Path $root 'upd.cmd')
        Copy-Item $cmdPath (Join-Path $root 'upd.cmd.next')
        $hash = (Get-FileHash (Join-Path $root 'upd.cmd.next') -Algorithm SHA256).Hash
        Set-Content (Join-Path $root 'upd.cmd.next.sha256') $hash -NoNewline
        & pwsh -NoLogo -NoProfile -File (Join-Path $tools 'Invoke-UpdLauncher.ps1') adopt-staged-batch
        $LASTEXITCODE | Should -Be 0
        Test-Path (Join-Path $root 'upd.cmd.next') | Should -BeFalse
        Test-Path (Join-Path $root 'upd.cmd.next.sha256') | Should -BeFalse
    }

    It 'behaviorally rejects and removes a stale staged batch' {
        $root = Join-Path $TestDrive 'adopt-stale'
        $tools = Join-Path $root 'tools'
        $null = New-Item -ItemType Directory -Path $tools
        Copy-Item $launcherPath (Join-Path $tools 'Invoke-UpdLauncher.ps1')
        Copy-Item $invokePath (Join-Path $root 'Invoke-BootUpdateCycle.ps1')
        Copy-Item $cmdPath (Join-Path $root 'upd.cmd')
        $stale = (Get-Content $cmdPath -Raw) -replace 'BootUpdateCycleVersion=2\.5\.29','BootUpdateCycleVersion=1.0.0'
        Set-Content (Join-Path $root 'upd.cmd.next') $stale -NoNewline
        $hash = (Get-FileHash (Join-Path $root 'upd.cmd.next') -Algorithm SHA256).Hash
        Set-Content (Join-Path $root 'upd.cmd.next.sha256') $hash -NoNewline
        & pwsh -NoLogo -NoProfile -File (Join-Path $tools 'Invoke-UpdLauncher.ps1') adopt-staged-batch 2>$null
        $LASTEXITCODE | Should -Not -Be 0
        Test-Path (Join-Path $root 'upd.cmd.next') | Should -BeFalse
        Test-Path (Join-Path $root 'upd.cmd.next.sha256') | Should -BeFalse
    }
}

Describe 'Typed run option forwarding' {
    It 'exposes the documented deployment controls as typed parameters' {
        foreach ($parameter in @(
            'OutputMode','MaxIterations','PackageTimeoutMinutes','StagedRollout',
            'IncludeDriverUpdates','IncludeFirmwareUpdates','UpdateWsl','UpdateContainers',
            'AllowMetered','EnableRestorePoint','EnableDotnetTools','EnableAwsTooling',
            'SkipDefender','SkipBitLocker','DisableSelfUpdate','ExcludePatterns','IncludePatterns'
        )) {
            $deploySource | Should -Match ([regex]::Escape("`$$parameter"))
        }
    }

    It 'keeps structured pattern arrays and new switches in both direct and scheduled paths' {
        $deploySource | Should -Match 'IncludePatternsBase64'
        $deploySource | Should -Match 'ExcludePatternsBase64'
        foreach ($name in @('SkipDefender','IncludeDriverUpdates','UpdateWsl','UpdateContainers','AllowMetered','SkipBitLocker','DisableSelfUpdate')) {
            $deploySource | Should -Match ([regex]::Escape("Config.$name"))
        }
        $deploySource | Should -Match '-not \$Config\.DisableSelfUpdate'
        $deploySource | Should -Match '\$remoteVer -ge \$currentVer'
    }
}

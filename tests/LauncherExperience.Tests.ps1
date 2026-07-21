BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $cmdPath = Join-Path $repoRoot 'upd.cmd'
    $launcherPath = Join-Path $repoRoot 'tools\Invoke-UpdLauncher.ps1'
    $deployPath = Join-Path $repoRoot 'Deploy-BootUpdateCycle.ps1'
    $invokePath = Join-Path $repoRoot 'Invoke-BootUpdateCycle.ps1'
    $releasePath = Join-Path $repoRoot 'tools\New-Release.ps1'
    $ps7BootstrapPath = Join-Path $repoRoot 'tools\Install-PowerShell7.ps1'
    $argumentBootstrapPath = Join-Path $repoRoot 'tools\Invoke-UpdBootstrap.ps1'
    $compatInstallerPath = Join-Path $repoRoot 'tools\Install-UpdCompat.ps1'

    function Get-ParsedScript {
        param([Parameter(Mandatory)][string]$Path)
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
        $errors | Should -BeNullOrEmpty
        return $ast
    }

    $launcherAst = Get-ParsedScript $launcherPath
    $null = Get-ParsedScript $deployPath
    $null = Get-ParsedScript $invokePath
    $argumentBootstrapAst = Get-ParsedScript $argumentBootstrapPath
    $compatInstallerAst = Get-ParsedScript $compatInstallerPath
    $launcherSource = Get-Content -LiteralPath $launcherPath -Raw
    $deploySource = Get-Content -LiteralPath $deployPath -Raw
    $invokeSource = Get-Content -LiteralPath $invokePath -Raw
    $releaseSource = Get-Content -LiteralPath $releasePath -Raw
    $ps7BootstrapSource = Get-Content -LiteralPath $ps7BootstrapPath -Raw
    $argumentBootstrapSource = Get-Content -LiteralPath $argumentBootstrapPath -Raw
    $compatInstallerSource = Get-Content -LiteralPath $compatInstallerPath -Raw
    $cmdSource = Get-Content -LiteralPath $cmdPath -Raw

    function Invoke-UpdCommand {
        param([Parameter(Mandatory)][string]$Arguments)
        $output = & cmd.exe /d /c "`"$cmdPath`" $Arguments" 2>&1
        $text = [regex]::Replace(($output -join "`n"), "`e\[[0-9;]*m", '')
        return [pscustomobject]@{ ExitCode=$LASTEXITCODE; Text=$text }
    }
}

Describe 'Batch launcher file format' {
    It 'stores only CRLF line endings because cmd.exe misparses LF-only files' {
        $bytes = [IO.File]::ReadAllBytes($cmdPath)
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        $text | Should -Match "`r`n"
        $text.Replace("`r`n", '') | Should -Not -Match "`n"
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
        $result.Text | Should -Match 'upd bootstrap'
        $result.Text | Should -Match 'upd aws'
        $result.Text | Should -Match 'RUN OPTIONS'
    }

    It 'rejects an unknown command and points back to help' {
        $result = Invoke-UpdCommand 'definitely-not-a-command -nu'
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
        foreach ($asset in @('Invoke-BootUpdateCycle.ps1','Deploy-BootUpdateCycle.ps1','Invoke-UpdLauncher.ps1','Invoke-UpdBootstrap.ps1','Show-BootUpdateProgressDemo.ps1','Install-PowerShell7.ps1','Repair-AwsTooling.ps1','upd.cmd')) {
            $launcherSource | Should -Match ([regex]::Escape("Name='$asset'"))
        }
        $launcherSource | Should -Match '\$\(\$spec\.Name\)\.sha256'
        $launcherSource | Should -Match "expected -notmatch '\^\[0-9A-F\]\{64\}\$'"
        $launcherSource | Should -Match 'SHA256 mismatch'
    }

    It 'runs from a trampoline so the active batch is never the adoption target' {
        $launcherSource | Should -Match 'Name=''upd\.cmd''.*StageBatch=\$true'
        $cmdSource | Should -Match 'set "UPD_LAUNCHER=.*Invoke-UpdLauncher\.ps1"'
        $cmdSource | Should -Match 'set "UPD_BOOTSTRAP=.*Invoke-UpdBootstrap\.ps1"'
        $cmdSource | Should -Match '"%UPD_PWSH%" .*"%UPD_BOOTSTRAP_ACTIVE%" %\*'
        $cmdSource.IndexOf('set "UPD_EXIT=%errorlevel%"') | Should -BeLessThan $cmdSource.IndexOf('upd.cmd.next')
        $cmdSource | Should -Match 'UPD_TRAMPOLINE_ACTIVE'
        $cmdSource | Should -Match 'cmd\.exe /d /s /c ""%UPD_TRAMPOLINE_PATH%" %\*"\s*$'
        $cmdSource.TrimEnd() | Should -Match 'cmd\.exe /d /s /c ""%UPD_TRAMPOLINE_PATH%" %\*"$'
        $cmdSource | Should -Match 'set "UPD_ROOT=%UPD_ORIGINAL_ROOT%"'
        $deploySource | Should -Match '\$destination\.baseline'
        $deploySource | Should -Match 'verified and staged for delayed activation'
        $launcherSource | Should -Match 'Get-FileHash -LiteralPath \$staged'
        $launcherSource | Should -Match '\$stagedVersion -ne \$coreVersion'
        $launcherSource | Should -Match '\[IO\.File\]::Replace'
    }

    It 'publishes the complete executable bundle with sidecars' {
        foreach ($asset in @('Deploy-BootUpdateCycle.ps1','Invoke-BootUpdateCycle.ps1','upd.cmd','tools/Invoke-UpdLauncher.ps1','tools/Invoke-UpdBootstrap.ps1','tools/Install-UpdCompat.ps1','tools/Show-BootUpdateProgressDemo.ps1','tools/Install-PowerShell7.ps1','Repair-AwsTooling.ps1')) {
            $releaseSource | Should -Match ([regex]::Escape($asset))
        }
        $releaseSource | Should -Match '"\$name\.sha256"'
    }

    It 'preflights operational and unknown commands through an untyped stage zero' {
        $argumentBootstrapAst.ParamBlock | Should -BeNullOrEmpty
        $argumentBootstrapSource | Should -Match '\$rawArguments\s*=\s*@\(\$args\)'
        $argumentBootstrapSource | Should -Match "Invoke-UpdBootstrapLauncher -Arguments @\('update'\)"
        $argumentBootstrapSource | Should -Match 'Invoke-UpdBootstrapLauncher -Arguments \$rawArguments'
        $argumentBootstrapSource | Should -Match 'Start-Process .* -Verb RunAs'
        $argumentBootstrapSource | Should -Match 'Verified UPD preflight failed; the operational command was not dispatched'
        $argumentBootstrapSource | Should -Match '\$dispatchArguments\s*=\s*@\(''-BundlePreflighted''\)\s*\+\s*@\(\$rawArguments\)'
        $cmdSource | Should -Match 'Invoke-UpdBootstrap-verified-%RANDOM%-%RANDOM%\.ps1'
        $cmdSource | Should -Match 'Bootstrap checksum mismatch'
    }

    It 'keeps stable read-only commands local and provides an explicit offline escape hatch' {
        $argumentBootstrapSource | Should -Match 'Read-only commands must remain local'
        foreach ($command in @('help','version','plan','status','splash','demo','fun','bootstrap')) {
            $argumentBootstrapSource | Should -Match ([regex]::Escape("'$command'"))
        }
        foreach ($switch in @('-nu','--no-update','--disable-self-update')) {
            $argumentBootstrapSource | Should -Match ([regex]::Escape("'$switch'"))
        }
    }

    It 'behaviorally preserves raw argument boundaries through the no-update handoff' {
        $root = Join-Path $TestDrive 'raw-argv'
        $tools = Join-Path $root 'tools'
        $null = New-Item -ItemType Directory -Path $tools
        Copy-Item $argumentBootstrapPath (Join-Path $tools 'Invoke-UpdBootstrap.ps1')
        $capture = Join-Path $root 'argv.json'
        @'
$args | ConvertTo-Json -Compress | Set-Content -LiteralPath $env:UPD_TEST_ARGV -Encoding utf8
exit 23
'@ | Set-Content -LiteralPath (Join-Path $tools 'Invoke-UpdLauncher.ps1') -Encoding utf8
        $previous = $env:UPD_TEST_ARGV
        try {
            $env:UPD_TEST_ARGV = $capture
            & pwsh -NoProfile -File (Join-Path $tools 'Invoke-UpdBootstrap.ps1') `
                future-command -nu 'value with spaces' '--future-option'
            $LASTEXITCODE | Should -Be 23
            $captured = @(Get-Content -LiteralPath $capture -Raw | ConvertFrom-Json)
            $captured | Should -Be @('future-command','-nu','value with spaces','--future-option')
        } finally {
            $env:UPD_TEST_ARGV = $previous
        }
    }

    It 'behaviorally decodes the elevated argv envelope without flattening values' {
        $root = Join-Path $TestDrive 'encoded-argv'
        $tools = Join-Path $root 'tools'
        $null = New-Item -ItemType Directory -Path $tools
        Copy-Item $argumentBootstrapPath (Join-Path $tools 'Invoke-UpdBootstrap.ps1')
        $capture = Join-Path $root 'argv.json'
        @'
$args | ConvertTo-Json -Compress | Set-Content -LiteralPath $env:UPD_TEST_ARGV -Encoding utf8
exit 29
'@ | Set-Content -LiteralPath (Join-Path $tools 'Invoke-UpdLauncher.ps1') -Encoding utf8
        $original = @('help','value with spaces','--future-option')
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $original -Compress)))
        $previous = $env:UPD_TEST_ARGV
        try {
            $env:UPD_TEST_ARGV = $capture
            & pwsh -NoProfile -File (Join-Path $tools 'Invoke-UpdBootstrap.ps1') --stage0-encoded $encoded
            $LASTEXITCODE | Should -Be 29
            $captured = @(Get-Content -LiteralPath $capture -Raw | ConvertFrom-Json)
            $captured | Should -Be $original
        } finally {
            $env:UPD_TEST_ARGV = $previous
        }
    }

    It 'publishes a one-time compatibility installer for historical batch parsers' {
        $releaseSource | Should -Match "Source='tools/Install-UpdCompat\.ps1'"
        $compatInstallerSource | Should -Match 'Find-CompatUpdBatch'
        $compatInstallerSource | Should -Not -Match 'where\.exe upd'
        $compatInstallerSource | Should -Match 'Join-Path \$env:ProgramFiles ''BootUpdateCycle'''
        $compatInstallerSource | Should -Match 'SetEnvironmentVariable\(''Path'',\$newMachinePath,''Machine''\)'
        $compatInstallerSource | Should -Match 'boot-upd-compat-stage-'
        $compatInstallerSource | Should -Match 'boot-upd-compat-backup-'
        $compatInstallerSource | Should -Match 'Cloud/local sync changed'
        $compatInstallerSource | Should -Match '\[IO\.File\]::Replace'
        $compatInstallerSource | Should -Match '& \$targetBatch @CommandArguments'
        $compatInstallerSource | Should -Match 'Start-Process .* -Verb RunAs'
        $compatInstallerSource | Should -Match 'The first PATH winner is not upd\.cmd'
        $compatInstallerSource | Should -Match 'TimeoutSec 120'
        $compatInstallerSource | Should -Match 'Committed bundle verification failed'
        $releaseSource | Should -Match 'README compatibility command must pin'
        $readme = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw
        $readme | Should -Not -Match 'COMPAT_INSTALLER_SHA256'
        $readme | Should -Match (Get-FileHash -LiteralPath $compatInstallerPath -Algorithm SHA256).Hash
        $readme |
            Should -Match 'powershell\.exe -NoProfile -ExecutionPolicy Bypass.*releases/latest/download/Install-UpdCompat\.ps1'
        $readme | Should -Match '\[ScriptBlock\]::Create\(\(Invoke-RestMethod -UseBasicParsing.*Install-UpdCompat\.ps1'
        $readme | Should -Match 'Install-UpdCompat\.ps1''\)\)\) -PromptForArguments'
        $compatInstallerSource | Should -Match 'PromptForArguments=\[bool\]\$PromptForArguments'
        $compatInstallerSource.IndexOf("Write-Host 'The verified updater is ready") |
            Should -BeGreaterThan $compatInstallerSource.IndexOf('Committed bundle verification failed')
    }

    It 'coheres release versions and detects cloud races around every bundle commit' {
        $launcherSource | Should -Match 'core version does not match its tag'
        $launcherSource | Should -Match 'batch version does not match its tag'
        $launcherSource | Should -Match 'Local/cloud sync changed'
        $launcherSource | Should -Match 'Post-copy SHA256 mismatch'
        $launcherSource | Should -Match 'live upd\.cmd changed after staging'
        $launcherSource | Should -Match 'adopted upd\.cmd failed post-copy verification'
    }

    It 'does not repeat a completed preflight or violate aws no-update mode' {
        $launcherSource | Should -Match '\[Parameter\(DontShow\)\]\[switch\]\$BundlePreflighted'
        $launcherSource | Should -Match '''aws''\s*\{(?s:.*?)-not \$DisableSelfUpdate -and -not \$BundlePreflighted'
        $launcherSource | Should -Match '''run''\s*\{(?s:.*?)-not \$DisableSelfUpdate -and -not \$BundlePreflighted'
        $functionAst = $launcherAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-UpdCanonicalAwsArguments'
        },$true) | Select-Object -First 1
        Invoke-Expression $functionAst.Extent.Text
        @(Get-UpdCanonicalAwsArguments -DisableUpdate) | Should -Be @('aws','-DisableSelfUpdate')
        @(Get-UpdCanonicalAwsArguments -Preflighted) | Should -Be @('aws','-BundlePreflighted')
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
        $baseline = (Get-FileHash (Join-Path $root 'upd.cmd') -Algorithm SHA256).Hash
        Set-Content (Join-Path $root 'upd.cmd.next.baseline') $baseline -NoNewline
        $priorActive = $env:UPD_TRAMPOLINE_ACTIVE
        $priorPath = $env:UPD_TRAMPOLINE_PATH
        try {
            $env:UPD_TRAMPOLINE_ACTIVE = '1'
            $env:UPD_TRAMPOLINE_PATH = Join-Path $TestDrive 'proved-trampoline.cmd'
            & pwsh -NoLogo -NoProfile -File (Join-Path $tools 'Invoke-UpdLauncher.ps1') adopt-staged-batch
        } finally {
            $env:UPD_TRAMPOLINE_ACTIVE = $priorActive
            $env:UPD_TRAMPOLINE_PATH = $priorPath
        }
        $LASTEXITCODE | Should -Be 0
        Test-Path (Join-Path $root 'upd.cmd.next') | Should -BeFalse
        Test-Path (Join-Path $root 'upd.cmd.next.sha256') | Should -BeFalse
        Test-Path (Join-Path $root 'upd.cmd.next.baseline') | Should -BeFalse
    }

    It 'replaces the original launcher exactly once while executing from a spaced trampoline path' {
        $root = Join-Path $TestDrive 'live batch adoption with spaces'
        $tools = Join-Path $root 'tools'
        $null = New-Item -ItemType Directory -Path $tools
        Copy-Item $launcherPath (Join-Path $tools 'Invoke-UpdLauncher.ps1')
        Copy-Item $invokePath (Join-Path $root 'Invoke-BootUpdateCycle.ps1')
        $target = Join-Path $root 'upd.cmd'
        Copy-Item $cmdPath $target
        [IO.File]::AppendAllText($target, "`r`n:: intentionally old launcher bytes", [Text.UTF8Encoding]::new($false))
        Copy-Item $cmdPath "$target.next"
        $nextHash = (Get-FileHash "$target.next" -Algorithm SHA256).Hash
        Set-Content "$target.next.sha256" $nextHash -NoNewline
        Set-Content "$target.next.baseline" (Get-FileHash $target -Algorithm SHA256).Hash -NoNewline

        $output = & cmd.exe /d /c "`"$target`" help" 2>&1
        $exitCode = $LASTEXITCODE
        $text = $output -join "`n"

        $exitCode | Should -Be 0
        ([regex]::Matches($text, 'Updated upd\.cmd from the checksummed release bundle\.')).Count |
            Should -Be 1
        $text | Should -Not -Match 'The system cannot find the path specified|Terminate batch job'
        (Get-FileHash $target -Algorithm SHA256).Hash | Should -Be $nextHash
        Test-Path "$target.next" | Should -BeFalse
    }

    It 'does not trust an inherited trampoline marker when the invoked batch path differs' {
        $root = Join-Path $TestDrive 'inherited marker guard'
        $tools = Join-Path $root 'tools'
        $null = New-Item -ItemType Directory -Path $tools
        Copy-Item $cmdPath (Join-Path $root 'upd.cmd')
        @'
param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
"launcher reached: $($Arguments -join ' ')"
'@ | Set-Content -LiteralPath (Join-Path $tools 'Invoke-UpdLauncher.ps1') -Encoding utf8
        $priorActive = $env:UPD_TRAMPOLINE_ACTIVE
        $priorPath = $env:UPD_TRAMPOLINE_PATH
        try {
            $env:UPD_TRAMPOLINE_ACTIVE = '1'
            $env:UPD_TRAMPOLINE_PATH = Join-Path $TestDrive 'some-other-process.cmd'
            $output = & cmd.exe /d /c "`"$(Join-Path $root 'upd.cmd')`" help" 2>&1
            $LASTEXITCODE | Should -Be 0
            ($output -join "`n") | Should -Match 'launcher reached: help'
        } finally {
            $env:UPD_TRAMPOLINE_ACTIVE = $priorActive
            $env:UPD_TRAMPOLINE_PATH = $priorPath
        }
    }

    It 'bridges a pre-trampoline launcher without replacing the batch while cmd is reading it' {
        $root = Join-Path $TestDrive 'legacy 2543 bridge'
        $tools = Join-Path $root 'tools'
        $null = New-Item -ItemType Directory -Path $tools
        Copy-Item $launcherPath (Join-Path $tools 'Invoke-UpdLauncher.ps1')
        Copy-Item $invokePath (Join-Path $root 'Invoke-BootUpdateCycle.ps1')
        $target = Join-Path $root 'upd.cmd'
        @"
@echo off
:: BootUpdateCycleVersion=2.5.43
pwsh -NoLogo -NoProfile -File "$tools\Invoke-UpdLauncher.ps1" adopt-staged-batch
echo legacy caller returned cleanly
exit /b 0
"@ | Set-Content -LiteralPath $target -Encoding ascii
        Copy-Item $cmdPath "$target.next"
        $nextHash = (Get-FileHash "$target.next" -Algorithm SHA256).Hash
        Set-Content "$target.next.sha256" $nextHash -NoNewline
        Set-Content "$target.next.baseline" (Get-FileHash $target -Algorithm SHA256).Hash -NoNewline

        $output = & cmd.exe /d /c "`"$target`"" 2>&1
        $LASTEXITCODE | Should -Be 0
        ($output -join "`n") | Should -Match 'legacy caller returned cleanly'
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while ((Test-Path "$target.next") -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        Test-Path "$target.next" | Should -BeFalse
        (Get-FileHash $target -Algorithm SHA256).Hash | Should -Be $nextHash
        (Get-Content (Join-Path $root 'upd.cmd.adoption.log') -Raw) | Should -Match 'completed'
    }

    It 'behaviorally rejects and removes a stale staged batch' {
        $root = Join-Path $TestDrive 'adopt-stale'
        $tools = Join-Path $root 'tools'
        $null = New-Item -ItemType Directory -Path $tools
        Copy-Item $launcherPath (Join-Path $tools 'Invoke-UpdLauncher.ps1')
        Copy-Item $invokePath (Join-Path $root 'Invoke-BootUpdateCycle.ps1')
        Copy-Item $cmdPath (Join-Path $root 'upd.cmd')
        $stale = (Get-Content $cmdPath -Raw) -replace 'BootUpdateCycleVersion=\d+(?:\.\d+){2}','BootUpdateCycleVersion=1.0.0'
        Set-Content (Join-Path $root 'upd.cmd.next') $stale -NoNewline
        $hash = (Get-FileHash (Join-Path $root 'upd.cmd.next') -Algorithm SHA256).Hash
        Set-Content (Join-Path $root 'upd.cmd.next.sha256') $hash -NoNewline
        $baseline = (Get-FileHash (Join-Path $root 'upd.cmd') -Algorithm SHA256).Hash
        Set-Content (Join-Path $root 'upd.cmd.next.baseline') $baseline -NoNewline
        $priorActive = $env:UPD_TRAMPOLINE_ACTIVE
        $priorPath = $env:UPD_TRAMPOLINE_PATH
        try {
            $env:UPD_TRAMPOLINE_ACTIVE = '1'
            $env:UPD_TRAMPOLINE_PATH = Join-Path $TestDrive 'proved-trampoline.cmd'
            & pwsh -NoLogo -NoProfile -File (Join-Path $tools 'Invoke-UpdLauncher.ps1') adopt-staged-batch 2>$null
        } finally {
            $env:UPD_TRAMPOLINE_ACTIVE = $priorActive
            $env:UPD_TRAMPOLINE_PATH = $priorPath
        }
        $LASTEXITCODE | Should -Not -Be 0
        Test-Path (Join-Path $root 'upd.cmd.next') | Should -BeFalse
        Test-Path (Join-Path $root 'upd.cmd.next.sha256') | Should -BeFalse
        Test-Path (Join-Path $root 'upd.cmd.next.baseline') | Should -BeFalse
    }
}

Describe 'Windows PowerShell 5.1 bootstrap with PowerShell 7 parallel runtime' {
    It 'treats a missing upd PATH entry as a fresh install under Windows PowerShell 5.1' {
        $resolver = $compatInstallerAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Find-CompatUpdBatch'
        },$true) | Select-Object -First 1
        $resolver | Should -Not -BeNullOrEmpty

        $helperPath = Join-Path $TestDrive 'compat-path-resolver.ps1'
        $winnerRoot = Join-Path $TestDrive 'winner path with spaces'
        $emptyRoot = Join-Path $TestDrive 'empty path'
        $null = New-Item -ItemType Directory -Path $winnerRoot,$emptyRoot
        Set-Content -LiteralPath $helperPath -Value $resolver.Extent.Text -Encoding utf8
        Set-Content -LiteralPath (Join-Path $winnerRoot 'upd.cmd') -Value '@echo off' -Encoding ascii
        $probe = @"
. '$($helperPath.Replace("'","''"))'
`$env:Path = '$($emptyRoot.Replace("'","''"))'
if (`$null -ne (Find-CompatUpdBatch)) { exit 7 }
`$env:Path = '$($winnerRoot.Replace("'","''"))'
`$expected = [IO.Path]::GetFullPath((Join-Path `$env:Path 'upd.cmd'))
if ((Find-CompatUpdBatch) -ine `$expected) { exit 8 }
Set-Content -LiteralPath (Join-Path `$env:Path 'upd.exe') -Value 'shadow' -Encoding ascii
try { Find-CompatUpdBatch; exit 9 } catch {
    if (`$_.Exception.Message -notmatch 'first PATH winner is not upd.cmd') { exit 10 }
}
exit 0
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
        $LASTEXITCODE | Should -Be 0
    }

    It 'hashes assets without module autoloading under Windows PowerShell 5.1' {
        $hasher = $compatInstallerAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Get-CompatSha256'
        },$true) | Select-Object -First 1
        $hasher | Should -Not -BeNullOrEmpty
        $compatInstallerSource | Should -Not -Match '\bGet-FileHash\b'

        $helperPath = Join-Path $TestDrive 'compat-sha256.ps1'
        $fixturePath = Join-Path $TestDrive 'hash fixture.bin'
        Set-Content -LiteralPath $helperPath -Value $hasher.Extent.Text -Encoding utf8
        Set-Content -LiteralPath $fixturePath -Value 'boot-upd-vm-fixture' -NoNewline -Encoding ascii
        $expected = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash
        $probe = @"
`$PSModuleAutoLoadingPreference = 'None'
Remove-Module Microsoft.PowerShell.Utility -Force -ErrorAction SilentlyContinue
. '$($helperPath.Replace("'","''"))'
if ((Get-CompatSha256 -Path '$($fixturePath.Replace("'","''"))') -cne '$expected') { exit 7 }
exit 0
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
        $LASTEXITCODE | Should -Be 0
    }

    It 'safely preserves quoted post-install arguments under Windows PowerShell 5.1' {
        $converter = $compatInstallerAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'ConvertFrom-CompatCommandLine'
        },$true) | Select-Object -First 1
        $converter | Should -Not -BeNullOrEmpty

        $helperPath = Join-Path $TestDrive 'compat-command-line.ps1'
        Set-Content -LiteralPath $helperPath -Value $converter.Extent.Text -Encoding utf8
        $probe = @"
. '$($helperPath.Replace("'","''"))'
`$actual = @(ConvertFrom-CompatCommandLine -Line 'run --exclude "Teams, One Drive" --delay 120')
`$expected = @('run','--exclude','Teams, One Drive','--delay','120')
if (`$actual.Count -ne `$expected.Count) { exit 7 }
for (`$index=0; `$index -lt `$expected.Count; `$index++) {
    if (`$actual[`$index] -cne `$expected[`$index]) { exit 8 }
}
exit 0
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
        $output = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Windows PowerShell argument parser probe failed: $($output -join "`n")" }
        $LASTEXITCODE | Should -Be 0
    }

    It 'atomically replaces an existing file under Windows PowerShell 5.1 with a concrete backup path' {
        $replacer = $compatInstallerAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Set-CompatStagedFile'
        },$true) | Select-Object -First 1
        $replacer | Should -Not -BeNullOrEmpty

        $root = Join-Path $TestDrive 'replace path with spaces'
        $null = New-Item -ItemType Directory -Path $root
        $helperPath = Join-Path $root 'compat-replacer.ps1'
        $incoming = Join-Path $root 'target.ps1.incoming'
        $target = Join-Path $root 'target.ps1'
        $snapshot = Join-Path $root 'target.ps1.snapshot'
        Set-Content -LiteralPath $helperPath -Value $replacer.Extent.Text -Encoding utf8
        Set-Content -LiteralPath $incoming -Value 'new bytes' -NoNewline -Encoding ascii
        Set-Content -LiteralPath $target -Value 'old bytes' -NoNewline -Encoding ascii
        Set-Content -LiteralPath $snapshot -Value 'old bytes' -NoNewline -Encoding ascii

        $probe = @"
. '$($helperPath.Replace("'","''"))'
Set-CompatStagedFile -Incoming '$($incoming.Replace("'","''"))' -Target '$($target.Replace("'","''"))' -Snapshot '$($snapshot.Replace("'","''"))' -Existed `$true
if ((Get-Content -LiteralPath '$($target.Replace("'","''"))' -Raw) -ne 'new bytes') { exit 7 }
if (Test-Path -LiteralPath '$($incoming.Replace("'","''"))') { exit 8 }
if (Get-ChildItem -LiteralPath '$($root.Replace("'","''"))' -Filter '*.file-replace-*') { exit 9 }
exit 0
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
        $output = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Windows PowerShell replacement probe failed: $($output -join "`n")" }
        $LASTEXITCODE | Should -Be 0
    }

    It 'does not feed checksum-verified PowerShell 7 assets to the PowerShell 5 parser' {
        $validator = $compatInstallerAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Test-CompatPowerShellAsset'
        },$true) | Select-Object -First 1
        $validator | Should -Not -BeNullOrEmpty

        $helperPath = Join-Path $TestDrive 'compat-validator.ps1'
        $ps7Path = Join-Path $TestDrive 'valid-ps7.ps1'
        $unmarkedPs7Path = Join-Path $TestDrive 'unmarked-ps7.ps1'
        $brokenPs5Path = Join-Path $TestDrive 'broken-ps5.ps1'
        Set-Content -LiteralPath $helperPath -Value $validator.Extent.Text -Encoding utf8
        Set-Content -LiteralPath $ps7Path -Value "#requires -Version 7.0`n`$value = `$null ?? 'valid'" -Encoding utf8
        Set-Content -LiteralPath $unmarkedPs7Path -Value "`$value = `$null ?? 'unmarked'" -Encoding utf8
        Set-Content -LiteralPath $brokenPs5Path -Value "#requires -Version 5.1`ntry { 'broken' }" -Encoding utf8

        $probe = @"
. '$($helperPath.Replace("'","''"))'
Test-CompatPowerShellAsset -Path '$($invokePath.Replace("'","''"))' -Name 'Invoke-BootUpdateCycle.ps1' -RequiredMajor 7
`$env:PATH = ''
Test-CompatPowerShellAsset -Path '$($ps7Path.Replace("'","''"))' -Name 'valid-ps7.ps1' -RequiredMajor 7
`$unmarkedRejected = `$false
try {
    Test-CompatPowerShellAsset -Path '$($unmarkedPs7Path.Replace("'","''"))' -Name 'unmarked-ps7.ps1' -RequiredMajor 7
} catch {
    `$unmarkedRejected = `$_.Exception.Message -match 'runtime declaration is missing'
}
if (-not `$unmarkedRejected) { exit 8 }
`$brokenRejected = `$false
try {
    Test-CompatPowerShellAsset -Path '$($brokenPs5Path.Replace("'","''"))' -Name 'broken-ps5.ps1' -RequiredMajor 5
} catch {
    `$brokenRejected = `$_.Exception.Message -match 'PowerShell parse error'
}
if (-not `$brokenRejected) { exit 9 }
exit 0
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
        $output = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Windows PowerShell validator probe failed: $($output -join "`n")" }
        $LASTEXITCODE | Should -Be 0
    }

    It 'runs its no-op installed-runtime path under Windows PowerShell' {
        $output = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $ps7BootstrapPath 2>&1
        $LASTEXITCODE | Should -Be 0
        ($output -join "`n") | Should -Match 'pwsh\.exe'
    }

    It 'uses supported install routes and validates the MSI publisher' {
        $ps7BootstrapSource | Should -Match '#requires -Version 5\.1'
        $ps7BootstrapSource | Should -Match "'Microsoft\.PowerShell'"
        $ps7BootstrapSource | Should -Match 'PowerShell/PowerShell/releases\?per_page=20'
        $ps7BootstrapSource | Should -Match 'Get-AuthenticodeSignature'
        $ps7BootstrapSource | Should -Match "Status -ne 'Valid'"
        $ps7BootstrapSource | Should -Match 'O=Microsoft Corporation'
        $ps7BootstrapSource | Should -Match '3010'
    }

    It 'keeps read-only commands ahead of automatic runtime installation' {
        $pwshCheck = $cmdSource.IndexOf('if defined UPD_PWSH goto runtime_ready')
        $help = $cmdSource.IndexOf('goto ps5_help')
        $bootstrapCall = $cmdSource.IndexOf('-File "%UPD_PS7_BOOTSTRAP%"')
        $pwshCheck | Should -BeGreaterThan 0
        $help | Should -BeGreaterThan $pwshCheck
        $help | Should -BeLessThan $bootstrapCall
        $cmdSource | Should -Match ':ps7_required(?s:.*?)no changes were made'
    }

    It 'behaviorally keeps help/version non-mutating when pwsh is unavailable' {
        $findLabel = $cmdSource.LastIndexOf(':find_pwsh')
        $findLabel | Should -BeGreaterThan 0
        $simulated = $cmdSource.Substring(0,$findLabel) + ":find_pwsh`r`nset `"UPD_PWSH=`"`r`nexit /b 0`r`n"
        $simulated = $simulated -replace '(?m)^if not defined UPD_TRAMPOLINE_ACTIVE goto trampoline_wrapper\r?\n',''
        $simulated = $simulated -replace '(?m)^if /i "%~f0"=="%UPD_TRAMPOLINE_PATH%" goto trampoline_active\r?\n',''
        $simulated = $simulated -replace '(?m)^goto trampoline_wrapper\r?\n',''
        $simulatedPath = Join-Path $TestDrive 'upd-ps5-only.cmd'
        Set-Content -LiteralPath $simulatedPath -Value ($simulated -split '\r?\n') -Encoding ascii

        $help = & cmd.exe /d /c "`"$simulatedPath`" help" 2>&1
        $LASTEXITCODE | Should -Be 0
        ($help -join "`n") | Should -Match 'Help is read-only'

        $version = & cmd.exe /d /c "`"$simulatedPath`" v" 2>&1
        $LASTEXITCODE | Should -Be 0
        $bundledVersion = [regex]::Match($cmdSource,'(?m)^:: BootUpdateCycleVersion=([\d.]+)\s*$').Groups[1].Value
        $bundledVersion | Should -Not -BeNullOrEmpty
        ($version -join "`n") | Should -Match "v$([regex]::Escape($bundledVersion)).*runtime not installed"

        $demo = & cmd.exe /d /c "`"$simulatedPath`" demo" 2>&1
        $LASTEXITCODE | Should -Be 2
        ($demo -join "`n") | Should -Match 'no changes were made'
    }

    It 'retains the PowerShell 7-only parallel orchestration engine' {
        $invokeSource | Should -Match '^#requires -Version 7\.0'
        $invokeSource | Should -Match 'Start-ThreadJob'
        $invokeSource | Should -Match 'ForEach-Object -Parallel'
        $invokeSource | Should -Match 'Join-Path \$env:ProgramFiles ''PowerShell\\7\\pwsh\.exe'''
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

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
    $ps7BootstrapAst = Get-ParsedScript $ps7BootstrapPath
    $launcherSource = Get-Content -LiteralPath $launcherPath -Raw
    $deploySource = Get-Content -LiteralPath $deployPath -Raw
    $invokeSource = Get-Content -LiteralPath $invokePath -Raw
    $releaseSource = Get-Content -LiteralPath $releasePath -Raw
    $ps7BootstrapSource = Get-Content -LiteralPath $ps7BootstrapPath -Raw
    $argumentBootstrapSource = Get-Content -LiteralPath $argumentBootstrapPath -Raw
    $compatInstallerSource = Get-Content -LiteralPath $compatInstallerPath -Raw
    $cmdSource = Get-Content -LiteralPath $cmdPath -Raw

    function Get-FunctionText {
        param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$Name)
        $function = $Ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        },$true)
        $function | Should -Not -BeNullOrEmpty
        return $function.Extent.Text
    }

    foreach ($name in @('Get-PowerShell7LatestStableVersion','Get-PowerShell7UpgradeDecision','ConvertFrom-PowerShell7HashFile','Select-PowerShell7LegacyEntry')) {
        . ([scriptblock]::Create((Get-FunctionText -Ast $ps7BootstrapAst -Name $name)))
    }

    function Invoke-UpdCommand {
        param([Parameter(Mandatory)][string]$Arguments)
        $output = & cmd.exe /d /c "`"$cmdPath`" $Arguments" 2>&1
        $text = [regex]::Replace(($output -join "`n"), "`e\[[0-9;]*m", '')
        return [pscustomobject]@{ ExitCode=$LASTEXITCODE; Text=$text }
    }
}

Describe 'Legacy adoption terminal record ordering' {
    It 'never overwrites a worker that finishes before Start-Process returns' {
        $script:RaceAdoptionLog=Join-Path $TestDrive 'upd.cmd.adoption.log'
        Mock Start-Process { Set-Content -LiteralPath $script:RaceAdoptionLog -Value 'Legacy launcher adoption completed.' }
        $functionText=Get-FunctionText -Ast $launcherAst -Name 'Start-UpdLegacyBatchAdoption'
        & {
            param($repoRoot,$definition)
            . ([scriptblock]::Create($definition))
            Start-UpdLegacyBatchAdoption
        } $TestDrive $functionText
        Get-Content -LiteralPath $script:RaceAdoptionLog -Raw | Should -Match 'completed'
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
        $result.Text | Should -Match 'Updates and repairs may request admin rights'
        $result.Text | Should -Match 'Help, plan, status, version, and previews do not'
        $result.Text | Should -Match 'Install PowerShell 7 if missing; otherwise upgrade it to the latest stable'
        $result.Text | Should -Match '--max-retry-passes <n>'
    }

    It 'rejects an unknown command and points back to help' {
        $result = Invoke-UpdCommand 'definitely-not-a-command -nu'
        $result.ExitCode | Should -Not -Be 0
        $result.Text | Should -Match "Unknown command 'definitely-not-a-command'"
        $result.Text | Should -Match 'upd help'
    }

    It 'describes the no-progress limit and reports total and stalled reboots in status' {
        $result = Invoke-UpdCommand 'help'
        $result.Text | Should -Match 'Consecutive reboots without verified progress; default 5'
        $statusText = Get-FunctionText -Ast $launcherAst -Name 'Show-UpdStatus'
        $statusText | Should -Match 'reboots .*RebootCount.*stalled .*NoProgressRebootCount'
        $statusText | Should -Not -Match 'iteration .*MaxIterations'
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
        $result = Invoke-UpdCommand 'plan --delay 120 --drivers --firmware --wsl --containers --allow-metered --restore-point --dotnet-tools --aws-tooling --skip-office365 --skip-ssms --output-mode Verbose --max-iterations 7 --max-retry-passes 9 --timeout 45 --exclude Teams,OneDrive --include Git'
        $result.ExitCode | Should -Be 0
        $result.Text | Should -Match 'RebootDelaySec\s+: 120'
        $result.Text | Should -Match 'IncludeDriverUpdates\s+: True'
        $result.Text | Should -Match 'EnableDotnetTools\s+: True'
        $result.Text | Should -Match 'SkipSsms\s+: True'
        $result.Text | Should -Match 'OutputMode\s+: Verbose'
        $result.Text | Should -Match 'MaxRetryPasses\s+: 9'
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

    It 'surfaces durable Winget quarantine and its undo command in status' {
        $launcherSource | Should -Match 'BootUpdateCycle-winget-quarantine\.json'
        $launcherSource | Should -Match 'winget quarantine active'
        $launcherSource | Should -Match 'UnpinCommand'
        $launcherSource | Should -Match "'uq'='unquarantine'"
        $launcherSource | Should -Match 'wingetPath pin remove --id \$record\.PackageId -e --disable-interactivity'
        $launcherSource | Should -Match 'its record was retained'
        $launcherSource | Should -Match 'Remove-Item -LiteralPath \$path -Force'
    }
}

Describe 'Checksummed launcher self-update handoff' {
    It 'requires checksum sidecars for every executable bundle asset' {
        foreach ($asset in @('Invoke-BootUpdateCycle.ps1','Deploy-BootUpdateCycle.ps1','Invoke-UpdLauncher.ps1','Invoke-UpdBootstrap.ps1','Show-BootUpdateProgressDemo.ps1','Install-PowerShell7.ps1','Repair-AwsTooling.ps1','Export-BootUpdateDiagnostics.ps1','upd.cmd')) {
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
        foreach ($asset in @('Deploy-BootUpdateCycle.ps1','Invoke-BootUpdateCycle.ps1','upd.cmd','tools/Invoke-UpdLauncher.ps1','tools/Invoke-UpdBootstrap.ps1','tools/Install-UpdCompat.ps1','tools/Show-BootUpdateProgressDemo.ps1','tools/Install-PowerShell7.ps1','Repair-AwsTooling.ps1','Export-BootUpdateDiagnostics.ps1')) {
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
        foreach ($command in @('help','version','plan','status','logs','splash','demo','fun','bootstrap')) {
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

    It 'exports sanitized logs and captures standalone AWS maintenance output' {
        $launcherSource | Should -Match "'l'='logs'"
        $launcherSource | Should -Match "'logs'\s*\{"
        $launcherSource | Should -Match '\$diagnosticsPath'
        $launcherSource | Should -Match 'BootUpdateCycle\.aws\.log'
        $launcherSource | Should -Match 'Start-Transcript'
        $launcherSource | Should -Match 'Invoke-UpdAwsLogMaintenance'
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
        $adoptionLog = Join-Path $root 'upd.cmd.adoption.log'
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            $completed = (Test-Path $adoptionLog) -and
                ((Get-Content $adoptionLog -Raw) -match 'completed')
            if (-not $completed) { Start-Sleep -Milliseconds 100 }
        } while (-not $completed -and [DateTime]::UtcNow -lt $deadline)
        Test-Path "$target.next" | Should -BeFalse
        (Get-FileHash $target -Algorithm SHA256).Hash | Should -Be $nextHash
        (Get-Content $adoptionLog -Raw) | Should -Match 'completed'
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

    It 'uses the supported MSIX route and validates the bundle publisher' {
        $ps7BootstrapSource | Should -Match '#requires -Version 5\.1'
        $ps7BootstrapSource | Should -Match "'Microsoft\.PowerShell'"
        $ps7BootstrapSource | Should -Match 'PowerShell/PowerShell/releases\?per_page=30'
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

Describe 'upd bootstrap upgrades an installed PowerShell 7' {
    It 'never downgrades and only reports an upgrade when installed is behind latest' {
        (Get-PowerShell7UpgradeDecision -InstalledVersion '7.4.5' -LatestVersion '7.4.6').NeedsUpgrade | Should -BeTrue
        (Get-PowerShell7UpgradeDecision -InstalledVersion '7.4.6' -LatestVersion '7.4.6').NeedsUpgrade | Should -BeFalse
        (Get-PowerShell7UpgradeDecision -InstalledVersion '7.4.6' -LatestVersion '7.4.6').Message |
            Should -Be 'PowerShell 7.4.6 is already the latest stable release.'
        (Get-PowerShell7UpgradeDecision -InstalledVersion '7.5.0' -LatestVersion '7.4.6').NeedsUpgrade | Should -BeFalse
    }

    It 'treats any non-MSIX PowerShell 7 as needing the move to MSIX, whatever its version' {
        $decision = Get-PowerShell7UpgradeDecision -InstalledVersion '7.6.10' -LatestVersion '7.7.0' -Legacy
        $decision.NeedsUpgrade | Should -BeTrue
        $decision.Message | Should -Match 'MSI install, which Microsoft no longer ships'
        (Get-PowerShell7UpgradeDecision -InstalledVersion '7.8.0' -LatestVersion '7.7.0' -Legacy).NeedsUpgrade | Should -BeTrue
    }

    It 'picks the highest stable version that has an MSIX bundle and checksums, not the first listed' {
        <# 2026-11-10: 7.6.10 was published beside 7.7.0. The old MSI lookup took the first
           release with an MSI, which was 7.6.10, so 7.7 was never offered. #>
        Mock -CommandName Invoke-RestMethod -MockWith {
            $hashes = [pscustomobject]@{ name='hashes.sha256'; browser_download_url='https://example.invalid/hashes' }
            @(
                [pscustomobject]@{ draft=$false; prerelease=$false; tag_name='v7.6.10'; assets=@(
                    [pscustomobject]@{ name='PowerShell-7.6.10-win-x64.msi'; browser_download_url='https://example.invalid/7610.msi' }
                    [pscustomobject]@{ name='PowerShell-7.6.10.msixbundle'; browser_download_url='https://example.invalid/7610.msixbundle' }
                    $hashes
                ) }
                [pscustomobject]@{ draft=$false; prerelease=$false; tag_name='v7.7.0'; assets=@(
                    [pscustomobject]@{ name='PowerShell-7.7.0-win-x64.zip'; browser_download_url='https://example.invalid/770.zip' }
                    [pscustomobject]@{ name='PowerShell-7.7.0.msixbundle'; browser_download_url='https://example.invalid/770.msixbundle' }
                    $hashes
                ) }
            )
        }
        $latest = Get-PowerShell7LatestStableVersion
        $latest.Version | Should -Be ([version]'7.7.0')
        $latest.Asset.name | Should -Be 'PowerShell-7.7.0.msixbundle'
        $latest.HashAsset.name | Should -Be 'hashes.sha256'
    }

    It 'skips drafts, prereleases and releases missing the bundle or the checksum file' {
        Mock -CommandName Invoke-RestMethod -MockWith {
            $hashes = [pscustomobject]@{ name='hashes.sha256'; browser_download_url='https://example.invalid/hashes' }
            @(
                [pscustomobject]@{ draft=$false; prerelease=$true; tag_name='v7.8.0-preview.1'; assets=@(
                    [pscustomobject]@{ name='PowerShell-7.8.0-preview.1.msixbundle'; browser_download_url='https://example.invalid/p.msixbundle' }; $hashes) }
                [pscustomobject]@{ draft=$true; prerelease=$false; tag_name='v7.7.2'; assets=@(
                    [pscustomobject]@{ name='PowerShell-7.7.2.msixbundle'; browser_download_url='https://example.invalid/d.msixbundle' }; $hashes) }
                [pscustomobject]@{ draft=$false; prerelease=$false; tag_name='v7.7.1'; assets=@(
                    [pscustomobject]@{ name='PowerShell-7.7.1.msixbundle'; browser_download_url='https://example.invalid/nohash.msixbundle' }) }
                [pscustomobject]@{ draft=$false; prerelease=$false; tag_name='v7.7.0'; assets=@(
                    [pscustomobject]@{ name='PowerShell-7.7.0.msixbundle'; browser_download_url='https://example.invalid/ok.msixbundle' }; $hashes) }
            )
        }
        (Get-PowerShell7LatestStableVersion).Version | Should -Be ([version]'7.7.0')
    }

    It 'finds the newest MSI for Windows that cannot take the MSIX, which is the 7.6 line' {
        Mock -CommandName Invoke-RestMethod -MockWith {
            $hashes = [pscustomobject]@{ name='hashes.sha256'; browser_download_url='https://example.invalid/hashes' }
            @(
                [pscustomobject]@{ draft=$false; prerelease=$false; tag_name='v7.7.0'; assets=@(
                    [pscustomobject]@{ name='PowerShell-7.7.0.msixbundle'; browser_download_url='https://example.invalid/770.msixbundle' }; $hashes) }
                [pscustomobject]@{ draft=$false; prerelease=$false; tag_name='v7.6.10'; assets=@(
                    [pscustomobject]@{ name='PowerShell-7.6.10-win-arm64.msi'; browser_download_url='https://example.invalid/arm.msi' }
                    [pscustomobject]@{ name='PowerShell-7.6.10-win-x64.msi'; browser_download_url='https://example.invalid/x64.msi' }; $hashes) }
                [pscustomobject]@{ draft=$false; prerelease=$false; tag_name='v7.5.13'; assets=@(
                    [pscustomobject]@{ name='PowerShell-7.5.13-win-x64.msi'; browser_download_url='https://example.invalid/7513.msi' }) }
            )
        }
        $latest = Get-PowerShell7LatestStableVersion -Package Msi -Architecture x64
        $latest.Version | Should -Be ([version]'7.6.10')
        $latest.Package | Should -Be 'Msi'
        $latest.Asset.name | Should -Be 'PowerShell-7.6.10-win-x64.msi'
        $ps7BootstrapSource | Should -Match "if \(\[Environment\]::OSVersion\.Version\.Build -lt 17763\) \{ return \`$false \}"
        $ps7BootstrapSource | Should -Match "InstallationType -ne 'Server Core'"
    }

    It 'reads the bundle hash from the release checksum file' {
        $text = "7c74e03b20a75b59715847439d046a6214b1863ee79b187872980f139bb4a05f *PowerShell-7.7.0-win-x64.zip`r`n" +
                "e00c349858c2d273f29485541ece91617b435accdd5e3f156d68d5cb97740022 *PowerShell-7.7.0.msixbundle`r`n"
        ConvertFrom-PowerShell7HashFile -Text $text -FileName 'PowerShell-7.7.0.msixbundle' |
            Should -Be 'E00C349858C2D273F29485541ECE91617B435ACCDD5E3F156D68D5CB97740022'
        { ConvertFrom-PowerShell7HashFile -Text $text -FileName 'PowerShell-7.7.1.msixbundle' } | Should -Throw '*no entry*'
    }

    It 'finds the deprecated MSI and its Microsoft Update bundle, bundle first, and nothing else' {
        $entries = @(
            [pscustomobject]@{ PSChildName='{5417B253-1A6D-4638-BC94-743A6EC2E6F4}'; DisplayName='PowerShell 7-x64'; DisplayVersion='7.6.9.0'; WindowsInstaller=1; UninstallString='MsiExec.exe /X{5417B253-1A6D-4638-BC94-743A6EC2E6F4}' }
            [pscustomobject]@{ PSChildName='{2f3d8eae-0153-446e-8adf-1a3ef35c591f}'; DisplayName='PowerShell 7.6.9.0-x64'; DisplayVersion='7.6.9.0'; WindowsInstaller=$null; UninstallString='"C:\ProgramData\Package Cache\{2f3d8eae-0153-446e-8adf-1a3ef35c591f}\PowerShell-7.6.9-win-x64.exe"  /uninstall' }
            [pscustomobject]@{ PSChildName='{11111111-2222-3333-4444-555555555555}'; DisplayName='PowerShell 7-preview-x64'; DisplayVersion='7.7.0.5'; WindowsInstaller=1; UninstallString='MsiExec.exe /X{11111111-2222-3333-4444-555555555555}' }
            [pscustomobject]@{ PSChildName='Example'; DisplayName='Example App'; DisplayVersion='1.0'; WindowsInstaller=1; UninstallString='MsiExec.exe /X{x}' }
        )
        $legacy = @(Select-PowerShell7LegacyEntry -Entries $entries)
        $legacy.Count | Should -Be 2
        $legacy[0].Kind | Should -Be 'Bundle'
        $legacy[1].Kind | Should -Be 'Msi'
        $legacy[1].ProductCode | Should -Be '{5417B253-1A6D-4638-BC94-743A6EC2E6F4}'
    }

    It 'keeps the byte-for-byte early exit when -Upgrade is absent' {
        $ps7BootstrapSource | Should -Match '\[switch\]\$Upgrade'
        $ps7BootstrapSource | Should -Match '\$existing = Get-PowerShell7Path\r?\nif \(\$existing -and -not \$Upgrade\) \{ Write-Output \$existing; exit 0 \}'
    }

    It 'never takes a prerelease and never downgrades, per the release-check source' {
        $ps7BootstrapSource | Should -Match 'release\.draft -or \$release\.prerelease'
        $ps7BootstrapSource | Should -Match '\$InstalledVersion -ge \$LatestVersion'
    }

    It 'fails open when the GitHub release check cannot be reached' {
        $ps7BootstrapSource | Should -Match 'Write-Warning "Could not check the latest PowerShell release: \$\(\$_\.Exception\.Message\)"'
        $ps7BootstrapSource | Should -Match '(?s)catch \{\s*Write-Warning "Could not check the latest PowerShell release:.*?exit 0\s*\}'
    }

    It 'reuses the elevation relaunch and carries -Upgrade across it' {
        $ps7BootstrapSource | Should -Match "if \(\`$Upgrade\) \{ \`$arguments \+= ' -Upgrade' \}"
        $ps7BootstrapSource.IndexOf("if (`$Upgrade) { `$arguments += ' -Upgrade' }") |
            Should -BeGreaterThan $ps7BootstrapSource.IndexOf('-Elevated" -f $PSCommandPath')
    }

    It 'installs only the machine-wide MSIX, from both the fresh-install and upgrade routes' {
        <# Source shape by necessity: provisioning and msiexec cannot run in a unit test. #>
        ($ps7BootstrapSource | Select-String -Pattern 'Complete-PowerShell7Install -Release' -AllMatches).Matches.Count |
            Should -Be 2
        $ps7BootstrapSource | Should -Match 'Add-AppxProvisionedPackage -Online -PackagePath \$bundlePath -SkipLicense'
        $ps7BootstrapSource | Should -Match 'Add-AppxPackage -Path \$bundlePath -DeferRegistrationWhenPackagesAreInUse'
        $ps7BootstrapSource | Should -Not -Match 'ForceApplicationShutdown|ForceTargetApplicationShutdown'
        <# WinGet is no longer an install route: for 7.7 it installs a per-user MSIX only. The
           MSI survives solely as the fallback inside Install-PowerShell7FromMsi. #>
        $ps7BootstrapSource | Should -Not -Match "--installer-type|'install','--id'|'upgrade','--id'|winget\.exe|\`$winget"
        ([regex]::Matches($ps7BootstrapSource, "'/i'")).Count | Should -Be 1
        $ps7BootstrapSource | Should -Match "(?s)if \(\`$Release\.Package -eq 'Msi'\) \{.*?Install-PowerShell7FromMsi -Release \`$Release"
        ([regex]::Matches($ps7BootstrapSource, 'Install-PowerShell7FromMsi -Release')).Count | Should -Be 1
        $ps7BootstrapSource | Should -Match 'Get-FileHash -LiteralPath \$bundlePath -Algorithm SHA256'
    }

    It 'removes the old MSI only after the MSIX starts, with Restart Manager off' {
        $ps7BootstrapSource | Should -Match '(?s)function Complete-PowerShell7Install.*?Install-PowerShell7Msix -Release.*?Remove-PowerShell7LegacyInstall'
        $ps7BootstrapSource | Should -Match '(?s)function Install-PowerShell7Msix.*?Get-PowerShell7InstalledVersion -PwshPath \$installed\.PwshPath'
        $ps7BootstrapSource | Should -Match 'MSIRESTARTMANAGERCONTROL=Disable'
        $ps7BootstrapSource | Should -Match "'/x', \`$entry\.ProductCode, '/qn', '/norestart'"
    }

    It 'never changes the runtime under a running cycle and reports a check with exit 100' {
        $ps7BootstrapSource | Should -Match "Get-ScheduledTask -TaskName 'BootUpdateCycle','BootUpdateCycleFallback'"
        $ps7BootstrapSource | Should -Match '(?s)if \(Test-BootUpdateCycleActive\) \{.*?exit 3'
        $ps7BootstrapSource.IndexOf('if (Test-BootUpdateCycleActive) {') |
            Should -BeLessThan $ps7BootstrapSource.IndexOf('$installed = Complete-PowerShell7Install -Release $latest')
        $ps7BootstrapSource | Should -Match 'if \(\$CheckOnly\) \{'
        $ps7BootstrapSource | Should -Match 'exit 100'
        $ps7BootstrapSource | Should -Match "PowerShell \`$installedVersion -> \`$\(\`$installed\.Version\) installed\."
    }

    It 'starts the upgrade after a verified completion, never during a preview or a pass' {
        $completion = [regex]::Match($invokeSource, '(?s)Terminal cleanup verification failed.*?Send-CompletionNotification').Value
        $completion | Should -Match 'Start-PowerShellRuntimeUpgrade'
        $invokeSource | Should -Match "'-Upgrade', '-WaitForProcessId', \`$PID"
        ([regex]::Matches($invokeSource, '(?m)^\s*Start-PowerShellRuntimeUpgrade\s*$')).Count | Should -Be 1
        $deploySource | Should -Match "Join-Path \`$installDir 'Install-PowerShell7\.ps1'"
    }

    It 'invokes the bootstrap script with -Upgrade from the launcher''s bootstrap command' {
        $bootstrapCommand = [regex]::Match($launcherSource, "(?s)'bootstrap'\s*\{.*?\n    \}")
        $bootstrapCommand.Success | Should -BeTrue
        $help = Invoke-UpdCommand 'help'
        $help.Text | Should -Match 'Install PowerShell 7 if missing; otherwise upgrade it to the latest stable'
        $bootstrapCommand.Value | Should -Match 'WindowsPowerShell\\v1\.0\\powershell\.exe'
        $bootstrapCommand.Value | Should -Match "'-Upgrade', '-CheckOnly'"
        $bootstrapCommand.Value | Should -Match 'if \(\$check\.ExitCode -ne 100\) \{ exit \$check\.ExitCode \}'
        $bootstrapCommand.Value | Should -Match '-WindowStyle Hidden'
        $bootstrapCommand.Value | Should -Match '-RedirectStandardOutput \$upgradeLog -RedirectStandardError \$upgradeErrorLog'
        $bootstrapCommand.Value | Should -Not -Match '&\s*\$ps7BootstrapPath'
        $bootstrapCommand.Value | Should -Not -Match '-Wait[^\r\n]*-Upgrade''\)\s*$'
    }
}

Describe 'Typed run option forwarding' {
    It 'exposes the documented deployment controls as typed parameters' {
        foreach ($parameter in @(
            'OutputMode','MaxIterations','MaxRetryPasses','PackageTimeoutMinutes','StagedRollout','AggressiveRepair',
            'IncludeDriverUpdates','IncludeFirmwareUpdates','SkipFeatureUpdates','FeatureUpdateTimeoutMinutes','UpdateWsl','UpdateContainers',
            'AllowMetered','EnableRestorePoint','EnableDotnetTools','EnableAwsTooling',
            'SkipSsms','SkipDefender','SkipBitLocker','DisableSelfUpdate','ResumeAfterAttention','ExcludePatterns','IncludePatterns'
        )) {
            $deploySource | Should -Match ([regex]::Escape("`$$parameter"))
        }
    }

    It 'keeps structured pattern arrays and new switches in both direct and scheduled paths' {
        $deploySource | Should -Match 'IncludePatternsBase64'
        $deploySource | Should -Match 'ExcludePatternsBase64'
        foreach ($name in @('SkipSsms','SkipDefender','SkipFeatureUpdates','IncludeDriverUpdates','UpdateWsl','UpdateContainers','AllowMetered','SkipBitLocker','DisableSelfUpdate','AggressiveRepair')) {
            $deploySource | Should -Match ([regex]::Escape("Config.$name"))
        }
        $deploySource | Should -Match ([regex]::Escape('FeatureUpdateTimeoutMinutes = $Config.FeatureUpdateTimeoutMin'))
        $deploySource | Should -Match ([regex]::Escape('"-FeatureUpdateTimeoutMinutes $($Config.FeatureUpdateTimeoutMin)"'))
        $deploySource | Should -Match 'ResumeAfterAttention = \$ResumeAfterAttention'
        $deploySource | Should -Match '-not \$Config\.DisableSelfUpdate'
        $deploySource | Should -Match '\$remoteVer -ge \$currentVer'
        $launcherSource | Should -Match "Alias\('ar','aggressive-repair'\)"
        $launcherSource | Should -Match "Alias\('no-ssms','skip-ssms'\)"
    }

    It 'honors an explicit false SkipSsms deployment value instead of treating its presence as true' {
        $deploySource | Should -Match 'PSBoundParameters\.ContainsKey\(''SkipSsms''\).*Config\.SkipSsms\s*=\s*\[bool\]\$SkipSsms'
        $deploySource | Should -Not -Match 'foreach \(\$name in @\([^)]*''SkipSsms'''
        (Get-FunctionText -Ast $launcherAst -Name 'Get-UpdDeployParameters') | Should -Match "SkipSsms='SkipSsms'"
        (Get-FunctionText -Ast $launcherAst -Name 'Get-UpdDeployParameters') | Should -Match 'ResumeAfterAttention=''ResumeAfterAttention'''
    }
}

Describe 'PowerShell 7 is started from $PSHOME, never from the process path or by name' {
    <# Lab row A, 2026-11-12: started through upd.cmd, pwsh ran via the per-user MSIX alias, and
       [Environment]::ProcessPath returned that alias inside the user's profile. Every
       continuation task, the SYSTEM fallback included, was registered with it. #>
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $sources = @{}
        foreach ($rel in 'Invoke-BootUpdateCycle.ps1','Deploy-BootUpdateCycle.ps1','tools/Invoke-UpdLauncher.ps1','Repair-AwsTooling.ps1') {
            $sources[$rel] = Get-Content -LiteralPath (Join-Path $root $rel) -Raw
        }
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Invoke-BootUpdateCycle.ps1'), [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-BootUpdatePwshPath' }, $true)
        . ([scriptblock]::Create($fn.Extent.Text))
    }

    It 'resolves the runtime to pwsh.exe in $PSHOME' {
        Get-BootUpdatePwshPath | Should -Be (Join-Path $PSHOME 'pwsh.exe')
    }

    It 'never launches the process path in any script' {
        foreach ($rel in $sources.Keys) {
            $sources[$rel] | Should -Not -Match '\(\[Environment\]::ProcessPath\)|=\s*\[Environment\]::ProcessPath|\{\s*\[Environment\]::ProcessPath' -Because $rel
            $sources[$rel] | Should -Not -Match '&\s+pwsh\s|Get-Command pwsh\)\.Source' -Because $rel
        }
    }

    It 'registers the Deploy task with $PSHOME\pwsh.exe' {
        $sources['Deploy-BootUpdateCycle.ps1'] | Should -Match "\`$pwshPath = Join-Path \`$PSHOME 'pwsh\.exe'"
        $sources['Invoke-BootUpdateCycle.ps1'] | Should -Match '(?s)function Register-BootUpdateTaskForReboot.*?\$pwshPath = Get-BootUpdatePwshPath'
    }
}

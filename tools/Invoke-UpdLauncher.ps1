#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Command = 'run',
    [Alias('h','?','usage')][switch]$Help,
    [Alias('r','delay','reboot-delay')][ValidateRange(0,86400)][int]$RebootDelaySec = 0,
    [Alias('o','output-mode')][ValidateSet('Quiet','Normal','Verbose','Debug')][string]$OutputMode = 'Normal',
    [Alias('n','max-iterations')][ValidateRange(1,50)][int]$MaxIterations = 5,
    [Alias('t','timeout','timeout-minutes','package-timeout-minutes')][ValidateRange(1,1440)][int]$PackageTimeoutMinutes = 30,
    [Alias('duration')][ValidateRange(2,60)][int]$DurationSeconds = 8,
    [Alias('s','StagedRollout')][switch]$Staged,
    [Alias('ar','aggressive-repair')][switch]$AggressiveRepair,
    [Alias('drv','IncludeDriverUpdates')][switch]$Drivers,
    [Alias('fw','IncludeFirmwareUpdates')][switch]$Firmware,
    [Alias('w','UpdateWsl')][switch]$Wsl,
    [Alias('c','UpdateContainers')][switch]$Containers,
    [Alias('m','allow-metered')][switch]$AllowMetered,
    [Alias('rp','restore-point','EnableRestorePoint')][switch]$RestorePoint,
    [Alias('dn','dotnet-tools','EnableDotnetTools')][switch]$DotnetTools,
    [Alias('aws','aws-tooling','EnableAwsTooling')][switch]$AwsTooling,
    [Alias('keep-aws-legacy')][switch]$PreserveAwsLegacy,
    [Alias('keep-aws-old')][switch]$PreserveAwsOldVersions,
    [Alias('no-pip','skip-pip')][switch]$SkipPip,
    [Alias('no-npm','skip-npm')][switch]$SkipNpm,
    [Alias('no-o365','skip-office365')][switch]$SkipOffice365,
    [Alias('no-psm','skip-power-shell-modules')][switch]$SkipPowerShellModules,
    [Alias('no-scoop','skip-scoop')][switch]$SkipScoop,
    [Alias('no-code','skip-vscode')][switch]$SkipVscode,
    [Alias('no-def','skip-defender')][switch]$SkipDefender,
    [Alias('no-check','skip-health-check')][switch]$SkipHealthCheck,
    [Alias('no-bl','skip-bit-locker')][switch]$SkipBitLocker,
    [Alias('nu','no-update','disable-self-update')][switch]$DisableSelfUpdate,
    [Alias('x','ExcludePatterns')][string[]]$Exclude = @(),
    [Alias('i','IncludePatterns')][string[]]$Include = @(),
    [Parameter(DontShow)][switch]$V,
    [Parameter(DontShow)][switch]$D,
    [Parameter(DontShow)][switch]$F,
    [Parameter(DontShow)][switch]$St,
    [Parameter(DontShow)][switch]$BundlePreflighted,
    [Parameter(DontShow)][switch]$LegacyAdoptionWorker,
    [Parameter(DontShow)][string]$EncodedArguments = '',
    [Parameter(ValueFromRemainingArguments)][string[]]$RemainingArguments = @()
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$deployPath = Join-Path $repoRoot 'Deploy-BootUpdateCycle.ps1'
$invokePath = Join-Path $repoRoot 'Invoke-BootUpdateCycle.ps1'
$demoPath = Join-Path $PSScriptRoot 'Show-BootUpdateProgressDemo.ps1'
$ps7BootstrapPath = Join-Path $PSScriptRoot 'Install-PowerShell7.ps1'
$argumentBootstrapPath = Join-Path $PSScriptRoot 'Invoke-UpdBootstrap.ps1'
$awsPath = Join-Path $repoRoot 'Repair-AwsTooling.ps1'
$diagnosticsPath = Join-Path $repoRoot 'Export-BootUpdateDiagnostics.ps1'

function Enable-UpdNtfsCompression {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    try {
        $item = Get-Item -LiteralPath $Path -Force
        if (($item.Attributes -band [IO.FileAttributes]::Compressed) -eq 0 -and
            (Get-Command compact.exe -ErrorAction SilentlyContinue)) {
            $null = & compact.exe /C /I /Q $item.FullName 2>$null
        }
    } catch { }
}

function Invoke-UpdAwsLogMaintenance {
    $directory = Join-Path $env:ProgramData 'BootUpdateCycle'
    if (-not (Test-Path -LiteralPath $directory)) { $null = New-Item -ItemType Directory -Path $directory -Force }
    $path = Join-Path $directory 'BootUpdateCycle.aws.log'
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 5MB) {
        $archive = $path -replace '\.log$', ".$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
        Move-Item -LiteralPath $path -Destination $archive -Force
        Enable-UpdNtfsCompression -Path $archive
    }
    Get-ChildItem -LiteralPath $directory -File -ErrorAction SilentlyContinue |
        Where-Object Name -Match '^BootUpdateCycle\.aws\.\d{8}-\d{6}\.log$' |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip 3 |
        Remove-Item -Force -ErrorAction SilentlyContinue
    return $path
}

function Show-UpdHelp {
    @'

  UPD // Boot Update Cycle
  Run as admin, walk away, come back to a verified configured patch pass.

  USAGE
    upd [run] [options]        Start an update cycle
    upd <seconds>              Legacy shorthand for --delay <seconds>
    upd splash                 Preview every splash theme; no updates or UAC
    upd demo [seconds]         Animate BOOT//PULSE; no updates or UAC
    upd fun [seconds]          Splash parade + animation; no updates or UAC
    upd plan [options]         Show the resolved deployment parameters only
    upd update                 Refresh the checksummed source bundle and exit
    upd aws                    Update/repair AWS CLI v2 and AWS.Tools
    upd logs                   Export a sanitized compressed diagnostic bundle
    upd repair                 Recover launcher/core files, then refresh the bundle
    upd bootstrap              Verify that the PowerShell 7 runtime is ready
    upd status                 Show checkpoint/task status
    upd uq [id|all]            Remove recorded Winget quarantine pins; default all
    upd version                Show the bundled updater version
    upd help                   Show this screen

  SHORT COMMANDS
    r=run  d=demo  f=fun  sp=splash  p=plan  u=update  a=aws  l=logs  uq=unquarantine  b=bootstrap  st=status  v=version
    Short commands do not take a leading dash.

  HELP ALIASES
    /?  ?  /help  help  -h  --help  usage  --usage

  RUN OPTIONS
    -r, --delay <seconds>      Reboot countdown; default 0
    -o, --output-mode <mode>   Quiet | Normal | Verbose | Debug
    -n, --max-iterations <n>   Reboot-loop safety limit; default 5
    -t, --timeout <minutes>    Per-provider hard timeout; default 30
    -s, --staged               Run one provider per checkpoint
    -ar, --aggressive-repair   Attempt repair/force reinstall for failed Winget packages
    -drv, --drivers            Include Windows driver updates
    -fw, --firmware            Include firmware updates
    -w, --wsl                  Update WSL kernel and distributions
    -c, --containers           Refresh Docker/Podman images
    -m, --allow-metered        Permit metered network use
    --restore-point            Opt in to a restore point
    --dotnet-tools             Opt in to .NET global-tool updates
    --aws-tooling              Opt in to AWS CLI/module repair
    --keep-aws-legacy         Preserve legacy AWSPowerShell* during upd aws
    --keep-aws-old            Preserve older modular AWS.Tools versions
    -x, --exclude <pattern>    Skip matching packages; repeat or comma-separate
    -i, --include <pattern>    Allow only matching packages; repeat or comma-separate
    --skip-pip                 Skip pip
    --skip-npm                 Skip npm
    --skip-office365           Skip Office Click-to-Run
    --skip-power-shell-modules Skip PowerShell modules
    --skip-scoop               Skip Scoop
    --skip-vscode              Skip VS Code extensions
    --skip-defender            Skip Defender signatures
    --skip-health-check        Skip service verification (completion is downgraded)
    --skip-bit-locker          Do not suspend BitLocker for an orchestrated reboot
    --disable-self-update      Do not check GitHub releases

  EXAMPLES
    upd -r 120 -drv -fw
    upd r -s -o Verbose
    upd -x Teams,OneDrive -no-o365
    upd p -w -c -m
    upd d 12

  During a live interactive run, press v to cycle output detail.
'@ | Write-Host
}

function Get-UpdVersion {
    param([switch]$AllowUnknown)
    try { $raw = Get-Content -LiteralPath $invokePath -Raw -ErrorAction Stop }
    catch { if ($AllowUnknown) { return [version]'0.0.0' }; throw }
    if ($raw -notmatch "BootUpdateCycleVersion'\s*-Value\s*'([\d.]+)'") {
        if ($AllowUnknown) { return [version]'0.0.0' }
        throw 'Could not read the bundled updater version.'
    }
    return [version]$Matches[1]
}

function Install-UpdStagedBatch {
    $target = Join-Path $repoRoot 'upd.cmd'
    $staged = "$target.next"
    $sidecar = "$staged.sha256"
    $baselineSidecar = "$staged.baseline"
    $backup = "$target.bak"
    $replaced = $false
    if (-not (Test-Path -LiteralPath $staged)) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $sidecar)) { throw 'staged checksum is missing' }
        if (-not (Test-Path -LiteralPath $baselineSidecar)) { throw 'staged baseline is missing' }
        $expected = ((Get-Content -LiteralPath $sidecar -Raw) -split '\s+')[0].ToUpperInvariant()
        if ($expected -notmatch '^[0-9A-F]{64}$') { throw 'staged checksum is malformed' }
        $actual = (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actual -ne $expected) { throw 'staged checksum does not match' }
        $batch = Get-Content -LiteralPath $staged -Raw
        if ($batch -notmatch '(?m)^:: BootUpdateCycleVersion=([\d.]+)\s*$') { throw 'staged version marker is missing' }
        $stagedVersion = [version]$Matches[1]
        $coreVersion = Get-UpdVersion
        if ($stagedVersion -ne $coreVersion) { throw "staged v$stagedVersion does not match core v$coreVersion" }
        if ($batch -notmatch '(?im)^@echo off\s*$' -or $batch -notmatch 'Invoke-UpdLauncher\.ps1') { throw 'staged launcher structure is invalid' }
        $expectedBaseline = (Get-Content -LiteralPath $baselineSidecar -Raw).Trim().ToUpperInvariant()
        if ($expectedBaseline -eq 'MISSING') {
            if (Test-Path -LiteralPath $target) { throw 'live upd.cmd appeared after staging' }
        } else {
            if ($expectedBaseline -notmatch '^[0-9A-F]{64}$') { throw 'staged baseline is malformed' }
            if (-not (Test-Path -LiteralPath $target)) { throw 'live upd.cmd disappeared after staging' }
            $liveHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToUpperInvariant()
            if ($liveHash -ne $expectedBaseline) { throw 'live upd.cmd changed after staging' }
        }
        [IO.File]::Replace($staged, $target, $backup, $true)
        $replaced = $true
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToUpperInvariant() -ne $actual) { throw 'adopted upd.cmd failed post-copy verification' }
        Remove-Item -LiteralPath $sidecar,$baselineSidecar -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        if ($replaced -and (Test-Path -LiteralPath $backup)) {
            [IO.File]::Replace($backup, $target, $null, $true)
        }
        Write-Warning "Rejected upd.cmd.next: $_"
        Remove-Item -LiteralPath $staged,$sidecar,$baselineSidecar -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Start-UpdLegacyBatchAdoption {
    <# v2.5.43 invokes adoption from the batch file it is still reading. Give that
       one legacy caller time to return before a detached worker performs the same
       checksum-, baseline-, and version-verified adoption. v2.5.44+ never uses
       this bridge because its temporary trampoline proves it is safe to swap. #>
    $workerLog = Join-Path $repoRoot 'upd.cmd.adoption.log'
    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath),
        'adopt-staged-batch', '-LegacyAdoptionWorker'
    )
    $null = Start-Process -FilePath (Get-Command pwsh).Source -WindowStyle Hidden -ArgumentList $arguments
    Set-Content -LiteralPath $workerLog -Value "$(Get-Date -Format o) Legacy launcher adoption queued." -Encoding utf8
}

function Get-UpdDeployParameters {
    $result = [ordered]@{
        RebootDelaySec        = $RebootDelaySec
        OutputMode            = $OutputMode
        MaxIterations         = $MaxIterations
        PackageTimeoutMinutes = $PackageTimeoutMinutes
        NonInteractive        = $true
    }
    $switchMap = [ordered]@{
        Staged='StagedRollout'; AggressiveRepair='AggressiveRepair'; Drivers='IncludeDriverUpdates'; Firmware='IncludeFirmwareUpdates'
        Wsl='UpdateWsl'; Containers='UpdateContainers'; AllowMetered='AllowMetered'
        RestorePoint='EnableRestorePoint'; DotnetTools='EnableDotnetTools'; AwsTooling='EnableAwsTooling'
        SkipPip='SkipPip'; SkipNpm='SkipNpm'; SkipOffice365='SkipOffice365'
        SkipPowerShellModules='SkipPowerShellModules'; SkipScoop='SkipScoop'; SkipVscode='SkipVscode'
        SkipDefender='SkipDefender'; SkipHealthCheck='SkipHealthCheck'; SkipBitLocker='SkipBitLocker'
        DisableSelfUpdate='DisableSelfUpdate'
    }
    foreach ($entry in $switchMap.GetEnumerator()) {
        if ((Get-Variable -Name $entry.Key -ValueOnly)) { $result[$entry.Value] = $true }
    }
    if ($Exclude.Count) { $result.ExcludePatterns = @($Exclude | ForEach-Object { $_ -split ',' } | Where-Object { $_ }) }
    if ($Include.Count) { $result.IncludePatterns = @($Include | ForEach-Object { $_ -split ',' } | Where-Object { $_ }) }
    return $result
}

function Test-UpdAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Add-UpdToMachinePath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path','Machine')
    $entries = @($machinePath -split ';' | Where-Object { $_ })
    if ($entries -contains $repoRoot) { return }
    $newPath = ($entries + $repoRoot) -join ';'
    if ($newPath.Length -gt 2047) {
        Write-Warning 'Machine PATH would exceed 2047 characters; launcher path was not added.'
        return
    }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')
    Write-Host "Added $repoRoot to the Machine PATH." -ForegroundColor Green
}

function Update-UpdSourceBundle {
    param([switch]$Explicit)
    $tempRoot = $null
    try {
        $localVersion = Get-UpdVersion -AllowUnknown
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/nanoDBA/boot-upd/releases/latest' `
            -Headers @{ 'User-Agent'='BootUpdateCycle-Launcher' } -TimeoutSec 15 -ErrorAction Stop
        $remoteVersion = [version]($release.tag_name -replace '^v','')
        if ($remoteVersion -lt $localVersion) {
            Write-Host "Checksummed bundle check: local v$localVersion is newer than published v$remoteVersion; no downgrade." -ForegroundColor Yellow
            return $false
        }

        $specs = @(
            [pscustomobject]@{ Name='Invoke-BootUpdateCycle.ps1'; Target=(Join-Path $repoRoot 'Invoke-BootUpdateCycle.ps1'); PowerShell=$true; StageBatch=$false }
            [pscustomobject]@{ Name='Deploy-BootUpdateCycle.ps1'; Target=(Join-Path $repoRoot 'Deploy-BootUpdateCycle.ps1'); PowerShell=$true; StageBatch=$false }
            [pscustomobject]@{ Name='Invoke-UpdLauncher.ps1'; Target=$PSCommandPath; PowerShell=$true; StageBatch=$false }
            [pscustomobject]@{ Name='Invoke-UpdBootstrap.ps1'; Target=$argumentBootstrapPath; PowerShell=$true; StageBatch=$false }
            [pscustomobject]@{ Name='Show-BootUpdateProgressDemo.ps1'; Target=$demoPath; PowerShell=$true; StageBatch=$false }
            [pscustomobject]@{ Name='Install-PowerShell7.ps1'; Target=$ps7BootstrapPath; PowerShell=$true; StageBatch=$false }
            [pscustomobject]@{ Name='Repair-AwsTooling.ps1'; Target=$awsPath; PowerShell=$true; StageBatch=$false }
            [pscustomobject]@{ Name='Export-BootUpdateDiagnostics.ps1'; Target=$diagnosticsPath; PowerShell=$true; StageBatch=$false }
            [pscustomobject]@{ Name='upd.cmd'; Target=(Join-Path $repoRoot 'upd.cmd'); PowerShell=$false; StageBatch=$true }
        )
        $baselines = @{}
        foreach ($spec in $specs) {
            $exists = Test-Path -LiteralPath $spec.Target
            $baselines[$spec.Name] = [pscustomobject]@{
                Exists = $exists
                Hash = if ($exists) { (Get-FileHash -LiteralPath $spec.Target -Algorithm SHA256).Hash.ToUpperInvariant() } else { $null }
            }
        }
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('boot-upd-bundle-{0}' -f [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $tempRoot -ErrorAction Stop
        $verified = [Collections.Generic.List[object]]::new()

        <# Validate the complete release before replacing any local executable. #>
        foreach ($spec in $specs) {
            $asset = $release.assets | Where-Object name -eq $spec.Name | Select-Object -First 1
            $shaAsset = $release.assets | Where-Object name -eq "$($spec.Name).sha256" | Select-Object -First 1
            if (-not $asset -or -not $shaAsset) { throw "Release $($release.tag_name) is missing $($spec.Name) or its SHA256 sidecar." }
            $expected = ((Invoke-RestMethod -Uri $shaAsset.browser_download_url -Headers @{ 'User-Agent'='BootUpdateCycle-Launcher' } -TimeoutSec 15) -split '\s+')[0].ToUpperInvariant()
            if ($expected -notmatch '^[0-9A-F]{64}$') { throw "Release $($release.tag_name) has an invalid SHA256 for $($spec.Name)." }
            $temp = Join-Path $tempRoot $spec.Name
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $temp -Headers @{ 'User-Agent'='BootUpdateCycle-Launcher' } -TimeoutSec 60
            $actual = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash.ToUpperInvariant()
            if ($actual -ne $expected) { throw "SHA256 mismatch for $($spec.Name)." }
            if ($spec.PowerShell) {
                $tokens=$null; $errors=$null
                [void][Management.Automation.Language.Parser]::ParseFile($temp,[ref]$tokens,[ref]$errors)
                if ($errors.Count) { throw "Downloaded $($spec.Name) has a PowerShell parse error: $($errors[0].Message)" }
            } else {
                $batch = Get-Content -LiteralPath $temp -Raw
                if ($batch -notmatch '(?im)^@echo off\s*$' -or $batch -notmatch 'Invoke-UpdLauncher\.ps1') { throw 'Downloaded upd.cmd failed its launcher structure check.' }
            }
            $verified.Add([pscustomobject]@{ Spec=$spec; Temp=$temp; Hash=$actual })
        }

        $downloadedCore = Get-Content -LiteralPath (($verified | Where-Object { $_.Spec.Name -eq 'Invoke-BootUpdateCycle.ps1' }).Temp) -Raw
        $downloadedBatch = Get-Content -LiteralPath (($verified | Where-Object { $_.Spec.Name -eq 'upd.cmd' }).Temp) -Raw
        if ($downloadedCore -notmatch "BootUpdateCycleVersion'\s*-Value\s*'([\d.]+)'") {
            throw "Release $($release.tag_name) core version marker is missing."
        }
        $downloadedCoreVersion = [version]$Matches[1]
        if ($downloadedCoreVersion -ne $remoteVersion) {
            throw "Release $($release.tag_name) core version does not match its tag."
        }
        if ($downloadedBatch -notmatch '(?m)^:: BootUpdateCycleVersion=([\d.]+)\s*$') {
            throw "Release $($release.tag_name) batch version marker is missing."
        }
        $downloadedBatchVersion = [version]$Matches[1]
        if ($downloadedBatchVersion -ne $remoteVersion) {
            throw "Release $($release.tag_name) batch version does not match its tag."
        }

        $changed = [Collections.Generic.List[string]]::new()
        $committed = [Collections.Generic.List[object]]::new()
        $commitStarted = $false
        try {
            foreach ($item in $verified) {
                $spec = $item.Spec
                $destination = if ($spec.StageBatch) { "$($spec.Target).next" } else { $spec.Target }
                $baseline = $baselines[$spec.Name]
                $liveExists = Test-Path -LiteralPath $spec.Target
                $liveHash = if ($liveExists) { (Get-FileHash -LiteralPath $spec.Target -Algorithm SHA256).Hash.ToUpperInvariant() } else { $null }
                if ($liveExists -ne $baseline.Exists -or $liveHash -ne $baseline.Hash) {
                    throw "Local/cloud sync changed $($spec.Target) during bundle staging."
                }
                if ((Test-Path -LiteralPath $spec.Target) -and (Get-FileHash -LiteralPath $spec.Target -Algorithm SHA256).Hash -eq $item.Hash) {
                    if ($spec.StageBatch) { Remove-Item -LiteralPath $destination,"$destination.sha256","$destination.baseline" -Force -ErrorAction SilentlyContinue }
                    continue
                }
                $snapshot = Join-Path $tempRoot ("rollback-{0}" -f $committed.Count)
                $existed = Test-Path -LiteralPath $destination
                if ($existed) { Copy-Item -LiteralPath $destination -Destination $snapshot -Force }
                $sidecarPath = "$destination.sha256"
                $sidecarSnapshot = "$snapshot.sha256"
                $baselinePath = "$destination.baseline"
                $baselineSnapshot = "$snapshot.baseline"
                $sidecarExisted = $spec.StageBatch -and (Test-Path -LiteralPath $sidecarPath)
                $baselineExisted = $spec.StageBatch -and (Test-Path -LiteralPath $baselinePath)
                if ($sidecarExisted) { Copy-Item -LiteralPath $sidecarPath -Destination $sidecarSnapshot -Force }
                if ($baselineExisted) { Copy-Item -LiteralPath $baselinePath -Destination $baselineSnapshot -Force }
                $committed.Add([pscustomobject]@{ Destination=$destination; Snapshot=$snapshot; Existed=$existed; SidecarPath=$sidecarPath; SidecarSnapshot=$sidecarSnapshot; SidecarExisted=$sidecarExisted; BaselinePath=$baselinePath; BaselineSnapshot=$baselineSnapshot; BaselineExisted=$baselineExisted; Staged=$spec.StageBatch })
                $commitStarted = $true
                $incoming = "$destination.incoming-$PID"
                try {
                    Copy-Item -LiteralPath $item.Temp -Destination $incoming -Force
                    Move-Item -LiteralPath $incoming -Destination $destination -Force
                    if ($spec.StageBatch) {
                        Set-Content -LiteralPath $sidecarPath -Value $item.Hash -Encoding ascii -NoNewline
                        $baselineValue = if ($baseline.Exists) { $baseline.Hash } else { 'MISSING' }
                        Set-Content -LiteralPath $baselinePath -Value $baselineValue -Encoding ascii -NoNewline
                    } elseif ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToUpperInvariant() -ne $item.Hash) {
                        throw "Post-copy SHA256 mismatch for $($spec.Name)."
                    }
                    $changed.Add($spec.Name)
                } finally {
                    if (Test-Path -LiteralPath $incoming) { Remove-Item -LiteralPath $incoming -Force -ErrorAction SilentlyContinue }
                }
            }
        } catch {
            for ($index = $committed.Count - 1; $index -ge 0; $index--) {
                $entry = $committed[$index]
                if ($entry.Existed) { Copy-Item -LiteralPath $entry.Snapshot -Destination $entry.Destination -Force }
                else { Remove-Item -LiteralPath $entry.Destination -Force -ErrorAction SilentlyContinue }
                if ($entry.Staged) {
                    if ($entry.SidecarExisted) { Copy-Item -LiteralPath $entry.SidecarSnapshot -Destination $entry.SidecarPath -Force }
                    else { Remove-Item -LiteralPath $entry.SidecarPath -Force -ErrorAction SilentlyContinue }
                    if ($entry.BaselineExisted) { Copy-Item -LiteralPath $entry.BaselineSnapshot -Destination $entry.BaselinePath -Force }
                    else { Remove-Item -LiteralPath $entry.BaselinePath -Force -ErrorAction SilentlyContinue }
                }
            }
            throw "Bundle commit failed and was rolled back: $_"
        }
        if ($changed.Count) { Write-Host "Checksummed bundle updated to v${remoteVersion}: $($changed -join ', ')" -ForegroundColor Green }
        else { Write-Host "Checksummed bundle already current at v$localVersion." -ForegroundColor Green }
        return ($changed.Count -gt 0)
    } catch {
        if ($Explicit -or $commitStarted) { throw }
        Write-Warning "Checksummed source-bundle update skipped: $_"
        return $false
    } finally {
        if ($tempRoot -and (Test-Path -LiteralPath $tempRoot)) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-UpdElevated {
    param([Parameter(Mandatory)][string[]]$CanonicalArguments)
    $json = ConvertTo-Json -InputObject @($CanonicalArguments) -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $quotedScript = '"{0}"' -f $PSCommandPath
    $process = Start-Process -FilePath (Get-Command pwsh).Source -Verb RunAs -Wait -PassThru -ArgumentList @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $quotedScript,
        '-EncodedArguments', $encoded
    )
    return $process.ExitCode
}

function Get-UpdCanonicalRunArguments {
    param([Parameter(Mandatory)][Collections.IDictionary]$DeployParameters)
    $arguments = [Collections.Generic.List[string]]::new()
    $arguments.Add('run')
    foreach ($entry in $DeployParameters.GetEnumerator()) {
        if ($entry.Key -eq 'NonInteractive') { continue }
        if ($entry.Value -is [bool]) {
            if ($entry.Value) { $arguments.Add("-$($entry.Key)") }
        } elseif ($entry.Value -is [array]) {
            foreach ($value in $entry.Value) { $arguments.Add("-$($entry.Key -replace 'Patterns$','')"); $arguments.Add([string]$value) }
        } else {
            $launcherName = switch ($entry.Key) {
                'PackageTimeoutMinutes' { '-PackageTimeoutMinutes' }
                default { "-$($entry.Key)" }
            }
            $arguments.Add($launcherName); $arguments.Add([string]$entry.Value)
        }
    }
    return $arguments.ToArray()
}

function Get-UpdCanonicalAwsArguments {
    param([switch]$DisableUpdate,[switch]$Preflighted,[switch]$KeepLegacy,[switch]$KeepOldVersions)
    $arguments = [Collections.Generic.List[string]]::new()
    $arguments.Add('aws')
    if ($DisableUpdate) { $arguments.Add('-DisableSelfUpdate') }
    if ($Preflighted) { $arguments.Add('-BundlePreflighted') }
    if ($KeepLegacy) { $arguments.Add('-PreserveAwsLegacy') }
    if ($KeepOldVersions) { $arguments.Add('-PreserveAwsOldVersions') }
    return $arguments.ToArray()
}

function Show-UpdStatus {
    $statePath = Join-Path $env:ProgramData 'BootUpdateCycle\BootUpdateCycle.state.json'
    $quarantinePath = Join-Path $env:ProgramData 'BootUpdateCycle\BootUpdateCycle-winget-quarantine.json'
    $taskNames = @('BootUpdateCycle','BootUpdateCycleFallback')
    Write-Host "Boot Update Cycle v$(Get-UpdVersion)" -ForegroundColor Cyan
    foreach ($name in $taskNames) {
        $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($task) { Write-Host ("  task  {0,-24} {1}" -f $name,$task.State) }
    }
    if (Test-Path -LiteralPath $statePath) {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        Write-Host "  state $($state.Phase)  iteration $($state.Iteration)/$($state.MaxIterations ?? '?')"
    } else { Write-Host '  state no active checkpoint' }
    if (Test-Path -LiteralPath $quarantinePath) {
        try {
            $quarantines = @((Get-Content -LiteralPath $quarantinePath -Raw | ConvertFrom-Json))
            Write-Host "  winget quarantine active ($($quarantines.Count) package(s))" -ForegroundColor Yellow
            foreach ($record in $quarantines) { Write-Host "    $($record.PackageId)  undo: $($record.UnpinCommand)" -ForegroundColor Yellow }
        } catch { Write-Warning "Winget quarantine record is unreadable: $quarantinePath" }
    }
}

function Remove-UpdWingetQuarantine {
    param([string]$Target = 'all')
    $path = Join-Path $env:ProgramData 'BootUpdateCycle\BootUpdateCycle-winget-quarantine.json'
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host 'No recorded Winget quarantine is active.' -ForegroundColor Green
        return
    }
    $records = @((Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json))
    foreach ($record in $records) {
        if ([string]$record.PackageId -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') {
            throw 'The Winget quarantine record contains an unsafe package identifier; no pins were changed.'
        }
    }
    if ($Target -ne 'all' -and $Target -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') {
        throw "Invalid Winget quarantine package id '$Target'."
    }
    $targets = if ($Target -eq 'all') { @($records) } else { @($records | Where-Object PackageId -eq $Target) }
    if (-not $targets.Count) { throw "No recorded Winget quarantine matches '$Target'." }
    $wingetPath = (Get-Command winget -ErrorAction Stop).Source
    $remaining = [Collections.Generic.List[object]]::new([object[]]$records)
    foreach ($record in $targets) {
        & $wingetPath pin remove --id $record.PackageId -e --disable-interactivity
        if ($LASTEXITCODE -ne 0) { throw "Winget could not remove the quarantine pin for $($record.PackageId); its record was retained." }
        $null = $remaining.Remove($record)
        if ($remaining.Count) {
            $temp = '{0}.{1}.{2}.tmp' -f $path,$PID,[guid]::NewGuid().ToString('N')
            try {
                [IO.File]::WriteAllText($temp, ($remaining.ToArray() | ConvertTo-Json -Depth 6), [Text.Encoding]::UTF8)
                [IO.File]::Move($temp,$path,$true)
            } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
        } else { Remove-Item -LiteralPath $path -Force }
        Write-Host "Removed Winget quarantine for $($record.PackageId)." -ForegroundColor Green
    }
}

if ($EncodedArguments) {
    $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($EncodedArguments)) | ConvertFrom-Json
    & $PSCommandPath @($decoded)
    exit $LASTEXITCODE
}

$helpNames = @('/?','?','/help','help','-help','--help','-h','usage','--usage')
if ($Help -or $Command -in $helpNames) { Show-UpdHelp; exit 0 }

if ($V -or $D -or $F -or $St) {
    throw "Short commands do not take a dash. Use 'upd v', 'upd f', or 'upd st'."
}

$commandAliases = @{
    'r'='run'; 'd'='demo'; 'f'='fun'; 'sp'='splash'; 'p'='plan'
    'u'='update'; 'a'='aws'; 'l'='logs'; 'uq'='unquarantine'; 'b'='bootstrap'; 'st'='status'; 'v'='version'
    '--demo'='demo'; '/demo'='demo'; '--fun'='fun'; '/fun'='fun'
}
if ($commandAliases.ContainsKey($Command.ToLowerInvariant())) {
    $Command = $commandAliases[$Command.ToLowerInvariant()]
}

if ($Command -match '^\d+$') {
    if ($PSBoundParameters.ContainsKey('RebootDelaySec')) { throw 'Specify the reboot delay only once.' }
    $RebootDelaySec = [int]$Command
    $Command = 'run'
} elseif ($Command -eq 'run' -and $RemainingArguments.Count -eq 1 -and $RemainingArguments[0] -match '^\d+$') {
    if ($PSBoundParameters.ContainsKey('RebootDelaySec')) { throw 'Specify the reboot delay only once.' }
    $RebootDelaySec = [int]$RemainingArguments[0]
    $RemainingArguments = @()
}

if ($Command -in @('demo','fun') -and $RemainingArguments.Count -eq 1 -and $RemainingArguments[0] -match '^\d+$') {
    $DurationSeconds = [int]$RemainingArguments[0]
    $RemainingArguments = @()
}
if ($Command -eq 'unquarantine') {
    if ($RemainingArguments.Count -gt 1) { throw 'Use upd uq [package-id|all].' }
    $unquarantineTarget = if ($RemainingArguments.Count) { $RemainingArguments[0] } else { 'all' }
    $RemainingArguments = @()
}
if ($RemainingArguments.Count) { throw "Unexpected argument(s): $($RemainingArguments -join ' '). Run 'upd help'." }

switch ($Command.ToLowerInvariant()) {
    'unquarantine' {
        if (-not (Test-UpdAdministrator)) {
            Write-Host 'Requesting administrator access to remove Winget quarantine pins...' -ForegroundColor Yellow
            exit (Invoke-UpdElevated -CanonicalArguments @('unquarantine',$unquarantineTarget))
        }
        Remove-UpdWingetQuarantine -Target $unquarantineTarget
        exit 0
    }
    'splash' {
        & $invokePath -PreviewSplash
        exit 0
    }
    'demo' {
        & $demoPath -DurationSeconds $DurationSeconds
        exit 0
    }
    'fun' {
        & $invokePath -PreviewSplash
        & $demoPath -DurationSeconds $DurationSeconds
        exit 0
    }
    'version' { Write-Host "Boot Update Cycle v$(Get-UpdVersion)"; exit 0 }
    'bootstrap' { Write-Host "PowerShell $($PSVersionTable.PSVersion) runtime ready: $((Get-Process -Id $PID).Path)" -ForegroundColor Green; exit 0 }
    'status' { Show-UpdStatus; exit 0 }
    'plan' {
        [pscustomobject](Get-UpdDeployParameters) | Format-List
        Write-Host 'PLAN ONLY — no elevation, deployment, updates, tasks, or reboots.' -ForegroundColor Cyan
        exit 0
    }
    'update' {
        if (-not (Test-UpdAdministrator)) {
            Write-Host 'Requesting administrator access to update the checksummed source bundle...' -ForegroundColor Yellow
            exit (Invoke-UpdElevated -CanonicalArguments @('update'))
        }
        $null = Update-UpdSourceBundle -Explicit
        exit 0
    }
    'adopt-staged-batch' {
        if ($LegacyAdoptionWorker) {
            Start-Sleep -Milliseconds 1500
            try {
                $adopted = Install-UpdStagedBatch
                if ($adopted) {
                    Set-Content -LiteralPath (Join-Path $repoRoot 'upd.cmd.adoption.log') -Value "$(Get-Date -Format o) Legacy launcher adoption completed." -Encoding utf8
                }
            } catch {
                Set-Content -LiteralPath (Join-Path $repoRoot 'upd.cmd.adoption.log') -Value "$(Get-Date -Format o) Legacy launcher adoption failed: $_" -Encoding utf8
                throw
            }
        } elseif ($env:UPD_TRAMPOLINE_ACTIVE -and $env:UPD_TRAMPOLINE_PATH) {
            $null = Install-UpdStagedBatch
        } else {
            Start-UpdLegacyBatchAdoption
        }
        exit 0
    }
    'aws' {
        if (-not (Test-UpdAdministrator)) {
            Write-Host 'Requesting administrator access to update AWS tooling...' -ForegroundColor Yellow
            exit (Invoke-UpdElevated -CanonicalArguments (Get-UpdCanonicalAwsArguments -DisableUpdate:$DisableSelfUpdate -Preflighted:$BundlePreflighted -KeepLegacy:$PreserveAwsLegacy -KeepOldVersions:$PreserveAwsOldVersions))
        }
        if (-not $DisableSelfUpdate -and -not $BundlePreflighted) { $null = Update-UpdSourceBundle }
        if (-not (Test-Path -LiteralPath $awsPath)) { throw 'Repair-AwsTooling.ps1 is unavailable. Run upd repair.' }
        $awsLogPath = Invoke-UpdAwsLogMaintenance
        $transcriptStarted = $false
        try {
            try { $null = Start-Transcript -LiteralPath $awsLogPath -Append -Force; $transcriptStarted = $true }
            catch { Write-Warning "AWS transcript could not be started; maintenance will continue: $_" }
            & $awsPath -Mode Remediate -PreserveLegacyModules:$PreserveAwsLegacy -PreserveOldModularVersions:$PreserveAwsOldVersions
            $awsExitCode = $LASTEXITCODE
        } finally {
            if ($transcriptStarted) { try { $null = Stop-Transcript } catch { } }
            Enable-UpdNtfsCompression -Path $awsLogPath
        }
        exit $awsExitCode
    }
    'logs' {
        if (-not (Test-Path -LiteralPath $diagnosticsPath)) {
            throw 'Diagnostics exporter is unavailable. Run upd update, then retry upd logs.'
        }
        & $diagnosticsPath
        exit $LASTEXITCODE
    }
    'run' {
        $deployParameters = Get-UpdDeployParameters
        if (-not (Test-UpdAdministrator)) {
            Write-Host 'Requesting administrator access for the update cycle...' -ForegroundColor Yellow
            exit (Invoke-UpdElevated -CanonicalArguments (Get-UpdCanonicalRunArguments -DeployParameters $deployParameters))
        }
        Add-UpdToMachinePath
        if (-not $DisableSelfUpdate -and -not $BundlePreflighted) { $null = Update-UpdSourceBundle }
        & $deployPath @deployParameters
        exit $LASTEXITCODE
    }
    default { throw "Unknown command '$Command'. Run 'upd help'." }
}

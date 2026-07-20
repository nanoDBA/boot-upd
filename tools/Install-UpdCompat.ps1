#requires -Version 5.1
<#
.SYNOPSIS
    One-time repair bridge for pre-trampoline upd.cmd installations.

.DESCRIPTION
    Run this script only after the old upd.cmd process has exited. It resolves
    the first upd.cmd on PATH (or -InstallRoot), downloads the complete latest
    runtime bundle plus SHA256 sidecars, validates everything before mutation,
    snapshots the exact target files locally, commits batch-last, and invokes
    the requested command through the repaired launcher.
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = '',
    [string[]]$CommandArguments = @('help'),
    [switch]$PromptForArguments,
    [string]$Repository = 'nanoDBA/boot-upd',
    [Parameter(DontShow)][string]$EncodedArguments = ''
)
$ErrorActionPreference = 'Stop'

if ($EncodedArguments) {
    try {
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($EncodedArguments)) | ConvertFrom-Json
        $InstallRoot = [string]$decoded.InstallRoot
        $CommandArguments = @($decoded.CommandArguments | ForEach-Object { [string]$_ })
        $PromptForArguments = [bool]$decoded.PromptForArguments
        $Repository = [string]$decoded.Repository
    } catch { throw 'Compatibility-installer elevation arguments are malformed.' }
}

function Test-CompatAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CompatSha256 {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-','')
    } finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Test-CompatPowerShellAsset {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$RequiredMajor
    )

    if ($RequiredMajor -gt $PSVersionTable.PSVersion.Major) {
        $source = Get-Content -LiteralPath $Path -Raw
        if ($source -notmatch "(?im)^\s*#requires\s+-Version\s+$RequiredMajor(?:\.0)?\s*$") {
            throw "PowerShell $RequiredMajor runtime declaration is missing from $Name."
        }

        $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $pwsh) {
            # The release checksum authenticates these exact bytes. The stable PS5
            # bootstrap is parsed below and installs PS7 before this asset executes.
            return
        }

        $parsePathVariable = 'BOOT_UPD_COMPAT_PARSE_PATH'
        $previousParsePath = [Environment]::GetEnvironmentVariable($parsePathVariable,'Process')
        try {
            [Environment]::SetEnvironmentVariable($parsePathVariable,$Path,'Process')
            $parseProbe = '& { $p=$env:BOOT_UPD_COMPAT_PARSE_PATH;$t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e);if($e.Count){[Console]::Error.WriteLine($e[0].Message);exit 1} }'
            $probeOutput = @(& $pwsh.Source -NoLogo -NoProfile -Command $parseProbe 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw "PowerShell parse error in ${Name}: $($probeOutput -join ' ')"
            }
        } finally {
            [Environment]::SetEnvironmentVariable($parsePathVariable,$previousParsePath,'Process')
        }
        return
    }

    $tokens=$null; $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw "PowerShell parse error in ${Name}: $($errors[0].Message)" }
}

function Set-CompatStagedFile {
    param(
        [Parameter(Mandatory)][string]$Incoming,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Snapshot,
        [Parameter(Mandatory)][bool]$Existed
    )

    if (-not $Existed) {
        Move-Item -LiteralPath $Incoming -Destination $Target -Force
        return
    }
    if (-not (Test-Path -LiteralPath $Snapshot -PathType Leaf)) {
        throw "Rollback snapshot is missing for $Target."
    }

    # Windows PowerShell 5.1 runs on .NET Framework, whose four-argument
    # File.Replace overload rejects a null destinationBackupFileName. The
    # durable rollback snapshot already exists; this concrete target-adjacent
    # backup keeps the atomic API on one volume and is removed after the swap.
    $replaceBackup = "$Target.file-replace-$PID"
    try {
        [IO.File]::Replace($Incoming,$Target,$replaceBackup,$true)
    } finally {
        Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
    }
}

function ConvertFrom-CompatCommandLine {
    param([Parameter(Mandatory)][string]$Line)

    if (-not ('BootUpdateCycle.CompatNativeArgv' -as [type])) {
        Add-Type -Namespace BootUpdateCycle -Name CompatNativeArgv -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", SetLastError=true)]
public static extern System.IntPtr CommandLineToArgvW(
    [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string commandLine,
    out int argumentCount);

[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr LocalFree(System.IntPtr memory);
'@
    }

    $count = 0
    $pointer = [BootUpdateCycle.CompatNativeArgv]::CommandLineToArgvW($Line,[ref]$count)
    if ($pointer -eq [IntPtr]::Zero) { throw 'Could not parse the requested updater arguments.' }
    try {
        $result = @()
        for ($index=0; $index -lt $count; $index++) {
            $argumentPointer = [Runtime.InteropServices.Marshal]::ReadIntPtr($pointer,$index * [IntPtr]::Size)
            $result += [Runtime.InteropServices.Marshal]::PtrToStringUni($argumentPointer)
        }
        return $result
    } finally {
        [void][BootUpdateCycle.CompatNativeArgv]::LocalFree($pointer)
    }
}

if (-not (Test-CompatAdministrator)) {
    $payload = [ordered]@{ InstallRoot=$InstallRoot; CommandArguments=@($CommandArguments); PromptForArguments=[bool]$PromptForArguments; Repository=$Repository }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $payload -Compress)))
    $quotedScript = '"{0}"' -f $PSCommandPath
    $process = Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -Wait -PassThru -ArgumentList @(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$quotedScript,'-EncodedArguments',$encoded
    )
    exit $process.ExitCode
}

if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

if (-not $InstallRoot) {
    $resolved = @(& where.exe upd 2>$null | Select-Object -First 1)
    if ($resolved) {
        if ($resolved[0] -notmatch '(?i)\.cmd$') {
            throw "The first PATH winner is not upd.cmd ($($resolved[0])). Refusing to repair a shadowed launcher; supply -InstallRoot explicitly."
        }
        $InstallRoot = Split-Path -Parent $resolved[0]
    } else {
        $InstallRoot = Join-Path $env:ProgramFiles 'BootUpdateCycle'
    }
}
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$targetBatch = Join-Path $InstallRoot 'upd.cmd'

$specs = @(
    [pscustomobject]@{ Name='Invoke-BootUpdateCycle.ps1'; Relative='Invoke-BootUpdateCycle.ps1'; PowerShell=$true; RequiredMajor=7; Batch=$false }
    [pscustomobject]@{ Name='Deploy-BootUpdateCycle.ps1'; Relative='Deploy-BootUpdateCycle.ps1'; PowerShell=$true; RequiredMajor=7; Batch=$false }
    [pscustomobject]@{ Name='Invoke-UpdLauncher.ps1'; Relative='tools\Invoke-UpdLauncher.ps1'; PowerShell=$true; RequiredMajor=7; Batch=$false }
    [pscustomobject]@{ Name='Invoke-UpdBootstrap.ps1'; Relative='tools\Invoke-UpdBootstrap.ps1'; PowerShell=$true; RequiredMajor=5; Batch=$false }
    [pscustomobject]@{ Name='Show-BootUpdateProgressDemo.ps1'; Relative='tools\Show-BootUpdateProgressDemo.ps1'; PowerShell=$true; RequiredMajor=7; Batch=$false }
    [pscustomobject]@{ Name='Install-PowerShell7.ps1'; Relative='tools\Install-PowerShell7.ps1'; PowerShell=$true; RequiredMajor=5; Batch=$false }
    [pscustomobject]@{ Name='Repair-AwsTooling.ps1'; Relative='Repair-AwsTooling.ps1'; PowerShell=$true; RequiredMajor=7; Batch=$false }
    [pscustomobject]@{ Name='upd.cmd'; Relative='upd.cmd'; PowerShell=$false; RequiredMajor=0; Batch=$true }
)

$headers = @{ 'User-Agent'='BootUpdateCycle-Compatibility-Installer' }
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" -Headers $headers -UseBasicParsing -TimeoutSec 30
if (-not $release.tag_name -or $release.tag_name -notmatch '^v\d+\.\d+\.\d+$') {
    throw 'The latest release has no valid semantic version tag.'
}
$remoteVersion = [version]($release.tag_name -replace '^v','')
$existingCore = Join-Path $InstallRoot 'Invoke-BootUpdateCycle.ps1'
if (Test-Path -LiteralPath $existingCore) {
    $existingText = Get-Content -LiteralPath $existingCore -Raw
    if ($existingText -match "BootUpdateCycleVersion'\s*-Value\s*'([\d.]+)'") {
        $localVersion = [version]$Matches[1]
        if ($remoteVersion -lt $localVersion) {
            throw "Refusing to downgrade local v$localVersion to $($release.tag_name)."
        }
    }
}

$stageRoot = Join-Path ([IO.Path]::GetTempPath()) ('boot-upd-compat-stage-{0}' -f [guid]::NewGuid().ToString('N'))
$backupRoot = Join-Path ([IO.Path]::GetTempPath()) ('boot-upd-compat-backup-{0:yyyyMMdd-HHmmss}' -f (Get-Date))
$verified = [Collections.Generic.List[object]]::new()
$committed = [Collections.Generic.List[object]]::new()
try {
    $null = New-Item -ItemType Directory -Path $stageRoot -Force
    $null = New-Item -ItemType Directory -Path $backupRoot -Force

    foreach ($spec in $specs) {
        $asset = $release.assets | Where-Object name -eq $spec.Name | Select-Object -First 1
        $sidecar = $release.assets | Where-Object name -eq "$($spec.Name).sha256" | Select-Object -First 1
        if (-not $asset -or -not $sidecar) { throw "Release $($release.tag_name) is missing $($spec.Name) or its checksum." }
        $expected = ((Invoke-RestMethod -Uri $sidecar.browser_download_url -Headers $headers -UseBasicParsing -TimeoutSec 30) -split '\s+')[0].ToUpperInvariant()
        if ($expected -notmatch '^[0-9A-F]{64}$') { throw "Malformed checksum for $($spec.Name)." }
        $staged = Join-Path $stageRoot $spec.Name
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $staged -Headers $headers -UseBasicParsing -TimeoutSec 120
        $actual = (Get-CompatSha256 -Path $staged).ToUpperInvariant()
        if ($actual -ne $expected) { throw "SHA256 mismatch for $($spec.Name)." }
        if ($spec.PowerShell) {
            Test-CompatPowerShellAsset -Path $staged -Name $spec.Name -RequiredMajor $spec.RequiredMajor
        }
        $target = Join-Path $InstallRoot $spec.Relative
        $baseline = if (Test-Path -LiteralPath $target) { Get-CompatSha256 -Path $target } else { $null }
        $verified.Add([pscustomobject]@{ Spec=$spec; Staged=$staged; Target=$target; Baseline=$baseline; Hash=$actual })
    }

    $coreText = Get-Content -LiteralPath (Join-Path $stageRoot 'Invoke-BootUpdateCycle.ps1') -Raw
    $batchText = Get-Content -LiteralPath (Join-Path $stageRoot 'upd.cmd') -Raw
    if ($coreText -notmatch "BootUpdateCycleVersion'\s*-Value\s*'([\d.]+)'") {
        throw 'Downloaded core version marker is missing.'
    }
    $downloadedCoreVersion = [version]$Matches[1]
    if ($downloadedCoreVersion -ne $remoteVersion) {
        throw 'Downloaded core version does not match the release tag.'
    }
    if ($batchText -notmatch '(?m)^:: BootUpdateCycleVersion=([\d.]+)\s*$') {
        throw 'Downloaded batch version marker is missing.'
    }
    $downloadedBatchVersion = [version]$Matches[1]
    if ($downloadedBatchVersion -ne $remoteVersion) {
        throw 'Downloaded batch version does not match the release tag.'
    }
    if ($batchText -notmatch '(?im)^@echo off\s*$' -or $batchText -notmatch 'Invoke-UpdBootstrap\.ps1') {
        throw 'Downloaded batch failed its stable-bootstrap structure check.'
    }

    foreach ($item in @($verified | Sort-Object { $_.Spec.Batch })) {
        $liveHash = if (Test-Path -LiteralPath $item.Target) { Get-CompatSha256 -Path $item.Target } else { $null }
        if ($liveHash -ne $item.Baseline) { throw "Cloud/local sync changed $($item.Target) during staging; no files were replaced." }
        $relativeBackup = $item.Spec.Relative -replace '[\\/:*?"<>|]','_'
        $snapshot = Join-Path $backupRoot $relativeBackup
        $existed = Test-Path -LiteralPath $item.Target
        if ($existed) { Copy-Item -LiteralPath $item.Target -Destination $snapshot -Force }
        $null = New-Item -ItemType Directory -Path (Split-Path $item.Target -Parent) -Force
        $incoming = "$($item.Target).incoming-$PID"
        $committed.Add([pscustomobject]@{ Target=$item.Target; Snapshot=$snapshot; Existed=$existed })
        Copy-Item -LiteralPath $item.Staged -Destination $incoming -Force
        try {
            Set-CompatStagedFile -Incoming $incoming -Target $item.Target -Snapshot $snapshot -Existed $existed
            if ((Get-CompatSha256 -Path $item.Target).ToUpperInvariant() -ne $item.Hash) {
                throw "Post-copy SHA256 mismatch for $($item.Spec.Name)."
            }
        } finally {
            Remove-Item -LiteralPath $incoming -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($item in $verified) {
        if (-not (Test-Path -LiteralPath $item.Target) -or (Get-CompatSha256 -Path $item.Target).ToUpperInvariant() -ne $item.Hash) {
            throw "Committed bundle verification failed for $($item.Spec.Name)."
        }
    }
} catch {
    for ($index=$committed.Count-1; $index -ge 0; $index--) {
        $item=$committed[$index]
        if ($item.Existed) { Copy-Item -LiteralPath $item.Snapshot -Destination $item.Target -Force }
        else { Remove-Item -LiteralPath $item.Target -Force -ErrorAction SilentlyContinue }
    }
    throw
} finally {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Verified $($release.tag_name) installed at $InstallRoot" -ForegroundColor Green
Write-Host "Previous runtime files are recoverable from $backupRoot" -ForegroundColor DarkGray

$machinePath = [Environment]::GetEnvironmentVariable('Path','Machine')
$machineEntries = @($machinePath -split ';' | Where-Object { $_ })
if ($machineEntries -notcontains $InstallRoot) {
    $newMachinePath = ($machineEntries + $InstallRoot) -join ';'
    if ($newMachinePath.Length -gt 2047) {
        Write-Warning "Machine PATH would exceed 2047 characters; add '$InstallRoot' manually."
    } else {
        [Environment]::SetEnvironmentVariable('Path',$newMachinePath,'Machine')
        Write-Host "Added $InstallRoot to the Machine PATH." -ForegroundColor Green
    }
}
if (@($env:Path -split ';') -notcontains $InstallRoot) { $env:Path = "$InstallRoot;$env:Path" }

if ($PromptForArguments) {
    if ([Console]::IsInputRedirected) {
        throw 'Cannot prompt for updater arguments because console input is redirected. Pass -CommandArguments explicitly.'
    }
    Write-Host ''
    Write-Host 'The verified updater is ready. Choose what it should do now.' -ForegroundColor Cyan
    Write-Host 'Examples: run | run --drivers --delay 120 | aws | help' -ForegroundColor DarkGray
    $argumentLine = Read-Host 'upd command and options [run]'
    if ([string]::IsNullOrWhiteSpace($argumentLine)) { $CommandArguments = @('run') }
    else { $CommandArguments = @(ConvertFrom-CompatCommandLine -Line $argumentLine) }
    if (-not $CommandArguments.Count) { $CommandArguments = @('run') }
}

& $targetBatch @CommandArguments
exit $LASTEXITCODE

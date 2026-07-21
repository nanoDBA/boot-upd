#requires -Version 7.0
# ------------------------------------------------------------------------------
# File:        Deploy-BootUpdateCycle.ps1
# Description: Single-file paste-to-deploy boot update cycle installer
# Purpose:     Deploys Invoke-BootUpdateCycle.ps1 to ProgramData, runs the first
#              iteration directly in user context (critical for user-scope winget),
#              and registers a scheduled task only if reboots are needed.
# Created:     2025-01-10
# Modified:    2026-04-25
# ------------------------------------------------------------------------------
[CmdletBinding()]
param(
    [int]$RebootDelaySec,
    [ValidateSet('Quiet','Normal','Verbose','Debug')][string]$OutputMode,
    [ValidateRange(1,50)][int]$MaxIterations,
    [ValidateRange(1,50)][int]$MaxRetryPasses,
    [ValidateRange(1,1440)][int]$PackageTimeoutMinutes,
    [switch]$StagedRollout,
    [switch]$AggressiveRepair,
    [switch]$IncludeDriverUpdates,
    [switch]$IncludeFirmwareUpdates,
    [switch]$UpdateWsl,
    [switch]$UpdateContainers,
    [switch]$AllowMetered,
    [switch]$EnableRestorePoint,
    [switch]$EnableDotnetTools,
    [switch]$EnableAwsTooling,
    [switch]$SkipPip,
    [switch]$SkipNpm,
    [switch]$SkipOffice365,
    [switch]$SkipPowerShellModules,
    [switch]$SkipScoop,
    [switch]$SkipVscode,
    [switch]$SkipDefender,
    [switch]$SkipHealthCheck,
    [switch]$SkipBitLocker,
    [switch]$DisableSelfUpdate,
    [string[]]$ExcludePatterns = @(),
    [string[]]$IncludePatterns = @(),
    [switch]$NonInteractive
)
<#
.SYNOPSIS
    Deploy and start the boot update cycle.  Run as admin, walk away.

.DESCRIPTION
    Copies Invoke-BootUpdateCycle.ps1 from the source directory to
    $env:ProgramData\BootUpdateCycle, installs required modules, and starts
    the first iteration directly in user context.

    WINGET SCOPE STRATEGY:
    - First run (user context): Updates BOTH user-scope AND machine-scope packages
    - Subsequent runs (SYSTEM): Machine-scope only
    - First run MUST be direct — it's the only chance for user-scope!

    The update cycle:
    - Winget, Chocolatey, Windows Update, pip, npm, Office 365,
      PowerShell modules, Scoop, dotnet tools, VS Code extensions
    - Reboots when updates require it, repeats until clean
    - Self-destructs when done

.NOTES
    Run as Administrator in PowerShell 7+
    Requires: Invoke-BootUpdateCycle.ps1 in the same directory

    To REMOVE (emergency stop):
    Unregister-ScheduledTask -TaskName 'BootUpdateCycle' -Confirm:$false
    Remove-Item "$env:ProgramData\BootUpdateCycle" -Recurse -Force
#>

#region Configuration - EDIT THESE
$Config = @{
    SkipPip               = $false  # Set $true to skip pip package updates
    SkipNpm               = $false  # Set $true to skip npm global package updates
    SkipOffice365         = $false  # Set $true to skip Office 365 Click-to-Run updates
    SkipAwsTooling        = $true   # Set $false to enable AWS CLI/module repair
    SkipPowerShellModules = $false  # Set $true to skip PowerShell module updates
    SkipScoop             = $false  # Set $true to skip Scoop package updates
    SkipDotnetTools       = $true   # OFF by default - can break SDK-dependent builds!
    SkipVscode            = $false  # Set $true to skip VS Code extension updates
    SkipDefender          = $false  # Set $true to skip Defender signature updates
    SkipRestorePoint      = $true   # Skip system restore point creation (opt-in: set $false to enable)
    SkipHealthCheck       = $false  # Skip post-update health check for critical services
    StagedRollout         = $false  # Run one package manager per boot instead of all at once. Slower but safer.
    AggressiveRepair      = $false  # Explicit opt-in: attempt Winget repair/force reinstall for failures
    IncludeDriverUpdates  = $false  # Opt in to Windows driver updates
    IncludeFirmwareUpdates = $false # Opt in to firmware updates
    UpdateWsl             = $false  # Opt in to WSL kernel/distribution updates
    UpdateContainers      = $false  # Opt in to Docker/Podman image refresh
    AllowMetered          = $false  # Permit metered network use
    SkipBitLocker         = $false  # Do not suspend BitLocker for one orchestrated reboot
    DisableSelfUpdate     = $false  # Suppress GitHub release self-update
    MaxIterations         = 5       # Safety valve for reboot loops
    MaxRetryPasses        = 5       # Consecutive same-boot recovery failures
    PackageTimeoutMin     = 30      # Minutes before killing a hung package manager (hard timeout)
                                    # Smart idle detection kills stuck processes after 5 min of no CPU
    RebootDelaySec        = 0       # Seconds before forced reboot (0 = immediate, /f = force-close apps, no abort)
    StartNow              = $true   # Start immediately after deployment
    InstallDir            = "$env:ProgramData\BootUpdateCycle"

    <# EXECUTION CONTEXT - READ THIS #>
    DirectFirstRun        = $true   # *** RECOMMENDED: First run in YOUR console (user context)
                                    #     - Updates BOTH user-scope AND machine-scope winget packages
                                    #     - If reboot: task registered, subsequent runs as SYSTEM
                                    # Set $false for headless: all runs as SYSTEM (no user-scope)

    RunAsUser             = $false  # Only matters if DirectFirstRun = $false
    NonInteractive        = $false  # Set $true for fire-and-forget: no prompts, no TUI
    OutputMode            = 'Normal' # Quiet | Normal | Verbose | Debug; interactive runs can cycle with v

    <# NOTIFICATIONS - leave empty to disable #>
    WebhookUrl            = ''     # One-time HTTPS bootstrap only; persisted to protected ProgramData, never task arguments
    NotifyEmail           = ''     # Recipient email (leave empty to disable)
    SmtpServer            = ''     # SMTP relay hostname (e.g., smtp.office365.com)

    <# MAINTENANCE WINDOW - leave -1 to run at any time #>
    MaintenanceWindowStart = -1   # Hour of day (0-23) when updates may start. -1 = no restriction. e.g., 2 = start at 2 AM
    MaintenanceWindowEnd   = -1   # Hour of day when updates must stop. -1 = no restriction. Supports midnight-crossing: Start=22, End=2 = 10 PM to 2 AM

    # Package name patterns to skip (substring match, case-insensitive). e.g. @('Teams', 'OneDrive')
    ExcludePatterns        = @()
    IncludePatterns        = @()
}

# Apply command-line parameter overrides
if ($PSBoundParameters.ContainsKey('RebootDelaySec')) { $Config.RebootDelaySec = $RebootDelaySec }
if ($PSBoundParameters.ContainsKey('OutputMode')) { $Config.OutputMode = $OutputMode }
if ($PSBoundParameters.ContainsKey('MaxIterations')) { $Config.MaxIterations = $MaxIterations }
if ($PSBoundParameters.ContainsKey('MaxRetryPasses')) { $Config.MaxRetryPasses = $MaxRetryPasses }
if ($PSBoundParameters.ContainsKey('PackageTimeoutMinutes')) { $Config.PackageTimeoutMin = $PackageTimeoutMinutes }
foreach ($name in @('StagedRollout','AggressiveRepair','IncludeDriverUpdates','IncludeFirmwareUpdates','UpdateWsl','UpdateContainers','AllowMetered','SkipPip','SkipNpm','SkipOffice365','SkipPowerShellModules','SkipScoop','SkipVscode','SkipDefender','SkipHealthCheck','SkipBitLocker','DisableSelfUpdate')) {
    if ($PSBoundParameters.ContainsKey($name)) { $Config[$name] = $true }
}
if ($EnableRestorePoint) { $Config.SkipRestorePoint = $false }
if ($EnableDotnetTools) { $Config.SkipDotnetTools = $false }
if ($EnableAwsTooling) { $Config.SkipAwsTooling = $false }
if ($PSBoundParameters.ContainsKey('ExcludePatterns')) { $Config.ExcludePatterns = @($ExcludePatterns) }
if ($PSBoundParameters.ContainsKey('IncludePatterns')) { $Config.IncludePatterns = @($IncludePatterns) }
if ($NonInteractive) { $Config.NonInteractive = $true }
#endregion

#region Validation
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7+ required. Current: $($PSVersionTable.PSVersion)"
}
if ($Config.OutputMode -notin @('Quiet','Normal','Verbose','Debug')) {
    throw "OutputMode must be Quiet, Normal, Verbose, or Debug. Current: $($Config.OutputMode)"
}
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run as Administrator."
}
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
#endregion

function Set-BootUpdateInstallDirectoryAcl {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        $null = New-Item -ItemType Directory -Path $Path -Force
    }
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $users = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    foreach ($sid in @($administrators, $system)) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $sid, [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance, $propagation, $allow
        ))
    }
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $users, [Security.AccessControl.FileSystemRights]::ReadAndExecute,
        $inheritance, $propagation, $allow
    ))
    $acl.SetOwner($administrators)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Set-BootUpdateWebhookSecret {
    param(
        [Parameter(Mandatory)][ValidatePattern('^https://')][string]$Url,
        [Parameter(Mandatory)][string]$InstallDirectory
    )

    Set-BootUpdateInstallDirectoryAcl -Path $InstallDirectory
    $secretPath = Join-Path $InstallDirectory 'webhook-url.secret'
    $tempPath = Join-Path $InstallDirectory ('.webhook-url.{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        $null = New-Item -ItemType File -Path $tempPath -Force
        $acl = [Security.AccessControl.FileSecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        $allow = [Security.AccessControl.AccessControlType]::Allow
        $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
        $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
        foreach ($sid in @($administrators, $system)) {
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                $sid, [Security.AccessControl.FileSystemRights]::FullControl, $allow
            ))
        }
        $acl.SetOwner($administrators)
        Set-Acl -LiteralPath $tempPath -AclObject $acl
        [IO.File]::WriteAllText($tempPath, $Url, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tempPath -Destination $secretPath -Force
        Set-Acl -LiteralPath $secretPath -AclObject $acl
    } finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

#region Deploy
Write-Host "`n=== Boot Update Cycle Deployment ===" -ForegroundColor Cyan

<# Ensure required modules are installed #>
$requiredModules = @(
    @{ Name = 'PSWindowsUpdate'; Scope = 'AllUsers' }
    @{ Name = 'BurntToast'; Scope = 'CurrentUser' }
)
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable $mod.Name)) {
        Write-Host "Installing module: $($mod.Name)..."
        Install-Module $mod.Name -Force -Scope $mod.Scope -AllowClobber -AcceptLicense
    } else {
        Write-Host "Module already installed: $($mod.Name)"
    }
}

$installDir = $Config.InstallDir
if (-not (Test-Path -LiteralPath $installDir)) {
    Write-Host "Created: $installDir"
}
Set-BootUpdateInstallDirectoryAcl -Path $installDir
if (-not [string]::IsNullOrWhiteSpace($Config.WebhookUrl)) {
    Set-BootUpdateWebhookSecret -Url $Config.WebhookUrl -InstallDirectory $installDir
    $Config.WebhookUrl = ''
    Write-Host 'Webhook URL stored in protected ProgramData configuration.' -ForegroundColor Green
}

<# Deploy Invoke script from source directory (no more embedded here-string duplication) #>
$sourceInvoke = Join-Path $PSScriptRoot 'Invoke-BootUpdateCycle.ps1'
if (-not (Test-Path $sourceInvoke)) {
    throw "Source script not found: $sourceInvoke  (Deploy and Invoke must be in the same directory)"
}

<# Self-update the SOURCE copy from GitHub before deploying (lz1 companion).
   Invoke's own self-update only replaces the live ProgramData copy — without this
   step, every deploy re-copies the stale source and re-downloads the same update.
   Updating the source here makes the update stick and skips the redundant download.
   Best-effort: any failure logs a warning and deploys the existing source. #>
if ([string]::IsNullOrEmpty($env:BOOT_UPDATE_NO_SELF_UPDATE) -and -not $Config.DisableSelfUpdate) {
    try {
        $srcRaw = Get-Content $sourceInvoke -Raw -ErrorAction Stop
        $currentVer = $null
        if ($srcRaw -match "BootUpdateCycleVersion'\s*-Value\s*'([\d.]+)'") {
            $currentVer = [System.Version]::new($matches[1])
        }
        if (-not $currentVer) { throw "could not parse BootUpdateCycleVersion from $sourceInvoke" }

        Write-Host "Source self-update: local v$currentVer — checking GitHub for newer release..."
        $releaseInfo = Invoke-RestMethod `
            -Uri 'https://api.github.com/repos/nanoDBA/boot-upd/releases/latest' `
            -TimeoutSec 15 `
            -Headers @{ 'User-Agent' = 'BootUpdateCycle' } `
            -ErrorAction Stop
        $remoteVer = [System.Version]::new(($releaseInfo.tag_name -replace '^v', ''))

        $coreUpdateNeeded = $remoteVer -gt $currentVer
        $bundleEligible = $remoteVer -ge $currentVer
        if ($remoteVer -lt $currentVer) { Write-Host "Source self-update: local v$currentVer is newer than published v$remoteVer; no downgrade." -ForegroundColor Yellow }
        elseif (-not $coreUpdateNeeded) { Write-Host "Source self-update: already on latest core (v$currentVer); verifying launcher companions." }
        else {
            Write-Host "Source self-update: v$currentVer -> v$remoteVer." -ForegroundColor Cyan
        }
        <# Replacing this running Deploy script is safe: pwsh parsed the whole file
           at startup, so the new copy applies next run. Launcher companions are
           verified even when the core version is current, which bootstraps them
           on the run after an older Deploy script updates itself. #>
        $sourceAssets = @(
            [pscustomobject]@{ Name='Invoke-BootUpdateCycle.ps1';   RelativeTarget='Invoke-BootUpdateCycle.ps1'; Required=$true;  PowerShell=$true;  Core=$true }
            [pscustomobject]@{ Name='Deploy-BootUpdateCycle.ps1';   RelativeTarget='Deploy-BootUpdateCycle.ps1'; Required=$true; PowerShell=$true;  Core=$true }
            [pscustomobject]@{ Name='Invoke-UpdLauncher.ps1';        RelativeTarget='tools\Invoke-UpdLauncher.ps1'; Required=$true; PowerShell=$true; Core=$false }
            [pscustomobject]@{ Name='Invoke-UpdBootstrap.ps1';       RelativeTarget='tools\Invoke-UpdBootstrap.ps1'; Required=$true; PowerShell=$true; Core=$false }
            [pscustomobject]@{ Name='Show-BootUpdateProgressDemo.ps1'; RelativeTarget='tools\Show-BootUpdateProgressDemo.ps1'; Required=$true; PowerShell=$true; Core=$false }
            [pscustomobject]@{ Name='Install-PowerShell7.ps1';         RelativeTarget='tools\Install-PowerShell7.ps1'; Required=$true; PowerShell=$true; Core=$false }
            [pscustomobject]@{ Name='Repair-AwsTooling.ps1';         RelativeTarget='Repair-AwsTooling.ps1';      Required=$true; PowerShell=$true; Core=$false }
            [pscustomobject]@{ Name='Export-BootUpdateDiagnostics.ps1'; RelativeTarget='Export-BootUpdateDiagnostics.ps1'; Required=$true; PowerShell=$true; Core=$false }
            [pscustomobject]@{ Name='upd.cmd';                       RelativeTarget='upd.cmd';                    Required=$true; PowerShell=$false; Core=$false }
        )
        $sourceTempRoot = Join-Path ([IO.Path]::GetTempPath()) ('boot-upd-source-bundle-{0}' -f [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $sourceTempRoot -ErrorAction Stop
        $verifiedSourceAssets = [Collections.Generic.List[object]]::new()
        foreach ($sourceAsset in $sourceAssets) {
            if (-not $bundleEligible) { break }
            if ($sourceAsset.Core -and -not $coreUpdateNeeded) { continue }
            $assetName = $sourceAsset.Name
            $asset = $releaseInfo.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
            $shaAsset = $releaseInfo.assets | Where-Object { $_.name -eq "$assetName.sha256" } | Select-Object -First 1
            if (-not $asset -or -not $shaAsset) { throw "release $($releaseInfo.tag_name) has no '$assetName' asset/checksum pair" }
            Write-Host "Source self-update: downloading $assetName..."
            $tempPath = Join-Path $sourceTempRoot $assetName
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tempPath -TimeoutSec 60 -Headers @{ 'User-Agent' = 'BootUpdateCycle' } -ErrorAction Stop
            if ($sourceAsset.PowerShell) { $null = [scriptblock]::Create((Get-Content $tempPath -Raw -ErrorAction Stop)) }
            else {
                $batchText = Get-Content $tempPath -Raw -ErrorAction Stop
                if ($batchText -notmatch '(?im)^@echo off\s*$' -or $batchText -notmatch 'Invoke-UpdLauncher\.ps1') { throw 'Downloaded upd.cmd failed its launcher structure check.' }
            }
            $shaContent = Invoke-RestMethod -Uri $shaAsset.browser_download_url -TimeoutSec 15 -Headers @{ 'User-Agent' = 'BootUpdateCycle' } -ErrorAction Stop
            $expectedSha = ($shaContent -split '\s+')[0].Trim().ToUpperInvariant()
            if ($expectedSha -notmatch '^[0-9A-F]{64}$') { throw "release $($releaseInfo.tag_name) provides no valid SHA256 for $assetName" }
            $actualSha = (Get-FileHash -Path $tempPath -Algorithm SHA256).Hash.ToUpperInvariant()
            if ($actualSha -ne $expectedSha) { throw "SHA256 mismatch for $assetName (expected=$expectedSha actual=$actualSha)" }
            $verifiedSourceAssets.Add([pscustomobject]@{ Spec=$sourceAsset; Temp=$tempPath; Hash=$actualSha })
            Write-Host "Source self-update: $assetName SHA256 verified."
        }

        $sourceCommitted = [Collections.Generic.List[object]]::new()
        try {
            foreach ($item in $verifiedSourceAssets) {
                $sourceAsset = $item.Spec
                $target = Join-Path $PSScriptRoot $sourceAsset.RelativeTarget
                $targetDirectory = Split-Path -Parent $target
                if (-not (Test-Path -LiteralPath $targetDirectory)) { New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null }
                $destination = $target
                if ($sourceAsset.Name -eq 'upd.cmd' -and (Test-Path -LiteralPath $target)) {
                    $currentBatch = Get-Content -LiteralPath $target -Raw -ErrorAction SilentlyContinue
                    if ($currentBatch -match 'upd\.cmd\.next') { $destination = "$target.next" }
                }
                if ((Test-Path -LiteralPath $target) -and (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $item.Hash) {
                    if ($destination -ne $target) { Remove-Item -LiteralPath $destination,"$destination.sha256","$destination.baseline" -Force -ErrorAction SilentlyContinue }
                    continue
                }
                $snapshot = Join-Path $sourceTempRoot ("rollback-{0}" -f $sourceCommitted.Count)
                $existed = Test-Path -LiteralPath $destination
                if ($existed) { Copy-Item -LiteralPath $destination -Destination $snapshot -Force }
                $isStaged = $destination -ne $target
                $sidecarPath = "$destination.sha256"
                $sidecarSnapshot = "$snapshot.sha256"
                $baselinePath = "$destination.baseline"
                $baselineSnapshot = "$snapshot.baseline"
                $sidecarExisted = $isStaged -and (Test-Path -LiteralPath $sidecarPath)
                $baselineExisted = $isStaged -and (Test-Path -LiteralPath $baselinePath)
                if ($sidecarExisted) { Copy-Item -LiteralPath $sidecarPath -Destination $sidecarSnapshot -Force }
                if ($baselineExisted) { Copy-Item -LiteralPath $baselinePath -Destination $baselineSnapshot -Force }
                $sourceCommitted.Add([pscustomobject]@{ Destination=$destination; Snapshot=$snapshot; Existed=$existed; SidecarPath=$sidecarPath; SidecarSnapshot=$sidecarSnapshot; SidecarExisted=$sidecarExisted; BaselinePath=$baselinePath; BaselineSnapshot=$baselineSnapshot; BaselineExisted=$baselineExisted; Staged=$isStaged })
                $sourceMutationStarted = $true
                $incoming = "$destination.incoming-$PID"
                Copy-Item -LiteralPath $item.Temp -Destination $incoming -Force
                Move-Item -LiteralPath $incoming -Destination $destination -Force
                if ($isStaged) {
                    Set-Content -LiteralPath $sidecarPath -Value $item.Hash -Encoding ascii -NoNewline
                    $baselineHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToUpperInvariant()
                    Set-Content -LiteralPath $baselinePath -Value $baselineHash -Encoding ascii -NoNewline
                }
                $commitVerb = if ($isStaged) { 'verified and staged for delayed activation' } else { 'verified and installed' }
                Write-Host "Source self-update: $($sourceAsset.Name) $commitVerb." -ForegroundColor Green
            }
        } catch {
            for ($index=$sourceCommitted.Count-1; $index -ge 0; $index--) {
                $entry=$sourceCommitted[$index]
                if ($entry.Existed) { Copy-Item -LiteralPath $entry.Snapshot -Destination $entry.Destination -Force }
                else { Remove-Item -LiteralPath $entry.Destination -Force -ErrorAction SilentlyContinue }
                if ($entry.Staged) {
                    if ($entry.SidecarExisted) { Copy-Item -LiteralPath $entry.SidecarSnapshot -Destination $entry.SidecarPath -Force }
                    else { Remove-Item -LiteralPath $entry.SidecarPath -Force -ErrorAction SilentlyContinue }
                    if ($entry.BaselineExisted) { Copy-Item -LiteralPath $entry.BaselineSnapshot -Destination $entry.BaselinePath -Force }
                    else { Remove-Item -LiteralPath $entry.BaselinePath -Force -ErrorAction SilentlyContinue }
                }
            }
            throw "source bundle commit failed and was rolled back: $_"
        }
        if ($coreUpdateNeeded) { Write-Host "Source self-update: source updated to v$remoteVer." -ForegroundColor Green }
    } catch {
        if ($sourceTempRoot -and (Test-Path -LiteralPath $sourceTempRoot)) { Remove-Item -LiteralPath $sourceTempRoot -Recurse -Force -ErrorAction SilentlyContinue }
        if ($sourceMutationStarted) { throw }
        Write-Host "Source self-update: skipped — $_" -ForegroundColor Yellow
    } finally {
        if ($sourceTempRoot -and (Test-Path -LiteralPath $sourceTempRoot)) { Remove-Item -LiteralPath $sourceTempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-Host 'Source self-update: disabled by configuration or BOOT_UPDATE_NO_SELF_UPDATE.'
}

$scriptPath = Join-Path $installDir 'Invoke-BootUpdateCycle.ps1'
$copySourceToLive = $true
if (Test-Path -LiteralPath $scriptPath) {
    try {
        $sourceRaw = Get-Content -LiteralPath $sourceInvoke -Raw -ErrorAction Stop
        $liveRaw = Get-Content -LiteralPath $scriptPath -Raw -ErrorAction Stop
        if ($sourceRaw -match "BootUpdateCycleVersion'\s*-Value\s*'([\d.]+)'") {
            $sourceVersion = [System.Version]::new($matches[1])
        }
        if ($liveRaw -match "BootUpdateCycleVersion'\s*-Value\s*'([\d.]+)'") {
            $liveVersion = [System.Version]::new($matches[1])
        }
        if ($null -ne $sourceVersion -and $null -ne $liveVersion -and $liveVersion -gt $sourceVersion) {
            $copySourceToLive = $false
            Write-Host "Preserved newer deployed orchestrator: v$liveVersion (source is v$sourceVersion)." -ForegroundColor Yellow
        }
    } catch {
        Write-Verbose "Could not compare source/deployed versions; deploying source copy: $_"
    }
}
if ($copySourceToLive) {
    Copy-Item $sourceInvoke $scriptPath -Force
    Write-Host "Deployed: $scriptPath"
}

<# Also copy companion scripts if present #>
foreach ($companion in @('Repair-AwsTooling.ps1','Export-BootUpdateDiagnostics.ps1')) {
    $src = Join-Path $PSScriptRoot $companion
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $installDir $companion) -Force
        Write-Host "Deployed: $companion"
    }
}

<# Deploy uninstall helper script #>
$uninstallScript = @'
#requires -RunAsAdministrator
param([switch]$RemoveFolder)
<# Uninstall: stops task, removes task (incl. ARSO fallback). Use -RemoveFolder to also delete logs/history. #>
foreach ($taskName in @('BootUpdateCycle', 'BootUpdateCycleFallback')) {
    $task = Get-ScheduledTask -TaskName $taskName -EA SilentlyContinue
    if ($task) {
        if ($task.State -eq 'Running') { Stop-ScheduledTask -TaskName $taskName; Write-Host "Task stopped: $taskName" }
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "Task '$taskName' removed." -ForegroundColor Green
    } else {
        Write-Host "Task '$taskName' not found." -ForegroundColor Yellow
    }
}
if ($RemoveFolder) {
    $targetDir = $PSScriptRoot
    $originalDir = (Get-Location).Path
    Set-Location $env:TEMP  <# Step out so we can delete the folder #>
    Start-Sleep -Milliseconds 500  <# Brief pause for file handles to release #>
    Remove-Item $targetDir -Recurse -Force -EA SilentlyContinue
    if (Test-Path $targetDir) {
        Write-Host "Warning: Could not fully remove $targetDir" -ForegroundColor Yellow
        Write-Host "  Some files may be locked. Try again after reboot, or delete manually."
    } else {
        Write-Host "Folder removed: $targetDir" -ForegroundColor Green
    }
    if (($originalDir -ne $targetDir) -and (Test-Path $originalDir)) {
        Set-Location $originalDir
    }
} else {
    Write-Host "Logs/history retained at: $PSScriptRoot" -ForegroundColor Cyan
    Write-Host "  To remove: & '$PSScriptRoot\Uninstall.ps1' -RemoveFolder"
}
'@
$uninstallPath = Join-Path $installDir 'Uninstall.ps1'
$uninstallScript | Set-Content -Path $uninstallPath -Force -Encoding UTF8
Write-Host "Deployed: $uninstallPath"

<#
    DIRECT-FIRST-RUN ARCHITECTURE:

    First run executes directly in user's console (user context) — ONLY chance for user-scope winget.
    If reboot needed: Invoke script registers a scheduled task (SYSTEM) before shutdown.
    If no reboot: done immediately, no task ever created.
#>
$taskName = 'BootUpdateCycle'

<# Stop and remove existing tasks from previous runs (incl. ARSO fallback) #>
foreach ($tn in @('BootUpdateCycle', 'BootUpdateCycleFallback')) {
    $existingTask = Get-ScheduledTask -TaskName $tn -EA SilentlyContinue
    if ($existingTask) {
        if ($existingTask.State -eq 'Running') {
            Stop-ScheduledTask -TaskName $tn
            Write-Host "Stopped running task: $tn" -ForegroundColor Yellow
            Start-Sleep -Seconds 2
        }
        Unregister-ScheduledTask -TaskName $tn -Confirm:$false
        Write-Host "Removed existing task: $tn"
    }
}

<# Reset state on re-deploy (fresh cycle) #>
$statePath = Join-Path $installDir 'BootUpdateCycle.state.json'
if (Test-Path $statePath) {
    Remove-Item $statePath -Force
    Write-Host "Reset state file (starting fresh cycle)"
}

Write-Host "Deployed scripts to: $installDir" -ForegroundColor Green
Write-Host "  First run: Direct (user context - updates user+machine winget scopes)"
Write-Host "  If reboot: Task registered for SYSTEM at startup (machine scope only)"

<# Common arg splatting for all execution modes #>
$invokeArgs = @{
    Force                = $true
    MaxIterations        = $Config.MaxIterations
    MaxRetryPasses       = $Config.MaxRetryPasses
    PackageTimeoutMinutes = $Config.PackageTimeoutMin
    RebootDelaySec       = $Config.RebootDelaySec
    OutputMode           = $Config.OutputMode
    SkipPip              = $Config.SkipPip
    SkipNpm              = $Config.SkipNpm
    SkipOffice365        = $Config.SkipOffice365
    SkipAwsTooling       = $Config.SkipAwsTooling
    SkipPowerShellModules = $Config.SkipPowerShellModules
    SkipScoop            = $Config.SkipScoop
    SkipDotnetTools      = $Config.SkipDotnetTools
    SkipVscode           = $Config.SkipVscode
    SkipDefender         = $Config.SkipDefender
    IncludeDriverUpdates = $Config.IncludeDriverUpdates
    IncludeFirmwareUpdates = $Config.IncludeFirmwareUpdates
    UpdateWsl            = $Config.UpdateWsl
    UpdateContainers     = $Config.UpdateContainers
    SkipRestorePoint     = $Config.SkipRestorePoint
    SkipHealthCheck      = $Config.SkipHealthCheck
    SkipBitLocker        = $Config.SkipBitLocker
    AllowMetered         = $Config.AllowMetered
    DisableSelfUpdate    = $Config.DisableSelfUpdate
    StagedRollout        = $Config.StagedRollout
    AggressiveRepair     = $Config.AggressiveRepair
    NotifyEmail             = $Config.NotifyEmail
    SmtpServer              = $Config.SmtpServer
    MaintenanceWindowStart  = $Config.MaintenanceWindowStart
    MaintenanceWindowEnd    = $Config.MaintenanceWindowEnd
    ExcludePatterns         = $Config.ExcludePatterns
    IncludePatterns         = $Config.IncludePatterns
}

function Invoke-DeployedCycle {
    <# Tell the live orchestrator which launcher/source directory to repair after
       self-update. The environment value also crosses the re-exec boundary. #>
    $previousSourceDir = $env:BOOT_UPDATE_SOURCE_DIR
    $env:BOOT_UPDATE_SOURCE_DIR = $PSScriptRoot
    try {
        & $scriptPath @invokeArgs
    } finally {
        if ($null -eq $previousSourceDir) {
            Remove-Item Env:BOOT_UPDATE_SOURCE_DIR -ErrorAction SilentlyContinue
        } else {
            $env:BOOT_UPDATE_SOURCE_DIR = $previousSourceDir
        }
    }
}

<# TUI: Modal overlay with deployment info #>
function Show-DeploymentModal {
    param(
        [string]$InstallDir,
        [string]$UninstallPath,
        [string]$TaskName,
        [bool]$DirectFirstRun = $true
    )

    $e = [char]27
    $bold = "$e[1m"; $dim = "$e[2m"; $reset = "$e[0m"
    $cyan = "$e[36m"; $green = "$e[32m"; $yellow = "$e[33m"; $white = "$e[97m"; $red = "$e[31m"

    $w = 90
    $bar = "=" * $w
    $sep = "-" * $w

    Clear-Host
    Write-Host ""
    Write-Host "$cyan$bold$bar$reset"
    Write-Host ""
    Write-Host "$cyan$bold   [OK] BOOT UPDATE CYCLE - READY TO START$reset"
    Write-Host ""
    Write-Host "$cyan$sep$reset"
    Write-Host ""

    if ($DirectFirstRun) {
        Write-Host "$yellow   EXECUTION MODE: DIRECT (user context)$reset"
        Write-Host ""
        Write-Host "$white   First run executes directly in THIS console as $($env:USERNAME)$reset"
        Write-Host "$green   + Winget: Updates BOTH user-scope AND machine-scope packages$reset"
        Write-Host "$dim     (This is the ONLY opportunity for user-scoped packages!)$reset"
        Write-Host ""
        Write-Host "$dim   If reboot needed: Scheduled task created, subsequent runs as SYSTEM$reset"
        Write-Host "$dim   If no reboot:     Done immediately, no task ever created$reset"
        Write-Host ""
        Write-Host "$red   WARNING: Script runs in THIS console.$reset"
        Write-Host "$red   Do NOT log off until complete or reboot begins.$reset"
        Write-Host "$dim   Lock screen (Win+L) is safe.$reset"
    } else {
        Write-Host "$yellow   EXECUTION MODE: SCHEDULED TASK (SYSTEM context)$reset"
        Write-Host ""
        Write-Host "$red   WARNING: Running as SYSTEM - user-scope winget packages will NOT be updated!$reset"
        Write-Host "$dim   Only machine-scope packages will be touched.$reset"
        Write-Host ""
        Write-Host "$dim   To update user-scope packages, set DirectFirstRun = `$true in Config$reset"
    }
    Write-Host ""
    Write-Host "$cyan$sep$reset"
    Write-Host ""
    Write-Host "$dim   Install directory:$reset"
    Write-Host "$white   $InstallDir$reset"
    Write-Host ""
    Write-Host "$cyan$sep$reset"
    Write-Host ""
    Write-Host "$yellow   COMMANDS$reset"
    Write-Host ""
    Write-Host "$dim   Monitor log:$reset"
    Write-Host "$white   Get-Content '$InstallDir\BootUpdateCycle.log' -Tail 50 -Wait$reset"
    Write-Host ""
    Write-Host "$dim   Uninstall (keep logs):$reset"
    Write-Host "$white   & '$UninstallPath'$reset"
    Write-Host ""
    Write-Host "$dim   Full cleanup:$reset"
    Write-Host "$white   & '$UninstallPath' -RemoveFolder$reset"
    Write-Host ""
    Write-Host "$cyan$sep$reset"
    Write-Host ""
    Write-Host "$green   >>> Press any key to START <<<$reset"
    Write-Host ""
    Write-Host "$cyan$bold$bar$reset"
    Write-Host ""
}

function Start-PersistentHeaderLogTail {
    param([string]$LogPath, [string]$UninstallPath)

    $e = [char]27
    $cyan = "$e[36m"; $green = "$e[32m"; $yellow = "$e[33m"; $red = "$e[31m"
    $dim = "$e[2m"; $bold = "$e[1m"; $reset = "$e[0m"
    $hideCursor = "$e[?25l"; $showCursor = "$e[?25h"

    $header = @(
        ""
        "$cyan$bold=================================================================================$reset"
        "$cyan$bold  BOOT UPDATE CYCLE - LIVE LOG                               Ctrl+C to exit$reset"
        "$cyan$bold=================================================================================$reset"
        ""
        "$dim  Uninstall (keep logs):$reset"
        "$green  & '$UninstallPath'$reset"
        ""
        "$dim  Full cleanup:$reset"
        "$green  & '$UninstallPath' -RemoveFolder$reset"
        ""
        "$cyan---------------------------------------------------------------------------------$reset"
    )
    $headerHeight = $header.Count

    $screenHeight = [Console]::WindowHeight
    $screenWidth = [Console]::WindowWidth
    $logAreaStart = $headerHeight
    $logAreaHeight = $screenHeight - $headerHeight - 1
    if ($logAreaHeight -lt 5) { $logAreaHeight = 15 }

    [Console]::Clear()
    Write-Host $hideCursor -NoNewline
    foreach ($line in $header) { Write-Host $line }

    if (-not (Test-Path $LogPath)) {
        [Console]::SetCursorPosition(0, $logAreaStart)
        Write-Host "$yellow  Waiting for log file...$reset"
        while (-not (Test-Path $LogPath)) { Start-Sleep -Seconds 1 }
    }

    $lastLength = 0
    $cycleComplete = $false

    try {
        while (-not $cycleComplete) {
            $fileInfo = Get-Item $LogPath -EA SilentlyContinue
            if ($fileInfo -and $fileInfo.Length -ne $lastLength) {
                $logContent = Get-Content $LogPath -Tail $logAreaHeight -EA SilentlyContinue
                $lastLength = $fileInfo.Length

                $logText = $logContent -join "`n"
                if ($logText -match 'Scheduled task removed') { $cycleComplete = $true }

                [Console]::SetCursorPosition(0, $logAreaStart)
                $lineNum = 0
                foreach ($line in $logContent) {
                    if ($lineNum -ge $logAreaHeight) { break }
                    if ($line.Length -gt ($screenWidth - 1)) { $line = $line.Substring(0, $screenWidth - 4) + "..." }
                    $padded = $line.PadRight($screenWidth - 1)
                    if ($line -match '\[Error\]') { Write-Host "$red$padded$reset" }
                    elseif ($line -match '\[Warn\]') { Write-Host "$yellow$padded$reset" }
                    else { Write-Host "$padded" }
                    $lineNum++
                }
                $emptyLine = "".PadRight($screenWidth - 1)
                while ($lineNum -lt $logAreaHeight) { Write-Host $emptyLine; $lineNum++ }
            }
            Start-Sleep -Milliseconds 300
        }
        Write-Host ""
        Write-Host "$green$bold  CYCLE COMPLETE - Exiting log viewer...$reset"
        Start-Sleep -Seconds 2
    } finally {
        Write-Host $showCursor -NoNewline
        [Console]::SetCursorPosition(0, $screenHeight - 1)
    }
}

<# Helper: Register scheduled task for non-direct mode #>
function Register-ScheduledTaskNow {
    $pwshPath = (Get-Command pwsh -EA SilentlyContinue).Source
    if (-not $pwshPath) { $pwshPath = "$env:ProgramFiles\PowerShell\7\pwsh.exe" }

    $taskArgs = @(
        '-NoProfile', '-ExecutionPolicy Bypass'
        "-File `"$scriptPath`"", '-Force'
        "-MaxIterations $($Config.MaxIterations)"
        "-MaxRetryPasses $($Config.MaxRetryPasses)"
        "-PackageTimeoutMinutes $($Config.PackageTimeoutMin)"
        "-RebootDelaySec $($Config.RebootDelaySec)"
        "-OutputMode $($Config.OutputMode)"
    )
    if ($Config.SkipPip)              { $taskArgs += '-SkipPip' }
    if ($Config.AggressiveRepair)     { $taskArgs += '-AggressiveRepair' }
    if ($Config.SkipNpm)              { $taskArgs += '-SkipNpm' }
    if ($Config.SkipOffice365)        { $taskArgs += '-SkipOffice365' }
    if ($Config.SkipAwsTooling)       { $taskArgs += '-SkipAwsTooling' }
    if ($Config.SkipPowerShellModules){ $taskArgs += '-SkipPowerShellModules' }
    if ($Config.SkipScoop)            { $taskArgs += '-SkipScoop' }
    if ($Config.SkipDotnetTools)      { $taskArgs += '-SkipDotnetTools' }
    if ($Config.SkipVscode)           { $taskArgs += '-SkipVscode' }
    if ($Config.SkipDefender)         { $taskArgs += '-SkipDefender' }
    if ($Config.IncludeDriverUpdates) { $taskArgs += '-IncludeDriverUpdates' }
    if ($Config.IncludeFirmwareUpdates) { $taskArgs += '-IncludeFirmwareUpdates' }
    if ($Config.UpdateWsl)            { $taskArgs += '-UpdateWsl' }
    if ($Config.UpdateContainers)     { $taskArgs += '-UpdateContainers' }
    if ($Config.SkipRestorePoint)     { $taskArgs += '-SkipRestorePoint' }
    if ($Config.SkipHealthCheck)      { $taskArgs += '-SkipHealthCheck' }
    if ($Config.SkipBitLocker)        { $taskArgs += '-SkipBitLocker' }
    if ($Config.AllowMetered)         { $taskArgs += '-AllowMetered' }
    if ($Config.DisableSelfUpdate)    { $taskArgs += '-DisableSelfUpdate' }
    if ($Config.StagedRollout)        { $taskArgs += '-StagedRollout' }
    if ($Config.MaintenanceWindowStart -ge 0) { $taskArgs += "-MaintenanceWindowStart $($Config.MaintenanceWindowStart)" }
    if ($Config.MaintenanceWindowEnd   -ge 0) { $taskArgs += "-MaintenanceWindowEnd $($Config.MaintenanceWindowEnd)" }
    if ($Config.NotifyEmail)          { $taskArgs += "-NotifyEmail `"$($Config.NotifyEmail)`"" }
    if ($Config.SmtpServer)           { $taskArgs += "-SmtpServer `"$($Config.SmtpServer)`"" }
    if ($Config.ExcludePatterns.Count -gt 0) {
        $encodedPatterns = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Config.ExcludePatterns | ConvertTo-Json -Compress)))
        $taskArgs += "-ExcludePatternsBase64 $encodedPatterns"
    }
    if ($Config.IncludePatterns.Count -gt 0) {
        $encodedPatterns = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Config.IncludePatterns | ConvertTo-Json -Compress)))
        $taskArgs += "-IncludePatternsBase64 $encodedPatterns"
    }

    $argString = $taskArgs -join ' '
    $action   = New-ScheduledTaskAction -Execute $pwshPath -Argument $argString -WorkingDirectory $installDir
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew

    if ($Config.RunAsUser) {
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
        $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest
        $runAsDesc = "$currentUser at logon"
    } else {
        $trigger   = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $runAsDesc = "SYSTEM at startup"
    }

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Boot update loop: patches everything, reboots until clean.' -Force -ErrorAction Stop | Out-Null
    $registeredTask = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    if ($registeredTask.State -eq 'Disabled') { throw "Registered task '$taskName' is disabled." }
    Write-Host "Registered task: $taskName ($runAsDesc)" -ForegroundColor Green
}

if ($Config.NonInteractive) {
    <# Fire-and-forget mode: minimal output, no prompts #>
    Write-Host "Deployed to: $installDir" -ForegroundColor Green
    Write-Host "Uninstall:   & '$uninstallPath'" -ForegroundColor Cyan

    if ($Config.StartNow) {
        if ($Config.DirectFirstRun) {
            Write-Host "Starting update cycle directly (user context)..." -ForegroundColor Green
            Write-Host "Log: $installDir\BootUpdateCycle.log"
            Invoke-DeployedCycle
        } else {
            Write-Host "WARNING: DirectFirstRun=false - user-scope winget packages will NOT be updated" -ForegroundColor Yellow
            Register-ScheduledTaskNow
            Start-ScheduledTask -TaskName $taskName
            Write-Host "Task started. Log: $installDir\BootUpdateCycle.log" -ForegroundColor Green
        }
    } else {
        Write-Host "Deployed but NOT started." -ForegroundColor Yellow
        Write-Host "To start: & '$scriptPath' -Force"
    }
} else {
    <# Interactive mode: show deployment info with execution context warning #>
    Show-DeploymentModal -InstallDir $installDir -UninstallPath $uninstallPath -TaskName $taskName -DirectFirstRun $Config.DirectFirstRun

    if ($Config.StartNow) {
        <# Flush keyboard buffer - paste+Enter leaves keys in buffer that would skip the prompt #>
        Start-Sleep -Milliseconds 200
        while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) }

        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        Clear-Host
        Write-Host ""

        if ($Config.DirectFirstRun) {
            Write-Host "Starting update cycle directly (user context)..." -ForegroundColor Green
            Write-Host "User-scoped winget packages will be updated NOW (only chance)." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Log: $installDir\BootUpdateCycle.log" -ForegroundColor Cyan
            Write-Host ""
            Invoke-DeployedCycle
        } else {
            Write-Host "Starting via scheduled task (SYSTEM context)..." -ForegroundColor Yellow
            Write-Host "WARNING: User-scope winget packages will NOT be updated!" -ForegroundColor Red
            Write-Host ""
            Register-ScheduledTaskNow
            Start-ScheduledTask -TaskName $taskName
            $logPath = Join-Path $installDir 'BootUpdateCycle.log'
            Start-PersistentHeaderLogTail -LogPath $logPath -UninstallPath $uninstallPath
        }
    } else {
        Write-Host ""
        Write-Host "Deployed but NOT started." -ForegroundColor Yellow
        Write-Host "To start: & '$scriptPath' -Force"
        Write-Host ""
    }
}
#endregion

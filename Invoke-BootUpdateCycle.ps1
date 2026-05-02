#requires -Version 7.0
#requires -RunAsAdministrator
# ------------------------------------------------------------------------------
# File:        Invoke-BootUpdateCycle.ps1
# Description: Boot-time update orchestrator with automatic reboot loop
# Purpose:     Runs at Windows startup to systematically update all package
#              managers and Windows itself, rebooting as needed until no pending
#              reboots remain.  Self-removes when done.
# Created:     2025-01-10
# Modified:    2026-04-25
# ------------------------------------------------------------------------------
<#
.SYNOPSIS
    Updates everything, reboots if needed, repeats until done.

.DESCRIPTION
    Each boot it:
    1. Runs pre-flight checks (disk, network, battery, conflicts)
    2. Updates Winget (user + machine scope), Chocolatey, Windows Update
    3. Updates pip, npm, Office 365, PowerShell modules, Scoop, dotnet tools, VS Code extensions
    4. Reboots if any updates require it
    5. Cleans up and self-destructs when no pending reboots remain

    Safety: max iteration limit prevents infinite reboot loops.
    Smart timeouts: kills idle processes but lets busy installs finish.

.PARAMETER MaxIterations
    Maximum reboot cycles before giving up.  Default 5.

.PARAMETER PackageTimeoutMinutes
    Hard timeout ceiling per package manager.  Default 30.

.PARAMETER RebootDelaySec
    Seconds before forced reboot (no user abort window).  Default 0 (immediate, forced).

.PARAMETER Force
    Skip confirmation prompts and override pre-flight warnings.

.PARAMETER WhatIf
    Show what would happen without making any changes.  No packages are updated,
    no reboots are triggered, no scheduled tasks are registered.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [int]$MaxIterations = 5,
    [int]$PackageTimeoutMinutes = 30,
    [int]$RebootDelaySec = 0,
    [switch]$SkipPip,
    [switch]$SkipNpm,
    [switch]$SkipOffice365,
    [switch]$SkipAwsTooling,
    [switch]$SkipPowerShellModules,
    [switch]$SkipScoop,
    [switch]$SkipDotnetTools = $true,
    [switch]$SkipVscode,
    [switch]$SkipRestorePoint,
    [switch]$SkipHealthCheck,
    [switch]$SkipBitLocker,
    [switch]$StagedRollout,           # Run one package manager per boot instead of all at once
    [switch]$Force,
    [ValidateScript({ $_ -eq '' -or $_ -match '^https?://' })]
    [string]$WebhookUrl       = '',   # Teams/Slack/Discord incoming webhook URL
    [string]$NotifyEmail      = '',   # SMTP recipient email address
    [string]$SmtpServer       = '',   # SMTP relay hostname (e.g., smtp.office365.com)
    [pscredential]$SmtpCredential = $null,  # SMTP credential (PSCredential object for authenticated relay)
    [string[]]$ExcludePatterns = @(),  # Package name/ID patterns to skip (substring match, case-insensitive)
    [ValidateRange(-1, 23)]
    [int]$MaintenanceWindowStart = -1,  # Hour of day (0-23) when updates may begin. -1 = no window enforced.
    [ValidateRange(-1, 23)]
    [int]$MaintenanceWindowEnd   = -1   # Hour of day when updates must stop. -1 = no window enforced.
)

$ErrorActionPreference = 'Stop'
$script:LogPath               = Join-Path $PSScriptRoot 'BootUpdateCycle.log'
$script:StatePath             = Join-Path $PSScriptRoot 'BootUpdateCycle.state.json'
$script:HistoryPath           = Join-Path $PSScriptRoot 'BootUpdateCycle.history.json'
$script:MaxLogSizeMB          = 5
$script:MaxHistoryEntries     = 50
$script:PackageTimeoutMinutes = $PackageTimeoutMinutes
$script:RebootDelaySec        = $RebootDelaySec
$script:MaxIterations         = $MaxIterations
$script:SkipPip               = $SkipPip
$script:SkipNpm               = $SkipNpm
$script:SkipOffice365         = $SkipOffice365
$script:SkipAwsTooling        = $SkipAwsTooling
$script:SkipPowerShellModules = $SkipPowerShellModules
$script:SkipScoop             = $SkipScoop
$script:SkipDotnetTools       = $SkipDotnetTools
$script:SkipVscode            = $SkipVscode
$script:SkipRestorePoint      = $SkipRestorePoint
$script:SkipHealthCheck       = $SkipHealthCheck
$script:SkipBitLocker         = $SkipBitLocker
$script:StagedRollout         = $StagedRollout.IsPresent
$script:BootUpdateMutex       = $null
$script:ExcludePatterns       = $ExcludePatterns
$script:WebhookUrl            = $WebhookUrl
$script:NotifyEmail           = $NotifyEmail
$script:SmtpServer            = $SmtpServer
$script:SmtpCredential        = $SmtpCredential
$script:MaintenanceWindowStart = $MaintenanceWindowStart
$script:MaintenanceWindowEnd   = $MaintenanceWindowEnd
Set-Variable -Name 'BootUpdateStateSchemaVersion' -Value 2 -Option ReadOnly -Scope Script -ErrorAction SilentlyContinue
Set-Variable -Name 'BootUpdateCycleVersion' -Value '2.4.0' -Option ReadOnly -Scope Script -ErrorAction SilentlyContinue

<# Force UTF-8 console I/O so box-drawing/block chars (BBS splash) render in cmd.exe regardless of system code page.
   chcp 65001 sets conhost interpretation; [Console]::OutputEncoding makes .NET write proper UTF-8 bytes. #>
try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding  = [System.Text.UTF8Encoding]::new($false)
    $OutputEncoding           = [System.Text.UTF8Encoding]::new($false)
    & chcp.com 65001 > $null 2>&1
} catch { <# no console attached (SYSTEM scheduled task) — ignore #> }

#region Logging
function Invoke-LogRotation {
    if (-not (Test-Path $script:LogPath)) { return }
    $logFile = Get-Item $script:LogPath
    if ($logFile.Length -gt ($script:MaxLogSizeMB * 1MB)) {
        $archivePath = $script:LogPath -replace '\.log$', ".$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
        Move-Item $script:LogPath $archivePath -Force
        Get-ChildItem (Split-Path $script:LogPath) -Filter 'BootUpdateCycle.*.log' |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip 3 | Remove-Item -Force
    }
}

function Write-Log {
    param([string]$Message, [ValidateSet('Info','Warn','Error')]$Level = 'Info')
    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    $trimmed = $Message.Trim()
    if ($trimmed -match '^[\|/\-\\]$') { return }
    if ($trimmed.Length -le 3 -and $trimmed -match '^[\|/\-\\]+$') { return }
    if ($Message -match '[\u2500-\u257F]|█|▒|░|\x08') { return }
    if ($Message -match 'Γûè|Γûê|ΓûÆ|Γöé|Γö') { return }
    if ($Message -match '^\s*(Downloading|Getting source|Refreshing source)') { return }
    if ($Message -match '^\s*[\d.]+\s*[KMG]?B\s*/\s*[\d.]+\s*[KMG]?B') { return }
    if ($Message -match '^\s+\d+(\.\d+)?\s*[KMG]?\s*(B|K|M)\s*\.{2,}$') { return }
    if ($Message -match '^-{5,}.*\d+\.\d+.*[KMG]?B.*eta') { return }
    if ($Message -match '^\s*━+|^\s*\|█+') { return }
    if ($Message -match 'Progress:\s*\d+%\s*-\s*Saving') { return }
    if ($Message -match 'is currently in use\.\s*Retry the operation after closing') { return }

    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] [$Level] $Message"
    Add-Content -Path $script:LogPath -Value $entry -Force
    switch ($Level) {
        'Info'  { Write-Host $entry }
        'Warn'  { Write-Host $entry -ForegroundColor Yellow }
        'Error' { Write-Host $entry -ForegroundColor Red }
    }
}
#endregion

#region State Management
function New-BootUpdateStateV2 {
    return [pscustomobject]@{
        StateVersion          = $script:BootUpdateStateSchemaVersion
        Iteration             = 0
        StartTime             = $null
        LastRun               = $null
        Phase                 = 'Init'
        StagedNextPhase       = $null
        LastPhaseStarted      = $null
        LastPhaseTimestamp     = $null
        WingetDone            = $false
        ChocolateyDone        = $false
        WindowsUpdateDone     = $false
        AwsToolingDone        = $false
        PipDone               = $false
        NpmDone               = $false
        Office365Done         = $false
        PowerShellModulesDone = $false
        ScoopDone             = $false
        DotnetToolsDone       = $false
        VscodeDone            = $false
        Summary               = [pscustomobject]@{
            Winget = 0; Chocolatey = 0; WindowsUpdate = 0; Pip = 0; Npm = 0; Office365 = 0
            PowerShellModules = 0; Scoop = 0; DotnetTools = 0; Vscode = 0
            HealthFailed = 0
        }
    }
}

function Update-BootUpdateStateSchema {
    param([Parameter(Mandatory)][pscustomobject]$State)
    $props = $State.PSObject.Properties.Name
    $ver = if ($props -contains 'StateVersion') { [int]$State.StateVersion } else { 1 }

    <# Forward-compat guard: state written by a newer script version — back it up and warn #>
    if ($ver -gt $script:BootUpdateStateSchemaVersion) {
        $bakPath = $script:StatePath -replace '\.json$', ".future-v$ver.bak"
        Write-Log "WARNING: State file has schema version $ver but this script only knows v$($script:BootUpdateStateSchemaVersion). Saving backup to $bakPath before proceeding." -Level Warn
        try { Copy-Item -Path $script:StatePath -Destination $bakPath -Force -EA SilentlyContinue } catch { }
    }

    <# v1 -> v2: rename inconsistent phase flags #>
    if ($ver -lt 2) {
        if (($props -contains 'WindowsUpdate') -and ($props -notcontains 'WindowsUpdateDone')) {
            $State | Add-Member -NotePropertyName 'WindowsUpdateDone' -NotePropertyValue ([bool]$State.WindowsUpdate) -Force
        }
        if ($props -contains 'WindowsUpdate') { $State.PSObject.Properties.Remove('WindowsUpdate') }
        if (($props -contains 'AwsTooling') -and ($props -notcontains 'AwsToolingDone')) {
            $State | Add-Member -NotePropertyName 'AwsToolingDone' -NotePropertyValue ([bool]$State.AwsTooling) -Force
        }
        if ($props -contains 'AwsTooling') { $State.PSObject.Properties.Remove('AwsTooling') }
    }

    $props = $State.PSObject.Properties.Name
    <# Add-if-missing: crash recovery, new phase flags #>
    foreach ($f in @('LastPhaseStarted','LastPhaseTimestamp','StagedNextPhase')) {
        if ($props -notcontains $f) { $State | Add-Member -NotePropertyName $f -NotePropertyValue $null -Force }
    }
    foreach ($f in @('WindowsUpdateDone','AwsToolingDone','PowerShellModulesDone','ScoopDone','DotnetToolsDone','VscodeDone')) {
        if ($props -notcontains $f) { $State | Add-Member -NotePropertyName $f -NotePropertyValue $false -Force }
    }

    <# Normalise Summary #>
    if ($null -eq $State.Summary) {
        $State.Summary = [pscustomobject]@{
            Winget = 0; Chocolatey = 0; WindowsUpdate = 0; Pip = 0; Npm = 0; Office365 = 0
            PowerShellModules = 0; Scoop = 0; DotnetTools = 0; Vscode = 0
            HealthFailed = 0
        }
    } elseif ($State.Summary -is [hashtable]) {
        $ht = $State.Summary
        $State.Summary = [pscustomobject]@{
            Winget = [int]($ht['Winget'] ?? 0); Chocolatey = [int]($ht['Chocolatey'] ?? 0)
            WindowsUpdate = [int]($ht['WindowsUpdate'] ?? 0); Pip = [int]($ht['Pip'] ?? 0)
            Npm = [int]($ht['Npm'] ?? 0); Office365 = [int]($ht['Office365'] ?? 0)
            PowerShellModules = [int]($ht['PowerShellModules'] ?? 0); Scoop = [int]($ht['Scoop'] ?? 0)
            DotnetTools = [int]($ht['DotnetTools'] ?? 0); Vscode = [int]($ht['Vscode'] ?? 0)
            HealthFailed = [int]($ht['HealthFailed'] ?? 0)
        }
    } else {
        $sp = $State.Summary.PSObject.Properties.Name
        foreach ($k in @('PowerShellModules','Scoop','DotnetTools','Vscode')) {
            if ($sp -notcontains $k) { $State.Summary | Add-Member -NotePropertyName $k -NotePropertyValue 0 -Force }
        }
        if ($null -eq $State.Summary.HealthFailed) {
            $State.Summary | Add-Member -NotePropertyName 'HealthFailed' -NotePropertyValue 0 -Force
        }
    }

    if ($props -notcontains 'StateVersion') {
        $State | Add-Member -NotePropertyName 'StateVersion' -NotePropertyValue $script:BootUpdateStateSchemaVersion -Force
    } else { $State.StateVersion = $script:BootUpdateStateSchemaVersion }
    return $State
}

function Get-BootUpdateState {
    if (-not (Test-Path $script:StatePath)) { return New-BootUpdateStateV2 }
    try {
        $raw = Get-Content -Path $script:StatePath -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { Write-Log 'State file empty, starting fresh.' -Level Warn; return New-BootUpdateStateV2 }
        $state = $raw | ConvertFrom-Json -ErrorAction Stop
        return (Update-BootUpdateStateSchema -State $state)
    } catch {
        Write-Log "State file corrupted: $_  Starting fresh." -Level Warn
        $corruptPath = $script:StatePath -replace '\.json$', ".corrupt-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        try { Move-Item -Path $script:StatePath -Destination $corruptPath -Force -EA SilentlyContinue } catch { }
        return New-BootUpdateStateV2
    }
}

function Set-BootUpdateState {
    param([Parameter(Mandatory)][pscustomobject]$State)
    <# Skip disk writes in WhatIf mode — state is read-only during dry runs #>
    if ($WhatIfPreference) { return }
    $State.LastRun = (Get-Date).ToUniversalTime().ToString('o')
    $tmpPath = $script:StatePath + '.tmp'
    <# Remove any pre-existing .tmp left by a prior failed write #>
    if (Test-Path $tmpPath) { Remove-Item $tmpPath -Force -EA SilentlyContinue }
    try {
        $json = $State | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($tmpPath, $json, [System.Text.Encoding]::UTF8)
        try {
            Move-Item -Path $tmpPath -Destination $script:StatePath -Force -ErrorAction Stop
        } catch {
            Write-Log "Failed to promote state file (Move-Item): $_" -Level Error
            if (Test-Path $tmpPath) { Remove-Item $tmpPath -Force -EA SilentlyContinue }
            throw
        }
    } catch {
        Write-Log "Failed to write state: $_" -Level Error
        if (Test-Path $tmpPath) { Remove-Item $tmpPath -Force -EA SilentlyContinue }
        throw
    }
}

function Clear-BootUpdateState {
    <# Skip disk writes in WhatIf mode #>
    if ($WhatIfPreference) { return }
    $tmpPath = $script:StatePath + '.tmp'
    if (Test-Path $tmpPath) { Remove-Item $tmpPath -Force -EA SilentlyContinue }
    if (Test-Path $script:StatePath) { Remove-Item $script:StatePath -Force }
}

function Test-CrashRecovery {
    param([Parameter(Mandatory)][pscustomobject]$State)
    if ([string]::IsNullOrWhiteSpace($State.LastPhaseStarted)) { return $false }
    $phaseToFlag = @{
        Winget='WingetDone'; Chocolatey='ChocolateyDone'; WindowsUpdate='WindowsUpdateDone'
        AwsTooling='AwsToolingDone'; Pip='PipDone'; Npm='NpmDone'; Office365='Office365Done'
        PowerShellModules='PowerShellModulesDone'; Scoop='ScoopDone'; DotnetTools='DotnetToolsDone'; Vscode='VscodeDone'
    }
    $flagName = $phaseToFlag[$State.LastPhaseStarted]
    if (-not $flagName) {
        Write-Log "Crash recovery: unknown phase '$($State.LastPhaseStarted)' in state file — ignoring." -Level Warn
        return $false
    }
    $isDone = if ($flagName -and ($State.PSObject.Properties.Name -contains $flagName)) { [bool]$State.$flagName } else { $false }
    if (-not $isDone) {
        $time = if ($State.LastPhaseTimestamp) { try { ([datetime]$State.LastPhaseTimestamp).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') } catch { $State.LastPhaseTimestamp } } else { '(unknown)' }
        Write-Log "Previous run crashed during [$($State.LastPhaseStarted)] at [$time]. Restarting that phase." -Level Warn
        return $true
    }
    return $false
}

function Save-CycleHistory {
    param([pscustomobject]$State, [timespan]$Duration)
    <# Skip disk writes in WhatIf mode #>
    if ($WhatIfPreference) { return }
    $s = $State.Summary
    $entry = [pscustomobject]@{
        Timestamp = Get-Date -Format 'o'
        Iterations = $State.Iteration
        DurationMinutes = [math]::Round($Duration.TotalMinutes, 1)
        Winget = $s.Winget; Chocolatey = $s.Chocolatey; WindowsUpdate = $s.WindowsUpdate
        Pip = $s.Pip; Npm = $s.Npm; Office365 = $s.Office365
        PowerShellModules = $s.PowerShellModules; Scoop = $s.Scoop; DotnetTools = $s.DotnetTools; Vscode = $s.Vscode
        HealthFailed = if ($null -ne $s.HealthFailed) { [int]$s.HealthFailed } else { 0 }
        Total = $s.Winget + $s.Chocolatey + $s.WindowsUpdate + $s.Pip + $s.Npm + $s.Office365 + $s.PowerShellModules + $s.Scoop + $s.DotnetTools + $s.Vscode
    }
    $history = @()
    if (Test-Path $script:HistoryPath) {
        try {
            $history = @(Get-Content $script:HistoryPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
        } catch {
            Write-Log "History file unreadable, starting fresh: $_" -Level Warn
            $history = @()
        }
    }
    $history = @($entry) + $history | Select-Object -First $script:MaxHistoryEntries
    $histTmpPath = $script:HistoryPath + '.tmp'
    if (Test-Path $histTmpPath) { Remove-Item $histTmpPath -Force -EA SilentlyContinue }
    $history | ConvertTo-Json -Depth 5 | Set-Content $histTmpPath -Force
    Move-Item -Path $histTmpPath -Destination $script:HistoryPath -Force
}
#endregion

#region Pre-flight Checks
function Test-PreFlightChecks {
    [CmdletBinding()]
    param([switch]$Force)

    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors   = [System.Collections.Generic.List[string]]::new()
    function Add-Warning { param([string]$Msg) $warnings.Add($Msg); Write-Log $Msg -Level Warn }
    function Add-Error   { param([string]$Msg) $errors.Add($Msg);   Write-Log $Msg -Level Error }

    Write-Log 'Pre-flight checks starting...'

    <# Disk space #>
    try {
        $drive = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop
        $freeGB = [math]::Round($drive.Free / 1GB, 1)
        Write-Log "Disk: $env:SystemDrive has $freeGB GB free"
        if ($freeGB -lt 5) { Add-Error "ABORT: $env:SystemDrive has only ${freeGB}GB free (minimum 5 GB)" }
        elseif ($freeGB -lt 10) { Add-Warning "LOW DISK: ${freeGB}GB free on $env:SystemDrive (recommend 10+)" }
    } catch { Add-Warning "Disk check failed: $_" }

    <# Network #>
    try {
        $dnsOk = $false
        try { $null = [System.Net.Dns]::GetHostAddresses('github.com'); $dnsOk = $true; Write-Log 'Network: DNS OK' }
        catch { Add-Warning "Network: DNS failed ($_)" }
        if ($dnsOk) {
            foreach ($target in @(@{H='chocolatey.org';P=443}, @{H='github.com';P=443})) {
                try {
                    $tcp = [System.Net.Sockets.TcpClient]::new()
                    $connected = $tcp.ConnectAsync($target.H, $target.P).Wait(5000)
                    $tcp.Close()
                    if ($connected) { Write-Log "Network: $($target.H):$($target.P) OK" }
                    else { Add-Warning "Network: $($target.H) unreachable" }
                } catch { Add-Warning "Network: $($target.H) error: $_" }
            }
        }
    } catch { Add-Warning "Network checks failed: $_" }

    <# Conflicting installers #>
    try {
        $found = [System.Collections.Generic.List[string]]::new()
        foreach ($name in @('msiexec','TrustedInstaller','TiWorker')) {
            $procs = Get-Process -Name $name -EA SilentlyContinue
            if ($procs) { $found.Add("$name (PID $(($procs.Id) -join ','))") }
        }
        if ($found.Count -gt 0) { Add-Warning "Installers running: $($found -join '; ')" }
        else { Write-Log 'Installer check: no conflicts' }
    } catch { Add-Warning "Installer check failed: $_" }

    <# Windows Update service #>
    try {
        $svc = Get-Service wuauserv -ErrorAction Stop
        if ($svc.StartType -eq 'Disabled') { Add-Error 'Windows Update service is Disabled' }
        elseif ($svc.Status -ne 'Running') {
            try { Start-Service wuauserv -ErrorAction Stop; Write-Log 'WU service: started' }
            catch { Add-Warning "WU service could not start: $_" }
        }
    } catch { Add-Warning "WU service check failed: $_" }

    <# Battery #>
    try {
        $bat = Get-CimInstance Win32_Battery -EA Stop
        if ($bat) {
            $onBattery = ($bat.BatteryStatus -eq 1)
            $charge = $bat.EstimatedChargeRemaining
            Write-Log "Battery: ${charge}%, on battery: $onBattery"
            if ($onBattery -and $charge -lt 30) { Add-Warning "BATTERY LOW: ${charge}% on battery — plug in before updating" }
            elseif ($onBattery) { Add-Warning "On battery (${charge}%) — recommend plugging in" }
        } else { Write-Log 'Battery: none detected (desktop/VM)' }
    } catch { Add-Warning "Battery check failed: $_" }

    <# PS version #>
    if ($PSVersionTable.PSVersion.Major -lt 7) { Add-Error "PowerShell 7+ required; running $($PSVersionTable.PSVersion)" }

    $canProceed = ($errors.Count -eq 0) -and (($warnings.Count -eq 0) -or $Force.IsPresent)
    $summary = if ($errors.Count -gt 0) { "BLOCKED ($($errors.Count) error(s))" }
               elseif ($warnings.Count -gt 0 -and -not $Force) { "BLOCKED ($($warnings.Count) warning(s)); use -Force to override" }
               elseif ($warnings.Count -gt 0) { "PROCEEDING with $($warnings.Count) warning(s) (-Force)" }
               else { 'ALL CHECKS PASSED' }
    Write-Log "Pre-flight: $summary"
    return [PSCustomObject]@{ CanProceed = $canProceed; Warnings = $warnings.ToArray(); Errors = $errors.ToArray() }
}
#endregion

#region Restore Point
function New-SystemRestorePoint {
    <#
    .SYNOPSIS
        Creates a Windows System Restore point before running updates.
    .NOTES
        Best-effort: failure logs a warning and returns $false — does NOT abort the cycle.
        Skipped automatically under SYSTEM context (Checkpoint-Computer requires interactive session).
        Skipped on Server SKUs where System Restore service is absent or disabled.
        Skipped in WhatIf mode.
    #>
    if ($WhatIfPreference) {
        Write-Log '  [WHATIF] Would create System Restore point'
        return $false
    }
    if ($script:SkipRestorePoint) {
        Write-Log 'System restore point: skipped (-SkipRestorePoint)'
        return $false
    }

    <# SYSTEM context check: Checkpoint-Computer requires interactive/user session on Windows 11 #>
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if ($currentIdentity.Name -match 'SYSTEM') {
        Write-Log 'System restore point: skipped (running as SYSTEM — Checkpoint-Computer requires interactive session)' -Level Warn
        return $false
    }

    <# SystemRestore service check: absent/disabled on Server SKUs #>
    try {
        $srSvc = Get-Service -Name 'SDRSVC' -ErrorAction Stop
        if ($srSvc.StartType -eq 'Disabled') {
            Write-Log 'System restore point: skipped (System Restore service is Disabled — likely Server SKU)' -Level Warn
            return $false
        }
    } catch {
        Write-Log "System restore point: skipped (System Restore service not found — likely Server SKU: $_)" -Level Warn
        return $false
    }

    <# Enable System Protection on the system drive (idempotent, safe) #>
    try {
        Enable-ComputerRestore -Drive $env:SystemDrive -ErrorAction Stop
        Write-Log "System restore: protection enabled on $env:SystemDrive"
    } catch {
        Write-Log "System restore: Enable-ComputerRestore failed (non-fatal): $_" -Level Warn
        <# Do not return — Checkpoint-Computer may still work if protection was already on #>
    }

    <# Create the restore point #>
    try {
        $description = "BootUpdateCycle pre-update $(Get-Date -Format 'yyyy-MM-dd')"
        Checkpoint-Computer -Description $description -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Log "System restore point created: $description"
        return $true
    } catch {
        Write-Log "System restore point creation failed (non-fatal): $_" -Level Warn
        return $false
    }
}
#endregion

#region Pending Reboot Detection
function Test-PendingReboot {
    <# Comprehensive pending-reboot detection based on Boxstarter/Brian Wilhite's
       Get-PendingReboot approach.  Checks every OS-level signal that a reboot is needed. #>
    $tests = @(
        @{ Name = 'CBS'; Test = {
            Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        }},
        @{ Name = 'WU'; Test = {
            Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        }},
        @{ Name = 'FileRename'; Test = {
            $val = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -EA Ignore
            $val -and $val.PendingFileRenameOperations.Count -gt 0
        }},
        @{ Name = 'ComputerRename'; Test = {
            $r = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -EA Ignore
            $a = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -EA Ignore
            $r -and $a -and $r.ComputerName -ne $a.ComputerName
        }},
        @{ Name = 'JoinDomain'; Test = {
            (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon' -Name 'JoinDomain' -EA Ignore) -or
            (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon' -Name 'AvoidSpnSet' -EA Ignore)
        }},
        @{ Name = 'SCCM'; Test = {
            try {
                $ccm = Invoke-CimMethod -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_ClientUtilities' `
                    -MethodName 'DetermineIfRebootPending' -EA Stop
                $ccm -and ($ccm.ReturnValue -eq 0) -and ($ccm.IsHardRebootPending -or $ccm.RebootPending)
            } catch { $false }  <# SCCM client not installed — expected on most workstations #>
        }}
    )
    @($tests | ForEach-Object { if (& $_.Test) { [pscustomobject]@{ Source = $_.Name; Status = 'Pending' } } })
}
#endregion

#region Smart Timeout
function Get-ProcessTreeActivity {
    param([Parameter(Mandatory)][int]$ParentPid)
    $allProcs = Get-CimInstance Win32_Process -EA SilentlyContinue
    if (-not $allProcs) { return [pscustomobject]@{ TotalCpuTime = [timespan]::Zero; ProcessCount = 0; HandleCount = 0 } }

    $byPid = @{}; $childMap = @{}
    foreach ($p in $allProcs) {
        $byPid[$p.ProcessId] = $p
        if (-not $childMap.ContainsKey($p.ParentProcessId)) { $childMap[$p.ParentProcessId] = [System.Collections.Generic.List[int]]::new() }
        $childMap[$p.ParentProcessId].Add($p.ProcessId)
    }

    $queue = [System.Collections.Generic.Queue[int]]::new(); $visited = [System.Collections.Generic.HashSet[int]]::new()
    $queue.Enqueue($ParentPid)
    $totalCpuMs = [int64]0; $procCount = 0; $handles = 0

    while ($queue.Count -gt 0) {
        $procId = $queue.Dequeue()
        if (-not $visited.Add($procId)) { continue }
        $cim = $byPid[$procId]
        if ($cim) {
            $totalCpuMs += ([int64]$cim.KernelModeTime + [int64]$cim.UserModeTime) / 10000
            $handles += [int]$cim.HandleCount; $procCount++
        }
        if ($childMap.ContainsKey($procId)) { foreach ($c in $childMap[$procId]) { if (-not $visited.Contains($c)) { $queue.Enqueue($c) } } }
    }
    return [pscustomobject]@{ TotalCpuTime = [timespan]::FromMilliseconds($totalCpuMs); ProcessCount = $procCount; HandleCount = $handles }
}

function Wait-ProcessWithIdleTimeout {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [int]$IdleTimeoutMinutes = 5, [int]$HardTimeoutMinutes = 60, [int]$PollIntervalSeconds = 30
    )
    $startTime = [datetime]::UtcNow; $lastCpuIncrease = $startTime; $lastCpuTime = [timespan]::Zero; $finalCpu = [timespan]::Zero
    $hardLimit = [timespan]::FromMinutes($HardTimeoutMinutes); $idleLimit = [timespan]::FromMinutes($IdleTimeoutMinutes)

    function Remove-ProcessTree { param([int]$RootPid)
        $all = Get-CimInstance Win32_Process -EA SilentlyContinue; if (-not $all) { return }
        $cm = @{}; foreach ($p in $all) { if (-not $cm.ContainsKey($p.ParentProcessId)) { $cm[$p.ParentProcessId] = [System.Collections.Generic.List[int]]::new() }; $cm[$p.ParentProcessId].Add($p.ProcessId) }
        $ordered = [System.Collections.Generic.List[int]]::new(); $q = [System.Collections.Generic.Queue[int]]::new(); $v = [System.Collections.Generic.HashSet[int]]::new()
        $q.Enqueue($RootPid)
        while ($q.Count -gt 0) { $id = $q.Dequeue(); if (-not $v.Add($id)) { continue }; $ordered.Add($id); if ($cm.ContainsKey($id)) { foreach ($c in $cm[$id]) { $q.Enqueue($c) } } }
        $ordered.Reverse()
        foreach ($id in $ordered) { $p = Get-Process -Id $id -EA SilentlyContinue; if ($p -and -not $p.HasExited) { try { $p.Kill(); Write-Log "Killed PID $id ($($p.ProcessName))" -Level Warn } catch { } } }
    }

    while ($true) {
        $Process.Refresh()
        if ($Process.HasExited) {
            $elapsed = [datetime]::UtcNow - $startTime
            Write-Log "Process PID $($Process.Id) exited normally ($([math]::Round($elapsed.TotalMinutes,1))m)"
            return @{ Reason = 'Completed'; Elapsed = $elapsed; FinalCpuTime = $finalCpu }
        }
        $elapsed = [datetime]::UtcNow - $startTime
        if ($elapsed -ge $hardLimit) {
            Write-Log "HARD TIMEOUT: PID $($Process.Id) exceeded $HardTimeoutMinutes min. Killing." -Level Error
            $tree = Get-ProcessTreeActivity -ParentPid $Process.Id
            Write-Log "  Tree at kill: $($tree.ProcessCount) processes, CPU=$([math]::Round($tree.TotalCpuTime.TotalSeconds,1))s, handles=$($tree.HandleCount)" -Level Warn
            Remove-ProcessTree -RootPid $Process.Id
            return @{ Reason = 'HardTimeout'; Elapsed = $elapsed; FinalCpuTime = $tree.TotalCpuTime }
        }
        $activity = Get-ProcessTreeActivity -ParentPid $Process.Id; $finalCpu = $activity.TotalCpuTime
        if ($activity.TotalCpuTime -gt $lastCpuTime) { $lastCpuTime = $activity.TotalCpuTime; $lastCpuIncrease = [datetime]::UtcNow }
        $idleFor = [datetime]::UtcNow - $lastCpuIncrease
        if ($idleFor -ge $idleLimit) {
            Write-Log "IDLE TIMEOUT: PID $($Process.Id) idle $([math]::Round($idleFor.TotalMinutes,1))m (threshold: ${IdleTimeoutMinutes}m), final CPU=$([math]::Round($activity.TotalCpuTime.TotalSeconds,1))s. Killing." -Level Error
            Write-Log "  Tree at kill: $($activity.ProcessCount) processes, handles=$($activity.HandleCount)" -Level Warn
            Remove-ProcessTree -RootPid $Process.Id
            return @{ Reason = 'IdleTimeout'; Elapsed = $elapsed; FinalCpuTime = $finalCpu }
        }
        Write-Log "  heartbeat: CPU=$([math]::Round($activity.TotalCpuTime.TotalSeconds,1))s procs=$($activity.ProcessCount) idle=$([math]::Round($idleFor.TotalMinutes,1))m elapsed=$([math]::Round($elapsed.TotalMinutes,1))m"
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

function Invoke-PackageManagerWithTimeout {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [int]$IdleTimeoutMinutes = 5, [int]$HardTimeoutMinutes = 60
    )
    $pwshPath = (Get-Command pwsh -EA SilentlyContinue)?.Source
    if (-not $pwshPath) { $pwshPath = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe' }
    if (-not (Test-Path $pwshPath)) { throw "pwsh not found for '$Name'" }

    $outputFile = [System.IO.Path]::GetTempFileName()
    $sbText = $ScriptBlock.ToString()
    $argsJson = $ArgumentList | ConvertTo-Json -Compress -Depth 5
    $childScript = @"
`$sb = [scriptblock]::Create(@'
$sbText
'@)
`$argList = (`'$argsJson`' | ConvertFrom-Json -NoEnumerate)
if (`$argList -isnot [array]) { `$argList = @(`$argList) }
& `$sb @argList 2>&1 | ForEach-Object { `$_.ToString() } | Out-File -FilePath '$($outputFile -replace "'","''")' -Encoding UTF8 -Append
"@
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($childScript))
    Write-Log "${Name}: Starting (idle: ${IdleTimeoutMinutes}m, hard: ${HardTimeoutMinutes}m)"

    $si = [System.Diagnostics.ProcessStartInfo]@{
        FileName = $pwshPath; Arguments = "-NoProfile -NonInteractive -EncodedCommand $encoded"
        UseShellExecute = $false; RedirectStandardOutput = $false; RedirectStandardError = $false; CreateNoWindow = $true
    }
    $proc = [System.Diagnostics.Process]::Start($si)
    if (-not $proc) {
        Write-Log "${Name}: Failed to start." -Level Error
        return @{ Output = @(); TimedOut = $false; Reason = 'StartFailed'; Elapsed = [timespan]::Zero }
    }
    Write-Log "${Name}: PID $($proc.Id)"
    $result = Wait-ProcessWithIdleTimeout -Process $proc -IdleTimeoutMinutes $IdleTimeoutMinutes -HardTimeoutMinutes $HardTimeoutMinutes -PollIntervalSeconds 30

    $output = @()
    if (Test-Path $outputFile) { $output = Get-Content $outputFile -Encoding UTF8 -EA SilentlyContinue; Remove-Item $outputFile -Force -EA SilentlyContinue }
    $timedOut = $result.Reason -in @('IdleTimeout','HardTimeout')
    if ($timedOut) { Write-Log "${Name}: Killed ($($result.Reason)) after $([math]::Round($result.Elapsed.TotalMinutes,1))m. Will retry next boot." -Level Warn }
    else { Write-Log "${Name}: Done in $([math]::Round($result.Elapsed.TotalMinutes,1))m" }
    return @{ Output = $output; TimedOut = $timedOut; Reason = $result.Reason; Elapsed = $result.Elapsed }
}
#endregion

#region Package Manager Updates
function Update-WingetPackages {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $TimeoutMinutes = $script:PackageTimeoutMinutes
    $wingetPath = $null
    $wg = Get-Command winget -EA SilentlyContinue
    if ($wg) { $wingetPath = $wg.Source }
    else {
        $candidates = @(
            (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'),
            (Get-ChildItem 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe' -EA SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        )
        foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { $wingetPath = $c; break } }
    }
    if (-not $wingetPath) { Write-Log 'Winget not found, skipping.' -Level Warn; return @{ Success = $true; Count = 0 } }
    Write-Log "Using winget: $wingetPath"

    $isSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
    if ($isSystem) { $scopes = @('machine'); Write-Log 'SYSTEM context: machine scope only' }
    else { $scopes = @('user', 'machine'); Write-Log 'User context: updating BOTH user + machine scopes' }

    $totalCount = 0; $anyTimeout = $false
    foreach ($scope in $scopes) {
        Write-Log "--- Winget upgrade (--scope $scope) ---"
        if ($PSCmdlet.ShouldProcess("Winget ($scope)", "Run Winget $scope-scope upgrades")) {

            if ($script:ExcludePatterns.Count -eq 0) {
                <# Fast path: no exclusions — use --all for best performance #>
                $result = Invoke-PackageManagerWithTimeout -Name "Winget-$scope" -ScriptBlock {
                    param($wp, $sc)
                    & $wp upgrade --all --scope $sc --accept-source-agreements --accept-package-agreements --disable-interactivity --no-vt 2>&1
                } -ArgumentList @($wingetPath, $scope) -IdleTimeoutMinutes 5 -HardTimeoutMinutes $TimeoutMinutes

                $count = 0; $installBlocked = $false
                foreach ($line in $result.Output) {
                    if ($line -match 'install.+in progress|in progress.+install|0x8A15') { $installBlocked = $true; Write-Log $line -Level Warn }
                    elseif ($line -match 'Successfully installed') { $count++; Write-Log $line }
                    else { Write-Log $line }
                }
                if ($result.TimedOut) { $anyTimeout = $true }

                <# One retry if blocked by another installer #>
                if ($installBlocked -and -not $result.TimedOut) {
                    Write-Log "Winget ($scope) blocked by another install. Waiting 30s, retrying once..." -Level Warn
                    Start-Sleep -Seconds 30
                    $retry = Invoke-PackageManagerWithTimeout -Name "Winget-$scope-retry" -ScriptBlock {
                        param($wp, $sc)
                        & $wp upgrade --all --scope $sc --accept-source-agreements --accept-package-agreements --disable-interactivity --no-vt 2>&1
                    } -ArgumentList @($wingetPath, $scope) -IdleTimeoutMinutes 5 -HardTimeoutMinutes $TimeoutMinutes
                    foreach ($line in $retry.Output) { if ($line -match 'Successfully installed') { $count++ }; Write-Log $line }
                    if ($retry.TimedOut) { $anyTimeout = $true }
                }
                $totalCount += $count

            } else {
                <# Filtered path: enumerate upgradeable packages, exclude by pattern, upgrade individually #>
                Write-Log "Winget ($scope): ExcludePatterns active ($($script:ExcludePatterns -join ', ')) — enumerating packages before upgrade"
                $listOutput = @()
                try {
                    $listOutput = @(& $wingetPath list --scope $scope --upgrade-available `
                        --accept-source-agreements --disable-interactivity --no-vt 2>&1 |
                        ForEach-Object { $_.ToString() })
                } catch {
                    Write-Log "Winget ($scope): Failed to enumerate upgradeable packages: $_" -Level Error
                    continue
                }

                <#
                    Parse the winget list table.  Locate the 'Id' column header by character offset,
                    then bound it against the next column header to know the field width.
                    Rows before and including the dashed separator are skipped.
                #>
                $packageIds = @()
                $headerLine = $listOutput | Where-Object { $_ -match '\bId\b' } | Select-Object -First 1
                if (-not $headerLine) {
                    Write-Log "Winget ($scope): Could not parse package list header — falling back to --all (no exclusion)" -Level Warn
                    $fbResult = Invoke-PackageManagerWithTimeout -Name "Winget-$scope" -ScriptBlock {
                        param($wp, $sc)
                        & $wp upgrade --all --scope $sc --accept-source-agreements --accept-package-agreements --disable-interactivity --no-vt 2>&1
                    } -ArgumentList @($wingetPath, $scope) -IdleTimeoutMinutes 5 -HardTimeoutMinutes $TimeoutMinutes
                    $count = 0
                    foreach ($line in $fbResult.Output) { if ($line -match 'Successfully installed') { $count++ }; Write-Log $line }
                    if ($fbResult.TimedOut) { $anyTimeout = $true }
                    $totalCount += $count
                    continue
                }

                $idColStart    = $headerLine.IndexOf('Id')
                $afterIdStr    = $headerLine.Substring($idColStart + 2).TrimStart()
                $nextColName   = ($afterIdStr -split '\s{2,}' | Where-Object { $_ -ne '' } | Select-Object -First 1)
                $nextColOffset = if ($nextColName) { $headerLine.IndexOf($nextColName, $idColStart + 2) } else { -1 }
                $headerIndex   = [array]::IndexOf($listOutput, $headerLine)

                foreach ($row in ($listOutput | Select-Object -Skip ($headerIndex + 1))) {
                    if ($row.Length -le $idColStart) { continue }
                    if ($row -match '^[-\s]+$') { continue }   # dashed separator line
                    $idField = if ($nextColOffset -gt $idColStart) {
                        $row.Substring($idColStart, $nextColOffset - $idColStart).Trim()
                    } else {
                        ($row.Substring($idColStart) -split '\s+')[0].Trim()
                    }
                    if ($idField -and $idField -notmatch '^-+$') { $packageIds += $idField }
                }

                if ($packageIds.Count -eq 0) {
                    Write-Log "Winget ($scope): No upgradeable packages found."
                    continue
                }
                Write-Log "Winget ($scope): $($packageIds.Count) package(s) available for upgrade"

                <# Apply exclusion filter #>
                $toUpgrade = @()
                foreach ($pkgId in $packageIds) {
                    $matchedPattern = $null
                    foreach ($pattern in $script:ExcludePatterns) {
                        if ($pkgId.IndexOf($pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $matchedPattern = $pattern; break }
                    }
                    if ($matchedPattern) {
                        Write-Log "Excluded by pattern '$matchedPattern': $pkgId" -Level Info
                    } else {
                        $toUpgrade += $pkgId
                    }
                }
                Write-Log "Winget ($scope): $($toUpgrade.Count) package(s) to upgrade after exclusions"

                $count = 0
                foreach ($pkgId in $toUpgrade) {
                    Write-Log "Winget ($scope): Upgrading $pkgId"
                    $pkgResult = Invoke-PackageManagerWithTimeout -Name "Winget-$scope-$pkgId" -ScriptBlock {
                        param($wp, $id, $sc)
                        & $wp upgrade --id $id --scope $sc -e --accept-source-agreements --accept-package-agreements --disable-interactivity --no-vt 2>&1
                    } -ArgumentList @($wingetPath, $pkgId, $scope) -IdleTimeoutMinutes 5 -HardTimeoutMinutes $TimeoutMinutes
                    foreach ($line in $pkgResult.Output) {
                        if ($line -match 'Successfully installed') { $count++ }
                        Write-Log $line
                    }
                    if ($pkgResult.TimedOut) { $anyTimeout = $true }
                }
                $totalCount += $count
            }

        } else {
            if ($script:ExcludePatterns.Count -eq 0) {
                Write-Log "  [WHATIF] Would run: winget upgrade --all --scope $scope"
            } else {
                Write-Log "  [WHATIF] Would run: winget list --upgrade-available --scope $scope, then upgrade each non-excluded package individually"
                Write-Log "  [WHATIF] ExcludePatterns: $($script:ExcludePatterns -join ', ')"
            }
        }
        Write-Log "--- Winget ($scope): $totalCount package(s) updated so far ---"
    }
    return @{ Success = (-not $anyTimeout); Count = $totalCount }
}

function Update-ChocolateyPackages {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $choco = Get-Command choco -EA SilentlyContinue
    if (-not $choco) { Write-Log 'Chocolatey not found, skipping.' -Level Warn; return @{ Success = $true; Count = 0 } }
    Write-Log 'Updating Chocolatey packages...'
    $count = 0
    if ($PSCmdlet.ShouldProcess('Chocolatey', 'Run choco upgrade all')) {
        if ($script:ExcludePatterns.Count -eq 0) {
            <# Fast path: no exclusions #>
            & choco upgrade all -y 2>&1 | ForEach-Object {
                if ($_ -match 'upgraded (\d+)/\d+ package') { $count = [int]$Matches[1] }
                Write-Log $_
            }
        } else {
            <# Filtered path: enumerate outdated packages, exclude by pattern, upgrade individually #>
            Write-Log "Chocolatey: ExcludePatterns active ($($script:ExcludePatterns -join ', ')) — enumerating outdated packages"
            $outdatedLines = @()
            try {
                $outdatedLines = @(& choco outdated --limit-output 2>&1 | ForEach-Object { $_.ToString() })
            } catch {
                Write-Log "Chocolatey: Failed to enumerate outdated packages: $_" -Level Error
                return @{ Success = $true; Count = 0 }
            }

            <#
                choco outdated --limit-output emits pipe-delimited lines: packageName|currentVersion|newVersion|pinned
                Skip any line that does not contain a pipe character (warnings, headers, etc.)
            #>
            $toUpgrade = @()
            foreach ($line in $outdatedLines) {
                if ($line -notmatch '\|') { continue }
                $pkgName = ($line -split '\|')[0].Trim()
                if (-not $pkgName) { continue }
                $matchedPattern = $null
                foreach ($pattern in $script:ExcludePatterns) {
                    if ($pkgName.IndexOf($pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $matchedPattern = $pattern; break }
                }
                if ($matchedPattern) {
                    Write-Log "Excluded by pattern '$matchedPattern': $pkgName" -Level Info
                } else {
                    $toUpgrade += $pkgName
                }
            }
            Write-Log "Chocolatey: $($toUpgrade.Count) package(s) to upgrade after exclusions"

            foreach ($pkgName in $toUpgrade) {
                Write-Log "Chocolatey: Upgrading $pkgName"
                & choco upgrade $pkgName -y 2>&1 | ForEach-Object {
                    if ($_ -match 'upgraded (\d+)/\d+ package|Software installed') { $count++ }
                    Write-Log $_
                }
            }
        }
    } else {
        if ($script:ExcludePatterns.Count -eq 0) {
            Write-Log '  [WHATIF] Would run: choco upgrade all -y'
        } else {
            Write-Log '  [WHATIF] Would run: choco outdated --limit-output, then upgrade each non-excluded package individually'
            Write-Log "  [WHATIF] ExcludePatterns: $($script:ExcludePatterns -join ', ')"
        }
    }
    return @{ Success = $true; Count = $count }
}

function Install-WindowsUpdates {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not (Get-Module -ListAvailable PSWindowsUpdate)) {
        Write-Log 'Installing PSWindowsUpdate module...'
        Install-Module PSWindowsUpdate -Force -Scope AllUsers -AllowClobber
    }
    Import-Module PSWindowsUpdate -Force
    Write-Log 'Checking for Windows Updates (excluding SQL Server)...'
    $params = @{
        AcceptAll = $true; Install = $true; NotTitle = ((@('SQL') + ($script:ExcludePatterns | ForEach-Object { [regex]::Escape($_) })) -join '|')
        RootCategories = @('Security Updates','Critical Updates','Definition Updates')
        AutoReboot = $false; Confirm = $false; IgnoreReboot = $true
    }
    $count = 0
    if ($PSCmdlet.ShouldProcess('Windows Update', 'Install available updates')) {
        try {
            Get-WindowsUpdate @params -Verbose 4>&1 | ForEach-Object {
                $line = $_.ToString()
                if ($line -eq 'System.__ComObject') { return }
                if ($_ -match 'Installed|Downloaded') { $count++ }
                Write-Log $line
            }
        } catch { Write-Log "Windows Update error: $_" -Level Error }
    } else {
        Write-Log '  [WHATIF] Would run: Get-WindowsUpdate (install all, exclude SQL)'
    }
    return @{ Success = $true; Count = $count }
}

function Update-PipPackages {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $pip = Get-Command pip -EA SilentlyContinue
    if (-not $pip) { Write-Log 'pip not found, skipping.' -Level Warn; return @{ Success = $true; Count = 0 } }
    Write-Log 'Updating pip packages...'
    $count = 0
    if ($PSCmdlet.ShouldProcess('pip', 'Upgrade pip and outdated packages')) {
        & python -m pip install --upgrade pip 2>&1 | ForEach-Object { Write-Log $_ }
        $outdated = @(& pip list --outdated --format=json 2>$null | ConvertFrom-Json -EA SilentlyContinue)
        foreach ($pkg in $outdated) {
            $matchedPattern = $null
            foreach ($pattern in $script:ExcludePatterns) {
                if ($pkg.name.IndexOf($pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $matchedPattern = $pattern; break }
            }
            if ($matchedPattern) {
                Write-Log "Pip: skipping $($pkg.name) (excluded by pattern '$matchedPattern')"
                continue
            }
            Write-Log "Upgrading: $($pkg.name)"
            & pip install --upgrade "$($pkg.name)" 2>&1 | ForEach-Object { Write-Log $_ }
            $count++
        }
    } else {
        Write-Log '  [WHATIF] Would run: pip install --upgrade <outdated packages>'
    }
    return @{ Success = $true; Count = $count }
}

function Update-NpmPackages {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $npm = Get-Command npm -EA SilentlyContinue
    if (-not $npm) { Write-Log 'npm not found, skipping.' -Level Warn; return @{ Success = $true; Count = 0 } }
    Write-Log 'Updating npm global packages...'
    $count = 0
    if ($PSCmdlet.ShouldProcess('npm', 'Run npm update -g')) {
        & npm update -g 2>&1 | ForEach-Object { if ($_ -match 'added|updated') { $count++ }; Write-Log $_ }
    } else {
        Write-Log '  [WHATIF] Would run: npm update -g'
    }
    return @{ Success = $true; Count = $count }
}

function Update-Office365 {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $c2rClient = "${env:ProgramFiles}\Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe"
    if (-not (Test-Path $c2rClient)) { Write-Log 'Office 365 C2R not found, skipping.' -Level Warn; return @{ Success = $true; Count = 0 } }
    Write-Log 'Updating Office 365 (Click-to-Run)...'
    if ($PSCmdlet.ShouldProcess('Office 365', 'Trigger OfficeC2RClient update')) {
        try {
            & $c2rClient /update user updatepromptuser=false forceappshutdown=true displaylevel=false 2>&1 | ForEach-Object { Write-Log $_ }
            Write-Log 'Office 365 update triggered (may complete in background)'
            return @{ Success = $true; Count = 1 }
        } catch { Write-Log "Office 365 error: $_" -Level Error; return @{ Success = $true; Count = 0 } }
    } else {
        Write-Log '  [WHATIF] Would run: OfficeC2RClient.exe /update user'
        return @{ Success = $true; Count = 0 }
    }
}

function Update-PowerShellModules {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-Log 'Checking installed PowerShell modules...'
    $count = 0
    $usePSResourceGet = [bool](Get-Command Update-PSResource -EA SilentlyContinue)

    if ($usePSResourceGet) {
        <# ── PSResourceGet path: single bulk call in child process (avoids file-lock issues) ── #>
        Write-Log 'Using PSResourceGet (Update-PSResource) for bulk module update...'
        $installed = Get-InstalledPSResource -Scope AllUsers -EA SilentlyContinue
        if (-not $installed) { $installed = Get-InstalledPSResource -EA SilentlyContinue }
        $moduleNames = @($installed | Where-Object {
            $_.Name -notlike 'Microsoft.PowerShell.*' -and
            $_.Name -notlike 'AWS.Tools.*' -and
            $_.Name -ne 'Az' -and
            $_.Type -eq 'Module'
        } | Select-Object -ExpandProperty Name -Unique)
        if (-not $moduleNames) { Write-Log 'No updatable modules found.'; return @{ Success = $true; Count = 0 } }
        Write-Log "Found $($moduleNames.Count) module(s) to update."
        if ($PSCmdlet.ShouldProcess("$($moduleNames.Count) modules", 'Update-PSResource')) {
            $throttle = [Math]::Min(8, [Math]::Max(2, [Environment]::ProcessorCount))
            Write-Log "Running parallel updates (throttle: $throttle)..."
            $job = Start-Job -ScriptBlock {
                param($Names, $Throttle)
                $Names | ForEach-Object -ThrottleLimit $Throttle -Parallel {
                    $n = $_
                    try {
                        $before = (Get-InstalledPSResource -Name $n -EA SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1).Version
                        Update-PSResource -Name $n -Scope AllUsers -TrustRepository -AcceptLicense -Quiet -EA Stop
                        $after = (Get-InstalledPSResource -Name $n -EA SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1).Version
                        if ($after -and $before -and $after -gt $before) {
                            "UPDATED|$n|$before|$after"
                        }
                    } catch {
                        "ERROR|$n|$_"
                    }
                }
            } -ArgumentList (,$moduleNames), $throttle
            $done = $job | Wait-Job -Timeout ($script:PackageTimeoutMinutes * 60)
            if (-not $done) {
                Write-Log "TIMEOUT: PSResource bulk update exceeded ${script:PackageTimeoutMinutes}m" -Level Warn
                try { Get-Process -Id $job.ChildJobs[0].ProcessId -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue } catch { }
                $job | Stop-Job -PassThru | Remove-Job -Force
            } else {
                $results = @(Receive-Job $job -EA SilentlyContinue)
                $jobFailed = $job.State -eq 'Failed'
                Remove-Job $job -Force
                foreach ($line in $results) {
                    if ($line -is [string] -and $line -match '^UPDATED\|(.+)\|(.+)\|(.+)$') {
                        Write-Log "  $($Matches[1]): $($Matches[2]) -> $($Matches[3])"
                        $count++
                    } elseif ($line -is [string] -and $line -match '^ERROR\|(.+)\|(.+)$') {
                        Write-Log "  $($Matches[1]) error: $($Matches[2])" -Level Warn
                    }
                }
                if ($jobFailed) { Write-Log 'PSResource bulk update job reported failure' -Level Warn }
            }
        } else {
            Write-Log "  [WHATIF] Would run: Update-PSResource for $($moduleNames.Count) modules"
        }
    } else {
        <# ── Legacy path: parallel Update-Module via ForEach-Object -Parallel inside one job ── #>
        Write-Log 'PSResourceGet not available — falling back to parallel Update-Module...'
        $installed = Get-InstalledModule -EA SilentlyContinue
        if (-not $installed) { Write-Log 'No user-installed modules found.' -Level Warn; return @{ Success = $true; Count = 0 } }
        $modules = @($installed | Where-Object {
            $_.Name -notlike 'Microsoft.PowerShell.*' -and
            $_.Name -notlike 'AWS.Tools.*' -and
            $_.Name -ne 'Az'
        })
        if (-not $modules) { Write-Log 'Only built-in modules found.'; return @{ Success = $true; Count = 0 } }
        Write-Log "Found $($modules.Count) module(s) to check."
        if ($PSCmdlet.ShouldProcess("$($modules.Count) modules", 'Update-Module')) {
            $throttle = [Math]::Min(8, [Math]::Max(2, [Environment]::ProcessorCount))
            $modulePairs = $modules | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Version = $_.Version.ToString() } }
            Write-Log "Running parallel updates (throttle: $throttle)..."
            $job = Start-Job -ScriptBlock {
                param($Pairs, $Throttle)
                $Pairs | ForEach-Object -ThrottleLimit $Throttle -Parallel {
                    $n = $_.Name; $curVer = $_.Version
                    try {
                        Update-Module -Name $n -Force -EA Stop *> $null
                        $newVer = (Get-InstalledModule -Name $n -EA SilentlyContinue).Version.ToString()
                        if ($newVer -and ($newVer -ne $curVer)) {
                            "UPDATED|$n|$curVer|$newVer"
                        }
                    } catch {
                        if ($_ -match 'already the latest') { return }
                        "ERROR|$n|$_"
                    }
                }
            } -ArgumentList (,$modulePairs), $throttle
            $done = $job | Wait-Job -Timeout ($script:PackageTimeoutMinutes * 60)
            if (-not $done) {
                Write-Log "TIMEOUT: parallel module update exceeded ${script:PackageTimeoutMinutes}m" -Level Warn
                try { Get-Process -Id $job.ChildJobs[0].ProcessId -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue } catch { }
                $job | Stop-Job -PassThru | Remove-Job -Force
            } else {
                $results = @(Receive-Job $job -EA SilentlyContinue)
                $jobFailed = $job.State -eq 'Failed'
                Remove-Job $job -Force
                foreach ($line in $results) {
                    if ($line -is [string] -and $line -match '^UPDATED\|(.+)\|(.+)\|(.+)$') {
                        Write-Log "  $($Matches[1]): $($Matches[2]) -> $($Matches[3])"
                        $count++
                    } elseif ($line -is [string] -and $line -match '^ERROR\|(.+)\|(.+)$') {
                        Write-Log "  $($Matches[1]) error: $($Matches[2])" -Level Warn
                    }
                }
                if ($jobFailed) { Write-Log 'Parallel module update job reported failure' -Level Warn }
            }
        } else {
            Write-Log "  [WHATIF] Would run: parallel Update-Module for $($modules.Count) modules"
        }
    }

    <# AWS.Tools modules: use the dedicated installer if available (both paths) #>
    $awsInstalled = if ($usePSResourceGet) {
        Get-InstalledPSResource -EA SilentlyContinue | Where-Object { $_.Name -like 'AWS.Tools.*' -and $_.Name -ne 'AWS.Tools.Installer' }
    } else {
        Get-InstalledModule -EA SilentlyContinue | Where-Object { $_.Name -like 'AWS.Tools.*' -and $_.Name -ne 'AWS.Tools.Installer' }
    }
    if ($awsInstalled -and (Get-Command Update-AWSToolsModule -EA SilentlyContinue)) {
        Write-Log "Updating $(@($awsInstalled).Count) AWS.Tools module(s) via Update-AWSToolsModule..."
        if ($PSCmdlet.ShouldProcess('AWS.Tools.*', 'Update-AWSToolsModule -CleanUp')) {
            try {
                $job = Start-Job -ScriptBlock { Update-AWSToolsModule -CleanUp -Force -Confirm:$false 2>&1 }
                $done = $job | Wait-Job -Timeout ($script:PackageTimeoutMinutes * 60)
                if (-not $done) {
                    Write-Log 'TIMEOUT: AWS.Tools update exceeded timeout' -Level Warn
                    try { Get-Process -Id $job.ChildJobs[0].ProcessId -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue } catch { }
                    $job | Stop-Job -PassThru | Remove-Job -Force
                } else {
                    $jobOutput = Receive-Job $job -EA SilentlyContinue
                    Remove-Job $job -Force
                    $jobOutput | ForEach-Object { Write-Log $_ }
                    $awsCount = @($jobOutput | Where-Object { $_ -match 'Installed|Updated' }).Count
                    if ($awsCount -gt 0) { Write-Log "  AWS.Tools: $awsCount module(s) updated"; $count += $awsCount }
                    else { Write-Log '  AWS.Tools: already latest' }
                }
            } catch { Write-Log "AWS.Tools update error: $_" -Level Warn }
        } else {
            Write-Log '  [WHATIF] Would run: Update-AWSToolsModule -CleanUp'
        }
    } elseif ($awsInstalled) {
        Write-Log "AWS.Tools modules found but Update-AWSToolsModule not available — skipping (install AWS.Tools.Installer)" -Level Warn
    }

    Write-Log "PS module updates: $count updated."
    return @{ Success = $true; Count = $count }
}

function Update-ScoopPackages {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $isSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
    if ($isSystem) { Write-Log 'Scoop skipped: SYSTEM context (user-scoped).' -Level Warn; return @{ Success = $true; Count = 0 } }
    $scoop = Get-Command scoop -EA SilentlyContinue
    if (-not $scoop) { Write-Log 'Scoop not found, skipping.' -Level Warn; return @{ Success = $true; Count = 0 } }
    Write-Log 'Updating Scoop...'
    if ($PSCmdlet.ShouldProcess('Scoop', 'Run scoop update and scoop update *')) {
        try {
            & scoop update 2>&1 | ForEach-Object { Write-Log $_ }
            Write-Log 'Updating all Scoop packages...'
            $count = 0
            & scoop update * 2>&1 | ForEach-Object {
                if ($_ -match '^\s*\S+:\s+\S+\s+->\s+\S+') { $count++ }
                Write-Log $_
            }
            Write-Log "Scoop: $count package(s) updated."
            return @{ Success = $true; Count = $count }
        } catch { Write-Log "Scoop error: $_" -Level Error; return @{ Success = $true; Count = 0 } }
    } else {
        Write-Log '  [WHATIF] Would run: scoop update && scoop update *'
        return @{ Success = $true; Count = 0 }
    }
}

function Update-DotnetTools {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $dotnet = Get-Command dotnet -EA SilentlyContinue
    if (-not $dotnet) { Write-Log 'dotnet not found, skipping.' -Level Warn; return @{ Success = $true; Count = 0 } }
    Write-Log '*** DOTNET TOOLS UPDATE - HIGH RISK ***' -Level Warn
    Write-Log '    May break SDK-dependent builds. To disable: -SkipDotnetTools' -Level Warn
    try {
        $listOutput = & dotnet tool list --global 2>&1
        $tools = @($listOutput | Select-Object -Skip 2 | Where-Object { $_ -match '^\S' } | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($tools.Count -eq 0) { Write-Log 'No .NET global tools found.'; return @{ Success = $true; Count = 0 } }
        Write-Log "Found $($tools.Count) tool(s): $($tools -join ', ')"
        $count = 0
        foreach ($tool in $tools) {
            Write-Log "Updating: $tool"
            if ($PSCmdlet.ShouldProcess($tool, 'dotnet tool update --global')) {
                try {
                    $output = & dotnet tool update --global $tool 2>&1
                    $output | ForEach-Object { Write-Log $_ }
                    if ($output -match 'was successfully updated') { $count++ }
                } catch { Write-Log "  $tool error: $_" -Level Warn }
            } else {
                Write-Log "  [WHATIF] Would run: dotnet tool update --global $tool"
            }
        }
        Write-Log "dotnet tools: $count updated."
        return @{ Success = $true; Count = $count }
    } catch { Write-Log "dotnet tools error: $_" -Level Error; return @{ Success = $true; Count = 0 } }
}

function Update-VscodeExtensions {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $isSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
    if ($isSystem) { Write-Log 'VS Code skipped: SYSTEM context (per-user).' -Level Warn; return @{ Success = $true; Count = 0 } }
    $codeCmd = Get-Command code -EA SilentlyContinue
    if (-not $codeCmd) { $codeCmd = Get-Command code-insiders -EA SilentlyContinue }
    if (-not $codeCmd) { Write-Log 'VS Code not found, skipping.' -Level Warn; return @{ Success = $true; Count = 0 } }
    Write-Log "Updating VS Code extensions via: $($codeCmd.Name)"
    if ($PSCmdlet.ShouldProcess('VS Code', 'Run code --update-extensions')) {
        try {
            $output = & $codeCmd.Name --update-extensions 2>&1
            $output | ForEach-Object { Write-Log $_ }
            $count = @($output | Where-Object { $_ -match '(?i)updating extension|updated to version' }).Count
            if ($count -eq 0) {
                $upToDate = $output | Where-Object { $_ -match '(?i)already installed|up.to.date' }
                if ($upToDate) { Write-Log 'VS Code extensions: all up to date.'; $count = 0 }
                else { Write-Log 'VS Code extensions: update ran (exact count unavailable).'; $count = 1 }
            } else { Write-Log "VS Code extensions: $count updated." }
            return @{ Success = $true; Count = $count }
        } catch { Write-Log "VS Code error: $_" -Level Error; return @{ Success = $true; Count = 0 } }
    } else {
        Write-Log '  [WHATIF] Would run: code --update-extensions'
        return @{ Success = $true; Count = 0 }
    }
}

function Repair-AwsTooling {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $awsScript = Join-Path $PSScriptRoot 'Repair-AwsTooling.ps1'
    if (-not (Test-Path $awsScript)) { Write-Log 'Repair-AwsTooling.ps1 not found, skipping.' -Level Warn; return $true }
    Write-Log 'Repairing AWS tooling...'
    if ($PSCmdlet.ShouldProcess('AWS tooling', 'Run Repair-AwsTooling.ps1 -Mode Remediate')) {
        try { & $awsScript -Mode Remediate } catch { Write-Log "AWS error: $_" -Level Error }
    } else {
        Write-Log '  [WHATIF] Would run: Repair-AwsTooling.ps1 -Mode Remediate'
    }
    return $true
}
#endregion

#region Health Check
function Test-PostUpdateHealth {
    <#
    .SYNOPSIS
        Verifies that critical Windows services are running after the update cycle.

    .DESCRIPTION
        Checks each service in CriticalServices.  If a service is stopped or
        stop-pending, one non-blocking start attempt is made using a background
        job with a 5-second timeout so a hung SCM call can never stall the cycle.
        Never throws — health check failure must not abort cleanup.

    .OUTPUTS
        [PSCustomObject] with AllHealthy, FailedServices, CheckedServices.
    #>
    param(
        [string[]]$CriticalServices = @('W32Time', 'WinDefend', 'Dnscache', 'Spooler', 'EventLog')
    )

    Write-Log '--- Post-Update Health Check ---'

    $checked = [System.Collections.Generic.List[string]]::new()
    $failed  = [System.Collections.Generic.List[string]]::new()

    foreach ($svc in $CriticalServices) {
        try {
            $serviceObj = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if (-not $serviceObj) {
                Write-Log "  Health check: service not found: $svc (skipped — may not exist on this SKU)" -Level Warn
                continue
            }

            $checked.Add($svc)

            if ($serviceObj.Status -in @('Stopped', 'StopPending')) {
                Write-Log "  Health check: $svc is $($serviceObj.Status) — attempting start (5 s timeout)..."
                $startJob = Start-Job -ScriptBlock {
                    param($n) Start-Service -Name $n -ErrorAction SilentlyContinue
                } -ArgumentList $svc

                Wait-Job -Job $startJob -Timeout 5 | Out-Null
                if ($startJob.State -eq 'Running') {
                    Stop-Job  -Job $startJob
                    Write-Log "  Health check: $svc start timed out (>5 s) — service may still be starting" -Level Warn
                }
                Remove-Job -Job $startJob -Force

                <# Re-query after attempt #>
                $refreshed = Get-Service -Name $svc -ErrorAction SilentlyContinue
                if ($refreshed -and $refreshed.Status -eq 'Running') {
                    Write-Log "  Health check: $svc started successfully"
                } else {
                    $finalStatus = if ($refreshed) { $refreshed.Status } else { 'Unknown' }
                    Write-Log "  Health check: $svc still not running (status: $finalStatus)" -Level Warn
                    $failed.Add($svc)
                }
            } else {
                Write-Log "  Health check: $svc is $($serviceObj.Status)"
            }
        } catch {
            Write-Log "  Health check: unexpected error checking $svc`: $_" -Level Warn
        }
    }

    $allHealthy = ($failed.Count -eq 0)
    if ($allHealthy) {
        Write-Log "  Health check: all $($checked.Count) service(s) healthy"
    } else {
        Write-Log "  Health check: $($failed.Count) service(s) not running: $($failed -join ', ')" -Level Warn
    }

    return [pscustomobject]@{
        AllHealthy      = $allHealthy
        FailedServices  = [string[]]$failed
        CheckedServices = [string[]]$checked
    }
}
#endregion

#region Maintenance Window
function Test-MaintenanceWindow {
    <#
    .SYNOPSIS
        Returns $true if the current hour falls within the configured maintenance window.

    .DESCRIPTION
        If either MaintenanceWindowStart or MaintenanceWindowEnd is -1 (default), no window
        is enforced and the function always returns $true.

        Supports midnight-crossing windows: e.g., Start=22 End=2 covers 10 PM through 2 AM.
        Normal windows: e.g., Start=2 End=5 covers 2 AM through 4:59 AM.

    .OUTPUTS
        [bool] $true = inside window (proceed); $false = outside window (defer).
    #>
    if ($script:MaintenanceWindowStart -eq -1 -or $script:MaintenanceWindowEnd -eq -1) {
        return $true
    }

    $now = (Get-Date).Hour

    if ($script:MaintenanceWindowStart -gt $script:MaintenanceWindowEnd) {
        # Midnight-crossing window (e.g., Start=22, End=2: 10 PM to 2 AM)
        return ($now -ge $script:MaintenanceWindowStart) -or ($now -lt $script:MaintenanceWindowEnd)
    } else {
        # Normal window (e.g., Start=2, End=5: 2 AM to 4:59 AM)
        return ($now -ge $script:MaintenanceWindowStart) -and ($now -lt $script:MaintenanceWindowEnd)
    }
}
#endregion

#region Task Management
function Unregister-BootUpdateTask {
    $taskName = 'BootUpdateCycle'
    if (Get-ScheduledTask -TaskName $taskName -EA SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Log 'Scheduled task removed.'
    }
}

function Register-BootUpdateTaskForReboot {
    $taskName = 'BootUpdateCycle'
    $pwshPath = (Get-Command pwsh -EA SilentlyContinue).Source
    if (-not $pwshPath) { $pwshPath = "$env:ProgramFiles\PowerShell\7\pwsh.exe" }
    $scriptPath = Join-Path $PSScriptRoot 'Invoke-BootUpdateCycle.ps1'
    $taskArgs = @(
        '-NoProfile', '-ExecutionPolicy Bypass'
        "-File `"$scriptPath`"", '-Force'
        "-MaxIterations $($script:MaxIterations)"
        "-PackageTimeoutMinutes $($script:PackageTimeoutMinutes)"
        "-RebootDelaySec $($script:RebootDelaySec)"
    )
    if ($script:SkipPip)              { $taskArgs += '-SkipPip' }
    if ($script:SkipNpm)              { $taskArgs += '-SkipNpm' }
    if ($script:SkipOffice365)        { $taskArgs += '-SkipOffice365' }
    if ($script:SkipAwsTooling)       { $taskArgs += '-SkipAwsTooling' }
    if ($script:SkipPowerShellModules){ $taskArgs += '-SkipPowerShellModules' }
    if ($script:SkipScoop)            { $taskArgs += '-SkipScoop' }
    if ($script:SkipDotnetTools)      { $taskArgs += '-SkipDotnetTools' }
    if ($script:SkipVscode)           { $taskArgs += '-SkipVscode' }
    if ($script:SkipRestorePoint)     { $taskArgs += '-SkipRestorePoint' }
    if ($script:SkipHealthCheck)      { $taskArgs += '-SkipHealthCheck' }
    if ($script:StagedRollout)        { $taskArgs += '-StagedRollout' }
    if ($script:WebhookUrl)           { $taskArgs += "-WebhookUrl `"$($script:WebhookUrl)`"" }
    if ($script:NotifyEmail)          { $taskArgs += "-NotifyEmail `"$($script:NotifyEmail)`"" }
    if ($script:SmtpServer)           { $taskArgs += "-SmtpServer `"$($script:SmtpServer)`"" }
    if ($script:MaintenanceWindowStart -ge 0) { $taskArgs += "-MaintenanceWindowStart $($script:MaintenanceWindowStart)" }
    if ($script:MaintenanceWindowEnd   -ge 0) { $taskArgs += "-MaintenanceWindowEnd $($script:MaintenanceWindowEnd)" }
    if ($script:ExcludePatterns.Count -gt 0) {
        $patternStr = ($script:ExcludePatterns | ForEach-Object { "'$($_ -replace "'", "''")'" }) -join ','
        $taskArgs += "-ExcludePatterns @($patternStr)"
    }
    $argString = $taskArgs -join ' '
    $action   = New-ScheduledTaskAction -Execute $pwshPath -Argument $argString -WorkingDirectory $PSScriptRoot
    $trigger  = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 4)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Boot update loop: patches everything, reboots until clean.' -Force | Out-Null
    Write-Log "Scheduled task registered: $taskName (SYSTEM at startup)"
}

function Suspend-BitLockerForReboot {
    <# Suspends BitLocker protection for exactly one reboot so the unattended loop
       doesn't land at a recovery prompt.  Best-effort — never throws. #>
    try {
        if ($script:SkipBitLocker) {
            Write-Log 'BitLocker suspend skipped (-SkipBitLocker).'
            return
        }

        $protectedVolumes = Get-BitLockerVolume -ErrorAction Stop |
            Where-Object { $_.ProtectionStatus -eq 'On' }

        if (-not $protectedVolumes) {
            Write-Log 'BitLocker: no protected volumes found — nothing to suspend.'
            return
        }

        foreach ($vol in $protectedVolumes) {
            $drive = $vol.MountPoint
            $suspended = $false

            # Primary path: BitLocker cmdlet (preferred — returns structured objects)
            try {
                $vol | Suspend-BitLocker -RebootCount 1 -ErrorAction Stop | Out-Null
                Write-Log "BitLocker suspended for 1 reboot on $drive"
                $suspended = $true
            } catch {
                Write-Log "BitLocker cmdlet failed on $drive (${_}); trying manage-bde fallback." -Level Warn
            }

            # Fallback: manage-bde.exe (available even when the PS module is broken)
            if (-not $suspended) {
                try {
                    $bdeOut = & manage-bde.exe -protectors -disable $drive -RebootCount 1 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Log "BitLocker suspended via manage-bde on $drive"
                    } else {
                        Write-Log "manage-bde failed on $drive (exit $LASTEXITCODE): $bdeOut" -Level Warn
                    }
                } catch {
                    Write-Log "manage-bde.exe unavailable on ${drive}: $_" -Level Warn
                }
            }
        }
    } catch {
        Write-Log "Suspend-BitLockerForReboot: unexpected error: $_" -Level Warn
    }
}
#endregion

#region Notifications
function Write-EventLogEntry {
    <# Central event log helper.  IDs: 1000=Complete, 1001=Reboot, 1002=Started, 1003=Failed, 1004=PhaseComplete #>
    param([int]$EventId, [string]$EntryType = 'Information', [string]$Message)
    try {
        $src = 'BootUpdateCycle'
        if (-not [System.Diagnostics.EventLog]::SourceExists($src)) { New-EventLog -LogName Application -Source $src -EA SilentlyContinue }
        Write-EventLog -LogName Application -Source $src -EventId $EventId -EntryType $EntryType -Message $Message
    } catch { }
}

function Send-WebhookNotification {
    param(
        [string]$Title,
        [string]$Message,
        [hashtable]$Data = @{}
    )
    if ([string]::IsNullOrWhiteSpace($script:WebhookUrl)) { return }

    <# Transparent-proxy support: SYSTEM context may not inherit user proxy config #>
    [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials

    $url = $script:WebhookUrl

    <# Build facts/fields from $Data for richer payloads #>
    $totalPkgs  = if ($Data.ContainsKey('_total'))     { $Data['_total'] }     else { 0 }
    $iterations = if ($Data.ContainsKey('_iterations')) { $Data['_iterations'] } else { 0 }
    $durMin     = if ($Data.ContainsKey('_durMin'))    { $Data['_durMin'] }    else { 0 }

    $perMgr = @(
        @{ n = 'Winget';          k = 'Winget'          }
        @{ n = 'Chocolatey';      k = 'Chocolatey'      }
        @{ n = 'Windows Update';  k = 'WindowsUpdate'   }
        @{ n = 'pip';             k = 'Pip'             }
        @{ n = 'npm';             k = 'Npm'             }
        @{ n = 'Office 365';      k = 'Office365'       }
        @{ n = 'PS Modules';      k = 'PowerShellModules' }
        @{ n = 'Scoop';           k = 'Scoop'           }
        @{ n = '.NET Tools';      k = 'DotnetTools'     }
        @{ n = 'VS Code';         k = 'Vscode'          }
    )

    try {
        if ($url -match 'webhook\.office\.com|teams') {
            <# Microsoft Teams: MessageCard format #>
            $facts = @(
                @{ name = 'Duration';    value = "$durMin min" }
                @{ name = 'Iterations';  value = "$iterations" }
                @{ name = 'Total Pkgs';  value = "$totalPkgs"  }
            )
            foreach ($pm in $perMgr) {
                $cnt = if ($Data.ContainsKey($pm.k)) { $Data[$pm.k] } else { 0 }
                if ($cnt -gt 0) { $facts += @{ name = $pm.n; value = "$cnt pkg(s)" } }
            }
            $payload = [ordered]@{
                '@type'      = 'MessageCard'
                '@context'   = 'https://schema.org/extensions'
                themeColor   = '0078D4'
                title        = $Title
                text         = $Message
                facts        = $facts
            }
        } elseif ($url -match 'hooks\.slack\.com') {
            <# Slack: simple text payload #>
            $lines = @($Title, $Message, "Duration: $durMin min | Iterations: $iterations | Total: $totalPkgs pkg(s)")
            foreach ($pm in $perMgr) {
                $cnt = if ($Data.ContainsKey($pm.k)) { $Data[$pm.k] } else { 0 }
                if ($cnt -gt 0) { $lines += "$($pm.n): $cnt" }
            }
            $payload = @{ text = ($lines -join "`n") }
        } elseif ($url -match 'discord\.com') {
            <# Discord: embeds format #>
            $fields = @(
                @{ name = 'Duration';   value = "$durMin min";    inline = $true }
                @{ name = 'Iterations'; value = "$iterations";    inline = $true }
                @{ name = 'Total Pkgs'; value = "$totalPkgs pkg"; inline = $true }
            )
            foreach ($pm in $perMgr) {
                $cnt = if ($Data.ContainsKey($pm.k)) { $Data[$pm.k] } else { 0 }
                if ($cnt -gt 0) { $fields += @{ name = $pm.n; value = "$cnt"; inline = $true } }
            }
            $payload = @{
                content = $Title
                embeds  = @(@{
                    description = $Message
                    color       = 5025616  <# #4CAF50 green #>
                    fields      = $fields
                })
            }
        } else {
            <# Generic fallback #>
            $payload = @{ text = "$Title`n$Message" }
        }

        $jsonBody = $payload | ConvertTo-Json -Depth 6 -Compress
        $maxRetries = 3
        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            try {
                Invoke-RestMethod -Uri $url -Method Post -Body $jsonBody `
                    -ContentType 'application/json' -TimeoutSec 10 -ErrorAction Stop | Out-Null
                Write-Log "Notification: webhook delivered"
                break
            } catch {
                if ($attempt -lt $maxRetries) {
                    Write-Log "Notification: webhook attempt $attempt failed, retrying in $($attempt * 2)s..." -Level Warn
                    Start-Sleep -Seconds ($attempt * 2)
                } else {
                    Write-Log "Notification: webhook failed after $maxRetries attempts: $_" -Level Warn
                }
            }
        }
    } catch {
        Write-Log "Notification: webhook error: $_" -Level Warn
    }
}

function Send-EmailNotification {
    param(
        [string]$Title,
        [string]$Message,
        [hashtable]$Data = @{}
    )
    if ([string]::IsNullOrWhiteSpace($script:NotifyEmail)) { return }
    if ([string]::IsNullOrWhiteSpace($script:SmtpServer))  { return }

    <# SMTP auth: pass credential if provided, otherwise rely on anonymous/relay #>

    Write-Log "Sending email notification to $($script:NotifyEmail)"

    $totalPkgs  = if ($Data.ContainsKey('_total'))     { $Data['_total'] }     else { 0 }
    $iterations = if ($Data.ContainsKey('_iterations')) { $Data['_iterations'] } else { 0 }
    $durMin     = if ($Data.ContainsKey('_durMin'))    { $Data['_durMin'] }    else { 0 }

    $bodyLines = @(
        $Title
        ''
        $Message
        ''
        "Duration:   $durMin min"
        "Iterations: $iterations"
        "Total pkgs: $totalPkgs"
        ''
        "Per package manager:"
        "  Winget:          $($Data['Winget'] ?? 0)"
        "  Chocolatey:      $($Data['Chocolatey'] ?? 0)"
        "  Windows Update:  $($Data['WindowsUpdate'] ?? 0)"
        "  pip:             $($Data['Pip'] ?? 0)"
        "  npm:             $($Data['Npm'] ?? 0)"
        "  Office 365:      $($Data['Office365'] ?? 0)"
        "  PS Modules:      $($Data['PowerShellModules'] ?? 0)"
        "  Scoop:           $($Data['Scoop'] ?? 0)"
        "  .NET Tools:      $($Data['DotnetTools'] ?? 0)"
        "  VS Code:         $($Data['Vscode'] ?? 0)"
        ''
        "Host: $env:COMPUTERNAME"
        "Sent: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    )

    try {
        $mailParams = @{
            To         = $script:NotifyEmail
            From       = "BootUpdateCycle@$env:COMPUTERNAME"
            Subject    = $Title
            Body       = ($bodyLines -join "`n")
            SmtpServer = $script:SmtpServer
            UseSsl     = $true
            Port       = 587
        }
        if ($script:SmtpCredential) {
            $mailParams['Credential'] = $script:SmtpCredential
        }
        $mailJob = Send-MailMessage @mailParams -AsJob
        Write-Log "Notification: email job queued to $($script:NotifyEmail)"
        $null = Wait-Job -Job $mailJob -Timeout 30
        $jobErrors = @(Receive-Job -Job $mailJob -ErrorAction SilentlyContinue -ErrorVariable receiveErrs 2>$null)
        if ($receiveErrs) { Write-Log "Notification: email job errors: $($receiveErrs -join '; ')" -Level Warn }
        Remove-Job -Job $mailJob -Force
    } catch {
        Write-Log "Notification: email failed: $_" -Level Warn
    }
}

function Send-CompletionNotification {
    param([string]$Title, [string]$Message, [pscustomobject]$Data = $null)
    Write-Log 'Sending completion notifications...'
    <# msg.exe broadcast #>
    try {
        $msgExe = Join-Path $env:SystemRoot 'System32\msg.exe'
        if (Test-Path $msgExe) { & $msgExe * /TIME:120 "$Title`n`n$Message" 2>$null; if ($LASTEXITCODE -eq 0) { Write-Log 'Notification: msg.exe sent' } }
    } catch { }
    <# BurntToast (user context only) #>
    $isSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
    if (-not $isSystem) {
        try {
            if (-not (Get-Module -ListAvailable BurntToast)) { Install-Module BurntToast -Force -Scope CurrentUser -AllowClobber }
            Import-Module BurntToast -Force; New-BurntToastNotification -Text $Title, $Message -AppLogo $null
            Write-Log 'Notification: BurntToast sent'
        } catch { Write-Log "Notification: BurntToast failed: $_" -Level Warn }
    }
    Write-EventLogEntry -EventId 1000 -Message "$Title`n$Message"

    <# Build a flat hashtable from the pscustomobject summary for webhook/email functions #>
    $dataHt = @{}
    if ($null -ne $Data) {
        foreach ($prop in $Data.PSObject.Properties) { $dataHt[$prop.Name] = $prop.Value }
    }
    Send-WebhookNotification -Title $Title -Message $Message -Data $dataHt
    Send-EmailNotification   -Title $Title -Message $Message -Data $dataHt
}

function Send-RebootWarning {
    param([int]$SecondsUntilReboot = 120)
    $msgFull = "Boot Update Cycle needs to reboot.`nReboot in: $SecondsUntilReboot seconds`nTo cancel: shutdown /a"
    Write-Log 'Sending reboot warnings...'
    $isSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
    if (-not $isSystem) {
        try { if (Get-Module -ListAvailable BurntToast) { Import-Module BurntToast -Force; New-BurntToastNotification -Text 'System Reboot Warning', $msgFull -AppLogo $null -Sound 'Alarm' } } catch { }
    }
    Write-EventLogEntry -EventId 1001 -EntryType Warning -Message $msgFull
}
#endregion

#region Console Visuals
<# Console-only visual elements for progress monitoring.  These use Write-Host
   and do NOT go to the log file — the log stays clean and greppable.  #>

function Show-StartupArt {
    <# BBS-inspired ANSI splash — ░▒▓█ gradient borders, neon palette, interpunct
       separators.  Evokes the ACiD/iCE era login screens of the early '90s.
       UTF-8 console encoding is forced at script start; on cmd.exe this requires
       chcp 65001 to also have run, which we attempt at top of file. #>
    $e = [char]27
    <# Curated neon palettes — each is (art, bar-accent, tagline) #>
    $palettes = @(
        @{ art = '96'; bar = '94'; tag = '93' }   # Cyan / Blue / Yellow (original)
        @{ art = '92'; bar = '96'; tag = '93' }   # Green / Cyan / Yellow
        @{ art = '95'; bar = '94'; tag = '96' }   # Magenta / Blue / Cyan
        @{ art = '93'; bar = '95'; tag = '92' }   # Yellow / Magenta / Green
        @{ art = '94'; bar = '92'; tag = '95' }   # Blue / Green / Magenta
        @{ art = '91'; bar = '93'; tag = '96' }   # Red / Yellow / Cyan
    )
    $p = $palettes[(Get-Random -Maximum $palettes.Count)]

    $art = "$e[$($p.art)m"; $bar2 = "$e[$($p.bar)m"; $tag = "$e[$($p.tag)m"
    $wh = "$e[97m"; $dk = "$e[90m"; $mg = "$e[95m"
    $B  = "$e[1m";  $r  = "$e[0m"

    $barLine = "$dk░▒$bar2▓$mg█$art$B$('═' * 56)$r$mg█$bar2▓$dk▒░$r"

    Write-Host ""
    Write-Host "  $barLine"
    Write-Host ""
    Write-Host "  $art$B    ██████╗  ██████╗  ██████╗ ████████╗$r"
    Write-Host "  $art$B    ██╔══██╗██╔═══██╗██╔═══██╗╚══██╔══╝$r"
    Write-Host "  $art$B    ██████╔╝██║   ██║██║   ██║   ██║$r"
    Write-Host "  $art$B    ██╔══██╗██║   ██║██║   ██║   ██║$r"
    Write-Host "  $art$B    ██████╔╝╚██████╔╝╚██████╔╝   ██║$r"
    Write-Host "  $art$B    ╚═════╝  ╚═════╝  ╚═════╝    ╚═╝$r"
    Write-Host ""
    Write-Host "  $wh$B    U P D A T E $dk·$wh C Y C L E$r                     $dk v$($script:BootUpdateCycleVersion)$r"
    Write-Host ""
    Write-Host "  $barLine"
    Write-Host ""
    Write-Host "  $tag    $dk·$tag Updating all the things so you don't have to. $dk·$r"
    Write-Host ""
}

function Show-CycleBanner {
    param([string]$Title, [string]$AnsiColor, [string[]]$Info)
    $e = [char]27; $b = "$e[1m"; $d = "$e[2m"; $w = "$e[97m"; $r = "$e[0m"
    $len = 70
    Write-Host ""
    Write-Host "$AnsiColor$b  $('=' * $len)$r"
    Write-Host ""
    Write-Host "$AnsiColor$b    $w$Title$r"
    Write-Host ""
    if ($Info.Count -gt 0) {
        Write-Host "$AnsiColor  $('-' * $len)$r"
        foreach ($line in $Info) { Write-Host "$d    $line$r" }
        Write-Host ""
    }
    Write-Host "$AnsiColor$b  $('=' * $len)$r"
    Write-Host ""
}

function Write-PhaseHeader {
    param([int]$Num, [int]$Total, [string]$Name)
    $e = [char]27; $c = "$e[36m"; $b = "$e[1m"; $w = "$e[97m"; $r = "$e[0m"
    $label = "[$Num/$Total] $Name"
    $pad = 66 - $label.Length; if ($pad -lt 3) { $pad = 3 }
    Write-Host ""
    Write-Host "$c$b  --- $w$label $c$('-' * $pad)$r"
}

function Write-PhaseResult {
    param([int]$Num, [int]$Total, [string]$Name, [bool]$Success, [double]$Minutes, [int]$Count = 0)
    $e = [char]27; $g = "$e[32m"; $red = "$e[31m"; $r = "$e[0m"
    $countMsg = if ($Count -gt 0) { ", $Count pkg" } else { '' }
    $t = "$([math]::Round($Minutes, 1)) min"
    if ($Success) { Write-Host "$g  >>> [$Num/$Total] $Name done ($t$countMsg)$r" }
    else          { Write-Host "$red  !!! [$Num/$Total] $Name FAILED ($t)$r" }
}

function Write-PhaseSkip {
    param([string]$Name)
    $e = [char]27; $d = "$e[2m"; $r = "$e[0m"
    Write-Host "$d    ~ $Name skipped$r"
}
#endregion

#region Main Orchestration
function Invoke-BootUpdateCycle {
    Invoke-LogRotation

    $state = Get-BootUpdateState
    $isFirstIteration = -not $state.StartTime
    if ($isFirstIteration) { $state.StartTime = Get-Date -Format 'o' }
    $pendingIteration = $state.Iteration + 1

    $sessionId = ([datetime]$state.StartTime).ToString('yyyy-MM-dd HH:mm:ss')
    $cycleVerb = if ($isFirstIteration) { 'STARTED' } else { 'RESUMED (after reboot)' }
    $context = if (([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value) -eq 'S-1-5-18') { 'SYSTEM (scheduled task)' } else { "$env:USERNAME (user context)" }

    <# Console: BBS splash on every run #>
    Show-StartupArt
    $bannerTitle = if ($WhatIfPreference) {
        "B O O T   U P D A T E   C Y C L E      [WHATIF - NO CHANGES]    v$($script:BootUpdateCycleVersion)"
    } else {
        "B O O T   U P D A T E   C Y C L E                           v$($script:BootUpdateCycleVersion)"
    }
    $bannerInfo = [System.Collections.Generic.List[string]]@(
        "$cycleVerb"
        "Session:    $sessionId"
        "Iteration:  $pendingIteration of $MaxIterations"
        "Context:    $context"
    )
    if ($script:MaintenanceWindowStart -ge 0) {
        $bannerInfo.Add("Window:     $($script:MaintenanceWindowStart):00 - $($script:MaintenanceWindowEnd):00")
    }
    Show-CycleBanner -Title $bannerTitle -AnsiColor "$([char]27)[36m" -Info $bannerInfo.ToArray()
    <# Log file: clean greppable entry #>
    $whatIfTag = if ($WhatIfPreference) { ' [WHATIF]' } else { '' }
    Write-Log "BOOT UPDATE CYCLE$whatIfTag $cycleVerb | Session: $sessionId | Iteration: $pendingIteration/$MaxIterations | Context: $context"
    if ($script:MaintenanceWindowStart -ge 0) { Write-Log "Maintenance window: $($script:MaintenanceWindowStart):00 - $($script:MaintenanceWindowEnd):00" -Level Info }

    <# Event Log: cycle started #>
    Write-EventLogEntry -EventId 1002 -Message "Boot Update Cycle $cycleVerb`nSession: $sessionId`nIteration: $pendingIteration of $MaxIterations"

    <# Maintenance window gate — exit clean (task survives) if outside configured window #>
    if (-not (Test-MaintenanceWindow)) {
        Write-Log "Outside maintenance window ($($script:MaintenanceWindowStart):00 - $($script:MaintenanceWindowEnd):00). Current hour: $((Get-Date).Hour). Deferring." -Level Warn
        exit 0
    }

    <# Commit iteration increment only after maintenance window gate passes #>
    $state.Iteration++
    Set-BootUpdateState -State $state

    <# Pre-flight checks (every iteration — disk/network can change between reboots) #>
    $preflight = Test-PreFlightChecks -Force:$Force
    if (-not $preflight.CanProceed) {
        Write-Log 'Update cycle aborted by pre-flight checks.' -Level Error
        Write-EventLogEntry -EventId 1003 -EntryType Error -Message "Cycle aborted by pre-flight checks.`nErrors: $($preflight.Errors -join '; ')"
        if (-not $WhatIfPreference) { Unregister-BootUpdateTask; Clear-BootUpdateState }
        exit 1
    }

    <# Max iterations safety valve #>
    if ($state.Iteration -gt $MaxIterations) {
        Write-Log "Max iterations ($MaxIterations) exceeded. Stopping." -Level Error
        Write-EventLogEntry -EventId 1003 -EntryType Error -Message "Cycle stopped: exceeded $MaxIterations iterations.`nSession: $sessionId"
        if (-not $WhatIfPreference) { Unregister-BootUpdateTask; Clear-BootUpdateState }
        return
    }

    <# Crash recovery #>
    $null = Test-CrashRecovery -State $state

    $pending = Test-PendingReboot
    if ($pending) { $pending | ForEach-Object { Write-Log "Pending reboot: $($_.Source)" -Level Warn } }
    else { Write-Log 'No pending reboots at start of iteration' }

    <# System restore point — first iteration only; skipped on SYSTEM, Server SKUs, -SkipRestorePoint, or WhatIf #>
    if ($isFirstIteration) {
        $null = New-SystemRestorePoint
    }

    <# ---- Phase counter for progress display ---- #>
    $allPhases = @(
        @{ Name='Winget';            Flag='WingetDone';            Key='Winget';            Skip=$false;                     Action={ Update-WingetPackages } }
        @{ Name='Chocolatey';        Flag='ChocolateyDone';        Key='Chocolatey';        Skip=$false;                     Action={ Update-ChocolateyPackages } }
        @{ Name='WindowsUpdate';     Flag='WindowsUpdateDone';     Key='WindowsUpdate';     Skip=$false;                     Action={ Install-WindowsUpdates } }
        @{ Name='AwsTooling';        Flag='AwsToolingDone';        Key=$null;               Skip=[bool]$SkipAwsTooling;      Action={ $r = Repair-AwsTooling; @{ Success = $r; Count = 0 } } }
        @{ Name='Pip';               Flag='PipDone';               Key='Pip';               Skip=[bool]$SkipPip;             Action={ Update-PipPackages } }
        @{ Name='Npm';               Flag='NpmDone';               Key='Npm';               Skip=[bool]$SkipNpm;             Action={ Update-NpmPackages } }
        @{ Name='Office365';         Flag='Office365Done';         Key='Office365';         Skip=[bool]$SkipOffice365;       Action={ Update-Office365 } }
        @{ Name='PowerShellModules'; Flag='PowerShellModulesDone'; Key='PowerShellModules'; Skip=[bool]$SkipPowerShellModules; Action={ Update-PowerShellModules } }
        @{ Name='Scoop';             Flag='ScoopDone';             Key='Scoop';             Skip=[bool]$SkipScoop;           Action={ Update-ScoopPackages } }
        @{ Name='DotnetTools';       Flag='DotnetToolsDone';       Key='DotnetTools';       Skip=[bool]$SkipDotnetTools;     Action={ Update-DotnetTools } }
        @{ Name='Vscode';            Flag='VscodeDone';            Key='Vscode';            Skip=[bool]$SkipVscode;          Action={ Update-VscodeExtensions } }
    )
    $enabledPhases = @($allPhases | Where-Object { -not $_.Skip })
    $phaseNum = 0

    <# ---- Staged rollout: one phase per boot; or all phases in one boot (default) ---- #>
    if ($script:StagedRollout) {
        <# Staged mode: determine the single phase to run this boot.
           If StagedNextPhase points to a valid undone enabled phase, honour it.
           Otherwise find the first undone enabled phase (first boot or post-reboot reset). #>

        $targetPhase = $null

        if (-not [string]::IsNullOrWhiteSpace($state.StagedNextPhase)) {
            $candidate = $allPhases | Where-Object { $_.Name -eq $state.StagedNextPhase } | Select-Object -First 1
            if ($candidate -and (-not $candidate.Skip) -and (-not [bool]$state.($candidate.Flag))) {
                $targetPhase = $candidate
            }
        }

        if (-not $targetPhase) {
            $targetPhase = $allPhases | Where-Object { (-not $_.Skip) -and (-not [bool]$state.($_.Flag)) } | Select-Object -First 1
        }

        if ($targetPhase) {
            $state.StagedNextPhase = $targetPhase.Name
            Set-BootUpdateState -State $state
            Write-Log "Staged rollout mode: running phase [$($state.StagedNextPhase)] only this iteration." -Level Info

            <# Compute display position within enabled phases #>
            $enabledPhaseNames = [System.Collections.Generic.List[string]]::new()
            foreach ($ep in $enabledPhases) { $enabledPhaseNames.Add($ep.Name) }
            $phaseNum = $enabledPhaseNames.IndexOf($targetPhase.Name) + 1
            if ($phaseNum -lt 1) { $phaseNum = 1 }

            Write-PhaseHeader -Num $phaseNum -Total $enabledPhases.Count -Name $targetPhase.Name
            Write-Log ">>> [$phaseNum/$($enabledPhases.Count)] $($targetPhase.Name) - STARTING"
            $phaseStart = Get-Date

            $state.LastPhaseStarted = $targetPhase.Name; $state.LastPhaseTimestamp = Get-Date -Format 'o'; $state.Phase = $targetPhase.Name
            Set-BootUpdateState -State $state

            try {
                if ($PSCmdlet.ShouldProcess($targetPhase.Name, "Run $($targetPhase.Name) updates")) {
                    $r = & $targetPhase.Action
                } else {
                    Write-Log "  [WHATIF] Would execute phase: $($targetPhase.Name)"
                    $r = @{ Success = $true; Count = 0 }
                }
                $state.($targetPhase.Flag) = $r.Success
                $phaseCount = if ($targetPhase.Key -and $r.Count) { $state.Summary.($targetPhase.Key) += $r.Count; $r.Count } else { 0 }
                $elapsed = (Get-Date) - $phaseStart

                Write-PhaseResult -Num $phaseNum -Total $enabledPhases.Count -Name $targetPhase.Name -Success $true -Minutes $elapsed.TotalMinutes -Count $phaseCount
                Write-Log "<<< [$phaseNum/$($enabledPhases.Count)] $($targetPhase.Name) - DONE ($([math]::Round($elapsed.TotalMinutes, 1)) min, $phaseCount pkg)"
                Write-EventLogEntry -EventId 1004 -Message "$($targetPhase.Name) complete: $phaseCount packages in $([math]::Round($elapsed.TotalMinutes,1)) min"
            } catch {
                $elapsed = (Get-Date) - $phaseStart

                Write-PhaseResult -Num $phaseNum -Total $enabledPhases.Count -Name $targetPhase.Name -Success $false -Minutes $elapsed.TotalMinutes
                Write-Log "<<< [$phaseNum/$($enabledPhases.Count)] $($targetPhase.Name) - FAILED ($([math]::Round($elapsed.TotalMinutes, 1)) min)" -Level Error
                Write-Log "  Error: $_" -Level Error
                if ($_.Exception.StackTrace) { Write-Log "  Stack: $($_.Exception.StackTrace)" -Level Error }
                if ($_.Exception.InnerException) { Write-Log "  Inner: $($_.Exception.InnerException.Message)" -Level Error }
                Write-EventLogEntry -EventId 1003 -EntryType Error -Message "$($targetPhase.Name) failed: $_"
                $state.($targetPhase.Flag) = $true  <# fail-forward #>
            }
            Set-BootUpdateState -State $state
        } else {
            <# All enabled phases already done — fall through to reboot/completion decision #>
            Write-Log 'Staged rollout: all phases already complete for this cycle.' -Level Info
        }
    } else {
        <# Non-staged mode: iterate all phases in sequence (v2.0 behaviour preserved) #>
    }

    if (-not $script:StagedRollout) { foreach ($phase in $allPhases) {
        if ($phase.Skip) {
            Write-PhaseSkip -Name $phase.Name
            Write-Log "  [SKIP] $($phase.Name) (disabled)"
            continue
        }
        if ($state.($phase.Flag)) { $phaseNum++; continue }  <# Already done this iteration #>

        $phaseNum++

        <# Console: styled phase header #>
        Write-PhaseHeader -Num $phaseNum -Total $enabledPhases.Count -Name $phase.Name
        Write-Log ">>> [$phaseNum/$($enabledPhases.Count)] $($phase.Name) - STARTING"
        $phaseStart = Get-Date

        <# Crash-recovery markers: write intent before execution (skipped in WhatIf) #>
        $state.LastPhaseStarted = $phase.Name; $state.LastPhaseTimestamp = Get-Date -Format 'o'; $state.Phase = $phase.Name
        Set-BootUpdateState -State $state

        try {
            <# ShouldProcess guard: in WhatIf mode the phase Action is NOT invoked #>
            if ($PSCmdlet.ShouldProcess($phase.Name, "Run $($phase.Name) updates")) {
                $r = & $phase.Action
            } else {
                Write-Log "  [WHATIF] Would execute phase: $($phase.Name)"
                $r = @{ Success = $true; Count = 0 }
            }
            $state.($phase.Flag) = $r.Success
            $phaseCount = if ($phase.Key -and $r.Count) { $state.Summary.($phase.Key) += $r.Count; $r.Count } else { 0 }
            $elapsed = (Get-Date) - $phaseStart

            <# Console: styled result #>
            Write-PhaseResult -Num $phaseNum -Total $enabledPhases.Count -Name $phase.Name -Success $true -Minutes $elapsed.TotalMinutes -Count $phaseCount
            Write-Log "<<< [$phaseNum/$($enabledPhases.Count)] $($phase.Name) - DONE ($([math]::Round($elapsed.TotalMinutes, 1)) min, $phaseCount pkg)"
            Write-EventLogEntry -EventId 1004 -Message "$($phase.Name) complete: $phaseCount packages in $([math]::Round($elapsed.TotalMinutes,1)) min"
        } catch {
            $elapsed = (Get-Date) - $phaseStart

            <# Console: styled failure #>
            Write-PhaseResult -Num $phaseNum -Total $enabledPhases.Count -Name $phase.Name -Success $false -Minutes $elapsed.TotalMinutes
            Write-Log "<<< [$phaseNum/$($enabledPhases.Count)] $($phase.Name) - FAILED ($([math]::Round($elapsed.TotalMinutes, 1)) min)" -Level Error
            Write-Log "  Error: $_" -Level Error
            if ($_.Exception.StackTrace) { Write-Log "  Stack: $($_.Exception.StackTrace)" -Level Error }
            if ($_.Exception.InnerException) { Write-Log "  Inner: $($_.Exception.InnerException.Message)" -Level Error }
            Write-EventLogEntry -EventId 1003 -EntryType Error -Message "$($phase.Name) failed: $_"
            $state.($phase.Flag) = $true  <# fail-forward #>
        }
        Set-BootUpdateState -State $state
    } }  <# end foreach ($phase in $allPhases) / end if (-not $script:StagedRollout) #>

    <# ---- Post-update health check ---- #>
    $healthCheck = if ($script:SkipHealthCheck) { $null } else { Test-PostUpdateHealth }
    if ($healthCheck -and -not $healthCheck.AllHealthy) {
        Write-Log "Health check detected failed services: $($healthCheck.FailedServices -join ', ')" -Level Warn
        $state.Summary.HealthFailed = $healthCheck.FailedServices.Count
        Set-BootUpdateState -State $state
    }

    <# ---- Post-update reboot decision ---- #>
    <# In WhatIf mode, always report clean — no reboot or task registration ever happens #>
    $pending = if ($WhatIfPreference) { @() } else { Test-PendingReboot }
    if ($pending) {
        Write-Log 'Pending reboot after updates: YES' -Level Warn
        $pending | ForEach-Object { Write-Log "  - $($_.Source)" -Level Warn }

        <# Reset phase Done flags for next iteration.
           Staged mode: reset ONLY the current phase's flag — completed phases are not re-run
           after the reboot (the current phase re-runs because the reboot may have been triggered
           by updates it installed).
           Non-staged mode: reset ALL flags — all phases re-run after each reboot (v2.0 behaviour). #>
        if ($script:StagedRollout -and $targetPhase) {
            $state.($targetPhase.Flag) = $false
            Write-Log "Staged rollout: reset only [$($targetPhase.Name)] flag for post-reboot re-run." -Level Info
        } else {
            $state.WingetDone = $false; $state.ChocolateyDone = $false; $state.WindowsUpdateDone = $false
            $state.AwsToolingDone = $false; $state.PipDone = $false; $state.NpmDone = $false; $state.Office365Done = $false
            $state.PowerShellModulesDone = $false; $state.ScoopDone = $false; $state.DotnetToolsDone = $false; $state.VscodeDone = $false
        }
        $state.LastPhaseStarted = $null; $state.LastPhaseTimestamp = $null; $state.Phase = 'Rebooting'
        Set-BootUpdateState -State $state

        <# Guard task registration and reboot — neither must fire in WhatIf mode #>
        if (-not $WhatIfPreference) {
            Register-BootUpdateTaskForReboot
            Send-RebootWarning -SecondsUntilReboot $script:RebootDelaySec

            <# Notify operators that a reboot is imminent (best-effort; never throws) #>
            Send-WebhookNotification `
                -Title   "Boot Update Cycle: Rebooting ($env:COMPUTERNAME)" `
                -Message "Iteration $($state.Iteration) complete. Rebooting in $($script:RebootDelaySec)s to apply updates. Cycle will resume after boot." `
                -Data    @{}

            <# Console: styled reboot banner #>
            Show-CycleBanner -Title 'R E B O O T I N G . . .' -AnsiColor "$([char]27)[33m" -Info @(
                "Shutdown in $($script:RebootDelaySec) seconds"
                "Cancel:  shutdown /a"
                "Next run as SYSTEM (scheduled task)"
            )

            Suspend-BitLockerForReboot
            $shutdownComment = 'Boot Update Cycle: Applying updates (forced reboot).'
            Write-Log "Initiating forced shutdown /r /f /t $($script:RebootDelaySec)"
            if ($PSCmdlet.ShouldProcess('Windows', 'Restart computer')) {
                & shutdown.exe /r /f /t $script:RebootDelaySec /c "$shutdownComment" /d p:2:17
                Write-Log 'Shutdown scheduled. Exiting; will resume after reboot.'
                exit 0
            }
        } else {
            Write-Log '  [WHATIF] Would register scheduled task and restart computer'
        }
    } else {
        <# No pending reboot. #>

        if ($script:StagedRollout) {
            <# Staged mode: check whether any enabled phases remain undone.
               If yes, stay registered and exit clean — next boot picks up the next phase.
               If no, fall through to normal cycle-complete cleanup. #>
            $remainingPhases = @($allPhases | Where-Object { (-not $_.Skip) -and (-not [bool]$state.($_.Flag)) })
            if ($remainingPhases.Count -gt 0) {
                $nextPhase = $remainingPhases[0]
                $state.StagedNextPhase = $nextPhase.Name
                Set-BootUpdateState -State $state
                Write-Log "Staged rollout: $($remainingPhases.Count) phase(s) remaining. Next boot will run [$($nextPhase.Name)]. Task stays registered." -Level Info
                Write-Log "  Remaining: $(($remainingPhases | ForEach-Object { $_.Name }) -join ', ')"
                if (-not $WhatIfPreference) { Register-BootUpdateTaskForReboot }
                return  <# Cycle not complete — exit without cleanup #>
            }
            Write-Log 'Staged rollout: all phases complete, no pending reboots — cycle done.' -Level Info
        }

        if ($WhatIfPreference) { Write-Log '[WHATIF] Pending reboot check skipped — reporting clean (no actual updates ran)' }
        $duration = if ($state.StartTime) { (Get-Date) - [datetime]$state.StartTime } else { [timespan]::Zero }
        $s = $state.Summary
        $total = $s.Winget + $s.Chocolatey + $s.WindowsUpdate + $s.Pip + $s.Npm + $s.Office365 + $s.PowerShellModules + $s.Scoop + $s.DotnetTools + $s.Vscode
        $reboots = $state.Iteration - 1
        $durMin = [math]::Round($duration.TotalMinutes, 1)
        $pkgLine = "Winget=$($s.Winget) Choco=$($s.Chocolatey) WU=$($s.WindowsUpdate) Pip=$($s.Pip) Npm=$($s.Npm) O365=$($s.Office365) PSMod=$($s.PowerShellModules) Scoop=$($s.Scoop) Dotnet=$($s.DotnetTools) VSCode=$($s.Vscode)"

        <# Console: styled completion banner #>
        $completionTitle = if ($WhatIfPreference) { 'W H A T I F   C H E C K   C O M P L E T E' } else { 'M I S S I O N   C O M P L E T E' }
        Show-CycleBanner -Title $completionTitle -AnsiColor "$([char]27)[32m" -Info @(
            "$durMin min | $($state.Iteration) iteration(s) | $reboots reboot(s)"
            "$total packages updated"
            $pkgLine
            if ($WhatIfPreference) { 'WHATIF MODE - No actual changes were made' } else { 'FULLY PATCHED - No pending reboots' }
        )
        <# Log file: structured entries #>
        Write-Log "BOOT UPDATE CYCLE${whatIfTag} COMPLETE | $durMin min | $($state.Iteration) iteration(s) | $reboots reboot(s) | $total packages"
        Write-Log "  $pkgLine"
        Write-Log "Info: View trends with: Show-BootUpdateHistory.ps1 -Format Graph"

        Save-CycleHistory -State $state -Duration $duration
        if (-not $WhatIfPreference) {
            <# Build enriched summary data: per-manager counts + scalar metrics for webhook/email #>
            $summaryData = [pscustomobject]@{
                Winget           = $s.Winget
                Chocolatey       = $s.Chocolatey
                WindowsUpdate    = $s.WindowsUpdate
                Pip              = $s.Pip
                Npm              = $s.Npm
                Office365        = $s.Office365
                PowerShellModules = $s.PowerShellModules
                Scoop            = $s.Scoop
                DotnetTools      = $s.DotnetTools
                Vscode           = $s.Vscode
                _total           = $total
                _iterations      = $state.Iteration
                _durMin          = $durMin
            }
            Send-CompletionNotification -Title 'Boot Update Cycle Complete' -Message "$total packages updated in $($state.Iteration) iteration(s), $durMin min" -Data $summaryData
            Unregister-BootUpdateTask
            Clear-BootUpdateState
        }
    }
}
#endregion

<# Entry point #>
if ($Force) { $ConfirmPreference = 'None' }

<# Named-mutex guard — prevents two instances racing on a fast boot (9ls).
   AbandonedMutexException means the prior owner crashed without releasing; we inherit ownership. #>
try {
    $script:BootUpdateMutex = [System.Threading.Mutex]::new($false, 'Global\BootUpdateCycle')
    $acquired = $false
    try {
        $acquired = $script:BootUpdateMutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        Write-Log 'Named mutex was abandoned (previous instance exited uncleanly). Claiming ownership.' -Level Warn
        $acquired = $true
    }
    if (-not $acquired) {
        Write-Log 'Another BootUpdateCycle instance is already running (mutex held). Exiting.' -Level Warn
        $script:BootUpdateMutex.Dispose()
        $script:BootUpdateMutex = $null
        exit 0
    }
} catch {
    Write-Log "Named mutex acquisition failed (non-fatal): $_" -Level Warn
    $script:BootUpdateMutex = $null
}

<# Release mutex on any exit path, including exit 0/1 inside the function #>
Register-EngineEvent -SourceIdentifier 'PowerShell.Exiting' -Action {
    if ($script:BootUpdateMutex) {
        try { $script:BootUpdateMutex.ReleaseMutex() } catch { }
        $script:BootUpdateMutex.Dispose()
        $script:BootUpdateMutex = $null
    }
} | Out-Null

Invoke-BootUpdateCycle

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
    Seconds before reboot.  Users can abort with: shutdown /a.  Default 120.

.PARAMETER Force
    Skip confirmation prompts and override pre-flight warnings.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [int]$MaxIterations = 5,
    [int]$PackageTimeoutMinutes = 30,
    [int]$RebootDelaySec = 120,
    [switch]$SkipPip,
    [switch]$SkipNpm,
    [switch]$SkipOffice365,
    [switch]$SkipAwsTooling,
    [switch]$SkipPowerShellModules,
    [switch]$SkipScoop,
    [switch]$SkipDotnetTools,
    [switch]$SkipVscode,
    [switch]$Force
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
Set-Variable -Name 'BootUpdateStateSchemaVersion' -Value 2 -Option ReadOnly -Scope Script -ErrorAction SilentlyContinue

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
        }
    }
}

function Update-BootUpdateStateSchema {
    param([Parameter(Mandatory)][pscustomobject]$State)
    $props = $State.PSObject.Properties.Name
    $ver = if ($props -contains 'StateVersion') { [int]$State.StateVersion } else { 1 }

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
    foreach ($f in @('LastPhaseStarted','LastPhaseTimestamp')) {
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
        }
    } elseif ($State.Summary -is [hashtable]) {
        $ht = $State.Summary
        $State.Summary = [pscustomobject]@{
            Winget = [int]($ht['Winget'] ?? 0); Chocolatey = [int]($ht['Chocolatey'] ?? 0)
            WindowsUpdate = [int]($ht['WindowsUpdate'] ?? 0); Pip = [int]($ht['Pip'] ?? 0)
            Npm = [int]($ht['Npm'] ?? 0); Office365 = [int]($ht['Office365'] ?? 0)
            PowerShellModules = [int]($ht['PowerShellModules'] ?? 0); Scoop = [int]($ht['Scoop'] ?? 0)
            DotnetTools = [int]($ht['DotnetTools'] ?? 0); Vscode = [int]($ht['Vscode'] ?? 0)
        }
    } else {
        $sp = $State.Summary.PSObject.Properties.Name
        foreach ($k in @('PowerShellModules','Scoop','DotnetTools','Vscode')) {
            if ($sp -notcontains $k) { $State.Summary | Add-Member -NotePropertyName $k -NotePropertyValue 0 -Force }
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
    $State.LastRun = (Get-Date).ToUniversalTime().ToString('o')
    $tmpPath = $script:StatePath + '.tmp'
    try {
        $json = $State | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($tmpPath, $json, [System.Text.Encoding]::UTF8)
        Move-Item -Path $tmpPath -Destination $script:StatePath -Force -ErrorAction Stop
    } catch {
        Write-Log "Failed to write state: $_" -Level Error
        if (Test-Path $tmpPath) { Remove-Item $tmpPath -Force -EA SilentlyContinue }
        throw
    }
}

function Clear-BootUpdateState {
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
    $s = $State.Summary
    $entry = [pscustomobject]@{
        Timestamp = Get-Date -Format 'o'
        Iterations = $State.Iteration
        DurationMinutes = [math]::Round($Duration.TotalMinutes, 1)
        Winget = $s.Winget; Chocolatey = $s.Chocolatey; WindowsUpdate = $s.WindowsUpdate
        Pip = $s.Pip; Npm = $s.Npm; Office365 = $s.Office365
        PowerShellModules = $s.PowerShellModules; Scoop = $s.Scoop; DotnetTools = $s.DotnetTools; Vscode = $s.Vscode
        Total = $s.Winget + $s.Chocolatey + $s.WindowsUpdate + $s.Pip + $s.Npm + $s.Office365 + $s.PowerShellModules + $s.Scoop + $s.DotnetTools + $s.Vscode
    }
    $history = @()
    if (Test-Path $script:HistoryPath) { $history = @(Get-Content $script:HistoryPath -Raw | ConvertFrom-Json) }
    $history = @($entry) + $history | Select-Object -First $script:MaxHistoryEntries
    $history | ConvertTo-Json -Depth 5 | Set-Content $script:HistoryPath -Force
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

#region Pending Reboot Detection
function Test-PendingReboot {
    $tests = @(
        @{ Name = 'CBS'; Test = { Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing' -Name 'RebootPending' -EA Ignore } },
        @{ Name = 'WU'; Test = { Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update' -Name 'RebootRequired' -EA Ignore } },
        @{ Name = 'FileRename'; Test = { Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -EA Ignore } },
        @{ Name = 'ComputerRename'; Test = {
            $r = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -EA Ignore
            $a = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -EA Ignore
            if ($r -and $a -and $r.ComputerName -ne $a.ComputerName) { $true } else { $null }
        }},
        @{ Name = 'JoinDomain'; Test = { Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon' -Name 'JoinDomain' -EA Ignore } }
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
        Write-Log "--- Winget ($scope): $count package(s) updated ---"
    }
    return @{ Success = (-not $anyTimeout); Count = $totalCount }
}

function Update-ChocolateyPackages {
    $choco = Get-Command choco -EA SilentlyContinue
    if (-not $choco) { Write-Log 'Chocolatey not found, skipping.' -Level Warn; return @{ Success = $true; Count = 0 } }
    Write-Log 'Updating Chocolatey packages...'
    $count = 0
    & choco upgrade all -y 2>&1 | ForEach-Object {
        if ($_ -match 'upgraded (\d+)/\d+ package') { $count = [int]$Matches[1] }
        Write-Log $_
    }
    return @{ Success = $true; Count = $count }
}

function Install-WindowsUpdates {
    if (-not (Get-Module -ListAvailable PSWindowsUpdate)) {
        Write-Log 'Installing PSWindowsUpdate module...'
        Install-Module PSWindowsUpdate -Force -Scope AllUsers -AllowClobber
    }
    Import-Module PSWindowsUpdate -Force
    Write-Log 'Checking for Windows Updates (excluding SQL Server)...'
    $params = @{
        AcceptAll = $true; Install = $true; NotTitle = 'SQL'
        RootCategories = @('Security Updates','Critical Updates','Definition Updates')
        AutoReboot = $false; Confirm = $false; IgnoreReboot = $true
    }
    $count = 0
    try {
        Get-WindowsUpdate @params -Verbose 4>&1 | ForEach-Object {
            if ($_ -match 'Installed|Downloaded') { $count++ }
            Write-Log $_.ToString()
        }
    } catch { Write-Log "Windows Update error: $_" -Level Error }
    return @{ Success = $true; Count = $count }
}

function Update-PipPackages {
    $pip = Get-Command pip -EA SilentlyContinue
    if (-not $pip) { Write-Log 'pip not found, skipping.' -Level Warn; return @{ Success = $true; Count = 0 } }
    Write-Log 'Updating pip packages...'
    & python -m pip install --upgrade pip 2>&1 | ForEach-Object { Write-Log $_ }
    $outdated = & pip list --outdated --format=json 2>$null | ConvertFrom-Json -EA SilentlyContinue
    $count = 0
    foreach ($pkg in $outdated) {
        Write-Log "Upgrading: $($pkg.name)"
        & pip install --upgrade $pkg.name 2>&1 | ForEach-Object { Write-Log $_ }
        $count++
    }
    return @{ Success = $true; Count = $count }
}

function Update-NpmPackages {
    $npm = Get-Command npm -EA SilentlyContinue
    if (-not $npm) { Write-Log 'npm not found, skipping.' -Level Warn; return @{ Success = $true; Count = 0 } }
    Write-Log 'Updating npm global packages...'
    $count = 0
    & npm update -g 2>&1 | ForEach-Object { if ($_ -match 'added|updated') { $count++ }; Write-Log $_ }
    return @{ Success = $true; Count = $count }
}

function Update-Office365 {
    $c2rClient = "${env:ProgramFiles}\Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe"
    if (-not (Test-Path $c2rClient)) { Write-Log 'Office 365 C2R not found, skipping.' -Level Warn; return @{ Success = $true; Count = 0 } }
    Write-Log 'Updating Office 365 (Click-to-Run)...'
    try {
        & $c2rClient /update user updatepromptuser=false forceappshutdown=true displaylevel=false 2>&1 | ForEach-Object { Write-Log $_ }
        Write-Log 'Office 365 update triggered (may complete in background)'
        return @{ Success = $true; Count = 1 }
    } catch { Write-Log "Office 365 error: $_" -Level Error; return @{ Success = $true; Count = 0 } }
}

function Update-PowerShellModules {
    Write-Log 'Checking installed PowerShell modules...'
    $installed = Get-InstalledModule -EA SilentlyContinue
    if (-not $installed) { Write-Log 'No user-installed modules found.' -Level Warn; return @{ Success = $true; Count = 0 } }
    $modules = $installed | Where-Object { $_.Name -notlike 'Microsoft.PowerShell.*' }
    if (-not $modules) { Write-Log 'Only built-in modules found.'; return @{ Success = $true; Count = 0 } }
    Write-Log "Found $(@($modules).Count) module(s) to check."
    $count = 0; $perModTimeout = [math]::Min($script:PackageTimeoutMinutes, 5)
    foreach ($mod in $modules) {
        $modName = $mod.Name; $curVer = $mod.Version
        Write-Log "Updating: $modName ($curVer)"
        try {
            $job = Start-Job -ScriptBlock { param($N) Update-Module -Name $N -Force -EA Stop 2>&1 } -ArgumentList $modName
            $done = $job | Wait-Job -Timeout ($perModTimeout * 60)
            if (-not $done) { Write-Log "TIMEOUT: $modName exceeded ${perModTimeout}m" -Level Warn; $job | Stop-Job -PassThru | Remove-Job -Force; continue }
            Receive-Job $job | ForEach-Object { Write-Log $_ }; Remove-Job $job -Force
            $newVer = (Get-InstalledModule -Name $modName -EA SilentlyContinue).Version
            if ($newVer -and ($newVer -gt $curVer)) { Write-Log "  ${modName}: $curVer -> $newVer"; $count++ }
            else { Write-Log "  ${modName}: already latest ($curVer)" }
        } catch {
            if ($_ -match 'already the latest') { Write-Log "  ${modName}: already latest" }
            else { Write-Log "  $modName error: $_" -Level Warn }
        }
    }
    Write-Log "PS module updates: $count updated."
    return @{ Success = $true; Count = $count }
}

function Update-ScoopPackages {
    $isSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
    if ($isSystem) { Write-Log 'Scoop skipped: SYSTEM context (user-scoped).' -Level Warn; return @{ Success = $true; Count = 0 } }
    $scoop = Get-Command scoop -EA SilentlyContinue
    if (-not $scoop) { Write-Log 'Scoop not found, skipping.' -Level Warn; return @{ Success = $true; Count = 0 } }
    Write-Log 'Updating Scoop...'
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
}

function Update-DotnetTools {
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
            try {
                $output = & dotnet tool update --global $tool 2>&1
                $output | ForEach-Object { Write-Log $_ }
                if ($output -match 'was successfully updated') { $count++ }
            } catch { Write-Log "  $tool error: $_" -Level Warn }
        }
        Write-Log "dotnet tools: $count updated."
        return @{ Success = $true; Count = $count }
    } catch { Write-Log "dotnet tools error: $_" -Level Error; return @{ Success = $true; Count = 0 } }
}

function Update-VscodeExtensions {
    $isSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
    if ($isSystem) { Write-Log 'VS Code skipped: SYSTEM context (per-user).' -Level Warn; return @{ Success = $true; Count = 0 } }
    $codeCmd = Get-Command code -EA SilentlyContinue
    if (-not $codeCmd) { $codeCmd = Get-Command code-insiders -EA SilentlyContinue }
    if (-not $codeCmd) { Write-Log 'VS Code not found, skipping.' -Level Warn; return @{ Success = $true; Count = 0 } }
    Write-Log "Updating VS Code extensions via: $($codeCmd.Name)"
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
}

function Repair-AwsTooling {
    $awsScript = Join-Path $PSScriptRoot 'Repair-AwsTooling.ps1'
    if (-not (Test-Path $awsScript)) { Write-Log 'Repair-AwsTooling.ps1 not found, skipping.' -Level Warn; return $true }
    Write-Log 'Repairing AWS tooling...'
    try { & $awsScript -Mode Remediate } catch { Write-Log "AWS error: $_" -Level Error }
    return $true
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
    if (Get-ScheduledTask -TaskName $taskName -EA SilentlyContinue) {
        Write-Log 'Scheduled task already registered (post-reboot iteration)'
        return
    }
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
    $argString = $taskArgs -join ' '
    $action   = New-ScheduledTaskAction -Execute $pwshPath -Argument $argString -WorkingDirectory $PSScriptRoot
    $trigger  = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 4)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Boot update loop: patches everything, reboots until clean.' -Force | Out-Null
    Write-Log "Scheduled task registered: $taskName (SYSTEM at startup)"
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

function Send-CompletionNotification {
    param([string]$Title, [string]$Message)
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
    <# BBS-inspired ANSI splash — shown on first iteration only.
       ░▒▓█ gradient borders, neon palette, interpunct separators.
       Evokes the ACiD/iCE era login screens of the early '90s.  #>
    $e = [char]27
    <# Neon BBS palette #>
    $cy = "$e[96m"; $bl = "$e[94m"; $mg = "$e[95m"
    $yl = "$e[93m"; $wh = "$e[97m"; $dk = "$e[90m"
    $B  = "$e[1m";  $r  = "$e[0m"

    $bar = "$dk░▒$bl▓$mg█$cy$B$('═' * 56)$r$mg█$bl▓$dk▒░$r"

    Write-Host ""
    Write-Host "  $bar"
    Write-Host ""
    Write-Host "  $cy$B    ██████╗  ██████╗  ██████╗ ████████╗$r"
    Write-Host "  $cy$B    ██╔══██╗██╔═══██╗██╔═══██╗╚══██╔══╝$r"
    Write-Host "  $cy$B    ██████╔╝██║   ██║██║   ██║   ██║$r"
    Write-Host "  $cy$B    ██╔══██╗██║   ██║██║   ██║   ██║$r"
    Write-Host "  $cy$B    ██████╔╝╚██████╔╝╚██████╔╝   ██║$r"
    Write-Host "  $cy$B    ╚═════╝  ╚═════╝  ╚═════╝    ╚═╝$r"
    Write-Host ""
    Write-Host "  $wh$B    U P D A T E $dk·$wh C Y C L E$r                     $dk v2.0$r"
    Write-Host ""
    Write-Host "  $bar"
    Write-Host ""
    Write-Host "  $yl    $dk·$yl Updating all the things so you don't have to. $dk·$r"
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
    $state.Iteration++
    $isFirstIteration = -not $state.StartTime
    if ($isFirstIteration) { $state.StartTime = Get-Date -Format 'o' }
    Set-BootUpdateState -State $state

    $sessionId = ([datetime]$state.StartTime).ToString('yyyy-MM-dd HH:mm:ss')
    $cycleVerb = if ($isFirstIteration) { 'STARTED' } else { 'RESUMED (after reboot)' }
    $context = if (([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value) -eq 'S-1-5-18') { 'SYSTEM (scheduled task)' } else { "$env:USERNAME (user context)" }

    <# Console: BBS splash on first boot, lean banner on reboots #>
    if ($isFirstIteration) { Show-StartupArt }
    Show-CycleBanner -Title 'B O O T   U P D A T E   C Y C L E                           v2.0' `
        -AnsiColor "$([char]27)[36m" -Info @(
            "$cycleVerb"
            "Session:    $sessionId"
            "Iteration:  $($state.Iteration) of $MaxIterations"
            "Context:    $context"
        )
    <# Log file: clean greppable entry #>
    Write-Log "BOOT UPDATE CYCLE $cycleVerb | Session: $sessionId | Iteration: $($state.Iteration)/$MaxIterations | Context: $context"

    <# Event Log: cycle started #>
    Write-EventLogEntry -EventId 1002 -Message "Boot Update Cycle $cycleVerb`nSession: $sessionId`nIteration: $($state.Iteration) of $MaxIterations"

    <# Pre-flight checks (every iteration — disk/network can change between reboots) #>
    $preflight = Test-PreFlightChecks -Force:$Force
    if (-not $preflight.CanProceed) {
        Write-Log 'Update cycle aborted by pre-flight checks.' -Level Error
        Write-EventLogEntry -EventId 1003 -EntryType Error -Message "Cycle aborted by pre-flight checks.`nErrors: $($preflight.Errors -join '; ')"
        Unregister-BootUpdateTask; Clear-BootUpdateState
        exit 1
    }

    <# Max iterations safety valve #>
    if ($state.Iteration -gt $MaxIterations) {
        Write-Log "Max iterations ($MaxIterations) exceeded. Stopping." -Level Error
        Write-EventLogEntry -EventId 1003 -EntryType Error -Message "Cycle stopped: exceeded $MaxIterations iterations.`nSession: $sessionId"
        Unregister-BootUpdateTask; Clear-BootUpdateState
        return
    }

    <# Crash recovery #>
    $null = Test-CrashRecovery -State $state

    $pending = Test-PendingReboot
    if ($pending) { $pending | ForEach-Object { Write-Log "Pending reboot: $($_.Source)" -Level Warn } }
    else { Write-Log 'No pending reboots at start of iteration' }

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

    foreach ($phase in $allPhases) {
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

        <# Crash-recovery markers: write intent before execution #>
        $state.LastPhaseStarted = $phase.Name; $state.LastPhaseTimestamp = Get-Date -Format 'o'; $state.Phase = $phase.Name
        Set-BootUpdateState -State $state

        try {
            $r = & $phase.Action
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
    }

    <# ---- Post-update reboot decision ---- #>
    $pending = Test-PendingReboot
    if ($pending) {
        Write-Log 'Pending reboot after updates: YES' -Level Warn
        $pending | ForEach-Object { Write-Log "  - $($_.Source)" -Level Warn }

        <# Reset all phase flags for next iteration #>
        $state.WingetDone = $false; $state.ChocolateyDone = $false; $state.WindowsUpdateDone = $false
        $state.AwsToolingDone = $false; $state.PipDone = $false; $state.NpmDone = $false; $state.Office365Done = $false
        $state.PowerShellModulesDone = $false; $state.ScoopDone = $false; $state.DotnetToolsDone = $false; $state.VscodeDone = $false
        $state.LastPhaseStarted = $null; $state.LastPhaseTimestamp = $null; $state.Phase = 'Rebooting'
        Set-BootUpdateState -State $state

        Register-BootUpdateTaskForReboot
        Send-RebootWarning -SecondsUntilReboot $script:RebootDelaySec

        <# Console: styled reboot banner #>
        Show-CycleBanner -Title 'R E B O O T I N G . . .' -AnsiColor "$([char]27)[33m" -Info @(
            "Shutdown in $($script:RebootDelaySec) seconds"
            "Cancel:  shutdown /a"
            "Next run as SYSTEM (scheduled task)"
        )

        $shutdownComment = 'Boot Update Cycle: Applying updates. Run "shutdown /a" to cancel.'
        Write-Log "Initiating shutdown /r /t $($script:RebootDelaySec) | Cancel: shutdown /a"
        & shutdown.exe /r /t $script:RebootDelaySec /c $shutdownComment /d p:2:17
        Write-Log 'Shutdown scheduled. Exiting; will resume after reboot.'
        exit 0
    } else {
        $duration = if ($state.StartTime) { (Get-Date) - [datetime]$state.StartTime } else { [timespan]::Zero }
        $s = $state.Summary
        $total = $s.Winget + $s.Chocolatey + $s.WindowsUpdate + $s.Pip + $s.Npm + $s.Office365 + $s.PowerShellModules + $s.Scoop + $s.DotnetTools + $s.Vscode
        $reboots = $state.Iteration - 1
        $durMin = [math]::Round($duration.TotalMinutes, 1)
        $pkgLine = "Winget=$($s.Winget) Choco=$($s.Chocolatey) WU=$($s.WindowsUpdate) Pip=$($s.Pip) Npm=$($s.Npm) O365=$($s.Office365) PSMod=$($s.PowerShellModules) Scoop=$($s.Scoop) Dotnet=$($s.DotnetTools) VSCode=$($s.Vscode)"

        <# Console: styled completion banner #>
        Show-CycleBanner -Title 'M I S S I O N   C O M P L E T E' -AnsiColor "$([char]27)[32m" -Info @(
            "$durMin min | $($state.Iteration) iteration(s) | $reboots reboot(s)"
            "$total packages updated"
            $pkgLine
            "FULLY PATCHED - No pending reboots"
        )
        <# Log file: structured entries #>
        Write-Log "BOOT UPDATE CYCLE COMPLETE | $durMin min | $($state.Iteration) iteration(s) | $reboots reboot(s) | $total packages"
        Write-Log "  $pkgLine"

        Save-CycleHistory -State $state -Duration $duration
        Send-CompletionNotification -Title 'Boot Update Cycle Complete' -Message "$total packages updated in $($state.Iteration) iteration(s), $durMin min"
        Unregister-BootUpdateTask
        Clear-BootUpdateState
    }
}
#endregion

<# Entry point #>
if ($Force) { $ConfirmPreference = 'None' }
Invoke-BootUpdateCycle

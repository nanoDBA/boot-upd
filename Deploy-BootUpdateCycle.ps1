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
    SkipRestorePoint      = $true   # Skip system restore point creation (opt-in: set $false to enable)
    SkipHealthCheck       = $false  # Skip post-update health check for critical services
    StagedRollout         = $false  # Run one package manager per boot instead of all at once. Slower but safer.
    MaxIterations         = 5       # Safety valve for reboot loops
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

    <# NOTIFICATIONS - leave empty to disable #>
    WebhookUrl            = ''     # Teams/Slack/Discord webhook URL (leave empty to disable)
    NotifyEmail           = ''     # Recipient email (leave empty to disable)
    SmtpServer            = ''     # SMTP relay hostname (e.g., smtp.office365.com)

    <# MAINTENANCE WINDOW - leave -1 to run at any time #>
    MaintenanceWindowStart = -1   # Hour of day (0-23) when updates may start. -1 = no restriction. e.g., 2 = start at 2 AM
    MaintenanceWindowEnd   = -1   # Hour of day when updates must stop. -1 = no restriction. Supports midnight-crossing: Start=22, End=2 = 10 PM to 2 AM

    # Package name patterns to skip (substring match, case-insensitive). e.g. @('Teams', 'OneDrive')
    ExcludePatterns        = @()
}

# Apply command-line parameter overrides
if ($PSBoundParameters.ContainsKey('RebootDelaySec')) { $Config.RebootDelaySec = $RebootDelaySec }
if ($NonInteractive) { $Config.NonInteractive = $true }
#endregion

#region Validation
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7+ required. Current: $($PSVersionTable.PSVersion)"
}
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run as Administrator."
}
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
#endregion

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
if (-not (Test-Path $installDir)) {
    New-Item -Path $installDir -ItemType Directory -Force | Out-Null
    Write-Host "Created: $installDir"
}

<# Deploy Invoke script from source directory (no more embedded here-string duplication) #>
$sourceInvoke = Join-Path $PSScriptRoot 'Invoke-BootUpdateCycle.ps1'
if (-not (Test-Path $sourceInvoke)) {
    throw "Source script not found: $sourceInvoke  (Deploy and Invoke must be in the same directory)"
}
$scriptPath = Join-Path $installDir 'Invoke-BootUpdateCycle.ps1'
Copy-Item $sourceInvoke $scriptPath -Force
Write-Host "Deployed: $scriptPath"

<# Also copy companion scripts if present #>
foreach ($companion in @('Repair-AwsTooling.ps1')) {
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
<# Uninstall: stops task, removes task. Use -RemoveFolder to also delete logs/history. #>
$taskName = 'BootUpdateCycle'
$task = Get-ScheduledTask -TaskName $taskName -EA SilentlyContinue
if ($task) {
    if ($task.State -eq 'Running') { Stop-ScheduledTask -TaskName $taskName; Write-Host "Task stopped." }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Task '$taskName' removed." -ForegroundColor Green
} else {
    Write-Host "Task '$taskName' not found." -ForegroundColor Yellow
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

<# Stop and remove existing task from previous runs #>
$existingTask = Get-ScheduledTask -TaskName $taskName -EA SilentlyContinue
if ($existingTask) {
    if ($existingTask.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $taskName
        Write-Host "Stopped running task: $taskName" -ForegroundColor Yellow
        Start-Sleep -Seconds 2
    }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Removed existing task: $taskName"
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
    PackageTimeoutMinutes = $Config.PackageTimeoutMin
    RebootDelaySec       = $Config.RebootDelaySec
    SkipPip              = $Config.SkipPip
    SkipNpm              = $Config.SkipNpm
    SkipOffice365        = $Config.SkipOffice365
    SkipAwsTooling       = $Config.SkipAwsTooling
    SkipPowerShellModules = $Config.SkipPowerShellModules
    SkipScoop            = $Config.SkipScoop
    SkipDotnetTools      = $Config.SkipDotnetTools
    SkipVscode           = $Config.SkipVscode
    SkipRestorePoint     = $Config.SkipRestorePoint
    SkipHealthCheck      = $Config.SkipHealthCheck
    StagedRollout        = $Config.StagedRollout
    WebhookUrl              = $Config.WebhookUrl
    NotifyEmail             = $Config.NotifyEmail
    SmtpServer              = $Config.SmtpServer
    MaintenanceWindowStart  = $Config.MaintenanceWindowStart
    MaintenanceWindowEnd    = $Config.MaintenanceWindowEnd
    ExcludePatterns         = $Config.ExcludePatterns
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
        "-PackageTimeoutMinutes $($Config.PackageTimeoutMin)"
        "-RebootDelaySec $($Config.RebootDelaySec)"
    )
    if ($Config.SkipPip)              { $taskArgs += '-SkipPip' }
    if ($Config.SkipNpm)              { $taskArgs += '-SkipNpm' }
    if ($Config.SkipOffice365)        { $taskArgs += '-SkipOffice365' }
    if ($Config.SkipAwsTooling)       { $taskArgs += '-SkipAwsTooling' }
    if ($Config.SkipPowerShellModules){ $taskArgs += '-SkipPowerShellModules' }
    if ($Config.SkipScoop)            { $taskArgs += '-SkipScoop' }
    if ($Config.SkipDotnetTools)      { $taskArgs += '-SkipDotnetTools' }
    if ($Config.SkipVscode)           { $taskArgs += '-SkipVscode' }
    if ($Config.SkipRestorePoint)     { $taskArgs += '-SkipRestorePoint' }
    if ($Config.StagedRollout)        { $taskArgs += '-StagedRollout' }
    if ($Config.WebhookUrl)           { $taskArgs += "-WebhookUrl `"$($Config.WebhookUrl)`"" }
    if ($Config.NotifyEmail)          { $taskArgs += "-NotifyEmail `"$($Config.NotifyEmail)`"" }
    if ($Config.SmtpServer)           { $taskArgs += "-SmtpServer `"$($Config.SmtpServer)`"" }
    if ($Config.ExcludePatterns.Count -gt 0) {
        $patternStr = ($Config.ExcludePatterns | ForEach-Object { "'$_'" }) -join ','
        $taskArgs += "-ExcludePatterns @($patternStr)"
    }

    $argString = $taskArgs -join ' '
    $action   = New-ScheduledTaskAction -Execute $pwshPath -Argument $argString -WorkingDirectory $installDir
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 4)

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
        -Description 'Boot update loop: patches everything, reboots until clean.' -Force | Out-Null
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
            & $scriptPath @invokeArgs
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
            & $scriptPath @invokeArgs
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

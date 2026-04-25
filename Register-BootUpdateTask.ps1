#requires -Version 7.0
#requires -RunAsAdministrator
# ------------------------------------------------------------------------------
# File:        Register-BootUpdateTask.ps1
# Description: 📋 Creates scheduled task for boot-time update cycle
# Purpose:     Registers a Windows scheduled task that runs at system startup
#              (before user logon) with SYSTEM privileges.  Configures the task
#              with retry logic, battery settings, and execution time limits.
#              Pair with Unregister-BootUpdateTask.ps1 for cleanup.
# Created:     2025-01-10
# Modified:    2025-01-10
# ------------------------------------------------------------------------------
<#
.SYNOPSIS
    Sets up the scheduled task that kicks off auto-patching at every boot.

.DESCRIPTION
    Creates a Windows scheduled task that fires before anyone logs in and
    keeps your machine in "patch until clean" mode.  The task:
    - Runs at system startup (before user logon) as SYSTEM
    - Has retry logic if it fails to start
    - Won't drain your laptop battery (respects power settings)
    - Times out after 4 hours (safety net for hung updates)
    
    Use -StartNow to immediately begin patching after registration.

.PARAMETER TaskName
    Name for the scheduled task. Default: 'BootUpdateCycle'

.PARAMETER SkipPip
    Pass -SkipPip to the update script (skip pip package updates).

.PARAMETER SkipNpm
    Pass -SkipNpm to the update script (skip npm global package updates).

.PARAMETER SkipOffice365
    Pass -SkipOffice365 to the update script (skip Office 365 C2R updates).

.PARAMETER SkipAwsTooling
    Pass -SkipAwsTooling to the update script (skip AWS CLI/module repair).

.PARAMETER MaxIterations
    Maximum reboot cycles. Default: 5

.PARAMETER PackageTimeoutMinutes
    Minutes to wait for a package manager before killing it.  Default: 30.
    Increase for large installs (VS, SQL, Office).

.PARAMETER RebootDelaySec
    Seconds before reboot after updates require restart.  Default: 120.
    Users see native Windows shutdown dialog and can abort with: shutdown /a

.PARAMETER StartNow
    Also run the update cycle immediately after registration.

.EXAMPLE
    .\Register-BootUpdateTask.ps1
    Registers the task with default settings.

.EXAMPLE
    .\Register-BootUpdateTask.ps1 -SkipPip -SkipNpm -StartNow
    Registers with pip/npm updates disabled and starts immediately.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TaskName = 'BootUpdateCycle',
    [switch]$SkipPip,
    [switch]$SkipNpm,
    [switch]$SkipOffice365,
    [switch]$SkipAwsTooling,
    [int]$MaxIterations = 5,
    [int]$PackageTimeoutMinutes = 30,
    [int]$RebootDelaySec = 120,
    [switch]$StartNow
)

$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Invoke-BootUpdateCycle.ps1'
if (-not (Test-Path $scriptPath)) {
    throw "Invoke-BootUpdateCycle.ps1 not found at: $scriptPath"
}

<# Build argument list for the scheduled task #>
$arguments = @(
    '-NoProfile'
    '-ExecutionPolicy Bypass'
    "-File `"$scriptPath`""
    '-Force'
    "-MaxIterations $MaxIterations"
    "-PackageTimeoutMinutes $PackageTimeoutMinutes"
    "-RebootDelaySec $RebootDelaySec"
)

if ($SkipPip)         { $arguments += '-SkipPip' }
if ($SkipNpm)         { $arguments += '-SkipNpm' }
if ($SkipOffice365)   { $arguments += '-SkipOffice365' }
if ($SkipAwsTooling)  { $arguments += '-SkipAwsTooling' }

$argString = $arguments -join ' '

<# Find pwsh.exe (PowerShell 7+) #>
$pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwshPath) {
    $pwshPath = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
}
if (-not (Test-Path $pwshPath)) {
    throw "PowerShell 7 (pwsh.exe) not found. Install PowerShell 7+ first."
}

Write-Host "Task Name   : $TaskName"
Write-Host "Script      : $scriptPath"
Write-Host "PowerShell  : $pwshPath"
Write-Host "Arguments   : $argString"

if ($PSCmdlet.ShouldProcess($TaskName, 'Register scheduled task')) {
    <# Remove existing task if present #>
    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-Host "Removing existing task '$TaskName'..."
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    <# Create task components #>
    $action = New-ScheduledTaskAction -Execute $pwshPath -Argument $argString -WorkingDirectory $PSScriptRoot

    <# Trigger at startup - runs before user logon #>
    $trigger = New-ScheduledTaskTrigger -AtStartup

    <# Run as SYSTEM with highest privileges #>
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    <# Settings: allow running on battery, don't stop on idle, etc. #>
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)

    <# Register the task #>
    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description 'Runs package manager updates and Windows patches in a loop until no pending reboots remain.' `
        -Force

    Write-Host "`nScheduled task '$TaskName' registered successfully." -ForegroundColor Green
    Write-Host "The task will run automatically at next system startup."

    if ($StartNow) {
        Write-Host "`nStarting update cycle now..."
        Start-ScheduledTask -TaskName $TaskName
    }
}

#requires -Version 7.0
#requires -RunAsAdministrator
# ------------------------------------------------------------------------------
# File:        Unregister-BootUpdateTask.ps1
# Description: 🧹 Removes boot update scheduled task and optional cleanup
# Purpose:     Emergency stop or cleanup utility for the boot update cycle.
#              Stops any running task, removes the scheduled task registration,
#              and optionally deletes log/state files.  Safe to run anytime.
# Created:     2025-01-10
# Modified:    2025-01-10
# ------------------------------------------------------------------------------
<#
.SYNOPSIS
    Emergency stop — kills the auto-patching loop and cleans up.

.DESCRIPTION
    Pull the plug on the update/reboot cycle.  Use this when:
    - Something went wrong and you need to abort
    - The cycle completed but you want to remove leftover files
    - You changed your mind and don't want auto-patching anymore
    
    Safe to run even if nothing is running — it just cleans up whatever exists.

.PARAMETER TaskName
    Scheduled tasks to remove. Default: both continuation tasks, 'BootUpdateCycle' and
    'BootUpdateCycleFallback'. Removing only the first leaves the SYSTEM fallback, which
    resumes the cycle at the next boot or watchdog probe.

.PARAMETER CleanupLogs
    Also remove log and state files.

.EXAMPLE
    .\Unregister-BootUpdateTask.ps1
    Removes both scheduled tasks only.

.EXAMPLE
    .\Unregister-BootUpdateTask.ps1 -CleanupLogs
    Removes task and all related files.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$TaskName = @('BootUpdateCycle', 'BootUpdateCycleFallback'),
    [switch]$CleanupLogs
)

$ErrorActionPreference = 'Stop'

foreach ($name in $TaskName) {
    $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue

    if ($task) {
        if ($task.State -eq 'Running') {
            Write-Host "Stopping running task '$name'..."
            if ($PSCmdlet.ShouldProcess($name, 'Stop scheduled task')) {
                Stop-ScheduledTask -TaskName $name
            }
        }

        Write-Host "Removing scheduled task '$name'..."
        if ($PSCmdlet.ShouldProcess($name, 'Unregister scheduled task')) {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
            Write-Host "Task '$name' removed." -ForegroundColor Green
        }
    }
    else {
        Write-Host "Task '$name' not found." -ForegroundColor Yellow
    }
}

if ($CleanupLogs) {
    $filesToRemove = @(
        (Join-Path $PSScriptRoot 'BootUpdateCycle.log'),
        (Join-Path $PSScriptRoot 'BootUpdateCycle.state.json')
    )

    foreach ($file in $filesToRemove) {
        if (Test-Path $file) {
            if ($PSCmdlet.ShouldProcess($file, 'Remove file')) {
                Remove-Item $file -Force
                Write-Host "Removed: $file"
            }
        }
    }
}

Write-Host "`nCleanup complete."

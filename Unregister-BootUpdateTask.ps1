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
    Name of the scheduled task to remove. Default: 'BootUpdateCycle'

.PARAMETER CleanupLogs
    Also remove log and state files.

.EXAMPLE
    .\Unregister-BootUpdateTask.ps1
    Removes the scheduled task only.

.EXAMPLE
    .\Unregister-BootUpdateTask.ps1 -CleanupLogs
    Removes task and all related files.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TaskName = 'BootUpdateCycle',
    [switch]$CleanupLogs
)

$ErrorActionPreference = 'Stop'

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

if ($task) {
    if ($task.State -eq 'Running') {
        Write-Host "Stopping running task '$TaskName'..."
        if ($PSCmdlet.ShouldProcess($TaskName, 'Stop scheduled task')) {
            Stop-ScheduledTask -TaskName $TaskName
        }
    }

    Write-Host "Removing scheduled task '$TaskName'..."
    if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister scheduled task')) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Task '$TaskName' removed." -ForegroundColor Green
    }
}
else {
    Write-Host "Task '$TaskName' not found." -ForegroundColor Yellow
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

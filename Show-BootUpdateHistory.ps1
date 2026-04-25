#requires -Version 7.0
# ------------------------------------------------------------------------------
# File:        Show-BootUpdateHistory.ps1
# Description: Read-only trend viewer for boot update cycle history
# Purpose:     Renders the last N entries from BootUpdateCycle.history.json
#              as a table, ASCII bar chart, or raw JSON.  No elevation needed.
# Created:     2026-04-25
# ------------------------------------------------------------------------------
<#
.SYNOPSIS
    Displays historical trends from the boot update cycle.

.DESCRIPTION
    Reads the BootUpdateCycle history file written by Invoke-BootUpdateCycle.ps1
    and renders it in your choice of format.  Entirely read-only; requires no
    elevation and makes zero writes to disk.

.PARAMETER Last
    Number of history entries to display.  Default 10, maximum 50.

.PARAMETER Format
    Output format.
    Table  - formatted table with top-3 package managers per run  (default)
    Graph  - ASCII bar chart scaled to the current window's max value
    Json   - raw JSON passthrough for piping to other tools

.EXAMPLE
    .\Show-BootUpdateHistory.ps1
    Shows the last 10 cycles as a table.

.EXAMPLE
    .\Show-BootUpdateHistory.ps1 -Format Graph -Last 5
    Renders a bar chart for the most recent 5 cycles.

.EXAMPLE
    .\Show-BootUpdateHistory.ps1 -Format Json | ConvertFrom-Json
    Round-trips the history through JSON for scripted consumption.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 50)]
    [int]$Last = 10,

    [ValidateSet('Table', 'Graph', 'Json')]
    [string]$Format = 'Table'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Resolve history file path.  The orchestrator writes to ProgramData when
# running as SYSTEM via scheduled task; fall back to the script's own dir
# for development runs where both files live side-by-side.
# ---------------------------------------------------------------------------
$defaultPath  = Join-Path $env:ProgramData 'BootUpdateCycle\BootUpdateCycle.history.json'
$siblingPath  = Join-Path $PSScriptRoot      'BootUpdateCycle.history.json'
$historyPath  = if (Test-Path $defaultPath) { $defaultPath }
               elseif (Test-Path $siblingPath) { $siblingPath }
               else { $defaultPath }   # keep canonical path for the error message

# ---------------------------------------------------------------------------
# Load history
# ---------------------------------------------------------------------------
if (-not (Test-Path $historyPath)) {
    Write-Host "No update history found at $historyPath"
    exit 0
}

$raw = $null
try {
    $raw = Get-Content $historyPath -Raw -ErrorAction Stop
}
catch {
    Write-Host "Error reading history file: $_"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($raw)) {
    Write-Host "No update history found at $historyPath"
    exit 0
}

$allEntries = $null
try {
    $allEntries = @($raw | ConvertFrom-Json)
}
catch {
    Write-Host "Error parsing history file: $_"
    exit 1
}

if ($allEntries.Count -eq 0) {
    Write-Host "No update history found at $historyPath"
    exit 0
}

# History is stored newest-first (prepend pattern in Save-CycleHistory).
# Select-Object -First $Last already gives us newest-first order.
$entries = @($allEntries | Select-Object -First $Last)

# ---------------------------------------------------------------------------
# Helper: parse ISO timestamp to a display string
# ---------------------------------------------------------------------------
function Format-Timestamp {
    param([string]$Iso)
    try {
        return ([datetime]$Iso).ToString('yyyy-MM-dd HH:mm')
    }
    catch {
        return $Iso
    }
}

# ---------------------------------------------------------------------------
# Helper: build "top-3 managers" summary string for Table mode
# ---------------------------------------------------------------------------
function Get-TopManagers {
    param([pscustomobject]$Entry)

    $managers = [ordered]@{
        Winget           = $Entry.Winget
        Chocolatey       = $Entry.Chocolatey
        'Windows Update' = $Entry.WindowsUpdate
        Pip              = $Entry.Pip
        Npm              = $Entry.Npm
        Office365        = $Entry.Office365
        PSModules        = $Entry.PowerShellModules
        Scoop            = $Entry.Scoop
        DotnetTools      = $Entry.DotnetTools
        VSCode           = $Entry.Vscode
    }

    $top3 = $managers.GetEnumerator() |
        Where-Object { $_.Value -gt 0 } |
        Sort-Object  Value -Descending |
        Select-Object -First 3

    if (-not $top3) { return '(none)' }

    return ($top3 | ForEach-Object { "$($_.Key)($($_.Value))" }) -join ', '
}

# ===========================================================================
# FORMAT: Json
# ===========================================================================
if ($Format -eq 'Json') {
    $entries | ConvertTo-Json -Depth 5
    exit 0
}

# ===========================================================================
# FORMAT: Table
# ===========================================================================
if ($Format -eq 'Table') {
    $rows = $entries | ForEach-Object {
        [pscustomobject]@{
            Timestamp      = Format-Timestamp $_.Timestamp
            Iterations     = $_.Iterations
            'Duration(min)'= $_.DurationMinutes
            TotalPackages  = $_.Total
            TopManagers    = Get-TopManagers $_
        }
    }
    $rows | Format-Table -AutoSize
    exit 0
}

# ===========================================================================
# FORMAT: Graph  (ASCII bar chart, newest at top)
# ===========================================================================

# ANSI support: PowerShell 7+ on a real terminal
$useAnsi = $PSVersionTable.PSVersion.Major -ge 7 -and
           $Host.UI.RawUI -ne $null -and
           [System.Console]::IsOutputRedirected -eq $false

$ESC   = [char]27
$RESET = "$ESC[0m"

function Get-AnsiColor {
    param([int]$Value, [int]$Max)
    if (-not $useAnsi -or $Max -eq 0) { return '' }
    $ratio = $Value / $Max
    return switch ($true) {
        ($ratio -le 0.33) { "$ESC[32m" }   # green  - low
        ($ratio -le 0.66) { "$ESC[33m" }   # yellow - medium
        default           { "$ESC[31m" }   # red    - high
    }
}

$maxTotal = ($entries | Measure-Object -Property Total -Maximum).Maximum
if ($maxTotal -eq $null -or $maxTotal -eq 0) { $maxTotal = 1 }

$barMaxWidth = 40   # character width for the longest bar

Write-Host ''

foreach ($entry in $entries) {
    $label   = Format-Timestamp $entry.Timestamp
    $total   = [int]$entry.Total
    $barLen  = [math]::Round(($total / $maxTotal) * $barMaxWidth)
    $bar     = if ($barLen -gt 0) { '█' * $barLen } else { '▏' }
    $color   = Get-AnsiColor -Value $total -Max $maxTotal
    $reset   = if ($useAnsi) { $RESET } else { '' }

    # Right-align the package count to keep columns tidy (up to 4 digits)
    $countStr = $total.ToString().PadLeft(4)

    Write-Host ("[$label] $color$bar$reset $countStr pkg")
}

Write-Host ''
Write-Host "  Showing $($entries.Count) of $($allEntries.Count) total cycle(s)  |  max = $maxTotal packages  |  each █ ~ $([math]::Round($maxTotal / $barMaxWidth, 1)) pkg"
Write-Host ''

exit 0

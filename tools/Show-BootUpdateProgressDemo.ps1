#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateRange(2,60)][int]$DurationSeconds = 8,
    [ValidateRange(50,1000)][int]$RefreshMilliseconds = 100
)

if ([Console]::IsOutputRedirected -or $Host.Name -ne 'ConsoleHost') {
    throw 'Run this demo directly in a PowerShell console so in-place rendering is visible.'
}

$frames = @('|', '/', '-', '\')
function New-NeonGradient {
    param([ValidateRange(4,64)][int]$StepsPerSegment = 16)
    $anchors = @(
        [int[]]@(80, 255, 230), [int[]]@(95, 115, 255),
        [int[]]@(15, 4, 22), [int[]]@(255, 90, 205),
        [int[]]@(75, 255, 145), [int[]]@(235, 255, 90),
        [int[]]@(0, 15, 14)
    )
    $gradient = [Collections.Generic.List[string]]::new()
    for ($segment = 0; $segment -lt $anchors.Count; $segment++) {
        $start = $anchors[$segment]
        $end = $anchors[($segment + 1) % $anchors.Count]
        for ($step = 0; $step -lt $StepsPerSegment; $step++) {
            $amount = $step / $StepsPerSegment
            $channels = for ($channel = 0; $channel -lt 3; $channel++) {
                [math]::Round($start[$channel] + (($end[$channel] - $start[$channel]) * $amount))
            }
            $gradient.Add(($channels -join ';'))
        }
    }
    return $gradient.ToArray()
}
function New-DepthGradient {
    param([ValidateRange(4,64)][int]$StepsPerSegment = 24)
    $anchors = @([int[]]@(0, 20, 28), [int[]]@(25, 10, 41))
    $gradient = [Collections.Generic.List[string]]::new()
    for ($segment = 0; $segment -lt $anchors.Count; $segment++) {
        $start = $anchors[$segment]
        $end = $anchors[($segment + 1) % $anchors.Count]
        for ($step = 0; $step -lt $StepsPerSegment; $step++) {
            $amount = $step / $StepsPerSegment
            $channels = for ($channel = 0; $channel -lt 3; $channel++) {
                [math]::Round($start[$channel] + (($end[$channel] - $start[$channel]) * $amount))
            }
            $gradient.Add(($channels -join ';'))
        }
    }
    return $gradient.ToArray()
}
function Limit-DemoText {
    param([string]$Text, [int]$MaxLength)
    if ($Text.Length -le $MaxLength) { return $Text }
    return $Text.Substring(0, [math]::Max(1, $MaxLength - 3)) + '...'
}
function Get-DemoProgressText {
    param(
        [string]$Frame, [string]$Activity, [string]$Status,
        [int]$Percent, [string]$Mode, [int]$MaxWidth
    )
    $filled = [math]::Min(10, [math]::Floor($Percent / 10))
    $meter = "[$(('#' * $filled) + ('-' * (10 - $filled)))] $Percent%"
    $suffix = " :: v:$($Mode.ToUpperInvariant())"
    $prefix = if ($MaxWidth -lt 60) { " PULSE [$Frame]" } else { " BOOT//PULSE [$Frame]" }
    $full = "$prefix $Activity :: $Status :: $meter$suffix"
    if ($full.Length -le $MaxWidth) { return $full }
    $withoutMeter = "$prefix $Activity :: $Status$suffix"
    if ($withoutMeter.Length -le $MaxWidth) { return $withoutMeter }
    $statusBudget = $MaxWidth - $prefix.Length - $Activity.Length - $suffix.Length - 5
    if ($statusBudget -ge 7) {
        return "$prefix $Activity :: $(Limit-DemoText $Status $statusBudget)$suffix"
    }
    $activityBudget = [math]::Max(4, $MaxWidth - $prefix.Length - $suffix.Length - 1)
    return "$prefix $(Limit-DemoText $Activity $activityBudget)$suffix"
}
$palette = New-NeonGradient
$depthPalette = New-DepthGradient
$scenes = @(
    @('Windows Update prefetch', 'Finishing background downloads'),
    @('Container images', 'Pulling refreshed layers'),
    @('Health checks', 'Verifying services')
)
$modes = @('Quiet','Normal','Verbose','Debug')
$mode = 'Normal'
$deadline = [datetime]::UtcNow.AddSeconds($DurationSeconds)
$index = 0
$colorIndex = 0
$renderedWidth = 0
$renderedConsoleWidth = 0
$cursorWasVisible = [Console]::CursorVisible
$vt = [bool]$Host.UI.SupportsVirtualTerminal
$escape = [char]27
try {
    [Console]::CursorVisible = $false
    Write-Host 'BOOT//PULSE demo — Turbo-era propeller status bar; press v to cycle modes.' -ForegroundColor Cyan
    while ([datetime]::UtcNow -lt $deadline) {
        while ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.KeyChar -in @('v','V')) {
                $mode = $modes[([array]::IndexOf($modes, $mode) + 1) % $modes.Count]
            }
        }
        $elapsed = $DurationSeconds - [math]::Max(0, ($deadline - [datetime]::UtcNow).TotalSeconds)
        $percent = [math]::Min(99, [math]::Floor(($elapsed / $DurationSeconds) * 100))
        $scene = $scenes[[math]::Min($scenes.Count - 1, [math]::Floor(($elapsed / $DurationSeconds) * $scenes.Count))]
        $frame = $frames[$index % $frames.Count]
        $width = [math]::Max(20, [math]::Min(120, [Console]::WindowWidth - 1))
        $line = Get-DemoProgressText -Frame $frame -Activity $scene[0] -Status $scene[1] `
            -Percent $percent -Mode $mode -MaxWidth $width
        if ($mode -eq 'Quiet') {
            if ($vt) {
                [Console]::Write("$escape[0m`r$escape[2K")
            } else {
                $clearWidth = [math]::Min([math]::Max(1, $renderedWidth), $width)
                [Console]::Write("`r$(' ' * $clearWidth)`r")
            }
            $renderedWidth = 0
            $renderedConsoleWidth = 0
        } elseif ($vt) {
            $rgb = $palette[$colorIndex]
            $depthRgb = $depthPalette[$colorIndex % $depthPalette.Count]
            $erase = if ($renderedConsoleWidth -gt 0 -and $renderedConsoleWidth -ne $width) { "$escape[2K" } else { '' }
            $padding = [math]::Min([math]::Max(0, $renderedWidth - $line.Length), [math]::Max(0, $width - $line.Length))
            [Console]::Write("`r$erase$escape[1;38;2;${rgb};48;2;${depthRgb}m$line$(' ' * $padding)$escape[0m")
            $renderedWidth = $line.Length
            $renderedConsoleWidth = $width
        } else {
            $padding = [math]::Min(
                [math]::Max(0, $renderedWidth - $line.Length),
                [math]::Max(0, $width - $line.Length)
            )
            [Console]::Write("`r$line$(' ' * $padding)")
            $renderedWidth = $line.Length
            $renderedConsoleWidth = $width
        }
        $index++
        $colorIndex = ($colorIndex + 1) % $palette.Count
        Start-Sleep -Milliseconds $RefreshMilliseconds
    }
} finally {
    try {
        if ($vt) {
            [Console]::Write("$escape[0m`r$escape[2K")
        } else {
            $clearWidth = [math]::Min([math]::Max(1, $renderedWidth), [math]::Max(1, [Console]::WindowWidth - 1))
            [Console]::Write("`r$(' ' * $clearWidth)`r")
        }
    } finally {
        [Console]::CursorVisible = $cursorWasVisible
    }
}
Write-Host "PASS: rendered $index BOOT//PULSE frames across $DurationSeconds seconds." -ForegroundColor Green

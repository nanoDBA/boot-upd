#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateRange(2,60)][int]$DurationSeconds = 8,
    [ValidateRange(50,1000)][int]$RefreshMilliseconds = 100
)

if ([Console]::IsOutputRedirected -or $Host.Name -ne 'ConsoleHost') {
    throw 'Run this demo directly in a PowerShell console so in-place rendering is visible.'
}

$frames = @(
    '>>>.....', '.>>>....', '..>>>...', '...>>>..', '....>>>.', '.....>>>',
    '....<<<.', '...<<<..', '..<<<...', '.<<<....'
)
$palette = @(
    '80;255;230', '45;225;238', '20;185;240', '95;115;255', '155;60;255',
    '220;70;230', '255;90;205', '190;105;235', '110;210;205', '75;255;145'
)
$scenes = @(
    @('Windows Update prefetch', 'Finishing background downloads'),
    @('Container images', 'Pulling refreshed layers'),
    @('Health checks', 'Verifying services')
)
$modes = @('Quiet','Normal','Verbose','Debug')
$mode = 'Normal'
$deadline = [datetime]::UtcNow.AddSeconds($DurationSeconds)
$index = 0
$renderedWidth = 0
$cursorWasVisible = [Console]::CursorVisible
$vt = [bool]$Host.UI.SupportsVirtualTerminal
$escape = [char]27
try {
    [Console]::CursorVisible = $false
    Write-Host 'BOOT//PULSE demo — neon comet, immutable status text; press v to cycle modes.' -ForegroundColor Cyan
    while ([datetime]::UtcNow -lt $deadline) {
        while ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.KeyChar -in @('v','V')) {
                $mode = $modes[([array]::IndexOf($modes, $mode) + 1) % $modes.Count]
            }
        }
        $elapsed = $DurationSeconds - [math]::Max(0, ($deadline - [datetime]::UtcNow).TotalSeconds)
        $percent = [math]::Min(99, [math]::Floor(($elapsed / $DurationSeconds) * 100))
        $filled = [math]::Min(10, [math]::Floor($percent / 10))
        $meter = ('#' * $filled) + ('-' * (10 - $filled))
        $scene = $scenes[[math]::Min($scenes.Count - 1, [math]::Floor(($elapsed / $DurationSeconds) * $scenes.Count))]
        $frame = $frames[$index % $frames.Count]
        $line = " BOOT//PULSE [$frame] $($scene[0]) :: $($scene[1]) :: [$meter] $percent% :: v:$($mode.ToUpperInvariant())"
        $width = [math]::Max(20, [math]::Min(120, [Console]::WindowWidth - 1))
        if ($line.Length -gt $width) { $line = $line.Substring(0, $width - 3) + '...' }
        if ($mode -eq 'Quiet') {
            if ($vt) {
                [Console]::Write("$escape[0m`r$escape[2K")
            } else {
                $clearWidth = [math]::Min([math]::Max(1, $renderedWidth), $width)
                [Console]::Write("`r$(' ' * $clearWidth)`r")
            }
            $renderedWidth = 0
        } elseif ($vt) {
            $rgb = $palette[$index % $palette.Count]
            [Console]::Write("`r$escape[2K$escape[1;38;2;${rgb}m$line$escape[0m")
            $renderedWidth = $line.Length
        } else {
            $padding = [math]::Min(
                [math]::Max(0, $renderedWidth - $line.Length),
                [math]::Max(0, $width - $line.Length)
            )
            [Console]::Write("`r$line$(' ' * $padding)")
            $renderedWidth = $line.Length
        }
        $index++
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

#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateRange(2,60)][int]$DurationSeconds = 8,
    [ValidateRange(50,1000)][int]$RefreshMilliseconds = 100
)

if ([Console]::IsOutputRedirected -or $Host.Name -ne 'ConsoleHost') {
    throw 'Run this demo directly in a PowerShell console so in-place progress rendering is visible.'
}

$frames = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
$deadline = [datetime]::UtcNow.AddSeconds($DurationSeconds)
$index = 0
$savedProgressPreference = $ProgressPreference
$savedProgressView = $PSStyle.Progress.View
$savedProgressWidth = $PSStyle.Progress.MaxWidth
try {
    $ProgressPreference = 'Continue'
    $PSStyle.Progress.View = 'Minimal'
    $PSStyle.Progress.MaxWidth = 88
    Write-Host 'Boot Update Cycle progress demo — watch the glyph rotate smoothly.' -ForegroundColor Cyan
    while ([datetime]::UtcNow -lt $deadline) {
        $elapsed = $DurationSeconds - [math]::Max(0, ($deadline - [datetime]::UtcNow).TotalSeconds)
        $percent = [math]::Min(99, [math]::Floor(($elapsed / $DurationSeconds) * 100))
        $frame = $frames[$index % $frames.Count]
        $index++
        Write-Progress -Id 740 -Activity 'Boot Update Cycle UI demo' `
            -Status "$frame animation frame $index | refresh ${RefreshMilliseconds}ms" `
            -PercentComplete $percent
        Start-Sleep -Milliseconds $RefreshMilliseconds
    }
} finally {
    Write-Progress -Id 740 -Activity 'Boot Update Cycle UI demo' -Completed
    $ProgressPreference = $savedProgressPreference
    $PSStyle.Progress.View = $savedProgressView
    $PSStyle.Progress.MaxWidth = $savedProgressWidth
}
Write-Host "PASS: rendered $index frames across $DurationSeconds seconds." -ForegroundColor Green

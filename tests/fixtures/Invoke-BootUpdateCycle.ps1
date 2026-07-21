param(
    [Parameter(Mandatory)][string]$MutexName,
    [Parameter(Mandatory)][string]$FunctionPath,
    [Parameter(Mandatory)][string]$ChildPath,
    [Parameter(Mandatory)][string]$ReadyPath,
    [Parameter(Mandatory)][string]$GoPath,
    [Parameter(Mandatory)][string]$ReplacementResultPath
)

$mutex = [System.Threading.Mutex]::new($false, $MutexName)
$ownsMutex = $mutex.WaitOne(0)
[Environment]::SetEnvironmentVariable('BOOT_UPDATE_SELF_UPDATE_HANDOFF', $null, 'Process')
$readyTemp = "$ReadyPath.$PID.tmp"
@{ ProcessId = $PID; OwnsMutex = $ownsMutex } |
    ConvertTo-Json -Compress |
    Set-Content -LiteralPath $readyTemp -Encoding utf8
[IO.File]::Move($readyTemp, $ReadyPath)

$deadline = [datetime]::UtcNow.AddSeconds(15)
while (-not (Test-Path -LiteralPath $GoPath)) {
    if ([datetime]::UtcNow -ge $deadline) { throw 'Timed out waiting for integration-test signal.' }
    Start-Sleep -Milliseconds 50
}

$markerName = 'BOOT_UPDATE_SELF_UPDATE_HANDOFF'
$marker = "v1:${PID}:$([guid]::NewGuid().ToString('N'))"
try {
    [Environment]::SetEnvironmentVariable($markerName, $marker, 'Process')
    & pwsh -NoProfile -File $ChildPath -MutexName $MutexName `
        -FunctionPath $FunctionPath -ResultPath $ReplacementResultPath
    if ($LASTEXITCODE -ne 0) { throw "Replacement process exited with $LASTEXITCODE." }
} finally {
    [Environment]::SetEnvironmentVariable($markerName, $null, 'Process')
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

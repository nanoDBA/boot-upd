param(
    [Parameter(Mandatory)][string]$MutexName,
    [Parameter(Mandatory)][string]$FunctionPath,
    [Parameter(Mandatory)][string]$ResultPath
)

function Write-Log { param([string]$Message, [string]$Level) }
function Test-LegacySelfUpdateHandoff { return $false }
. $FunctionPath

$granted = Enter-BootUpdateMutex -MutexName $MutexName
$result = [ordered]@{
    ProcessId = $PID
    Granted = $granted
    OwnsMutex = ($null -ne $script:BootUpdateMutex)
    HandoffConsumed = [string]::IsNullOrEmpty(
        [Environment]::GetEnvironmentVariable('BOOT_UPDATE_SELF_UPDATE_HANDOFF', 'Process')
    )
}
$result | ConvertTo-Json -Compress | Set-Content -LiteralPath $ResultPath -Encoding utf8

if ($script:BootUpdateMutex) {
    $script:BootUpdateMutex.ReleaseMutex()
    $script:BootUpdateMutex.Dispose()
}

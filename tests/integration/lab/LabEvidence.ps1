function ConvertFrom-BootUpdLabTaskEvent {
    <# Parse Windows event XML structurally; ToXml() may use either quote style. #>
    [CmdletBinding()]
    param([Parameter(Mandatory,ValueFromPipeline)][string]$Xml)
    process {
        $document=[xml]$Xml
        $data=@{}
        foreach ($node in $document.Event.EventData.Data) { $data[[string]$node.Name]=[string]$node.'#text' }
        [pscustomobject]@{
            Id=[int][string]$document.Event.System.EventID
            TaskName=[string]$data['TaskName']
            UserContext=[string]$data['UserContext']
            TimeCreatedUtc=[datetime]$document.Event.System.TimeCreated.SystemTime
            Xml=$Xml
        }
    }
}

function Get-BootUpdLabContinuationResult {
    param([bool]$Verified,[bool]$CleanupVerified,[string]$CompletionLine)
    if (-not $Verified -or -not $CleanupVerified -or $CompletionLine -notmatch 'BOOT UPDATE CYCLE COMPLETE\b') { return 'FAIL' }
    if ($CompletionLine -match 'DEFERRED INVENTORY|WINGET QUARANTINE') { return 'PARTIAL' }
    return 'PASS'
}

function Add-BootUpdLabLiveLog {
    <# Appends the guest log lines one poll brought back to the host-side live copy and
       returns the guest's line count to hand to the next poll. A guest log shorter than
       last time was rotated or recreated (a fresh install archives the old log), so the
       poll returned the whole new file; the marker keeps that break visible instead of
       letting two logs run together as one. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$KnownCount,
        [Parameter(Mandatory)][int]$GuestCount,
        [string[]]$NewLines=@()
    )
    if ($GuestCount -lt $KnownCount) {
        Add-Content -LiteralPath $Path -Value ("# {0} guest log shrank from {1} to {2} lines (rotated or recreated); the lines below are the new file" -f (Get-Date -Format 'HH:mm:ss'), $KnownCount, $GuestCount)
    }
    if (@($NewLines).Count -gt 0) { Add-Content -LiteralPath $Path -Value $NewLines }
    return $GuestCount
}

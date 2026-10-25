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

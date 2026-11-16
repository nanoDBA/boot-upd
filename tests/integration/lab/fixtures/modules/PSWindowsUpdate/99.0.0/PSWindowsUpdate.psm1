function Get-WindowsUpdate {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [switch]$AcceptAll,
        [switch]$Download,
        [switch]$Install,
        [switch]$IgnoreReboot,
        [switch]$AutoReboot,
        [string[]]$NotTitle,
        [string]$Criteria,
        [string]$Category,
        [int]$ResultPageSize
    )
    $record = [pscustomobject]@{ Provider='WindowsUpdate'; AtUtc=[datetime]::UtcNow.ToString('o'); Install=[bool]$Install; Download=[bool]$Download }
    $record | ConvertTo-Json -Compress | Add-Content -LiteralPath $env:BOOTUPD_LAB_FIXTURE_LOG -Encoding UTF8
    return @()
}
Export-ModuleMember -Function Get-WindowsUpdate

function Get-WindowsUpdate {
    param(
        [switch]$AcceptAll,
        [switch]$Download,
        [switch]$Install,
        [switch]$IgnoreReboot,
        [switch]$AutoReboot,
        [string[]]$NotTitle,
        [string]$Criteria,
        [string]$Category
    )
    return @()
}
Export-ModuleMember -Function Get-WindowsUpdate

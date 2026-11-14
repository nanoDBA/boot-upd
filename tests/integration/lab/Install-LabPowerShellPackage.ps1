#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BundlePath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$Sha256,
    [Parameter(Mandatory)][string]$ResultPath
)
$ErrorActionPreference = 'Stop'
$actual = (Get-FileHash -LiteralPath $BundlePath -Algorithm SHA256).Hash
if ($actual -ine $Sha256) { throw 'The lab PowerShell package hash does not match its pinned release digest.' }
Add-AppxPackage -Path $BundlePath -ForceUpdateFromAnyVersion -ErrorAction Stop
$package = Get-AppxPackage -Name Microsoft.PowerShell | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
if (-not $package) { throw 'The PowerShell MSIX package was not registered for this account.' }
$result = [pscustomobject]@{
    Version = [string]$package.Version
    PwshPath = Join-Path $package.InstallLocation 'pwsh.exe'
    PackageFullName = [string]$package.PackageFullName
    Sha256 = $actual
}
$result | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $ResultPath -Encoding UTF8

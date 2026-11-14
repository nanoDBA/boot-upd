#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BundlePath,
    [Parameter(Mandatory)][string]$XamlDependencyPath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$BundleSha256,
    [Parameter(Mandatory)][string]$ResultPath
)
$ErrorActionPreference = 'Stop'
try {
    $actual = (Get-FileHash -LiteralPath $BundlePath -Algorithm SHA256).Hash
    if ($actual -ine $BundleSha256) { throw 'Windows Terminal package hash mismatch.' }
    Add-AppxPackage -Path $XamlDependencyPath -ErrorAction Stop
    Add-AppxPackage -Path $BundlePath -ErrorAction Stop
    $package = Get-AppxPackage -Name Microsoft.WindowsTerminal | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
    if (-not $package) { throw 'Windows Terminal did not register for the lab user.' }
    [pscustomobject]@{ Version=[string]$package.Version; PackageFullName=[string]$package.PackageFullName; Result='PASS' } |
        ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
} catch {
    $_ | Out-String | Set-Content -LiteralPath ($ResultPath + '.err') -Encoding UTF8
    exit 1
}

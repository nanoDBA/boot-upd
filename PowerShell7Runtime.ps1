#requires -Version 5.1
[CmdletBinding()]
param([switch]$ResolveMachineMsixPath, [string]$WindowsAppsRoot = (Join-Path $env:ProgramFiles 'WindowsApps'))

function Get-PowerShell7TargetArchitecture {
    if (-not [Environment]::Is64BitOperatingSystem) { return 'x86' }
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { return 'arm64' }
    return 'x64'
}

function Select-PowerShell7LegacyEntry {
    <# The installer's definition of the PowerShell 7 MSI and its Microsoft Update bundle.
       Keep previews, unrelated products and the MSIX out of this list. #>
    param([object[]]$Entries)
    $matched = foreach ($entry in @($Entries)) {
        if (-not $entry -or [string]$entry.DisplayName -notmatch '^PowerShell 7(\.[\d.]+)?-(x64|x86|arm64)$') { continue }
        $isBundle = [string]$entry.UninstallString -match '(?i)\.exe"?\s+/uninstall'
        $isMsi = -not $isBundle -and ([int]($entry.WindowsInstaller -as [int]) -eq 1) -and
            [string]$entry.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$'
        if (-not $isBundle -and -not $isMsi) { continue }
        [pscustomobject]@{
            Name = [string]$entry.DisplayName
            Version = [string]$entry.DisplayVersion
            Kind = if ($isBundle) { 'Bundle' } else { 'Msi' }
            ProductCode = [string]$entry.PSChildName
            UninstallString = [string]$entry.UninstallString
        }
    }
    return @($matched | Sort-Object @{ Expression = { if ($_.Kind -eq 'Bundle') { 0 } else { 1 } } })
}

function Get-PowerShell7MachineMsixPackages {
    param(
        [string]$WindowsAppsRoot = (Join-Path $env:ProgramFiles 'WindowsApps'),
        [string]$Architecture = (Get-PowerShell7TargetArchitecture),
        [switch]$ErrorOnEnumerationFailure
    )
    $pattern = '^Microsoft\.PowerShell_(?<version>\d+(?:\.\d+){1,3})_' +
        [regex]::Escape($Architecture) + '__8wekyb3d8bbwe$'
    $enumerationErrorAction = if ($ErrorOnEnumerationFailure) { 'Stop' } else { 'SilentlyContinue' }
    $packages = foreach ($folder in @(Get-ChildItem -LiteralPath $WindowsAppsRoot -Directory -ErrorAction $enumerationErrorAction)) {
        if ($folder.Name -notmatch $pattern) { continue }
        $version = [version]'0.0'
        if (-not [version]::TryParse($Matches.version, [ref]$version)) { continue }
        $path = Join-Path $folder.FullName 'pwsh.exe'
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            [pscustomobject]@{ Version=$version; PwshPath=$path; Architecture=$Architecture }
        }
    }
    return @($packages | Sort-Object Version -Descending)
}

function Get-PowerShell7MachineMsixPath {
    param(
        [string]$WindowsAppsRoot = (Join-Path $env:ProgramFiles 'WindowsApps'),
        [string]$Architecture = (Get-PowerShell7TargetArchitecture)
    )
    $package = Get-PowerShell7MachineMsixPackages -WindowsAppsRoot $WindowsAppsRoot -Architecture $Architecture |
        Select-Object -First 1
    if ($package) { return [string]$package.PwshPath }
    return $null
}

if ($ResolveMachineMsixPath) {
    $path = Get-PowerShell7MachineMsixPath -WindowsAppsRoot $WindowsAppsRoot
    if ($path) { Write-Output $path; exit 0 }
    exit 1
}

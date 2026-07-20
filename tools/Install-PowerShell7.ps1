#requires -Version 5.1
[CmdletBinding()]
param([switch]$Elevated)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Get-PowerShell7Path {
    $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($candidate in @(
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe')
    )) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$existing = Get-PowerShell7Path
if ($existing) { Write-Output $existing; exit 0 }

if (-not (Test-Administrator)) {
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -Elevated' -f $PSCommandPath
    $process = Start-Process -FilePath $windowsPowerShell -Verb RunAs -Wait -PassThru -ArgumentList $arguments
    exit $process.ExitCode
}

Write-Host 'PowerShell 7 is required for parallel update execution.' -ForegroundColor Cyan
Write-Host 'Installing it side-by-side with Windows PowerShell 5.1...' -ForegroundColor Cyan

$winget = Get-Command winget.exe -ErrorAction SilentlyContinue
if ($winget) {
    $wingetArguments = @(
        'install','--id','Microsoft.PowerShell','--exact','--source','winget',
        '--installer-type','wix','--scope','machine','--silent',
        '--accept-package-agreements','--accept-source-agreements','--disable-interactivity'
    )
    & $winget.Source @wingetArguments
    $installed = Get-PowerShell7Path
    if ($installed) { Write-Output $installed; exit 0 }

    Write-Warning 'The machine-wide WinGet/MSI route was unavailable; trying the supported default package.'
    & $winget.Source install --id Microsoft.PowerShell --exact --source winget --silent `
        --accept-package-agreements --accept-source-agreements --disable-interactivity
    $installed = Get-PowerShell7Path
    if ($installed) { Write-Output $installed; exit 0 }
}

$architecture = if (-not [Environment]::Is64BitOperatingSystem) { 'x86' } elseif (
    $env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64'
) { 'arm64' } else { 'x64' }

Write-Host "WinGet did not provide PowerShell 7; locating the newest Microsoft-signed $architecture MSI..." -ForegroundColor Yellow
$headers = @{ 'User-Agent' = 'BootUpdateCycle-PowerShell7-Bootstrap' }
$releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases?per_page=20' -Headers $headers -UseBasicParsing
$asset = $null
foreach ($release in $releases) {
    if ($release.draft -or $release.prerelease) { continue }
    $asset = $release.assets | Where-Object { $_.name -match "^PowerShell-[\d.]+-win-$architecture\.msi$" } | Select-Object -First 1
    if ($asset) { break }
}
if (-not $asset) { throw "No stable Microsoft PowerShell MSI was found for $architecture." }

$tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ('boot-upd-pwsh-{0}' -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tempDirectory -ErrorAction Stop
$msiPath = Join-Path $tempDirectory $asset.name
try {
    $oldProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $msiPath -Headers $headers -UseBasicParsing }
    finally { $ProgressPreference = $oldProgress }

    $signature = Get-AuthenticodeSignature -FilePath $msiPath
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?i)(^|,\s*)O=Microsoft Corporation(,|$)') {
        throw "PowerShell MSI publisher verification failed: $($signature.Status) $($signature.SignerCertificate.Subject)"
    }
    Write-Host "Verified Microsoft publisher signature on $($asset.name)." -ForegroundColor Green
    $arguments = @('/i', ('"{0}"' -f $msiPath), '/qn', '/norestart', 'USE_MU=1', 'ENABLE_MU=1')
    $installer = Start-Process -FilePath msiexec.exe -ArgumentList $arguments -Wait -PassThru
    if ($installer.ExitCode -notin @(0,3010)) { throw "PowerShell MSI installation failed with exit code $($installer.ExitCode)." }
} finally {
    Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

$installed = Get-PowerShell7Path
if (-not $installed) { throw 'PowerShell 7 installation completed but pwsh.exe could not be located.' }
Write-Host "PowerShell 7 ready: $installed" -ForegroundColor Green
Write-Output $installed

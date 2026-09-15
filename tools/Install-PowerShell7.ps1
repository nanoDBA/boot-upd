#requires -Version 5.1
[CmdletBinding()]
param([switch]$Elevated, [switch]$Upgrade, [switch]$CheckOnly)

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

function Get-PowerShell7TargetArchitecture {
    if (-not [Environment]::Is64BitOperatingSystem) { return 'x86' }
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { return 'arm64' }
    return 'x64'
}

function Get-PowerShell7LatestStableVersion {
    param([Parameter(Mandatory)][string]$Architecture)
    $headers = @{ 'User-Agent' = 'BootUpdateCycle-PowerShell7-Bootstrap' }
    $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases?per_page=20' -Headers $headers -UseBasicParsing
    foreach ($release in $releases) {
        if ($release.draft -or $release.prerelease) { continue }
        $asset = $release.assets | Where-Object { $_.name -match "^PowerShell-[\d.]+-win-$Architecture\.msi$" } | Select-Object -First 1
        if ($asset -and $asset.name -match '^PowerShell-(?<ver>[\d.]+)-win-') {
            return [pscustomobject]@{ Version = [version]$Matches.ver; Asset = $asset }
        }
    }
    throw "No stable Microsoft PowerShell MSI was found for $Architecture."
}

function Get-PowerShell7InstalledVersion {
    param([Parameter(Mandatory)][string]$PwshPath)
    try {
        $outFile = [IO.Path]::GetTempFileName()
        $errFile = [IO.Path]::GetTempFileName()
        try {
            $process = Start-Process -FilePath $PwshPath -ArgumentList @('-NoProfile','-NonInteractive','-Command','$PSVersionTable.PSVersion.ToString()') `
                -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
            if ($process.WaitForExit(15000)) {
                $text = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
                $versionText = ($text -split '\r?\n' | Where-Object { $_ } | Select-Object -Last 1)
                if ($versionText) { return [version]$versionText }
            } else {
                try { $process.Kill() } catch { }
            }
        } finally {
            Remove-Item -LiteralPath $outFile,$errFile -Force -ErrorAction SilentlyContinue
        }
    } catch { }
    return [version](Get-Item -LiteralPath $PwshPath).VersionInfo.FileVersion
}

function Get-PowerShell7UpgradeDecision {
    param([Parameter(Mandatory)][version]$InstalledVersion, [Parameter(Mandatory)][version]$LatestVersion)
    if ($InstalledVersion -ge $LatestVersion) {
        return [pscustomobject]@{
            NeedsUpgrade = $false
            Message      = "PowerShell $InstalledVersion is already the latest stable release."
        }
    }
    return [pscustomobject]@{ NeedsUpgrade = $true; Message = $null }
}

function Install-PowerShell7FromMsi {
    param([Parameter(Mandatory)][string]$Architecture)

    $headers = @{ 'User-Agent' = 'BootUpdateCycle-PowerShell7-Bootstrap' }
    $latest = Get-PowerShell7LatestStableVersion -Architecture $Architecture
    $asset = $latest.Asset

    $tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ('boot-upd-pwsh-{0}' -f [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $tempDirectory -ErrorAction Stop
    $msiPath = Join-Path $tempDirectory $asset.name
    $exitCode = 0
    try {
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $msiPath -Headers $headers -UseBasicParsing }
        finally { $ProgressPreference = $oldProgress }

        <# Explicit path: when Windows PowerShell 5.1 is started from pwsh it inherits pwsh's
           PSModulePath and cannot autoload its own Microsoft.PowerShell.Security, which is
           exactly how the launcher's bootstrap command starts this script. #>
        Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security') -ErrorAction Stop
        $signature = Get-AuthenticodeSignature -FilePath $msiPath
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?i)(^|,\s*)O=Microsoft Corporation(,|$)') {
            throw "PowerShell MSI publisher verification failed: $($signature.Status) $($signature.SignerCertificate.Subject)"
        }
        Write-Host "Verified Microsoft publisher signature on $($asset.name)." -ForegroundColor Green
        <# MSIRESTARTMANAGERCONTROL=Disable: an in-place upgrade must not let Restart Manager
           close the running pwsh.exe, because on a machine that already has PowerShell 7 that
           process is the launcher hosting this very upgrade. Observed on lab-b 2026-09-15:
           Restart Manager closed pwsh mid-transaction, cmd.exe asked "Terminate batch job",
           the client died, and the guest was left with no pwsh.exe at all (MSI 1316/1603).
           With Restart Manager off, files in use are replaced at the next restart and msiexec
           reports 3010, which the caller surfaces as a pending restart. #>
        $msiLog = Join-Path ([IO.Path]::GetTempPath()) 'boot-upd-PowerShell-msi.log'
        $arguments = @('/i', ('"{0}"' -f $msiPath), '/qn', '/norestart', '/l*v', ('"{0}"' -f $msiLog),
                       'USE_MU=1', 'ENABLE_MU=1', 'MSIRESTARTMANAGERCONTROL=Disable')
        $installer = Start-Process -FilePath msiexec.exe -ArgumentList $arguments -Wait -PassThru
        if ($installer.ExitCode -notin @(0,3010)) { throw "PowerShell MSI installation failed with exit code $($installer.ExitCode). Installer log: $msiLog" }
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
        $exitCode = $installer.ExitCode
    } finally {
        if ($installer) { $installer.Dispose() }
    }
    <# Deliberately NOT deleting the package here. When this script hosts an in-place
       upgrade, Restart Manager shuts down pwsh.exe and the console Ctrl+C that carries
       unwinds this try/finally while msiexec is still mid-transaction; a finally that
       removed the temp directory deleted the source MSI under the installer, which then
       failed SecureRepair with 1316/1603 and left the machine with no pwsh.exe at all
       (lab-b, 2026-09-15). The package is removed after a successful exit code instead. #>
    return $exitCode
}

$existing = Get-PowerShell7Path
if ($existing -and -not $Upgrade) { Write-Output $existing; exit 0 }

if (-not (Test-Administrator) -and -not $CheckOnly) {
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -Elevated' -f $PSCommandPath
    if ($Upgrade) { $arguments += ' -Upgrade' }
    if ($CheckOnly) { $arguments += ' -CheckOnly' }
    $process = Start-Process -FilePath $windowsPowerShell -Verb RunAs -Wait -PassThru -ArgumentList $arguments
    exit $process.ExitCode
}

if ($existing -and $Upgrade) {
    $architecture = Get-PowerShell7TargetArchitecture
    try {
        $latest = Get-PowerShell7LatestStableVersion -Architecture $architecture
    } catch {
        Write-Warning "Could not check the latest PowerShell release: $($_.Exception.Message)"
        exit 0
    }

    $installedVersion = Get-PowerShell7InstalledVersion -PwshPath $existing
    $decision = Get-PowerShell7UpgradeDecision -InstalledVersion $installedVersion -LatestVersion $latest.Version
    if (-not $decision.NeedsUpgrade) {
        Write-Host $decision.Message -ForegroundColor Green
        exit 0
    }
    if ($CheckOnly) {
        <# Exit 100: an upgrade is available. The launcher uses this to hand the real upgrade
           to a detached host, because the installer closes every pwsh.exe, including the one
           running the launcher. #>
        Write-Host "PowerShell $installedVersion is behind the latest stable release $($latest.Version)." -ForegroundColor Yellow
        exit 100
    }

    Write-Host "Upgrading PowerShell $installedVersion to $($latest.Version)..." -ForegroundColor Cyan
    $msiExitCode = 0
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        $wingetArguments = @(
            'upgrade','--id','Microsoft.PowerShell','--exact','--source','winget',
            '--silent','--accept-package-agreements','--accept-source-agreements','--disable-interactivity'
        )
        & $winget.Source @wingetArguments
        $wingetExit = $LASTEXITCODE
        if ($wingetExit -ne 0) { Write-Warning "winget upgrade returned $wingetExit; verifying the installed version before claiming anything." }
    } else {
        $msiExitCode = Install-PowerShell7FromMsi -Architecture $architecture
    }

    $newInstalled = Get-PowerShell7Path
    if (-not $newInstalled) { throw 'PowerShell 7 upgrade completed but pwsh.exe could not be located.' }
    $newVersion = Get-PowerShell7InstalledVersion -PwshPath $newInstalled
    if ($newVersion -le $installedVersion -and $msiExitCode -ne 3010) {
        <# No evidence of a change: say so and fail, rather than print an upgrade that did not happen. #>
        Write-Warning "PowerShell is still $newVersion after the upgrade attempt; no version change was verified."
        exit 1
    }
    Write-Host "PowerShell $installedVersion -> $newVersion installed." -ForegroundColor Green
    if ($msiExitCode -eq 3010) {
        Write-Host 'A restart is pending before the new version is fully in place.' -ForegroundColor Yellow
    }
    exit 0
}

Write-Host 'PowerShell 7 is required for parallel update execution.' -ForegroundColor Cyan
Write-Host 'Installing it side-by-side with Windows PowerShell 5.1...' -ForegroundColor Cyan

$architecture = Get-PowerShell7TargetArchitecture

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

Write-Host "WinGet did not provide PowerShell 7; locating the newest Microsoft-signed $architecture MSI..." -ForegroundColor Yellow
$null = Install-PowerShell7FromMsi -Architecture $architecture

$installed = Get-PowerShell7Path
if (-not $installed) { throw 'PowerShell 7 installation completed but pwsh.exe could not be located.' }
Write-Host "PowerShell 7 ready: $installed" -ForegroundColor Green
Write-Output $installed

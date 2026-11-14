#requires -Version 5.1
[CmdletBinding()]
param([switch]$Elevated, [switch]$Upgrade, [switch]$CheckOnly, [int]$WaitForProcessId = 0)

<# PowerShell 7 is installed one way: Microsoft's MSIX bundle from the GitHub release,
   provisioned machine-wide. PowerShell 7.7 ships no MSI (Microsoft deprecated it; 7.6 LTS is
   the last line with one), and WinGet installs only the MSIX for 7.7. Provisioning makes it
   available to every account on the machine; SYSTEM has no app execution alias but runs the
   provisioned pwsh.exe by its full path, which is how boot-upd starts it (Get-BootUpdatePwshPath).
   An existing 7.6 LTS MSI stays installed beside the newer MSIX. Do not remove it automatically.
   Windows that cannot install the MSIX (older than build 17763, or Server Core) keeps the
   deprecated route, the signed 7.6 LTS MSI, because that is what Microsoft supports there.
   See docs/adr/0008-powershell-7-is-the-machine-wide-msix.md.

   Exit codes: 0 done or nothing to do; 1 failed; 3 deferred because an update cycle is in
   progress; 100 (-CheckOnly) a newer version is available. #>

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

<# Started from pwsh, Windows PowerShell inherits pwsh's PSModulePath and cannot autoload its
   own Appx, Dism, ScheduledTasks or Microsoft.PowerShell.Security modules, which is exactly
   how the launcher and the orchestrator start this script. Use the machine's own value. #>
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $env:PSModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
}

$script:PackageName = 'Microsoft.PowerShell'
$script:PublisherId = '8wekyb3d8bbwe'
$script:LegacyPwshPath = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-LocalSystem {
    return ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
}

function Get-PowerShell7TargetArchitecture {
    if (-not [Environment]::Is64BitOperatingSystem) { return 'x86' }
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { return 'arm64' }
    return 'x64'
}

function Get-PowerShell7MsixInstall {
    <# The newest Microsoft.PowerShell package on this machine for this architecture, as
       [pscustomobject]@{ Version; PwshPath }, or $null. Get-AppxPackage -AllUsers needs
       elevation; a provisioned package nobody has signed in to yet is only visible as its
       folder under WindowsApps, which SYSTEM can list. #>
    $architecture = Get-PowerShell7TargetArchitecture
    $found = @()
    try {
        $packages = if (Test-Administrator) { Get-AppxPackage -AllUsers -Name $script:PackageName -ErrorAction Stop }
                    else { Get-AppxPackage -Name $script:PackageName -ErrorAction Stop }
        foreach ($package in @($packages)) {
            if ($package.PublisherId -ne $script:PublisherId) { continue }
            if ([string]$package.Architecture -ne $architecture -and [string]$package.Architecture -ne 'Neutral') { continue }
            $path = Join-Path $package.InstallLocation 'pwsh.exe'
            if (Test-Path -LiteralPath $path) { $found += [pscustomobject]@{ Version = [version]$package.Version; PwshPath = $path } }
        }
    } catch { }
    $pattern = '^{0}_(?<ver>[\d.]+)_{1}__{2}$' -f [regex]::Escape($script:PackageName), $architecture, $script:PublisherId
    foreach ($folder in @(Get-ChildItem -LiteralPath (Join-Path $env:ProgramFiles 'WindowsApps') -Directory -ErrorAction SilentlyContinue)) {
        if ($folder.Name -notmatch $pattern) { continue }
        $path = Join-Path $folder.FullName 'pwsh.exe'
        if (Test-Path -LiteralPath $path) { $found += [pscustomobject]@{ Version = [version]$Matches.ver; PwshPath = $path } }
    }
    return ($found | Sort-Object Version -Descending | Select-Object -First 1)
}

function Get-PowerShell7Path {
    $msix = Get-PowerShell7MsixInstall
    if ($msix) { return $msix.PwshPath }
    if (Test-Path -LiteralPath $script:LegacyPwshPath) { return $script:LegacyPwshPath }
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
    if ($env:LOCALAPPDATA -and (Test-Path -LiteralPath $alias)) { return $alias }
    $command = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
}

function Test-PowerShell7MsixSupported {
    <# The MSIX needs Windows 10 1809 / Server 2019 (build 17763, the package's minimum) and
       the Appx deployment stack, which Server Core does not have yet (PowerShell/PowerShell
       #27610). Those machines stay on the 7.6 LTS MSI, the last line Microsoft ships as one
       and supports for that line's lifetime. #>
    if ([Environment]::OSVersion.Version.Build -lt 17763) { return $false }
    if (-not (Get-Command Add-AppxProvisionedPackage -ErrorAction SilentlyContinue)) { return $false }
    $installationType = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).InstallationType
    return ($installationType -ne 'Server Core')
}

function Get-PowerShell7LatestStableVersion {
    <# The highest stable version on the release page that carries the package this machine
       installs: the MSIX bundle plus the release's checksum file, or, where the MSIX cannot
       install, the architecture's MSI. Highest by version, not by list order: maintenance
       releases of older lines (7.6.10 was published beside 7.7.0) must never win. #>
    param([ValidateSet('Msix','Msi')][string]$Package = 'Msix', [string]$Architecture = 'x64')
    $headers = @{ 'User-Agent' = 'BootUpdateCycle-PowerShell7-Bootstrap' }
    $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases?per_page=30' -Headers $headers -UseBasicParsing
    $best = $null
    foreach ($release in @($releases)) {
        if ($release.draft -or $release.prerelease) { continue }
        if ([string]$release.tag_name -notmatch '^v(?<ver>\d+\.\d+\.\d+)$') { continue }
        $version = [version]$Matches.ver
        $assetName = if ($Package -eq 'Msix') { "PowerShell-$version.msixbundle" } else { "PowerShell-$version-win-$Architecture.msi" }
        $asset = $release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
        $hashes = $release.assets | Where-Object { $_.name -eq 'hashes.sha256' } | Select-Object -First 1
        if (-not $asset -or ($Package -eq 'Msix' -and -not $hashes)) { continue }
        if (-not $best -or $version -gt $best.Version) {
            $best = [pscustomobject]@{ Version = $version; Package = $Package; Asset = $asset; HashAsset = $hashes }
        }
    }
    if (-not $best) { throw "No stable Microsoft PowerShell $Package package was found on the release page." }
    return $best
}

function ConvertFrom-PowerShell7HashFile {
    <# hashes.sha256 is "<sha256> *<file name>" per line (UTF-16 on the release page). #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$FileName)
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match '^\s*(?<hash>[0-9A-Fa-f]{64})\s+\*?(?<name>\S+)\s*$' -and $Matches.name -eq $FileName) {
            return $Matches.hash.ToUpperInvariant()
        }
    }
    throw "The release checksum file has no entry for $FileName."
}

function Get-PowerShell7UpgradeDecision {
    param(
        [Parameter(Mandatory)][version]$InstalledVersion,
        [Parameter(Mandatory)][version]$LatestVersion,
        <# The installed PowerShell 7 is the deprecated MSI (or anything that is not the MSIX). #>
        [switch]$Legacy
    )
    if ($Legacy) {
        return [pscustomobject]@{
            NeedsUpgrade = $true
            Message      = "PowerShell $InstalledVersion is an MSI install, which Microsoft no longer ships; replacing it with the $LatestVersion MSIX."
        }
    }
    if ($InstalledVersion -ge $LatestVersion) {
        return [pscustomobject]@{
            NeedsUpgrade = $false
            Message      = "PowerShell $InstalledVersion is already the latest stable release."
        }
    }
    return [pscustomobject]@{ NeedsUpgrade = $true; Message = $null }
}

function Get-PowerShell7CheckOnlyResult {
    param(
        [Parameter(Mandatory)][ValidateSet('Msix','Msi')][string]$Package,
        [Parameter(Mandatory)][version]$InstalledVersion,
        [Parameter(Mandatory)][version]$LatestVersion,
        [AllowEmptyCollection()][object[]]$LegacyEntries = @()
    )
    $decision = Get-PowerShell7UpgradeDecision -InstalledVersion $InstalledVersion -LatestVersion $LatestVersion
    $coexistence = ''
    if ($Package -eq 'Msix' -and @($LegacyEntries).Count -gt 0) {
        $targetVersion = if ($decision.NeedsUpgrade) { $LatestVersion } else { $InstalledVersion }
        $runtimeVerb = if ($decision.NeedsUpgrade) { 'will use' } else { 'use' }
        $coexistence = " The PowerShell 7.6 MSI is kept on purpose. upd and a newly opened Windows Terminal $runtimeVerb PowerShell $targetVersion; pwsh typed by name may still start PowerShell 7.6."
    }
    if ($decision.NeedsUpgrade) {
        $message = if ($decision.Message) { $decision.Message } else { "PowerShell $InstalledVersion is behind the latest stable release $LatestVersion." }
        return [pscustomobject]@{ ExitCode = 100; Message = ($message + $coexistence) }
    }
    if ($Package -eq 'Msix' -and @($LegacyEntries).Count -gt 0) {
        return [pscustomobject]@{
            ExitCode = 0
            Message = "PowerShell $InstalledVersion MSIX is current.$coexistence"
        }
    }
    return [pscustomobject]@{ ExitCode = 0; Message = $decision.Message }
}

function Get-PowerShell7InstalledVersion {
    param([Parameter(Mandatory)][string]$PwshPath)
    try {
        $outFile = [IO.Path]::GetTempFileName()
        $errFile = [IO.Path]::GetTempFileName()
        try {
            $process = Start-Process -FilePath $PwshPath -ArgumentList @('-NoProfile','-NonInteractive','-Command','$PSVersionTable.PSVersion.ToString()') `
                -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
            if ($process.WaitForExit(30000)) {
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
    try { return [version](Get-Item -LiteralPath $PwshPath).VersionInfo.ProductVersion.Split(' ')[0] } catch { return $null }
}

function Select-PowerShell7LegacyEntry {
    <# Uninstall entries of the deprecated PowerShell 7 MSI: the MSI product ("PowerShell 7-x64")
       and the Microsoft Update bundle that wraps it ("PowerShell 7.6.9.0-x64"). Previews and
       the MSIX are not matched. Bundles first: removing one removes its MSI too. #>
    param([object[]]$Entries)
    $matched = foreach ($entry in @($Entries)) {
        if (-not $entry -or [string]$entry.DisplayName -notmatch '^PowerShell 7(\.[\d.]+)?-(x64|x86|arm64)$') { continue }
        $isBundle = [string]$entry.UninstallString -match '(?i)\.exe"?\s+/uninstall'
        $isMsi = -not $isBundle -and ([int]($entry.WindowsInstaller -as [int]) -eq 1) -and [string]$entry.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$'
        if (-not $isBundle -and -not $isMsi) { continue }
        [pscustomobject]@{
            Name = [string]$entry.DisplayName; Version = [string]$entry.DisplayVersion
            Kind = $(if ($isBundle) { 'Bundle' } else { 'Msi' })
            ProductCode = [string]$entry.PSChildName; UninstallString = [string]$entry.UninstallString
        }
    }
    return @($matched | Sort-Object @{ Expression = { if ($_.Kind -eq 'Bundle') { 0 } else { 1 } } })
}

function Get-PowerShell7LegacyEntry {
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    return Select-PowerShell7LegacyEntry -Entries @(Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue)
}

function Remove-PowerShell7LegacyInstall {
    <# Deliberately uncalled. The owner chose to keep an installed 7.6 MSI beside the MSIX;
       see bd on_boot_update_reboot_loop_while_pending_restarts_exist-14qf before changing this. #>
    <# Restart Manager stays off (MSIRESTARTMANAGERCONTROL=Disable): the launcher that started
       this may still be running on the MSI's pwsh.exe, and on lab-b (2026-09-15) Restart
       Manager closing pwsh mid-transaction left a machine with no PowerShell at all. Files in
       use are removed at the next restart instead (3010). The runtime no longer lives in that
       folder, so nothing depends on them. #>
    $restartPending = $false
    $legacyRemoved = $false
    foreach ($entry in @(Get-PowerShell7LegacyEntry)) {
        Write-Host "Removing the deprecated PowerShell MSI install: $($entry.Name) $($entry.Version)..." -ForegroundColor Cyan
        if ($entry.Kind -eq 'Bundle') {
            if ($entry.UninstallString -notmatch '^\s*"(?<exe>[^"]+\.exe)"') { Write-Warning "Unrecognised uninstall command for $($entry.Name); left in place."; continue }
            $exe = $Matches.exe
            if (-not (Test-Path -LiteralPath $exe)) { continue }
            $process = Start-Process -FilePath $exe -ArgumentList @('/uninstall','/quiet','/norestart') -Wait -PassThru
        } else {
            $msiLog = Join-Path ([IO.Path]::GetTempPath()) 'boot-upd-PowerShell-msi-uninstall.log'
            $process = Start-Process -FilePath msiexec.exe -Wait -PassThru -ArgumentList @(
                '/x', $entry.ProductCode, '/qn', '/norestart', '/l*v', ('"{0}"' -f $msiLog), 'MSIRESTARTMANAGERCONTROL=Disable')
        }
        $code = $process.ExitCode
        $process.Dispose()
        if ($code -in @(0,3010)) {
            $legacyRemoved = $true
            if ($code -eq 3010) { $restartPending = $true }
        } elseif ($code -notin @(1605, 1614)) {
            Write-Warning "Removing $($entry.Name) returned $code; it may need to be removed from Settings > Apps."
        }
    }
    if ($legacyRemoved) {
        Write-Host 'TERMINAL_NOTICE: Close and reopen Windows Terminal to refresh PowerShell profiles that still point to the removed MSI.' -ForegroundColor Yellow
    }
    return $restartPending
}

function Test-BootUpdateCycleActive {
    <# A cycle in progress has continuation tasks that name the runtime's path. Changing the
       runtime under them would strand the next pass, so the change waits for the cycle to
       finish; the finished cycle starts this script again. #>
    return [bool](Get-ScheduledTask -TaskName 'BootUpdateCycle','BootUpdateCycleFallback' -ErrorAction SilentlyContinue)
}

function Install-PowerShell7Msix {
    param([Parameter(Mandatory)]$Release)

    if (-not (Get-Command Add-AppxProvisionedPackage -ErrorAction SilentlyContinue)) {
        throw 'This Windows edition cannot install MSIX packages (Microsoft tracks Server Core support in PowerShell/PowerShell#27610).'
    }
    $headers = @{ 'User-Agent' = 'BootUpdateCycle-PowerShell7-Bootstrap' }
    $tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ('boot-upd-pwsh-{0}' -f [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $tempDirectory -ErrorAction Stop
    try {
        $bundlePath = Join-Path $tempDirectory $Release.Asset.name
        $hashPath = Join-Path $tempDirectory 'hashes.sha256'
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $Release.Asset.browser_download_url -OutFile $bundlePath -Headers $headers -UseBasicParsing
            Invoke-WebRequest -Uri $Release.HashAsset.browser_download_url -OutFile $hashPath -Headers $headers -UseBasicParsing
        } finally { $ProgressPreference = $oldProgress }

        $expected = ConvertFrom-PowerShell7HashFile -Text (Get-Content -LiteralPath $hashPath -Raw) -FileName $Release.Asset.name
        $actual = (Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).Hash
        if ($actual -ne $expected) { throw "PowerShell bundle checksum mismatch: expected $expected, got $actual." }
        $signature = Get-AuthenticodeSignature -FilePath $bundlePath
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?i)(^|,\s*)O=Microsoft Corporation(,|$)') {
            throw "PowerShell bundle publisher verification failed: $($signature.Status) $($signature.SignerCertificate.Subject)"
        }
        Write-Host "Verified the checksum and Microsoft publisher signature on $($Release.Asset.name)." -ForegroundColor Green

        <# Machine-wide: every existing and future account gets the package, and its files
           land under WindowsApps where SYSTEM can run them by full path. #>
        $null = Add-AppxProvisionedPackage -Online -PackagePath $bundlePath -SkipLicense -ErrorAction Stop
        <# The account running this gets the pwsh alias now rather than at its next sign-in.
           Deferred while an older PowerShell 7 MSIX is running, never forced closed. #>
        if (-not (Test-LocalSystem)) {
            try { Add-AppxPackage -Path $bundlePath -DeferRegistrationWhenPackagesAreInUse -ErrorAction Stop }
            catch { Write-Warning "PowerShell is installed machine-wide; registering it for this account will finish at the next sign-in ($($_.Exception.Message))." }
        }
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }

    $installed = Get-PowerShell7MsixInstall
    if (-not $installed -or $installed.Version -lt $Release.Version) {
        throw "PowerShell $($Release.Version) was provisioned but its pwsh.exe could not be found."
    }
    $running = Get-PowerShell7InstalledVersion -PwshPath $installed.PwshPath
    if (-not $running -or $running -lt $Release.Version) {
        throw "PowerShell $($Release.Version) was provisioned but $($installed.PwshPath) did not start."
    }
    return $installed
}

function Install-PowerShell7FromMsi {
    param([Parameter(Mandatory)]$Release)

    $headers = @{ 'User-Agent' = 'BootUpdateCycle-PowerShell7-Bootstrap' }
    $asset = $Release.Asset

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

function Complete-PowerShell7Install {
    param([Parameter(Mandatory)]$Release)
    if ($Release.Package -eq 'Msi') {
        <# Fallback for Windows that cannot take the MSIX: the signed 7.6 LTS MSI. #>
        Write-Host "This Windows cannot install the PowerShell MSIX; using the $($Release.Version) MSI, the last line Microsoft ships as one." -ForegroundColor Yellow
        $exitCode = Install-PowerShell7FromMsi -Release $Release
        $path = Get-PowerShell7Path
        if (-not $path) { throw 'PowerShell 7 installation completed but pwsh.exe could not be located.' }
        $installed = [pscustomobject]@{ Version = (Get-PowerShell7InstalledVersion -PwshPath $path); PwshPath = $path }
        if ($exitCode -eq 3010) { Write-Host 'A restart is pending before the new version is fully in place.' -ForegroundColor Yellow }
    } else {
        $installed = Install-PowerShell7Msix -Release $Release
    }
    Write-Host "PowerShell $($installed.Version) ready: $($installed.PwshPath)" -ForegroundColor Green
    return $installed
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

if ($WaitForProcessId -gt 0) {
    <# Started by a finishing update cycle: let it exit and release its tasks first. #>
    Wait-Process -Id $WaitForProcessId -Timeout 900 -ErrorAction SilentlyContinue
}

$package = if (Test-PowerShell7MsixSupported) { 'Msix' } else { 'Msi' }

if ($existing -and $Upgrade) {
    try {
        $latest = Get-PowerShell7LatestStableVersion -Package $package -Architecture (Get-PowerShell7TargetArchitecture)
    } catch {
        Write-Warning "Could not check the latest PowerShell release: $($_.Exception.Message)"
        exit 0
    }

    $msix = Get-PowerShell7MsixInstall
    $legacy = @(if ($package -eq 'Msix') { Get-PowerShell7LegacyEntry })
    if ($msix) {
        $installedVersion = $msix.Version
        $decision = Get-PowerShell7UpgradeDecision -InstalledVersion $installedVersion -LatestVersion $latest.Version
    } else {
        $installedVersion = Get-PowerShell7InstalledVersion -PwshPath $existing
        if (-not $installedVersion) { $installedVersion = [version]'0.0' }
        $decision = Get-PowerShell7UpgradeDecision -InstalledVersion $installedVersion -LatestVersion $latest.Version -Legacy:($package -eq 'Msix')
    }
    if ($CheckOnly) {
        $check = Get-PowerShell7CheckOnlyResult -Package $package -InstalledVersion $installedVersion `
            -LatestVersion $latest.Version -LegacyEntries $legacy
        $color = if ($check.ExitCode -eq 100) { 'Yellow' } else { 'Green' }
        Write-Host $check.Message -ForegroundColor $color
        exit $check.ExitCode
    }
    if (-not $decision.NeedsUpgrade) {
        Write-Host $decision.Message -ForegroundColor Green
        exit 0
    }
    if (Test-BootUpdateCycleActive) {
        Write-Warning "An update cycle is in progress; PowerShell $($latest.Version) will be installed when it finishes."
        exit 3
    }

    Write-Host "Upgrading PowerShell $installedVersion to $($latest.Version)..." -ForegroundColor Cyan
    try {
        $installed = Complete-PowerShell7Install -Release $latest
    } catch {
        Write-Warning "PowerShell upgrade failed: $($_.Exception.Message)"
        exit 1
    }
    Write-Host "PowerShell $installedVersion -> $($installed.Version) installed." -ForegroundColor Green
    exit 0
}

Write-Host 'PowerShell 7 is required for parallel update execution.' -ForegroundColor Cyan
Write-Host 'Installing it machine-wide, side-by-side with Windows PowerShell 5.1...' -ForegroundColor Cyan
$latest = Get-PowerShell7LatestStableVersion -Package $package -Architecture (Get-PowerShell7TargetArchitecture)
$installed = Complete-PowerShell7Install -Release $latest
Write-Output $installed.PwshPath

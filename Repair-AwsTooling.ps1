#requires -Version 7.0
# ------------------------------------------------------------------------------
# File:        Repair-AwsTooling.ps1
# Description: 🔧 Audits and repairs AWS CLI v2 + AWS.Tools module installations
# Purpose:     Ensures consistent AWS tooling across fleet by:
#              - Detecting multiple aws.exe on PATH (the "roulette" problem)
#              - Installing/updating AWS CLI v2 from official MSI
#              - Syncing AWS.Tools modules via Update-AWSToolsModule -CleanUp
#              - Optionally removing legacy AWS CLI v1
#              Built for ops teams tired of "which aws did I just run?" surprises.
# Created:     2025-01-10
# Modified:    2026-01-12
# ------------------------------------------------------------------------------

<#
.SYNOPSIS
    Audits and repairs AWS CLI v2 and AWS.Tools PowerShell module installations.

.DESCRIPTION
    Detects common AWS tooling problems on Windows servers:
    - Multiple aws.exe binaries on PATH (causes unpredictable behavior)
    - Missing or outdated AWS CLI v2
    - Stale AWS.Tools module versions (version drift across modules)
    - Legacy AWSPowerShell monolithic modules still installed

    Runs in Audit mode by default for safety.  Remediate mode requires elevation
    and will install/update software.

.PARAMETER Mode
    Audit = report current state, no changes made.
    Remediate = fix issues found (install CLI, update modules, etc.).
    Default: Remediate

.PARAMETER MsiPath
    Optional path to a specific AWSCLIV2.msi file.  Use this to pin to a
    known-good version or install offline.  If not provided, downloads the
    latest from https://awscli.amazonaws.com/AWSCLIV2.msi

.PARAMETER SkipCli
    Skip all AWS CLI operations (install, uninstall, version detection).
    Useful if you only want to repair PowerShell modules.

.PARAMETER SkipModules
    Skip AWS.Tools module update/cleanup.  Useful if you only want to
    repair the CLI installation.

.PARAMETER UninstallCliV1
    Also uninstall legacy AWS CLI v1 if found in the registry.  Use with
    caution — some older automation may depend on v1-specific behavior.

.EXAMPLE
    .\Repair-AwsTooling.ps1 -Mode Audit

    Reports current AWS tooling state without making any changes.
    Safe to run anytime, no elevation required.

.EXAMPLE
    .\Repair-AwsTooling.ps1 -Mode Remediate -Verbose

    Fixes detected issues with verbose output.  Requires elevation.
    Installs CLI v2 if missing, updates all AWS.Tools modules.

.EXAMPLE
    .\Repair-AwsTooling.ps1 -Mode Remediate -UninstallCliV1 -SkipModules

    Installs CLI v2, removes CLI v1, skips PowerShell module updates.

.NOTES
    Requires:     PowerShell 7+, elevation for Remediate mode
    Side effects: Installs software, modifies system PATH (via MSI), removes old modules
    Idempotent:   Yes — safe to run multiple times
    
    The AWS.Tools.Installer module handles keeping all AWS.Tools.* modules at
    the same version and cleaning up old versions.  This is AWS's recommended
    approach per their documentation.

    Author:  Lars Rasmussen
    Version: 1.0.0
#>

[CmdletBinding()]
param(
    [ValidateSet('Audit', 'Remediate')]
    [string]$Mode = 'Remediate',

    [string]$MsiPath,

    [switch]$SkipCli,
    [switch]$SkipModules,

    [switch]$UninstallCliV1
)

$ErrorActionPreference = 'Stop'

# ---- HELPER FUNCTIONS ----

function Test-IsAdmin {
    # Returns $true if current process is running elevated (Administrator).
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-AwsOnPath {
    # Returns all aws.exe locations found via PATH resolution.
    # Multiple hits = "PATH roulette" — whichever one wins depends on PATH order.
    $hits = @()
    try { $hits = @(where.exe aws 2>$null) } catch {}
    $hits | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique
}

function Get-AwsCliV2Exe {
    # Returns path to AWS CLI v2 if installed at the standard location.
    # AWS MSI always installs to Program Files\Amazon\AWSCLIV2.
    $expected = Join-Path $env:ProgramFiles 'Amazon\AWSCLIV2\aws.exe'
    if (Test-Path $expected) { return $expected }
    return $null
}

# ---- CLI INSTALLATION ----

function Install-AwsCliV2 {
    # Downloads (if needed) and installs AWS CLI v2 via MSI.
    # Requires elevation.  Idempotent — MSI handles upgrade-in-place.
    if (-not (Test-IsAdmin)) {
        throw "CLI install/update requires elevation.  Re-run pwsh as Administrator."
    }

    $msi = $MsiPath
    if (-not $msi) {
        # AWS documents this endpoint in their official install guide.
        # https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
        $msi = Join-Path $env:TEMP 'AWSCLIV2.msi'
        Write-Verbose "Downloading AWS CLI v2 MSI to $msi"
        Invoke-WebRequest 'https://awscli.amazonaws.com/AWSCLIV2.msi' -OutFile $msi
    }

    if (-not (Test-Path $msi)) { throw "MSI not found: $msi" }

    Write-Verbose "Installing AWS CLI v2 from $msi"
    $msiArgs = @('/i', "`"$msi`"", '/qn', '/norestart')
    $proc = Start-Process msiexec.exe -Wait -PassThru -ArgumentList $msiArgs
    if ($proc.ExitCode -ne 0) { throw "msiexec failed.  ExitCode=$($proc.ExitCode)" }

    # Clean up downloaded MSI (but not user-provided one).
    if (-not $MsiPath -and (Test-Path $msi)) {
        Remove-Item $msi -Force -ErrorAction SilentlyContinue
    }
}

function Uninstall-AwsCliV1IfPresent {
    # Removes legacy AWS CLI v1 installations found in the registry.
    # Only runs if -UninstallCliV1 switch is set.  Best-effort — some
    # installers may not have clean uninstall strings.
    if (-not $UninstallCliV1) { return }

    if (-not (Test-IsAdmin)) {
        throw "CLI uninstall requires elevation.  Re-run pwsh as Administrator."
    }

    # Check both 64-bit and 32-bit registry hives.
    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $found = foreach ($root in $uninstallRoots) {
        Get-ItemProperty $root -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DisplayName -match '^AWS Command Line Interface\b' -or
                $_.DisplayName -match '^AWS CLI\b'
            }
    }

    foreach ($entry in $found) {
        if ($entry.UninstallString) {
            Write-Host "Uninstalling: $($entry.DisplayName)"
            $cmd = $entry.UninstallString

            if ($cmd -match 'MsiExec\.exe\s*/[IX]\{([0-9A-Fa-f\-]+)\}') {
                # MSI uninstall: invoke msiexec directly with structured args (no cmd.exe shell)
                $productCode = $Matches[1]
                $msiArgs = "/X{$productCode} /qn /norestart"
                Write-Host "  Running: msiexec.exe $msiArgs"
                Start-Process msiexec.exe -Wait -ArgumentList $msiArgs
            } else {
                Write-Host "  Skipping non-MSI uninstall (manual removal required): $cmd" -ForegroundColor Yellow
            }
        }
    }
}

# ---- POWERSHELL MODULE MAINTENANCE ----

function Repair-AwsToolsModules {
    # Uses AWS.Tools.Installer to keep all AWS.Tools.* modules in sync.
    # -CleanUp removes old versions, preventing the "which version loaded?" problem.
    # This is AWS's recommended approach for the modular SDK.
    if (-not (Get-Module -ListAvailable AWS.Tools.Installer)) {
        if ($Mode -eq 'Audit') { return }
        Write-Verbose "Installing AWS.Tools.Installer from PSGallery"
        Install-Module AWS.Tools.Installer -Repository PSGallery -Scope AllUsers -Force -AllowClobber
    }

    Import-Module AWS.Tools.Installer -Force

    if ($Mode -eq 'Remediate') {
        # Kill other PowerShell processes that might have AWS modules loaded.
        # Aggressive, but this runs during boot update — no user sessions should be active.
        $myPid = $PID
        $pwshProcs = Get-Process -Name 'pwsh', 'powershell' -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -ne $myPid }
        
        if ($pwshProcs) {
            Write-Host "  Killing $($pwshProcs.Count) other PowerShell process(es) to release module locks..."
            $pwshProcs | ForEach-Object {
                Write-Verbose "    Killing PID $($_.Id): $($_.ProcessName)"
                $_ | Stop-Process -Force -ErrorAction SilentlyContinue
            }
            Start-Sleep -Milliseconds 500  # Let file handles release
        }
        
        # Run update in SUBPROCESS — guarantees clean module state in child process.
        Write-Host "  Running AWS.Tools update in subprocess..."
        
        $scriptBlock = @'
$ErrorActionPreference = 'Stop'

function Test-AwsToolsSignedModuleDirectory {
    param(
        [Parameter(Mandatory)][string]$ModuleRoot,
        [Parameter(Mandatory)][string]$ModuleName
    )
    $requiredSignedFiles = @("$ModuleName.psd1", "$ModuleName.dll")
    if ($ModuleName -eq 'AWS.Tools.Common') { $requiredSignedFiles += 'AWSSDK.Core.dll' }
    else { $requiredSignedFiles += (($ModuleName -replace '^AWS\.Tools\.','AWSSDK.') + '.dll') }
    foreach ($relativePath in $requiredSignedFiles) {
        $path = Join-Path $ModuleRoot $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "The AWS module $ModuleName is missing signed file $relativePath."
        }
        $signature = Get-AuthenticodeSignature -LiteralPath $path
        if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or -not $signature.SignerCertificate) {
            throw "The AWS module file $relativePath has Authenticode status $($signature.Status)."
        }

        $certificate = $signature.SignerCertificate
        $commonName = $certificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
        $isAmazonOrganization = $certificate.Subject -match '(?:^|,\s*)O="?Amazon Web Services, Inc\."?(?:,|$)'
        if ($commonName -ne 'Amazon Web Services, Inc.' -or -not $isAmazonOrganization) {
            throw "The AWS module file $relativePath is signed by an unexpected publisher: $($certificate.Subject)"
        }
        $codeSigningOid = '1.3.6.1.5.5.7.3.3'
        $hasCodeSigningEku = @($certificate.Extensions | Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } |
            ForEach-Object { $_.EnhancedKeyUsages } | Where-Object { $_.Value -eq $codeSigningOid }).Count -gt 0
        if (-not $hasCodeSigningEku) { throw "The AWS module signer for $relativePath is not authorized for code signing." }

        $chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
        try {
            $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::Online
            $chain.ChainPolicy.RevocationFlag = [Security.Cryptography.X509Certificates.X509RevocationFlag]::EntireChain
            $chain.ChainPolicy.VerificationFlags = [Security.Cryptography.X509Certificates.X509VerificationFlags]::NoFlag
            $chain.ChainPolicy.UrlRetrievalTimeout = [timespan]::FromSeconds(30)
            if (-not $chain.Build($certificate)) {
                $why = ($chain.ChainStatus | ForEach-Object { $_.Status.ToString() } | Sort-Object -Unique) -join ', '
                throw "The AWS module signer chain failed validation for ${relativePath}: $why"
            }
        } finally { $chain.Dispose() }
    }
    return $true
}

function Get-AwsToolsDirectoryManifest {
    param([Parameter(Mandatory)][string]$ModuleRoot)
    $root = [IO.Path]::GetFullPath($ModuleRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    <# PowerShellGet creates PSGetModuleInfo.xml locally after package extraction;
       it is repository metadata, not package payload. Every package-supplied byte
       remains in the comparison. #>
    return @(Get-ChildItem -LiteralPath $root -Recurse -File -Force |
        Where-Object { $_.Name -ne 'PSGetModuleInfo.xml' } |
        ForEach-Object {
        [pscustomobject]@{
            RelativePath = $_.FullName.Substring($root.Length).TrimStart([IO.Path]::DirectorySeparatorChar).Replace('\','/')
            Length = [int64]$_.Length
            SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
    } | Sort-Object RelativePath)
}

function Test-AwsToolsDirectoryManifest {
    param(
        [Parameter(Mandatory)][string]$ModuleRoot,
        [Parameter(Mandatory)][object[]]$Expected
    )
    $actualJson = Get-AwsToolsDirectoryManifest -ModuleRoot $ModuleRoot | ConvertTo-Json -Depth 3 -Compress
    $expectedJson = @($Expected) | ConvertTo-Json -Depth 3 -Compress
    return $actualJson -ceq $expectedJson
}

function Get-VerifiedAwsToolsRolloverCandidate {
    $stageRoot = Join-Path ([IO.Path]::GetTempPath()) ('aws-tools-publisher-check-{0}' -f [guid]::NewGuid().ToString('N'))
    try {
        $repository = Get-PSRepository -Name PSGallery -ErrorAction Stop
        $source = ([string]$repository.SourceLocation).TrimEnd('/')
        if ($source -ine 'https://www.powershellgallery.com/api/v2') {
            throw "PSGallery resolves to an unexpected source: $source"
        }
        if (-not (Get-Command Update-AWSToolsModule -ErrorAction Stop).Parameters.ContainsKey('SkipPublisherCheck')) {
            throw 'The installed AWS.Tools.Installer does not expose the supported SkipPublisherCheck parameter.'
        }

        $moduleNames = @(Get-Module -ListAvailable 'AWS.Tools.*' |
            Where-Object { $_.Name -ne 'AWS.Tools.Installer' } |
            Select-Object -ExpandProperty Name -Unique)
        if ($moduleNames -notcontains 'AWS.Tools.Common') { $moduleNames += 'AWS.Tools.Common' }
        foreach ($moduleName in $moduleNames) {
            Save-Module -Name $moduleName -Path $stageRoot -Repository PSGallery -Force -ErrorAction Stop
        }

        $versions = [Collections.Generic.List[version]]::new()
        $manifests = @{}
        foreach ($moduleName in $moduleNames) {
            $moduleRoot = Get-ChildItem -LiteralPath (Join-Path $stageRoot $moduleName) -Directory -ErrorAction Stop |
                Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
            if (-not $moduleRoot) { throw "The staged $moduleName package has no version directory." }
            if (-not (Test-AwsToolsSignedModuleDirectory -ModuleRoot $moduleRoot.FullName -ModuleName $moduleName)) {
                throw "Signature verification did not succeed for staged $moduleName."
            }
            $manifests[$moduleName] = @(Get-AwsToolsDirectoryManifest -ModuleRoot $moduleRoot.FullName)
            $versions.Add([version]$moduleRoot.Name)
        }
        $distinctVersions = @($versions | Sort-Object -Unique)
        if ($distinctVersions.Count -ne 1) {
            throw "The staged AWS.Tools modules do not have one synchronized version: $($distinctVersions -join ', ')."
        }
        return [pscustomobject]@{ Version=$distinctVersions[0]; ModuleNames=[string[]]$moduleNames; Manifests=$manifests }
    } finally {
        if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Test-AwsToolsPublisherMismatchMessage {
    param([Parameter(Mandatory)][string]$Message)
    $pattern = "(?s)Authenticode issuer '(?<NewIssuer>[^']+)' of the new module '(?<NewModule>AWS\.Tools\.[^']+)'.+?is not matching with the authenticode issuer '(?<OldIssuer>[^']+)' of the previously-installed module '(?<OldModule>AWS\.Tools\.[^']+)'"
    $match = [regex]::Match($Message, $pattern)
    if (-not $match.Success -or $match.Groups['NewModule'].Value -ne $match.Groups['OldModule'].Value) { return $false }
    foreach ($issuer in @($match.Groups['NewIssuer'].Value, $match.Groups['OldIssuer'].Value)) {
        $amazonCn = $issuer -match '(?:^|,\s*)CN="?Amazon Web Services, Inc\."?(?:,|$)'
        $amazonOrg = $issuer -match '(?:^|,\s*)O="?Amazon Web Services, Inc\."?(?:,|$)'
        if (-not $amazonCn -or -not $amazonOrg) { return $false }
    }
    return $true
}

try {
    Import-Module AWS.Tools.Installer -Force -ErrorAction Stop
    try {
        Update-AWSToolsModule -CleanUp -Force -Confirm:$false -ErrorAction Stop
    } catch {
        $publisherMismatch = Test-AwsToolsPublisherMismatchMessage -Message $_.Exception.Message
        if (-not $publisherMismatch) { throw }
        Write-Warning 'AWS.Tools publisher certificate rollover detected; validating the current AWS.Tools.Common package before the supported bypass.'
        $candidate = Get-VerifiedAwsToolsRolloverCandidate
        Update-AWSToolsModule -RequiredVersion $candidate.Version -Force -SkipPublisherCheck -Confirm:$false -ErrorAction Stop
        foreach ($moduleName in $candidate.ModuleNames) {
            $installedCopies = @(Get-Module -ListAvailable $moduleName | Where-Object Version -eq $candidate.Version)
            if (-not $installedCopies.Count) { throw "The target AWS module $moduleName $($candidate.Version) was not installed. Old versions were retained." }
            foreach ($installed in $installedCopies) {
                $signed = Test-AwsToolsSignedModuleDirectory -ModuleRoot $installed.ModuleBase -ModuleName $moduleName
                $byteIdentical = Test-AwsToolsDirectoryManifest -ModuleRoot $installed.ModuleBase -Expected $candidate.Manifests[$moduleName]
                if (-not $signed -or -not $byteIdentical) {
                    throw "Installed AWS module verification failed for $moduleName $($candidate.Version) at $($installed.ModuleBase). Old versions were retained."
                }
            }
        }
        Uninstall-AWSToolsModule -ExceptVersion $candidate.Version -Force -Confirm:$false -ErrorAction Stop
    }
    exit 0
}
catch {
    Write-Warning "AWS.Tools update error: $_"
    exit 1
}
'@
        
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($scriptBlock))
        $proc = Start-Process pwsh.exe -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedCommand
        ) -Wait -PassThru -NoNewWindow
        
        if ($proc.ExitCode -ne 0) {
            throw "AWS.Tools subprocess failed (exit code $($proc.ExitCode))"
        }
    }
}

# ---- MAIN EXECUTION ----

Write-Host "== AWS CLI (path resolution) =="
Write-Host "Mode: $Mode"

$awsHits = Get-AwsOnPath
$awsV2 = Get-AwsCliV2Exe

# Report what's on PATH.
$awsHits | ForEach-Object { Write-Host "  aws on PATH: $_" }
if (-not $awsHits) { Write-Host "  aws on PATH: <none>" }

# Multiple aws.exe = unpredictable behavior depending on PATH order.
if ($awsHits.Count -gt 1) {
    Write-Warning "Multiple aws.exe found on PATH — command resolution is non-deterministic."
}

# Check for / install CLI v2.
if (-not $awsV2) {
    Write-Host "  AWS CLI v2 not found at standard location."
    if ($Mode -eq 'Remediate' -and -not $SkipCli) {
        Install-AwsCliV2
        $awsV2 = Get-AwsCliV2Exe
    }
}

if ($awsV2) {
    $ver = & $awsV2 --version 2>$null
    Write-Host "  AWS CLI v2: $awsV2"
    Write-Host "  Version: $ver"
}

# Remove legacy CLI v1 if requested.
if ($Mode -eq 'Remediate' -and -not $SkipCli) {
    Uninstall-AwsCliV1IfPresent
}

Write-Host "`n== AWS Tools for PowerShell modules =="

if (-not $SkipModules) {
    # Warn about legacy monolithic modules — we don't auto-remove them because
    # some older scripts may still depend on them.
    $legacy = Get-Module -ListAvailable AWSPowerShell, AWSPowerShell.NetCore -ErrorAction SilentlyContinue
    if ($legacy) {
        Write-Warning "Legacy AWSPowerShell* modules present (consider manual removal):"
        $legacy | ForEach-Object { Write-Host "  $($_.Name) v$($_.Version) @ $($_.ModuleBase)" }
    }

    Repair-AwsToolsModules
}

Write-Host "`nDone."

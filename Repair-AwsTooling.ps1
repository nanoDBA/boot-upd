#requires -Version 5.1
# ------------------------------------------------------------------------------
# File:        Repair-AwsTooling.ps1
# Description: Audits and repairs AWS CLI v2 + AWS.Tools module installations
# Purpose:     Ensures consistent AWS tooling across fleet by:
#              - Detecting multiple aws.exe on PATH (the "roulette" problem)
#              - Installing/updating AWS CLI v2 from official MSI
#              - Syncing AWS.Tools modules via Update-AWSToolsModule -CleanUp
#              - Optionally removing legacy AWS CLI v1
#              Built for ops teams tired of "which aws did I just run?" surprises.
# Created:     2025-01-10
# Modified:    2026-07-21
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
    caution - some older automation may depend on v1-specific behavior.

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
    Idempotent:   Yes - safe to run multiple times
    
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
    # Multiple hits = "PATH roulette" - whichever one wins depends on PATH order.
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

function Get-AwsPowerShellModuleInventory {
    # Preserve exact installation identities. Name/version alone is insufficient
    # when AllUsers and CurrentUser (often cloud-synced) roots overlap.
    $modules = @(Get-Module -ListAvailable AWS.Tools.*, AWSPowerShell, AWSPowerShell.NetCore -ErrorAction SilentlyContinue)
    return @($modules | ForEach-Object {
        [pscustomobject]@{
            Family     = if ($_.Name -like 'AWS.Tools.*') { 'Modular' } else { 'Legacy' }
            Name       = $_.Name
            Version    = [version]$_.Version
            ModuleBase = [IO.Path]::GetFullPath($_.ModuleBase)
        }
    } | Sort-Object Family,Name,Version,ModuleBase -Unique)
}

# ---- CLI INSTALLATION ----

function Install-AwsCliV2 {
    # Downloads (if needed) and installs AWS CLI v2 via MSI.
    # Requires elevation.  Idempotent - MSI handles upgrade-in-place.
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
    # Only runs if -UninstallCliV1 switch is set.  Best-effort - some
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
        # Run update in SUBPROCESS - guarantees clean module state in child process.
        # Do not terminate other PowerShell sessions to release module locks. If an
        # old module is genuinely locked, verified installation may still succeed
        # and cleanup will fail closed while retaining that old version.
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

function Get-AwsToolsInventory {
    return @(Get-Module -ListAvailable 'AWS.Tools.*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'AWS.Tools.Installer' } |
        ForEach-Object {
            [pscustomobject]@{
                Name=$_.Name; Version=[version]$_.Version
                ModuleBase=[IO.Path]::GetFullPath($_.ModuleBase)
            }
        } | Sort-Object Name,Version,ModuleBase -Unique)
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

function Invoke-VerifiedAwsToolsCleanup {
    param(
        [Parameter(Mandatory)][version]$ExceptVersion,
        [Parameter(Mandatory)][string[]]$ModuleNames
    )
    $cleanupRecords = @(Uninstall-AWSToolsModule -ExceptVersion $ExceptVersion -Force -Confirm:$false -ErrorAction Continue *>&1)
    $benignAlreadyAbsent = 0
    $unexpectedErrors = [Collections.Generic.List[object]]::new()
    foreach ($record in $cleanupRecords) {
        if ($record -is [Management.Automation.ErrorRecord]) {
            $isAlreadyAbsent = Test-AwsToolsAlreadyAbsentCleanupError -Record $record
            if ($isAlreadyAbsent) { $benignAlreadyAbsent++; continue }
            $unexpectedErrors.Add($record)
            continue
        }
        # Provider chatter is intentionally suppressed; the verified summary below
        # is the stable user-facing contract.
    }
    if ($unexpectedErrors.Count) {
        throw "AWS.Tools cleanup reported unexpected error(s): $($unexpectedErrors -join '; ')"
    }
    if ($benignAlreadyAbsent) {
        Write-Host "AWS.Tools cleanup: $benignAlreadyAbsent already-absent package record(s) ignored."
    }

    $stale = @($ModuleNames | ForEach-Object {
        Get-Module -ListAvailable $_ | Where-Object Version -ne $ExceptVersion
    } | Sort-Object Name,Version,ModuleBase -Unique)
    if ($stale.Count) {
        Write-Warning ("Verified AWS.Tools $ExceptVersion is installed; locked or independently installed older copies were retained:`n  " +
            (($stale | ForEach-Object { "$($_.Name) v$($_.Version) @ $($_.ModuleBase)" }) -join "`n  "))
    } else {
        Write-Host "AWS.Tools cleanup verified: no older managed module copies remain."
    }
}

function Test-AwsToolsAlreadyAbsentCleanupError {
    param([Parameter(Mandatory)][Management.Automation.ErrorRecord]$Record)
    # PowerShellGet changes FullyQualifiedErrorId and InvocationInfo across
    # versions. The exact provider message is stable; constrain it to an
    # AWS.Tools module name and rely on the following exact-path inventory to
    # report any copy that truly remains.
    return $Record.Exception.Message -match "^No match was found for the specified search criteria and module names 'AWS\.Tools\.[A-Za-z0-9.]+'\.$"
}

try {
    Import-Module AWS.Tools.Installer -Force -ErrorAction Stop
    $before = @(Get-AwsToolsInventory)
    $moduleNames = @($before | Select-Object -ExpandProperty Name -Unique)
    if ($moduleNames -notcontains 'AWS.Tools.Common') { $moduleNames += 'AWS.Tools.Common' }
    $usedPublisherRollover = $false
    try {
        $null = @(Update-AWSToolsModule -Force -Confirm:$false -ErrorAction Stop *>&1)
    } catch {
        $publisherMismatch = Test-AwsToolsPublisherMismatchMessage -Message $_.Exception.Message
        if (-not $publisherMismatch) { throw }
        Write-Warning 'AWS.Tools publisher certificate rollover detected; validating Amazon-signed packages before the narrow supported bypass.'
        $candidate = Get-VerifiedAwsToolsRolloverCandidate
        $null = @(Update-AWSToolsModule -RequiredVersion $candidate.Version -Force -SkipPublisherCheck -Confirm:$false -ErrorAction Stop *>&1)
        $moduleNames = @($candidate.ModuleNames)
        $usedPublisherRollover = $true
    }

    $afterInstall = @(Get-AwsToolsInventory)
    $common = @($afterInstall | Where-Object Name -eq 'AWS.Tools.Common' | Sort-Object Version -Descending)
    if (-not $common.Count) { throw 'AWS.Tools.Common was not installed; old versions were retained.' }
    $targetVersion = [version]$common[0].Version
    foreach ($moduleName in $moduleNames) {
        $installedCopies = @($afterInstall | Where-Object { $_.Name -eq $moduleName -and $_.Version -eq $targetVersion })
        if (-not $installedCopies.Count) { throw "The target AWS module $moduleName $targetVersion was not installed. Old versions were retained." }
        foreach ($installed in $installedCopies) {
            $signed = Test-AwsToolsSignedModuleDirectory -ModuleRoot $installed.ModuleBase -ModuleName $moduleName
            if (-not $signed) { throw "Signature verification failed for $moduleName $targetVersion at $($installed.ModuleBase)." }
            if ($usedPublisherRollover) {
                $byteIdentical = Test-AwsToolsDirectoryManifest -ModuleRoot $installed.ModuleBase -Expected $candidate.Manifests[$moduleName]
                if (-not $byteIdentical) { throw "Installed AWS module differs from the verified package: $moduleName $targetVersion at $($installed.ModuleBase)." }
            }
        }
    }
    Invoke-VerifiedAwsToolsCleanup -ExceptVersion $targetVersion -ModuleNames $moduleNames
    $after = @(Get-AwsToolsInventory)
    $updatedNames = @($moduleNames | Where-Object {
        $name = $_
        $old = @($before | Where-Object Name -eq $name | Sort-Object Version -Descending | Select-Object -First 1)
        -not $old.Count -or [version]$old[0].Version -lt $targetVersion
    })
    Write-Host "AWS.Tools verified: $($moduleNames.Count) module(s) at v$targetVersion; $($updatedNames.Count) installed/updated; $($after.Count) exact path/version record(s)."
    exit 0
}
catch {
    Write-Warning "AWS.Tools update error: $_"
    exit 1
}
'@
        
        $engine = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
        # The verification program is deliberately substantial and exceeds the
        # Windows process command-line limit when Base64-encoded. Execute it from
        # a random temporary file instead; it contains code only, never secrets.
        $childPath = Join-Path ([IO.Path]::GetTempPath()) ('Repair-AwsTools-child-{0}.ps1' -f [guid]::NewGuid().ToString('N'))
        try {
            # UTF-8 BOM keeps Windows PowerShell 5.1 parsing deterministic.
            [IO.File]::WriteAllText($childPath, $scriptBlock, [Text.UTF8Encoding]::new($true))
            $proc = Start-Process $engine -ArgumentList @(
                '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$childPath`""
            ) -Wait -PassThru -NoNewWindow

            if ($proc.ExitCode -ne 0) {
                throw "AWS.Tools subprocess failed (exit code $($proc.ExitCode))"
            }
        } finally {
            Remove-Item -LiteralPath $childPath -Force -ErrorAction SilentlyContinue
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
    Write-Warning "Multiple aws.exe found on PATH - command resolution is non-deterministic."
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
    # Warn about legacy monolithic modules - we don't auto-remove them because
    # some older scripts may still depend on them.
    $inventory = @(Get-AwsPowerShellModuleInventory)
    $legacy = @($inventory | Where-Object Family -eq 'Legacy')
    $modular = @($inventory | Where-Object Family -eq 'Modular')
    if ($legacy) {
        Write-Warning "Legacy AWSPowerShell modules are isolated from modular maintenance and retained for compatibility ($($legacy.Count) exact installation record(s)):"
        $legacy | ForEach-Object { Write-Host "  $($_.Name) v$($_.Version) @ $($_.ModuleBase)" }
    }

    if ($modular) {
        Write-Host "  Modular inventory: $($modular.Count) exact installation record(s), $(@($modular.Name | Sort-Object -Unique).Count) module name(s)."
    } else {
        Write-Host '  Modular inventory: no AWS.Tools modules installed yet.'
    }

    Repair-AwsToolsModules
}

Write-Host "`nDone."

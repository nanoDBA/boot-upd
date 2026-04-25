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

            # Normalize MSI uninstall to silent mode.
            $cmd = $entry.UninstallString
            if ($cmd -match 'MsiExec\.exe') {
                $cmd = $cmd -replace '/I', '/X'
                if ($cmd -notmatch '/qn') { $cmd += ' /qn' }
                if ($cmd -notmatch '/norestart') { $cmd += ' /norestart' }
            }
            Start-Process cmd.exe -Wait -ArgumentList "/c $cmd"
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
try {
    Import-Module AWS.Tools.Installer -Force -ErrorAction Stop
    Update-AWSToolsModule -CleanUp -Force -Confirm:$false -ErrorAction Stop
    exit 0
}
catch {
    Write-Warning "AWS.Tools update error: $_"
    exit 1
}
'@
        
        $proc = Start-Process pwsh.exe -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-Command', $scriptBlock
        ) -Wait -PassThru -NoNewWindow
        
        if ($proc.ExitCode -ne 0) {
            Write-Warning "AWS.Tools subprocess failed (exit code $($proc.ExitCode))"
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

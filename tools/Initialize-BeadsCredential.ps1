#requires -Version 7.0
<#
.SYNOPSIS
    Configure secure Windows Credential Manager access for the beads client.

.DESCRIPTION
    Reuses an existing generic credential when present. For a new credential,
    prompts for the Dolt username and twice for the password without echo,
    verifies the password entries match, and stores both in a DPAPI-protected
    Windows Credential Manager generic credential. Existing credentials are
    never overwritten unless -Replace is explicitly supplied.

    The secret is never printed, passed in process arguments, or stored in an
    environment variable. The repository stores only the non-secret credential
    target name in its local Git configuration.

.PARAMETER Target
    Windows Credential Manager target. Defaults to the repository-local
    beads.credentialTarget setting, then BEADS_DOLT_PASSWORD.

.PARAMETER Replace
    Explicitly replace an existing credential after a double no-echo prompt.

.PARAMETER Username
    Central Dolt username to store in the credential. Defaults to the local
    beads metadata username, then root.

.EXAMPLE
    ./tools/Initialize-BeadsCredential.ps1

.EXAMPLE
    ./tools/Initialize-BeadsCredential.ps1 -Replace
#>
[CmdletBinding()]
param(
    [string]$Target,

    [string]$Username,

    [switch]$Replace
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent

function Initialize-BetterCredentialsModule {
    if (-not (Get-Module -ListAvailable -Name BetterCredentials)) {
        $installModule = Get-Command Install-Module -ErrorAction SilentlyContinue
        if (-not $installModule) {
            throw 'BetterCredentials is not installed and Install-Module is unavailable. Install PowerShellGet, then rerun this command.'
        }

        Install-Module -Name BetterCredentials -Repository PSGallery -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }

    Import-Module BetterCredentials -ErrorAction Stop
}

function Get-DefaultDoltUsername {
    $metadataPath = Join-Path $repoRoot '.beads\metadata.json'
    if (Test-Path -LiteralPath $metadataPath) {
        try {
            $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace($metadata.dolt_server_user)) {
                return [string]$metadata.dolt_server_user
            }
        }
        catch {
            Write-Verbose "Could not read Dolt username from ${metadataPath}: $($_.Exception.Message)"
        }
    }

    return 'root'
}

function Assert-DoltUsername {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') {
        throw 'Dolt username must contain only letters, numbers, dot, underscore, or hyphen.'
    }
}

function Test-SecureStringEqual {
    param(
        [Parameter(Mandatory)]
        [Security.SecureString]$First,

        [Parameter(Mandatory)]
        [Security.SecureString]$Second
    )

    $firstBstr = [IntPtr]::Zero
    $secondBstr = [IntPtr]::Zero
    try {
        $firstBstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($First)
        $secondBstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Second)
        if ($First.Length -ne $Second.Length) {
            return $false
        }

        for ($index = 0; $index -lt $First.Length; $index++) {
            $offset = $index * 2
            if ([Runtime.InteropServices.Marshal]::ReadInt16($firstBstr, $offset) -ne
                [Runtime.InteropServices.Marshal]::ReadInt16($secondBstr, $offset)) {
                return $false
            }
        }
        return $true
    }
    finally {
        if ($firstBstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($firstBstr)
        }
        if ($secondBstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secondBstr)
        }
    }
}

function Get-StoredGenericCredential {
    param(
        [Parameter(Mandatory)]
        [string]$Target
    )

    try {
        return [CredentialManagement.Store]::Load($Target, [CredentialManagement.CredentialType]::Generic, $false)
    }
    catch {
        if ($_.Exception.InnerException.NativeErrorCode -eq 1168) {
            return $null
        }
        throw
    }
}

if ([string]::IsNullOrWhiteSpace($Target)) {
    $Target = & git -C $repoRoot config --local --get beads.credentialTarget
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Target)) {
        $Target = 'BEADS_DOLT_PASSWORD'
    }
}

Initialize-BetterCredentialsModule

$existingCredential = Get-StoredGenericCredential -Target $Target
if ($existingCredential -and -not $Replace) {
    Write-Output "Credential target '$Target' already exists; preserving its stored username and password."
}
else {
    $secret = $null
    $confirmation = $null
    $credential = $null
    try {
        if ([string]::IsNullOrWhiteSpace($Username)) {
            $defaultUsername = Get-DefaultDoltUsername
            $Username = Read-Host "Enter the central beads Dolt username [$defaultUsername]"
            if ([string]::IsNullOrWhiteSpace($Username)) {
                $Username = $defaultUsername
            }
        }
        Assert-DoltUsername -Value $Username

        $secret = Read-Host "Enter the central beads Dolt password for '$Target'" -AsSecureString
        $confirmation = Read-Host 'Confirm the password' -AsSecureString
        if ($secret.Length -eq 0) {
            throw 'Empty password; no credential was stored.'
        }
        if (-not (Test-SecureStringEqual -First $secret -Second $confirmation)) {
            throw 'Passwords do not match; no credential was stored.'
        }

        $credential = [PSCredential]::new($Username, $secret)
        BetterCredentials\Set-Credential `
            -Credential $credential `
            -Target $Target `
            -Type Generic `
            -Persistence LocalComputer `
            -Description 'boot-upd central beads Dolt password' | Out-Null
    }
    finally {
        if ($secret) {
            $secret.Dispose()
        }
        if ($confirmation) {
            $confirmation.Dispose()
        }
        $credential = $null
    }

    Write-Output "Credential target '$Target' stored in Windows Credential Manager (value not printed)."
}

& git -C $repoRoot config --local beads.credentialTarget $Target
if ($LASTEXITCODE -ne 0) {
    throw 'Could not write the repository-local beads.credentialTarget setting.'
}
& git -C $repoRoot config --local --unset-all beads.credentialUser 2>$null

$existingCredential = $null
Write-Output 'Repository credential target configured. Verifying central beads access...'
& (Join-Path $PSScriptRoot 'Invoke-Beads.ps1') status --json | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Credential was configured, but the beads connectivity check failed with exit code $LASTEXITCODE."
}
Write-Output 'Central beads access verified.'

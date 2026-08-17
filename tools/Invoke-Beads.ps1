#requires -Version 7.0
<#
.SYNOPSIS
    Run bd with the central Dolt username and password from Windows Credential Manager.

.DESCRIPTION
    Retrieves the generic credential identified by the repository-local
    beads.credentialTarget Git setting, makes its username and password available
    only for the lifetime of the bd invocation, and clears both in a finally block.

    The password is never printed, passed on the command line, or persisted as
    a User/Machine environment variable.

.EXAMPLE
    ./tools/Invoke-Beads.ps1 ready

.EXAMPLE
    ./tools/Invoke-Beads.ps1 show boot-upd-123
#>
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

$credentialTarget = & git -C $repoRoot config --local --get beads.credentialTarget
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($credentialTarget)) {
    throw 'Missing repository-local beads.credentialTarget setting. Run: ./tools/Initialize-BeadsCredential.ps1'
}

Initialize-BetterCredentialsModule

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

$credential = Get-StoredGenericCredential -Target $credentialTarget
if (-not $credential) {
    throw "Windows Credential Manager has no generic credential for '$credentialTarget'. Run: ./tools/Initialize-BeadsCredential.ps1"
}

$exitCode = 1
try {
    $doltUsername = $credential.UserName
    if ([string]::IsNullOrWhiteSpace($doltUsername)) {
        throw "Windows Credential Manager credential '$credentialTarget' has no Dolt username. Run: ./tools/Initialize-BeadsCredential.ps1 -Replace"
    }

    $env:BEADS_DOLT_SERVER_USER = $doltUsername
    $env:BEADS_DOLT_PASSWORD = $credential.GetNetworkCredential().Password
    & bd -C $repoRoot @args
    $exitCode = $LASTEXITCODE
}
finally {
    Remove-Item Env:BEADS_DOLT_SERVER_USER -ErrorAction SilentlyContinue
    Remove-Item Env:BEADS_DOLT_PASSWORD -ErrorAction SilentlyContinue
    $credential = $null
}

exit $exitCode

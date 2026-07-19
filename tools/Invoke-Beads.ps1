#requires -Version 7.0
#requires -Modules BetterCredentials
<#
.SYNOPSIS
    Run bd with the central Dolt password from Windows Credential Manager.

.DESCRIPTION
    Retrieves the generic credential identified by the repository-local
    beads.credentialUser Git setting, makes its password available only for the
    lifetime of the bd invocation, and clears it in a finally block.

    The password is never printed, passed on the command line, or persisted as
    a User/Machine environment variable.

.EXAMPLE
    ./tools/Invoke-Beads.ps1 ready

.EXAMPLE
    ./tools/Invoke-Beads.ps1 show boot-upd-123
#>
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent

$credentialUser = & git -C $repoRoot config --local --get beads.credentialUser
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($credentialUser)) {
    throw 'Missing repository-local beads.credentialUser setting. Configure it with: git config --local beads.credentialUser BEADS_DOLT_PASSWORD'
}

Import-Module BetterCredentials -ErrorAction Stop
$credential = BetterCredentials\Get-Credential -UserName $credentialUser -GenericCredentials
if (-not $credential) {
    throw "Windows Credential Manager has no generic credential for '$credentialUser'."
}

$exitCode = 1
try {
    $env:BEADS_DOLT_PASSWORD = $credential.GetNetworkCredential().Password
    & bd -C $repoRoot @args
    $exitCode = $LASTEXITCODE
}
finally {
    Remove-Item Env:BEADS_DOLT_PASSWORD -ErrorAction SilentlyContinue
}

exit $exitCode

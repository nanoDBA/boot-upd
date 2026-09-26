#requires -Version 7.0
<#
.SYNOPSIS
    Resolve the disposable lab guest's password durably, not from a process variable.

.DESCRIPTION
    Dot-source this. It provides Get-BootUpdLabPassword and Set-BootUpdLabPassword.

    The lab guest's password used to live only in BOOTUPD_LAB_PASSWORD, set by hand in
    whichever shell happened to be driving a run. That is a process variable, so it died
    with the session that set it, and every lab script then failed on a guest that was
    otherwise perfectly healthy. Worse, recovery looked possible and was not: the rendered
    answer file left behind under C:\HyperV still held a password, but the ISO had been
    rebuilt after the guest was installed, so the value on disk was a LATER render than the
    one the guest actually took. It matched itself and matched nothing in the VM. The guest
    had to be rebuilt to get back in.

    So the password belongs in Windows Credential Manager, which is where this project's
    other credentials already live and which survives the session that created it. The
    environment variable still wins when it is set, because a one-off override is useful and
    because existing invocations keep working.

    This is a throwaway credential for a disposable guest, and it is still handled as a
    credential: never written to a tracked file, never passed on a command line, never
    logged. That rule does not bend for low-value secrets, because the habit is the control.
#>

$script:BootUpdLabCredentialTarget = 'boot-upd-lab-guest'

function Initialize-BootUpdLabCredentialModule {
    if (-not (Get-Module -ListAvailable -Name BetterCredentials)) {
        if (-not (Get-Command Install-Module -ErrorAction SilentlyContinue)) {
            throw 'BetterCredentials is not installed and Install-Module is unavailable.'
        }
        Install-Module -Name BetterCredentials -Repository PSGallery -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }
    Import-Module BetterCredentials -ErrorAction Stop
}

function ConvertTo-BootUpdLabSecureString {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Legacy environment, ISO, and autologon inputs are already plaintext; convert immediately to a SecureString without logging.')]
    param([Parameter(Mandatory)][string]$Value)

    ConvertTo-SecureString $Value -AsPlainText -Force
}

function Get-BootUpdLabStoredCredential {
    param([Parameter(Mandatory)][string]$Target)

    try {
        return [CredentialManagement.Store]::Load($Target, [CredentialManagement.CredentialType]::Generic, $false)
    } catch {
        # 1168 is ERROR_NOT_FOUND: an absent credential is expected during first-time setup.
        if ($_.Exception.InnerException.NativeErrorCode -eq 1168) { return $null }
        throw
    }
}

function Set-BootUpdLabStoredCredential {
    param(
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory)][string]$Target
    )

    BetterCredentials\Set-Credential -Credential $Credential -Target $Target -Type Generic -Persistence LocalComputer | Out-Null
}

function Get-BootUpdLabPassword {
    <# Returns the plain password, or $null when nothing is stored. Order: the environment
       variable first as a deliberate override, then Credential Manager. #>
    [CmdletBinding()]
    param([string]$Target = $script:BootUpdLabCredentialTarget)

    if ($env:BOOTUPD_LAB_PASSWORD) { return $env:BOOTUPD_LAB_PASSWORD }

    Initialize-BootUpdLabCredentialModule
    $stored = Get-BootUpdLabStoredCredential -Target $Target
    if (-not $stored) { return $null }
    return $stored.GetNetworkCredential().Password
}

function Set-BootUpdLabPassword {
    <# Stores the guest password for future sessions. With -Generate, invents one. It does not
       write the plaintext to the pipeline unless -RevealGeneratedPassword is explicitly used.
       Existing credentials are preserved unless -Replace is explicitly used.

       The generated alphabet excludes characters that would have to be escaped somewhere in
       the chain this password travels: an unattend XML document, a PowerShell string, and a
       net user command line. A password that is strong but unquotable fails the build in a
       way that looks like a Windows problem. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'Public lab credential interface preserves the existing Password, UserName, and Generate parameters for credential provisioning.')]
    [CmdletBinding()]
    param(
        [string]$Password,
        [switch]$Generate,
        [switch]$Replace,
        [switch]$RevealGeneratedPassword,
        [int]$Length = 28,
        [string]$UserName = 'updtest',
        [string]$Target = $script:BootUpdLabCredentialTarget
    )

    if ($Generate) {
        if ($Password) { throw 'Pass -Password or -Generate, not both.' }
        if ($Length -lt 1) { throw '-Length must be greater than zero.' }
        $alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789-_'
        $bytes = [byte[]]::new($Length)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        $Password = -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
    }
    if (-not $Password) { throw 'Nothing to store: pass -Password or -Generate.' }
    if ($RevealGeneratedPassword -and -not $Generate) {
        throw '-RevealGeneratedPassword is only valid with -Generate.'
    }

    Initialize-BootUpdLabCredentialModule
    $existing = Get-BootUpdLabStoredCredential -Target $Target
    if ($existing -and -not $Replace) {
        throw "A lab credential already exists for target '$Target'. It was left unchanged; pass -Replace only when intentionally rotating or migrating the guest credential."
    }

    $credential = [System.Management.Automation.PSCredential]::new(
        $UserName, (ConvertTo-BootUpdLabSecureString $Password))
    Set-BootUpdLabStoredCredential -Credential $credential -Target $Target
    if ($Generate -and $RevealGeneratedPassword) { return $Password }
}

function Initialize-BootUpdLabCredential {
    <# Ensures the default lab guest credential exists for future sessions. Existing stored
       credentials are reused unchanged. This deliberately reads Credential Manager directly,
       so BOOTUPD_LAB_PASSWORD is never persisted as a side effect. #>
    [CmdletBinding()]
    param(
        [string]$Target = $script:BootUpdLabCredentialTarget,
        [string]$UserName = 'updtest',
        [int]$Length = 28,
        [switch]$PassThru
    )

    Initialize-BootUpdLabCredentialModule
    $existing = Get-BootUpdLabStoredCredential -Target $Target
    $created = $false
    if (-not $existing) {
        Set-BootUpdLabPassword -Generate -Length $Length -UserName $UserName -Target $Target
        $created = $true
    }

    if ($PassThru) {
        return [pscustomobject]@{
            Created = $created
            Target  = $Target
        }
    }
}

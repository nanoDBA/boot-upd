#requires -Version 7.0
#requires -RunAsAdministrator
<#
.SYNOPSIS
    Configure or remove the Boot Update Cycle notification webhook.

.DESCRIPTION
    Prompts without echo, validates an HTTPS webhook URL, and stores it in
    ProgramData with an ACL limited to SYSTEM and local Administrators. The URL
    is never placed in Task Scheduler arguments, process arguments, or Git.

.PARAMETER Remove
    Remove the stored webhook configuration.
#>
[CmdletBinding()]
param([switch]$Remove)

$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:ProgramData 'BootUpdateCycle'
$secretPath = Join-Path $installDir 'webhook-url.secret'

function Set-InstallDirectoryAcl {
    if (-not (Test-Path -LiteralPath $installDir)) {
        $null = New-Item -ItemType Directory -Path $installDir -Force
    }
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $users = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    foreach ($sid in @($administrators, $system)) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $sid, [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance, $propagation, $allow
        ))
    }
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $users, [Security.AccessControl.FileSystemRights]::ReadAndExecute,
        $inheritance, $propagation, $allow
    ))
    $acl.SetOwner($administrators)
    Set-Acl -LiteralPath $installDir -AclObject $acl
}

function New-RestrictedFileAcl {
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    foreach ($sid in @($administrators, $system)) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $sid, [Security.AccessControl.FileSystemRights]::FullControl, $allow
        ))
    }
    $acl.SetOwner($administrators)
    return $acl
}

Set-InstallDirectoryAcl
if ($Remove) {
    if (Test-Path -LiteralPath $secretPath) {
        Remove-Item -LiteralPath $secretPath -Force
        Write-Output 'Boot Update Cycle webhook configuration removed.'
    } else {
        Write-Output 'No Boot Update Cycle webhook configuration exists.'
    }
    exit 0
}

$secureUrl = Read-Host 'Enter the HTTPS webhook URL' -AsSecureString
$bstr = [IntPtr]::Zero
$url = $null
$tempPath = Join-Path $installDir ('.webhook-url.{0}.tmp' -f [guid]::NewGuid().ToString('N'))
try {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureUrl)
    $url = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    if ([string]::IsNullOrWhiteSpace($url) -or $url -notmatch '^https://') {
        throw 'Webhook URL must be a non-empty HTTPS URL.'
    }

    $null = New-Item -ItemType File -Path $tempPath -Force
    $fileAcl = New-RestrictedFileAcl
    Set-Acl -LiteralPath $tempPath -AclObject $fileAcl
    [IO.File]::WriteAllText($tempPath, $url, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tempPath -Destination $secretPath -Force
    Set-Acl -LiteralPath $secretPath -AclObject $fileAcl
} finally {
    if ($bstr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    $url = $null
    if ($null -ne $secureUrl) { $secureUrl.Dispose() }
    if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

Write-Output "Webhook configured at '$secretPath' (value not printed)."

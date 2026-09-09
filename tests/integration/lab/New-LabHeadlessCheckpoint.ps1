#requires -Version 7.0
<#
.SYNOPSIS
    Derive a cold checkpoint whose guest has nobody signed in, for the headless rows.

.DESCRIPTION
    Microsoft documents a machine with no signed-in user as the *unblocked* servicing path,
    so the rows that matter most start from a guest that never reaches a desktop. The
    baseline guest is the opposite by design: it auto-signs-in, because the interactive-user
    continuation path needs a session to continue into.

    Turning that off is not one registry write. New-LabGuest also installs a SYSTEM startup
    task, Lab-RepairAutoLogon, that re-asserts auto-logon on every boot - it has to, because
    Windows consumes an auto-logon and deletes the values rather than treating them as
    settings. A checkpoint that clears the registry but leaves the task produces a guest that
    signs in again at the next boot, which is precisely the boot the headless row cares
    about. So the task, its script, and the registry values all go.

    Verification is by observation, not by assumption: the guest is booted once after the
    change and must show an active LogonUI with no Explorer before the checkpoint is taken.
    A row that silently ran against a signed-in guest would report a pass for the wrong
    machine, which is worse than failing.

.PARAMETER From
    Cold checkpoint to derive from. Must already exist.

.PARAMETER Name
    Name of the cold checkpoint to create.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VMName,
    [string]$From = 'baseline-clean',
    [string]$Name = 'baseline-no-autologon',
    [string]$GuestUser = 'updtest',
    [string]$GuestPassword,
    [int]$TimeoutMinutes = 20
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabCredential.ps1')
if (-not $GuestPassword) { $GuestPassword = Get-BootUpdLabPassword }
if (-not $GuestPassword) {
    throw 'No lab guest password available. Store one with: . ./LabCredential.ps1; Set-BootUpdLabPassword -Generate'
}
$cred = [System.Management.Automation.PSCredential]::new($GuestUser,
        (ConvertTo-SecureString $GuestPassword -AsPlainText -Force))
function Say { param($m) Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -ForegroundColor Cyan }

if (-not (Get-VMCheckpoint -VMName $VMName -Name $From -ErrorAction SilentlyContinue)) {
    throw "Source checkpoint '$From' does not exist on $VMName."
}

Say "deriving '$Name' from '$From'"
Restore-VMCheckpoint -VMName $VMName -Name $From -Confirm:$false
if ((Get-VM -Name $VMName).State -ne 'Running') { Start-VM -Name $VMName }

function Wait-Reachable {
    param([int]$Minutes = 10)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalMinutes -lt $Minutes) {
        try {
            if (Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock { 1 } -ErrorAction Stop) { return $true }
        } catch { }
        Start-Sleep -Seconds 10
    }
    return $false
}

if (-not (Wait-Reachable -Minutes ([math]::Max(5, [int]($TimeoutMinutes / 2))))) {
    throw 'Guest never became reachable over PowerShell Direct.'
}
Say 'reachable; removing auto-logon'

Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
    $w = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    foreach ($n in 'AutoAdminLogon', 'DefaultUserName', 'DefaultPassword', 'DefaultDomainName', 'AutoLogonCount') {
        Remove-ItemProperty -Path $w -Name $n -ErrorAction SilentlyContinue
    }
    Set-ItemProperty -Path $w -Name AutoAdminLogon -Value '0' -Type String
    Unregister-ScheduledTask -TaskName 'Lab-RepairAutoLogon' -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item 'C:\Lab\Repair-AutoLogon.ps1' -Force -ErrorAction SilentlyContinue
    Start-Process shutdown -ArgumentList '/s', '/t', '3', '/f' -NoNewWindow
} | Out-Null

$sw = [Diagnostics.Stopwatch]::StartNew()
while ((Get-VM -Name $VMName).State -ne 'Off' -and $sw.Elapsed.TotalSeconds -lt 240) { Start-Sleep -Seconds 3 }
if ((Get-VM -Name $VMName).State -ne 'Off') { throw 'Guest did not shut down cleanly.' }

<# Prove it. Boot once and confirm the guest parks at the logon screen instead of signing in.
   Everything below this line exists because "I removed the registry values" is a claim about
   the change, not about the machine. #>
Say 'verifying the guest now parks at the logon screen'
Start-VM -Name $VMName
if (-not (Wait-Reachable -Minutes ([math]::Max(5, [int]($TimeoutMinutes / 2))))) {
    throw 'Guest never became reachable after the auto-logon removal.'
}
$probe = Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
    [pscustomobject]@{
        Explorer = @(Get-Process explorer -ErrorAction SilentlyContinue).Count
        LogonUI  = @(Get-Process LogonUI  -ErrorAction SilentlyContinue).Count
        Console  = (Get-CimInstance Win32_ComputerSystem).UserName
    }
}
Say "probe: Explorer=$($probe.Explorer) LogonUI=$($probe.LogonUI) Console='$($probe.Console)'"
if ($probe.Explorer -ne 0 -or $probe.LogonUI -eq 0) {
    throw "Guest still signs a user in (Explorer=$($probe.Explorer), LogonUI=$($probe.LogonUI), Console='$($probe.Console)'). The headless checkpoint would be a lie."
}

Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
    Start-Process shutdown -ArgumentList '/s', '/t', '3', '/f' -NoNewWindow
} | Out-Null
$sw2 = [Diagnostics.Stopwatch]::StartNew()
while ((Get-VM -Name $VMName).State -ne 'Off' -and $sw2.Elapsed.TotalSeconds -lt 240) { Start-Sleep -Seconds 3 }
if ((Get-VM -Name $VMName).State -ne 'Off') { throw 'Guest did not shut down cleanly before checkpointing.' }

Get-VMCheckpoint -VMName $VMName -Name $Name -ErrorAction SilentlyContinue |
    Remove-VMCheckpoint -Confirm:$false
Checkpoint-VM -Name $VMName -SnapshotName $Name
Say "cold checkpoint '$Name' taken; guest has no interactive user"

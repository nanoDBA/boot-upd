#requires -Version 7.0
<#
.SYNOPSIS
    Build a boot-upd lab guest end to end, unattended, and leave it at a verified desktop.

.DESCRIPTION
    One call per guest, so the matrix can run rows in parallel on independent VMs. Creates
    the VM, installs Windows unattended, waits for the auto-logon desktop, installs the
    auto-logon repair task, and optionally takes a cold checkpoint.

    Three traps are handled here because each one cost real time to find:

    1. "Press any key to boot from CD or DVD" gets no answer in an unattended build, so the
       firmware falls through to PXE and the guest sits there forever. Hyper-V exposes the
       guest keyboard over WMI (Msvm_Keyboard), so the boot prompt is answered by typing
       into it rather than by a human at vmconnect.

    2. Windows deletes AutoAdminLogon, DefaultUserName and DefaultPassword after consuming
       an auto-logon. Configuring it once is a one-shot, not a property, so a SYSTEM startup
       task re-asserts it on every boot.

    3. A Windows Boot Manager entry is a UEFI *File* entry. Setting the raw disk as first
       boot device finds no \EFI\BOOT\BOOTX64.EFI on a Windows system partition and falls
       through to the DVD and then PXE, so the File entry is promoted after install.

.PARAMETER Checkpoint
    Shut the guest down cleanly and take a cold checkpoint of this name. Cold matters:
    a running-state checkpoint resumes a session that believes it is the capture time,
    so Windows locks it and the console state after a restore is non-deterministic.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [string]$VmRoot      = 'C:\HyperV\VMs',
    [string]$InstallIso  = 'C:\HyperV\ISO\Win11_Ent_LTSC_Eval_26100.iso',
    [string]$UnattendIso = 'C:\HyperV\ISO\unattend.iso',
    [string]$SwitchName  = 'Default Switch',
    [int]$CpuCount       = 2,
    [int64]$MemoryStartupBytes = 4GB,
    [int64]$MemoryMaximumBytes = 6GB,
    [int64]$DiskSize     = 50GB,
    [string]$GuestUser   = 'updtest',
    [string]$GuestPassword,
    [string]$Checkpoint  = '',
    [int]$InstallTimeoutMinutes = 45
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LabCredential.ps1')
if (-not $GuestPassword) { $GuestPassword = Get-BootUpdLabPassword }
if (-not $GuestPassword) {
    throw 'No lab guest password available. Store one with: . ./LabCredential.ps1; Set-BootUpdLabPassword -Generate'
}
function Say { param($m) Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -ForegroundColor Cyan }

if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { throw "VM '$Name' already exists." }
foreach ($iso in @($InstallIso, $UnattendIso)) {
    if (-not (Test-Path -LiteralPath $iso)) { throw "Missing image: $iso" }
}

$vmPath  = Join-Path $VmRoot $Name
$vhdPath = Join-Path $vmPath "$Name.vhdx"
New-Item -ItemType Directory -Force -Path $vmPath | Out-Null

Say "creating $Name ($CpuCount vCPU)"
$vm = New-VM -Name $Name -Generation 2 -MemoryStartupBytes $MemoryStartupBytes `
    -NewVHDPath $vhdPath -NewVHDSizeBytes $DiskSize -SwitchName $SwitchName -Path $VmRoot
Set-VM -VM $vm -ProcessorCount $CpuCount -DynamicMemory -MemoryMinimumBytes 2GB `
    -MemoryMaximumBytes $MemoryMaximumBytes -AutomaticCheckpointsEnabled $false `
    -CheckpointType Standard -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
Add-VMDvdDrive -VM $vm -Path $InstallIso
Add-VMDvdDrive -VM $vm -Path $UnattendIso
Set-VMKeyProtector -VM $vm -NewLocalKeyProtector
Enable-VMTPM -VM $vm
Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'
Set-VMFirmware -VM $vm -FirstBootDevice (Get-VMDvdDrive -VM $vm | Where-Object Path -eq $InstallIso)

Say 'starting and answering the boot prompt'
Start-VM -Name $Name
$sys = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$Name'"
$kb  = Get-CimAssociatedInstance -InputObject $sys -ResultClassName Msvm_Keyboard
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 30) {
    foreach ($k in 0x20, 0x0D) {
        try { Invoke-CimMethod -InputObject $kb -MethodName TypeKey -Arguments @{ keyCode = [uint32]$k } | Out-Null } catch { }
    }
    Start-Sleep -Milliseconds 400
}
<# Poll for evidence rather than sampling once. How fast Setup starts writing depends on
   vCPU count and on what else the host is running: a 4-vCPU guest reached 0.29GB in 30s
   while a 2-vCPU guest sharing the host was still at 0.04GB and only looked stuck. #>
$diskGb = 0
$startWait = [Diagnostics.Stopwatch]::StartNew()
while ($startWait.Elapsed.TotalMinutes -lt 5) {
    $diskGb = [math]::Round((Get-VHD $vhdPath).FileSize / 1GB, 2)
    if ($diskGb -ge 0.25) { break }
    Start-Sleep -Seconds 15
}
if ($diskGb -lt 0.25) {
    throw "Setup never started writing (disk $diskGb GB after $([math]::Round($startWait.Elapsed.TotalMinutes,1)) min). The boot prompt was probably not answered."
}
Say "Setup writing (disk ${diskGb}GB); waiting for the auto-logon desktop"

$cred = New-Object System.Management.Automation.PSCredential($GuestUser,
        (ConvertTo-SecureString $GuestPassword -AsPlainText -Force))
$deadline = (Get-Date).AddMinutes($InstallTimeoutMinutes)
$ready = $false
while ((Get-Date) -lt $deadline) {
    try {
        $probe = Invoke-Command -VMName $Name -Credential $cred -ErrorAction Stop -ScriptBlock {
            [pscustomobject]@{
                Explorer = @(Get-Process explorer -ErrorAction SilentlyContinue).Count
                LogonUI  = @(Get-Process LogonUI -ErrorAction SilentlyContinue).Count
                User     = (Get-CimInstance Win32_ComputerSystem).UserName
            }
        }
        if ($probe.Explorer -ge 1 -and $probe.LogonUI -eq 0) { $ready = $true; Say "desktop up as $($probe.User)"; break }
    } catch { }
    Start-Sleep -Seconds 20
}
if (-not $ready) { throw "Guest never reached a desktop within $InstallTimeoutMinutes minutes." }

Say 'installing the auto-logon repair task'
Invoke-Command -VMName $Name -Credential $cred -ArgumentList $GuestUser, $GuestPassword, $Name -ScriptBlock {
    param($User, $Password, $Machine)
    New-Item -ItemType Directory -Path 'C:\Lab' -Force | Out-Null
    $body = @"
`$w = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty `$w -Name AutoAdminLogon    -Value "1" -Type String
Set-ItemProperty `$w -Name DefaultUserName   -Value "$User" -Type String
Set-ItemProperty `$w -Name DefaultDomainName -Value "`$env:COMPUTERNAME" -Type String
Set-ItemProperty `$w -Name DefaultPassword   -Value "$Password" -Type String
Remove-ItemProperty `$w -Name AutoLogonCount -ErrorAction SilentlyContinue
"@
    Set-Content -Path 'C:\Lab\Repair-AutoLogon.ps1' -Value $body -Encoding UTF8
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\Lab\Repair-AutoLogon.ps1'
    $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\Lab\Repair-AutoLogon.ps1'
    $t = New-ScheduledTaskTrigger -AtStartup
    $p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'Lab-RepairAutoLogon' -Action $a -Trigger $t -Principal $p -Force | Out-Null
} | Out-Null

Say 'promoting the Windows Boot Manager entry and ejecting install media'
Invoke-Command -VMName $Name -Credential $cred -ScriptBlock { Start-Process shutdown -ArgumentList '/s', '/t', '3', '/f' -NoNewWindow }
$sw2 = [Diagnostics.Stopwatch]::StartNew()
while ((Get-VM -Name $Name).State -ne 'Off' -and $sw2.Elapsed.TotalSeconds -lt 180) { Start-Sleep -Seconds 3 }
Get-VMDvdDrive -VMName $Name | ForEach-Object {
    Set-VMDvdDrive -VMName $Name -ControllerNumber $_.ControllerNumber -ControllerLocation $_.ControllerLocation -Path ''
}
$fileEntry = (Get-VMFirmware -VMName $Name).BootOrder | Where-Object BootType -eq 'File' | Select-Object -First 1
if ($fileEntry) {
    $rest = (Get-VMFirmware -VMName $Name).BootOrder | Where-Object { $_.BootType -ne 'File' }
    Set-VMFirmware -VMName $Name -BootOrder (@($fileEntry) + @($rest))
}

if ($Checkpoint) {
    Checkpoint-VM -Name $Name -SnapshotName $Checkpoint
    Say "cold checkpoint '$Checkpoint' taken"
}

[pscustomobject]@{
    Name       = $Name
    State      = (Get-VM -Name $Name).State
    Checkpoint = $Checkpoint
    DiskGB     = [math]::Round((Get-VHD (Get-VMHardDiskDrive -VMName $Name).Path).FileSize / 1GB, 2)
    Minutes    = [math]::Round($sw.Elapsed.TotalMinutes, 1)
}

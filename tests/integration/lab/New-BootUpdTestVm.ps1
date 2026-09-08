#requires -Version 7.0
<#
.SYNOPSIS
    Build the disposable Hyper-V guest for the boot-upd multi-reboot convergence gate.

.DESCRIPTION
    Creates a Generation 2 VM that installs Windows 11 Enterprise LTSC Evaluation
    unattended, signs in automatically as a local administrator, and is then
    checkpointed so each scenario in the matrix can start from an identical machine.

    Run this from an elevated PowerShell 7 console AFTER the restart that activates
    the Hyper-V role. It refuses to run if the hypervisor is not actually up, because
    the Hyper-V cmdlets exist as soon as the feature is staged and would otherwise
    fail deep into the build with a confusing error.

.PARAMETER Name
    VM name. Also the checkpoint prefix.

.PARAMETER SwitchName
    Virtual switch. Defaults to the Hyper-V 'Default Switch', which provides NAT
    internet without touching the host's own adapter. An external switch bridges a
    physical NIC and can briefly drop host connectivity while it is created, which
    is a poor trade on a laptop that is also running your work.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Name          = 'boot-upd-matrix',
    [string]$VmRoot        = 'C:\HyperV\VMs',
    [string]$InstallIso    = 'C:\HyperV\ISO\Win11_Ent_LTSC_Eval_26100.iso',
    [string]$UnattendIso   = 'C:\HyperV\ISO\unattend.iso',
    [string]$SwitchName    = 'Default Switch',
    [int64]$MemoryStartupBytes = 4GB,
    [int64]$MemoryMaximumBytes = 8GB,
    [int64]$DiskSize       = 60GB,
    [int]$CpuCount         = 4
)

$ErrorActionPreference = 'Stop'

function Assert-Prerequisite {
    if (-not (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator))) {
        throw 'Run this from an elevated PowerShell 7 console.'
    }
    <# The Hyper-V module is present the moment the feature is staged, but the VMMS
       service only exists once the machine has restarted into the hypervisor. Check
       the service, not the module, or the failure surfaces halfway through the build. #>
    $vmms = Get-Service vmms -ErrorAction SilentlyContinue
    if (-not $vmms) {
        throw 'The Hyper-V Virtual Machine Management service is not present. Restart the machine to finish enabling Hyper-V, then run this again.'
    }
    if ($vmms.Status -ne 'Running') { Start-Service vmms }
    foreach ($iso in @($InstallIso, $UnattendIso)) {
        if (-not (Test-Path -LiteralPath $iso)) { throw "Missing image: $iso" }
    }
}

function Resolve-Switch {
    param([string]$Requested)
    $existing = Get-VMSwitch -Name $Requested -ErrorAction SilentlyContinue
    if ($existing) { return $existing.Name }
    Write-Warning "Switch '$Requested' not found. Available switches:"
    Get-VMSwitch | Select-Object Name, SwitchType | Format-Table -AutoSize | Out-String | Write-Host
    $internal = Get-VMSwitch | Where-Object SwitchType -ne 'Private' | Select-Object -First 1
    if (-not $internal) {
        throw "No usable virtual switch. Create one, or re-run with -SwitchName. The guest needs internet access for the updater to do any work."
    }
    Write-Warning "Falling back to '$($internal.Name)'."
    return $internal.Name
}

Assert-Prerequisite

if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
    throw "VM '$Name' already exists. Remove it first, or pass a different -Name. Refusing to touch an existing VM."
}

$switch = Resolve-Switch -Requested $SwitchName
$vmPath = Join-Path $VmRoot $Name
$vhdPath = Join-Path $vmPath "$Name.vhdx"

if (-not $PSCmdlet.ShouldProcess($Name, "Create Generation 2 VM on switch '$switch'")) { return }

New-Item -ItemType Directory -Force -Path $vmPath | Out-Null

$vm = New-VM -Name $Name -Generation 2 -MemoryStartupBytes $MemoryStartupBytes `
    -NewVHDPath $vhdPath -NewVHDSizeBytes $DiskSize -SwitchName $switch -Path $VmRoot

Set-VM -VM $vm -ProcessorCount $CpuCount `
    -DynamicMemory -MemoryMinimumBytes 2GB -MemoryMaximumBytes $MemoryMaximumBytes `
    -AutomaticCheckpointsEnabled $false `
    -CheckpointType Standard `
    -AutomaticStartAction Nothing -AutomaticStopAction ShutDown

<# Standard rather than Production checkpoints. Production uses VSS and discards the
   running state on revert, so a scenario interrupted mid-reboot could not be replayed
   from the same instant. Standard captures memory too, which is the whole point here. #>

# Two DVD drives: the installer, and the answer file Setup looks for on removable media.
Add-VMDvdDrive -VM $vm -Path $InstallIso
Add-VMDvdDrive -VM $vm -Path $UnattendIso

<# vTPM so the guest satisfies the Windows 11 requirements honestly, instead of
   patching the installer to skip the TPM and Secure Boot checks. A guest built by
   bypassing servicing-adjacent checks is a poor place to test servicing behaviour. #>
Set-VMKeyProtector -VM $vm -NewLocalKeyProtector
Enable-VMTPM -VM $vm
Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'

# Boot from the installer DVD for the first start.
$installerDvd = Get-VMDvdDrive -VM $vm | Where-Object Path -eq $InstallIso
Set-VMFirmware -VM $vm -FirstBootDevice $installerDvd

Write-Host ''
Get-VM -Name $Name | Select-Object Name, State, ProcessorCount,
    @{n='MemoryMaxGB';e={[math]::Round($_.MemoryMaximum/1GB,1)}},
    @{n='Switch';e={$switch}}, CheckpointType, AutomaticCheckpointsEnabled |
    Format-List | Out-String | Write-Host

Write-Host "Created. Next:" -ForegroundColor Green
Write-Host "  Start-VM -Name $Name"
Write-Host "  vmconnect.exe localhost $Name"
Write-Host ""
Write-Host "Setup runs unattended and auto-signs-in as 'updtest'. Once the desktop"
Write-Host "settles, take the baseline every scenario reverts to:"
Write-Host "  Checkpoint-VM -Name $Name -SnapshotName 'baseline-clean'"
Write-Host ""
Write-Host "To reset between matrix rows:"
Write-Host "  Restore-VMCheckpoint -VMName $Name -Name 'baseline-clean' -Confirm:`$false"

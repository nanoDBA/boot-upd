#requires -Version 7.0
<#
.SYNOPSIS
    Capture the live console of a Hyper-V guest to a PNG.

.DESCRIPTION
    PowerShell Direct answers "is the OS running", never "what is the user looking at".
    A guest sitting at a logon screen, a "Configuring updates" screen, or a modal restart
    dialog answers PowerShell Direct perfectly happily. For a gate about reboot and
    resume behaviour, the screen is evidence in its own right.

    Two traps this encodes, both hit for real on 2026-09-08:

    1. A VM with checkpoints has SEVERAL Msvm_VirtualSystemSettingData instances, one per
       snapshot plus the live one. Taking the first match returns a snapshot's SAVED frame,
       which never changes no matter what the guest does. Two consecutive captures looked
       identical and sent me chasing a boot failure that had already been fixed. Filter for
       VirtualSystemType 'Microsoft:Hyper-V:System:Realized'.

    2. The thumbnail comes back as RGB565 and can be a few bytes LONGER than
       width*height*2. Copying the whole buffer overruns the bitmap and kills the CLR
       outright (0x80131506). Copy min(stride*height, length).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VMName,
    [string]$Path,
    [ValidateRange(64, 1920)][int]$Width  = 1024,
    [ValidateRange(64, 1200)][int]$Height = 768
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not $Path) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $Path = Join-Path $env:TEMP "$VMName-$stamp.png"
}

$vsms = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VirtualSystemManagementService
$cs   = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$VMName'"
if (-not $cs) { throw "No VM named '$VMName'." }

# Trap 1: the live configuration, never a snapshot's frozen frame.
$sd = Get-CimAssociatedInstance -InputObject $cs -ResultClassName Msvm_VirtualSystemSettingData |
      Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' } |
      Select-Object -First 1
if (-not $sd) { throw "No realized setting data for '$VMName'; refusing to return a snapshot frame." }

$r = Invoke-CimMethod -InputObject $vsms -MethodName GetVirtualSystemThumbnailImage -Arguments @{
    TargetSystem = $sd; WidthPixels = [uint16]$Width; HeightPixels = [uint16]$Height
}
if ($r.ReturnValue -ne 0) { throw "GetVirtualSystemThumbnailImage failed with $($r.ReturnValue)." }
$src = [byte[]]$r.ImageData
if (-not $src -or $src.Length -eq 0) { throw 'Thumbnail returned no data (is the VM off?).' }

$bmp  = New-Object System.Drawing.Bitmap($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
$rect = New-Object System.Drawing.Rectangle(0, 0, $Width, $Height)
$data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
try {
    # Trap 2: never copy more than the bitmap can hold.
    [System.Runtime.InteropServices.Marshal]::Copy($src, 0, $data.Scan0, [Math]::Min($data.Stride * $Height, $src.Length))
} finally {
    $bmp.UnlockBits($data)
}
$bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

[pscustomobject]@{
    Path        = $Path
    CapturedAt  = Get-Date
    Config      = $sd.ConfigurationID
    Bytes       = (Get-Item $Path).Length
}

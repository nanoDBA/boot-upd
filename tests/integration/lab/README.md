# Disposable VM lab for the multi-reboot convergence gate

`docs/TESTING.md` requires the multi-reboot matrix on a disposable VM before releasing
changes to checkpointing, tasks, reboot detection, mutexes, provider convergence, or final
cleanup. These scripts build and drive that lab on Hyper-V.

## Setup

```powershell
$env:BOOTUPD_LAB_PASSWORD = '<a throwaway password for the guest>'
./New-UnattendIso.ps1                       # renders the template, builds unattend.iso
./New-LabGuest.ps1 -Name lab-a -Checkpoint fresh
./Invoke-LabRow.ps1 -VMName lab-a -Row A -Checkpoint fresh -ArmReboots 3
```

The guest password is supplied through `BOOTUPD_LAB_PASSWORD` and never committed. The
tracked answer file carries `__LAB_PASSWORD__` and the ISO builder substitutes it into a
temporary copy that is deleted afterwards.

## Why the evidence rule exists

`Invoke-LabRow.ps1` always records Windows event 6005 next to the updater's own log and
reports whether the two agree about how many times the machine restarted.

That comparison is not ceremony. Row A's updater log was internally consistent and wrong:
it claimed two reboots where the OS recorded three, because two boots fell inside the
120-second boot-session tolerance. The bug gates the reboot limit, so a fast reboot loop
could evade the cap entirely. Nothing in the updater's own account revealed it, and the
same check later caught the *first fix for it* also being wrong.

A log that records only what the program believes cannot reveal what the program got wrong.

## Traps encoded in these scripts

Each cost real time to find and is commented at the point it matters.

- **"Press any key to boot from CD or DVD"** gets no answer in an unattended build, so the
  firmware falls through to PXE and waits forever. The scripts type into the guest keyboard
  over WMI (`Msvm_Keyboard`) instead of needing a human at `vmconnect`.
- **`Microsoft-Windows-International-Core` must appear in the `oobeSystem` pass**, not only
  `windowsPE`. Without it OOBE stalls on the region and keyboard screens with nobody to
  click, even though the install itself completed unattended and the answer file logged no
  errors.
- **Windows deletes `AutoAdminLogon`, `DefaultUserName` and `DefaultPassword`** after
  consuming an auto-logon, so configuring it once is a one-shot rather than a property. A
  SYSTEM startup task re-asserts it every boot.
- **A Windows Boot Manager entry is a UEFI *File* entry.** Setting the raw disk as first
  boot device finds no `\EFI\BOOT\BOOTX64.EFI` on a Windows system partition and falls
  through to the DVD and then PXE.
- **Checkpoints are taken cold, with the guest off.** A running-state checkpoint resumes a
  session that believes it is the capture time, so Windows locks it and replays logon
  overlays; the console state after such a restore is non-deterministic.
- **Never drive a guest reboot with `Restart-VM`.** It is a hard reset and discards
  unflushed registry and file writes, which in a gate about state surviving restarts
  manufactures failures that do not exist. Use `shutdown /r` inside the guest.
- **Reboots are armed from real servicing state.** Enabling a restart-requiring optional
  feature sets CBS `RebootPending`, the signal the updater actually reads. `TelnetClient`
  does *not* require a restart and produces no signal.

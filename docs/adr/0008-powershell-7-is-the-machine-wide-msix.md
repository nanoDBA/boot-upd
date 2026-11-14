# Prefer the PowerShell MSIX; keep an existing 7.6 MSI

boot-upd installs PowerShell 7 from Microsoft's MSIX bundle, checks the release's
`hashes.sha256` and Microsoft signature, then provisions it for the whole machine with
`Add-AppxProvisionedPackage -Online`. `upd.cmd` prefers the signed-in user's WindowsApps alias
when it is registered. Once PowerShell is running, continuation tasks, Deploy, child processes,
the self-update relaunch and elevation use `pwsh.exe` in `$PSHOME` through
`Get-BootUpdatePwshPath`. They do not resolve `pwsh` by name. That distinction matters because
the alias lives in one user's profile and SYSTEM has none. A lab row once caught v2.5.92
registering every continuation task, including the SYSTEM fallback, against that alias.
`$PSHOME` names the actual package directory even when the user started PowerShell through the
alias.

PowerShell 7.7 shipped on 2026-11-10 with no MSI. Microsoft had announced the MSI's deprecation
in April: 7.6 LTS is the last line that ships one, and WinGet's `Microsoft.PowerShell` 7.7
manifest offers only the MSIX. boot-upd's upgrade check looked for the newest release with an
MSI asset and found 7.6.10, published two minutes before 7.7.0, so every machine reported
"already the latest stable release" while 7.7 was out.

The MSIX has a gap Microsoft tracks as a blocker (PowerShell/PowerShell#27562): it registers
per user, and its `pwsh` is on PATH only as a per-user app execution alias. SYSTEM has no
alias, so `pwsh` by name does not exist for the continuation tasks or the headless fallback.
The executable itself does run as SYSTEM. On lab-b (Windows 11 LTSC, build 26100), with
7.7.0 provisioned machine-wide, a SYSTEM scheduled task that named the alias failed with
"not recognized", and one that named
`C:\Program Files\WindowsApps\Microsoft.PowerShell_7.7.0.0_x64__8wekyb3d8bbwe\pwsh.exe` ran
7.7.0, started a ThreadJob and wrote to ProgramData. `$PSHOME\pwsh.exe` is that executable
for every install method, and on an MSI machine it is the same path as before.

With both packages installed and the MSIX registered for the signed-in user, a newly opened
Windows Terminal uses the MSIX for its default PowerShell profile and lists the MSI separately.
The profile list is generated when Terminal starts. The lab observation is recorded on bead
`on_boot_update_reboot_loop_while_pending_restarts_exist-14qf`. The `upd` batch launcher prefers
the per-user MSIX alias, while a bare `pwsh` command can still resolve the MSI because its
machine PATH entry can precede the user alias.

## Considered options

- **Keep an existing 7.6 LTS MSI beside the MSIX.** Accepted. The MSI still receives Microsoft
  Update servicing, runs as SYSTEM, supports WinRM remoting, and offers machine-wide profile and
  execution-policy settings that the MSIX does not. Removing it can strand machine-wide
  references that boot-upd cannot discover or repair. boot-upd therefore leaves an installed
  MSI alone while installing or upgrading the MSIX. On machines where an earlier boot-upd
  release already removed the MSI, boot-upd does not reinstall it.
- **Use the 7.6 LTS MSI where MSIX cannot install.** Retained for Windows older than build
  17763 and Server Core (PowerShell/PowerShell#27610).
- **The ZIP package under `Program Files\PowerShell\7`.** Microsoft documents it and it runs as
  SYSTEM, but it has no servicing story. Moving to it means uninstalling the MSI and
  unpacking files into the folder the MSI just left, which leaves a half-installed machine
  if anything fails in between. Rejected because the MSIX does the same job and is the
  method Microsoft supports.
- **WinGet.** For 7.7 it installs the MSIX for the current user only. Run elevated, that is
  the administrator's account, not the machine, and SYSTEM cannot run WinGet at all.
  Rejected as an install route. WinGet's own MSIX upgrades are harmless to a running cycle
  because it registers with deferral and never force-closes the app.

## Consequences

- The runtime never changes while a cycle is in progress. A cycle's tasks name the runtime's
  path, and an upgrade can remove an MSIX version folder. `Install-PowerShell7.ps1` refuses
  (exit 3) while `BootUpdateCycle` or `BootUpdateCycleFallback` exists. A cycle that completes
  starts it with `-WaitForProcessId`, so upgrades happen between cycles without the operator
  running `upd bootstrap`.
- An existing 7.6 MSI is never removed automatically by `upd bootstrap` or the after-cycle
  runtime upgrade. Both packages can remain installed. The MSI continues receiving its Microsoft
  Update servicing. Any removal must be an explicit operator decision after reviewing references
  to the old path; boot-upd does not edit Terminal settings, tasks, OpenSSH, App Paths, or PATH.
- Windows machines already updated by v2.5.93, which removed the MSI, are left unchanged. This
  decision does not reinstall the MSI or alter their runtime.
- The installer finds the installed MSIX through `Get-AppxPackage -AllUsers` and also by its
  folder under WindowsApps, which SYSTEM can list, so a provisioned package that no account
  has registered yet is still found.
- Microsoft's documented limits on MSIX PowerShell apply to every machine that has it:
  `$PSHOME` is read-only, so no all-users profile in `$PSHOME`, no WSMan endpoint
  registration and no `Set-ExecutionPolicy -Scope LocalMachine`. boot-upd uses none of these.
  An operator who relies on WinRM remoting into PowerShell 7 should know before upgrading.
- When Microsoft ships SYSTEM support for the packaged pwsh (#27562), nothing here has to
  change: the full path keeps working, and the alias becomes an extra.

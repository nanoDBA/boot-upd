# PowerShell 7 is the machine-wide MSIX, and boot-upd runs it by its real path

boot-upd installs PowerShell 7 one way: Microsoft's MSIX bundle from the PowerShell release
page, checked against the release's `hashes.sha256` and its Microsoft signature, and
provisioned for the whole machine with `Add-AppxProvisionedPackage -Online`. Everything in
boot-upd that starts PowerShell 7 (continuation tasks, the Deploy task, child processes, the
self-update relaunch, the launcher's elevation) uses `pwsh.exe` in `$PSHOME`, the folder the
running PowerShell lives in (`Get-BootUpdatePwshPath`). It never asks for `pwsh` by name.
`Get-Command pwsh` is exactly what must not be used: for an MSIX install it resolves to the
per-user alias inside the user's profile. A lab row that accidentally ran v2.5.92 on an MSIX
guest registered every continuation task, the SYSTEM fallback included, with that alias.
(`[Environment]::ProcessPath`, which the first version of this change used, reports the real
package path even when pwsh was started through the alias; `$PSHOME` is used because it names
the install folder directly.)

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

## Considered options

- **Keep the 7.6 LTS MSI.** Microsoft still supports it and it runs as SYSTEM. Rejected as
  the default because the operator asked for the current release, and staying on 7.6 means
  staying on an install method Microsoft has stopped shipping for new versions. It remains
  the fallback where the MSIX cannot install: Windows older than build 17763 (the package's
  minimum, so Windows Server 2016) and Server Core (PowerShell/PowerShell#27610).
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
- An existing MSI install is uninstalled once the MSIX has been provisioned and its pwsh.exe
  has started and reported the expected version. The Microsoft Update package that services
  the MSI goes with it. Restart Manager stays off, so open PowerShell windows keep running and
  files still in use go at the next restart.
- The installer finds the installed MSIX through `Get-AppxPackage -AllUsers` and also by its
  folder under WindowsApps, which SYSTEM can list, so a provisioned package that no account
  has registered yet is still found.
- Microsoft's documented limits on MSIX PowerShell apply to every machine that has it:
  `$PSHOME` is read-only, so no all-users profile in `$PSHOME`, no WSMan endpoint
  registration and no `Set-ExecutionPolicy -Scope LocalMachine`. boot-upd uses none of these.
  An operator who relies on WinRM remoting into PowerShell 7 should know before upgrading.
- When Microsoft ships SYSTEM support for the packaged pwsh (#27562), nothing here has to
  change: the full path keeps working, and the alias becomes an extra.

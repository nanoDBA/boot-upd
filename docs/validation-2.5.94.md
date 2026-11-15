# v2.5.94 validation

This release stops removing the PowerShell 7.6 MSI (PR #144). The PowerShell 7.7 MSIX is installed beside it. PR #145 adds the lab harness option used for the check below and changes no product file.

## PowerShell 7 install on a real machine

One lab row, `PR145-bootstrap-verified`, on lab-b from its `baseline-clean` checkpoint (PowerShell 7.6.5 MSI, no MSIX). The row ran `upd bootstrap --no-update`, waited for the PowerShell install it starts, and stopped. It ran from `a2ca2c9`, whose product files are identical to `b33a8b0`, the merge of PR #144.

| Check | Result |
|---|---|
| MSI before | 7.6.5.0 |
| MSIX before | none |
| Bootstrap task result | 0 |
| MSI after | 7.6.5.0, still installed |
| MSIX after | 7.7.0.0 |
| `pwsh.exe` in the MSI folder | starts, reports 7.6.5 |
| `pwsh.exe` in the MSIX package folder | starts, reports 7.7.0 |
| Reboot | none |
| Update cycle | not started |

Result: **PASS**.

## Windows Terminal with both installed

Observed on lab-b during the work that led to this release, on a development build and not on the release commit: with the 7.6 MSI and the 7.7 MSIX both installed and the MSIX registered for the signed-in account, a newly started Windows Terminal opened PowerShell 7.7 from the MSIX. Windows Terminal ranks a Store-packaged PowerShell above a traditional install of the same major version, and it builds that list when it starts.

## Gates

On the release branch, from elevated PowerShell 7.7:

- Pester unit/process: **754 passed, 0 failed**.
- User/SYSTEM security boundary: **passed**.
- Published-launcher upgrade: **passed**.

Two gate fixes were needed to run them where PowerShell 7 is installed only as the MSIX and where files created by an elevated process are owned by the user, as they are when UAC is off. Neither changes a product file.

- `tests/SecurityHardening.Tests.ps1`: the fixture that builds a locked-down folder never ran, because its elevation flag was set only while Pester discovered the tests. The six write-mask tests were checking the temp folder's inherited permissions. With UAC on those happen to give the expected answers; with UAC off three of them failed. The flag is now set for the run and the fixture sets the hook file's owner itself.
- `tests/integration/Invoke-CrossContextMutexGate.ps1`: the SYSTEM task was given whatever `pwsh` was first on PATH. With only the MSIX installed that is the per-user alias, which SYSTEM cannot start, and the gate timed out. It now names `pwsh.exe` in `$PSHOME`.

## Not run

- A multi-reboot lab row on this release. The change deletes the MSI uninstall step from `tools/Install-PowerShell7.ps1`; the cycle, the tasks and the reboot chain are unchanged since the v2.5.93 rows.
- Live bootstrap on a clean hosted VM.
- A machine where the MSIX is provisioned but not yet registered for the account that runs `upd bootstrap`.
- Windows Terminal on the release commit itself.
- The MSI fallback on Windows Server 2016 or Server Core.

The host was not rebooted to test this release, and no update cycle ran on it.

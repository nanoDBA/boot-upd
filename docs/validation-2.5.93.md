# v2.5.93 validation

This release installs Windows feature updates (PR #130), installs PowerShell 7 as Microsoft's machine-wide MSIX, which is how 7.7 ships (PR #131), starts PowerShell 7 from `$PSHOME` (PR #132), and gives Windows cumulative updates the same long Windows Update budget as feature updates (release branch).

## Multi-reboot lab rows

Both rows ran from a detached worktree pinned at the release candidate, on guests migrated from the PowerShell 7.6.5 MSI to the 7.7.0 MSIX by the new installer and saved as cold checkpoints. The harness hashes the host's frozen source and compares it with the orchestrator installed on the guest (`InstalledIsCandidate`); both rows matched. Row A ran `93f8d51`; row B ran `41e374e`, which changes only the lab harness (below). The release commit changes nothing the rows ran.

| Row | Build | Result | What it established |
|---|---|---|---|
| A-release-2593d | `93f8d51` | **PASS** | Interactive user, `upd run --no-update`, 3 armed reboots: 9 passes, 7 reboots claimed, every phase converged, health checks passed, both tasks and the state file removed, no pending reboot. Windows Update installed two Windows cumulative updates (2026-09, then 2026-11, which was offered only after the first) under the 240-minute budget, 34 and 18 minutes. All 33 task launches recorded by Task Scheduler ran `C:\Program Files\WindowsApps\Microsoft.PowerShell_7.7.0.0_x64__8wekyb3d8bbwe\pwsh.exe`. After the cycle exited, the post-cycle PowerShell check logged `PowerShell 7.7.0.0 is already the latest stable release.` 96.9 minutes. |
| B-release-2593e | `41e374e` | **PARTIAL** | Headless, SYSTEM fallback, 2 armed reboots, on a guest no one had signed in to since 7.7 was provisioned: 8 passes, 5 reboots (the 2 armed, one after each cumulative update, one for pending file renames). Machine scope converged and the final Windows Update scan found nothing left; health checks passed. Windows Update installed the 2026-09 and 2026-11 cumulative updates under the 240-minute budget, 38 and 18 minutes. All 24 task launches ran the MSIX `pwsh.exe` by full path as SYSTEM. User-scope work (Winget, Scoop, AI tools, VS Code) is queued for the saved user's next sign-in behind one logon-only task, which names the same `pwsh.exe` and retries 3 times at 2-minute intervals; no interactive session appeared. 128 minutes. |

A headless row with queued user work is PARTIAL by definition, so the summary for this gate is **not PASS**. Row B shows what a headless machine is expected to do. The queued logon task running on a first sign-in after the MSIX was provisioned is **not run**.

Row A's OS recorded 9 boots against the updater's 7 reboots, and row B's 8 against 5. Windows restarts more than once while it finishes a cumulative update: in row A twice per update (boots at 19:36 and 19:38, then 20:20 and 20:22, guest time), in row B three times and then twice. The updater counts the reboots it requested and the boot sessions it resumed in, so 7 and 5 are correct, and `RebootAccountingAgrees: false` in row A's `summary.json` reflects servicing's extra restarts, not a missed one. In both rows the 2026-11 cumulative update was offered only after the 2026-09 one was installed; the next final scan withheld convergence (`1 update(s) remain applicable`) and queued another pass, which installed it.

Earlier attempts that are not evidence for this release:

- **A-ps77msix, B-ps77msix** (`507cbf7`): stopped within seconds by the host's low-memory process reaper while both guests were booting. No cycle started. Rows now run one guest at a time.
- **A-release-2593, A-release-2593b**: launched as `upd run -DisableSelfUpdate`. `upd.cmd` does not recognize that switch, so it refreshed itself from the published v2.5.92 release before starting, and the guest ran v2.5.92. Its `Get-Command pwsh` resolves to the per-user app execution alias, so its tasks named the alias. That was misread as a property of the process path and led to PR #132; the comments, ADR 0008 and the safety rule were corrected on the release branch. The harness also took its "candidate" hash from the guest copy, so these rows reported a match. It now hashes the host's frozen source and adds `InstalledIsCandidate`. Lab handoff notes now pass `--no-update`.
- **B-release-2593d** (`93f8d51`): stopped before deploying. The harness checks the guest's PowerShell modules by running its `pwsh.exe` over PowerShell Direct as the lab account, and Windows refused with "Access is denied": a packaged app starts only for an account it is registered for, a provisioned package registers at the account's next interactive sign-in, and this headless guest had not been signed in to since 7.7 was provisioned. Only SYSTEM had it registered. The file permissions allow Users to run it. `41e374e` registers the provisioned package for the lab account before the probe, as that sign-in would. The updater needs no change: its user tasks run only in a signed-in session (`-LogonType Interactive`) and its other tasks run as SYSTEM, which row B exercises.
- **A-release-2593c** (`d1a0e64`): ran the candidate. Windows Update killed the 2026-09 cumulative update at the 30-minute per-provider budget (`HARD TIMEOUT: ... exceeded 30 min`), and the row did not converge. That is the change in `93f8d51`.

### Windows cumulative updates were left out before this release

On the same guest, v2.5.92's category filter reported "zero applicable updates remain in the configured category scope" while the 2026-09 cumulative security update was still offered. The new scope (PR #130) put it in front of the installer, and row A-release-2593c showed it needed more than 30 minutes. In `93f8d51`, an offer titled with its resulting OS build (`(26100.9457)`), or with "Cumulative Update for Windows" or "... for Microsoft server operating system", gets `--feature-timeout`, the same as a feature update.

## PowerShell 7 migration

Run as a SYSTEM scheduled task, the way a finished headless cycle starts it, on lab-b and on lab-a (Windows 11, build 26100, PowerShell 7.6.5 MSI):

| Check | Result |
|---|---|
| Installer exit | 0, `PowerShell 7.6.5 -> 7.7.0.0 installed.` |
| MSI uninstall entry and its PATH entry | gone |
| A busy `pwsh.exe` from the MSI (lab-b) | still running |
| MSIX | `Microsoft.PowerShell_7.7.0.0_x64__8wekyb3d8bbwe`, provisioned |
| SYSTEM task running 7.7 by full path (lab-b) | 7.7.0 as `NT AUTHORITY\SYSTEM`; a ThreadJob returned |
| Second run | exit 0, `already the latest stable release` |

## Gates

- Pester unit/process on `93f8d51`: **744 passed, 0 failed**.
- Lab harness tests after `41e374e` (`LabCompletion`, `LabHandoff`, `LabReadiness`): **23 passed, 0 failed**.
- Cross-context mutex, User/SYSTEM security boundary and published-launcher upgrade gates: **passed**.

## Not run

- A lab row with a Windows feature update in scope (tracked separately). No feature update has yet been installed by the updater itself.
- The saved user's first sign-in after the MSIX was provisioned, which runs row B's queued logon task. Provisioned packages register at that sign-in; the task retries 3 times at 2-minute intervals if it starts first.
- Building a new lab guest with the changed `New-LabGuest.ps1`.
- The MSI fallback on a real Windows Server 2016 or Server Core machine (release selection is unit-tested only).
- Migrating the maintainer's own machine; `-Upgrade -CheckOnly` there selects 7.7.0 and finds both the MSI and its Microsoft Update package.

The host was not rebooted to test this release.

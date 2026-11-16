# v2.5.96 validation

This release adds one option, `--skip-windows-update` (PR #158 for the updater and deploy script, plus the launcher flag in the release PR). It also records the lab rows that v2.5.95 listed as not run.

## Gates

On the release branch, from elevated PowerShell 7.7:

- Pester unit/process: **788 passed, 0 failed**.
- User/SYSTEM security boundary: **passed**.
- Published-launcher upgrade: **passed**.

## The option

| Layer | Evidence |
|---|---|
| Updater: no scan, download or install; driver and firmware phase skipped; summary says skipped by request | `tests/WindowsUpdateSkip.Tests.ps1`, and the guest logs of lab rows 2 and 3, where every pass logged "Windows Update: skipped by request" |
| Kept across continuation tasks | Lab row 3: four passes in three cycles, each with the skip; lab row 2: two SYSTEM passes and one user pass, each with the skip |
| Launcher: `--skip-windows-update` and `-no-wu` | `upd plan` test: the flag resolves to `SkipWindowsUpdate`, is absent by default, and is listed in help. The test failed before the flag existed |

## Lab rows owed from v2.5.95

Run on Hyper-V guests reset to existing checkpoints. Each result was checked against the guest's own log, not only the harness summary.

| Row | Code under test | Result |
|---|---|---|
| A provider that runs to its hard timeout stops the cycle (#147) | v2.5.95 as tagged | **PASS.** The stand-in Winget ran once, was killed at the timeout, the cycle stopped for manual attention, no reboot, no tasks left |
| npm left for the signed-in user by a SYSTEM run (#148) | v2.5.95 plus #156 and #158 | **PASS.** Two SYSTEM passes reached the update phases with no user signed in; the stand-in npm was not run and npm stayed queued for the user. After sign-in a user pass ran it once and the cycle finished with no state file and no tasks |
| A repeated Winget failure is remembered (#152) | v2.5.95 plus #156 and #158 | **PASS.** Cycle 1 failed twice, recorded the failure and stopped for attention. Cycle 2 tried the package once, listed it as a known failure left outstanding and did not stop. Cycle 3 cleared the record when the offered version changed and installed it |

Rows 2 and 3 took more than one attempt. Earlier attempts were stopped by the lab, not the product: Windows Update could not be kept out of a row, the stand-in Winget was not visible to continuation tasks, the guest had no npm, and one row ended before the second cycle. The fixes are in PR #156 and the option above. An earlier row 2 attempt was reported as a pass and downgraded on review, because its SYSTEM pass rebooted before reaching any update phase.

## Not run

- A lab row started through `upd --skip-windows-update`. The rows passed the switch through the deploy script.
- Memory clearing by a successful install of the same offered version; the row cleared it by changing the offer.
- An SSMS 21 update on a real machine.
- Live bootstrap on a clean hosted VM.

No update cycle ran on the development machine and it was not rebooted to test this release.

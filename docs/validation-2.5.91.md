# v2.5.91 validation

This release lets a stopped cycle be restarted, stops one package from blocking every other update, keeps the watchdog probe armed while one pass queues the next, and adds the AI tools phase (PRs #122 and #123).

## Multi-reboot lab rows

Every row ran with `-Launcher deploy`, and the guest's installed orchestrator hash matched the candidate. The release commit changes only the version line of `Invoke-BootUpdateCycle.ps1` after these rows. The orchestrator in rows B3, B4 and A-release is byte-identical to merged master `6d8c412`.

| Row | Build | Result | What it established |
|---|---|---|---|
| A-stuck-cycle-fix | `224ffba` (#122) | **PASS** | Interactive user, armed reboots: every phase converged, both tasks and the state file removed. |
| B-stuck-cycle-fix | `224ffba` (#122) | **PARTIAL** | Headless: machine scope converged and user work was held for the saved user. Windows Update then upgraded PowerShell 7 under the queued pass, which died at launch (0x8000809A), and nothing ran again that boot. |
| B2-stuck-cycle-fix | `a47b0a3` (#122) | **PARTIAL** | Same stall as B; that pass died mid-startup (0xE0434352). Led to #123. |
| B3-retry-watchdog | `526d5fd` (#123) | **PARTIAL** | Headless: reached the saved-user hand-off (one logon-only task; Winget, Scoop, AI tools and VS Code queued). No pass died, so the probe was armed but never fired. |
| B4-retry-watchdog-kill | `95895e1` (#123) | **PARTIAL** | The queued pass was killed right after it started, before it re-registered. The fallback's watchdog probe relaunched it 15 + 3 minutes after the hand-off was registered, without charging the recovery budget, and the cycle reached the same saved-user hand-off. |
| A-release | `6d8c412` (master) | **PASS** | Interactive user: 2 passes, 1 reboot, health checks passed, both tasks and the state file removed, no pending reboot. |

A headless row with queued user work is PARTIAL by definition. User-scope work waits for the saved user's next sign-in, so the summary for this gate is **not PASS**. The rows show what a headless machine is expected to do. Not reproduced: a queued pass that dies *at launch* under the MSI upgrade with the probe armed. It reaches the same probe through the same registration as B4.

## Gates

- Pester unit/process: **705 passed, 0 failed** (93.45 seconds).
- User/SYSTEM boundary: **passed** (10.47 seconds).
- Published-launcher upgrade from v2.5.43: **passed** (6.37 seconds).
- GitHub quality, User/SYSTEM, and published-launcher checks passed on #122 and #123.

The User/SYSTEM gate first failed three times on an unplugged laptop. The gate's SYSTEM worker task used Task Scheduler's default settings, which never start a task on battery. The task sat `Queued` and the gate timed out after 20 seconds with no assertion failing. The two host-side gates (User/SYSTEM and saved-user session) now allow battery start, and a test checks it. The lab guests have no battery, and their tasks already set it.

The published-launcher gate then failed once on a successful adoption. The legacy helper consumes `upd.cmd.next`, removes the sidecars, and then writes its completion line. The gate checked for leftover sidecars as soon as `.next` disappeared, so it could catch the helper between those steps. It now checks after the completion line.

The host was not rebooted to test this release.

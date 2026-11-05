# v2.5.92 validation

This release makes the parallel phase group log as it goes, with a start line, a finish line carrying each phase's own duration, and a five-minute heartbeat naming the phases still running, and gives lab rows a running host-side copy of the guest's updater log (PR #127).

## Multi-reboot lab rows

Every row ran with `-Launcher deploy` from a worktree pinned at merged master `81d24b7`, and the guest's installed orchestrator hash matched the candidate. The release commit changes only the version line of `Invoke-BootUpdateCycle.ps1` after these rows.

| Row | Build | Result | What it established |
|---|---|---|---|
| A-release | `81d24b7` (master) | **PASS** | Interactive user, 3 armed reboots: 3 passes, 2 reboots claimed and 2 recorded by the OS, every phase converged, health checks passed, both tasks and the state file removed, no pending reboot. 10.4 minutes. |
| B-release | `81d24b7` (master) | **PARTIAL** | Headless, SYSTEM fallback, 1 armed reboot: 4 passes, 2 reboots (the armed one, then Windows Update's own after installing 2 packages), both recorded by the OS and both counted by the updater. Machine scope converged; user-scope work (Winget, Scoop, AI tools, VS Code) was queued for the saved user's next sign-in behind one logon-only task. No interactive session appeared. 26 minutes. |

A headless row with queued user work is PARTIAL by definition, so the summary for this gate is **not PASS**. The row shows what a headless machine is expected to do.

The parallel group finished in 0.4 minutes in both rows, so its five-minute heartbeat never fired; that line is covered by unit tests only. Every phase logged `STARTING` as its job launched and `DONE (x min, n pkg)` as it finished, with Defender the last at 0.3 to 0.4 minutes.

The host-side live copy of the guest log (`BootUpdateCycle.live.log`), built from the lines each 40-second poll brought back across each row's two guest reboots, was compared line for line with the log collected whole at the end of the row: row A 280 lines in each, row B 254 lines in each, no differences, no rotation marker.

Three earlier attempts at these rows were abandoned and left evidence directories with a `run-manifest.json` of `InterruptedOrFailed` and no `summary.json`:

- Rows A and B were first launched from the worktree where the version bump was then applied. The harness hashes the file list when a row starts and re-hashes the orchestrator after the copy, so row A stopped with "Orchestrator hash mismatch" and row B's PowerShell Direct session died during the same copy. Rows now run from a detached worktree pinned at the commit under test; the lab-row skill records this trap.
- Row B then failed twice more during the tree sync, with "A remote session might have ended" from PowerShell Direct within a minute of the guest booting, both times while row A was running on the other guest. The host logged no Hyper-V session errors, was on AC power, and had 10 GB free. The 11-02 rows that passed ran one guest at a time; row B was rerun alone.

## Gates

- Pester unit/process: **715 passed, 0 failed** (89.7 seconds), on the release branch.
- User/SYSTEM boundary: **passed** (7.6 seconds).
- Published-launcher upgrade from v2.5.43: **passed** (18.0 seconds).
- GitHub quality, User/SYSTEM, and published-launcher checks passed on #127.

The host was not rebooted to test this release.

# Epic -35qb handoff

Append one section per stop. Newest last.

## 2026-09-09, unattended session (v2.5.79)

**IN PROGRESS at the time of writing.** This section is written ahead of the stop so the work
is recoverable if context is lost; it is rewritten with the final stop condition when the
session actually ends. If you are reading this and the section still says IN PROGRESS, treat
the tracker and git as authoritative and resume from the "next ticket" line below.

### Where the release stands

Version is bumped to 2.5.79 in `Invoke-BootUpdateCycle.ps1`, `upd.cmd` (both places) and the
README installer pin. The `Install-UpdCompat.ps1` hash in the README is carried forward
deliberately: that file is unchanged since v2.5.78, confirmed by
`git diff --stat v2.5.78..HEAD -- Install-UpdCompat.ps1` returning nothing.

Test gates: **PASS**, 477 tests / 0 failed, plus the user/SYSTEM boundary and published-launcher
gates. Note the unit gate failed **once** at 1 of 477 and passed on three subsequent runs; the
gate threw a bare count and discarded the results, so the failing test cannot be identified.
`tools/Invoke-TestGates.ps1` now names failing tests so this is diagnosable next time.

Draft release notes live at
`C:\Users\LarsR\AppData\Local\Temp\claude\G--My-Drive-backups-projects-boot-upd\fc81763d-eabe-486d-ae4a-e3e62fea9cf9\scratchpad\notes-2579.md`
with a `VALIDATION_BLOCK` placeholder to be replaced by the real gate and row table. **They are
not committed to `RELEASE_NOTES.md` until that block is filled from actual `summary.json`
files.**

### Tickets closed this session, with evidence

All evidence directories are under `C:\HyperV\evidence\`.

| Ticket | Result | Evidence |
|---|---|---|
| `-35qb.6` lab timeline streaming | closed | verified live on every row since |
| `-35qb.1` ResumeUserSid dead code | closed | unit; live SID task registration seen in `B-k610-fix-boot-upd-matrix-20260909-093402` |
| `-35qb.4` NoInteractiveUser exhaustion test | closed | unit |
| `-9nj2` withheld logged as crash | closed | `B-k610-cgua-v2-boot-upd-matrix-20260909-095952` |
| `-h2z0` / `-qibm` pending-cleanup evidence sidecar | closed | unit only; no bundle captured from a guest yet |
| `-ynvn` orphaned MSI transaction | closed | unit only; never exercised on a guest |
| `-35qb.3` beads export identity | closed | export inspected; 0 leaks |
| `-vla0` diagnostics phase/pass | closed | already fixed in v2.5.72; regression tests added |
| `-h58s` row E | closed PASS | `E-delayed-signal-boot-upd-matrix-20260908-213738` |
| `-l6yq` row B (old) | closed PARTIAL, re-scoped to `-k610` | `B-headless-terminal-v5-...-030428` |
| `-21p2` wuauserv | closed INVALID, re-scoped to `-k610` | — |
| `-2bx` repeating FileRename | closed, not reproducible | host registry read 2026-09-09, value absent |
| `-k610` KB5007651 re-offer | closed | `k610-diagnosis-20260909-083408` + `B-k610-cgua-v2-...-095952` |
| `-cgua` bounded user wait | closed | `B-k610-cgua-v2-...-095952` |
| `-n6qn` row D failed restart | closed PARTIAL | `D-failed-restart-lab-b-20260909-092536` |
| `-781l` row C cancelled restart | closed PASS | FAIL `C-cancelled-restart-v3-...-101428`, PASS `C-cancelled-restart-v4-...-105952` |
| `-7yeb` row F PS5.1 bootstrap | closed PASS | `F-ps51-bootstrap-v3-lab-b-20260909-095955` |
| `-57yf` row G killed process | closed PARTIAL | `G-killed-after-promotion-v2-...-110032` + `C:\Lab\g4-kill-evidence.json` |
| `-3tw` disposable-VM gate | closed | all row tickets closed |
| `-35qb.9` harness one-line log | closed | reproduced and fixed, commit 918f641 |
| `-35qb.8` prose identity leak | closed | corrected in the tracker; export now 0 leaks |
| `-jjyx` boot-session deepening | **still in_progress** | rows A and B against the final build are its acceptance |

Deferred with reasons: `-5vbd`, `-35qb.7`, `-35qb.10`.
Still open: `-35qb.2` (closes when the notes land), `-jjyx`.

### Defects this session found that were NOT in any ticket

Each is fixed and committed; several were found only because a row ran.

1. The lab harness reported a converged cycle against a one-line guest log (`@()` inside an
   `if`, scalar collapse). Commit 918f641.
2. `RESUMED (after reboot)` announced on passes that followed no reboot. Commit 1338f19.
3. The dated `-RetryAt` watchdog had never been armed in any release: `[Nullable[datetime]]`
   binds to a plain `DateTime`, so `.HasValue` was always `$null`. Commit f74b693.
4. An injection that threw still reported `Injected=true`. Commit 0651d8c.
5. A double UTC conversion on Windows Update history dates. Commit 5744a28.
6. `Test-WindowsUpdateConvergence` early returns omitted fields, so the ordinary converged
   path threw on `[datetime]$null`. Found by the Standards review. Commit 45e74c6.
7. The evidence sidecar was **not** written under `-WhatIf` despite the notes, ADR-0004 and
   the ticket all saying so — `Set-Content` honours `ShouldProcess`. Found by the Spec review.
   Commit 45e74c6.
8. The re-offer classification was scoped to the boot, so it lost its evidence across the very
   restart it exists to stop repeating. Found by lab row B against the shipping build.
   Commit 22e2733.
9. `summary.json` reported `Completed=false` for a run that had completed 28 seconds before
   the monitor's deadline. Commit f786c91.

### The exact next step

Rows A and B must both pass against the final build before anything is tagged.

```powershell
cd 'G:\My Drive\backups\projects\boot-upd'
./tests/integration/lab/Invoke-LabRow.ps1 -VMName boot-upd-matrix -Row 'A-v2579-ship3' -Checkpoint 'baseline-clean' -ArmReboots 3 -TimeoutMinutes 60
./tests/integration/lab/Invoke-LabRow.ps1 -VMName lab-b -Row 'B-v2579-ship3' -Checkpoint 'baseline-no-autologon' -ArmReboots 1 -SystemContext -DeployArgs '-MaxUserIdentityWaits 2' -TimeoutMinutes 60
```

Then, in order: fill `VALIDATION_BLOCK` in the draft notes from the real `summary.json` files,
prepend the section to `RELEASE_NOTES.md`, close `-35qb.2` and `-jjyx`, re-run
`./tools/Invoke-TestGates.ps1`, and only then:

```powershell
./tools/New-Release.ps1 -Tag v2.5.79 -Title 'v2.5.79 - truthful claims' -NotesPath RELEASE_NOTES.md
gh release view v2.5.79 --repo nanoDBA/boot-upd --json isDraft,assets
```

Expect not-draft and 20 assets (10 scripts, 10 `.sha256` sidecars).

### Assumed rather than verified

- That `Install-UpdCompat.ps1` hashes identically once published, so the README pin carried
  over from v2.5.78 is correct. The immutable published-launcher gate confirms this only
  **after** the release is cut.
- That the pending-cleanup sidecar and the orphaned-installer wait behave on a real machine as
  their unit tests say. Neither has been exercised on a guest: no row timed out a package, and
  no diagnostics bundle has been captured from a guest running the sidecar.
- That the one-off `1 of 477` gate failure was not a real defect. It could not be identified
  because the gate discarded the failing test names; three subsequent full runs were clean.
- That row F's PASS says nothing about this build. It validated the published v2.5.78 bundle,
  because `upd.cmd`'s documented path recovers the checksummed bundle from the latest release.
- That lab-b's rebuild is equivalent to lab-a. It was rebuilt from scratch this session after
  its old checkpoints proved unusable (credential rejected, repeated reboots); its Windows
  Update state differs from lab-a's, which is why row B behaves differently on each.

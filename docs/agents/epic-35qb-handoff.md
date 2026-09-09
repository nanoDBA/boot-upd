# Epic -35qb handoff

Append one section per stop. Newest last.

## 2026-09-09, unattended session — v2.5.79 shipped

### Which stop condition fired

The first: **`v2.5.79` is published and every child of the epic is closed, deferred with a
reason, or re-scoped.**

<https://github.com/nanoDBA/boot-upd/releases/tag/v2.5.79> — `isDraft: false`, **20 assets**
(10 scripts + 10 SHA-256 sidecars), targeting commit `938de32`, which is the commit both
validation rows verified by orchestrator hash at sync time. The epic was closed with
`--force`, because the only non-closed children are the three deferred ones, each with a
written reason: `-35qb.10`, `-5vbd`, `-35qb.7`.

The compatibility-installer hash pinned in `README.md` was carried forward from v2.5.78 and
then **checked against the published asset** by downloading it —
`67662B3B02252FF6DE045FCDF28FB74D8DEB6FDA8080C46B1DAFC7BFBE54ABE3`, matching. The published
release body was updated afterwards so its Validation block records that, rather than leaving
it as the promise it was when written.

### Final gates and rows

`./tools/Invoke-TestGates.ps1`: **478 tests, 0 failed**; user/SYSTEM boundary **PASS**;
published-launcher upgrade **PASS**.

| Row | Result | Evidence under `C:\HyperV\evidence\` | Build |
|---|---|---|---|
| A interactive, 3 reboots | **PASS** | `A-v2579-final-boot-upd-matrix-20260909-145814` | shipping |
| B headless SYSTEM | **PASS**, qualified claim | `B-v2579-final-lab-b-20260909-145818` | shipping |
| C cancelled restart | **PASS** | `C-cancelled-restart-v4-lab-b-20260909-105952` | `0651d8c` |
| D failed restart | **PARTIAL** (meets its own acceptance; convergence impossible by design) | `D-failed-restart-lab-b-20260909-092536` | `918f641` |
| E delayed signal | **PASS under v2.5.77**, not re-run | `E-delayed-signal-boot-upd-matrix-20260908-213738` | v2.5.77 |
| F PS5.1 bootstrap | **PASS** | `F-ps51-bootstrap-v3-lab-b-20260909-095955` | published v2.5.78 bundle |
| G killed process | **PARTIAL** (state integrity yes; resume no) | `G-killed-after-promotion-v2-boot-upd-matrix-20260909-110032` | `0651d8c` |

### Tickets closed, with evidence

`-35qb.1` `-35qb.2` `-35qb.3` `-35qb.4` `-35qb.6` `-35qb.8` `-35qb.9` `-3tw` `-781l` `-2bx`
`-21p2` `-57yf` `-7yeb` `-9nj2` `-cgua` `-h2z0` `-h58s` `-jjyx` `-k610` `-l6yq` `-n6qn`
`-qibm` `-vla0` `-ynvn`. Each close reason names its evidence directory or its test count.

Deferred with reasons: `-35qb.10` (killed cycle not resumed until logon or boot — needs a
repeating watchdog trigger and its own lab row), `-5vbd` (waits for a real bundle carrying the
new sidecar), `-35qb.7` (KVP beacon; `-35qb.6`'s streamed timeline covers the need for now).

### Nine defects found that no ticket had

Five were found only because a row ran on a machine.

1. Lab harness reported a converged cycle against a one-line guest log — scalar collapse. `918f641`
2. `RESUMED (after reboot)` announced on passes that followed no reboot. `1338f19`
3. The dated `-RetryAt` watchdog had never been armed in any release: `[Nullable[datetime]]`
   binds to a plain `DateTime`, so `.HasValue` was always `$null`. `f74b693`
4. An injection that threw still reported `Injected=true`. `0651d8c`
5. Double UTC conversion on Windows Update history dates. `5744a28`
6. `Test-WindowsUpdateConvergence` early returns omitted fields, so the ordinary converged
   path threw on `[datetime]$null` — a crash on the common path. `45e74c6`
7. The evidence sidecar was **not** written under `-WhatIf` despite the notes, ADR-0004 and
   the ticket all saying so. `45e74c6`
8. The re-offer classification was scoped to the boot and lost its evidence across the very
   restart it exists to stop repeating. `22e2733`
9. `summary.json` said `Completed=false` for a run that completed 28 seconds before the
   monitor's deadline. `f786c91`

Plus two wording defects fixed rather than shipped: the re-offer message said "since this
boot" while counting over the run (`c9bb8e9`), and the notes' own test count was one out
(`938de32`).

### If you are picking this up next

There is no in-flight work. Start from `bd ready`. The obvious next candidates are the three
deferred tickets, `-35qb.10` first — it is the only one that leaves a real durability gap.

To reproduce any row:

```powershell
cd 'G:\My Drive\backups\projects\boot-upd'
./tests/integration/lab/Invoke-LabRow.ps1 -VMName boot-upd-matrix -Row 'A-check' -Checkpoint 'baseline-clean' -ArmReboots 3 -TimeoutMinutes 60
./tests/integration/lab/Invoke-LabRow.ps1 -VMName lab-b -Row 'B-check' -Checkpoint 'baseline-no-autologon' -ArmReboots 1 -SystemContext -DeployArgs '-MaxUserIdentityWaits 2' -TimeoutMinutes 60
```

Guests: `boot-upd-matrix` (lab-a) and `lab-b`, both with `baseline-clean` and
`baseline-no-autologon`; lab-b additionally has `baseline-ps51` for row F. **lab-b was rebuilt
from scratch this session** — its old checkpoints rejected the lab credential and the guest
rebooted repeatedly. Two guests at 4 GB, never three.

### Assumed rather than verified

- **`New-Release.ps1 -NotesPath RELEASE_NOTES.md` no longer works** and the brief's command is
  now wrong: GitHub rejects a body over 125,000 characters and the accumulated file is past
  it. The release was cut by extracting just the `## v2.5.79` section to a file and passing
  that. Nothing has been changed in the tool to make this automatic — the next release will
  hit the same wall.
- The pending-cleanup sidecar (`-h2z0`) and the orphaned-installer wait (`-ynvn`) have **unit
  cover only**. No row this cycle timed out a package, and no diagnostics bundle has been
  captured from a guest running the sidecar. Both are stated as limitations in the notes.
- The unit gate **failed once at 1 of 477** and passed on five later full runs. The gate threw
  a bare count and discarded the names, so it cannot be identified. `Invoke-TestGates.ps1` now
  names failing tests; whether that one was real is not known.
- Row F's PASS says nothing about this build: `upd.cmd`'s documented path recovered the
  published v2.5.78 bundle, as its log shows.
- Rows C, D and G ran against commits one to three behind the shipping build. None of those
  commits touched the paths those rows exercise, but they were not re-run.
- `Test-BootUpdateInteractiveUserPresent` reads `Win32_ComputerSystem.UserName`, the console
  session. An RDP-only server with a signed-in administrator reads as having no interactive
  user and is therefore bounded. That is the safe direction, and it is stated in the notes,
  but it was not tested on such a machine.

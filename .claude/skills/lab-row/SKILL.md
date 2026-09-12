---
name: lab-row
description: Run and report one multi-reboot lab matrix row on the Hyper-V lab, or define a new row. Use for any change to checkpointing, tasks, reboot detection, mutexes, provider convergence, cleanup, or the resume chain.
---

Read `tests/integration/lab/README.md` and `tests/integration/lab/Invoke-LabRow.ps1` before
touching a row; both encode traps that cost real hours and are not repeated in full here.

## When to use it

Any change to checkpointing, scheduled tasks, reboot detection, mutexes, provider convergence,
final cleanup, or the resume chain needs at least rows A and B run against the changed build
before it ships (`docs/TESTING.md`, "Multi-reboot VM matrix"). Unit-test agreement is not
evidence of behavior on a machine — three defects in this project were invisible to a green
suite and caught only by a lab row.

## Guests and checkpoints

- Guests: `boot-upd-matrix` (referred to as lab-a) and `lab-b`.
- Checkpoints: `baseline-clean` (autologon on) and `baseline-no-autologon` (verified headless).
- Restore only through `Invoke-LabRow.ps1`. Never call `Restore-VMCheckpoint` or `Restart-VM`
  directly — see traps below.

## Running a row

Always run as a background job. Never poll a row's progress by re-invoking a check in a loop —
`host-timeline.txt` in the evidence directory is append-as-it-happens and is the thing to tail
if a live view is wanted. When the job finishes, read `summary.json` first, then grep
`BootUpdateCycle.log` for:

```
CYCLE (STARTED|RESUMED|COMPLETE)|new Windows boot session|recovery limit|Deferred inventory|No interactive user
```

Row A (interactive user, multiple reboots):

```powershell
./tests/integration/lab/Invoke-LabRow.ps1 -VMName lab-a -Row A-<label> `
    -Checkpoint baseline-clean -ArmReboots 3 -TimeoutMinutes 45
```

Row B (headless, SYSTEM fallback):

```powershell
./tests/integration/lab/Invoke-LabRow.ps1 -VMName lab-a -Row B-<label> `
    -Checkpoint baseline-no-autologon -ArmReboots 1 -SystemContext `
    -DeployArgs '-MaxUserIdentityWaits 2' -TimeoutMinutes 45
```

Kill-injection row (G shape — no armed reboot). On the guest the harness runs the cycle
through a `Lab-RunDeploy` task whose `pwsh.exe` command line names
`C:\Lab\boot-upd\Deploy-BootUpdateCycle.ps1`; Deploy then runs the orchestrator *inside that
same process*, so no process anywhere has `Invoke-BootUpdateCycle` on its command line. Kill the
Deploy host. Row G v2 injected on `Chocolatey - DONE`, which lands after Winget and Chocolatey are
promoted and during Windows Update:

```powershell
./tests/integration/lab/Invoke-LabRow.ps1 -VMName lab-a -Row G-<label> `
    -Checkpoint baseline-clean -TimeoutMinutes 45 `
    -InjectWhen 'Chocolatey - DONE' `
    -InjectAction {
        Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" |
            Where-Object { $_.CommandLine -match 'Deploy-BootUpdateCycle' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    }
```

## Defining a new row

There is no registry of rows. A row is defined entirely by the call: a `-Row` label, a
`-Checkpoint`, and — for a row that disturbs the cycle at a specific moment rather than letting
it run clean — an `-InjectWhen` regex matched against the updater's log plus an `-InjectAction`
scriptblock run on the guest the first time that regex matches. Pick the checkpoint that puts
the guest in the starting state the row needs (build a new one with `New-LabHeadlessCheckpoint.ps1`
or by branching an existing checkpoint) and choose `-InjectWhen` from a log line that only
appears at the moment the row cares about, not one that could also match on an earlier pass.

## Traps

- **An injection that throws must not count as `Injected: true`.** `Invoke-LabRow.ps1` wraps the
  injection call in `try/catch` for exactly this reason; a scriptblock that itself tries
  `try/catch` as an *expression* is invalid PowerShell and will look like it ran while killing
  nothing (row G v3).
- **Completion is taken from collected evidence, not from a poll catching it.** A cycle can
  converge between polls; the harness re-checks the log and task count after the monitor loop
  exits before declaring `Completed: false`. Don't second-guess a `summary.json` that says
  `Completed: true` with zero remaining tasks just because the timeline shows the deadline hit.
- **A kill filter matching a `pwsh` command line for `Invoke-BootUpdateCycle` matches nothing.**
  Deploy runs the orchestrator in-process, so the only command line to match is the one naming
  `Deploy-BootUpdateCycle.ps1` (or `upd.cmd` under `cmd.exe` when `-Launcher upd`). When in
  doubt, enumerate `Get-CimInstance Win32_Process` on the guest during a row before writing the
  filter.
- **`$x = if (...) { @(Get-Content ...) }` collapses a one-line log to a string**, silently
  turning every `-match`/`.Count` check downstream into a lie. Use `Where-Object`, not `-match`,
  when counting matching lines.
- **Never drive a guest reboot with `Restart-VM`.** It is a hard reset and discards unflushed
  writes, manufacturing failures in a gate that is about surviving restarts. Reboots inside the
  guest go through `shutdown /r` only.
- **Checkpoints are taken and restored cold, guest off.** A running-state checkpoint resumes a
  session that thinks it is still capture time and behaves non-deterministically after restore.
- **The tree-sync path deletes the guest copy before copying**, so a file removed on the host
  cannot survive on the guest while the orchestrator hash still matches.
- **`DeployTaskResult` 267014 or 1073807364 on a row that rebooted is benign** — the launcher
  task got killed by the reboot. `0x80070002` means the task's executable is missing.
  `RebootsClaimed: $null` means no completion claim was made, not a disagreement with the OS.

## Reporting a row

A row is **PASS** only when every enabled phase converged, no reboot evidence remains, health
checks pass, and both continuation tasks and active state are absent. Anything short of that is
**PARTIAL** — name what *was* established — or **FAIL** — name why. **NOT RUN** is its own word,
never folded into PASS. A summary line may say PASS only when every row underneath it is PASS;
one PARTIAL or FAIL anywhere makes the summary not PASS. Always name the evidence directory
(`EvidenceDir` in `summary.json`) when reporting a row's result.

## Sanitization

This repository is public. Evidence directory names, guest names, and any log excerpt quoted
into a tracked doc, ticket, or release note must not carry a real computer name, username, or
profile path. Use the guest names above and neutral labels (`<label>`, `WORKSTATION01`) instead
of whatever a live run actually produced.

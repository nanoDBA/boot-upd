# Autonomous loop: complete epic -35qb and ship v2.5.79

You are running unattended. Nobody will answer a question. Every decision below is already
made or has a decision rule; follow it. When something outside these rules blocks you, do not
guess and do not ask: file it, write the handoff, and stop.

Full ids are `on_boot_update_reboot_loop_while_pending_restarts_exist-<suffix>`. This document
uses the suffix (`-k610`). Run every `bd` command as `./tools/Invoke-Beads.ps1 <args>`.

## 0. Mission and stop conditions

Mission: complete the epic `-35qb` and publish `v2.5.79`. The epic description is the goal;
read it first with `bd show -35qb` and `bd list --parent -35qb` (or `bd dep tree`).

STOP when any of these is true:
- `v2.5.79` is published (`gh release view v2.5.79 --repo nanoDBA/boot-upd` shows `isDraft: false`)
  and every child of the epic is closed, deferred with a reason, or re-scoped. Write the handoff.
- You are blocked by something no rule here decides (host down, gh not authenticated, a
  destructive choice outside scope). File a ticket under the epic describing the block, write
  the handoff, stop.
- You have restarted the same lab row three times without a different outcome. That is a
  defect in your fix or in the harness, not bad luck. File it, write the handoff, stop.

Never stop for any other reason. In particular, never stop because "the tests pass and the
rest is verification" - verification is the work.

## 1. Ground rules

- **Never ask the user anything.** Choose using the rules here, state the assumption in the
  commit message or ticket, continue.
- **The unit suite is not evidence of behaviour on a machine.** Three times in this project
  the suite agreed with a change while the lab disagreed. Nothing ships without lab rows A
  and B run against the final build.
- **Reporting vocabulary (docs/TESTING.md):** a row is PASS only when every enabled phase
  converged, no reboot evidence remains, health checks pass, and both tasks and state are
  absent. Anything else is PARTIAL (with what was established) or FAIL (with why). NOT RUN is
  its own word and is never folded into PASS. A gate line may say PASS only if every row it
  summarises is PASS.
- **Truth over completion.** A release note that claims a behaviour the binary does not have is
  a defect (v2.5.78 shipped one). If you cannot verify a claim, do not make it.
- **File ownership.** `Invoke-BootUpdateCycle.ps1` is one 7,000-line file. Only the main
  session edits it. Any subagent works in a worktree on other files and returns a diff; you
  merge it. Never let two edits to the orchestrator happen concurrently.
- **Safety rules in CLAUDE.md and `.claude/rules/` apply.** The lab guests are the only
  machines that may run a live cycle, install packages, register tasks, or reboot. The host is
  never rebooted, never runs the cycle.
- **No credentials in tracked files, task arguments, command lines, or chat.** The lab password
  is in Windows Credential Manager (`LabCredential.ps1`); never print it, never write it to a
  tracked file.
- **Commit and push after every closed ticket** (`git pull --rebase; git push`). Export the
  tracker (`bd export -o .beads/issues.jsonl`) before every push. If context is lost, the
  tracker and git are the resume point - not this conversation.

## 2. The loop

Repeat until a stop condition holds:

1. **Observe.** `bd ready` and `bd list --parent -35qb --status open`. Re-read this document's
   phase table to find the current phase (the earliest phase with an open ticket).
2. **Pick** the highest-priority open, unblocked ticket in the current phase. `bd update <id> --claim`.
3. **Read the ticket.** The ticket is the spec. Its description and `--acceptance` field are
   the definition of done for that ticket. Do not widen it.
4. **Act.** Make the change. Write scripts to files and run the files; never pass multi-line
   PowerShell through a shell `-Command` string (quoting eats it every time).
5. **Verify with the evidence the ticket names.** Unit tests for unit-level claims; a lab row
   for any claim about behaviour across a reboot, a task, an identity, or a limit. Read the
   evidence (`summary.json`, then a grep of decisive log lines); do not assume it.
6. **Record.** `bd close <id> --reason "<what changed, what evidence, where it lives>"`. Name
   the evidence directory for any lab row. Commit with a message that says why, not what.
   Export, push.
7. **Reconcile.** If the work revealed a new defect, file it under the epic before moving on.
   If it disproved a ticket's premise, close that ticket as invalid with the reason and
   re-scope to the real cause.

One ticket per iteration. Background lab rows may run across iterations; check them when the
notification arrives, never by polling.

## 3. Phases and tickets

Work phases in order. Inside a phase, tickets marked ∥ may run concurrently with the others
in that phase; everything else is sequential.

### Phase 0 - hygiene and lab readiness (no orchestrator edits)

| Ticket | Action |
|---|---|
| `-35qb.6` | Append each poll to `host-timeline.txt` as it happens. Do this first; every row after benefits. |
| `-3tw` | Close as already implemented: `tests/integration/lab/`, shipped v2.5.77. |
| `-l6yq` | Close with evidence `C:\HyperV\evidence\B-headless-terminal-v5-*`: terminal state reached, did not converge (KB5007651), re-scoped to `-k610`. |
| `-781l`, `-h58s` | Close: passed under v2.5.77 (evidence dirs `C-*` and `E-*` under `C:\HyperV\evidence`). Note "not re-run since; re-run in Phase 4". |
| `-21p2` | Close as invalid: a stopped `wuauserv` is the resting state; `Test-WindowsUpdateServiceReady` starts it each pass. Real cause is `-k610`. |
| ∥ build `lab-b` | `./tests/integration/lab/New-LabGuest.ps1 -Name lab-b -Checkpoint baseline-clean -CpuCount 2` then `New-LabHeadlessCheckpoint.ps1 -VMName lab-b`. Background job. Host has ~9 GB free: **two guests at 4 GB, never three.** Rename `boot-upd-matrix` mentally as `lab-a`; do not rename the VM. |

### Phase 1 - the v2.5.78 review findings

| Ticket | Owner | Notes |
|---|---|---|
| `-35qb.1` ResumeUserSid dead code | main | Declare the property in the constructor (~L1897) and the add-if-missing normaliser (~L1959). Test must go constructor → discovery → resolver, not call the resolver directly. |
| `-35qb.4` NoInteractiveUser exhaustion test | main | Behavioural test per the ticket's three assertions. |
| `-9nj2` withheld logged as crash | main | Distinguish "withheld" from "crashed" in the resume message. |
| ∥ `-35qb.3` beads export identity | Sonnet subagent, worktree | Forward-only sanitising in the export path; rewrite existing rows once; no history rewrite. |
| ∥ `-35qb.2` TESTING.md reporting rule | Sonnet subagent, worktree | Add the PASS/PARTIAL/FAIL/NOT RUN rule to `docs/TESTING.md`. The notes correction happens in Phase 5. |
| ∥ diagnostics cluster `-vla0`, `-h2z0`, `-qibm`, `-5vbd` | Sonnet subagent, worktree | These touch `Export-BootUpdateDiagnostics.ps1`; if one needs an orchestrator change, the subagent reports it and the main session makes it. |
| ∥ `-k610` diagnosis | background job on lab-a | See section 4. Runs while the above proceed. |

After Phase 1: `./tools/Invoke-TestGates.ps1` must pass. Then run row A on lab-a as a
checkpoint that the orchestrator edits changed nothing about reboot accounting.

### Phase 2 - the -k610 decision

Apply the decision rule in section 4. Implement the branch it selects. Then run row B
(headless) on lab-a. Success criterion for this phase: row B **converges** (`Completed: true`,
`TasksRemaining: 0`, no state file) with a QUALIFIED claim carrying deferred inventory for the
user-scope work. That run also closes `-cgua` (the bounded user wait must appear in the log:
"No interactive user appeared after N rediscovery attempts"). If row B still does not converge
after the fix, the decision was wrong: re-read the evidence, pick the other branch once. If it
still fails, stop condition 3 applies.

### Phase 3 - matrix backlog (∥ across two guests)

| Row | Guest | Ticket | Command shape |
|---|---|---|---|
| D failed restart command | lab-b | `-n6qn` | `Invoke-LabRow -Row D -Checkpoint baseline-clean -ArmReboots 1 -InjectWhen 'Initiating forced shutdown' -InjectAction { <break shutdown> }` |
| F PS5.1-only bootstrap | lab-b | `-7yeb` | Needs a checkpoint **without** PowerShell 7: derive one from `baseline-clean` by uninstalling PS7 (`msiexec /x`), cold checkpoint `baseline-ps51`. The bootstrap must install PS7 itself. |
| G killed-process recovery | lab-a | `-57yf` | The v2.5.77 attempt matched nothing: the kill filter looked for `Invoke-BootUpdateCycle` in a pwsh command line, which is not how Deploy launches it. Find the real process first (`Get-CimInstance Win32_Process` on the guest during a row) and kill by that. |
| `-ynvn`, `-2bx` | - | investigate with the same evidence discipline; close, fix, or re-scope with reason. Time-box each to one iteration. |

Each row closes its ticket with the evidence directory and the PASS/PARTIAL/FAIL word.

### Phase 4 - -jjyx deepening (optional but preferred)

Read the ticket; its acceptance is rows A and B. Design the interface first (the ticket
sketches it), implement in the main session, run rows A and B on both guests concurrently.
If after one full attempt either row regresses, revert the refactor, close the ticket as
deferred with the evidence, and continue - the release does not depend on it.

### Phase 5 - ship v2.5.79

1. Bump `2.5.78` → `2.5.79` in `Invoke-BootUpdateCycle.ps1` (line ~357), `upd.cmd` (two
   places), `README.md` (the installer pin; the compat hash stays unless `Install-UpdCompat.ps1`
   changed - compute it with `Get-FileHash`).
2. Write the `v2.5.79` section in `RELEASE_NOTES.md`: Fixed / Changed / Corrections to v2.5.78
   / Validation. Corrections must include: the dead SID preference claim, and the gate line
   that said PASS for a non-converging row. Validation reports **every** gate and **every** row
   with the vocabulary in section 1, and names evidence directories.
3. `./tools/Invoke-TestGates.ps1` — all gates PASS, or the release does not proceed.
4. Run rows A and B against the final build (both guests, concurrently). Both must meet the
   claims the notes make about them. If not, fix and repeat from step 3.
5. Two-axis review: spawn two subagents (model: opus) with the briefs in
   `.claude/plugins/.../code-review` semantics: Standards (repo rules + smell baseline) and Spec
   (the epic + tickets + the notes as claims to verify). Fix every HARD finding; fix or file
   every judgement call; re-run step 3 if code changed.
6. Commit, push, then `./tools/New-Release.ps1 -Tag v2.5.79 -Title "v2.5.79 - <two words>" -NotesPath RELEASE_NOTES.md`.
7. Verify: `gh release view v2.5.79 --repo nanoDBA/boot-upd --json isDraft,assets` → not draft,
   20 assets. Close the epic with the release URL. Export, push. Write the handoff. Stop.

## 4. The -k610 decision rule

Question: does "Installed [1] Updates" for KB5007651 correspond to anything changing on the
guest?

Diagnosis (background job on lab-a from `baseline-no-autologon`, run before/after one pass):
```
Get-MpComputerStatus | Select AMProductVersion, AMEngineVersion, AntivirusSignatureVersion
Get-ChildItem "$env:ProgramData\Microsoft\Windows Defender\Platform" | Sort {[version]$_.Name}
Get-WinEvent -LogName 'Microsoft-Windows-WindowsUpdateClient/Operational' -MaxEvents 200 |
  Where-Object Message -match '5007651' | Select TimeCreated, Id, Message
(New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().QueryHistory(0,50) |
  Where-Object Title -match '5007651' | Select Date, ResultCode, Title
```

Decision:
- **Platform version advances and WU history shows ResultCode 2 (succeeded) each time, yet the
  next scan re-offers it** → environmental re-offer. Implement: after an update is recorded
  installed with success in the same boot and is re-offered on the final scan, record it as
  *deferred inventory* with kind `ReofferedAfterSuccess`, carrying the KB and the observed
  version evidence, and do **not** count it as retry fuel. The claim becomes qualified
  convergence. This is CONTEXT.md's "negative evidence" and "deferred inventory" exactly.
- **Platform version does not advance, or history shows a failure code** → the phase counted an
  install that did not happen. That is a verified-update truthfulness defect: fix the phase to
  take the WU result code, not the "Installed [n]" line, as the evidence, and treat a failed
  result as retryable up to the existing budget.
- **Ambiguous** (history absent, version unreadable) → pick the first branch, say so in the
  ticket, and add the diagnosis output to the evidence.

## 5. Lab runbook

- Guests: `boot-upd-matrix` (lab-a), `lab-b`. Checkpoints: `baseline-clean` (autologon on),
  `baseline-no-autologon` (verified headless). Restore only through `Invoke-LabRow`.
- Row B: `Invoke-LabRow.ps1 -VMName <guest> -Row B-<label> -Checkpoint baseline-no-autologon -ArmReboots 1 -SystemContext -DeployArgs '-MaxUserIdentityWaits 2' -TimeoutMinutes 45`
- Row A: `Invoke-LabRow.ps1 -VMName <guest> -Row A-<label> -Checkpoint baseline-clean -ArmReboots 3 -TimeoutMinutes 45`
- Always run rows as background jobs (`run_in_background`), never poll; read
  `summary.json` first, then grep the log for `CYCLE (STARTED|RESUMED|COMPLETE)|new Windows boot session|recovery limit|Deferred inventory|No interactive user`.
- `DeployTaskResult` 267014 or 1073807364 on a row that rebooted is the launcher task being
  killed by the reboot - benign. 0x80070002 means the task's executable is missing.
- `RebootsClaimed` is `$null` when no completion claim was made; that is not a disagreement.
- Reboot the guest only with `shutdown /r` inside it. `Restart-VM` is a hard reset and discards
  writes. Checkpoints are taken cold (guest off).
- If the guest is unreachable for >10 min outside a reboot, take a screenshot
  (`Get-VmScreen.ps1`) before doing anything else; OOBE and boot-menu stalls are console-only.

## 6. Traps that have each cost hours here

- Persisted timestamps: anything read back from the state file is a `[datetime]` and must go
  through `ConvertTo-BootUpdateTimestampString` before comparison; never bind one to `[string]`.
  Round-trip tests must populate the field they claim to cover.
- Never compare raw uptime direction to detect a reboot; use `Test-BootUpdateMonotonicBootMoved`.
- PowerShell variable names are case-insensitive: a loop local `$parentPid` overwrites a
  parameter `$ParentPid`.
- A `[pscustomobject]` throws on assignment to an undeclared property; an empty `catch {}`
  around such an assignment is a silent no-op. Declare state fields in the constructor.
- This checkout is on Google Drive: CRLF warnings on commit are normal; whole-file diffs with
  no real change are line endings - check with `git diff --stat` before committing.
- Multi-line PowerShell through a shell `-Command` string gets mangled. Write a `.ps1` to the
  scratchpad and run it.
- `bd dep add A B` makes A **blocked by** B and hides A from `bd ready`. For "related" use
  `bd dep relate`. Epics cannot block tasks.

## 7. Cost rules

- Lab rows are background shell jobs: zero agent tokens. Never assign an agent to watch one.
- Subagents: at most one Sonnet worker (Phase 1, worktree) and two Opus reviewers (Phase 5).
  Haiku may digest a log into a table. **Never fork.**
- Batch independent tool calls in one turn. Do not re-read files you have not changed.
- When the conversation grows long, finish the current ticket, push, and continue in a fresh
  session from `bd show -35qb` and this document. The tracker is the memory.

## 8. Handoff (written on every stop)

Append to `docs/agents/epic-35qb-handoff.md` (create if absent), then commit and push:
- Which stop condition fired.
- Tickets closed this session, with evidence directories.
- The exact next ticket and the command to resume.
- Anything you assumed rather than verified, in one list.

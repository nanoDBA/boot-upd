# v2.5.79 post-mortem: issues, failures, status

Written 2026-09-09 at the end of the unattended session that shipped v2.5.79. The handoff
(`epic-35qb-handoff.md`) says how to resume; this says what happened, what broke, and what is
still broken. Release notes carry the user-facing account; this is the engineering one.

---

## 1. Status

| | |
|---|---|
| Release | [v2.5.79](https://github.com/nanoDBA/boot-upd/releases/tag/v2.5.79) — not a draft, 20 assets, target `938de32` |
| Epic `-35qb` | CLOSED |
| Children | 28: **25 closed, 3 deferred** with reasons, 0 open |
| Gates | unit-and-process-behavior **PASS** (478/0), user/SYSTEM boundary **PASS**, published-launcher upgrade **PASS** |
| Rows A and B | **PASS** against the shipping build, both guests |
| Matrix gate line | **PARTIAL** — rows D and G partial, rows C, E, F not run against this build |
| Working tree | clean, pushed, `master` level with `origin/master` |
| Lab guests | `boot-upd-matrix` and `lab-b`, both powered off |

Deferred, each with a written reason on the ticket:

- **`-35qb.10`** — a cycle killed mid-pass is not resumed until the next logon or boot. The
  only deferral that leaves a real durability gap. Take this first.
- **`-5vbd`** — retire log-parsing for machine-readable manifest fields. Waits for a real
  diagnostics bundle carrying the new sidecar.
- **`-35qb.7`** — Hyper-V KVP status beacon. Largely obviated by `-35qb.6`'s streamed timeline.

---

## 2. Defects found and fixed

Twenty-one are tabulated below, sixteen in the updater and five in the lab harness; section
2.3 adds the tooling, tracker and documentation issues.

**Ten of the sixteen updater defects were in no ticket.** Six of those ten were found by
running a row on a real machine (#2, #4, #5, #6, #7, #10) and four by the two-axis review
(#13, #14, #15, #16). The remaining six updater defects (#1, #3, #8, #9, #11, #12) came from
tickets that already existed.

### 2.1 In the updater (shipped in v2.5.79)

| # | Defect | How it was found | Commit |
|---|---|---|---|
| 1 | `ResumeUserSid` assigned to an undeclared `[pscustomobject]` property inside an empty `catch`, so the SID preference was dead and `AzureAD\`/`MicrosoftAccount\` machines degraded to SYSTEM-only | ticket `-35qb.1` (v2.5.78 review) | `af4c728` |
| 2 | Fixing #1 **reopened** the unbounded user wait: LogonUI's record of a *past* session made every headless machine look like one with a user coming back | lab row B hung at `UserContextPending` | `4aebb57` |
| 3 | `KB5007651` re-offered after a successful install was treated as retry fuel forever | ticket `-k610`, diagnosed with before/after probes | `4385fd9` |
| 4 | WU history dates are UTC tagged `Unspecified`; `ToUniversalTime()` added the offset twice, and could carry a pre-window success across the line | reading row B's log, not its test result | `5744a28` |
| 5 | The re-offer window was the **boot**, so the evidence was lost across the very restart the classification exists to stop repeating | lab row B against the shipping build | `22e2733` |
| 6 | The re-offer message said "since this boot" while counting over the run | lab row B, final validation | `c9bb8e9` |
| 7 | The dated `-RetryAt` watchdog **had never been armed in any release**: `[Nullable[datetime]]` binds to a plain `DateTime`, so `.HasValue` was always `$null` | lab row C; confirmed by `Export-ScheduledTask` on the guest | `f74b693` |
| 8 | A timeout kill orphaned `msiexec` (parented to `services.exe`, outside the killed tree), and later passes collided with it at 1618 | ticket `-ynvn` | `3dbdd6f` |
| 9 | A deliberately withheld phase was logged as a crash | ticket `-9nj2` | `6eb3ac3` |
| 10 | `RESUMED (after reboot)` announced on passes that followed no reboot | lab row D | `1338f19` |
| 11 | The diagnostics manifest inferred pending-cleanup state from the **absence** of a log line | ticket `-h2z0` | `fa1bf87` |
| 12 | The explicit 3010/1641 short-circuit skipped the pending-file recording entirely | ticket `-qibm` | `fa1bf87` |
| 13 | `Test-WindowsUpdateConvergence` early returns omitted fields, so the caller read `@($null)` — count **1** — and the **ordinary converged path** threw on `[datetime]$null` | Standards review | `45e74c6` |
| 14 | The evidence sidecar was **not** written under `-WhatIf`, despite the notes, ADR-0004 and the ticket all saying it was (`Set-Content` honours `ShouldProcess`) | Spec review | `45e74c6` |
| 15 | A stale `ResumeUserSid` could outrank a fresh name at a resolver that prefers SIDs absolutely | Standards review | `45e74c6` |
| 16 | `Test-BootUpdateInstallerMutexHeld` read an ACL denial as "no transaction", contrary to ADR-0005 | Standards review | `45e74c6` |

Items 13 and 14 deserve emphasis: **both are the exact failure mode this release existed to
correct**, committed by this session, and caught only because the review ran. #13 was a crash
on the common path that every unit test missed, because they all mock the background scan.

Also changed, not a defect: `-jjyx` deepened boot-session identity into one call returning
`{ NewBoot, Reason, RebootCounted, State }` (`66d85ad`).

### 2.2 In the lab harness

| # | Defect | Consequence | Commit |
|---|---|---|---|
| 17 | `$x = if (…) { @(Get-Content …) }` collapses a one-line log to a **String**, so `$string -match` returns a boolean whose `.Count` is 1 | Row D reported `Completed: true` with `Passes: 0` and stopped 80 seconds in — a PASS-shaped result for a cycle that had not started | `918f641` |
| 18 | An injection that **threw** still set `Injected = true` | Row G v3 killed nothing and would have been read as a successful kill | `0651d8c` |
| 19 | `Completed` came from whether a poll caught the completion line | Row B completed 28 s before the deadline and `summary.json` said `Completed: false` | `f786c91` |
| 20 | The PSSession sync path copied over the existing tree without clearing it | A file deleted on the host survived on the guest while the orchestrator hash still matched | `45e74c6` |
| 21 | `PowerShell Direct` sessions cannot be opened to a PowerShell 5.1-only guest under **any** configuration name | Row F could not run at all | `a66c0f6` |

### 2.3 In tooling, tracker and docs

- **`Invoke-TestGates.ps1` threw a bare count** and discarded the failing test names. Fixed
  (`bb69aa6`) — see failure F10 below for why that mattered.
- **The beads export leaked the maintainer's identity into a public repo**: 600 fields across
  216 rows (`created_by` 274, `owner` 211, `assignee` 113, `author` 2), plus one real profile
  path in ticket prose. Sanitised forward-only (`205b4c2`, `4834eeb`); the prose case was
  corrected in the tracker itself so it survives future exports.
- **The first privacy sweep was narrower than the rule, and missed a real computer name.**
  After the release was cut, a re-read of `.claude/rules/public-repository-privacy.md` turned
  up a real computer name in ticket `-3tw`'s notes — `This machine (<REDACTED>) is Windows 11 PRO`, a real computer
  name, which the rule forbids alongside usernames. The earlier check had verified "0 matches
  for the real name" and stopped there; the rule covers usernames, **computer names**,
  domains, employer and customer names, and private drive layouts. Corrected in the tracker so
  it survives export, and forward-only, consistent with the decision recorded on `-35qb.3`.
  The v2.5.79 release notes and the published release body were checked and are clean.
  Lesson: verify against the whole rule, not against the last thing that went wrong.
- **`docs/TESTING.md` had no written reporting rule** — PASS/PARTIAL/FAIL/NOT RUN was
  re-derived each release. Now stated (`6ebf845`).
- **A new test could not fail**: an ordering assertion searched for a string the boot-session
  restructure had deleted, so `IndexOf` returned `-1`, and `-1` is less than everything. Found
  by the Standards review (`45e74c6`).
- **`TuiExperience.Tests.ps1` dot-sources by name** and broke when the timeout path gained a
  call to `Wait-BootUpdateInstallerMutex` (`9e5ee38`).

---

## 3. Failures during the session

Distinct from defects: these are things that *failed while running*. Several were
environmental and produced no code change.

| | Failure | Cause | Resolution |
|---|---|---|---|
| F1 | lab-b unusable: credential rejected over PowerShell Direct, guest rebooting repeatedly, black console | Unknown; its `staged`/`fresh` checkpoints were from an earlier build | **Rebuilt lab-b from scratch** per Phase 0, then derived `baseline-clean`, `baseline-no-autologon` and `baseline-ps51` |
| F2 | Row D run 1 ended in 80 s claiming convergence | Harness defect #17 | Result **discarded**, harness fixed, row re-run |
| F3 | Row F runs 1 and 2 died at `New-PSSession` | Defect #21; the first fix (hard-coding `Microsoft.PowerShell`) then broke PS7 guests | Try default → fall back → zip over the guest service channel |
| F4 | Row G v2 could not distinguish "killed" from "rebooted" | The kill raced a planned restart already in flight (`-ArmReboots 1`) | Re-shaped the row: no armed reboot, kill after phase promotion |
| F5 | Row G v3 injection threw | `try/catch` used as an **expression**, which PowerShell does not allow | Rewrote the scriptblock; also fixed defect #18 so this can never look like success |
| F6 | Row B (first `-k610` fix attempt) hung at `UserContextPending` for 20+ min | Defect #2 | Row stopped deliberately, defect fixed, row re-run |
| F7 | Row B ship attempt 1 did not converge — 6 passes, 45-min timeout | Defect #5 | Fixed, re-run |
| F8 | Row B ship attempt 2 converged but reported `Completed: false` | Defect #19 | Fixed, re-run to get an unambiguous artifact |
| F9 | Test gate failed at 1 of 466 | Defect: `TuiExperience` missing dot-source | Fixed (`9e5ee38`) |
| F10 | Test gate failed **once** at 1 of 477, passed on five later full runs | **Unknown — the failing test cannot be identified**, because the gate threw a count and discarded the results | Gate now names failing tests (`bb69aa6`). Whether that failure was real is **not known** |
| F11 | `New-Release.ps1 -NotesPath RELEASE_NOTES.md` failed | GitHub rejects a release body over **125,000 characters**; the accumulated file is past it | Cut the release from the extracted `## v2.5.79` section. **Not fixed in the tool** |
| F12 | Two `git commit` calls produced mangled messages / a pathspec error | PowerShell expanded `$WhatIfPreference` inside a double-quoted `-m`, and PowerShell has no `<<` heredoc | Write the message to a file, `git commit -F` |

### Aborted runs that left evidence directories

F6, F7 and F8 were stopped or superseded. Two of them left directories **sharing a row label
with the passing runs**:

| Directory | What it is |
|---|---|
| `A-v2579-final-…-115623` | **abandoned** (stopped mid-run) — `host-timeline.txt` only |
| `B-v2579-final-…-115621` | **abandoned** (stopped mid-run) — `host-timeline.txt` only |
| `A-v2579-final-…-145814` | **the passing row A** — full evidence set |
| `B-v2579-final-…-145818` | **the passing row B** — full evidence set |

**The discriminator is `summary.json`**: an abandoned row has none. Anyone citing
`A-v2579-final` or `B-v2579-final` must use the `1458xx` timestamps.

---

## 4. What is still broken or unverified

Every item here is also stated in the v2.5.79 release notes; this is the same list without
the prose.

### Known gaps

1. **A cycle killed mid-pass is not resumed until the next logon or boot** (`-35qb.10`,
   deferred). Row G established that state integrity holds through a kill — the file parsed
   valid before and after, no `.tmp`, promoted phases recorded — but nothing resumed for the
   remaining 37 minutes. The chain armed at pass start is boot- and logon-scoped, and Task
   Scheduler's restart-on-failure does not cover a pass launched by `Deploy` or `upd.cmd`
   rather than by the task, which is always true of the **first** pass. Fixing it means
   putting a repeating trigger into the resume chain, which needs its own lab row.
2. **`New-Release.ps1` cannot be used as documented.** The next release will hit F11 again.
   Either teach the tool to extract the current section, or change the runbook.

### Claims resting on unit tests only

3. **The pending-cleanup sidecar** (`-h2z0`) and **the orphaned-installer wait** (`-ynvn`)
   have never run on a guest. No row this cycle timed out a package, and no diagnostics bundle
   has been captured from a machine running the sidecar. `-5vbd` is deferred waiting on
   exactly that bundle.

### Evidence that is weaker than it looks

4. **Row F's PASS says nothing about this build.** `upd.cmd`'s documented path recovers the
   checksummed bundle from the latest GitHub release, and its log shows
   `Checksummed bundle updated to v2.5.78`.
5. **Rows C, D and G ran against commits one to three behind the shipping build.** None of
   those commits touched the paths those rows exercise, but the rows were not re-run.
6. **Row E was not re-run at all** — it is a v2.5.77 pass.
7. **The UAC consent count for the fresh-install flow was not measured.** Row F records
   `MaxConsentPrompts: 0`, but the row launches through a task at `RunLevel Highest`, which
   cannot raise a consent dialog. That zero describes the harness.
8. **`Test-BootUpdateInteractiveUserPresent` reads the console session.** An RDP-only server
   with a signed-in administrator reads as having no interactive user and is bounded. Safe
   direction, stated in the notes, but not tested on such a machine.
9. **The gate flake (F10) is unexplained.**

---

## 5. What this session says about the process

Three observations worth keeping, because they are the reason the release is what it is.

- **The unit suite agreed with the code in every machine-found defect.** #2, #4, #5, #6, #7
  and #10 in the updater, and #17, #18 and #19 in the harness, were all invisible to a green
  suite. The project's existing rule — nothing ships without rows A and B against the final
  build — earned its keep repeatedly: row B alone caught #2, #4, #5 and #6.
- **The two-axis review caught a crash on the common path and a false claim in the notes.**
  Both were committed by this session, hours apart, while it was actively correcting the same
  class of defect in v2.5.78. Self-review would not have found either.
- **A privacy check that verifies one field is not a privacy check.** The identity
  sanitisation was thorough about the four structured fields it set out to fix and verified
  itself precisely — and still left a real computer name in prose, because the verification
  was written against the defect rather than against the rule.
- **A one-line label collision nearly poisoned the evidence.** F2's harness bug produced a
  PASS-shaped `summary.json` for a cycle that never started. It was caught only because the
  numbers inside it disagreed with each other (`Completed: true`, `Passes: 0`). Reading the
  fields rather than the verdict is what caught it.

# September 12 diagnostics and VM validation

## Findings

The latest cycles in both supplied v2.5.79 captures completed with explicitly
deferred inventory. Historical provider failures in the accumulated logs are not
failures of these latest cycles. The sanitized-log hashes were checked against
their manifests; both captures report stable, complete snapshots.

| Capture suffix | Latest cycle (log-local time) | Reported outcome |
|---|---|---|
| `142250` | 10:10:21–10:19:22 | Two passes, one reported reboot, five verified updates, one unknown-version Winget deferral |
| `142346` | 10:06:39–10:10:32 | One pass, zero reported reboots, three verified updates, two provider actions, explicit Winget deferrals and advisory cleanup |

These are separate captures, not a shared machine timeline. Their reboot totals
are the updater's claims; the supplied bundles do not provide an independent OS
boot-event witness.

### Empty cleanup incorrectly labeled persistent

[Issue #53](https://github.com/nanoDBA/boot-upd/issues/53), centralized Beads
`on_boot_update_reboot_loop_while_pending_restarts_exist-qsuw`, records a
reproduced exporter defect. The `142250` manifest reported `Persistent=true`
despite both selected observations being `observed-empty`, with no categories
or fingerprints. The exporter compared equal empty signatures and interpreted
that equality as surviving cleanup.

The fix requires an equal **nonempty** signature for persistence. Empty-to-empty
and cleared comparisons are false; missing or skipped observations remain
unknown. A regression test was added, and the existing session-isolation test
was corrected without removing its isolation assertions.

Replaying the actual captured sidecars through the production function gives:

| Capture | Sidecar records | Before/after fingerprints | Old result | Corrected result |
|---|---:|---|---|---|
| `142250` | 7 | 0 / 0 | true | false |
| `142346` | 7 | 141 / 141 | true | true |

The nonempty control comprises 15 application, 120 non-system and six legacy
PackageManagement cleanup entries. Their unchanged fingerprints establish
persistence through this cycle, which did not reboot. They do not establish
that those particular requests survived a reboot or identify why they remain.
[Issue #45](https://github.com/nanoDBA/boot-upd/issues/45) retains that separate
investigation. No shared pending-file queue was rewritten.

### Deferred inventory and historical failures

The larger capture accounts for machine-scope unknown-version and
install-technology deferrals, plus user-scope pinned and elevation-blocked
inventory. The smaller capture reports one unknown-version deferral. Neither
latest cycle contains an `[Error]` line; provider progress and completion records
are present in the same bounded sections. This supports their qualified
completion, not an assertion that every installed package is current.

Older Winget, Chocolatey and Windows Update failures remain historical evidence.
They were not reopened as current regressions without reproduction. Interrupted
cycle evidence remains separately tracked in
[issue #47](https://github.com/nanoDBA/boot-upd/issues/47).

### VM setup observations

The first interactive attempt lost its PowerShell Direct transport while the
harness was arming optional-feature reboots, before the updater launched. A
later compact query found CBS reboot evidence; it did not establish completion
of the generator. The failure artifacts and a cold guest checkpoint were
preserved before retrying from the baseline. This is not an updater failure.

The first headless deployment spent an extended interval installing required
modules before creating any updater log or state. It subsequently advanced
from PSWindowsUpdate to BurntToast; a permanent install hang was not established.
A separate guest-user probe failed against a gallery package endpoint while
the NuGet index answered successfully. That probe does not establish the exact
failure of the SYSTEM installer.

[Issue #65](https://github.com/nanoDBA/boot-upd/issues/65), Beads
`on_boot_update_reboot_loop_while_pending_restarts_exist-ziez`, tracks bounded
required-module acquisition and durable setup evidence. The cached-module
retry uses PSWindowsUpdate 2.2.1.5 and BurntToast 1.1.0, with source-copy and
transfer hashes verified. This supplies lifecycle-test prerequisites; it does
not validate fresh online module acquisition.

The first kill-recovery attempt also stopped before deployment when Hyper-V's
guest file-copy service returned `0x800710DF` (device not ready). Its evidence
was preserved and the retry added bounded retries for the idempotent module
transfer. [Issue #67](https://github.com/nanoDBA/boot-upd/issues/67), central
Beads `jflw`, tracks durable setup-stage reporting and bounded readiness checks.
It explicitly excludes blindly retrying non-idempotent feature arming.

## Issue synchronization

Nine open central backlog items were mirrored to GitHub with explicit Beads
backlinks and historical-report qualifications: #54–#58, #60–#61 and #63–#64.
An ambiguous creation response produced identical #58 and #59; #59 was verified
as a duplicate and closed in favor of #58. Existing #45 and #47 now have central
Beads counterparts (`ui8c` and `2kmy`). Deferred items were left deferred.

The investigation and VM validation are tracked by
[issue #62](https://github.com/nanoDBA/boot-upd/issues/62), Beads
`on_boot_update_reboot_loop_while_pending_restarts_exist-d2d9`.

## Validation

The focused diagnostics tests failed before the fix (20 passed, two failed),
then passed after it (22 passed, zero failed). The standalone production-function
reproducer also passed empty, unchanged-nonempty and cleared controls.
The full exporter produced valid ZIPs from both supplied sidecar replays and
from the completed interactive VM's captured main log and sidecars. That VM
export reports a complete snapshot, completed capture state and
`PendingFileCleanup.Persistent=false` for its empty observations.

| Local gate | Result |
|---|---|
| Unit/process behavior | PASS — 495 tests, none failed or skipped |
| User/SYSTEM mutex boundary | PASS |
| Published-launcher upgrade | PASS |

GPT-6 Astra reviewed the exporter and regression-test diff with no actionable
findings. The VM driver runs rows as background jobs, preserves a failed guest
instead of restoring over its evidence, and records state/task snapshots and
session observations. Self-update is disabled to keep the tested source fixed.

The first GitHub quality run exposed five existing lab-credential analyzer
errors, separately tracked in [issue #66](https://github.com/nanoDBA/boot-upd/issues/66).
The correction centralizes the required plaintext-to-SecureString compatibility
conversion and documents two function-scoped analyzer exceptions. Credential
store behavior, environment precedence and the existing setter interface are
preserved. Three focused tests pass, the tracked-script analyzer reports zero
errors, and Astra approved the diff. An unrelated ignored local worktree still
contains the old code; the clean GitHub checkout is the authoritative recursive
analyzer check.

[Clean CI for `cd34699`](https://github.com/nanoDBA/boot-upd/actions/runs/34702592369)
passed all jobs: 498 tests with zero failures or skips, zero analyzer errors,
the user/SYSTEM exclusion gate and the published-launcher upgrade gate.
Issue #66 and its central Beads counterpart are closed.

### Interactive multi-reboot row A

**PASS for the configured row.** The cached-prerequisite retry completed at
11:35:44 after four user-context passes. Three OS event-log startup records
inside the cycle matched the three claimed reboots; the baseline startup was
excluded. The final Windows Update assessment contained no applicable updates
in the configured Critical/Definition/Security scope. All five service health
checks passed, CBS was clear, and the final cleanup observations were empty.

Continuation tasks fell from two to zero, corroborated by successful enumeration
of 227 other tasks. Active state was removed. Windows Update and Defender were
exercised; absent package managers were skipped and are not counted as tested
integrations. The earlier setup/transport failure and the first cache retry's
PowerShell-version probe mismatch are retained as separate setup failures.

Evidence labels: `vm-runs-retry2/A-sep12-boot-upd-matrix-20260912-111434`
and `vm-runs-retry2/A-sep12/final-evidence.json`.

### Headless SYSTEM row B

**Qualified completion; PARTIAL for full provider convergence.** The cycle
completed at 11:53:44 after five SYSTEM passes and two claimed reboots, matching
two OS startup records inside the cycle. All five service health checks passed.
After two user rediscovery attempts, Winget, Scoop and VS Code user inventory
remained deferred because no interactive user appeared. Windows Update also
retained one `ReofferedAfterSuccess` entry for KB5007651; it did not claim a zero
applicable-update result or retry the re-offer after recognizing its
successful-install history.

All 97 successful session observations recorded no console user and no Explorer
process. This is sampled evidence, not continuous event-level coverage. Final
enumeration found 226 other tasks and zero continuation tasks; active state was
absent, CBS was clear, and the cleanup observations were empty.

The original 45-minute harness snapshot was a **timeout while still active**.
It is preserved, not overwritten. Continued observation of the same cycle
captured the terminal result at 11:54. A scheduled continuation launched at
11:44:28 but emitted its first cycle log at 11:47:29; task and process timestamps
confirm that this was a post-launch delay, not a missed trigger.

The live guest exporter hash matched the fixed source. Its ZIP reports a
completed, complete snapshot with `Persistent=false` for the empty cleanup
observations. Evidence labels: `vm-runs/B-sep12/extended-final-evidence.json`,
`extended-observations.jsonl` and `live-export-result.json`; the preliminary
snapshot is under `vm-runs/B-sep12-lab-b-20260912-104515`.

### Process-kill recovery row G

**PASS for recovery and final convergence.** The durable checkpoint captured
at 11:47:35 retained completed Winget/Chocolatey phases and unfinished Windows
Update. The intended Deploy process, PID 9572, was terminated; its scheduled
action recorded the termination at 11:48:25.511. The earlier capture timestamp
is not used as the termination time.

Task Scheduler record 76 explicitly identifies a **time trigger** at
11:48:30.806. Records 77–79 connect that task instance to replacement PID 5148.
It resumed on the same boot and reported the interrupted Windows Update phase.
The unqualified completion at 11:56:38 reports two passes and zero reboots,
matching the OS evidence. Windows Update's final assessment was empty, all
five health checks passed, cleanup observations were empty, CBS was clear,
and continuation tasks and active state were removed.

A later SYSTEM timer probe, PID 4784, detected the held mutex and exited
successfully while the recovered user process continued. This provides a
separate healthy-probe control. Recovery attribution rests on the scheduler's
explicit trigger and process records; the security log contains other logons
and is not presented as proof that no logon event occurred.

Evidence labels: `vm-runs-retry3/G-sep12-boot-upd-matrix-20260912-114303`,
`G-sep12/scheduler-final-evidence.json` and `G-sep12/compact-evidence.json`.
The original 98 MB capture is retained privately: its size comes from nested
PowerShell metadata attached to a captured string, not provider-log volume.
The compact digest selects the actual state and event fields.

## Delivery and remaining work

The exporter fix is commit `7230e48`; lab credential quality-gate compatibility
is commit `cd34699`. No product version was bumped and no release was published.
The two fixed issues (#53 and #66) are closed in both trackers. Online module
setup (#65), lab setup resilience (#67), and the synchronized backlog remain
open. GPT-6 Astra reviewed code and VM results; lower-model workers handled
triage, implementation, synchronization and compact evidence preparation.

The unattended drivers, raw logs and intermediate failures remain in local
evidence storage. Both guests were shut down cleanly after evidence capture.
The pre-existing Git packed-refs lock still prevents pruning two obsolete
remote-tracking references; commits and pushes work. That limitation is recorded
in the existing deferred storage issue `d6u`. Google Drive was not paused and
the active checkout was not relocated.

Raw diagnostics, guest identities and unsanitized local evidence are not
published in this repository.

## Release follow-up: v2.5.80

The later release review found and corrected an additional watchdog-accounting gap: an interrupted `ParallelCohort` checkpoint previously bypassed the retry budget. Commit `98f72e2` charges one recovery per resumed pass, preserves completed provider flags, records the unobserved stop, and reaches the existing retry-limit handoff. Four new behavioral regressions passed; clean CI passed all 502 tests with zero failures/skips, parsing, analyzer checks, user/SYSTEM exclusion, and the published-launcher upgrade gate.

The targeted H acceptance used candidate orchestrator SHA256 `22808f6cd3da71116f0db4ecaddc12526d766cec20fb991444329934aa31a201` and evidence directory `cohort-release/evidence/H-cohort-retry-limit-boot-upd-matrix-20260912-134042`.

- The installed production orchestrator ran directly, with an admin-only fixture directory and a trusted `BeforeDefender` hook holding the persisted cohort entry before provider jobs started. No released script was modified for this final row.
- Two kills were confirmed, on iterations 1 and 2 with retry counts 0 and 1. Distinct checkpoint markers and process IDs, pre-kill state receipts, and death confirmations establish both injections.
- Scheduler time-trigger records map the two subsequent continuation instances to their processes. Iterations 2 and 3 each recorded one `ParallelCohort` unobserved stop. The third pass retained `RetryLimitReached` state, retry count 2, reboot count 0, and removed both continuation tasks; 227 other scheduled tasks provided a positive enumeration control. No completion claim was made.
- The original automated assessment falsely rejected boot equality because one timestamp representation was UTC and another was local time. All four readings normalize exactly to `2026-09-12T17:40:48.500Z`; there was no additional OS boot event.
- Scheduler event 201 encoded the final status as `2147942403` (`0x80070003`). An independent scheduled native `exit 3` control returned `LastTaskResult=3` and the same event encoding. The original assessment and raw XML are retained; the corrected interpretation does not alter the underlying evidence.

Result: **PASS for bounded cohort recovery and safety-stop cleanup; PARTIAL for convergence by design.** This row interrupts the cohort-entry checkpoint, not an active provider process. Earlier A/B/G coverage retains its original build and scope qualifications.

Earlier H attempts were fixture failures and are not counted as interruption coverage: incorrect temporary harness placement/arguments, potentially interfering checkpoint reads, an absent installed hook, the production hook trust false positive, and a PowerShell 5 parser used against PowerShell 7 syntax. Two uninjected attempts completed normal candidate cycles. The final fixture verifies the installed hook with the production trust resolver under PowerShell 7, requires a running injector before launch, archives stale logs, captures scheduler records after a baseline record ID, and only reads state during the deliberate hook hold.

Remaining issues are synchronized in central Beads and GitHub: prerequisite download bounds (#65), unattended lab readiness (#67), final-verification interruption accounting (#71), and read-only permission grants incorrectly rejected by hook trust (#72). The latter two remain known limitations; this release does not claim to fix them.

Publication completed: [v2.5.80](https://github.com/nanoDBA/boot-upd/releases/tag/v2.5.80) is public and latest, targeting commit `c28fc141d6f50a82984391809ab8c40cc464f217`. All ten scripts and ten checksum sidecars were verified against the pushed Git blobs before publication. [Live bootstrap workflow 34709679151](https://github.com/nanoDBA/boot-upd/actions/runs/34709679151) passed the fresh-install and legacy-repair scenarios. Central Beads and GitHub track the completed release in #68.

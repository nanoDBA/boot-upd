# Local lab handoff validation — September 26, 2026

This change makes lab setup and evidence reusable across agent sessions. It does not
change the production updater or establish new SSMS/AWS provider coverage. The entry point
for another agent is the [lab handoff runbook](../tests/integration/lab/HANDOFF.md).
Machine-specific configuration and historical evidence locations stay in ignored files
beside that runbook.

## Handoff-change verification

- Handoff-change full unit/process suite: **PASS**, 606 tests, zero failed or skipped.
- Handoff-change User/SYSTEM exclusion gate: **PASS**.
- Handoff-change published-launcher compatibility gate: **PASS**.
- Final focused lab suite after review fixes: **PASS**, 27 tests, zero failed or skipped.
  This was a separate rerun, not 27 more tests added to the 606-test suite.
- PowerShell parsing and PSScriptAnalyzer Error checks: **PASS** for all seven changed/new
  PowerShell files. `git diff --check` passed.
- Independent static review found no remaining blockers for the handoff change.
- A fresh PowerShell process retrieved the existing credential and authenticated to the
  running headless guest with a read-only command. No password was printed.
- Credential initialization returned `Created=false`: the existing credential was reused,
  not rotated.
- The readiness check reported the running guest unavailable for cold restore. Authentication
  for the powered-off guest remained **NOT RUN**; it was not started.
- Private configuration and local handoff files are ignored by Git and excluded from the
  harness transfer set. The dependency cache was copied to durable local storage and its
  SHA256 matched the earlier cache.

Review addressed unsafe credential replacement, default plaintext output, an unsupported
PowerShell Direct parameter combination, mismatched environment overrides, saved
running-state checkpoints, missing source files, source identity, and deliberately deleted
tracked files. Regression tests use disposable fixtures and mocked credential stores; they
do not rotate real credentials or restore VMs.

## Current CI and subsequent VM evidence

The later current-head GitHub CI run for `3f20003` passed **608 tests**:
[run 36252566075](https://github.com/nanoDBA/boot-upd/actions/runs/36252566075). This is
separate from the handoff change's recorded 606-test local gate and does not validate
multi-reboot VM behavior.

A separate release-final interactive A row passed within scope: four passes, three claimed
and OS-observed reboots, matching source/installed hashes, no state file, zero continuation
tasks, CBS clear, and five health checks passed. Evidence is
`A-release-final-20ce892b295d47fca942660365160534`. It is not a headless SYSTEM result or
AWS repair proof. Its initial deploy task recorded `0xC000013A`, consistent with termination at the first
reboot; that explanation is inferred because Scheduler events were not exported. Do not
blanket-whitelist this code; follow-up [#81](https://github.com/nanoDBA/boot-upd/issues/81).

The later release-final headless B row completed **with deferred inventory** after five
passes and three claimed/observed reboots. Hashes matched, final state was absent, continuation
tasks numbered zero, CBS was clear, and five health checks passed. Evidence is
`B-release-final-03fd1bb381b74fab9525e17ee7f4ced1`. B successfully resumed and cleaned up, but
did not fully converge: without an interactive user, user-scope Winget, Scoop, and VS Code
work was deferred, and Windows Update KB5007651 remained applicable after one successful
install. Overall A/B VM evidence is **PARTIAL**, not a full-patching PASS.

The B Task Scheduler Operational export scanned a bounded 2,000 events and matched 44.
Its lookback began before the test interval, so it corroborates captured task cleanup but
does not establish complete event-log coverage for the run.

Recovered historical B evidence shows that the original row completed **with deferred
inventory** at **10:16:03**, after **five passes and three boots**. The later Hyper-V critical
pause and disk-full event occurred at **11:06:07**. The original B capture does not explicitly
prove active-state absence at final collection, so it cannot support a clean state-cleanup
claim. Keep the deferred inventory in the result.

The fresh A/B rows are complete and independently reviewed. Their results are separate from the handoff
change's local verification. Final release acceptance should retain B's deferred inventory
and the A initial-task-result caveat; do not claim full convergence.

## Limits and safe continuation

The per-VM lease coordinates this harness only. An older runner or direct Hyper-V command
does not acquire it. A terminated host runner can leave guest tasks active, so an available
lease alone never authorizes a restore; inspect the guest and prior evidence first. The
harness also refuses running guests.

For the handoff change itself, the host was not rebooted and no guest was restored. The
separate release-final A and B runs each rebooted their disposable guests three times.
Track the handoff work in [#82](https://github.com/nanoDBA/boot-upd/issues/82) and lab disk
recovery in [#83](https://github.com/nanoDBA/boot-upd/issues/83).

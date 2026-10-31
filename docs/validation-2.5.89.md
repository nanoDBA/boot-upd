# v2.5.89 validation

This is a test-coverage release. The updater behavior is unchanged from v2.5.88.

## Behavioral regression

The test builds a recovered `AttentionRequired` checkpoint by writing the state, zero-filling the primary, and loading the backup. It then runs the real `Invoke-BootUpdateCycle` function in a disposable PowerShell process. State writes, task removal, logging, and banners are fixture-local; the host Task Scheduler and update providers are not called.

- Without `-ResumeAfterAttention`, the child exits with code 2, records simulated tasks as disarmed, logs the manual-attention stop, and exits before cycle start.
- With `-ResumeAfterAttention`, the child clears `Phase`, `LimitReason`, and a seeded `LimitReachedAt`, saves the resumed state, and reaches a cycle-start sentinel before pre-flight or provider work.
- Child processes have a 30-second timeout and are killed if they exceed it.

Focused regression: **1 passed, 0 failed**.

## Gates

- Pester unit/process: **677 passed, 0 failed** (79.62 seconds).
- User/SYSTEM boundary: **passed** (7.62 seconds).
- Published-launcher upgrade: **passed** (6.01 seconds).
- GitHub PR #114 checks passed on rerun after one Pester worker-container failure that did not report an individual assertion. The merged result also passed the master push checks.

No VM row was run for this release because no updater behavior changed. The v2.5.88 VM results remain in the [v2.5.88 validation report](validation-2.5.88.md). The host was not rebooted.

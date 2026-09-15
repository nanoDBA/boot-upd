---
name: reboot-resilience-review
description: Review Boot Update Cycle changes for Windows checkpoints, reboots, Task Scheduler, user-versus-SYSTEM scope, pending-reboot evidence, launcher self-update, provider exit-code reconciliation, Winget inventory anomalies, and truthful convergence. Use after updater, launcher, provider-parser, retry, state, or lifecycle changes.
---

Read `docs/TESTING.md`, `Invoke-BootUpdateCycle.ps1`, and the changed tests. Review the actual diff rather than only current files.

Check that:

- state is written atomically with process-unique temporary files and survives termination;
- the global mutex remains accessible to SYSTEM and Administrators and fails closed;
- a watchdog probe decides liveness only from the global mutex — held means exit 0 without touching state, free or abandoned means it is the recovery pass — never from process observation, log freshness, or state timestamps (ADR-0005, ADR-0006);
- primary and fallback tasks are staggered, mutually exclusive, read back, and cleanly removed;
- the in-flight resume checkpoint is the only arm that carries the repeating watchdog trigger, and every deliberate-stop arm (retry-pending, retry-at, user-context wait, restart watchdog) carries none; registration verification fails closed in both directions;
- the watchdog interval is passed through in continuation-task arguments and has a floor and no off switch;
- explicit 3010/1641 evidence and delayed registry evidence survive until a changed boot is observed;
- same-boot reboot barriers consume a bounded retry budget;
- a pass resumed after an unobserved stop charges the retry budget exactly once per pass — never per incomplete phase, and never twice for a parallel-cohort kill — never charges the reboot budget, still stops at the retry limit through the existing manual-attention handoff, and is disclosed in the completion banner and repair plan without changing the convergence claim;
- user-scoped phases are neither silently skipped nor declared complete under SYSTEM;
- completion requires provider convergence, settled reboot probes, health checks, and verified task/state cleanup;
- provider exceptions stop retries only when structured output accounts for every attempted item; preserve Winget/MSI `1605` as an already-absent stale-record outcome, conditionally reconcile only aggregate `0x8A15002C`, display install/cleanup/pin choices, and never increment verified updates;
- `upd.cmd` executes from a canonical-path-verified trampoline before staged adoption;
- the oldest supported published launcher still upgrades behaviorally;
- evidence for the two lab rows — positive kill-and-resume, negative short-interval no-double-run — is named, with PASS/PARTIAL/FAIL/NOT RUN per docs/TESTING.md, before the change is called validated.

Classify findings by user impact. Require the relevant explicit gate instead of accepting a generic test-count claim. A green unit suite does not validate a Task Scheduler trigger shape; require the lab rows or a read-back of a registered task.

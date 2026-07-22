---
name: reboot-resilience-review
description: Review Boot Update Cycle changes for Windows checkpoints, reboots, Task Scheduler, user-versus-SYSTEM scope, pending-reboot evidence, launcher self-update, provider exit-code reconciliation, Winget inventory anomalies, and truthful convergence. Use after updater, launcher, provider-parser, retry, state, or lifecycle changes.
---

Read `docs/TESTING.md`, `Invoke-BootUpdateCycle.ps1`, and the changed tests. Review the actual diff rather than only current files.

Check that:

- state is written atomically with process-unique temporary files and survives termination;
- the global mutex remains accessible to SYSTEM and Administrators and fails closed;
- primary and fallback tasks are staggered, mutually exclusive, read back, and cleanly removed;
- explicit 3010/1641 evidence and delayed registry evidence survive until a changed boot is observed;
- same-boot reboot barriers consume a bounded retry budget;
- user-scoped phases are neither silently skipped nor declared complete under SYSTEM;
- completion requires provider convergence, settled reboot probes, health checks, and verified task/state cleanup;
- provider exceptions stop retries only when structured output accounts for every attempted item; preserve Winget/MSI `1605` as an already-absent stale-record outcome, conditionally reconcile only aggregate `0x8A15002C`, display install/cleanup/pin choices, and never increment verified updates;
- `upd.cmd` executes from a canonical-path-verified trampoline before staged adoption;
- the oldest supported published launcher still upgrades behaviorally.

Classify findings by user impact. Require the relevant explicit gate instead of accepting a generic test-count claim.

---
name: reboot-resilience-review
description: Review Boot Update Cycle changes for Windows checkpoint, reboot, Task Scheduler, user-versus-SYSTEM, pending-reboot, launcher self-update, and truthful-convergence regressions.
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
- `upd.cmd` executes from a canonical-path-verified trampoline before staged adoption;
- the oldest supported published launcher still upgrades behaviorally.

Classify findings by user impact. Require the relevant explicit gate instead of accepting a generic test-count claim.

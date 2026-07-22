---
paths:
  - "Invoke-BootUpdateCycle.ps1"
  - "Deploy-BootUpdateCycle.ps1"
  - "tools/Invoke-Upd*.ps1"
  - "tests/RebootResilience.Tests.ps1"
  - "tests/SecurityHardening.Tests.ps1"
---

# Updater safety and convergence

- Do not run the live update cycle, install packages, register continuation tasks, mutate services, or reboot merely to test a change unless the user explicitly authorized that live-system effect.
- The `Global\BootUpdateCycle` mutex is a fail-closed safety boundary shared by elevated-user and SYSTEM tasks. Preserve its explicit SYSTEM/Administrators ACL.
- Persist checkpoints atomically before mutation and preserve user-versus-SYSTEM scope across every continuation.
- Treat provider exit codes as evidence, not phase outcomes. Winget/MSI `1605` is an already-absent stale uninstall record. Reconcile aggregate `0x8A15002C` only when structured output accounts for every attempted package as verified success or `1605`.
- Never count `1605`, a provider trigger, or an inferred action as a verified update. Do not queue a retry for a fully reconciled stale record. Preserve the phase-level regression in `tests/RebootResilience.Tests.ps1`.
- Completion claims require provider convergence, settled restart evidence, truthful verified counts, and verified cleanup of continuation tasks and state.

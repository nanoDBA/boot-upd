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
- Treat a fully accounted Winget/MSI `1605` as independent Windows Installer evidence that the product code is not installed, even when Winget continues to enumerate the stale record. Key learned outcomes by package ID, scope, code, and observed version; invalidate on success or changed failure evidence. Never ask Winget inventory to disprove its own stale inventory, and never suppress recovery choices when durable persistence fails.
- `Windows\SystemTemp\ChocolateyPrototype-2.8.5.130` belongs to Microsoft PackageManagement/OneGet's legacy Chocolatey provider, not the independent `choco.exe` CLI. Treat blank-destination delete markers there as non-blocking housekeeping, retain their sanitized provenance, and never rewrite the shared `PendingFileRenameOperations` value to clean them up.
- Avoid broad `Get-Package`, `Find-Package`, or forced provider-discovery probes in the orchestrator. They can initialize or bootstrap legacy PackageManagement providers and create unrelated system state during an otherwise read-only assessment.
- Completion claims require provider convergence, settled restart evidence, truthful verified counts, and verified cleanup of continuation tasks and state.

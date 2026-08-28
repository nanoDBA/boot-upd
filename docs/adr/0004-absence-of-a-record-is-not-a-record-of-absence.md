# Absence of a record is not a record of absence

The diagnostics manifest reconstructs machine state by regex-matching prose in the human-readable
log, and in several places it reads the *non-appearance* of a line as a fact about the machine.
`CONTEXT.md` now calls the thing it is missing *negative evidence*: a recorded observation that a
condition was checked and found absent, as opposed to the absence of any observation. We are
changing the updater to emit negative evidence into a structured artifact, and the exporter to
prefer that artifact over parsed prose, because silence has many causes and a reader cannot tell
them apart.

The concrete failure is `PendingFileCleanup.Persistent`. `Get-BootUpdateDiagnosticCleanupSummary`
derives the pre-mutation state solely from whether a `Pending-file cleanup [before mutation]` line
appears, and collapses to `null` when it does not. But `Write-PendingFileRenameAdvisory` declines to
emit that line for four unrelated reasons: the advisory set was empty; the identical
context-and-fingerprint pair was already logged and the duplicate guard suppressed it;
`Get-ConfirmedPendingReboot` returned early on an explicit 3010/1641 request and never probed at
all; or the phase did not run, as the after-updates call does not under `-WhatIf`. One `null` for
four situations, one of which — the explicit-reboot short-circuit — correlates with exactly the
servicing activity that makes the evidence worth having.

This is the same invariant ADR-0003 asserts about convergence, applied to the diagnostic surface
rather than the claim. There, a cycle may not assume it converged because nothing objected; here, a
bundle may not report a state because no line contradicted it. In both cases the honest output
distinguishes *checked and clear* from *not checked*, and says which it holds.

## Considered options

- **Keep parsing prose, fix the emitters so the line is always present.** Cheapest, and it needs no
  new artifact. Rejected because it makes the human-readable log a machine contract: every future
  wording change, visibility filter, or duplicate-collapse rule in `Write-Log` becomes a potential
  silent corruption of the manifest, and `Write-Log` already drops lines by more than a dozen
  pattern rules. It also cannot express *why* a state is unknown.
- **One general `BootUpdateCycle.evidence.json` covering cleanup, phase, and pass metadata,**
  retiring log-parsing for every machine-readable manifest field at once. This is the right
  destination — it would also close the `Phase="s ran"` defect, which is the same bug in a different
  field — but it is a larger contract to get right in one step. Reached by a later change, after the
  narrow artifact has proven the shape.
- **Publish both snapshots and drop `Persistent` entirely,** letting the reader draw the conclusion.
  Rejected: it moves interpretation onto whoever opens the bundle during an incident, which is the
  work the manifest exists to have already done.

## Consequences

- The new artifact is on an **evidence** lifecycle, not a cache lifecycle. This is a deliberate
  departure from `BootUpdateCycle.wu-assessment.json`, which is the nearest-looking file in the
  bundle but is a TTL'd cache: it is invalidated on age, scope, and environment-fingerprint
  mismatch, deleted when stale, and skipped entirely under `-WhatIf`. Copying that lifecycle would
  reproduce the fourth absence cause. The right neighbours are `BootUpdateCycle-repair-plan.txt` and
  `BootUpdateCycle-winget-quarantine.json`: written to be read later, never expired.
- Records are per pass, keyed by session id and pass number, rather than a single overwritten
  snapshot. Whether a fingerprint survived a restart is only answerable across passes, and that is
  the open question in the `FileRename` investigation; today it cannot be answered from a bundle at
  all, only by hand-diffing two bundles captured days apart.
- Recording and display separate. The duplicate guard in `Write-PendingFileRenameAdvisory` stays —
  suppressing repeat probe lines in the log is legitimate — but it stops having evidentiary meaning,
  because the log is no longer the evidence.
- Bundles produced before this change report an explicit legacy state rather than a bare `null`, so
  a historical limitation stays distinguishable from a current-format bundle that failed to record.
  The latter is a bug; the former is not.

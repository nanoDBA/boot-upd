# An unobservable process tree is not an idle one

`Wait-ProcessWithIdleTimeout` kills a package that stops consuming CPU, on the theory that a
provider which has gone quiet for the idle threshold is wedged rather than working. The signal it
trusts is `Get-ProcessTreeActivity`, which walks `Win32_Process` from the launched provider PID and
sums CPU across the tree. That walk could not succeed. `Win32_Process` types `ProcessId` and
`ParentProcessId` as `UInt32`, the traversal queue is `Queue[int]`, and a `Hashtable` keyed by
`UInt32` never matches an `Int32` probe — so every lookup missed, and the function reported an empty
tree with zero CPU for every process it was ever asked about.

Zero CPU never exceeds the previous zero, so the idle clock never reset. The idle timeout was
therefore not an idle timeout at all: it was a fixed wall-clock kill at `IdleTimeoutMinutes`,
applied to healthy and wedged packages alike. Shipped logs carry the fingerprint plainly —
`heartbeat: CPU=0s procs=0` beside phases that completed normally, and `Tree at kill: 0 processes,
handles=0` on the kills. On 2026-09-06 it killed an Acrobat Reader upgrade at exactly five minutes,
orphaning an `msiexec` that then failed the next six packages with `1618`, and cost three iterations
and 39.6 minutes.

Fixing the key types restores the measurement. It does not make the measurement always available,
which is the decision this record is about. `msiexec.exe` is parented to `services.exe`, so an
MSI-backed package legitimately does its work outside the tree we are watching, and a CIM query can
fail transiently for reasons of its own. Both read as zero processes. We now treat a zero-process
reading on a process that is still running as *no measurement* rather than as *no activity*: the
idle clock is held, a warning names the condition once, and the hard timeout remains the bound.

This is ADR-0004's invariant moved from the diagnostic surface to a control decision. There, a
bundle may not report a state because no line contradicted it. Here, the updater may not kill a
process because it failed to see the process working. In both cases the honest reading distinguishes
*checked and clear* from *not checked*, and the code has to say which it holds.

## Considered options

- **Fix the key types and stop.** The tree walk works, and out-of-tree installers stay invisible.
  Rejected because it leaves the same spurious kill in place for exactly the packages that take
  longest — large MSIs — while making the failure rarer and therefore harder to recognise the next
  time it happens.
- **Fix the key types and defer the reused-PID edge check.** How this change started. Abandoned
  once the edge check turned out to protect against the same spurious kill rather than merely
  tidying a reading; see the consequence below.
- **Count a running `msiexec`/`TrustedInstaller`/`TiWorker` anywhere on the machine as activity.**
  Closer to the truth for MSI packages, and preflight already enumerates those processes. Rejected
  as the primary mechanism: it attributes unrelated system servicing to our package and would hold
  the idle clock open for a genuinely wedged provider whenever Windows Update happens to be busy.
  Worth revisiting as a positive signal once the orphan handling in `-ynvn` is settled.
- **Drop the idle timeout and rely on the hard timeout alone.** Simple and never spuriously kills.
  Rejected because the idle timeout earns its place on providers that do run in-tree, where it
  turns a thirty-minute hang into a five-minute one.

## Consequences

- A genuinely wedged process whose tree cannot be observed now runs to the hard timeout instead of
  the idle timeout — thirty minutes rather than five for Winget. This is the deliberate cost: the
  failure mode moves from *kills healthy work* to *waits longer on dead work*, and only the first
  of those corrupts the machine.
- The idle timeout's behaviour changes materially for every provider, because it has never actually
  measured idleness in any shipped release. Timings recorded before this change describe a
  wall-clock kill and should not be read as evidence about how long packages stay busy.
- `Remove-ProcessTree`'s CIM fallback carried the same key-type defect and is fixed with it. The
  primary path calls `Process.Kill($true)`, so the fallback's failure to find children had been
  masked, and neither path stops an out-of-tree installer — tracked separately as `-ynvn`.
- Parent edges are now rejected when the claimed child started before the claimed parent. This was
  opened as a deferred `-y9es` and closed into this change once measurement showed it was not
  cosmetic: a process keeps its `ParentProcessId` after its parent exits, and a reused PID adopted
  every orphan still naming it. One PID's reading moved from 71 minutes of stranger CPU to 2
  seconds of real CPU between consecutive samples, and a total that *falls* can never exceed the
  previous high-water mark — so the idle clock advances and kills working software. The same guard
  is applied on the kill path, where adopting an orphan would terminate an unrelated process.
- Loop locals in the tree walk must not be named `$parentPid`. PowerShell variable names are
  case-insensitive, so that name overwrites the `$ParentPid` parameter and reroots the walk on
  whichever process CIM enumerated last. This was introduced and caught during this change; it is
  held by a source-shape assertion rather than a behavioural one, because a mis-rooted walk still
  returns a plausible tree — the observed buggy run reported *more* CPU than the correct one, so
  every threshold assertion passed.

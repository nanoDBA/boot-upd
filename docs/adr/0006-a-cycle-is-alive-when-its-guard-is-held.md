# A cycle is alive when its guard is held

A pass killed on a machine that stays logged on and does not reboot was never resumed: every
trigger in the resume chain was boot- or logon-scoped, and the one dated trigger only existed on
the restart path. Matrix row G showed the shape on 2026-09-09 — state promoted cleanly, both
continuation tasks sitting Ready, and nothing running for the rest of the row. The chain now
carries a repeating trigger, armed only at the in-flight checkpoint, that starts a watchdog probe
every few minutes until the cycle converges or stops deliberately.

The decision this record holds is how the probe decides whether the cycle is alive. It does not
look at processes, CPU, log freshness, or how recently the state file was written. It asks for the
cycle's named guard, `Global\BootUpdateCycle`. Held means a pass is running and the probe exits at
once, having touched nothing. Free or abandoned means nothing is running, and the probe simply
continues as the recovery pass — the abandoned-mutex path already existed for exactly this case.

## Considered options

- **A heartbeat timestamp in state, with the probe judging staleness.** Rejected because a
  Windows Update phase can legitimately run for tens of minutes without writing state, so any
  staleness threshold either kills healthy work or waits so long the probe is pointless. ADR-0005
  records why a reading that can be absent for innocent reasons must not drive a control decision.
- **A dead-man's switch: a one-shot dated trigger pushed forward at every phase start.** Fewer
  moving parts on paper, but the deadline can fire mid-phase, be answered by a probe that exits on
  the held guard, and leave nothing armed for a death later in the same phase. Closing that gap
  means the probe re-arms on its way out, at which point it is the repeating design with extra
  steps.
- **Launch the first pass through the scheduled task so `RestartOnFailure` covers it.** Does not
  cover a pass Task Scheduler believes exited cleanly, is capped at three attempts, and would
  change how every operator starts a cycle to fix a gap in the chain.

## Consequences

- Deliberate stops must never carry a repeating trigger. A cycle waiting for a logon would
  otherwise be prodded every few minutes and burn its identity-rediscovery budget on probes.
  Registration fails closed if a repetition appears where none was asked for, or is missing
  where one was.
- A pass that resumes after an unobserved stop is a recovery pass and charges the retry budget
  once, so a cycle that keeps dying for a reason the updater cannot see stops at the existing
  limit with the existing handoff instead of looping forever. A genuine reboot still resets it.
- The cycle's summary and repair plan say that a pass stopped without reporting and was resumed,
  naming the phase. A converged cycle that silently absorbed a kill would be making a claim it
  had not earned.
- The bound on how long a killed cycle can sit idle is the probe interval, not "until the next
  logon". The interval has a floor and no off switch, because an off switch is the gap this
  record closes.
- A residual gap remains before the arm. The repeating trigger is registered at the resume
  checkpoint, which sits after self-update, remote configuration and pre-flight. A pass that
  hangs inside those steps holds the guard with no repeating trigger armed. Accepted for now:
  those steps are bounded by their own timeouts, and arming before pre-flight would register
  tasks on a machine that pre-flight may be about to reject.

## Amendment (2026-11-01): a queued pass keeps the probe

The repeating trigger was armed only at the in-flight checkpoint, and every hand-off that queued
another pass (`-RetrySoon`) replaced it with one one-shot trigger per task. The queued run then
had to launch and live long enough to reach its own checkpoint. On lab row B it did neither,
twice: a PowerShell 7 MSI upgrade from Windows Update removed `pwsh.dll` as the SYSTEM fallback
launched (`0x8000809A`), and on the rerun replaced PowerShell under a run that had already started
(`0xE0434352`). Task Scheduler recorded both as completed, so its restart policy never fired, and
the cycle sat until the next boot or sign-in.

A queued pass is not a deliberate stop, so `-RetrySoon` now arms the same repeating trigger. A
healthy queued run re-registers the tasks within minutes, which moves the first probe out again;
the probe only fires when that run died. The saved-user logon wait still never repeats, for the
reason in the first consequence above. This narrows the residual gap only for death: a queued
pass that dies before its checkpoint is now probed, but one that hangs there still holds the
guard, and the probe backs off as designed.

A probe that picks up a queued pass is not charged as a recovery. The run that died never touched
the state, so the state still says the pass was queued deliberately, and that is the pass that
runs. If PowerShell stays broken, every probe fails the same way. That costs one failed launch per
interval and changes nothing, and the first probe after a repair resumes the cycle.

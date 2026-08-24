# Context

Domain glossary for Boot Update Cycle. Terms only — no implementation detail, no plans.

## Cycle vocabulary

**Cycle** — one end-to-end attempt to bring a machine to convergence, spanning however many passes and reboots that takes. A cycle owns a session identity that survives restarts.

**Pass** — a single execution of the updater within a cycle. A pass ends by converging, requesting a reboot, queuing a recovery pass, or stopping.

**Recovery pass** — a pass queued because the previous one left work incomplete. Distinct from a pass that resumes after a reboot: no restart happened, the updater simply tries again.

**Retry budget** — how many consecutive recovery passes a cycle may spend before it stops and asks for a human. Consumed by recovery passes, reset by a genuine reboot. Exists so that a failure the updater cannot fix cannot loop forever.

**Boot session** — the identity of the machine's current boot. Two observations belong to the same boot session when they fall inside a tolerance window, not when they are byte-identical, because the underlying clock reading drifts within a single boot.

**Convergence** — every enabled phase reporting success against evidence, with no restart pending. A claim of convergence is a factual assertion about the machine, never an optimistic default.

**Qualified convergence** — a cycle that completed with every phase complete and no restart pending, but still carrying deferred inventory. The machine is as converged as this cycle could make it, and is not fully up to date. Stated as such: an unqualified claim of convergence would be false, and a claim of failure would be equally false, because nothing failed.

## Phase outcomes

**Phase** — one provider's slice of a pass (Winget, Chocolatey, Windows Update, Defender, …). A phase is enabled or skipped, and if enabled it is complete or incomplete.

**Retryable failure** — an incomplete phase whose cause might not recur. It consumes retry budget and the cycle tries again.

**Terminal failure** — an incomplete phase whose cause is proven not to be transient, so retrying cannot help. It stops the cycle immediately and demands manual attention rather than consuming the whole retry budget. Proof is repetition: the identical failure signature observed across consecutive passes.

**Deferred inventory** — outstanding work the updater could not attempt: a package pinned by the operator, one whose installed version cannot be determined, one the provider refuses to upgrade in place, or one under quarantine. Never counted as a verified update and never treated as retry fuel. It does not make a phase fail, but it does prevent an unqualified claim of convergence — the cycle completes and reports qualified convergence instead.

**Scope deferral** — a phase whose machine-scope work is done but whose user-scope work cannot run here, because the pass is executing as SYSTEM and only a logged-in user can complete it. Distinct from deferred inventory: the work is attemptable, just not from this identity, so the cycle hands it to a later user-context pass rather than recording it as outstanding.

**Quarantine** — a reversible, durable block placed on a single package so it stops being attempted, persisting until lifted. Quarantine is an action the updater takes against the package manager; deferred inventory is the status that action produces. They are orthogonal, not alternatives: a quarantined package is deferred inventory for as long as it stays quarantined. A quarantine lifts either by explicit human action or on its own, when the failure signature changes because the cause was fixed upstream.

**Failure signature** — a stable identity for *what went wrong*, used to recognise the same failure recurring across passes. A signature must discriminate causes: two different failures of the same package must not share one. It must also change when the underlying cause changes, so that a failure fixed upstream stops being treated as terminal without human intervention.

**Verified update** — a package the updater has evidence it actually changed. Provider triggers, inferred actions, and already-absent records are not verified updates.

## Evidence

**Pending reboot** — a restart the machine needs before further servicing is safe. Confirmed by two probes separated in time, because servicing signals can appear shortly after boot.

**Repair plan** — the handoff written when the updater stops for manual attention: what failed, the evidence, and what a human can do about it. It states facts and options; it does not instruct the reader to weaken a verification boundary.

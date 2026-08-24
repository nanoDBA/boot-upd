# Deferred inventory qualifies the convergence claim; it never fails the run

A cycle can finish with work it was never able to attempt: a package pinned by the operator, one
whose installed version cannot be determined, one Winget refuses to upgrade because the new version
uses a different install technology, or one the updater has quarantined after a terminal failure.
`CONTEXT.md` calls this *deferred* inventory and says it "does not make a phase fail, but it does
prevent an unqualified claim of convergence". The code did not implement the second half: deferred
counts existed only to reconcile a provider exit code, reached nothing downstream, and a cycle
carrying deferred inventory reported `BOOT UPDATE CYCLE COMPLETE` and sent a **Success**
notification. We are fixing the code to match the glossary rather than relaxing the glossary.

The claim is qualified in the log wording, in the notification severity, and in the repair plan —
**not** in the exit code. Every caller (`upd.cmd`, both scheduled tasks, any automation downstream)
reads a non-zero exit as failure, so encoding the qualification there would assert exactly the thing
the term forbids: that a phase failed. It would trade an over-optimistic claim for an over-pessimistic
one, and both are untruthful. The exit code stays zero because nothing failed; the human-readable
surfaces stop saying the machine is fully converged, because it is not.

This also settles quarantine, which was the question that prompted the ADR. *Quarantine* is an action
taken against the package manager; *deferred* is the ledger status that action produces. They are
orthogonal, not alternatives — Winget already quarantines via a blocking pin and reports the package
as deferred inventory. So a Chocolatey phase in which thirteen packages verify and one is quarantined
is **complete**, and the cycle **completes**, while declining to claim unqualified convergence.

## Considered options

- **Block completion while deferred inventory exists.** Ruled out by a concrete case: Microsoft Edge
  is permanently technology-blocked under Winget and reappears on every Edge release. This machine
  would never complete a cycle again. A rule that makes completion permanently unreachable is not a
  rule.
- **Amend the glossary to match the code**, accepting that deferred inventory does not qualify
  convergence. Cheaper, but the truthful-convergence invariant is load-bearing for the updater-safety
  rule and for ADR-0001; weakening it to avoid one code change is the wrong direction of fit.
- **A distinct non-zero exit code.** Most expressive for automation, rejected for the reason above.

## Consequences

- A run that today ends in a Success toast will, once deferred inventory is wired through, end in a
  qualified one. That is a visible behaviour change on machines that have carried deferred inventory
  silently — including this one, via Edge.
- `deferred` was overloaded and is now split. `UserCompletionDeferred` is a *scheduling* deferral (the
  machine-scope pass ran; the user-scope pass must run in user context later) and already drives the
  completion disposition. Deferred *inventory* is outstanding work that cannot be attempted at all.
  They are different concepts and must not share a name; see `CONTEXT.md`.
- Quarantine must not become a silent permanent exclusion. ADR-0002's self-healing property carries
  over: when the maintainer refreshes the metadata the signature changes, so the quarantine lifts on
  its own. A quarantined package stays visible as deferred inventory for exactly as long as it is
  quarantined, which is what keeps the qualified claim honest.

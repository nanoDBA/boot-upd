# Local lab handoff validation — September 26, 2026

This change makes lab setup and evidence reusable across agent sessions. It does
not change the production updater or establish new SSMS/AWS provider coverage.
The entry point for another agent is the [lab handoff runbook](../tests/integration/lab/HANDOFF.md).
Machine-specific configuration and historical evidence locations are kept in the
ignored files beside that runbook.

## Verification

- Full unit/process suite: **PASS**, 606 tests, zero failed or skipped.
- Real User/SYSTEM exclusion gate: **PASS**.
- Published-launcher compatibility gate: **PASS**.
- Final focused lab suite after review fixes: **PASS**, 27 tests, zero failed or
  skipped. This is a separate rerun, not 27 additional tests added to the full count.
- PowerShell parsing and PSScriptAnalyzer Error checks: **PASS** for all seven
  changed/new PowerShell files. `git diff --check` passed.
- Independent static review found no remaining blockers.
- A fresh PowerShell process retrieved the existing credential and authenticated
  to the running headless guest using a read-only command. No password was printed.
- Credential initialization returned `Created=false`: the existing credential was
  reused, not rotated.
- The readiness check reported the running guest as unavailable for cold restore.
  Authentication for the powered-off guest remained **NOT RUN**; it was not started.
- Private configuration and local handoff files are ignored by Git and excluded
  from the harness transfer set. The dependency cache was copied to durable local
  storage and its SHA256 was verified against the prior cache.

Review addressed unsafe credential replacement, default plaintext output, an
unsupported PowerShell Direct parameter combination, mismatched environment
overrides, saved running-state checkpoints, missing source files, source identity,
and deliberately deleted tracked files. Regression tests use disposable fixtures
and mocked credential stores; they do not rotate real credentials or restore VMs.

## Limits

Fresh multi-reboot A/B rows using the revised tracked harness: **NOT RUN** in this
handoff change. Existing historical rows used the earlier temporary harness; their
results are not relabeled as acceptance of this revision. Run both rows before
using the new harness as release acceptance evidence, and keep deferred inventory
distinct from a passing convergence result.

The per-VM lease coordinates this harness only. An older runner or a direct
Hyper-V command does not acquire it. A terminated host runner can leave guest
tasks active, so an available lease alone never authorizes a restore; inspect
the guest and previous evidence first. The harness also refuses running guests.

The host updater was not run, and neither host nor guest was rebooted or restored
for this change. The existing AWS validation draft and active headless guest were
preserved. Follow-up validation is tracked with [#82](https://github.com/nanoDBA/boot-upd/issues/82).

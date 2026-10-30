# v2.5.87 validation

Validation was run on the local Windows host and the configured disposable Hyper-V guest on 2026-10-30. The VM rows used orchestrator SHA-256 `C92DE15E143D4659DD57E0503354DF7CC0AFDE937770A19222602D0D4455A3B8`; that build is the candidate before the final Defender count-reporting correction. The correction was covered by the final Pester and GitHub gates, but was not redeployed to the guest.

## Automated gates

- Pester unit and process tests: **676 passed, 0 failed, 0 skipped** in 110.47 seconds across three isolated PowerShell processes.
- User/SYSTEM exclusion gate: **passed** in 6.44 seconds.
- Published-launcher upgrade gate from v2.5.43: **passed** in 4.41 seconds.
- GitHub checks for PR #106: quality, User/SYSTEM exclusion, and published-launcher upgrade all **passed**.

The earlier sequential baseline was 662 tests in 138.99 seconds. The local run was about 20% faster with 14 additional tests. This is one host comparison; hosted CI timing has not been measured.

## VM rows

**Row A — PASS.** The `upd` launcher completed four passes and claimed three reboots; Windows recorded three boot events. The run removed its checkpoint and tasks, had no pending CBS restart, and showed no consent prompt. The guest observed PowerShell 7 during the run.

**Row B — PARTIAL at the headless boundary; saved-user continuation PASS.** The `deploy` launcher ran as SYSTEM with no console user. After five passes and three OS-observed reboots, it parked at `UserContextPending` with one task triggered only by the saved user's logon. CBS was clear and no consent prompt appeared. A temporary lab sign-in then started the existing task as the saved user. Health checks passed, the cycle completed after five iterations and three reboots, and it removed its state and tasks. The helper verified that temporary AutoAdminLogon settings were cleared. The continuation used the same pre-correction candidate hash listed above.

The guest ran Windows Update servicing during Row B and required a third OS-observed reboot before the saved-user handoff. No no-progress reboot was charged in that row. Both VM rows used one shared guest and ran serially; the guest was shut down after continuation verification.

## Open follow-up

[Issue #108](https://github.com/nanoDBA/boot-upd/issues/108) tracks an inferred, unreproduced case where a long Windows servicing chain could reach the no-progress limit before later package work verifies progress. The current default remains five consecutive reboots without verified progress. The VM run above did not reproduce this condition.

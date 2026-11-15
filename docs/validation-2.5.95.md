# v2.5.95 validation

This release carries seven fixes found by reading diagnostics bundles from two machines: PRs #147, #148, #149, #150, #151, #152 and #153.

## Gates

On the release branch, from elevated PowerShell 7.7:

- Pester unit/process: **782 passed, 0 failed**.
- User/SYSTEM security boundary: **passed**.
- Published-launcher upgrade: **passed**.

The same three gates passed on each PR head before it merged, and in CI.

## Per-change evidence

| PR | Change | Evidence |
|---|---|---|
| #147 | A hard-timed-out Winget scope or package stops the cycle; no same-boot retry | Test failed before the change (`TerminalFailure` was false), passes after |
| #148 | npm deferred to the signed-in user in a SYSTEM run | Completion-disposition test |
| #149 | `upd.cmd` self-replacement on one line | Real `cmd.exe` run adopting a longer and a shorter staged file; published-launcher gate |
| #150 | `PowerShellRuntimeUpgrade.log` in the bundle; capture state from the last event | Export test with redaction; activity tests for attention, limit and resumed runs |
| #151 | SSMS 21 updated like SSMS 22; reworded message for other versions | Mocked installer and inventory |
| #152 | Winget failure memory by package, scope, exit code and offered version | 328 lines of tests on the parser, the memory file and the targeted pass |
| #153 | Clipboard helper skipped as SYSTEM or without an interactive session | Tests failed before the change, pass after |

## The idle rule that was removed

PR #147 first changed idle detection from "any CPU increase" to "at least 1.25 CPU seconds per minute". Before merge it was replayed against the recorded heartbeats of the runs that prompted it. It caught the stuck install, which used about 0.9 CPU seconds per minute for 30 minutes. It would also have killed, at about 6 minutes, a machine-scope install that used about 0.5 CPU seconds per minute for 12 minutes and then updated successfully. The installer's own work runs in the Windows Installer service, outside the process tree being measured, so the rate does not separate the two. The rule was removed and a test now guards the slow healthy case.

## Not run

- A multi-reboot lab row on this release. #147, #148 and #152 change what a cycle does across retry passes and are covered by unit and process tests only.
- An SSMS 21 update on a real machine. The servicing path is the one SSMS 22 already uses.
- A real Winget package failing with the same exit code across two cycles.
- A real installer running to the hard timeout.
- Live bootstrap on a clean hosted VM.

No update cycle ran on the development machine and it was not rebooted to test this release.

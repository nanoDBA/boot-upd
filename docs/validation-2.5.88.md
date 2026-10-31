# v2.5.88 validation

Validation was run on 2026-10-31 against the candidate updater source SHA-256 `47259940AA8F2383FEF33E8578F647143F5BF8D9A3956BF84A664DE110F05704`. The VM rows used the source before the release version string changed from 2.5.87 to 2.5.88; updater behavior and tests were otherwise the same. The final version-string change was covered by the full local gates.

## What the log showed

The sanitized October 31 bundle records a run that stopped for a repeated MuseScore Winget MSI 1603. At 20:36:05, boot-upd reported both continuation tasks removed. At 20:44:17 it recovered `.bak` after the primary state file became unusable; by 20:44:21, the earlier session was running again and the tasks had been armed. It stopped again at 20:48:13.

The log proves that the older checkpoint was loaded and the cycle resumed. It does not show why another invocation happened after the tasks were removed, so this report does not attribute that launch to a particular scheduler trigger. The MuseScore installer failure itself is a package failure; this change keeps the updater from silently undoing its manual stop if state recovery occurs.

## Change

Manual-attention and task-disarm-failure states are kept in both checkpoint copies. A later invocation keeps the cycle stopped and removes any continuation tasks. After checking and correcting the provider failure, an operator can resume deliberately with `upd run -ResumeAfterAttention`.

The regression test writes an active state, records manual attention, zero-fills the primary, and verifies that backup recovery still reports the stop. It also verifies the disarm-failure state is treated as manual attention.

## Automated gates

- Focused manual-attention recovery test: **1 passed, 0 failed**.
- Full Pester unit/process gate: **677 passed, 0 failed, 0 skipped** in 91.39 seconds.
- User/SYSTEM exclusion gate: **passed** in 6.15 seconds.
- Published-launcher upgrade gate: **passed** in 4.48 seconds.

The unit/process gate was about 34% faster than the 137.54-second baseline recorded in issue [#107](https://github.com/nanoDBA/boot-upd/issues/107), with 15 additional tests. This is one host run, not a repeatability or hosted-CI timing claim.

## VM rows

**Row A — PASS.** On `baseline-clean`, `upd` completed after four passes and three reboots. The guest OS recorded three new boot times, matching the updater. Windows Update reported zero remaining applicable updates; health assessment passed for five services. The state file and both continuation tasks were absent, CBS had no pending restart, and no consent prompts appeared. The guest’s installed updater SHA matched the candidate.

**Row B — PARTIAL.** The headless `deploy` run started as SYSTEM with the saved-user wait limit set to one. It reached `UserContextPending` after three passes and two counted reboots; Windows Update was verified complete. The saved-user logon task and the SYSTEM fallback task remained armed. We stopped at that boundary and shut the guest down normally; we did not sign in to exercise the user-scoped continuation or verify its cleanup. We stopped the monitor at this boundary because this run did not include the saved-user sign-in step, so it has no final harness summary.

The first A attempt used the configured September checkpoint, which rejected the stored lab credential at the lock screen. That attempt did not launch the updater. It was abandoned without rotating credentials, and A was rerun successfully from the October `baseline-clean` checkpoint. All VM tests ran serially on disposable guests. The host was not rebooted.

## Limits

Windows 10, RDP, real user-installed application upgrades, and a user sign-in after Row B were not tested in this run. The release does not retry or suppress the MuseScore MSI 1603; it preserves the stop and requires deliberate operator action after review.

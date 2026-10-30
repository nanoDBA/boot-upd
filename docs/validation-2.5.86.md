# v2.5.86 validation

## Gates

| Gate | Result | Evidence |
|---|---|---|
| Unit/process behavior | PASS | 649 Pester tests passed. |
| User/SYSTEM security boundary | PASS | GitHub `User/SYSTEM exclusion gate`. |
| Published launcher upgrade | PASS | GitHub `Published launcher upgrade gate`, from v2.5.43. |
| Quality | PASS | GitHub `quality` check. |
| Live README bootstrap | PASS | Windows PowerShell 5.1 fresh-install and legacy-repair scenarios passed in [workflow run 40231896651](https://github.com/nanoDBA/boot-upd/actions/runs/40231896651). |
| Multi-reboot convergence, VM B | PARTIAL | Details below. |
| Multi-reboot convergence, VM A | NOT RUN | The configured checkpoint did not reach a desktop within the harness wait, so the updater did not start. |

## VM B and saved-user continuation

The headless row ran the candidate through five updater passes and three Windows boot events. It finished machine-scope servicing and correctly left one logon-triggered continuation for the saved user. At that checkpoint, CBS servicing was still pending. The headless row is **PARTIAL**, not PASS.

A separate harness test configured one temporary guest sign-in and let Windows launch that existing continuation. The task ran as the saved user, then completed the cycle after a total of three updater-reported reboots and five iterations. Policy-aware health checks passed; both scheduled tasks and the active checkpoint were removed; no CBS reboot-pending flag remained; temporary autologon settings were removed and verified.

The completion record was `BOOT UPDATE CYCLE COMPLETE WITH DEFERRED INVENTORY`. Windows Update offered KB5007651 again after two successful installs, so it was recorded as deferred rather than retried or counted as an update. The guest also lacked Winget, so the user-context run did not exercise actual user-app upgrades. The saved-user continuation result is **PARTIAL**. See [issue #96](https://github.com/nanoDBA/boot-upd/issues/96) for the re-offer.

The host was not rebooted. The lab sign-in test rebooted only the disposable guest once to trigger Windows logon automation; that test reboot is separate from the updater's three-reboot count.

## Limits

This run did not test Windows 10, RDP, real user-installed app upgrades, or the remaining rows in the full VM matrix. No result should be read as a PASS for the overall VM matrix.

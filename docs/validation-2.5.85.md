# v2.5.85 release validation

Published [v2.5.85](https://github.com/nanoDBA/boot-upd/releases/tag/v2.5.85) from commit `3e219ea31cc95403e402244e66abc99eba2c8782`.

| Gate | Result | Evidence |
|---|---|---|
| Unit/process behavior | PASS: 645 tests | Local full test gates and [release-commit CI](https://github.com/nanoDBA/boot-upd/actions/runs/40154751650) |
| User/SYSTEM exclusion | PASS | Local full test gates and release-commit CI |
| Published launcher upgrade | PASS: immutable v2.5.43 to release candidate | Local full test gates and release-commit CI |
| Exact README bootstrap | PASS: fresh installation and legacy repair, starting in Windows PowerShell 5.1 | [Hosted Windows VM run](https://github.com/nanoDBA/boot-upd/actions/runs/40154970065) |
| Public release assets | PASS: ten assets, matching SHA256 sidecars, PowerShell LF and batch CRLF | Draft download verification before publication; public download verification afterward |
| Multi-reboot and saved-user continuation | PARTIAL overall: A/G/N PASS; B user continuation verified, machine inventory still deferred | [Implementation VM evidence](validation-user-continuation.md) |
| Live provider integration | NOT RUN for this release | No new AWS or SSMS provider behavior in this patch |

The release updater SHA256 is `A1C6F6A8119AE5578CBA5F6FDF3A7C7F441D261D3AD0AF088CA868536D9DEA33`.
The published batch launcher SHA256 is `671BBEFD71DFC981646DE11A52693E1892F0EC9C64A6972D23F75E51345EB187`.

VM rows tested the implementation before the version-only updater and batch changes for v2.5.85. They were not rerun against the published assets. The hosted bootstrap tests used the published release and dispatched help without running updates or rebooting the host.

[Issue #96](https://github.com/nanoDBA/boot-upd/issues/96) remains open: KB5007651 was offered again after successful installation. Completion remains qualified rather than claiming every provider converged. Windows 10, RDP, simultaneous interactive sessions and real user-installed application upgrades remain outside the recorded VM coverage.

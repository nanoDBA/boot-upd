# AWS CLI repair validation for v2.5.83

**Release status: held.** The headless row is PARTIAL because Hyper-V paused the
guest after the host disk ran out of space. This candidate has not been published.
Recovery is tracked in [#83](https://github.com/nanoDBA/boot-upd/issues/83).

The candidate narrows cross-manager repair guidance to the explicit Chocolatey
`awscli` / Winget `Amazon.AWSCLI` pair. A reported Winget success and a Chocolatey
failure are evidence for this guidance, not proof of the cause of an MSI failure.
No package registration is removed automatically by the updater.

## Candidate and review

- Implementation commit: `75b466ed578bc87f993a81551402bedada266d3a`.
- Tested orchestrator file SHA256:
  `0A0D8A0B6CDEF944C66571BC9AE5C5327E7F08BEFFA122A568EB918E9BC33C22`.
- Tests run from an isolated local checkout with source bytes compared against the
  working repository. VM synchronization also checks the orchestrator hash.
- Independent review found and then cleared five defects in the initial merged
  revision: package uninstall scripts still enabled, ambiguous substring identity
  matching, unchecked command text, missing unnumbered Winget success identities,
  and repair suggestions for checksum mismatches.
- Focused regressions: 12 passed, including an actual checkpoint file write/read.

## Local gates

| Gate | Result |
|---|---|
| Unit/process behavior | PASS: 589 passed; zero failed or skipped |
| Real User/SYSTEM exclusion | PASS |
| Published launcher upgrade | PASS |
| PowerShell parsing | PASS: 44 files, zero errors |
| PSScriptAnalyzer Error severity | PASS: zero errors |

[GitHub CI for the implementation commit](https://github.com/nanoDBA/boot-upd/actions/runs/36244605741)
also passed its quality, User/SYSTEM exclusion, and published-launcher jobs.

An earlier full run failed one timing-sensitive UI assertion (three frames instead
of four within a 300 ms deadline). A separate loaded run also exceeded a ThreadJob
startup allowance, wrapped the 112-color palette, and reached a native-child timeout
before its first output. The final run uses the corrected deadline contract,
bounded startup allowance, and palette-wrap assertion. The native-child timeout
test itself is unchanged and passed in the final sequential run. Earlier failures
remain in private evidence; they are not counted as passes.

## Disposable VM evidence

| Scenario | Result | Evidence |
|---|---|---|
| A: interactive `upd`, repeated reboot/resume | PASS | `A-aws-repair-boot-upd-matrix-20260926-091557` |
| B: headless SYSTEM fallback | PARTIAL, infrastructure-blocked | `B-aws-repair-lab-b-20260926-093517`, recovered `B-recovered/summary.json` |
| Chocolatey package-script suppression and external-file retention | PASS | `choco-record-removal.json`, `remaining.log` |

Row A completed four passes and three reboots. The harness-collected Windows event
6005 count also equals three; raw event timestamps are not retained separately.
The final Windows Update convergence scan found zero applicable updates, followed
by a settled reboot probe. All five health services passed. Active state was absent,
continuation tasks numbered zero, CBS pending was false, and updater processes were
empty. Candidate and installed orchestrator hashes both match the SHA256 above.

SSMS ran through the default launcher path and verified build `22.10.12210.168`
already current, with zero SSMS updates counted. Winget and Chocolatey were absent
from this checkpoint, and AWS tooling was disabled; this row is not live AWS repair
proof. The first fixture attempt stopped on the missing Chocolatey prerequisite
before making package changes. Its failed setup attempt is retained separately.

The fixture retry used Chocolatey 2.7.4, installed only in the disposable guest from
the official signed bootstrap. Normal uninstall ran the fixture uninstall script,
created its sentinel, and removed its external application file. After reinstall,
the corrected command removed the package registration while leaving that file
intact and the sentinel absent. The fixture was cleaned up, and the guest shut
down normally before row B began.

On September 26 at 11:06:07 local time, Hyper-V event 18524 recorded a critical
pause of the headless guest; storage events 12635/12636 reported Disk Full. The
host system volume had approximately 725 MiB free when inspected. The last saved
monitor sample at 10:12:23 recorded four passes and two continuation tasks.
Independent Hyper-V events record three post-launch guest boots. A bounded
read-only PowerShell Direct attempt was refused because the VM was paused, so
current guest health, installed hash, active state, and final task cleanup remain
unknown. The original monitor process was not observed; its termination cause
is unknown. This establishes an infrastructure interruption, not a product
failure or a completed convergence result. No guest was resumed or reset during
recovery. Sanitized findings belong here; raw host evidence remains private.

## Scope and limitations

The new Chocolatey fixture uses a normal-uninstall control that writes a sentinel
and removes an external application file. The record-removal case uses both
`--skip-autouninstaller` and `--skip-powershell`. Its scope is package-script
suppression and external-file retention, not registry-based automatic uninstall,
Chocolatey hooks, or AWS publisher rollover.

The host updater was not run and the host was not rebooted. Reboot testing is
confined to disposable guests. Native SSMS servicing remains enabled by default;
the existing live SSMS upgrade evidence is documented in
[v2.5.82 validation](validation-ssms-2.5.82.md). A native SSMS installer returning
3010/1641 remains a live-coverage gap, not a result established by this release.
That follow-up is tracked in [#79](https://github.com/nanoDBA/boot-upd/issues/79).

Watchdog kill-and-resume and short-interval no-double-run scenarios were not rerun
for this repair-guidance change. The existing scheduler and mutex mechanisms are
unchanged; the current User/SYSTEM exclusion gate was run explicitly.

Tracking: [#76](https://github.com/nanoDBA/boot-upd/issues/76),
[#77](https://github.com/nanoDBA/boot-upd/issues/77).

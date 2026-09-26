# AWS CLI repair validation for v2.5.83

**Status: reviewed release validation.** Current CI passed, the scoped Chocolatey fixture passed,
and both fresh VM rows completed. The interactive A row is a scoped PASS. The headless
SYSTEM B row completed with deferred inventory, so the overall VM matrix is **PARTIAL**;
it does not establish full convergence.

The change narrows cross-manager repair guidance to the exact Chocolatey `awscli` /
Winget `Amazon.AWSCLI` pair. A Winget success and Chocolatey failure support that
repair suggestion; they do not prove the cause of an MSI failure. The updater never
removes the package registration automatically.

## Implementation and review

- Implementation commit: `75b466ed578bc87f993a81551402bedada266d3a`.
- Tested orchestrator SHA256: `0A0D8A0B6CDEF944C66571BC9AE5C5327E7F08BEFFA122A568EB918E9BC33C22`.
- Fresh VM source commit: `3f20003`.
- Pre-release GitHub CI: **PASS, 608 tests**, [run 36252566075](https://github.com/nanoDBA/boot-upd/actions/runs/36252566075).
- Earlier implementation local gates: unit/process **589 passed**, User/SYSTEM exclusion
  **PASS**, published-launcher compatibility **PASS**, PowerShell parsing (44 files)
  **PASS**, and PSScriptAnalyzer Error checks **PASS**. The current CI run supersedes the
  earlier test count for the latest head; neither establishes VM convergence.
- Focused regressions: **12 passed**, including an actual checkpoint file write/read.
- Independent review found and cleared five initial defects: package uninstall scripts still
  enabled, ambiguous substring identity matching, unchecked command text, missing unnumbered
  Winget success identities, and repair suggestions for checksum mismatches.

## Disposable VM evidence

| Scenario | Result | Evidence |
|---|---|---|
| Fresh A: interactive user | **SCOPED PASS** — 4 passes, 3 claimed/observed reboots | `A-release-final-20ce892b295d47fca942660365160534` |
| Fresh B: headless SYSTEM | **COMPLETED WITH DEFERRED INVENTORY (PARTIAL)** — 5 passes, 3 claimed/observed reboots | `B-release-final-03fd1bb381b74fab9525e17ee7f4ced1` |
| Original B: headless SYSTEM | Completed with deferred inventory; original capture lacks explicit final state-absence proof | `B-aws-repair-lab-b-20260926-093517`, recovered `recovered-existing-B/recovered-existing-B.json` |
| Chocolatey uninstall-script suppression and external-file retention fixture | **PASS within fixture scope** | `choco-record-removal.json`, `remaining.log` |

### Fresh A: interactive user

The release-final A row ran the interactive `upd` launcher in user+machine scope. Its
summary records **four passes**, **three claimed and three OS-observed reboots** (accounting
agrees), no remaining state file, zero continuation tasks, and `CbsPending=false`. Candidate
and installed orchestrator hashes match:
`0A0D8A0B6CDEF944C66571BC9AE5C5327E7F08BEFFA122A568EB918E9BC33C22`. The updater log
records all five policy-aware health checks passing, Windows Update convergence with zero
applicable updates, cycle completion, and removal of both continuation tasks. This supports
a **scoped PASS** for this interactive A row, not full provider coverage: AWS and .NET tools
were skipped, and SSMS was already at `22.10.12210.168` (zero SSMS updates).

The wrapper summary records `DeployTaskResult=3221225786` (`0xC000013A`). This is consistent
with task termination at the first reboot, but that cause is inferred: Task Scheduler event
records were not exported. Do not blanket-whitelist this result code. Investigate and classify
it in [#81](https://github.com/nanoDBA/boot-upd/issues/81).

### Fresh B: headless SYSTEM

The B row ran through the SYSTEM deployment path on `lab-b`, with no interactive user or
Explorer session. It completed **five passes** after **three claimed and three OS-observed
reboots** (accounting agrees). Candidate and installed orchestrator hashes match
(`0A0D8A0B6CDEF944C66571BC9AE5C5327E7F08BEFFA122A568EB918E9BC33C22`). The summary reports
no remaining state file, zero continuation tasks, and `CbsPending=false`; the log confirms
both continuation tasks were removed at 13:50:47 and 13:50:49. The Task Scheduler Operational export scanned a bounded 2,000 events and matched 44; its lookback began at 11:53:44Z, earlier than this run. It includes task-removal and successful fallback completion records, corroborating cleanup, but it is not a complete event history for the run. All five policy-aware health
checks passed. This verifies successful resume and cleanup for this row.

The updater completed at **13:50:44** with deferred inventory, not full convergence. No
interactive user appeared after one rediscovery attempt, so user-scope Winget, Scoop, and
VS Code work was deferred. The log also records that Windows Update KB5007651 remained
applicable after **one successful install** and was deferred as `ReofferedAfterSuccess=1`.
Do not count deferred work as updated or describe B as fully patched. The guest had no
Winget or Chocolatey installation available in this row, SSMS was absent, and AWS tooling
was disabled; B is SYSTEM resume/cleanup evidence, not AWS repair coverage.

### Original B and its later infrastructure interruption

Recovered evidence shows the original B row completed **with deferred inventory** at
**10:16:03**, after **five passes and three boots**. The later Hyper-V critical pause occurred
at **11:06:07**, when the host disk ran out of space. Do not describe the pause as interrupting
the row before its recorded completion. The original B capture lacks explicit proof that
active state was absent at final collection; it therefore does not establish clean state
cleanup. The fresh B row above now provides its own state/task cleanup evidence, while keeping
the older row's evidence limits intact.

## AWS repair scope

A direct AWS CLI provider failure points to `upd aws`. When the recorded provider evidence is
specifically Winget success for `Amazon.AWSCLI` plus Chocolatey failure for `awscli`, the repair
plan offers `choco uninstall awscli -y --skip-autouninstaller --skip-powershell` to remove only
Chocolatey's package metadata. It asks the operator to confirm the installed product first.
The updater does not execute this removal automatically. A checksum mismatch offers no command
until a person verifies the hashes.

The disposable fixture ran on Chocolatey 2.7.4. Its normal-uninstall control ran the
package uninstall script, created a sentinel, and removed an external application file.
After reinstall, the command with both suppression flags removed the package registration,
retained the external file, and left the sentinel absent. The fixture was then cleaned up.
An earlier setup attempt stopped because Chocolatey was missing; it is not counted as a pass.
This does **not** test Chocolatey hooks, Windows Installer failure
causes, registry-based automatic uninstall, or AWS publisher rollover.

## Coverage limits

- Overall A/B matrix result: **PARTIAL** because B completed with deferred user-scope and
  Windows Update inventory. The B row verifies resume and cleanup, not full convergence.
- Native SSMS servicing remains enabled by default. A verified SSMS was already current;
  B found no SSMS instance. Neither fresh row executed an SSMS upgrade. Existing live upgrade
  evidence remains in [v2.5.82 validation](validation-ssms-2.5.82.md).
- SSMS installer exits `3010`/`1641` remain a live-coverage gap. Follow-up: [#79](https://github.com/nanoDBA/boot-upd/issues/79).
- Watchdog kill-and-resume and short-interval no-double-run rows were not rerun for this AWS
  repair-guidance change; the current User/SYSTEM exclusion gate did run explicitly.
- The host updater was not run and the host was not rebooted. Reboot testing is confined to
  disposable guests. Keep raw host evidence private; publish only sanitized findings.

Tracking: [#76](https://github.com/nanoDBA/boot-upd/issues/76),
[#77](https://github.com/nanoDBA/boot-upd/issues/77), handoff [#82](https://github.com/nanoDBA/boot-upd/issues/82),
and lab disk recovery [#83](https://github.com/nanoDBA/boot-upd/issues/83).

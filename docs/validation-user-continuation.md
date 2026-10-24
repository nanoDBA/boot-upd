# Saved-user continuation validation

Test date: 2026-10-24. This tests a development candidate based on v2.5.84;
it is not a release validation for every supported Windows configuration.

Updater SHA256:
`A25BEE1342D69EED7B235B51B3B2D56A13112085EF84C2B4B217D3C58D75C932`

## What changed

After bounded headless retries, a resolvable saved account keeps its checkpoint
and one logon continuation. Signing in resumes the user-only work automatically.
A different signed-in account cannot reset that saved account's wait budget.
An already-active saved session gets a dated retry so a missed logon event does
not leave the cycle waiting forever.

The launcher also writes its queued adoption record before spawning the worker.
A fast worker can no longer have its completed record overwritten by its parent.
Deployment messages now describe later user-context continuation instead of
calling the first run the only chance to update user-scoped packages.

The first automatic sign-in test found an early health-check failure. W32Time was
stopped 82 seconds after boot with delayed automatic startup configured; a later
read-only check found it running. The fix observes that service's startup for a
bounded interval within the first five minutes of boot. It requires confirmed
delayed-auto configuration, accepts `Stopped` or `StartPending` as reasons to
observe, and still fails if the service never reaches `Running`. It never starts
or reconfigures a service.

## Development checks

| Check | Result |
|---|---|
| Unit and process behavior | PASS: 645 tests, zero failures or skips |
| Real user/SYSTEM mutex boundary | PASS |
| Published v2.5.43 launcher upgrade | PASS |
| Saved-account detection under real SYSTEM | PASS |

The targeted saved-user tests failed before the session check was corrected and
passed afterwards. A separate deterministic launcher regression reproduced the
parent overwriting a worker's completion record, then passed with the write moved
before process creation.

The delayed-start regression also failed before its fix. Tests now require
`Running` before success, retain failure on expiry and for non-delayed automatic
services, and cover `StartPending` and the end of the startup window. Manual and
policy-managed service handling is unchanged.

The real SYSTEM session gate passed against the exact updater hash above: it
recognized the saved console account, rejected a different local account and an
unresolvable account, and removed its temporary scheduled task. It reads the
production functions without running the updater or rebooting the host.

The first full published-launcher gate failed with a missing terminal adoption
record. Its old cleanup removed the raw fixture, so that failure alone cannot
establish the cause. The deterministic regression established the race separately.
Failed launcher fixtures are now retained for diagnosis.

## VM evidence and limits

Both guests used Windows 11 Enterprise LTSC Evaluation build 26100 with
PowerShell 7.6.5 installed. They ran the `deploy` entry point with self-update
disabled and a two-minute watchdog interval.
Provider convergence remains **PARTIAL overall** because KB5007651 is still
offered after successful installation. The saved-user handoff itself is verified.

| Final-build scenario | Result | Evidence directory |
|---|---|---|
| Interactive continuation, two armed reboots | PASS: three user passes; 2 claimed/2 OS boots; health, tasks and state verified | `A-health-settle-da24cc34e330411494ed6db9e02ec94d` |
| Kill during Windows Update; dated watchdog recovery | PASS: one recovery pass; no reboot or new sign-in; health and cleanup verified | `G-health-kill-recovery-7219a64c42f642d79cc74e45000e24de` |
| Healthy long-running pass under watchdog probes | PASS: four task starts, one updater pass, no recovery or reboot; health and cleanup verified | `N-health-no-double-run-a66774f6ae384be8bf38d19bd2905afa` |
| Headless SYSTEM servicing, then saved-user wait | PARTIAL: four passes, two OS boots, user work queued; CBS flag present at collection | `B-health-saved-user-632ec61faffe453b9b855c8d319bb6e8` |
| Automatic saved-user sign-in | PARTIAL cycle; `UserContinuationVerified=true`, health, task/state and credential cleanup verified; KB5007651 remains | `saved-user-resume-2831349cb28e404a9377066a4f238050` |

G and N completed with a nonblocking cleanup advisory, which remains visible in
their completion records. Both had clear CBS evidence and no continuation tasks
or active state. The headless wait is intentionally not counted as a completed
cycle; its late CBS flag is also retained rather than overwritten by a later scan.

N recorded three user-principal probes and one SYSTEM probe, with no second
updater pass. G resumed on the same boot at 15:35:14 after the verified kill at
15:34:07; scheduler event 107 identifies the dated trigger.

The sign-in helper's one external guest reboot cleared the CBS flag seen at the
headless collection. That boot is recorded separately and is not charged as an
updater-requested reboot. Windows then launched the existing saved-user task;
the helper did not start the updater. W32Time's bounded observation ran from
15:54:00 to 15:54:55 and finished with the service Running. Final health passed,
CBS was clear, and tasks, state and temporary autologon settings were removed.

The initial continuation candidate had updater hash
`541C7ED6AD1773C15D9003C91E7AC6D12D89ECC3DA6F8F37C79DF31ADBFBF95A`.
Its results are retained below; new rows test the final hash above.

| Initial scenario | Result | Evidence directory |
|---|---|---|
| Interactive continuation, two armed reboots | PASS | `A-final-short-watchdog-9c4dae8fad1e43a5ba85aba8c04bb3aa` |
| Headless SYSTEM servicing, then saved-user wait | PARTIAL: user work remains queued | `B-final-saved-user-9139c1e182bf45859c6e8c6882f47a8a` |
| Automatic saved-user sign-in | FAIL: W32Time health observation; identity and cleanup succeeded | `saved-user-resume-95b0a0f8dfac48b1b939988607a6c707` |

The initial interactive row completed three passes across two real reboots.
Windows' boot events and the updater's reboot count agree. Health checks passed;
continuation tasks, active state, and CBS reboot evidence were absent at collection.

The headless row completed five passes and three OS-observed reboots without a
console session. At collection it retained `UserContextPending` and exactly one
saved-user logon trigger; the SYSTEM fallback was removed. This is the intended
waiting state, not a completed cycle. Its Windows Update inventory also records
KB5007651 as still offered after successful installation.

The failed sign-in row proves Windows launched the existing task as the saved
user: both the new user-context log and scheduler event 100 identify that account.
Tasks and state were removed, CBS was clear, and temporary autologon cleanup was
verified. Its health failure remains a FAIL in the original summary. The
[KB5007651 follow-up](https://github.com/nanoDBA/boot-upd/issues/96) remains
independent of the sign-in behavior.

The original scheduler collector searched for double-quoted XML attributes;
Windows returned single quotes, leaving its export empty. That export is retained,
but it proves nothing about watchdog activity. The corrected collector parses XML
fields. Unit cases cover both quote styles, and live positive controls captured
actual updater registration records. Later rows use the corrected collector.

An initial kill-row job failed at parameter binding before the guest was launched:
`Start-Job` serialized its injection scriptblock as text. No injection or recovery
result is claimed for that attempt. The documented worker now reconstructs the
trusted injection block before calling the harness.

The updater itself remained unchanged while that collector was corrected. Original
manifests and collector versions are preserved; the sign-in helper records its own
script and parser hashes. Do not substitute the earlier interactive run's results:
that run used an older updater hash.

The recorded manifests retain the deployment file used in each VM. Deployment
comments and status text were corrected after transfer; its execution choices and
the tested updater hash did not change.

No real user-installed application upgrade is established by these guests. The
tests check execution context, continuation, inventory handling, and cleanup.
Windows 10 and PowerShell 5.1-only live bootstrap were not run in this session.
RDP and simultaneous interactive sessions were not exercised.
Published release assets were not built or validated.

For reuse, follow the [lab handoff](../tests/integration/lab/HANDOFF.md) and
[separate development gates](TESTING.md). Raw logs and manifests stay in the local
lab archive; the ignored local handoff records its location. Raw files can contain
guest identities and private paths and must not be copied into public issues.

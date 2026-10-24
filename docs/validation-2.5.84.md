# Validation for v2.5.84

**Status: reviewed release validation.** Local gates passed, and both release VM rows
completed on the exact release orchestrator. The interactive A row is a **PASS**. The
headless SYSTEM B row completed with deferred inventory, so the overall VM matrix is
**PARTIAL**; it does not establish full convergence on a machine with no signed-in user.

## What changed

- Targeted single-package Winget upgrades (`winget upgrade --id ...`) are parsed as Winget
  prints them: no `(N/M)` counter, and per-package wording for "no applicable upgrade" and
  "install technology is different". Targeted runs now reconcile exit codes and feed the
  deferred-inventory ledger the same way bulk runs do (PR #86).
- The repeating in-flight watchdog is armed before pre-flight instead of after it (PR #87).
  A same-boot resume pass that dies during pre-flight is now restarted within the watchdog
  interval instead of waiting for the next boot.

## Gates

```text
Unit/process behavior:       PASS (619 tests)
User/SYSTEM boundary:        PASS
Published launcher upgrade: PASS
Live bootstrap:              runs on publication; result recorded in the release notes
Provider integration:       NOT APPLICABLE (no provider install logic changed)
Multi-reboot convergence:    PARTIAL (A PASS, B completed with deferred inventory)
Release assets:              verified after publication (download, SHA256 sidecars, line endings, version)
```

- Release orchestrator SHA256: `B8FAA947E7437558131E1A3F43E8EB1453BC3853A3A87B34E7118EFB7CDE20BC`.
  Both release rows report this installed hash.

## Disposable VM evidence

| Row | Result | Evidence |
|---|---|---|
| A: interactive user, 3 armed reboots | **PASS**: 4 passes, 3 claimed and 3 OS-observed reboots, health checks passed, no tasks or state remain, CBS clear | `A-release-2.5.84-e73af159a73640119949461c8e175b7b` |
| B: headless SYSTEM fallback | **PARTIAL**: completed with deferred inventory after 5 passes, 2 claimed and 2 OS-observed reboots; health checks passed; no tasks or state remain; CBS clear | `B-release-2.5.84-c00a092877c74abfb64210c5ce87900e` |
| G: kill a resumed SYSTEM pass during pre-flight (PR #87 build) | **PARTIAL**, property held: the killed pass was resumed by the watchdog about 18 minutes later and the cycle completed; deferred inventory as in B | `G-preflight-kill-f76626c6cbac45c78b6e98fdaefb36d4` |
| B on the PR #87 build | **PARTIAL**, property held without injection: a pass died during pre-flight on its own and the watchdog resumed it about 17 minutes later | `B-watchdog-preflight-a90cc3f4a4e74ae0a18bbe8895b67d74` |

Rows G and the earlier B ran the PR #87 orchestrator before the version bump. The bump changes
only the embedded version string, which is why the release rows A and B were run again on the
bumped file. The PR #87 commit message calls the earlier B row a PASS; under the lab-row rules
it is PARTIAL, as recorded here.

### B deferrals

- Winget, Scoop and VS Code user scope: no interactive user appeared after two rediscovery
  attempts, so user-scope work was recorded as deferred inventory, as designed for a headless row.
- Windows Update: `KB5007651` installed successfully but was still offered on the final scan,
  and was recorded as re-offered after success.
- Cleanup advisory: 97 non-system, delete-only pending file operations remained. Updates
  converged and no restart was required.

## Not covered

- The lab guest has no Winget, so the targeted Winget transcript path is covered by unit tests
  built from real Winget transcript shapes, not by a live VM run.
- The Windows Update replacement of `pwsh.exe` that motivated PR #87 was observed once on its
  own; row G reproduces the effect (a dead pass in pre-flight) by killing the process.

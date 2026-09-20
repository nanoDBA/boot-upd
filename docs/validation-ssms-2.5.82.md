# SSMS 22 native servicing validation

Date: 2026-09-20. Implementation: `a2ea739`.
Tracking: [#73](https://github.com/nanoDBA/boot-upd/issues/73).

## Automated gates

- Local unit/process suite: 563 tests passed.
- Local user/SYSTEM exclusion and published-launcher compatibility gates: passed.
- Final focused lifecycle suite: 9 tests passed; provider suite: 18 tests passed.
  These overlap the full suite and are not additional full-suite tests.
- All 42 PowerShell files parsed; PSScriptAnalyzer reported zero error-severity findings.
- [GitHub CI](https://github.com/nanoDBA/boot-upd/actions/runs/35520474420):
  quality, user/SYSTEM exclusion, and published-launcher upgrade jobs passed.

## Native installer VM: PASS

Evidence directory: `SSMS-provider-20260920-114020` (private raw artifacts).
The measured production script SHA256 was
`500B50B729A44DA08061633C6A7CF0AD2E7C23EBA168EB27A75B6A872D9DE446`.
The guest runner verified this hash and a unique run identifier, and ran as SYSTEM.

| Observation | Before | After | Second pass |
| --- | --- | --- | --- |
| SSMS display version | 22.9.2 | 22.10.1 | 22.10.1 |
| Installation build | 22.9.12120.119 | 22.10.12210.168 | 22.10.12210.168 |
| Complete and launchable | Yes | Yes | Yes |
| Provider count | — | 1 | 0 |
| Installer triggered | — | Yes | No |

The same instance identity, installation path, release channel, and configured
channel source survived the update. Native servicing took 15.8 minutes. The final
SSMS summary was one update, with no pending accounting records or reboot evidence.
The second provider invocation independently refreshed inventory and verified a no-op.

This gate exercises the production provider helpers and process wrapper, with a
private checkpoint path and test UI callbacks. It does not itself establish full
cycle completion. The installer did not request a reboot in this run; native
3010/1641 and interrupted accounting cases have automated regression coverage,
not a demonstrated native-installer reboot in this VM run.

## Full-cycle VM rows

The headless SYSTEM row and interactive `upd.cmd` row run serially because the
lab has capacity for one active guest. Results will be recorded after collection.

### Initial headless row: PARTIAL

Evidence directory: `B-ssms-final-lab-b-20260920-115709`.
This row used the initial default-on implementation, before `-SkipSsms` was added.
Five passes and two reboots were observed; Windows event 6005 and the updater's
reboot count agreed. SSMS absence was handled successfully, and machine servicing
continued with no interactive session. The completion claim explicitly deferred
Winget, Scoop, and VS Code user work and the KB5007651 re-offer after successful
installation.

The collector observed zero continuation tasks but an active state file and a
CBS reboot marker. This is not evidence of complete cleanup or settled reboot
state. Investigation found two ordering gaps: the collector could finish between
task removal and state removal ([#74](https://github.com/nanoDBA/boot-upd/issues/74)),
and the final Windows Update scan could leave the last clean reboot observation
several minutes old ([#75](https://github.com/nanoDBA/boot-upd/issues/75)). The exact
time and cause of the observed CBS marker were not established. Final rows use
the corrected collector and a fresh settled reboot probe after that scan.

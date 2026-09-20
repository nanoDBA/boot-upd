# SSMS 22 native servicing validation

Date: 2026-09-20. Final implementation: `7030170`.
Tracking: [#73](https://github.com/nanoDBA/boot-upd/issues/73).

Release assets are exported from committed Git blobs. The orchestrator release
blob SHA256 is `2AFA525678E508939551AB6DBB7C17FC2CD3253566D0C01EA2D3BA431D5EC59B`.
Its LF line endings differ from the CRLF VM source identified below; a direct UTF-8
comparison after line-ending normalization confirmed identical text.

## Automated gates

- Local unit/process suite: 577 tests passed on the final implementation.
- Local user/SYSTEM exclusion and published-launcher compatibility gates: passed.
- Focused SSMS lifecycle suite: 11 tests passed; provider suite: 18 tests passed.
  These overlap the full suite and are not additional full-suite tests.
- All 43 PowerShell files parsed; PSScriptAnalyzer reported zero error-severity findings.
- [GitHub CI](https://github.com/nanoDBA/boot-upd/actions/runs/35524681689):
  quality, user/SYSTEM exclusion, and published-launcher upgrade jobs passed.

## Native installer VM: PASS

Evidence directory: `SSMS-provider-20260920-114020` (private raw artifacts).
The measured production script SHA256 was
`500B50B729A44DA08061633C6A7CF0AD2E7C23EBA168EB27A75B6A872D9DE446`.
The guest runner verified this hash and a unique run identifier, and ran as SYSTEM.
This native run used `a2ea739`; all 18 SSMS helper functions were independently
compared with the final implementation and remain unchanged. The final full-cycle
rows additionally cover the parameter and final-verification changes.

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
lab has capacity for one active guest.
This is not an all-PASS matrix: the headless rows retain the qualifications below.

### Final headless `-SkipSsms` row: PARTIAL

Evidence directory: `B-skip-ssms-final-lab-b-20260920-131135`.
Both the transferred source and installed orchestrator measured SHA256
`0F5BC2DDD9A91FE73008C18B244E3EBB64F93FA3BD0A5CFF512E06F8BC65E385`.
The corrected collector captured its final snapshot at 17:45:19 UTC.

The initial and every resumed SYSTEM launch contract retained the SSMS skip
setting, and the phase log recorded `Ssms (disabled)`. Four passes completed with
two reboots, matching the independent Windows event count. No interactive console
user or Explorer session was present. All five service-health checks passed.
The final scan was followed by a fresh settled reboot probe; the collector observed
zero continuation tasks, no active state, no CBS reboot marker, and no updater
processes. Both lab guests were shut down normally after evidence collection.

Parameter persistence, reboot accounting, and cleanup are verified. The overall row
is PARTIAL because Winget, Scoop, and VS Code user work could not run without a user,
and Windows Update still offered KB5007651 after recording successful installation.
The updater explicitly reported those as deferred inventory. Preflight also reported
active Windows servicing processes; the configured `-Force` policy allowed the pass
to continue, and a later CBS signal took the normal reboot path before mutation.

### Final interactive `upd.cmd` row: PASS

Evidence directory: `A-ssms-upd-boot-upd-matrix-20260920-130018`.
The final source (`7030170`, host SHA256
`0F5BC2DDD9A91FE73008C18B244E3EBB64F93FA3BD0A5CFF512E06F8BC65E385`)
was transferred with the harness's source/guest hash equality check.

The actual `upd.cmd` entry point completed four passes and three reboots, with
all three confirmed independently by Windows event 6005. SSMS ran in the normal
phase sequence and correctly recognized build 22.10.12210.168 as current, counting
zero SSMS updates. All five service-health checks passed. The final Windows Update
scan found no applicable updates and was followed by a fresh settled reboot probe.
The collected snapshot showed zero continuation tasks, no active state, and no CBS
reboot marker; the run reported unqualified completion.

This harness invocation had already been parsed while held before the collector
fix was written. Its final snapshot nevertheless independently contains all required
cleanup facts. The subsequent explicit-skip row uses the corrected collector and
its additional source/installed-script hash fields.

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
time and cause of the observed CBS marker were not established. The final build
takes a fresh settled reboot probe after that scan, and the explicit-skip row uses
the corrected collector.

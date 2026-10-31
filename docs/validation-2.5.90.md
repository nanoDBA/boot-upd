# v2.5.90 validation

This release makes the existing same-boot recovery limit configurable through `upd`. The default remains 5; this does not change the retry behavior of an existing invocation.

## Launcher behavior

- `upd /?` identifies the batch entry point, distinguishes commands that may request administrator rights, describes `upd bootstrap` as installing or upgrading PowerShell 7, and lists both retry limits.
- `upd plan --max-retry-passes 8` reports `MaxRetryPasses: 8` and exits without elevation, updates, tasks, or reboots.
- The launcher passes the value to deployment, where it becomes the core `MaxRetryPasses` setting.

## Gates

- Focused launcher Pester: **61 passed, 0 failed**.
- Full unit/process Pester: **677 passed, 0 failed** (61.26 seconds).
- User/SYSTEM boundary: **passed** (5.04 seconds).
- Published-launcher upgrade from v2.5.43: **passed** (4.48 seconds).
- GitHub quality, User/SYSTEM, and published-launcher checks: **passed**.
  The first hosted quality attempt lost one Pester worker at the framework/container level without an assertion-level failure; rerunning the failed job passed.

No multi-reboot lab row was run: the default retry limit is unchanged, and this release only exposes the existing deployment setting through the launcher. The separate [release-triggered live bootstrap workflow](https://github.com/nanoDBA/boot-upd/actions/runs/41247716667) passed both clean Windows PowerShell 5.1 VM jobs: fresh install and legacy repair. The host was not rebooted.
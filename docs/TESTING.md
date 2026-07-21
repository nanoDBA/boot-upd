# Testing Boot Update Cycle

Treat test confidence as separate gates. A large Pester count does not substitute for a missing Windows security-context, published-upgrade, or reboot-convergence gate.

## Required gates

| Gate | What it proves | Automation |
|---|---|---|
| Unit and process behavior | State transitions, retry limits, parsing, UI ordering, failure classification, and ordinary cross-process ownership | Every push and pull request |
| User/SYSTEM security boundary | The production global mutex is mutually exclusive and accessible in both directions across real Windows identities | Every push and pull request |
| Published launcher upgrade | The immutable oldest supported launcher upgrades to the candidate without stale-offset execution or leftover sidecars | Every push and pull request |
| Live bootstrap | The README command works from Windows PowerShell 5.1 on a clean hosted VM | Published releases and manual dispatch |
| Live provider integration | External provider behavior such as AWS publisher rollover and cleanup | Manual dispatch before affected releases |
| Multi-reboot convergence | Checkpoint, restart, delayed signals, user-primary/SYSTEM-fallback, cleanup, and final claims survive at least two real reboots | Disposable VM before lifecycle-affecting releases |

Run the locally available gates from an elevated PowerShell 7 console:

```powershell
./tools/Invoke-TestGates.ps1
```

Use `-SkipOsBoundary` only on a non-elevated development machine and report that category as **not run**, never as passed. `-SkipPublishedUpgrade` is for offline development only.

## Multi-reboot VM matrix

Before releasing changes to checkpointing, tasks, reboot detection, mutexes, provider convergence, or final cleanup, exercise at least:

- Windows 10 and Windows 11 where supported;
- PowerShell 5.1-only bootstrap and an existing PowerShell 7 installation;
- interactive-user continuation, no-user-login SYSTEM fallback, and both triggers becoming eligible;
- two or more reboots, a canceled delayed restart, a failed restart command, and a delayed reboot signal;
- local profiles plus OneDrive-redirected module paths;
- killed-process recovery during checkpoint creation and immediately after state promotion.

Capture the updater log, every checkpoint revision, task definitions and results, boot identifiers, effective identities, provider exit/reboot evidence, and the final cleanup inventory. A scenario passes only when every enabled phase converges, no reboot evidence remains after settling, health checks pass, and both tasks and active state are absent.

## Release evidence

Report each gate independently:

```text
Unit/process behavior:       PASS
User/SYSTEM boundary:        PASS
Published launcher upgrade: PASS
Live bootstrap:              PASS
Provider integration:       PASS or NOT APPLICABLE
Multi-reboot convergence:    PASS
Release assets:              PASS
```

Do not collapse `NOT RUN`, `NOT APPLICABLE`, and `PASS`. Release assets must be downloaded again, matched to SHA256 sidecars, checked for expected line endings, and matched to the tag and embedded version.

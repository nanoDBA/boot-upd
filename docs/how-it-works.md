# Reboot and console internals

For installation and everyday commands, see the [README](../README.md).

## Reboot and resume checks

1. Pre-flight checks visibly report their current check and elapsed time while validating disk space, network, battery, and conflicting installers. They observe—but never start—the Windows Update service
2. Interactive deployment starts in your user context; unattended deployment can start as SYSTEM. User-scoped Winget, Scoop, and VS Code work can also run during later user-context resumes
3. Before mutation, two reboot-signal probes span a 20-second servicing-settle window. CBS, Windows Update Agent, real file replacements, protected Windows-file deletes, and provider-native reboot results are hard barriers; delete-only application/cloud/temp housekeeping is reported as an advisory
4. Native `3010`/`1641`, Chocolatey `350`/`1604`, and `Microsoft.Update.SystemInfo.RebootRequired` results are persisted immediately instead of waiting for registry flags to appear
5. Verified resume tasks are armed before updates start: user-at-logon plus a delayed SYSTEM fallback, with dated watchdogs for canceled shutdowns and deferred retries
6. `shutdown /g` restarts Windows; the checkpoint resumes automatically, preserves successful provider phases, preserves user-only work for user context, and retries only incomplete or interrupted work
7. Windows Update owns its service recovery: start and component-reset attempts are isolated behind a 30-second boundary. A stuck or indefinitely `StartPending` service makes only that phase retryable while safe independent providers continue
8. A successful online Windows Update assessment is reusable for six hours—even across reboots—only after an offline WUA catalog check confirms zero applicable work and the update source, scope, and recent servicing history fingerprints still match
9. Full convergence requires every enabled phase, a zero-applicable Windows Update assessment, and two probes with no blocking reboot evidence (max 5 completed reboot safety valve). A cycle can instead complete with explicitly reported deferred inventory; those items are not counted as updated. Optional third-party cleanup cannot create a reboot loop; routine categories are compact in Verbose, fingerprints are reserved for Debug and the log, and Normal remains focused on actionable state
10. Hooks run, resume tasks and transient state are removed and verified absent, and only then does the final screen congratulate the user and send a result-specific notification
11. If explicit aggressive mode quarantined a persistent Winget failure, its durable record survives cleanup and the final screen reports degraded completion with an `upd uq` reversal command

Notifications distinguish four outcomes instead of using one generic toast: updates complete with no restart,
another pass scheduled with no restart, user-context work waiting for sign-in, and restart required with automatic
continuation. They are shown only in an interactive user session; SYSTEM resume work never attempts a desktop toast.

## Console rendering

Choose the initial view explicitly with `-OutputMode Quiet|Normal|Verbose|Debug`, or set
`OutputMode` in `Deploy-BootUpdateCycle.ps1`. The interactive `BOOT//PULSE` row uses a
classic `| / - \` ASCII propeller with a 112-step, seven-stop theme-zero glow. Cyan, blue,
magenta, acid green, and electric yellow-green flow through near-black violet and cyan valleys,
making the pulse discernible at a distance without abrupt flashes. Motion and color advance independently.
At narrower widths the row keeps the operation,
elapsed time, and `v:NORMAL` mode visible, shortens repeated provider prose, and drops decorative meter
cells first. Normal and Verbose omit `CPU 0s | 0 proc`; nonzero activity remains visible, while Debug
shows the raw heartbeat fields for diagnosis.
ASCII status text is kept immutable; non-ASCII glyphs are represented safely in the live row while
remaining untouched in the log. Key polling and animation disable themselves under SYSTEM,
redirected output, and non-console hosts; file logging is unchanged.

On VT consoles, steady-state frames overwrite the owned row in place to avoid ConsoleHost flicker;
a full erase is reserved for width changes, ordinary output, mode transitions, and cleanup.

All console rendering is built in; the updater does not install or import a third-party TUI module.
Phase headers and results use native ANSI/console output, and the themed splash remains unchanged.

To visually smoke-test animation without running any package updates:

```powershell
.\tools\Show-BootUpdateProgressDemo.ps1
```

The demo renders the same four-frame `BOOT//PULSE` propeller, adaptive-width row, and interpolated neon
gradient at the production 100 ms cadence, includes the photographed Windows Update status text, accepts
live `v` mode cycling, and restores its console row and cursor when complete.

Built-in operations that can block for more than a moment run behind a process-tree-aware,
progress-pumped adapter, keeping both animation and `v` key handling responsive. Administrator-supplied
hooks intentionally retain same-scope execution semantics; a long hook must provide its own
console feedback because isolating it would change how hook variables and side effects work.

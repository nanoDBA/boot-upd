# Boot Update Cycle - Release Notes

**Current Version:** v2.5.31
**Release Date:** 2026-07-20
**Status:** STABLE

---

## v2.5.31 (2026-07-20)

### Verified launcher handoff before operational dispatch

- Added a deliberately untyped stage-zero launcher that receives raw arguments, refreshes the complete checksummed release bundle, and only then invokes the current typed command implementation.
- With PowerShell 7 already present, operational and not-yet-known commands cross a single elevation boundary and are interpreted by the newly installed launcher; a current invocation no longer continues under stale in-memory dispatch code. A PS5.1-only machine may show a separate first-use consent while installing PowerShell 7.
- Help, version, plan, status, splash, demo, fun, and bootstrap remain local and non-mutating. `-nu` remains the explicit offline/no-refresh escape hatch.
- Added a PS5.1-compatible compatibility installer for pre-trampoline batches. It resolves the actual PATH winner, stages outside cloud storage, verifies every runtime asset, checks for sync races, snapshots exact targets, commits batch-last, rolls back on failure, and then forwards the requested arguments.
- Added checksummed recovery for a missing stage-zero asset and expanded release/deployer coverage and regression tests.

Historical batches still require the one-time external compatibility installer; newer code cannot intercept arguments that an already-running legacy batch rejected before handoff.

---

## v2.5.30 (2026-07-20)

**Windows PowerShell 5.1 can open the door; PowerShell 7 still runs the machine.**

- Adds a Windows PowerShell 5.1-compatible bootstrap that installs PowerShell 7 side-by-side through WinGet or a Microsoft Authenticode-validated stable MSI fallback.
- Keeps help and version non-mutating on PS5-only systems and requires explicit `upd bootstrap` before read-only preview, plan, or status commands.
- Automatically bootstraps PowerShell 7 for operational update, repair, and AWS commands, then relaunches the typed launcher under `pwsh`.
- Preserves the PowerShell 7-only orchestrator, `Start-ThreadJob`, `ForEach-Object -Parallel`, and absolute-`pwsh` scheduled resume paths.
- Adds the bootstrap to the checksummed transactional runtime bundle and release assets.

---

## v2.5.29 (2026-07-20)

**A friendly, compact launcher with safe previews and a checksummed self-updating handoff.**

- Adds typed `upd` commands for help, plan, status, version, explicit update, splash, demo, and fun, with compact aliases such as `upd d`, `upd p`, `upd u`, and `upd v`.
- Adds short run flags (`-r`, `-o`, `-n`, `-t`, `-s`, `-drv`, `-fw`, `-w`, `-c`, `-m`, `-x`, and `-i`) while retaining descriptive long forms.
- Keeps help, planning, splash, demo, fun, version, and status non-elevated and non-mutating; operational execution still fails closed without administrator rights.
- Passes validated options across UAC as Base64-encoded structured JSON instead of rebuilding a free-form command line.
- Refreshes the full runtime bundle only from release assets with mandatory SHA256 sidecars, validates every asset before mutation, rolls back failed commits, and checksum/version-gates atomic `upd.cmd.next` adoption.
- Preserves a compatibility bridge for older two-script installations, adds `upd repair` recovery, and publishes all six executable runtime assets plus matching checksums through a verified draft-release gate.
- Adds `upd aws` (`upd a`) for focused AWS CLI v2 and AWS.Tools repair/update work and rejects ambiguous dashed short commands before they can become a default update run.
- Adds launcher behavior and forwarding tests while keeping every splash theme byte-identical.

---

## v2.5.28 (2026-07-20)

**A reboot chain that survives delayed evidence, canceled restarts, context changes, and honest provider failures.**

- Persists native reboot requests in durable state and clears them only after Windows reports a different boot-session identity; reboot counts now represent observed completed boots.
- Uses the two-probe servicing-settle detector before mutation as well as at completion, preventing late CBS or Windows Update flags from racing the next install phase.
- Treats pending reboot evidence as a phase barrier and stops the remaining sequential/parallel work after a provider raises `3010` or `1641`.
- Adds dated watchdogs for cancelable shutdowns, maintenance-window deferrals, transient resumed preflight failures, and staged no-reboot continuations.
- Preserves a saved interactive identity across SYSTEM fallback runs and defers Winget user scope, Scoop, VS Code, WSL, and containers until a user-context continuation can run.
- Round-trips behavior-changing switches and structured include/exclude arrays through scheduled resumes, then reads tasks back to verify exact action arguments, principal, trigger types, startup delay, and retry policy.
- Stops treating provider exceptions, timeouts, failed thread jobs, or native nonzero exits as success across driver/firmware, WSL, containers, Defender, AWS, PowerShell modules, and parallel package adapters.
- Requires a final read-only Windows Update scan to report zero applicable updates in the configured category scope.
- Checks `shutdown.exe` results and queues recovery when restart initiation fails; unknown-user discovery retries no longer consume mutation iterations.
- Moves the success notification and the personality-rich completion banner after hooks, task retirement, state cleanup, and terminal cleanup verification. Skipped health checks receive downgraded wording.
- Adds behavioral state-machine tests for boot identity, evidence retention, completion disposition, dated maintenance retries, convergence scans, watchdogs, cleanup ordering, and failed parallel jobs.
- Keeps every splash theme byte-identical.

### Scope note

The verified claim is intentionally limited to the configured patch pass. Full zero-work convergence for asynchronous Office Click-to-Run and additional package providers is tracked as follow-up work.

---

## v2.5.27 (2026-07-20)

**Reboot-resilient checkpoints and a completion screen that earns its confidence.**

- Arms and verifies the durable resume checkpoint before any mutating phase, so even an installer-initiated `1641` surprise reboot has a continuation waiting after boot.
- Captures native installer exit codes `3010` and `1641` as explicit reboot requests instead of losing them at the PowerShell child-process boundary.
- Requires two clean reboot-signal probes across a 20-second animated servicing-settle window before completion.
- Gives resume tasks three two-minute retries, rejects overlapping instances, and reads every registration back before permitting a reboot.
- Preserves the checkpoint and retry chain when a resumed run encounters a transient preflight failure; failed preflights no longer consume an iteration.
- Withholds success when any enabled phase is incomplete and queues a two-minute recovery pass.
- Tracks actual orchestrated reboot count in durable state.
- Replaces the optimistic `FULLY PATCHED` footer with a warm, evidence-backed `PATCH CYCLE VERIFIED` screen: configured phases, double reboot check, service health, and queue state.
- Keeps every splash theme byte-identical.

---

## v2.5.26 (2026-07-20)

**Smooth ConsoleHost repaint without blank-frame stagger.**

- Removed the full `CSI 2K` erase from every steady-state VT animation tick; frames now overwrite the owned row directly with bounded tail padding.
- Retained full-line erasure for console-width changes, logs, verbosity transitions, completion, and error cleanup.
- Preserved the v2.5.25 `| / - \` propeller, 100 ms cadence, and exact 48-step cyan/blue/magenta/acid-green glow.
- Updated the demo and regression suite to enforce flicker-free steady-state writes and resize-safe clearing.
- Kept every splash theme byte-identical.

---

## v2.5.25 (2026-07-20)

**Turbo-era propeller status bar.**

- Replaced the bidirectional chevron comet with the classic fixed-width ASCII `| / - \` propeller sequence.
- Preserved the existing smooth cyan, blue, magenta, and acid-green glow exactly; only the motion glyph changed.
- Retained the independent 48-step color cycle, 100 ms cadence, immutable status text, live `v` mode switching, and safe non-VT fallback.
- Updated the visual demo and regression suite to enforce the propeller order, fixed width, smooth loop seam, and production/demo parity.
- Kept every splash theme byte-identical.

---

## v2.5.24 (2026-07-20)

**Smoother BOOT//PULSE glow with a dependency-free console UI.**

- Replaced the ten abrupt per-frame color jumps with a closed 48-step RGB interpolation through the splash palette's cyan, blue, magenta, and acid-green anchors.
- Decoupled the comet motion index from the color index so the ten-frame movement does not reset or strobe the longer color fade.
- Removed the `PwshSpectreConsole` discovery, installation, trust-validation, import, and rendering paths; its only remaining job was coloring three lines already covered by native output.
- Phase headers and results now render directly through the existing native ANSI/console paths, eliminating a PSGallery/network dependency from elevated runs.
- Added regression coverage that bounds every adjacent RGB channel change, including the loop seam, while preserving the splash golden hash.

---

## v2.5.23 (2026-07-20)

**Splash-themed BOOT//PULSE animation with corruption-proof status text.**

- Replaced PowerShell's host-owned yellow Minimal progress pane after ConsoleHost was observed shifting every status character down one code point.
- The updater now owns one live carriage-return row with a fixed-width ASCII comet and the splash palette's cyan, magenta, blue, and acid-green pulse.
- Activity and status text remain separate from the animated frame; unsafe controls are removed and the live row is normalized to single-cell ASCII before resize-safe truncation. Full Unicode remains unchanged in the log.
- Ordinary logs and Spectre phase/result lines clear the live row before printing; completion restores the cursor and removes residual text.
- Quiet mode hides the row while continuing to poll `v`, and SYSTEM, redirected, detached, or non-VT consoles retain safe fallbacks.
- The visual demo now exercises `BOOT//PULSE`, the exact photographed Windows Update text, palette cycling, and live verbosity changes without running updates.
- Added regression coverage for exact status preservation, ASCII-safe fixed-width frames, cadence, console cleanup, and width handling.
- The BBS splash implementation and all three themes remain byte-stable.

---

## v2.5.22 (2026-07-19)

**Continuously animated progress with extensive UI regression coverage.**

- Spinner rendering now refreshes every 100 ms and polls `v` on every frame.
- Long built-in commands and background jobs run behind progress-pumped, process-tree-aware adapters instead of freezing the parent UI thread.
- Sequential and staged paths now animate across Chocolatey, Windows Update and drivers, WSL, containers, package ecosystems, Defender, Office, AWS tooling, service checks, notification waits, and installer retry waits.
- Progress cleanup is idempotent and protected by a top-level `finally`, including staged-rollout early returns.
- Added behavioral tests for exact frame rotation, cadence bounds, live jobs, silent native processes, partial timeout output, descendant cleanup, failures, Quiet/noninteractive behavior, verbosity cycling, blocking-path coverage, and completion cleanup.
- Added `tools/Show-BootUpdateProgressDemo.ps1` for a harmless human-visible animation smoke test.
- The BBS splash implementation and all three themes remain unchanged.

### Compatibility

- Trusted hooks retain their existing same-scope behavior and are not moved to background runspaces. Long-running hooks remain responsible for their own feedback.

---

## v2.5.21 (2026-07-19)

**Optional Spectre-enhanced phase rendering with automatic, safe bootstrap.**

- Interactive PowerShell 7.4+ runs now use `PwshSpectreConsole` for richer phase and result lines.
- When no protected all-users copy exists, stable version 2.6.3 is installed from PSGallery under Program Files; user-writable module copies are never imported by the elevated updater.
- SYSTEM, redirected, older-PowerShell, offline, `-WhatIf`, and failed install/import paths retain the native renderer.
- The key-responsive native `Write-Progress` spinner and all themed splash functionality remain unchanged.

### Compatibility

- PowerShell 7 remains the baseline. Spectre enhancement requires 7.4+, but it is optional and never blocks an update cycle.

---

## v2.5.20 (2026-07-19)

**Compact live progress, runtime verbosity controls, and preserved themed splash.**

- Interactive runs now default to a compact phase/progress view while retaining the complete timestamped log file.
- The existing themed startup splash and preview/theme controls remain enabled in the default view; only explicit Quiet mode suppresses the splash.
- Pressing `v` cycles live through Quiet, Normal, Verbose, and Debug console modes without restarting the updater.
- Native minimal `Write-Progress` rendering adds phase progress and spinner feedback during monitored processes and parallel cohorts, with safe automatic disablement under SYSTEM or redirected hosts.
- `-OutputMode` and the deployment `OutputMode` setting select the initial view and persist across scheduled reboot resumes.

### Compatibility

- No state-schema changes and no mandatory UI dependency. Normal remains the default, while full diagnostic output remains available in the log and through Verbose/Debug modes.

---

## v2.5.19 (2026-07-19)

**Fail-closed self-update integrity, protected webhook storage, and trusted elevated hooks.**

- Self-update now fails closed unless every downloaded PowerShell asset has a valid, matching SHA-256 value.
- Notification webhook URLs persist only in an ACL-protected ProgramData file and are no longer forwarded through Task Scheduler or self-update process arguments.
- Elevated extension hooks must remain under the orchestrator directory, be owned by Administrators or SYSTEM, and pass path, reparse-point, and broad-write ACL checks before execution.
- Deployment now hardens the ProgramData installation directory, and a no-echo webhook initializer supports secure setup and removal.

### Compatibility

- No state-schema changes. Existing webhook configuration can migrate through the one-time deployment setting; non-HTTPS webhook endpoints are now rejected.

---

## v2.5.18 (2026-07-19)

**Race-free self-update handoff, process-level regression coverage, and automated quality gates.**

- The updater retains continuous ownership of the single-instance mutex while its replacement runs, eliminating the release/reacquire race.
- A consumed, process-only nonce capability identifies the replacement child while legacy updater handoffs remain supported.
- Mutex arbitration now has an injectable mutex-name seam, preserving fail-closed production behavior while enabling isolated real-process tests.
- Added focused unit and real-process regression coverage for accepted and rejected handoffs, capability consumption, continuous parent ownership, competing invocation rejection, and legacy compatibility.
- Added Windows GitHub Actions quality gates for PowerShell parsing, Pester 5, PSScriptAnalyzer error-severity findings, and Git diff integrity.
- Fixed invalid switch-return syntax in the update-history renderer that the new parser gate surfaced.
- Hardened release creation by staging immutable script copies before hashing and upload, cleaning temporary assets on every exit path, and supporting `-WhatIf` validation without publication.
- Added secure Windows Credential Manager onboarding for the centralized beads client and renamed its repository-local lookup key to `beads.credentialTarget`.

### Compatibility

- No user-facing updater parameter or state-schema changes. Drop-in replacement for v2.5.17.

---

## v2.5.17 (2026-07-18)

**Self-update mutex handoff and persistent source healing.**

- The running version now releases the named mutex before launching its downloaded replacement.
- A replacement downloaded by v2.5.16 or older recognizes the legacy synchronous parent handoff, allowing existing broken installations to heal from GitHub without a manual file copy.
- After GitHub confirms the live script is current, it repairs an older launcher-side `Invoke-BootUpdateCycle.ps1` so the next `upd` run cannot redeploy the stale version.
- Deployment preserves a newer ProgramData copy if source update is unavailable, preventing a network failure from downgrading a healed installation.
- No parameter or state-schema changes. Drop-in replacement for v2.5.16.

---

## v2.5.16 (2026-07-06)

**ARSO user-context resume + wildcard/allowlist filters + notification levels.**

### ARSO user-context resume (2ql)

Where Windows ARSO (Automatic Restart Sign-On) is available — not SYSTEM, `DisableAutomaticRestartSignOn` policy unset, user not opted out — the post-reboot task is now registered as the **user at logon** instead of SYSTEM at startup. Combined with v2.5.15's `shutdown /g`, the user is signed back in automatically and the cycle resumes in **user context**, so user-scoped phases (winget user scope, Scoop, VS Code extensions, WSL, containers) run on **every** iteration, not just the first. No password is ever stored — winlogon handles the resume.

- Fallback: a `BootUpdateCycleFallback` SYSTEM task (startup + 3 min) covers the case where ARSO doesn't sign the user in; the named mutex arbitrates if both fire and phase flags prevent duplicate work.
- Without ARSO, the classic single SYSTEM-at-startup task is registered as before.
- `Uninstall.ps1`, re-deploys, and self-destruct remove both tasks.

### Package filters (6sh, from Winget-AutoUpdate)

- `ExcludePatterns` now supports wildcards (`Mozilla.Firefox*`, `*.Beta`) alongside legacy substrings.
- New `-IncludePatterns` allowlist mode: when non-empty, ONLY matching packages update (winget/choco/pip filtered paths; exclude wins over include).
- Both flow through remote config (`ConfigUrl`) and the post-reboot task arguments.

### Notification levels (6sh)

New `-NotificationLevel Full|SuccessOnly|ErrorsOnly|None` gates toast/webhook/email/msg.exe noise. Event log entries and the native shutdown countdown are never gated. Max-iterations exit now sends an Error-kind notification (visible under `ErrorsOnly`).

### Compatibility

- New optional parameters only. Drop-in replacement for v2.5.15.

---

## v2.5.15 (2026-07-06)

**Reboot-loop diagnosability, WU self-healing, WU prefetch, ARSO restart.**

### Changes

- **Per-signal pending-reboot detail (juw):** `Test-PendingReboot` now reports WHY each signal is pending (FileRename count + sample paths, active→pending computer name, CCM hard/soft flags) and adds two signals: CBS `PackagesPending` and WU `PostRebootReporting`. If a reboot is driven by the exact same signal set as the previous reboot, the log calls out a likely stale/perpetually-repopulated signal (the classic `PendingFileRenameOperations` loop).
- **WU remediation escalation (gxo):** after 2+ consecutive Windows Update phase failures (streak survives reboots via a sidecar file), the standard component reset runs once per streak — stop wuauserv/cryptsvc/bits/msiserver, rename SoftwareDistribution + catroot2, restart. DISM /RestoreHealth is deliberately left manual.
- **WU download prefetch (2uj):** Windows Update scan+download starts as a background child process right after the pending-reboot check and runs while Winget/Chocolatey execute (BITS downloads — no msiexec/CBS contention). The install step stays sequential and collects the prefetch first. Skipped in staged rollout/WhatIf/module-missing cases.
- **ARSO restart:** reboots now use `shutdown /g` instead of `/r` — Windows Automatic Restart Sign-On signs the last interactive user back in and restarts registered apps, with no stored password. Degrades gracefully to a plain restart where ARSO is unavailable. `shutdown /a` still aborts.
- State gains `LastRebootSignals` (add-if-missing migration; no schema version bump).

### Compatibility

- No parameter changes. Drop-in replacement for v2.5.14.

---

## v2.5.14 (2026-07-06)

**Wider parallel cohort — faster cycles.** Defender, Office 365, and PowerShell modules move from the sequential chain into the ThreadJob parallel cohort (now 8 phases wide), overlapping with pip/npm/Scoop/.NET tools/VS Code. None of the three touch msiexec or CBS, so they cannot conflict with the sequential installers. Typical saving: the full serial time of those three phases per iteration (often 5–15 min).

### Details

- Defender in the cohort uses process-based `MpCmdRun.exe -SignatureUpdate -MMPC` instead of `Update-MpSignature` (the Defender module's WinPS-compat remoting is not safe to share across ThreadJob runspaces).
- Sequential chain is now: Winget → Chocolatey → Windows Update → Driver/Firmware → AWS tooling → WSL → Containers (msiexec/CBS contention, or opt-in caution).
- Staged rollout (`-StagedRollout`) is unaffected — it still runs one phase per boot via the original functions.
- Crash recovery, per-phase hooks, state flags, and summary counts unchanged.

### Compatibility

- No parameter or schema changes. Drop-in replacement for v2.5.13.

---

## v2.5.13 (2026-07-06)

**Self-update hardening.**

### Changes

- Releases now ship `.sha256` sidecar assets for both scripts (via new `tools/New-Release.ps1` helper), activating the SHA256 integrity checks that already existed in both self-update paths but had never fired.
- `Deploy-BootUpdateCycle.ps1` now also self-updates its own source copy from the latest release (previously only Invoke's source was refreshed). Same parse + SHA256 validation, atomic replace with `.bak`, `BOOT_UPDATE_NO_SELF_UPDATE` opt-out. `upd.cmd` is intentionally not auto-updated (replacing a running batch file is unsafe).
- CLAUDE.md documentation caught up: splash themes/preview, log-filter and `--no-progress` conventions, dual source self-update, release procedure.

### Compatibility

- No parameter or schema changes. Drop-in replacement for v2.5.12.

---

## v2.5.12 (2026-07-06)

**Splash defaults to neon gradient.** No more per-run rotation — theme 0 (neon gradient) is the default on VT consoles. `BOOT_UPDATE_SPLASH_THEME=0|1|2` still switches themes, `upd splash` still previews all three, and non-VT consoles still get the classic blocks.

### Compatibility

- No parameter or schema changes. Drop-in replacement for v2.5.11.

---

## v2.5.11 (2026-07-06)

**Splash art in README.** Pixel-true SVG renders of all three splash themes (`docs/img/splash-theme{0,1,2}.svg`), generated from the actual `Show-StartupArt` ANSI output, embedded in the README — neon gradient as the hero image, the other two collapsible.

### Compatibility

- Docs/assets only; no functional changes. Drop-in replacement for v2.5.10.

---

## v2.5.10 (2026-07-06)

**Splash preview mode.** `Invoke-BootUpdateCycle.ps1 -PreviewSplash` renders all three splash themes (labeled, with the `BOOT_UPDATE_SPLASH_THEME` pin hint) and exits — no mutex, no state, no updates. `upd splash` reaches it from cmd/Run dialog (self-elevates, pauses so the window stays open).

### Compatibility

- New optional switch only. No schema changes. Drop-in replacement for v2.5.9.

---

## v2.5.9 (2026-07-06)

**Rotating splash themes.** Each run cycles through three wordmark variants: (0) neon gradient with scanlines/dither/bevel, (1) bright-rim outline with checkerboard-dithered fill and denser glitch confetti, (2) classic 16-color blocks. Pin one with `BOOT_UPDATE_SPLASH_THEME=0|1|2`.

### Additions

- Glitch-confetti gutters flanking the wordmark (deterministic, sparse colored cells in the letter palette).
- Bevel on the neon theme: bright lip on top edges, dark shadow on bottom edges.
- BBS-style metadata footer: `[board] nanoDBA/boot-upd`, `[motd]`, and `[log]` (live log path) lines under the sysop/carrier tagline.

### Compatibility

- Non-VT consoles always get the classic block theme. Still spaces + background color only. No parameter or schema changes.

---

## v2.5.8 (2026-07-06)

**Neon gradient splash.** The BOOT wordmark now renders as 24-bit ANSI/VT gradient cells — per-letter demoscene gradients (cyan B, magenta O, blue/violet O, acid-green T), CRT scanlines (odd rows dimmed), deterministic dither, and a phosphor reflection row under the letters. The BBS frame, sysop/carrier tagline, and metadata header are unchanged.

### Compatibility

- Still spaces + background color only — no Unicode glyphs — so the pre-2.5.6 cmd.exe glyph-drop failure mode cannot recur.
- Consoles without VT truecolor (Server 2016, pre-Win10 1703) automatically fall back to the v2.5.6 16-color block wordmark.
- No parameter or schema changes. Drop-in replacement for v2.5.7.

---

## v2.5.7 (2026-07-06)

**Log spam elimination and upd.cmd hardening.**

### Fixes

- Chocolatey download progress no longer floods the log: `choco upgrade` now runs with `--no-progress`, and the `Write-Log` filter drops any `Progress:` line (previously only `Progress: ...% - Saving` was filtered). A single git.install download had produced hundreds of identical `Progress: Downloading git.install ... 1%` entries.
- `Write-Log` now collapses consecutive duplicate lines from any phase: the first occurrence logs normally, repeats are counted, and one `(previous line repeated N more times)` summary is emitted when the message changes.
- `Deploy-BootUpdateCycle.ps1` now self-updates the SOURCE copy of `Invoke-BootUpdateCycle.ps1` from the latest GitHub release before deploying (parse + SHA256 validation, atomic replace with `.bak`, `BOOT_UPDATE_NO_SELF_UPDATE` opt-out). Previously Invoke's self-update only patched the live ProgramData copy, which Deploy overwrote with the stale source on every run.

### upd.cmd improvements

- `upd /?` (also `-h`, `--help`) prints usage.
- The delay argument is validated as a whole number before elevating; bad input exits with code 1 and a clear message.
- Verifies `pwsh` is on PATH and `Deploy-BootUpdateCycle.ps1` exists next to the launcher before doing anything, with clear errors instead of a silently vanishing window.
- Startup banner now echoes the effective reboot delay.

### Compatibility

- No parameter or schema changes. Drop-in replacement for v2.5.6.

---

## v2.5.6 (2026-05-02)

**Win11 cmd and Server 2016 splash visibility fix.** Replaced glyph-dependent BOOT art with native PowerShell background-color cells made from ordinary spaces.

### Fixes

- Main BOOT wordmark now renders as colored background blocks via `Write-Host -BackgroundColor`, avoiding cmd.exe/font paths that drop Unicode block glyphs to blank space.
- Keeps the BBS/NFO frame and compact startup status flow from v2.5.5.
- Removes the fragile UTF-8 glyph capability branch that looked valid by codepage but failed visually in Windows 11 cmd.

### Compatibility

- No parameter or schema changes. Drop-in replacement for v2.5.5.

---

## v2.5.5 (2026-05-02)

**Splash and startup flow refinement.** Restored real BBS gradient block styling when UTF-8 console output is active, while keeping an ASCII fallback for legacy consoles.

### Fixes

- Added a gradient block splash path using `░▒▓█` framing and heavier BOOT lettering for consoles running UTF-8.
- Kept the ASCII-only splash fallback for constrained legacy output.
- Replaced the immediate second startup banner with a compact cycle status strip so the splash is not undermined by duplicate framing.

### Compatibility

- No parameter or schema changes. Drop-in replacement for v2.5.4.

---

## v2.5.4 (2026-05-02)

**Splash redesign.** Replaced the plain block-letter splash with a more distinctive static BBS/NFO-style BOOT screen.

### Fixes

- Uses a custom framed composition instead of generic hash-block lettering.
- Keeps the startup splash ASCII-only, ANSI-colored, dependency-free, and below 80 visible columns.
- Preserves the no-animation startup behavior.

### Compatibility

- No parameter or schema changes. Drop-in replacement for v2.5.3.

---

## v2.5.3 (2026-05-02)

**Splash compatibility cleanup.** Applied the practical constraints from OmniJeff's `ascii-art` skill guidance: ASCII-only art, simple retro characters, and an 80-column-safe banner.

### Fixes

- Removed the now-unnecessary `Show-StartupArt` Unicode codepage P/Invoke path; the splash no longer depends on box-drawing or block glyph support.
- Documented the banner's 80-column constraint in the splash comment.

### Compatibility

- No parameter or schema changes. Drop-in replacement for v2.5.2.

---

## v2.5.2 (2026-05-02)

**Splash compatibility fix.** Replaced the fragile Unicode BBS splash with a static ASCII-only BOOT banner.

### Fixes

- Startup art now renders cleanly in legacy `cmd.exe` consoles even when Unicode block and box-drawing glyphs fail.
- Keeps the BBS-style neon ANSI look, but removes animation and palette rotation.

### Compatibility

- No parameter or schema changes. Drop-in replacement for v2.5.1.

---

## v2.5.1 (2026-05-02)

**Splash render fix.** The BBS startup splash was rendering as blank space on legacy `cmd.exe` consoles because `chcp.com 65001 > $null 2>&1` at script start was silently no-opping when stdout was redirected, leaving the console at CP437/CP1252 — which strips Unicode box-drawing/block-element chars (U+2500–U+259F) to nothing.

### Fixes

- `Show-StartupArt` now calls `kernel32!SetConsoleOutputCP(65001)` and `SetConsoleCP(65001)` directly via P/Invoke right before drawing, plus re-asserts `[Console]::OutputEncoding = UTF-8`. Idempotent and reliable regardless of how the parent process was launched.
- Reverted the v2.5.1-rc per-row palette rotation. Each splash invocation again picks one random palette from the constrained six-theme set and uses it across all 6 BBS rows.

### Compatibility

- No parameter or schema changes. Drop-in replacement for v2.5.0.

---

## v2.5.0 (2026-05-02)

**Major feature release.** Concurrency safety, BitLocker support, parallelized cohort, four new update phases, extension-hook system, self-update, and remote configuration. All 25 open issues from the 2026-05 code review closed across seven coordinated phases. State schema v2 → v3 with automatic migration; all changes backwards-compatible.

### New features

- **Named-mutex concurrency guard** (`Global\BootUpdateCycle`). A duplicate orchestrator instance now logs and exits cleanly instead of racing on `$state.Iteration` and `shutdown.exe`. `AbandonedMutexException` from a crashed prior owner is recovered.
- **BitLocker suspend across reboot.** New `Suspend-BitLockerForReboot` runs `Suspend-BitLocker -RebootCount 1` (with `manage-bde.exe` fallback) immediately before `shutdown.exe /r`. Eliminates the recovery-prompt stall on protected machines. New `-SkipBitLocker` switch.
- **Parallel cohort.** Pip, Npm, Scoop, DotnetTools, and Vscode now run concurrently via `Start-ThreadJob`. ~30-40% wall-clock savings on the user-package phase.
- **Parallel Winget scopes.** `--scope user` and `--scope machine` run concurrently in user context (sequential fallback under SYSTEM and when `ExcludePatterns` is active).
- **Defender signature update phase** (default ON, `-SkipDefender` to disable). Runs after Windows Update.
- **Driver/firmware update phase** (opt-in, `-IncludeDriverUpdates` / `-IncludeFirmwareUpdates`). Honors regex-escaped `ExcludePatterns`.
- **WSL kernel + distro phase** (opt-in, `-UpdateWsl`). Runs `wsl --update` plus per-distro apt/dnf/pacman. SYSTEM-context skipped.
- **Container image refresh + prune** (opt-in, `-UpdateContainers`). Detects Docker or Podman, pulls all non-`<none>` images unique-deduped, then `system prune -f`. SYSTEM-context skipped.
- **Metered connection detection.** WinRT `GetConnectionCost` with CIM fallback. Aborts cleanly via `exit 0` (not the error path) unless `-AllowMetered` is set.
- **Pre-flight network cache.** DNS + TCP probes cached in state for 5 minutes. Saves ~5-10s per iteration on slow networks. Cleared on reboot.
- **Cycle-level hooks.** New `-PreCycleScript` / `-PostCycleScript` parameters dot-source user .ps1 files at cycle entry and at successful-completion / max-iterations paths.
- **Per-phase hooks via `hooks.psd1`.** Sidecar file with 30 named scriptblocks (Before/After x 15 phases). Loaded at script start; failures are logged and never crash the cycle.
- **Self-update from GitHub releases** (default ON, `-DisableSelfUpdate` to disable). User-context only. Checks the `latest` release, validates the downloaded asset parses, optionally verifies SHA256 from a sibling asset or release body, atomically replaces the live script, and re-execs with the original parameters.
- **Remote configuration URL.** New `-ConfigUrl` parameter pulls a JSON config; supported keys override `$script:*` defaults only when the user did not pass them on the command line. Successful fetches are cached at `ProgramData\BootUpdateCycle\remote-config.cache.json`.

### Bug fixes

- `$SkipDotnetTools` now defaults to `$true` (matches documented OFF default; was running by accident).
- `shutdown.exe /c` comment is quoted (PS7.0-7.2 Legacy native-arg passing).
- pip per-package upgrade quotes the package name and applies `ExcludePatterns`.
- Windows Update `NotTitle` regex-escapes user-supplied `ExcludePatterns` (no more silent over-exclusion or parse errors).
- `Set-BootUpdateState` clears stale `.tmp` from a prior failed write and surfaces `Move-Item` failures via the logger.
- `Save-CycleHistory` writes atomically and tolerates a corrupted/empty history file (try/catch around `ConvertFrom-Json`).
- `$state.Iteration++` and the state write now happen AFTER the maintenance-window gate — narrow windows no longer burn iteration slots on misses.
- `Register-BootUpdateTaskForReboot` no longer early-returns when the task already exists; `Register-ScheduledTask -Force` always rewrites the action with the current arguments.
- `Update-BootUpdateStateSchema` warns and backs up state files written by a future schema version (`<path>.future-vN.bak`).
- `Repair-AwsTooling.ps1` passes its multi-line scriptblock to `pwsh.exe` via `-EncodedCommand` (newlines no longer drop across `CreateProcess`).
- `Send-MailMessage -AsJob` is awaited with a 30-second timeout, errors logged, and the job removed (no more job-object leak / silent SMTP failures).

### State schema

- Bumped v2 → v3. Adds `DefenderDone`, `DriverFirmwareDone`, `WslDone`, `ContainersDone`, `LastPreflightNetworkOk`, `LastPreflightNetworkAt`. Migration is automatic and idempotent.
- Forward-compat guard added: a state file at `v > $script:BootUpdateStateSchemaVersion` is backed up to `<path>.future-vN.bak` before the script proceeds.

### Compatibility

- New optional parameters; no removals or renames.
- `$SkipDotnetTools` default flipped from running → skipped, restoring documented behavior.
- All existing call sites and scheduled-task arg propagations updated.

---

## v2.4.0 (2026-04-25)

**Performance:** PowerShell module updates now run in parallel via `ForEach-Object -Parallel`.

- **PSResourceGet path** (PS 7.4+ / PSResourceGet installed): bulk `Update-PSResource` runs N modules concurrently inside the existing child job.
- **Legacy path** (PS 7.0-7.3): per-module `Update-Module` calls also run in parallel inside one child job (was sequential).
- Throttle limit: `min(8, max(2, ProcessorCount))` — caps concurrency to avoid repository contention and resource exhaustion.
- Same structured output format (`UPDATED|name|old|new`, `ERROR|name|msg`); same hard timeout via `PackageTimeoutMinutes`.

Expected: 3-5× faster module phase on machines with many installed modules.

---

## v2.3.4 (2026-04-25)

**Fix:** BBS splash rendered as blank when launched via `upd.cmd` — Unicode block-drawing chars stripped by inherited CP437/CP1252 console encoding.

- Forces UTF-8 console I/O on script start (`[Console]::OutputEncoding` + `chcp 65001`) so block/box-drawing chars (U+2588, U+2557, U+2550, etc.) survive the cmd.exe → pwsh handoff

---

## v2.3.3 (2026-04-25)

**UX:** BBS-style startup splash (`Show-StartupArt`) now renders on every iteration instead of only the first. Visible on every `upd.cmd` invocation and on post-reboot SYSTEM task runs.

---

## v2.3.2 (2026-04-25)

**Fix:** Banner version was hardcoded as `v2.1` in three places. Extracted to `$script:BootUpdateCycleVersion` variable — single source of truth for all version displays.

---

## v2.3.1 (2026-04-25)

**Enhancement:** Comprehensive pending reboot detection based on Boxstarter/Brian Wilhite's `Get-PendingReboot`.

| Check | Before | After |
|-------|--------|-------|
| CBS RebootPending | Property lookup | Subkey existence (`Test-Path`) |
| WU RebootRequired | Property lookup | Subkey existence (`Test-Path`) |
| PendingFileRenameOperations | Property exists | Verify entries count > 0 |
| Netlogon JoinDomain | Property only | `JoinDomain` OR `AvoidSpnSet` |
| SCCM CCM_ClientUtilities | Not checked | Added (WMI, graceful skip if no SCCM client) |

---

## v2.3.0 (2026-04-25)

**Major:** Migrate PowerShell module updates from sequential `Update-Module` to bulk `Update-PSResource` (PSResourceGet).

- **Primary path** (PS 7.4+ / PSResourceGet installed): single `Start-Job` runs `Update-PSResource` for all modules in one child process. ~2x faster, C#-native, no PackageManagement dependency conflicts.
- **Legacy fallback** (PS 7.0-7.3): existing per-module `Update-Module` via `Start-Job` preserved.
- Child process avoids module-in-use file locks.
- Structured output parsing (`UPDATED|name|old|new`, `ERROR|name|msg`).

---

## v2.2.1 (2026-04-25)

**Fixes:**
- **AWS.Tools.* stale repository** — all AWS.Tools modules failed with `Unable to find repository` error. Now uses `Update-AWSToolsModule -CleanUp` instead of generic `Update-Module`.
- **Az meta-module timeout** — `Az` wrapper (80+ sub-modules) exceeded 5-minute timeout. Excluded from generic loop; sub-modules update individually.
- **PackageManagement noise** — filtered `module is currently in use` warning from logs.

---

## v2.2.0 (2026-04-25)

**Major:** Resolves all remaining open issues (7 bugs + 4 enhancements) via 4 parallel agents.

### Bugs Fixed

| Issue | Description |
|-------|-------------|
| #2 | pip JSON parsing breaks on single outdated package (wrapped in `@()`) |
| #3 | Crash recovery treats unknown phase names as crashes (now warns and ignores) |
| #4 | `$LASTEXITCODE` stale value — webhook uses `-ErrorAction Stop` |
| #5 | Module update job failures not detected (State checked before `Remove-Job`) |
| #6 | `Repair-AwsTooling` cmd.exe injection — uses `msiexec.exe` directly, non-MSI skipped |
| #16 | ExcludePatterns with special chars break task args (single quotes escaped) |
| #19 | `Stop-Job` leaves orphan pwsh.exe (child process killed via `ProcessId`) |

### Enhancements

| Issue | Description |
|-------|-------------|
| #17 | WebhookUrl validated with `[ValidateScript]` (must be `http`/`https` or empty) |
| #18 | SMTP auth via `[pscredential]$SmtpCredential` parameter |
| #20 | Webhook retry with exponential backoff (3 attempts, 2s/4s delays) |
| #21 | ASCII art splash picks random neon palette from 6 curated schemes |

---

## v2.1.4 (2026-04-25)

**Fixes from full codebase review:**
- Deploy: `SkipHealthCheck`, `MaintenanceWindowStart`, `MaintenanceWindowEnd` now forwarded to scheduled task args (were silently dropped after reboot)
- ExcludePatterns uses `.IndexOf()` instead of `-like` (no wildcard bugs with `[]`, `?`, `*`)
- `Show-BootUpdateHistory`: empty JSON array `[]` handled gracefully
- `[ValidateRange(-1, 23)]` added to `MaintenanceWindowStart`/`MaintenanceWindowEnd`

---

## v2.1.3 (2026-04-25)

**Fix:** Filter `System.__ComObject` noise from Windows Update log output. PSWindowsUpdate emits COM objects whose `.ToString()` renders as the type name.

---

## v2.1.2 (2026-04-25)

**Fix:** Banner version strings updated from `v2.0` to `v2.1` (ASCII splash, normal banner, WhatIf banner).

---

## v2.1.1 (2026-04-25)

**Fix:** Windows Update `-NotTitle` parameter type error. Parameter is `[String]`, not `[String[]]` — joined ExcludePatterns array with `|` to produce regex alternation string.

---

## v2.1 (2026-04-25)

**Major release** adding 8 features across three capability areas:

### Observability
- **Webhook & Email Notifications** — Teams/Slack/Discord auto-detection, dual notifications (completion + reboot warning), proxy support, async email
- **Trend Visualization** (`Show-BootUpdateHistory.ps1`) — Table/Graph/JSON output, ASCII bar charts with ANSI colors, read-only (no elevation)
- **Post-Update Health Check** — validates W32Time, WinDefend, Dnscache, Spooler, EventLog; service recovery; state tracking

### Safety & Control
- **Exclude Patterns** — skip packages by substring match across Winget, Chocolatey, Windows Update
- **Maintenance Window** — hour-based scheduling with midnight-crossing support; defers (doesn't fail)
- **Staged Rollout** — one package manager per boot; state persistence; isolated failure domains

### Quality of Life
- **WhatIf/Dry-Run Mode** — `ShouldProcess` guards on all external calls; zero side effects
- **System Restore Point** — opt-in snapshot before first iteration; SYSTEM/Server SKU tolerant

**Defaults:** All features disabled by default except health check. 100% backward compatible with v2.0.

---

## v2.0 (2026-04-25)

**Initial release.** Full-featured boot-time update orchestrator:

- 11 package manager phases (Winget, Chocolatey, Windows Update, pip, npm, Office 365, PowerShell modules, Scoop, dotnet tools, VS Code extensions, AWS tooling)
- Pre-flight checks (disk, network, battery, conflicts, WU service)
- Smart idle-aware timeouts with process tree monitoring
- Crash recovery with atomic state writes
- State schema versioning with auto-migration
- Log rotation, history tracking, toast notifications, event logging
- DirectFirstRun mode for user-scope Winget access
- Self-destructing scheduled task on completion

---

## Configuration

```powershell
$Config = @{
    # Safety & Control
    SkipRestorePoint         = $true      # Set $false to enable restore point
    SkipHealthCheck          = $false     # Health check on by default
    StagedRollout            = $false     # One manager per boot
    ExcludePatterns          = @()        # Skip packages by substring
    MaintenanceWindowStart   = -1         # Hour (0-23), -1 = no restriction
    MaintenanceWindowEnd     = -1         # Hour (0-23), -1 = no restriction

    # Notifications
    WebhookUrl               = ''         # Teams/Slack/Discord webhook
    NotifyEmail              = ''         # Email recipient
    SmtpServer               = ''         # SMTP relay
    # SmtpCredential         = (Get-Credential)  # Optional SMTP auth

    # Core
    RebootDelaySec           = 0          # Immediate forced reboot
    MaxIterations            = 5          # Safety valve
    PackageTimeoutMin        = 30         # Hard timeout per manager
}
```

---

## Getting Help

```powershell
# Monitor running cycle
Get-Content "$env:ProgramData\BootUpdateCycle\BootUpdateCycle.log" -Tail 50 -Wait

# View cycle history
Get-Content "$env:ProgramData\BootUpdateCycle\BootUpdateCycle.history.json" | ConvertFrom-Json

# Event log
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='BootUpdateCycle'}

# Trend visualization
.\Show-BootUpdateHistory.ps1 -Format Graph

# Preview without changes
.\Invoke-BootUpdateCycle.ps1 -WhatIf -Force

# Uninstall
& "$env:ProgramData\BootUpdateCycle\Uninstall.ps1"
```

---

## License

MIT - See LICENSE file

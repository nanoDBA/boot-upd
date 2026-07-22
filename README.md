# Boot Update Cycle

**Run `upd` as admin. Walk away. Come back patched—or with a clear, reversible explanation of which installer chose violence.**

A reboot-resilient Windows updater that runs the configured package managers, checkpoints real
progress, restarts when required, and resumes only the unfinished work until the selected scope
verifies clean. Then it removes its continuation tasks, because leaving mysterious scheduled tasks
behind is how software becomes folklore.

[![Latest release](https://img.shields.io/github/v/release/nanoDBA/boot-upd?display_name=tag&sort=semver)](https://github.com/nanoDBA/boot-upd/releases/latest)
[![PowerShell 7+](https://img.shields.io/badge/PowerShell-7%2B-5391FE?logo=powershell&logoColor=white)](#requirements)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

<img src="docs/img/splash-theme0.png" alt="Boot Update Cycle splash — neon gradient theme" width="684">

<a id="navigate"></a>
## 🧭 Navigate

- [Quick start](#quick-start)
- [Which command do I want?](#which-command-do-i-want)
- [See it in action](#updater-in-action)
- [What it updates](#what-it-updates)
- [Commands](#friendly-launcher)
- [How reboot/resume works](#what-happens)
- [Status and recovery](#status-and-recovery)
- [Common questions](#common-questions)
- [Security model](#security-model)
- [Configuration](#configuration) · [Testing](#testing)

<a id="quick-start"></a>
## 🚀 Quick start

Open **Windows PowerShell as Administrator**, paste this command, and press Enter. Yes,
PowerShell—not Command Prompt wearing a PowerShell command as a hat:

```powershell
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; & ([ScriptBlock]::Create((Invoke-RestMethod -UseBasicParsing -TimeoutSec 30 'https://github.com/nanoDBA/boot-upd/releases/latest/download/Install-UpdCompat.ps1'))) -PromptForArguments
```

After the compatibility installer starts, it verifies every runtime asset against the
release bundle's SHA256 sidecars before installing the runtime bundle. At the
prompt, press Enter to use the defaults. After installation, everyday use is deliberately
short:

```powershell
upd          # update, reboot when required, and resume automatically
upd status   # show the current checkpoint and continuation tasks
upd logs     # create a sanitized support ZIP on the Desktop
upd help     # commands, short aliases, and every option
```

### Which command do I want?

| Goal | Run | What you are authorizing |
|---|---|---|
| Patch normally | `upd` | Default providers, immediate restart when required |
| Give me a warning | `upd -r 120` | Same run, with 120 seconds to remember where you left that unsaved document |
| Show the plan first | `upd plan -drv -r 120` | Resolve options only; no elevation, installs, tasks, or reboots |
| Be more forceful with Winget | `upd -ar` | One bounded repair attempt, then reversible quarantine instead of an eternal loop |
| Update AWS tooling | `upd aws` | AWS CLI v2 and modular AWS.Tools; AWS gets its own side quest because of course it does |
| Tell me what is happening | `upd status` | Read the checkpoint, continuation tasks, and Winget quarantine records |
| Package evidence for support | `upd logs` | Create a sanitized ZIP and copy its full path to the clipboard |
| Just admire the pixels | `upd fun 12` | Splash parade and live animation; absolutely no useful work, proudly |

> [!IMPORTANT]
> `upd` installs software and can restart Windows immediately by default. Save your work
> first, or use `upd -r 120` for a two-minute reboot warning. Cancel a pending restart with
> `shutdown /a`.

Want to look around without changing the machine? These commands are read-only and do not
request elevation. Suspicion is healthy; production has taught us all things.

```powershell
upd splash
upd demo 12
upd plan -drv -r 120
upd version
```

**Trust boundary:** the one-liner trusts GitHub HTTPS and this project's latest release;
the downloaded compatibility installer then requires a valid SHA256 sidecar for every
runtime asset. Checksums protect integrity but are not publisher signatures. See
[Security model](#security-model) and the [version-pinned recovery path](#install-details-and-compatibility)
before using it in a controlled environment.

The BBS-style splash defaults to the neon gradient theme above; two more ship with it (`upd splash` previews them all; switch with `BOOT_UPDATE_SPLASH_THEME=0|1|2`):

<details>
<summary>The other two themes</summary>

<img src="docs/img/splash-theme1.png" alt="Boot Update Cycle outline dither theme" width="684">

<img src="docs/img/splash-theme2.png" alt="Boot Update Cycle classic 16-color theme" width="684">

</details>

## Updater in action

The default `Normal` view stays zoomed out while the animated `BOOT//PULSE` row shows the current operation:

<img src="docs/img/updater-progress.png" alt="Boot Update Cycle resumed after reboot, reusing a verified Windows Update assessment and refreshing Defender in the compact Normal console view" width="900">

The splash immediately marks restart status as **checking**. Before updates begin—and again after they finish—the Normal view displays a prominent **RESTART REQUIRED** or **RESTART NOT REQUIRED** result. If a restart is required, the screen also confirms that automatic continuation is armed.

When the configured work, restart checks, service assessment, and terminal cleanup all pass, the final screen leads with a plain-language result: the run finished, whether a restart is needed, whether any packages were skipped, and what (if anything) the user should do next. It still has some earned personality:

<img src="docs/img/updater-complete.png" alt="Boot Update Cycle configured patch pass verified completion screen" width="900">

<sub>Representative v2.5.62 console captures rendered from current production wording for deterministic, privacy-safe documentation; package counts and elapsed time are illustrative.</sub>

## What it updates

| Phase | Package Manager | Default | Notes |
|-------|----------------|---------|-------|
| 1 | **Winget** | On | User + machine scope; ARSO resumes user scope after reboot, with a delayed SYSTEM safety net |
| 2 | **Chocolatey** | On | `choco upgrade all -y` |
| 3 | **Windows Update** | On | Security, Critical, Definition updates (excludes SQL Server) |
| 4 | **AWS Tooling** | Off | Optional CLI v2 + AWS.Tools repair |
| 5 | **pip** | On | All outdated global packages |
| 6 | **npm** | On | All global packages |
| 7 | **Office 365** | On | Click-to-Run silent update |
| 8 | **PowerShell Modules** | On | Installed modules via PSResourceGet when available, with compatible fallback behavior |
| 9 | **Scoop** | On | User-scoped; skipped under SYSTEM |
| 10 | **.NET Global Tools** | **Off** | High risk — can break SDK-dependent builds |
| 11 | **VS Code Extensions** | On | User-scoped; skipped under SYSTEM |
| 12 | **Microsoft Defender** | On | Signature refresh through `MpCmdRun.exe` |
| 13 | **Drivers / firmware** | **Off** | Explicit opt-in with `-drv` / `-fw` |
| 14 | **WSL / containers** | **Off** | Explicit opt-in; user-context work resumes at logon |

## Install details and compatibility

The [quick-start command](#quick-start) is the shortest supported fresh-install,
repair, and run path from an elevated Windows PowerShell session.

If you prefer the downloaded bootstrap to remain visible in `%TEMP%` for inspection or
troubleshooting, use the equivalent download-and-run form:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing 'https://github.com/nanoDBA/boot-upd/releases/latest/download/Install-UpdCompat.ps1' -OutFile ([IO.Path]::Combine([IO.Path]::GetTempPath(),'Install-UpdCompat.ps1')); & ([IO.Path]::Combine([IO.Path]::GetTempPath(),'Install-UpdCompat.ps1')) -CommandArguments run"
```

The short form verifies and installs the complete bundle first, then prompts for an `upd`
command and options; press Enter to run with defaults. To automate it, replace
`-PromptForArguments` with an explicit array such as
`-CommandArguments @('run','--drivers','--delay','120')`.

Both convenience commands trust GitHub HTTPS and the repository's current latest release.
The downloaded installer then verifies every runtime asset against its published SHA256
sidecar and installs to `Program Files\BootUpdateCycle`, or transactionally repairs the
existing `upd.cmd` PATH winner. For a version-and-hash-pinned bootstrap, use the stricter
compatibility command below.

Already installed:

```
upd
```

That's it. Once installed, `upd` runs from an elevated Command Prompt, PowerShell, or the
Run dialog (Win+R → `upd` → Ctrl+Shift+Enter). The installer is PowerShell; the installed
launcher is the part that works everywhere. Tiny distinction, surprisingly large number of error messages.

`upd.cmd` auto-adds itself to your system PATH on first run, so it works from anywhere after that.

### Friendly launcher

The launcher accepts both commands and typed run options. Help, previews, planning,
version, and status do not request elevation; only `run` starts the UAC-protected updater.

```text
upd help                         Full command and option reference
upd /?                           Same help (also ?, /help, -h, --help, usage)
upd splash                       Preview all splash themes; no updates
upd demo 12                      Run the production BOOT//PULSE animation for 12 seconds
upd fun 12                       Splash parade followed by the animation
upd update                       Refresh the checksummed launcher bundle and exit
upd aws                          Update/repair AWS CLI v2 and AWS.Tools
upd logs                         Export a sanitized diagnostic ZIP to the Desktop
upd repair                       Recover missing/corrupt launcher and core files
upd bootstrap                    Install/verify PowerShell 7, then show help
upd version                      Show the bundled version
upd status                       Show resume tasks and checkpoint state
upd uq                           Remove every recorded Winget quarantine pin
upd uq Corsair.iCUE.5            Remove one quarantine pin and reconcile its record
upd plan --drivers --delay 120   Resolve options without elevation or changes

upd                              Run with defaults
upd 120                          Legacy shorthand: run with a 120-second reboot warning
upd --delay 120 --drivers --firmware
upd --staged --output-mode Verbose
upd --wsl --containers --allow-metered
upd -ar                          Opt in to aggressive Winget repair/reinstall attempts
upd --exclude Teams,OneDrive --skip-office365
```

Short forms keep everyday commands light: `upd d 12`, `upd f`, `upd p -drv -r 120`,
`upd r -s -o Verbose`, `upd a`, `upd l`, `upd u`, and `upd v`. Short commands do not use a
leading dash; ambiguous dashed forms fail before they can reach the update path. Long
names remain available for scripts and discoverability. `upd help` knows all of them, has
no feelings about your typing speed, and is more current than a copied command from six releases ago.

A stable raw-argument bootstrap now checks the latest GitHub release before an operational
command reaches the typed parser. Every executable
asset must have a valid SHA256 sidecar or the refresh is rejected. These checksums detect
corruption but are not code-signing signatures. PowerShell files are
verified and installed first; `upd.cmd` is staged as `upd.cmd.next` and adopted only after
the current PowerShell launcher exits, after a second checksum and version check. The
requested arguments are dispatched through the newly installed typed launcher rather than
the stale in-memory copy. Use `upd u` to request the refresh explicitly or `-nu` to skip the
automatic check for one run. `upd repair` can bootstrap a missing launcher and repair a
missing or corrupt core bundle.

An already-running historical batch cannot benefit from code it has not downloaded: some
pre-v2.5.29 launchers parse the first token as a reboot delay before self-update is reachable.
For those installations, run this version-pinned compatibility bridge **after the old batch
has exited**. It verifies the installer against the hash embedded below, then the installer
verifies and transactionally replaces the complete release bundle before forwarding `aws`:

```powershell
$u='https://github.com/nanoDBA/boot-upd/releases/download/v2.5.65/Install-UpdCompat.ps1'; $f=Join-Path $env:TEMP 'Install-UpdCompat-v2.5.65.ps1'; Invoke-WebRequest $u -OutFile $f; if((Get-FileHash $f -Algorithm SHA256).Hash -ne '67662B3B02252FF6DE045FCDF28FB74D8DEB6FDA8080C46B1DAFC7BFBE54ABE3'){throw 'Compatibility installer hash mismatch'}; & $f -CommandArguments aws
```

This is the one-time chicken-and-egg escape hatch. It resolves the first `upd.cmd` on PATH,
stages outside cloud storage, preserves a rollback snapshot, detects sync races, and replaces
only runtime files. It deliberately does not use a mutable gist or `iex`.

Windows PowerShell 5.1 is supported as a bootstrap host. On an operational command,
`upd.cmd` installs PowerShell 7 side-by-side using WinGet when available, or a
Microsoft Authenticode-validated MSI on older Windows Server systems, then relaunches
the PS7 updater. Help and version remain read-only; preview/plan/status commands ask
the user to run `upd bootstrap` rather than silently installing anything. The updater
itself remains PowerShell 7-only so `Start-ThreadJob` and `ForEach-Object -Parallel`
execution are preserved.

Run `upd help` for the complete list, including provider opt-ins, skip switches,
timeouts, iteration limits, health/BitLocker controls, include/exclude filters, and
self-update control. `demo`, `fun`, and `splash` never deploy files, register tasks,
update packages, or reboot Windows.

### Console views

Interactive runs use a compact progress view by default: current phase, overall progress,
phase results, warnings, and errors. The complete timestamped detail stream still goes to
`BootUpdateCycle.log`. Raw Winget and Chocolatey output is retained separately in
`BootUpdateCycle.providers.log` for troubleshooting without overwhelming the normal run log.
Standalone `upd aws` output is captured in `BootUpdateCycle.aws.log`. These logs rotate
independently (three archives, 5 MB for core/AWS and 10 MB for provider detail) and the
active and archived files receive NTFS compression when the volume supports it.

Run `upd logs` (or `upd l`) to create a compressed diagnostic ZIP on the Desktop. The
export includes all three log streams and fails closed if its identity, network, or path
redaction checks detect material that should not leave the machine. Its single absolute
ZIP path is displayed and copied to the Windows clipboard for easy attachment.

Because AWS maintenance is opt-in, `upd aws` fully modernizes the requested tooling by
default: it verifies the current Amazon-signed modular modules, then removes validated
older modular versions and legacy `AWSPowerShell*` version directories. Use
`upd aws --keep-aws-legacy --keep-aws-old` only when compatibility requires preserving them.

Press `v` at any time during an interactive run to cycle through:

| Mode | Console output |
|---|---|
| `Quiet` | Errors and final/reboot status only |
| `Normal` | The themed splash, progress, phase results, warnings, and errors (default) |
| `Verbose` | Normal plus detailed package-manager output |
| `Debug` | Verbose plus process IDs and heartbeat diagnostics |

Choose the initial view explicitly with `-OutputMode Quiet|Normal|Verbose|Debug`, or set
`OutputMode` in `Deploy-BootUpdateCycle.ps1`. The interactive `BOOT//PULSE` row uses a
classic `| / - \` ASCII propeller with a 112-step, seven-stop theme-zero glow. Cyan, blue,
magenta, acid green, and electric yellow-green flow through near-black violet and cyan valleys,
making the pulse discernible at a distance without abrupt flashes. Motion and color advance independently.
The row adapts instead of blindly chopping off its tail: at narrower widths it keeps the operation,
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

### What happens

1. Pre-flight checks visibly report their current check and elapsed time while validating disk space, network, battery, and conflicting installers. They observe—but never start—the Windows Update service
2. First iteration runs in **your** console (user context) — the only chance for user-scoped winget/Scoop/VS Code
3. Before mutation, two reboot-signal probes span a 20-second servicing-settle window. CBS, Windows Update Agent, real file replacements, protected Windows-file deletes, and provider-native reboot results are hard barriers; delete-only application/cloud/temp housekeeping is reported as an advisory
4. Native `3010`/`1641`, Chocolatey `350`/`1604`, and `Microsoft.Update.SystemInfo.RebootRequired` results are persisted immediately instead of waiting for registry flags to appear
5. Verified resume tasks are armed before updates start: user-at-logon plus a delayed SYSTEM fallback, with dated watchdogs for canceled shutdowns and deferred retries
6. `shutdown /g` restarts Windows; the checkpoint resumes automatically, preserves successful provider phases, preserves user-only work for user context, and retries only incomplete or interrupted work
7. Windows Update owns its service recovery: start and component-reset attempts are isolated behind a 30-second boundary. A stuck or indefinitely `StartPending` service makes only that phase retryable while safe independent providers continue
8. A successful online Windows Update assessment is reusable for six hours—even across reboots—only after an offline WUA catalog check confirms zero applicable work and the update source, scope, and recent servicing history fingerprints still match
9. Completion requires every enabled phase, a zero-applicable Windows Update assessment, and two probes with no blocking reboot evidence (max 5 completed reboot safety valve). Optional third-party cleanup cannot create a reboot loop; routine categories are compact in Verbose, fingerprints are reserved for Debug and the log, and Normal remains focused on actionable state
10. Hooks run, resume tasks and transient state are removed and verified absent, and only then does the final screen congratulate the user and send a result-specific notification
11. If explicit aggressive mode quarantined a persistent Winget failure, its durable record survives cleanup and the final screen reports degraded completion with an `upd uq` reversal command

Notifications distinguish four outcomes instead of using one generic toast: updates complete with no restart,
another pass scheduled with no restart, user-context work waiting for sign-in, and restart required with automatic
continuation. They are shown only in an interactive user session; SYSTEM resume work never attempts a desktop toast.

### Reliability lineage

The reboot design intentionally borrows proven boundaries instead of treating every registry
artifact as equally authoritative:

- [Boxstarter](https://github.com/chocolatey-community/boxstarter) checkpoints around package work and recognizes provider-native reboot results rather than restarting an entire provisioning plan from zero.
- [Microsoft DSC](https://learn.microsoft.com/powershell/dsc/configurations/reboot-a-node) resumes dependency-ordered resources after reboot and makes pending-file-rename checks policy-selectable.
- [Ansible's Windows Update implementation](https://github.com/ansible-collections/ansible.windows/blob/main/plugins/modules/win_updates.ps1) uses the Windows Update Agent API and per-update results before and after installation.
- [PendingReboot](https://github.com/bcwilhite/PendingReboot) explicitly supports excluding pending-file-renames because antivirus and other background products commonly create false positives.
- [Microsoft's `MoveFileEx` contract](https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-movefileexa) distinguishes a blank-destination delete from a source/destination replacement; boot-upd keeps replacements blocking while treating non-system housekeeping as advisory.
- [Chocolatey's documented exit codes](https://docs.chocolatey.org/en-us/choco/commands/install/#exit-codes) distinguish successful reboot requests (`1641`, `3010`) from reboot barriers that leave work incomplete (`350`, `1604`).

### Reboot delay

```
upd        # immediate reboot (0 sec delay)
upd 120    # 2-minute countdown — users can cancel with: shutdown /a
```

## Requirements

- **Windows 10/11**
- **PowerShell 7+ runtime** (`upd.cmd` can install it side-by-side from Windows PowerShell 5.1)
- **Administrator privileges**

Package managers are auto-detected. Missing ones are skipped with a warning.

## Files

| File | Purpose |
|------|---------|
| `upd.cmd` | Entry point — run this |
| `tools/Invoke-UpdBootstrap.ps1` | Stable raw-argument preflight and verified current-launcher handoff |
| `tools/Invoke-UpdLauncher.ps1` | Typed commands, compact aliases, UAC boundary, and runtime-bundle updates |
| `tools/Install-UpdCompat.ps1` | One-time repair bridge for historical batch parsers |
| `tools/Install-PowerShell7.ps1` | Windows PowerShell 5.1-compatible PS7 bootstrap |
| `Deploy-BootUpdateCycle.ps1` | Deploys scripts to ProgramData + runs first iteration |
| `Invoke-BootUpdateCycle.ps1` | The orchestrator — runs all updates, manages reboots |
| `Register-BootUpdateTask.ps1` | Standalone task registration (alternative to Deploy) |
| `Unregister-BootUpdateTask.ps1` | Emergency stop — removes the scheduled task |
| `Repair-AwsTooling.ps1` | Optional AWS CLI v2 + module maintenance |
| `Export-BootUpdateDiagnostics.ps1` | Sanitized, compressed diagnostic bundle export |
| `tools/Initialize-BootUpdateWebhook.ps1` | Securely configures a notification webhook outside Git and task arguments |

<a id="status-and-recovery"></a>
## 🛟 Status and recovery

Start with the built-in commands; they keep the common support path short and preserve
useful evidence. Copying a 4,000-line console screenshot into chat is technically evidence,
in the same sense that a landfill is technically a filing system:

```powershell
upd status    # checkpoint, resume tasks, and reversible Winget quarantines
upd logs      # sanitized compressed diagnostics on the Desktop
upd repair    # restore checksummed launcher/core files
upd update    # refresh the verified source bundle without starting an update cycle
```

### What the final result means

| Result | Meaning | What you should do |
|---|---|---|
| **Updates complete — no restart required** | Every enabled phase and verification check passed | Enjoy the rare moment when Windows has no further requests |
| **Updates complete** with skipped packages | Repeated Winget failures were reversibly pinned to prevent another loop | Nothing now; use the displayed `upd uq` command when you want to retry them |
| **Recovery pass queued** | One or more phases did not verify; a near-term retry is armed | No action unless it keeps returning or reaches the safety limit |
| **User update pass pending** | Machine work finished, but user-scoped work needs the saved user to sign in | Sign in as that user; do not "fix" it by deleting the checkpoint |
| **Restart required** | Blocking evidence was confirmed and continuation was verified | Save work; boot-upd resumes automatically after Windows restarts |
| **Needs attention** | A bounded safety limit or terminal failure stopped automation | Run `upd status`, then `upd logs`; the tool stopped rather than improvising on your operating system |

If explicit `-ar` mode quarantines a repeatedly failing Winget package, the final screen says
the selected update run finished **with skipped packages**—not that the machine is fully patched.
The durable status record includes the reversal command:

```powershell
upd uq Package.Id    # remove one blocking pin
upd uq               # remove all recorded blocking pins
```

Records are removed only after Winget confirms that the corresponding pin was removed.

When Winget reports MSI error `1605`, the application is already absent but Windows still has
incomplete uninstall inventory. boot-upd does not count that as an update, fail the phase, or queue
another pass. It immediately displays three choices:

```powershell
# The application is wanted: reconstruct its installation
winget install --id Package.Id -e --source winget --force --accept-source-agreements --accept-package-agreements

# Temporary, reversible silence while leaving the stale inventory untouched
winget pin add --id Package.Id -e --blocking --force
```

If removal was intentional, use [Microsoft's Program Install and Uninstall troubleshooter](https://support.microsoft.com/en-us/windows/deployment/install-upgrade/fix-problems-that-block-programs-from-being-installed-or-removed)
to clean corrupt registry keys or incomplete uninstall data. A blocking pin suppresses the symptom;
the troubleshooter addresses the stale Windows inventory.

### More monitoring

```powershell
# Live log tail
Get-Content "$env:ProgramData\BootUpdateCycle\BootUpdateCycle.log" -Tail 50 -Wait

# Unabridged package-manager transcript
Get-Content "$env:ProgramData\BootUpdateCycle\BootUpdateCycle.providers.log" -Tail 100 -Wait

# Sanitized support bundle on the Desktop (short form: upd l)
upd logs

# Cycle history (last 50 runs with package counts)
Get-Content "$env:ProgramData\BootUpdateCycle\BootUpdateCycle.history.json" | ConvertFrom-Json

# Windows Event Log
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='BootUpdateCycle'} | Select-Object -First 10
```

### Emergency stop

```powershell
# Cancel a pending reboot
shutdown /a

# Remove both continuation tasks (stops automatic resume without deleting logs)
Get-ScheduledTask -TaskName 'BootUpdateCycle','BootUpdateCycleFallback' -ErrorAction SilentlyContinue |
    Unregister-ScheduledTask -Confirm:$false

# Full cleanup
& "$env:ProgramData\BootUpdateCycle\Uninstall.ps1" -RemoveFolder
```

Canceling `shutdown` does not mean the update checkpoint has forgotten why it wanted a reboot.
That would be convenient, but it would also be lying.

<a id="common-questions"></a>
## 🙋 Common questions

### Is `ChocolateyPrototypeCleanup` a problem?

Usually, no. It means Windows has delete-only housekeeping for Chocolatey's temporary prototype
directory. It does **not** block convergence or consume the reboot budget. Since v2.5.62 it stays
out of Normal warnings: Verbose shows a compact category/count, while Debug and the durable log
retain sanitized fingerprints. A real source/destination replacement is still blocking.

### Why did it restart more than once?

Some updates reveal more applicable work only after reboot. boot-upd preserves completed phases,
increments the reboot count only after observing a new Windows boot session, and resumes the
unfinished work. It is a checkpointed update cycle, not `while ($true) { reboot }` with branding.

### Why is Windows Update being checked again?

A clean online assessment can be reused for up to six hours across reboots only when the local
Windows Update catalog, configured scope, update source, and servicing-history fingerprints still
agree. If one changes, boot-upd asks Windows again. Cached confidence is useful; cached fiction is not.

### Why did a package get skipped?

Normal mode leaves ordinary pins and unsupported inventory visible but does not override them.
With explicit `upd -ar`, one repeated, identical Winget failure may receive a bounded repair attempt
and then a reversible blocking pin. Use `upd status` to see it and `upd uq Package.Id` to retry it.

### Does `upd aws` run during a normal `upd`?

No. AWS tooling is opt-in. `upd aws` explicitly modernizes AWS CLI v2 and modular AWS.Tools;
`upd --aws-tooling` includes that phase in the complete update cycle. Use the preservation flags
only when an older script genuinely depends on legacy modules, not because old versions look lonely.

### Can I see everything without the console becoming a novel?

Press `v` during a run to cycle Quiet → Normal → Verbose → Debug. Normal is designed for humans;
the rotating logs preserve the exhaustive details for humans who have become debuggers.

<a id="security-model"></a>
## 🔐 Security model

- Release self-update fails closed when an executable asset or valid SHA256 sidecar is
  missing, malformed, or mismatched.
- The running batch launcher is updated through a temporary trampoline so it never
  replaces the file that `cmd.exe` is actively reading.
- Scheduled continuation arguments contain configuration references, not webhook bearer
  credentials. Webhook secrets live in an administrator/SYSTEM-protected local file.
- Administrator hooks must remain under the protected deployed directory and pass path,
  ACL, reparse-point, and optional signature/hash checks before elevated execution.
- Diagnostic export redacts identities, network addresses, URLs, registry paths, and local
  paths, then verifies the sanitized output before creating the ZIP.
- Aggressive Winget repair is opt-in (`-ar`). An identical persistent failure can be moved
  to a reversible blocking pin, which is recorded outside transient checkpoint state and
  shown by `upd status`.

For the most conservative bootstrap, use the version-and-hash-pinned command in
[Install details and compatibility](#install-details-and-compatibility). Never commit real
webhook URLs or other credentials to this public repository. Report vulnerabilities through
GitHub's [private vulnerability reporting](https://github.com/nanoDBA/boot-upd/security/advisories/new); otherwise open a minimal public issue
without secrets or exploit details so a private channel can be arranged.

## Configuration

Edit the `$Config` block in `Deploy-BootUpdateCycle.ps1`:

```powershell
$Config = @{
    MaxIterations         = 5       # Maximum completed reboot cycles
    MaxRetryPasses        = 5       # Consecutive failed recovery passes per boot
    PackageTimeoutMin     = 30      # Hard timeout per package manager
    RebootDelaySec        = 120     # Countdown before reboot (0 = immediate)
    SkipPip               = $false
    SkipNpm               = $false
    SkipOffice365         = $false
    SkipAwsTooling        = $true   # Off by default
    SkipPowerShellModules = $false
    SkipScoop             = $false
    SkipDotnetTools       = $true   # Off by default — high risk
    SkipVscode            = $false
}
```

### Notification webhook

Never commit a Teams, Slack, or Discord webhook URL or place it in a scheduled-task
command line. Configure it once from an elevated PowerShell prompt; the tool prompts
without echo and stores the URL under ProgramData with access limited to SYSTEM and
local Administrators:

```powershell
./tools/Initialize-BootUpdateWebhook.ps1

# Remove it later
./tools/Initialize-BootUpdateWebhook.ps1 -Remove
```

The legacy `WebhookUrl` deployment setting remains as a one-time migration path. If
set, deployment immediately moves its value into the protected local file and clears
the in-memory configuration before registering a task. Do not save a real URL in a
tracked copy of `Deploy-BootUpdateCycle.ps1`.

### Extension-hook trust boundary

Pre-cycle, post-cycle, and `hooks.psd1` extensions must be located inside the deployed
BootUpdateCycle directory. The orchestrator rejects hooks outside that directory,
hooks reached through reparse points, and hooks whose file or parent directory grants
write access to Everyone, Authenticated Users, or the built-in Users group.

## Smart timeouts

Package managers get killed if they're truly stuck, but busy installs are left alone:

- **Idle timeout (5 min)**: If the entire process tree (winget + msiexec + setup.exe + children) has zero CPU activity for 5 minutes, it's stuck — kill it
- **Hard timeout (configurable)**: Absolute ceiling regardless of activity
- **Timed-out packages retry next boot** — not lost, just delayed

This means Visual Studio can install for 45 minutes (busy CPU = fine), but a hung winget source refresh gets killed in 5 minutes (zero CPU = stuck).

## Testing

Testing is split into explicit confidence gates rather than a single test count. See [Testing Boot Update Cycle](docs/TESTING.md), or run `./tools/Invoke-TestGates.ps1` from an elevated PowerShell 7 console.

## License

MIT

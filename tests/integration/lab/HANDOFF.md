# Reusing the lab without inheriting an agent's shell

Run from an elevated PowerShell 7 console at the repository root. Read
`docs/TESTING.md` for what each gate proves. These commands operate on disposable
guests; do not run the updater on the host. Run one guest at a time unless the
host has been explicitly sized for parallel rows.

On a host that blocks unsigned development scripts, launch that console with
`pwsh -NoProfile -ExecutionPolicy Bypass` (process scope only), then explicitly
change to the checkout directory. Do not change the machine execution policy.

## Find the machine-local setup

`tests/integration/lab/lab.local.json` is ignored by Git. It holds paths, guest and
checkpoint names, and a Credential Manager target name, never a password. The
adjacent `HANDOFF.local.md`, when present, records this machine's checkpoint
inventory and historical evidence. Neither file is copied to guests by the row
harness. Copy the tracked example configuration for a new machine; do not
overwrite an existing local configuration.
The template is `lab.local.example.json`.

```powershell
& ./tests/integration/lab/Test-LabReadiness.ps1 | ConvertTo-Json -Depth 6
```

This is read-only: it does not install modules, boot guests, restore checkpoints,
or rotate credentials. `-ProbeGuest` additionally tests authentication on already
running guests, with a bounded timeout. Authentication on an off guest is
**NOT RUN**. A credential existing in the store is not proof that it matches a
guest. A running guest is not ready for a cold restore; inspect its run first.

## Credentials: reuse by default

`LabCredential.ps1` uses BetterCredentials and Windows Credential Manager.
Agents under the same Windows account can retrieve the stored credential across
sessions. SYSTEM and other accounts must not assume they share that store.

For first-time setup only, initialize the target before building the answer ISO:

```powershell
. ./tests/integration/lab/LabCredential.ps1
Initialize-BootUpdLabCredential
& ./tests/integration/lab/New-UnattendIso.ps1
```

Initialization reuses an existing target or generates and stores one if missing;
it prints no secret. BetterCredentials is installed for the current user when
needed by setup. Existing guests need no initialization or password prompt.
`Set-BootUpdLabPassword` refuses replacement without `-Replace`. Replacement does
not change passwords inside existing guests or checkpoints. Never rotate a
credential to solve a failed login without first establishing which guests use it.
Clear a stale `BOOTUPD_LAB_PASSWORD` override when reusing stored credentials.

For teardown, shut down guests normally. Keep the credential while any guest or
checkpoint depends on it. Full retirement can remove it from Credential Manager
after those dependents are retired. Do not delete it at the end of each test row.
Unattended answer ISOs and guest autologon configuration contain the disposable
credential; keep those artifacts local, even though the guest is disposable.

## Run a repeatable row

The selected guest **and** checkpoint must be Off. The harness refuses running
guests, saved running-state checkpoints, and a competing row for the same VM.
It holds an OS file lease under `%ProgramData%/BootUpdateCycle-Lab/locks`, keyed by
VM ID, across restore, execution, and evidence collection. The lease records the
owner PID and evidence directory and is readable while held. Never delete a lock
file to bypass an active owner. Older runners and direct Hyper-V commands do not
participate in this lease; inspect those before reuse.

Read local configuration and select the guest explicitly:

```powershell
$config = Get-Content ./tests/integration/lab/lab.local.json -Raw | ConvertFrom-Json
$guest = $config.Guests[0]
$parameters = @{
    VMName = $guest.Name
    Checkpoint = $guest.Checkpoint
    SourceRoot = $config.SourceRoot
    EvidenceRoot = $config.EvidenceRoot
    GuestUser = $config.GuestUser
    CredentialTarget = $config.CredentialTarget
    ModuleCachePath = $config.ModuleCachePath
    ModuleCacheSha256 = $config.ModuleCacheSha256
    Row = 'A-review'
    ArmReboots = 3
    Launcher = 'upd'
    DeployArgs = 'run -DisableSelfUpdate'
    TimeoutMinutes = 50
}
$harness = (Resolve-Path ./tests/integration/lab/Invoke-LabRow.ps1).Path
$job = Start-Job -ArgumentList $harness,$parameters -ScriptBlock {
    param($script,$arguments)
    & $script @arguments
}
```

For the headless row, select its configured guest/checkpoint and change the row
parameters to `Row='B-review'`, `ArmReboots=2`, `Launcher='deploy'`,
`SystemContext=$true`, and `DeployArgs='-MaxUserIdentityWaits 1 -DisableSelfUpdate'`.
Keep the PowerShell job's owning process alive. `Receive-Job -Wait` waits for the
result; use `host-timeline.txt` for progress without repeatedly dumping raw logs.
A lost host process releases its lease but does not stop guest tasks. Inspect and
collect evidence before shutting down or restoring that guest.

The harness does not automatically shut down guests at completion, so failed
state remains inspectable. When finished collecting evidence, use a guest-side
normal shutdown (`shutdown.exe /s /t 0` through PowerShell Direct), wait for Off,
then run the next row. Never use `Restart-VM` as a substitute for a guest reboot.

## Dependencies and source identity

Use an isolated local Git checkout when cloud-drive locks or scanning interfere.
Commit identity alone is insufficient for dirty candidates: every transferred
file is hashed in `run-manifest.json`, alongside the harness hash, parameters,
Git status, timestamps, and injection action. The transfer uses Git-listed files
plus non-ignored untracked files, excluding tracker data and local handoff files.
Do not edit the source tree during a row. `-SkipSync` is a diagnostic option and
does not establish that guest files match the host manifest.

The optional module ZIP must contain module/version directories directly at its
root, such as `BurntToast/1.1.0` and `PSWindowsUpdate/2.2.1.5`. The configured SHA256
is checked on the host and again inside the guest. Pin and obtain modules from a
trusted source; a matching hash proves identity, not publisher authenticity.
The September 26 cache used those two versions. To recreate an equivalent cache:

```powershell
$cache = Join-Path $env:TEMP ('bootupd-modules-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $cache | Out-Null
Save-Module BurntToast -RequiredVersion 1.1.0 -Repository PSGallery -Path $cache
Save-Module PSWindowsUpdate -RequiredVersion 2.2.1.5 -Repository PSGallery -Path $cache
Compress-Archive -Path (Join-Path $cache '*') -DestinationPath "$cache.zip"
Get-FileHash "$cache.zip" -Algorithm SHA256
```

A rebuilt ZIP may have a different hash; review and record its own digest. Cache
provisioning requires PowerShell 7 in the guest. Omit both cache parameters for a
PowerShell 5.1-only bootstrap row. Record dependency versions when comparing runs.
The Chocolatey fixture is `tests/integration/Invoke-ChocolateyRecordRemovalGate.ps1`;
it requires Chocolatey installed inside the disposable guest and a matching
`-LabGuestName`. Its positive control proves package-script suppression and external
file retention, not a real AWS publisher rollover or every uninstall mechanism.

## Read results before reaching for screenshots

Read `run-manifest.json`, then `summary.json`, then targeted log excerpts. The
manifest says **Collected**, not **PASS**: classification still requires provider
convergence, settled reboot evidence, health checks, and cleanup. A completion
banner with deferred inventory is PARTIAL. Missing files or a failed collector
are not success. `os-boot-times.json` retains raw boot timestamps for independent
recounting. An optional `-ScreenCaptureScript` enables a local screenshot helper;
there is no implicit dependency on one.

Raw evidence stays outside Git and can contain guest identities and private paths.
Publish only sanitized summaries. Preserve earlier failed attempts and name tests
that were not run. Finish validation reports with evidence paths and coverage
limits, then commit them; an untracked draft is not a durable handoff.

For development gates, run `tools/Invoke-TestGates.ps1`. Beads work uses
`tools/Invoke-Beads.ps1`; if the installed client and central schema disagree,
consult the local handoff and issue #78 rather than migrating the shared server.

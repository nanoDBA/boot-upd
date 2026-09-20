# SSMS native servicing

`upd` includes a serial SSMS phase after Winget and Chocolatey. SSMS 22 is
serviced by Visual Studio Installer, whose update availability can differ from
the package managers' published versions. Earlier SSMS generations remain under
their existing package-manager paths.

Native servicing is enabled by default. `upd --skip-ssms` (alias `--no-ssms`),
or `-SkipSsms` on the PowerShell entry points, disables this phase for the cycle.
The setting survives deployment, self-update, and reboot resume, including an
explicit `-SkipSsms:$false` override. It does not filter SSMS packages from Winget
or Chocolatey.

The phase discovers installed instances through `vswhere`, including prerelease
and incomplete instances, and filters for the SSMS product. It never invokes
`updateall`, installs a new instance, changes a channel, or passes `--force`.
For an outdated instance it runs the installed `setup.exe update --installPath`
with `--quiet --norestart`, from outside the Installer directory, and waits for
the process result. `--wait` is a bootstrapper option and is not passed to
`setup.exe`.

Before updating, the phase reads the instance's configured channel source and
validates its product, channel, and build metadata. Installed build versions and
the channel build are compared in the same version domain; the public marketing
version is not interchangeable with the installation build. The manifest reader
is an adapter to observed publisher data, not a guarantee of a permanent JSON
schema. Unrecognized metadata or an inaccessible source cannot establish
convergence.

After updating, fresh inventory must identify the same instance, path, and
channel/source and reach the validated target. An already-current healthy
instance needs no installer invocation. Only an observed version increase counts
as a verified update. A successful process exit by itself does not prove that
SSMS changed or reached its channel target.

Installer and inventory reboot evidence keep the phase unfinished until the
cycle resumes after reboot. Other incomplete outcomes use the existing bounded
retry policy. SSMS has its own durable completion flag and summary counter,
including migration from checkpoints written before this phase existed.
The pre-update build is checkpointed before starting the installer. A verified
change and retirement of that baseline are committed together, so a reboot or
interruption cannot turn a completed version change into an uncounted no-op.

## Provider VM gate

Prepare a disposable Hyper-V guest with an older SSMS 22 build, then run:

```powershell
./tests/integration/Invoke-SsmsUpdateGate.ps1 -VMName lab-a
```

The gate runs the production helpers under SYSTEM, verifies the transferred
candidate hash, retains native installer logs, and independently checks before
and after inventory. A second provider pass must leave the same instances and
versions unchanged with zero updates and zero installer actions. `-ExpectNoChange`
can exercise a guest already at its configured channel target. An incomplete
provider result, including a reboot requirement, is not a passing gate.

## References

- [Microsoft: update SSMS](https://learn.microsoft.com/en-us/ssms/install/update)
- [Microsoft: command-line parameters and exit codes](https://learn.microsoft.com/en-us/ssms/install/command-line-parameters)
- [Microsoft: command-line examples](https://learn.microsoft.com/en-us/ssms/install/command-line-examples)
- [Microsoft: vswhere examples](https://github.com/microsoft/vswhere/wiki/Examples)
- [Issue #73](https://github.com/nanoDBA/boot-upd/issues/73)

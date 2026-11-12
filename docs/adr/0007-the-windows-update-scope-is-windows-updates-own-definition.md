# The Windows Update scope is Windows Update's own definition, and what it leaves alone is named

The Windows Update phase decides what to install by one Windows Update Agent search-criteria
string, built in `Get-WindowsUpdateVerificationScope` and consumed unchanged by the background
prefetch, the install call, the offline reconciliation of a cached assessment and the final
convergence scan. The string says: every software update Windows Update has marked for
installation, in any category, plus feature updates that Windows Update offers as optional,
unless the operator says `-SkipFeatureUpdates`. Drivers are a different update type and stay
with the opt-in driver/firmware phase. Everything Windows Update offers that the string does not
select is logged by name with the reason.

The decision replaces an allowlist of three categories (Security, Critical, Definition) that had
been the scope since the first release. On 2026-11-06 a machine on Windows 11 25H2 had been
offered 26H2 for weeks; the updater ran daily and wrote "zero applicable updates remain in the
configured category scope" every time. Two things hid the feature update, and they compounded.
Feature updates are a fourth category, `Upgrades`, so the allowlist excluded them. Adding the
category would not have found it either: the agent implies `DeploymentAction='Installation'`
for every search that names no deployment action, and a feature update a device may take but
has not been pushed is offered as `OptionalInstallation`. Every scan in the cycle used a
default search, so the prefetch, the install and the final convergence check agreed with each
other, and the convergence claim was true of the scope and false of the machine.

An allowlist of categories is a prediction about how Microsoft will file updates. It was wrong
once in a way nothing could detect, and it will be wrong again the next time a new kind of
update appears. Windows Update already has a definition of "what this machine should install":
the deployment action it attaches to each offer. Taking that definition means the phase does
exactly what leaving the machine alone would do, with the one addition the operator installs
this tool for, which is to take the feature update now rather than wait for the push.

## Considered options

- **Add `Upgrades` to the allowlist and `OptionalInstallation` to the criteria.** The smallest
  patch, and it finds 26H2. Rejected because it keeps the prediction: the next category Microsoft
  invents, or the next deployment action, is hidden the same way, and nothing in the log would
  say so. It also leaves PSWindowsUpdate's category post-filter in the loop, which returned
  nothing for this feature update even when asked for `Upgrades`.
- **Build a category-name filter of our own around a broad search.** Deterministic and testable,
  but it is still an allowlist, and it puts a second definition of "in scope" (a PowerShell
  predicate) beside the first (the criteria string the install call needs). Two definitions of
  the same thing drift. The scan worker instead runs the scope criteria and a broad search and
  marks membership by UpdateID, so there is one definition and the scan cannot disagree with the
  install.
- **Install through the agent's COM interface and drop PSWindowsUpdate.** Cleaner in the long run,
  and the project already reads the agent directly for history and reboot evidence. Deferred:
  the install path's output parsing, re-offer classification and reboot evidence are verified
  machinery, and the module honours a caller-supplied criteria string, which is all this change
  needs from it. The final scan no longer needs the module at all.

## Consequences

- The scope has a single textual representation. Tests pin that no `-RootCategories` or
  category literal returns to the phase, and the rule file says why.
- A feature update is a new Windows version, not a package. The install phase scans first and,
  when a feature update or a Windows cumulative update is in scope, runs under
  `-FeatureUpdateTimeoutMinutes` (default 240)
  instead of the per-provider budget. The child process waits on COM while TrustedInstaller
  works, so the CPU-based idle clock (ADR-0005) cannot tell a long install from a hang; the
  budget is the only protection, and it has to fit the work.
- Silence is no longer the default for the things the phase does not take. In-scope offers are
  logged with kind, size and download state; out-of-scope offers with a reason (driver, optional,
  excluded by pattern, installed earlier this run, feature updates skipped). Drivers log at
  Verbose because they are a documented opt-in and would otherwise repeat on every machine with a
  vendor driver pending. This is ADR-0003's invariant pointed at the scan: a convergence claim
  says what it covered and what it saw and left.
- The scope signature changed, so cached zero-work evidence from earlier versions is not reused
  once. One extra online scan per upgraded machine is the price of not trusting an assessment
  made under the old blind spot.
- Lab coverage for a feature update installing through the updater is **not run** at the time of
  this decision; the change was verified read-only against the live offer on the reporting
  machine and by unit tests. The lab row is tracked and belongs in the validation report of the
  release that first ships this.

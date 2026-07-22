---
paths:
  - "*.cmd"
  - "tools/Invoke-UpdLauncher.ps1"
  - "tools/Invoke-UpdBootstrap.ps1"
  - "tests/LauncherExperience.Tests.ps1"
  - "tests/integration/Invoke-PublishedLauncherUpgradeGate.ps1"
  - "tests/SelfUpdateHandoff.Tests.ps1"
---

# Batch launcher and self-update safety

- Preserve CRLF bytes in every `.cmd` file because `cmd.exe` can misparse mixed or LF-only launchers.
- After any batch-file edit, run `./tools/Repair-LineEndings.ps1`. Test and release gates also repair line endings automatically; fix them instead of reporting them as a user-facing blocker.
- Never replace `upd.cmd` while `cmd.exe` is reading it. Preserve the canonical-path-verified temporary trampoline and the v2.5.43 compatibility bridge.
- Accept staged launcher adoption only after release-manifest and SHA256 verification; missing or malformed integrity evidence fails closed.
- Preserve raw argument forwarding so old launchers can bootstrap new commands without binding command words to legacy positional parameters.

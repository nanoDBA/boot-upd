# Claude Code project instructions

@AGENTS.md

## Repository orientation

- This is a Windows PowerShell 7 updater whose correctness depends on real Windows identities, Task Scheduler, package-manager exit codes, and reboot persistence.
- Read `README.md` for supported behavior and `docs/TESTING.md` before changing lifecycle, launcher, task, mutex, state, or reboot logic.
- Treat `Invoke-BootUpdateCycle.ps1` as the authoritative orchestrator and `upd.cmd` plus `tools/Invoke-UpdLauncher.ps1` as one launcher system.
- Preserve CRLF bytes in every `.cmd` file because `cmd.exe` can misparse mixed or LF-only launchers. After any batch-file edit, run `./tools/Repair-LineEndings.ps1`; the test and release gates also run it automatically, so fix line endings instead of reporting them as a user-facing blocker.

## Working safely

- The checkout may be inside Google Drive. Keep edits narrow, preserve unrelated changes, and do not bulk-copy another tree over the repository.
- Never place credentials, webhook URLs, tokens, or passwords in tracked files, task arguments, command lines, or chat. Use Windows Credential Manager and the existing credential helpers.
- Do not run the live update cycle, install packages, register continuation tasks, or reboot a machine merely to test a code change unless the user explicitly authorized that live-system effect.
- Do not replace `upd.cmd` while `cmd.exe` is reading it. Preserve the verified trampoline and the v2.5.43 compatibility bridge.
- The global mutex is a fail-closed safety boundary shared by elevated-user and SYSTEM tasks. Preserve its explicit SYSTEM/Administrators ACL.

## Verification

- Run `./tools/Invoke-TestGates.ps1` from elevated PowerShell 7 for lifecycle or launcher changes.
- If elevation or network access is unavailable, use the documented skip switches and report skipped gates as **not run**, never passed.
- Use the immutable published-launcher and user/SYSTEM gates; a Pester count alone is not sufficient release evidence.
- For release work, follow `docs/TESTING.md` and `tools/New-Release.ps1`; never publish merely because the working-tree tests pass.

## Claude Code notes

- Use project skills `/test-gates` and `/reboot-resilience-review` when applicable.
- Store durable project knowledge with `./tools/Invoke-Beads.ps1 remember`; Claude auto-memory is supplementary, not authoritative.
- Use `/context` to confirm this file and its `AGENTS.md` import loaded.

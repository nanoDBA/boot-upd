# Claude Code project instructions

@AGENTS.md

## Repository orientation

- This is a Windows PowerShell 7 updater whose correctness depends on real Windows identities, Task Scheduler, package-manager exit codes, and reboot persistence.
- Read `README.md` for supported behavior and `docs/TESTING.md` before changing lifecycle, launcher, task, mutex, state, or reboot logic.
- Treat `Invoke-BootUpdateCycle.ps1` as the authoritative orchestrator and `upd.cmd` plus `tools/Invoke-UpdLauncher.ps1` as one launcher system.
- File-specific invariants live in `.claude/rules/` and load when Claude works on the matching updater, launcher, test, or public-documentation files.

## Working safely

- The checkout may be inside Google Drive. Keep edits narrow, preserve unrelated changes, and do not bulk-copy another tree over the repository.
- Never place credentials, webhook URLs, tokens, or passwords in tracked files, task arguments, command lines, or chat. Use Windows Credential Manager and the existing credential helpers.
- Do not run the live update cycle, install packages, register continuation tasks, or reboot a machine merely to test a code change unless the user explicitly authorized that live-system effect.
- Treat all tracked content as public: examples, fixtures, screenshots, logs, release notes, and test output must use sanitized identities, paths, domains, and organization names.

## Verification

- Run `./tools/Invoke-TestGates.ps1` from elevated PowerShell 7 for lifecycle or launcher changes.
- If elevation or network access is unavailable, use the documented skip switches and report skipped gates as **not run**, never passed.
- Use the immutable published-launcher and user/SYSTEM gates; a Pester count alone is not sufficient release evidence.
- For release work, follow `docs/TESTING.md` and `tools/New-Release.ps1`; never publish merely because the working-tree tests pass.

## Claude Code notes

- Use project skills `/test-gates` and `/reboot-resilience-review` when applicable.
- Store durable project knowledge with `./tools/Invoke-Beads.ps1 remember`; Claude auto-memory is supplementary, not authoritative.
- Use `/memory` to confirm this file, its `AGENTS.md` import, and applicable `.claude/rules/` files loaded.

---
name: test-gates
description: Run and interpret Boot Update Cycle's separate unit/process, user-SYSTEM, and published-launcher compatibility gates. Use when verifying code, launcher, scheduled-task, mutex, state, or reboot-chain changes.
argument-hint: "[fast|all]"
disable-model-invocation: true
---

Read `docs/TESTING.md`, then inspect the worktree before testing.

- With `fast`, run `./tools/Invoke-TestGates.ps1 -SkipOsBoundary -SkipPublishedUpgrade`.
- With `all` or no argument, run `./tools/Invoke-TestGates.ps1` from elevated PowerShell 7.
- Never describe a skipped gate as passed.
- Report the three gate dispositions separately and include any failed scenario's concrete identity, version edge, or state transition.
- Do not start the live updater or reboot the machine as part of this skill.

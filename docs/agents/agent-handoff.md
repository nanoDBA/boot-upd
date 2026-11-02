# Handoff for a new agent

Written for Duet joining the project. It applies to any agent new to this repository.
Claude Code and OpenAI Codex have both worked here and the automation is mature, so the
work is mostly following the existing setup, not building new tooling.

This file points to the documents that are the source of truth. When they disagree with
this file, follow them and fix this file.

## 1. Read these first, in order

1. `AGENTS.md`: tracker commands, non-interactive shell flags, the session-close checklist.
2. `.claude/rules/*.md`: three short rule files. Claude Code loads them automatically
   for matching paths. Other agents don't, so read all three yourself before you edit the
   updater, the launcher or any public doc. They hold the invariants that past defects
   taught (exit-code reconciliation, boot-session identity, CRLF launchers, privacy).
3. `CONTEXT.md` and `docs/adr/`: the domain vocabulary and recorded decisions.
4. `docs/TESTING.md`: what each test gate proves and how results are reported.
5. `README.md`: the supported behavior users rely on.

Runbooks are in `.agents/skills/` (the copy Codex uses) and `.claude/skills/` (the copy
Claude Code uses). Each `SKILL.md` is plain Markdown, so follow it as a checklist even if
your tool has no skill system. The ones you'll use most:

| Skill | Use it for |
|---|---|
| `test-gates` | Running and reporting `./tools/Invoke-TestGates.ps1` |
| `lab-row` | Running a multi-reboot row on the Hyper-V lab guests |
| `reboot-resilience-review` | Reviewing any change to lifecycle, tasks, state, providers or the launcher |
| `humanize-docs` | Public docs and release notes (in `.agents/skills/` only) |

If you change a skill that has two copies, change both.

## 2. What the project is

A PowerShell 7 updater that runs Windows Update, Winget, Chocolatey and other providers
across reboots. It saves its progress before each step, keeps going after restarts using
Task Scheduler, and reports only what it actually verified. Its correctness depends on
real Windows identities, the scheduler and reboots, which unit tests can't simulate.

- `Invoke-BootUpdateCycle.ps1` is the main script.
- `upd.cmd` and `tools/Invoke-UpdLauncher.ps1` are one launcher system and change
  together.
- `.cmd` files must stay CRLF. Run `./tools/Repair-LineEndings.ps1` after editing one.

## 3. Working alongside other agents

- **Check the checkout first.** Another agent may have left it on a feature branch or with
  uncommitted work. Run `git status -sb` and `gh pr list` before you start. Never discard
  or reformat changes you didn't make.
- **Claim before you work.** `./tools/Invoke-Beads.ps1 update <id> --claim` tells the other
  agents the issue is taken. Check `ready` and the open PRs so you don't duplicate work in
  flight.
- **One branch and one PR per change**, targeting `master`. Never push to someone else's
  branch, force-push a shared branch, or merge to `master` unless the maintainer asks.
- **Leave a trail the next agent can follow.** Put the evidence in the PR body, a comment
  on the bead, and for multi-session work a dated section in a handoff file under
  `docs/agents/`. `docs/agents/epic-35qb-handoff.md` is a good model.
- **Commit trailers:** past commits name the agent in a `Co-Authored-By` line. Follow your
  tool's convention for this.

## 4. Issue tracking (bd)

`docs/agents/issue-tracker.md` has the conventions. Things that have caught agents out:

- **Use the wrapper.** Always run `./tools/Invoke-Beads.ps1`, never a bare `bd`. The
  wrapper reads the credential from Windows Credential Manager and runs only the pinned bd
  1.1.0 client named by the repo-local git config `beads.clientPath`. A newer `bd` on PATH
  can try to migrate the shared database schema.
- **The database is shared and remote.** If it's unreachable, write down what you would
  have filed and carry on. Don't poll it or retry in a loop, and don't create a local
  database.
- **Exports:** run `./tools/Invoke-Beads.ps1 export -o .beads/issues.jsonl`. The wrapper
  removes personal data from it; a raw `bd export` does not.
- **Search before creating.** `search` matches titles only. To check descriptions too, run
  `list --all --json` and filter the text.
- **GitHub Issues:** bd is authoritative. Some GitHub issues mirror a bead and name it in
  their body. Never run `bd github sync` without `--parent`.

## 5. Safety lines

- Never run the live update cycle, install packages, register continuation tasks or
  reboot on the host machine to test a change. The Hyper-V lab guests exist for that.
  The lab runbook is `tests/integration/lab/HANDOFF.md`, and its machine-local settings
  are in ignored files next to it.
- Never put a credential, token, webhook URL or password in a file, a command line, a task
  argument or chat. The lab and tracker credentials are already in Credential Manager;
  use the helper scripts that read them.
- **The repository is public.** Nothing tracked may contain a real computer name,
  username, domain, internal host or IP, email address or local path. That includes
  evidence names quoted into docs, release notes and test fixtures. Use `WORKSTATION01`,
  `username`, `C:\Path\To\...`. Machine-specific notes go in gitignored `*.local.*`
  files.
- The checkout may live in a cloud-synced folder. Files can show as modified with no
  content change, and slow stats can stall `git status`. Check `git diff` before believing
  a change exists, and create worktrees outside the synced folder.

## 6. Evidence and reporting

This is where agents most often go wrong here, so be strict:

- Use exactly four results: **PASS**, **PARTIAL** (name what *was* established), **FAIL**
  (name why) and **NOT RUN**. A skipped gate is NOT RUN, never PASS. A summary may say PASS
  only when every row under it passed.
- **A green unit suite isn't enough.** Several shipped defects were found only by VM rows,
  with every unit test passing. Changes to checkpoints, tasks, reboot detection, mutexes,
  provider convergence, cleanup or the resume chain need lab rows A and B against the final
  build before release.
- **Read a row's numbers, not just its verdict.** `summary.json` once said
  `Completed: true` alongside `Passes: 0`.
- **Headless row B is usually PARTIAL**, not PASS. User-scope work is deferred when no one
  is signed in, and Windows Update has kept re-offering an already-installed update in the
  disposable guests. Report it as PARTIAL with the reason. A previous agent wrote PASS in a
  commit message for a PARTIAL row, and it had to be corrected in the docs and the tracker.
- Name the evidence directory for every row you report.

## 7. Releases

Follow `docs/TESTING.md` ("Release evidence") and `tools/New-Release.ps1`:

- The working tree must be clean.
- The tag must match the version embedded in the script and in `upd.cmd`.
- After publishing, download the assets again and check each one against its SHA256
  sidecar.
- Run the live bootstrap workflow.

Record results in a `docs/validation-<version>.md`. Don't publish just because local tests
pass.

## 8. Where the history is

- `docs/validation-*.md`: per-release and per-change evidence, including what was not
  covered.
- `docs/agents/epic-35qb-postmortem.md`: what went wrong in a long unattended session and
  why. Its last section is the best short summary of how to work here.
- `RELEASE_NOTES.md`: user-facing history.
- For current state, run `./tools/Invoke-Beads.ps1 ready` and `gh pr list`; this file
  doesn't track it.

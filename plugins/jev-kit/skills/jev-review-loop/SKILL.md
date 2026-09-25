---
name: jev-review-loop
description: Run an unattended, budget-capped code review → fix → verify loop in which Jev makes every high-volume judgment (which changed code needs review and through which lenses, which model tier, whether a finding holds, whether a fix is on target) so frontier-LLM tokens go only where they matter. Uses a deterministic code impact graph to scope the work, a persisted ledger and state graph to drive /loop or scheduled runs, and a PreToolUse scope guard to keep autonomy inside the envelope. Use when asked to review a branch or PR autonomously or cheaply, to review in a loop until clean, or to set up unattended review.
---

# Jev-gated unattended review loop

`SPEC.md` in this folder is the contract. Read §3 (autonomy envelope), §5
(Jev decision points), and §9 (stop rules) before the first run in a
repository. This file is the runbook.

**Costs, from the spec:** a 14-question Jev battery costs about $0.00004 and
takes about 110 ms. The same battery costs roughly 40× more on Haiku and about
800× more on Opus. Jev is about Sonnet-level at judgment (67.8% vs Opus 73.1%
on one independent test). So Jev **allocates** LLM attention, but it never has
the last word on anything high-stakes.

## Paths

- Scripts are in `${CLAUDE_SKILL_DIR}/scripts/`. If that variable isn't
  substituted, use the folder beside this file. Call them `$S` below.
- Run directory is `.review-loop/` in the repo, holding `ledger.json`,
  `graph.json`, the batch files, and the `ACTIVE` marker.
- Profile: `.claude/review-scope.json` if the repo has one, otherwise
  `${CLAUDE_SKILL_DIR}/scope.default.json`. Call it `$P`.
- Requirements: PowerShell 7, git, and `TYPESAFE_API_KEY`. The **jev** skill
  covers the key. Without a key, the loop still runs in spending mode (full
  LLM review).

## One-time setup (a person does this, not the unattended run)

1. Copy `scope.default.json` to `.claude/review-scope.json` and tighten it:
   live-system commands, `alwaysReview` paths, `minTierByPath`, and gates.
2. Enable the scope guard with `Install-JevKit.ps1 -EnableReviewScopeGuard`.
   That adds a `PreToolUse` hook for `Bash|Edit|Write|MultiEdit|NotebookEdit`.
   The guard does nothing unless `.review-loop/ACTIVE` exists.
3. Do the first run in a repository with `shadow: true`, then compare what Jev
   would have skipped against what the reviewers found (spec §7).

## Start a run (SCOPE)

1. Require a clean working tree and a review branch matching the profile's
   `allowPushBranch`. Create the branch from the target if needed.
2. Initialize the ledger and turn the guard on:
   ```powershell
   pwsh -NoProfile -File $S/Invoke-ReviewLoop.ps1 -LedgerPath .review-loop/ledger.json -Command init `
     -Data '{"base":"origin/master","head":"<sha>","branch":"claude/review-x","scopeProfile":".claude/review-scope.json"}'
   New-Item -ItemType File -Force .review-loop/ACTIVE
   ```
3. Commit `.review-loop/` so a fresh session can resume from git. Then run
   `-Command move -Data '{"to":"GRAPH","reason":"scoped"}'`.

## The tick (repeat until `terminal` is true)

`Invoke-ReviewLoop.ps1 -Command next` returns `{state, action, reason,
terminal}`. Do **only** that state's work, record it, run `move`, commit the
ledger, and loop. Never skip `next`: it evaluates the budget, oscillation, and
red-gate stop rules before anything else.

### GRAPH

```powershell
pwsh -NoProfile -File $S/Get-ReviewGraph.ps1 -Base <base> -Depth 2 -OutputPath .review-loop/graph.json
pwsh -NoProfile -File $S/Invoke-ReviewLoop.ps1 -LedgerPath .review-loop/ledger.json -Command frontier -Data '{"graphPath":".review-loop/graph.json"}'
```

Then `move` to REVIEW.

### REVIEW: Jev decides, the LLM reviews only what's flagged

1. **D1 triage.** Write `.review-loop/d1.json` as one item per frontier node:
   `{id, file, kind, diff, callers, callees}`. For `diff`, send only that
   node's hunks (for a function, the lines within its span), never whole
   files. Then run:
   `Invoke-JevReviewGate.ps1 -Decision node-triage -InputPath .review-loop/d1.json -LedgerPath .review-loop/ledger.json -ProfilePath $P`
   Each item comes back as `skip`, `review`, or `audit`, with `lenses` and a
   `tier`.
2. **D2 context.** For each `review` or `audit` node, list candidate passages:
   direct callers and callees (their function bodies), tests that name the
   file, and docs lines that name it. Run `-Decision context-select` and keep
   only `include: true`. Set `mustInclude` for direct callers when a signature
   changed.
3. **Dispatch reviewers** with the Agent tool, grouped by tier, and pass
   `model` set to the D3 tier. Run at most 3 in parallel per tier. Give each
   reviewer only its node's diff, its selected context, and **only its flagged
   lenses**, using the reviewer brief below. Nodes marked `audit` get haiku and
   all lenses.
4. **Record** each finding with `add-finding`. Record spend with
   `cost {tier, dispatches, chars}`, where `chars` is the prompt size you
   sent. If an `audit` node produced a confirmed finding of medium or worse,
   record `cost {auditMisses: 1}`. That turns off skipping for the rest of the
   run, so re-triage.
5. `move` to VERIFY. If the frontier had nothing to review, `move` to DONE.

### VERIFY: settle cheaply first

1. Build `d4.json` from open, unverified findings:
   `{id, file, lens, severity, summary, evidence, excerpt, openFindings}`.
   `excerpt` is about 40 lines around `line`. `openFindings` lists the ids and
   summaries of the other open findings.
2. `Invoke-JevReviewGate.ps1 -Decision finding-verify ... -RepoRoot .`
   - `reject` (fabricated evidence, contradicted, or style-only): run
     `set-finding {verdict: rejected}`.
   - `confirm`: run `set-finding {verdict: confirmed}`. This only happens at
     medium severity or below, when Jev is confident.
   - `llm`: dispatch an **adversarial verifier** at the given `tier`. High and
     critical findings always land here. The verifier must refute or
     reproduce the finding. High and critical findings need a failing test,
     or a concrete input with its wrong output, before they're confirmed.
   - `duplicateOf` set: add a note and treat the finding as the same issue. If
     the original was already fixed, the ledger's reopen logic escalates it.
3. If `next` says to mark findings escalated, do that. Then `move` to FIX, or
   to DONE when `next` says so.

### FIX: one finding, one commit

For each fixable finding (highest severity first, up to
`maxFixesPerIteration`):

1. **D5.** Run `-Decision fix-tier` and dispatch the fixer at that tier with
   the fixer brief below. A correctness fix must include a test that fails
   before the fix.
2. **D6.** Run `-Decision fix-check` on the finding plus the fix diff.
   `gates` means proceed. `llm-review` means one review of the diff at the
   fixer's tier, then accept it or discard it and count an attempt.
3. Commit with `review-loop(<runId>): fix <id> <summary>`, then run
   `set-finding {id, verdict: confirmed, status: fixed, fixCommit: <sha>}`.
   A failed attempt gets `set-finding {id, countAttempt: true}`.
4. The scope guard blocks edits outside the impacted subgraph and to
   protected paths. When it blocks one, don't look for a workaround: mark the
   finding `inScope: false` so it gets escalated.

Then `move` to GATE.

### GATE

Run every gate in the profile and record each result with `gate`. A gate that
can't run in this environment is `not-run`, **never passed**. If a gate fails,
`next` sends the loop back to FIX once. A second red result in the same
iteration stops the run, which then reverts that iteration's fix commits with
`git revert`. When the gates are green, push the review branch only
(`git push -u origin <branch>`). Then compute the new frontier from the
files the fixes touched:

```powershell
pwsh -NoProfile -File $S/Get-ReviewGraph.ps1 -ChangedPath <files touched by fixes> -Depth 1 -OutputPath .review-loop/graph.json
```

Run `frontier`, then `move` to REVIEW. That re-runs D1 on the fix-impact
subgraph, usually trivially. **This is where the loop gets most of its
savings: the fixed point is often reached without any LLM call.**

### DONE or STOPPED

1. Remove `.review-loop/ACTIVE` and write the report (template below) to
   `.review-loop/REPORT.md`, then show it to the user.
2. The final commit deletes `.review-loop/` so the PR diff stays clean. The
   report goes into the final message or the PR body instead.

## Running unattended

- **In an attended session:** `/loop` with no interval (self-paced). Each
  firing performs ticks until the run is terminal or about 20 minutes have
  passed, then schedules the next wakeup. Pass the same prompt back every
  time.
- **Scheduled cloud run:** a Routine that starts a fresh session per firing
  with the prompt "Resume the jev-review-loop run on branch <branch>". The
  ledger in git is the only state it needs.
- **Every tick must be idempotent:** re-running a tick after a crash repeats
  at most one partial state. Never keep state only in chat.

## Briefs (LLM subagents)

**Reviewer.** "Review ONLY this change for these lenses: <lenses>. Node:
<id>. Diff: <hunks>. Context: <selected passages>. Report only real defects,
as JSON lines `{file, line, lens, severity (critical|high|medium|low),
summary (one sentence), evidence (quote the exact code line(s) verbatim)}`.
If there is no real defect, return `[]`. Do not report style unless it
causes a bug. Do not edit files."

**Verifier.** "Try to REFUTE this finding: <finding>. Code: <excerpt>. Return
`{verdict: confirmed|rejected, reproduction: <failing test or concrete
input → wrong output, or why it can't happen>}`. A finding is confirmed only
if you can show it. Do not edit files."

**Fixer.** "Fix exactly this finding and nothing else: <finding>. Make the
smallest change. For correctness, add or adjust a test that fails before the
fix and passes after. Do not touch unrelated code, formatting, dependencies,
CI, or settings. Do not weaken or skip tests. Report the files you changed."

## Report template

```
Review loop <runId>: DONE | STOPPED (<reason>), <iterations> iteration(s)
Findings: <fixed> fixed · <escalated> escalated · <rejected> rejected · <open> open
Gates:    <name>: passed|failed|NOT RUN …   (never summarize NOT RUN as passing)
Escalations (need a human): <id> <file> <summary> (reason)
Cost:     Jev <calls> calls, <tokens> tok (~$<usd>) · LLM dispatches opus/sonnet/haiku = a/b/c
          (~<est> tokens, estimated) · avoided: <n> nodes skipped, <n> lenses pruned,
          <n> findings and <n> fixes settled by Jev · audit: <sampled> sampled, <misses> misses
```

Don't call a run "clean" if any gate was NOT RUN or anything is open or
escalated.

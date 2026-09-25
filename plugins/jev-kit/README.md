# jev-kit

Portable Claude Code skills for [Jev](https://docs.typesafe.ai/), TypeSafe AI's
System One model. Jev returns typed, calibrated decisions (choice, score, or
yes/no probability) in under a second, at $0.042 per million input tokens. It
doesn't write text. The skills pair it with Claude so that Jev makes the cheap,
high-volume judgments and Claude does the reading, reasoning, and writing.

These skills aren't tied to Boot Update Cycle. They live in this repository so
they're versioned and can be installed on any machine.

| Skill | Use it for |
| --- | --- |
| `jev` | One-shot typed questions about a piece of text or JSON, question design rules, and API errors |
| `jev-triage` | Bulk triage of logs, mail, comments, tickets, and transcripts into routed buckets. Claude reads only what matters |
| `jev-skill-router` | Picking at most one installed skill per prompt, with an optional fail-open `UserPromptSubmit` hook |
| `jev-review-loop` | An unattended review → fix → verify loop. Jev decides which code needs review, through which lenses, and at which model tier. It also settles findings and checks fixes, so opus, sonnet, and haiku are spent only where Jev says they matter. It uses a deterministic impact graph, a persisted ledger and state graph (for `/loop` or scheduled runs), and a fail-closed scope guard. The contract is `skills/jev-review-loop/SPEC.md` |

Built-in triage rubrics: `sql-errorlog`, `firewall-log` (OPNsense, Suricata,
Zenarmor), `email`, `meeting-transcript`, and `feedback` (YouTube, community,
and reviews).

## Requirements

- PowerShell 7+ (`pwsh`) on `PATH`.
- A TypeSafe API key from the console's API keys page, provided either way:
  - the `TYPESAFE_API_KEY` environment variable, or
  - a `Microsoft.PowerShell.SecretManagement` secret named `TypeSafeApiKey`.

  Don't put the key in `settings.json`, task arguments, or a tracked file.

## Install everywhere (plugin marketplace)

```bash
claude plugin marketplace add nanoDBA/boot-upd
claude plugin install jev-kit@nanodba
```

To update:

```bash
claude plugin marketplace update nanodba
claude plugin update jev-kit@nanodba
```

Then restart Claude Code or run `/reload-plugins`. Plugin skills are namespaced,
for example `/jev-kit:jev-triage`.

## Install without the marketplace (copy to user skills)

From a checkout, run this after every `git pull` to update:

```powershell
pwsh -NoProfile -File ./plugins/jev-kit/Install-JevKit.ps1 -WhatIf
pwsh -NoProfile -File ./plugins/jev-kit/Install-JevKit.ps1
```

- The installer replaces only the `jev`, `jev-triage`, `jev-skill-router`, and `jev-review-loop`
  folders in `~/.claude/skills`. It doesn't touch anything else.
- `-Destination` takes several directories if other agents read skills from
  somewhere else.
- `-EnableSkillRouterHook` and `-DisableSkillRouterHook` add or remove the
  router hook in `~/.claude/settings.json`. The installer writes a timestamped
  backup first and leaves other hooks alone.
- `-EnableReviewScopeGuard` and `-DisableReviewScopeGuard` do the same for the
  review loop's `PreToolUse` guard. The guard does nothing unless a run is
  active (`.review-loop/ACTIVE` exists in the project).

## Companion: TypeSafe's official skill

For writing application code against the Jev API, TypeSafe maintains an
authoring skill that tracks the live docs:

```bash
claude plugin marketplace add typesafe-ai/skills
claude plugin install typesafe@typesafe-ai
```

## Tests

These run offline, with no key and no network:

```powershell
Invoke-Pester ./plugins/jev-kit/tests
```

They cover skill frontmatter, script syntax, the manifest versions matching,
rubric question limits and routing references, local question validation, and
the rule that an API key never appears in an error message. For the review
loop, they cover the acceptance criteria in `SPEC.md` §11: legal transitions,
every stop rule, oscillation escalation, falling back to more LLM review when
Jev is unreachable, rejecting fabricated evidence, the scope guard (active,
inactive, and fail-closed), and the impact graph.

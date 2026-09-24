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

- The installer replaces only the `jev`, `jev-triage`, and `jev-skill-router`
  folders in `~/.claude/skills`. It doesn't touch anything else.
- `-Destination` takes several directories if other agents read skills from
  somewhere else.
- `-EnableSkillRouterHook` and `-DisableSkillRouterHook` add or remove the
  router hook in `~/.claude/settings.json`. The installer writes a timestamped
  backup first and leaves other hooks alone.

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
the rule that an API key never appears in an error message.

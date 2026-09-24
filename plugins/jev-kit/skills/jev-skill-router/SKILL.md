---
name: jev-skill-router
description: Use Jev to pick at most one installed skill for a request so large skill libraries can stay out of the context window. Covers running the router by hand, explaining why a skill was or was not suggested, tuning its thresholds, and enabling or disabling the optional UserPromptSubmit hook that injects the suggestion automatically. Use when the user asks which skill fits a task, wants to set up or debug Jev skill suggestion, or wants to mark skills user-invocable-only without losing discoverability.
---

# Jev skill router

This ports TypeSafe's skill-suggestion cookbook, which in their benchmark cut
wrong-skill loads from 16.8% to 7.3% and loads-when-nothing-fits from 9.8% to 4.0%.
Each prompt costs two Jev calls:

1. **Rank.** A Choice over every installed skill (name → description), plus
   three gate nouls: does this act on the user's systems, would an expert
   follow a documented procedure, and would prose alone suffice (inverted).
   If the average gate is below 0.30, nothing is suggested.
2. **Re-check.** The top 3 skills are re-read with their full description and
   a body excerpt, and each gets an absolute "does it fit?" noul. If the best
   fit is below 0.30, nothing is suggested.

The payoff is that skills can be marked `disable-model-invocation: true`, so
they stay out of Claude's context. The router still ranks them and, when one
fits, injects its name and SKILL.md path for the turn.

The script is `${CLAUDE_SKILL_DIR}/../jev/scripts/Select-JevSkill.ps1`. If that
variable isn't substituted, use the `jev/scripts/` folder beside this skill's
folder. It needs PowerShell 7 and `TYPESAFE_API_KEY`.

## Ask by hand

```powershell
pwsh -NoProfile -File "${CLAUDE_SKILL_DIR}/../jev/scripts/Select-JevSkill.ps1" `
  -Prompt 'triage last night''s errorlog' -Explain
```

`-Explain` prints JSON with the gate score, the ranked shortlist, the fit
nouls, and the chosen skill's path. Without it, the script prints only the
skill name, or nothing when no skill fits. By default it scans
`~/.claude/skills`, `~/.claude/plugins`, and the project's `.claude/skills`.
Override that with `-SkillRoot 'dirA,dirB'`.

Tuning: `-GateThreshold` / `-FitsThreshold` (default 0.30 each), `-Shortlist`
(default 3), `-ExcerptChars` (default 600), and `-ExcludeUserInvocableOnly`.
Tune on real prompts. The cookbook's thresholds are a starting point, not a law.

## Automatic hook (opt-in)

This adds about 0.2-1 s and two paid calls to every prompt, so enable it only
when the user asks for it. The hook **fails open**. With no key, a slash
command, a short prompt, a timeout, an API error, or bad input, it prints
nothing and exits 0, so it can't block a prompt.

To enable it, run the installer from the jev-kit plugin folder:

```powershell
pwsh -NoProfile -File ./Install-JevKit.ps1 -EnableSkillRouterHook
```

That merges this entry into `~/.claude/settings.json` after writing a
timestamped backup. The same installer with `-DisableSkillRouterHook` removes it.

```json
{ "hooks": { "UserPromptSubmit": [ { "hooks": [ {
  "type": "command",
  "command": "pwsh -NoProfile -File \"<skills>/jev/scripts/Select-JevSkill.ps1\" -Hook",
  "timeout": 15 } ] } ] } }
```

When a suggestion arrives as `<skill_relevance>` context, read the named
SKILL.md and follow it if it fits the user's actual request. If it doesn't fit,
ignore it without comment.

## Debugging "why didn't it suggest X?"

1. Run with `-Explain` on the exact prompt.
2. If `gate` is under the threshold, the request read as advice rather than
   action. That is usually correct.
3. If X isn't in `ranked`, X's description doesn't say what it does. Fix the
   description, not the threshold.
4. If X is ranked but `fits` is low, the body excerpt contradicts the
   description. Tighten the skill.

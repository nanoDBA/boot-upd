---
name: jev
description: Ask TypeSafe's Jev model fast, calibrated, typed questions (choice / score / yes-no probability) about text or JSON instead of having an LLM eyeball it. Use when a task needs a cheap structured judgment on one item: classify a ticket, score severity of a log entry, check whether a document says something, pick a category with a confidence to gate on, or prototype questions before bulk triage. Also use when writing code that calls the TypeSafe/Jev API.
---

# Jev: typed judgments on demand

Jev (TypeSafe AI) is a **System One** model. It does not write text or reason out
loud. You send a `state` plus named questions, and it returns typed answers with
calibrated probabilities in roughly 70-500 ms, at $0.042 per million input tokens
with free output. Use it for the decision and keep the thinking and writing with
Claude.

Scripts live in `${CLAUDE_SKILL_DIR}/scripts/`. If that variable isn't
substituted, use the `scripts/` folder next to this SKILL.md. They need
PowerShell 7 (`pwsh`).

## Preconditions

- The API key goes in `TYPESAFE_API_KEY` or in a SecretManagement secret named
  `TypeSafeApiKey` (`Set-Secret -Name TypeSafeApiKey`). Never print it, put it
  in a command line, write it to a file, or paste it into chat. If it's
  missing, tell the user to create a key at https://console.typesafe.ai/keys.
  Don't guess.
- `TYPESAFE_BASE_URL` and `TYPESAFE_DEFAULT_MODEL` are optional overrides.

## One-shot evaluation

```powershell
pwsh -NoProfile -File "${CLAUDE_SKILL_DIR}/scripts/Invoke-Jev.ps1" `
  -StatePath ./item.txt -QuestionsPath ./questions.json -AsJson
```

- `-State '<text>'` or pipeline input also works. Add `-StateIsJson` to send a
  file as structured state.
- `-QuestionsPath` accepts a plain question map or a jev-triage rubric. For a
  rubric, it uses the rubric's `questions` property.
- `-Raw` returns full probability maps instead of the compact summary.

## Question design (the part that actually matters)

| Need | Type | Shape |
| --- | --- | --- |
| One of a fixed set | `choice` | `criteria`: `{ "option": "what it means", ... }`, 1-255 options |
| Degree on a rubric | `score` | `criteria`: ordered array of 2-10 **self-contained** level descriptions |
| Is X true? | `noul` | Optional `criteria`: `{ "true": "...", "false": "..." }`; returns P(yes) |

```json
{
  "department": { "type": "choice", "instructions": "Which team should handle this?",
    "criteria": { "billing": "Payments, refunds", "technical": "Bugs, outages", "none": "Nothing here fits" } },
  "urgency": { "type": "score", "instructions": "How time-sensitive is this?",
    "criteria": ["Can wait", "This week", "Today", "Right now"] },
  "is_scam": { "type": "noul", "instructions": "Is this likely phishing or fraud?" }
}
```

Rules that keep answers honest:

- **Ask one narrow judgment per question.** Question ids are never sent to the
  model, so the `instructions` must carry the whole meaning.
- **Give every choice an escape hatch** ("none" or "other") when nothing may fit.
  The model can't choose an option you left out.
- **Ask independent questions in one call.** They run in parallel, cost one
  round trip, and can't see each other's answers.
- **Use structured state** (named JSON fields) when the context has several
  parts. Point at fields with backticks: ``"Is `ticket.body` a refund request?"``.
- **Keep counting, math, and date arithmetic out of Jev.** It reads literally
  and does badly with numbers and indirection. Do those in code and ask Jev for
  the semantic part only.
- **State budget:** about 32k tokens for state plus the longest question. The
  script truncates oversized text and sets `stateTruncated`. Treat a truncated
  answer as unverified.

## Reading answers

- `choice` / `score` include `confidence` (0-1), which is how concentrated the
  distribution is. A `noul` has no confidence field, and 0.5 means a coin flip,
  not "medium".
- Gate actions by risk. Act on high confidence, confirm or review on medium,
  and don't act on low. Set the thresholds from the cost of being wrong, not
  from habit.
- Typed output guarantees the interface, not the truth. Spot-check a handful of
  real items before trusting a new question set.

## Hand-offs

- Many items → use the **jev-triage** skill (bulk, parallel, routed buckets).
- Picking which skill to load → use the **jev-skill-router** skill.
- Writing application code against the API → the live docs are canonical:
  https://docs.typesafe.ai/llms.txt (append `.md` to any page path). TypeSafe
  also ships an official authoring skill: `claude plugin marketplace add
  typesafe-ai/skills` then `claude plugin install typesafe@typesafe-ai`.

## Errors

| Status | Meaning | Script behavior |
| --- | --- | --- |
| 401 | Bad or missing key | Fails immediately |
| 422 | Malformed questions or state | Fails immediately. Most shape errors are caught locally first |
| 429 / 529 / 5xx / network | Rate limit or overload | Up to 5 attempts, exponential backoff, honors `Retry-After` |

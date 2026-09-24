---
name: jev-triage
description: Bulk-triage hundreds to thousands of items with Jev before Claude reads any of them - log lines (SQL Server ERRORLOG, Windows events, OPNsense/Suricata, Home Assistant), email exports, support tickets, YouTube/community comments, meeting transcripts. Classifies every item in parallel for fractions of a cent, routes each into buckets (page / act / review / drop / error) with deterministic rules, then Claude only reads what matters. Use when input is too large or too repetitive to read line by line.
---

# Jev triage: cheap model sorts, Claude thinks

The pattern is to have Jev label every item with the same rubric, let code apply
the routing rules, and give Claude only the buckets worth reading. Nothing gets
dropped silently. API failures go to `error`, truncated or low-confidence
unmatched items go to `review`, and the summary counts every bucket.

The engine is `${CLAUDE_SKILL_DIR}/../jev/scripts/Invoke-JevTriage.ps1`. If that
variable isn't substituted, use the `jev/scripts/` folder beside this skill's
folder. Rubrics are in `${CLAUDE_SKILL_DIR}/rubrics/`. It needs PowerShell 7 and
`TYPESAFE_API_KEY`. The **jev** skill covers key handling and question design.

## Workflow

1. **Pick or write a rubric.** Built-in rubrics:

   | Rubric | For | Buckets |
   | --- | --- | --- |
   | `sql-errorlog.json` | ERRORLOG, Agent logs, Application events | page / act / watch / drop / review |
   | `firewall-log.json` | OPNsense filterlog, Suricata/Zenarmor, router syslog | page / investigate / watch / drop / review |
   | `email.json` | Mail exports (subject/from/body) | quarantine / now / reply / read_later / drop / review |
   | `meeting-transcript.json` | Transcripts or chunks | escalate / extract / archive / drop |
   | `feedback.json` | Comments, posts, reviews, discussions | retain / reply / testimonial / backlog / drop |

   To make a new one, copy the closest rubric and edit it. Keep it to 2-6
   questions. Put the questions and thresholds in the file, not in the command
   line, so a human can review them.

2. **Prefilter with regex when you can.** `-Pattern` drops lines before any
   tokens are spent. For logs, start with something like
   `'Error|Severity|fail|deadlock|I/O|corrupt'` and widen it only if the drop
   bucket is suspiciously empty.

3. **Dry run first.** Add `-WhatIf` to see the item count and an estimated cost.
   `-MaxItems` (default 5000) is a spend guard. Raise it on purpose rather than
   out of reflex.

4. **Run it.**

   ```powershell
   pwsh -NoProfile -File "${CLAUDE_SKILL_DIR}/../jev/scripts/Invoke-JevTriage.ps1" `
     -InputPath ./ERRORLOG -RubricPath "${CLAUDE_SKILL_DIR}/rubrics/sql-errorlog.json" `
     -Pattern 'Error|Severity|fail|deadlock|I/O' -OutputPath ./errorlog.triage.jsonl -AsJson
   ```

   Input formats:
   - `.jsonl` / `.ndjson` / `.json`: use `-StateProperty body` to send one field
     (the default is the whole record) and `-IdProperty id`.
   - `.csv`: same flags.
   - Anything else is plain text, one item per line. Use `-LinesPerItem N` for
     multi-line entries.
   - You can also pipe objects in.

   `-ThrottleLimit` (default 8) caps parallel requests. The service limit is
   about 1,200 requests per minute.

5. **Read only what matters.** With `-OutputPath`, stdout is just the summary.
   Then:

   ```powershell
   Get-Content ./errorlog.triage.jsonl | ConvertFrom-Json | Where-Object bucket -in 'page','act','review','error'
   ```

   Summarize, correlate, and fix those. Report every bucket count, including
   `error` and `review`, and never present a triage run as complete coverage
   when `error` > 0.

6. **Calibrate before trusting.** On the first run of a new rubric, sample about
   10 items from `drop` and 10 from the top bucket and read them yourself. If
   the labels are wrong, fix the question wording or the thresholds and rerun.
   Don't paper over it in the summary.

## Routing rules (rubric `route`)

```json
"route": {
  "rules": [
    { "bucket": "page", "when": { "question": "data_loss_risk", "noulAtLeast": 0.7 } },
    { "bucket": "drop", "when": [ { "question": "category", "choiceIn": ["informational"], "minConfidence": 0.6 },
                                  { "question": "severity", "scoreBelow": 0.8 } ] }
  ],
  "default": "watch",
  "reviewWhen": { "question": "category", "confidenceBelow": 0.35 }
}
```

- Rules run in order and the first match wins. A `when` array means all of its
  conditions must hold.
- Conditions: `noulAtLeast`, `noulBelow`, `choiceIn`, `choiceNotIn`,
  `scoreAtLeast`, `scoreBelow`, `confidenceBelow`, plus an optional
  `minConfidence` gate on choice/score tests.
- Put the dangerous buckets (page, quarantine) first and `drop` after them, so
  an item that is both noise-shaped and dangerous gets paged.
- Score values are level indexes (0 = first level) and can fall between levels.

## Output record

```json
{"id":"L2","bucket":"page","rule":1,"truncated":false,
 "answers":{"category":{"type":"choice","value":"corruption","confidence":0.83}, "...": "..."},
 "error":null,"preview":"first 300 chars of the item"}
```

The preview is truncated. Go back to the source by `id` (for text input, `L<n>`
is the starting line number) before quoting or acting on anything.

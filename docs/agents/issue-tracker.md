# Issue tracker: bd (beads)

Issues and specs for this repo live in **bd**, on the shared Dolt server (`boot_upd` database).
They do NOT live in GitHub Issues, even though the remote is GitHub. On Windows always go through
`./tools/Invoke-Beads.ps1` so the Dolt credential comes from Windows Credential Manager and is
cleared after each call; the tables below write `bd` as shorthand for that wrapper.

There is no local database and no offline fallback. If the Dolt host is unreachable, bd is
unusable - that is a network condition, not a bd problem.

## Conventions

- **Create**: `bd create "<title>" -t bug|task|feature -p 0-4 -d "<description>" [--acceptance "<criteria>"] [--design "<notes>"]`
- **Read**: `bd show <id>`
- **List**: `bd list --status open --json` (add `--all` for closed; `--label` / `--exclude-label` to filter)
- **Comment**: `bd comment <id> "<text>"`
- **Labels**: `bd label add <id> <label>` / `bd label remove <id> <label>` / `bd label list-all`
- **Claim**: `bd update <id> --claim`
- **Close**: `bd close <id> --reason "<what was done and where the evidence is>"`
- **Ready work**: `bd ready`
- **Durable knowledge**: `bd remember "<fact>"` - not MEMORY.md, not TODO lists
- **Export for git**: `bd export -o .beads/issues.jsonl` at session end (mandatory, see AGENTS.md)

Issue ids are `<prefix>-<4 chars>`; the prefix is long, so refer to issues by the short suffix
(`-k610`) in prose and by full id on the command line.

## GitHub sync

`bd github sync` exists but is opt-in and MUST be scoped with `--parent <id>`. A bare sync pushes
every issue in the database into a public repository. The token comes from `gh auth token` via
`GITHUB_TOKEN` at call time and is deliberately not persisted.

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Set to `yes` if this repo treats external PRs as feature requests; `/triage` reads this flag.)_

## When a skill says "publish to the issue tracker"

`bd create`. Put acceptance criteria in `--acceptance`, not in the description.

## When a skill says "fetch the relevant ticket"

`bd show <id>`.

## Wayfinding operations

Used by `/wayfinder`. The **map** is one issue; its **tickets** are child issues.

- **Map**: `bd create "<name>" -t epic --add-label wayfinder:map` (or `bd label add <id> wayfinder:map` afterwards).
- **Child ticket**: `bd create "<question>" --parent <map-id> --add-label wayfinder:<type>` with type one of `research`, `prototype`, `grilling`, `task`.
- **Blocking**: bd's native dependencies. `bd dep add <blocked> <blocker>` (or `bd dep <blocker> --blocks <blocked>`); `bd dep tree <id>` renders it. For a non-blocking relationship use `bd dep relate <a> <b>` - a blocking edge hides the ticket from `bd ready`.
- **Frontier query**: `bd ready` scoped to the map's children - open, unblocked, unassigned.
- **Claim**: `bd update <id> --claim`, the session's first write.
- **Resolve**: `bd comment <id> "<answer>"`, then `bd close <id> --reason "<gist>"`, then append a context pointer to the map's Decisions-so-far.

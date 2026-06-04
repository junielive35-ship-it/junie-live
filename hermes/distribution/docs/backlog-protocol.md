# Hermes Backlog Protocol

This document defines the Hermes-native backlog format and rules for Junie Live.
It replaces all OpenClaw-legacy backlog state.

## Location

```
$HERMES_HOME/junie-live/state/backlog/
```

At runtime, the path resolves via `state.get_profile_dir()`:
`<profile_dir>/junie-live/state/backlog/`

## Structure

```
backlog/
├── items/          # Active item files (one .md per item)
│   ├── BL-20260601-001.md
│   ├── BL-20260601-002.md
│   └── ...
├── archive/        # Done/dropped/obsolete items moved here
│   ├── BL-20260531-001.md
│   └── ...
└── events.jsonl    # Append-only event log for backlog operations
```

## Item schema

Each item is a Markdown file with YAML frontmatter between `---` delimiters.

```markdown
---
id: BL-20260601-001
kind: feature
status: candidate
title: Short descriptive title
source: autonomous
problem: >
  What problem does this solve? Evidence and context.
desired_outcome: >
  What should happen after this is done?
acceptance: |
  - Acceptance criterion 1
  - Acceptance criterion 2
verification: |
  - How to verify criterion 1
  - How to verify criterion 2
scores:
  strategy_fit: 8
  effort: 3
approval_required: false
created: 2026-06-01T12:00:00+0000
updated: 2026-06-01T14:00:00+0000
history: |
  [2026-06-01 12:00:00] Created from autonomous window AW-20260601-001
  [2026-06-01 14:00:00] Status changed to in_progress
---

Optional Markdown body with detailed notes, evidence, or discussion.
```

### Frontmatter fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | yes | Unique item id, e.g. `BL-YYYYMMDD-NNN` |
| `kind` | string | yes | `feature`, `bug`, `chore`, `refactor`, `decision`, `question` |
| `status` | string | yes | One of allowed statuses (see below) |
| `title` | string | yes | One-line descriptive title |
| `source` | string | yes | How the item was created: `autonomous`, `owner`, `cron`, `reflection`, `manual` |
| `problem` | string | no | Problem statement with evidence |
| `desired_outcome` | string | no | What done looks like |
| `acceptance` | string (list) | no | Acceptance criteria |
| `verification` | string (list) | no | Verification steps |
| `scores` | dict | no | `strategy_fit` (1-10), `effort` (1-10), etc. |
| `approval_required` | bool | no | Whether owner approval is needed before execution |
| `created` | string (ISO) | no | Creation timestamp |
| `updated` | string (ISO) | no | Last update timestamp |
| `history` | string | no | Append-only chronological notes |

### Allowed statuses

| Status | Meaning |
|--------|---------|
| `candidate` | Potential work item, not yet validated |
| `validated` | Problem confirmed, solution approach agreed |
| `ready` | Ready for execution |
| `in_progress` | Currently being worked |
| `blocked` | Blocked awaiting owner decision or external dependency |
| `needs_approval` | Needs owner approval before proceeding |
| `done` | Completed and verified |
| `failed` | Attempted but not successfully completed |
| `dropped` | No longer relevant, moved to archive |

## Rules

1. **No OpenClaw fallback.** This backlog is the sole Hermes source of truth.
   Never read `.openclaw`, `~/.openclaw`, `JUNIE_WORKSPACE`, `workspace-junie-live`,
   `openclaw/scripts/backlog.sh`, or raw legacy JSON item files.

2. **No legacy JSON import.** Do not convert or import legacy OpenClaw backlog
   items into this format. Start fresh.

3. **AW window artifacts are not global backlog.** `selection.md` and
   `last_step_result.md` inside a window directory are per-window artifacts.
   They do not replace items in `backlog/items/`. The AW
   `record_outcome` phase should update the actual backlog item.

4. **Append-only event log.** Use `events.jsonl` for tracking backlog operations
   (create, status change, archive). Each line is a JSON object with `ts`,
   `type`, and optional `data`.

5. **Archive, don't delete.** Move done/dropped items to `archive/` instead of
   deleting them. This preserves audit trail.

## Backlog helper module

A Python helper exists at:
`hermes/distribution/plugins/autonomous-work/backlog.py`

It provides:
- Path resolution (`get_backlog_root()`, `get_items_dir()`, etc.)
- `ensure_backlog_dirs()` — create directory structure
- `generate_item_id(kind="BL")` — safe sequential id generation
- `parse_frontmatter(text)` / `format_frontmatter(data)` — YAML frontmatter
  parsing without PyYAML
- `read_item(path)` / `write_item(path, frontmatter, body)` — item CRUD
- `list_items()` / `filter_by_status()` / `list_active_items()` — query helpers
- `update_item_status(path, new_status, history_note)` — status transitions
- `get_candidate_paths()` — AW-specific candidate detection

See the module source for complete API details.

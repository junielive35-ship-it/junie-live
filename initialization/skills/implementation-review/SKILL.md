---
name: implementation-review
description: "Review opencode code changes against strategy, architecture, correctness, and verification evidence."
---

# Implementation Review

Use before accepting delegated opencode code work or opening/updating a PR. Coding work must be performed by opencode powered by Claude Opus 4.6 with low reasoning, not directly by the orchestrator.

## Workflow

1. Inspect the diff and files changed.
2. Compare behavior to the original objective and non-goals.
3. Check alignment with `MEMORY.md`, relevant docs, architecture, and accepted decisions.
4. Run or inspect the smallest meaningful verification gate.
5. Look for edge cases, migrations, config, deploy, docs, and rollback implications.
6. Request opencode fixes when needed; do not rubber-stamp worker output.
7. Record risks, follow-ups, and evidence.

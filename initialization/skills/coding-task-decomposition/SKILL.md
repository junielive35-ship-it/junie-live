---
name: coding-task-decomposition
description: "Break accepted code work into mutex-safe opencode tasks using Claude Opus 4.6 low reasoning."
---

# Coding Task Decomposition

Use after a code-changing task is accepted and before delegating implementation. The orchestrator must never do coding work itself; all coding work goes to opencode powered by Claude Opus 4.6 with low reasoning. Documentation-only Markdown edits are an explicit exception and may be handled directly by the orchestrator when no code/scripts/config/tests/generated files or external systems are changed.

## Workflow

1. Check repo status and code mutex. The mutex is held when `.openclaw/state/code_mutex/` exists; acquire it by atomically creating that directory and writing `holder.json` metadata.
2. Restate objective, constraints, and non-goals.
3. Identify affected components and likely files.
4. Split work into sequential scoped tasks when useful.
5. For each task, prepare an opencode worker brief with relevant context only, specifying Claude Opus 4.6 with low reasoning.
6. Define verification: tests, typecheck, lint, build, manual inspection, or screenshots.
7. Plan review gates before any PR/update.

Do not run parallel code-changing workers against the same repo unless an approved isolation strategy exists.

---
name: junie-coding-task-decomposition
description: "Break accepted code work into mutex-safe delegated tasks."
version: 1.0.0
tags: [junie-live, delegation, coding, decomposition]
---

# Coding Task Decomposition

Use after a code-changing task is accepted and before delegating implementation. The orchestrator must never do coding work itself; all coding work is delegated via `delegate_task` or spawned coding agents.

Documentation-only Markdown edits are an explicit exception and may be handled directly by the orchestrator.

## Workflow

1. Check repo status and code mutex. The mutex is held when `~/.hermes/junie-live/state/code_mutex/holder.json` exists.
2. Acquire the mutex by running `scripts/code-mutex.sh acquire --holder "junie:<task-id>" --reason "<description>"`.
3. Restate objective, constraints, and non-goals.
4. Identify affected components and likely files.
5. Split work into sequential scoped tasks when useful.
6. For each task, prepare a `delegate_task` call with relevant context only.
7. Define verification: tests, typecheck, lint, build, manual inspection.
8. Plan review gates before any PR/update.

Do not run parallel code-changing workers against the same repo unless an approved isolation strategy exists.

## delegate_task template

```python
delegate_task(
    goal="<scoped coding objective>",
    context='''
Project: <repo path>
Task: <what to implement>
Files likely involved: <list>
Constraints: <architecture rules, non-goals>
Verification: <how to verify the work>
After completing, run: git status --short --branch --untracked-files=all
Report outcome_status=done|partial|blocked with any gaps.
''',
    toolsets=["terminal", "file"]
)
```

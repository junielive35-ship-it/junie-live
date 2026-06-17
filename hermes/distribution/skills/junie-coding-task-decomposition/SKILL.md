---
name: junie-coding-task-decomposition
description: "Break accepted code work into Senior Dev Kanban-routed tasks."
version: 1.0.0
tags: [junie-live, delegation, coding, decomposition]
---

# Coding Task Decomposition

Use after a code-changing task is accepted and before delegating implementation. The orchestrator must never do coding work itself; normal source, script, config, and test changes are delegated with `create_senior_task` to the `senior-dev` Kanban lane. Use `delegate_task` only for non-code subtasks.

Documentation-only Markdown edits are an explicit exception and may be handled directly by the orchestrator.

## Workflow

1. Check repo status and active Senior Dev Kanban tasks. Call `senior_active_tasks` for the target repo/origin (use `include_comments=true` when deciding follow-up routing).
2. Restate objective, constraints, and non-goals.
3. Identify affected components and likely files.
4. Split work into sequential scoped tasks when useful.
5. For a new code-changing task, prepare a `create_senior_task` request with relevant context, target repo, constraints, and verification expectations. For a related active task, attach a comment; if a blocked `review-required` / `needs-input` ask has been answered, unblock/requeue it instead of creating a duplicate. For non-code tasks, use `delegate_task`.
6. Define verification: tests, typecheck, lint, build, manual inspection.
7. Plan review gates before any PR/update.

Do not run parallel code-changing workers against the same repo unless an approved isolation strategy exists. In p1, Senior Dev Kanban is the active concurrency boundary for normal Chat Agent code work.

## delegate_task template

For tasks that don't change code (research, analysis, reading), use `delegate_task`:

```python
delegate_task(
    goal="<non-coding objective>",
    context='''
Project: <repo path>
Task: <what to investigate/analyze>
Files likely involved: <list>
Report outcome_status=done|partial|blocked with any gaps.
''',
    toolsets=["terminal", "file"]
)
```

## create_senior_task template (all code-changing work)

All new code-changing work is delegated through the Senior Dev Kanban lane after active-task lookup:

```python
create_senior_task(
    title="<short user-visible task title>",
    repo="/abs/path/to/repo",
    request="""
<objective, constraints, likely files, verification expectations>
""",
)
```

For follow-up/fix loops, prefer the existing active Kanban task: add a comment with the fix/follow-up context and unblock/requeue when the previous `blocked` reason has been answered. Create a new task only when the prior task is done/archived or the new request is semantically separate.

---
name: junie-coding-task-decomposition
description: "Break accepted code work into mutex-safe delegated tasks."
version: 1.0.0
tags: [junie-live, delegation, coding, decomposition]
---

# Coding Task Decomposition

Use after a code-changing task is accepted and before delegating implementation. The orchestrator must never do coding work itself; all coding work is delegated via `marinator_delegate` or `delegate_task` for non-code subtasks.

Documentation-only Markdown edits are an explicit exception and may be handled directly by the orchestrator.

## Workflow

1. Check repo status and code mutex. The mutex is held when `$HERMES_PROFILE_DIR/junie-live/state/code_mutex/holder.json` exists (profile-local; default: `~/.hermes/profiles/junie-live/junie-live/state/code_mutex/holder.json`).
2. Acquire the mutex by running `$HERMES_PROFILE_DIR/scripts/code-mutex.sh acquire --holder "junie:<task-id>" --reason "<description>"`.
3. Restate objective, constraints, and non-goals.
4. Identify affected components and likely files.
5. Split work into sequential scoped tasks when useful.
6. For each code-changing task, prepare a `marinator_delegate` invocation with relevant context. For non-code tasks, use `delegate_task`.
7. Define verification: tests, typecheck, lint, build, manual inspection.
8. Plan review gates before any PR/update.

Do not run parallel code-changing workers against the same repo unless an approved isolation strategy exists.

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

## marinator_delegate template (all code-changing work)

All code-changing work is delegated via `marinator_delegate`. Write a prompt file, then call the tool:

```python
marinator_delegate(
    job_id="<short-stable-id>",
    repo="/abs/path/to/repo",
    prompt_file="/abs/path/to/PROMPT.md",
    enable_per_minute_reports=True,
)
```

For follow-up/fix loops, pass `opencode_previous_session_id` to continue the prior OpenCode context.

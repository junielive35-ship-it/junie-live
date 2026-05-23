# Delegation Protocol

Use this file to guide coding-worker or subagent delegation for the assigned project.

## Principles

- The orchestrator owns strategy, context, planning, delegation, final review, and acceptance.
- The orchestrator must never do coding work itself.
- All coding work is delegated to opencode powered by Claude Opus 4.6 with low reasoning.
- Workers get scoped tasks, not the whole project history by default.
- Code-changing opencode workers run sequentially under the code mutex unless an approved isolation strategy exists. The mutex is the atomic lock directory `.openclaw/state/code_mutex/` with holder metadata in `holder.json`.
- Prompts should include relevant goal, constraints, architecture notes, verification expectations, and non-goals.

## Delegation brief template

```markdown
Objective:

Relevant context:

Files/areas likely involved:

Constraints and non-goals:

Expected output:

Verification required:

Risks/questions to report:
```

## Project-specific notes

TODO

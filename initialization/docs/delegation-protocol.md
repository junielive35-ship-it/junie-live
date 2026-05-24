# Delegation Protocol

Use this file to guide coding-worker or subagent delegation for the assigned project.

## Principles

- The orchestrator owns strategy, context, planning, delegation, final review, and acceptance.
- The orchestrator must never do coding work itself.
- All coding work is delegated to opencode powered by Claude Opus 4.6 with low reasoning.
- Documentation-only Markdown edits are an explicit exception: the orchestrator may directly edit Markdown docs/guidance when no source code, scripts, tests, config, generated files, or external systems are changed.
- Workers get scoped tasks, not the whole project history by default.
- Code-changing opencode workers run sequentially under the code mutex unless an approved isolation strategy exists. The mutex is the atomic lock directory `.openclaw/state/code_mutex/` with holder metadata in `holder.json`.
- Markdown-only direct edits still need normal strategic/context review and must follow approval rules for semantic changes.
- Prompts should include relevant goal, constraints, architecture notes, verification expectations, and non-goals.
- Worker handoffs must include `git status --short --branch --untracked-files=all` for the owned repo after work. The final status should be clean or list only intentional changes.
- Workers must treat root workspace artifacts such as `AGENTS.md`, `USER.md`, `.openclaw/`, and similar runtime files in the repo root as mistakes unless the repo intentionally tracks them. They must prevent or clean these artifacts, not hide them with `.gitignore`, `.git/info/exclude`, or other exclude masks.
- Autonomous/worker commit subjects must summarize actual changes; reject generic iteration counters such as `Autonomous MVP loop iteration N`.

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

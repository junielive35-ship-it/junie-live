# Delegation Protocol

Use this file to guide opencode worker delegation for the assigned project. Native OpenClaw subagents are not part of the project implementation workflow.

## Principles

- The orchestrator owns strategy, context, planning, delegation, final review, and acceptance.
- The orchestrator must never do coding work itself.
- All coding work is delegated to opencode powered by Claude Opus 4.6 with low reasoning.
- Native OpenClaw subagents (`sessions_spawn` with `runtime="subagent"`) are forbidden for project work and must not be used as implementation workers.
- If work needs a subagent/worker, use the opencode worker boundary; if the change is documentation-only Markdown, the orchestrator may edit it directly under the Markdown exception.
- Documentation-only Markdown edits are an explicit exception: the orchestrator may directly edit Markdown docs/guidance when no source code, scripts, tests, config, generated files, or external systems are changed.
- Workers get scoped tasks, not the whole project history by default.
- Code-changing opencode workers run sequentially under the code mutex unless an approved isolation strategy exists. The mutex is the atomic lock directory `.openclaw/state/code_mutex/` with holder metadata in `holder.json`.
- Markdown-only direct edits still need normal strategic/context review and must follow approval rules for semantic changes.
- Prompts should include relevant goal, constraints, architecture notes, verification expectations, and non-goals.
- Prompts must include the requested user outcome in concrete terms and ask the worker to report `outcome_status=done|partial|blocked`, with gaps if not done.
- Worker handoffs must distinguish user-visible outcome evidence from internal/scaffolding evidence. Passing helper-script tests is not enough when the user requested an end-to-end behavior.
- Worker handoffs must include `git status --short --branch --untracked-files=all` for the owned repo after work. The final status should be clean or list only intentional changes.
- Workers must treat root workspace artifacts such as `AGENTS.md`, `USER.md`, `.openclaw/`, and similar runtime files in the repo root as mistakes unless the repo intentionally tracks them. They must prevent or clean these artifacts, not hide them with `.gitignore`, `.git/info/exclude`, or other exclude masks.
- Autonomous/worker commit subjects must summarize actual changes; reject generic iteration counters such as `Autonomous MVP loop iteration N`.
- New code-changing entrypoints must not invent ad hoc implementation-worker paths. They must reuse or implement the shared implementation acceptance loop: worker/delegation/review/fix/acceptance, including review-driven fix requests and explicit acceptance before the task is called done.
- Delegation briefs for new triggers or paths must call out cross-cutting invariants and bypass risks that the worker must preserve.
- When a worker or delegation boundary exits without completing the requested outcome — whether due to timeout, error, resource limit, blocker, or session end — the handoff must report the work as partial or blocked with explicit remaining steps. Never silently abandon half-finished work or leave it unreported.

## Delegation brief template

```markdown
Objective:

Relevant context:

Files/areas likely involved:

Constraints and non-goals:

Expected output:

Requested user outcome / acceptance criteria:

Verification required, including user-outcome evidence:

Outcome status to report (`done`, `partial`, or `blocked`) and any gaps:

Risks/questions to report:
```

## Project-specific notes

TODO

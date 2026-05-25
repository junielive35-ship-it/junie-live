# Delegation Protocol

Use this file to guide coding-worker delegation for the assigned project.

## Principles

- The orchestrator (Hermes main session) owns strategy, context, planning, delegation, final review, and acceptance.
- The orchestrator must never do coding work itself.
- All coding work is delegated via `delegate_task` to subagents, or via spawned coding agent processes for long-running work.
- Documentation-only Markdown edits are an explicit exception: the orchestrator may directly edit Markdown docs/guidance when no source code, scripts, tests, config, generated files, or external systems are changed.
- Workers get scoped tasks, not the whole project history by default.
- Code-changing workers run sequentially under the code mutex. The mutex state lives at `~/.hermes/junie-live/state/code_mutex/`.
- Markdown-only direct edits still need normal strategic/context review and must follow approval rules for semantic changes.
- Prompts should include relevant goal, constraints, architecture notes, verification expectations, and non-goals.
- Prompts must include the requested user outcome in concrete terms and ask the worker to report `outcome_status=done|partial|blocked`, with gaps if not done.
- Worker handoffs must distinguish user-visible outcome evidence from internal/scaffolding evidence.
- Workers must check `git status --short --branch --untracked-files=all` after work. Final status should be clean or list only intentional changes.
- Autonomous/worker commit subjects must summarize actual changes; reject generic iteration counters.
- New code-changing entrypoints must not invent ad hoc implementation-worker paths. They must reuse or implement the shared implementation acceptance loop: worker/delegation/review/fix/acceptance.
- Delegation briefs for new triggers or paths must call out cross-cutting invariants and bypass risks.

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

## Using delegate_task

For bounded coding subtasks (under ~5 minutes), use `delegate_task`:

```
delegate_task(
  goal="Implement the email validation endpoint",
  context="Project at ~/code/myapp. FastAPI backend. See docs/architecture.md for the auth module layout. Must include unit tests.",
  toolsets=["terminal", "file"]
)
```

For longer work or work requiring interactive tools, spawn a separate Hermes process:

```
terminal(command="hermes chat -q 'Implement the full auth module per the spec at ~/code/myapp/docs/auth-spec.md'", background=true, notify_on_complete=true)
```

## Project-specific notes

TODO

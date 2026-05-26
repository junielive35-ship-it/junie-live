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

## Coding executor: opencode

All code-changing work is executed via [OpenCode CLI](https://opencode.ai) using `~/.opencode/bin/opencode run`.

Default model and settings:
- **Model:** `openrouter/anthropic/claude-opus-4.6`
- **Reasoning effort:** `--variant minimal` (low reasoning)
- **Agent:** `build` (default, handles implementation)

### One-shot tasks (preferred)

For bounded coding subtasks, use `~/.opencode/bin/opencode run` via terminal:

```
terminal(
  command="~/.opencode/bin/opencode run '<scoped coding objective>' --model openrouter/anthropic/claude-opus-4.6 --variant minimal -f <relevant_files>",
  workdir="<target repo path>",
  timeout=300
)
```

Example:

```
terminal(
  command="~/.opencode/bin/opencode run 'Implement the email validation endpoint in src/api/auth.py with unit tests in tests/test_auth.py. FastAPI backend, see docs/architecture.md for module layout.' --model openrouter/anthropic/claude-opus-4.6 --variant minimal -f src/api/auth.py -f tests/test_auth.py",
  workdir="~/code/myapp",
  timeout=300
)
```

### Long-running tasks

For work expected to take longer than 5 minutes, run in background with notification:

```
terminal(
  command="~/.opencode/bin/opencode run '<detailed objective>' --model openrouter/anthropic/claude-opus-4.6 --variant minimal",
  workdir="<target repo path>",
  background=true,
  notify_on_complete=true
)
```

### Attaching context

Use `-f` flags to attach files the worker needs to see:

```
~/.opencode/bin/opencode run '<objective>' -f src/module.py -f docs/spec.md -f tests/test_module.py
```

### Overriding defaults

When a task needs higher reasoning effort (complex refactoring, architecture changes):

```
~/.opencode/bin/opencode run '<objective>' --model openrouter/anthropic/claude-opus-4.6 --variant high
```

## Project-specific notes

TODO

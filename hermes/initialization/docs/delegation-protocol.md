# Delegation Protocol

Use this file to guide coding-worker delegation for the assigned project.

## Principles

- The orchestrator (Hermes main session) owns strategy, context, planning, delegation, final review, and acceptance.
- The orchestrator must never do coding work itself.
- All coding work is delegated via `marinator_delegate` (the Marinator delegation tool), which starts a supervised OpenCode worker run and wakes the owning Hermes session for review. Direct `opencode run` invocation from the orchestrator is replaced by this tool.
- Documentation-only Markdown edits are an explicit exception: the orchestrator may directly edit Markdown docs/guidance when no source code, scripts, tests, config, generated files, or external systems are changed.
- Workers get scoped tasks, not the whole project history by default.
- Code-changing workers run sequentially under the code mutex. The mutex state lives at `~/.hermes/profiles/junie-live/junie-live/state/code_mutex/` (profile-local). See `docs/code-mutex-protocol.md` for the full mutex invariants (atomicity, holder identity, escalation when held, no `delegate_task` substitution).
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

## Coding executor: marinator_delegate (Marinator plugin)

All code-changing work is executed via the `marinator_delegate` tool, which is installed as a Hermes user plugin by `hire-junie.sh`. This is the only approved code-changing delegation path.

`marinator_delegate` starts a supervised OpenCode process in the background, captures logs, monitors progress, detects stalls (without killing), and wakes the orchestrator on completion or failure. The orchestrator reviews the result, decides accept/fix/wait/kill/block, and does not report success unless the requested user-visible outcome is verified.

### Tool schema

```json
{
  "job_id": "stable-identifier",
  "repo": "/abs/path/to/repo",
  "prompt_file": "/abs/path/to/prompt.md",
  "attachments": ["/optional/path"],
  "opencode_previous_session_id": null,
  "enable_per_minute_reports": true
}
```

- `job_id`: stable identifier for the delegation job (alphanumeric/hyphen/underscore/dot).
- `repo`: absolute path to the target repository.
- `prompt_file`: absolute path to a prompt file (.md) written by the orchestrator before calling the tool.
- `attachments`: optional list of absolute paths to attach as context.
- `opencode_previous_session_id`: optional; for follow-up/fix loops, pass the previous OpenCode session id.
- `enable_per_minute_reports`: defaults to `true` for debug visibility. Do not set to `false` unless the human explicitly asked to disable progress/debug messages.

### Workflow

1. Write the delegation prompt to a file (e.g. under the run state directory or a temp path).
2. Call `marinator_delegate` with the prompt file path and repo.
3. The tool returns immediately with `job_id`, `run_dir`, `runtime_mode`, and `status_path`.
4. In live Telegram sessions, `notify_on_complete` wakes the orchestrator when the worker finishes.
5. In headless sessions, the wrapper calls `hermes chat --resume` to continue the orchestrator session.
6. On wake, the orchestrator reads `status.json`, `result.md`, stdout/stderr logs, inspects the repo diff, and decides: accept, fix (re-delegate with `opencode_previous_session_id`), wait, kill, or block.

### Follow-up / fix loops

When a worker result is rejected, delegate a fix run:

```json
{
  "job_id": "fix-<original-job-id>-1",
  "repo": "/abs/path/to/repo",
  "prompt_file": "/abs/path/to/fix-prompt.md",
  "opencode_previous_session_id": "<session_id from previous result>"
}
```

### Key constraints

- Do not pass model/variant flags; OpenCode uses its configured defaults.
- Do not include chat ids, tokens, or profile names in the tool call.
- Runtime mode (live_gateway vs headless) is auto-detected.
- Suspected stalls are recorded but never auto-kill; the orchestrator decides.

## Deferred

- **Kanban-backed Marinator**: deferred for MVP. The delegation protocol remains a single linear orchestrator session.
- **Cron-bound session continuation**: deferred. Live sessions use `notify_on_complete`; headless sessions use `hermes chat --resume`.

## Project-specific notes

TODO

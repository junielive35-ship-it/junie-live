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

## Bundled Marinator delegation runtime

A hired Junie Live workspace includes the standard Marinator delegation runtime:

- `marinator-delegation/` — OpenClaw plugin exposing the `marinator_delegate` tool.
- `marinator-delegation/scripts/delegate-coding-task.sh` — supervised opencode runner bundled inside the plugin.
- `.openclaw/state/marinator/runs/<job_id>/` — per-run state, logs, events, and result artifacts.

`hire-junie.sh` is responsible for copying these assets from the seed, linking the plugin from the workspace copy, and patching runtime config so `marinator_delegate` is usable with `tools.profile: "coding"`:

- `tools.alsoAllow` includes `marinator-delegation`;
- `agents.defaults.models["openrouter/openai/gpt-4.1-mini"] = {}` is present for progress-summary inference;
- the plugin install/link uses the explicit unsafe-install bypass because the runner starts an external child process.

The plugin creates a resolved `spec.json` from the current OpenClaw delivery context, starts the runner detached, and returns the run directory. The runner is responsible for bounded execution, progress summaries, terminal status, and waking the orchestrator on completion or failure. Progress summaries are observability only; they must not change Marinator task/subtask granularity, which remains based on review and acceptance boundaries.

A Marinator run must not remain in `running` after the worker process exits. The runner records `opencode.exit`, writes terminal `status.json` state, appends `events.jsonl`, and wakes Marinator for `completed`, `failed`, `timeout`, `killed`, or `stalled` outcomes. If the runner exits unexpectedly before a terminal state, it must fail closed and report `runner_exited_unexpectedly` rather than silently abandoning the task.

## Executor isolation (runner talks only to the orchestrator)

The executor layer (the opencode runner) communicates **only with the orchestrator**, never directly with the end user. The orchestrator is the sole party that messages the user. In future flows the orchestrator may also go back to the runner to request fixes/redos, and all of that must happen without user involvement.

The runner signals the orchestrator by waking it: `openclaw system event --session-key <orchestrator_session_key> --mode now` (see `wake_marinator` in `delegate-coding-task.sh`). The orchestrator then reads `result.md` and the repo diff and decides what, if anything, to report to the user.

Known debug-only exception (temporary): the current runner still calls `send_telegram` directly for progress summaries and terminal alerts. These are explicitly marked `DEBUG-ONLY (TEMPORARY)` in the runner and are treated as a user-facing progress log only. They technically violate the executor-isolation invariant and are slated to be removed once the orchestrator-driven delivery path is considered final. Do not add new direct runner-to-user sends.

## How the orchestrator wake actually reaches the user

The wake is delivered as a **heartbeat-class turn** in the orchestrator's real session. Two facts matter:

- A registered per-agent heartbeat is required for the wake to run at all. `openclaw system event` only enqueues text on the target session's queue; the heartbeat runner is what drains that queue and runs a turn. So the agent must have a non-zero `heartbeat.every`. The wake itself fires immediately (`--mode now`, intent `immediate`), not on the periodic schedule.
- The wake turn must run in the agent's **real shared session** (`isolatedSession: false`, `lightContext: false`). With an isolated session the pending system event is not inspected/injected and the wake is silently dropped until an unrelated inbound message drains it.
- **Session is not the delivery channel.** Whether the orchestrator's reply reaches the user is governed solely by `heartbeat.target`. With `target: "none"` the turn runs but the reply is never delivered (this was the original supervisor-wake bug). Use `target: "last"` so the orchestrator's report reaches the chat that started the delegation, and suppress routine `HEARTBEAT_OK` ticks via channel heartbeat visibility (`showOk: false`) so periodic heartbeats stay silent.

`hire-junie.sh` bakes this in: it registers the heartbeat with all fields set explicitly (no reliance on OpenClaw API defaults) — `every: 6h`, `target: last`, `includeSystemPromptSection: false`, `isolatedSession: false`, `lightContext: false`, `directPolicy: allow`, `skipWhenBusy: false` — and sets the Telegram account heartbeat visibility to `showOk: false, showAlerts: true, useIndicator: false`.

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

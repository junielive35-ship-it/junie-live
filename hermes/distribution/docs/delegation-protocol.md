# Delegation Protocol

Use this file to guide OpenCode worker delegation for the assigned project. Native Hermes subagents are not part of the project implementation workflow for code-changing work.

## Principles

- The Chat Agent owns strategy, intake, routing, user communication, and product/backlog coherence.
- The Chat Agent must never do coding work itself.
- Normal user-visible code work is routed through `create_senior_task`, which creates one Hermes Kanban task assigned to `senior-dev` and subscribes the originating chat/thread for terminal events.
- The `senior-dev` Hermes profile owns implementation execution and engineering acceptance for its assigned task. It uses `marinator_delegate` to start a supervised OpenCode worker run, then calls `senior_dev_task_result` to mark the Kanban task completed or blocked.
- Native Hermes subagents (`delegate_task`) are forbidden as code-changing implementation workers. They may be used only for non-code subtasks such as research, analysis, reading, or planning.
- The Chat Agent does not expose `marinator_delegate` in normal CLI/Telegram toolsets. For normal code tasks, route through the Senior Dev Kanban lane. Documentation-only Markdown edits remain a direct-edit exception.
- Documentation-only Markdown edits are an explicit exception: the orchestrator may directly edit Markdown docs/guidance when no source code, scripts, tests, config, generated files, or external systems are changed.
- Workers get scoped tasks, not the whole project history by default.
- Code-changing OpenCode workers run sequentially under the code mutex unless an approved isolation strategy exists. The mutex state lives at `~/.hermes/profiles/junie-live/junie-live/state/code_mutex/` (profile-local) with holder metadata in `holder.json`. See `docs/code-mutex-protocol.md` for the full mutex invariants: atomicity, holder identity, escalation when held, and no `delegate_task` substitution.
- Markdown-only direct edits still need normal strategic/context review and must follow approval rules for semantic changes.
- Prompts should include relevant goal, constraints, architecture notes, verification expectations, and non-goals.
- Prompts must include the requested user outcome in concrete terms and ask the worker to report `outcome_status=done|partial|blocked`, with gaps if not done.
- Worker handoffs must distinguish user-visible outcome evidence from internal/scaffolding evidence. Passing helper-script tests is not enough when the user requested an end-to-end behavior.
- Worker handoffs must include `git status --short --branch --untracked-files=all` for the owned repo after work. The final status should be clean or list only intentional changes.
- Workers must treat root workspace artifacts such as `AGENTS.md`, `USER.md`, `.openclaw/`, `.hermes/`, and similar runtime files in the repo root as mistakes unless the repo intentionally tracks them. They must prevent or clean these artifacts, not hide them with `.gitignore`, `.git/info/exclude`, or other exclude masks.
- Autonomous/worker commit subjects must summarize actual changes; reject generic iteration counters such as `Autonomous MVP loop iteration N`.
- New code-changing entrypoints must not invent ad hoc implementation-worker paths. They must reuse or implement the shared implementation acceptance loop: worker/delegation/review/fix/acceptance, including review-driven fix requests and explicit acceptance before the task is called done.
- Delegation briefs for new triggers or paths must call out cross-cutting invariants and bypass risks that the worker must preserve.
- When a worker or delegation boundary exits without completing the requested outcome — whether due to timeout, error, resource limit, blocker, or session end — the handoff must report the work as partial or blocked with explicit remaining steps. Never silently abandon half-finished work or leave it unreported.

## Bundled Marinator delegation runtime

A hired Junie Live Hermes profile includes the standard Marinator delegation runtime:

- `plugins/marinator-delegation/` — Hermes user plugin exposing the `marinator_delegate` tool.
- `plugins/marinator-delegation/scripts/marinator-worker.sh` — supervised OpenCode runner bundled inside the plugin.
- `~/.hermes/profiles/junie-live/junie-live/state/marinator/runs/<job_id>/` — per-run state, logs, events, and result artifacts.

`hire-junie.sh` is responsible for copying these assets from the seed into the Hermes profile and enabling the main Chat Agent toolsets (`senior`, `autonomous`, `terminal`, and `file`) for CLI and Telegram. It must not enable the main profile `marinator` toolset; `install-senior-dev-profile.sh` enables `marinator` for the companion `senior-dev` profile.

The plugin creates a resolved `spec.json` from the current Hermes delivery context, starts the runner, and returns the run directory plus status path. The runner is responsible for bounded execution, progress summaries, terminal status, and waking the orchestrator on completion or failure. Progress summaries are observability only; they must not change Marinator task/subtask granularity, which remains based on review and acceptance boundaries.

A Marinator run must not remain in `running` after the worker process exits. The runner records `opencode.exit`, writes terminal `status.json` state, appends `events.jsonl`, writes `result.md`, and wakes or resumes the orchestrator for `completed`, `failed`, `timeout`, `killed`, or `stalled` outcomes. If the runner exits unexpectedly before a terminal state, it must fail closed and report the unexpected runner exit rather than silently abandoning the task.

## Executor isolation (runner talks only to the orchestrator)

The executor layer (the OpenCode runner) communicates **only with the orchestrator**, never directly with the end user as the source of truth. The orchestrator is the sole party that decides what counts as accepted and what final status to report to the user. In future flows the orchestrator may also go back to the runner to request fixes/redos, and all of that must happen without user involvement.

The runner signals the orchestrator by using Hermes process completion semantics:

- in live Telegram/gateway sessions, the wrapper is dispatched through `terminal(background=true, notify_on_complete=true)`, so Hermes wakes the owning session when the process exits;
- in headless sessions, the wrapper resumes the owning Hermes session with `hermes -p <profile> chat --resume <owner_session_id>`.

Headless resume is fire-and-forget: the wrapper must launch the resume helper asynchronously and immediately return to supervising OpenCode. A resumed orchestrator may decide to write `control/kill`; the wrapper must continue polling that control file while the resumed Hermes session is still thinking or using tools.

The orchestrator then reads `status.json`, `result.md`, stdout/stderr logs, and the repo diff, and decides what, if anything, to report to the user.

Known debug-only exception (temporary): the current runner can send periodic progress summaries via Hermes messaging when `enable_per_minute_reports=true`. These are user-facing progress logs only. They technically violate the strict executor-isolation invariant and should not become task acceptance, fix-loop, or completion signals. Do not add new direct runner-to-user sends; route substantive status, decisions, and completion through the orchestrator.

## How the orchestrator wake actually reaches the user

The wake is delivered through Hermes background-process completion or headless session resume, not through an OpenClaw heartbeat. Three facts matter:

- **Live gateway sessions:** `marinator_delegate` dispatches `marinator-worker.sh` via Hermes `terminal(background=true, notify_on_complete=true)`. The background-process completion notification wakes the same live session that started the delegation.
- **Headless sessions:** the wrapper uses `hermes -p <profile> chat --resume <owner_session_id>` with a prompt that tells the orchestrator to review status/result/logs/diff and decide accept/fix/wait/kill/block.
- **Progress is not acceptance.** Per-minute reports are observability only. Completion still requires the orchestrator to review artifacts and verify the requested user-visible outcome.

This means the Hermes version does not need OpenClaw heartbeat registration fields such as `heartbeat.every`, `target: last`, `isolatedSession`, or `lightContext`; those are OpenClaw-specific mechanics. The invariant is the same: the completion path must reach the orchestrator's real shared session, and the orchestrator must be the final reporter.

## Fix-loop escalation

The delegate → review → request-fixes flow is orchestrator-driven judgment, not a fixed-count loop. There is no enforced numeric retry budget; the orchestrator decides when to retry, restructure, or stop.

The one heuristic worth making explicit, because it is easy to skip: do not just keep re-sending a richer version of the same task. If a fix request fails to land, switch strategy instead of reformulating harder.

Ladder when a delegated task is not done properly:

1. Request a fix with sharper detail, constraints, and the concrete failure evidence (roughly 1–2 focused attempts).
2. If it still fails the same way, stop reformulating and diagnose *why*: ambiguous/under-specified outcome, too-large or mis-scoped task, missing context the worker needed, or a wrong overall approach.
3. If scope or complexity is the cause, decompose the work into smaller, independently verifiable scoped tasks and delegate those.
4. If the cause is an unclear spec, infeasibility, or a missing decision, do not keep delegating — block the task and surface it to the owner with a truthful partial/blocked report and the specific question.

The goal is to recognize when to move from “retry harder” to “restructure or escalate,” rather than burning repeated worker runs on the same failing shape. Keep this judgment-based; do not turn it into a hard attempt counter unless the owner asks for one.

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

## Coding executor: Senior Dev Kanban lane + marinator_delegate

Normal code-changing work is executed through the Senior Dev Kanban lane:

1. Chat Agent calls `create_senior_task` with the user-visible request and target repo.
2. Hermes Kanban dispatches the task to the `senior-dev` profile.
3. `senior-dev` builds a scoped Marinator prompt and calls `marinator_delegate` with Kanban linkage.
4. `marinator_delegate` starts supervised OpenCode, captures logs, monitors progress, detects stalls (without killing), and wakes/resumes the worker profile on completion or failure.
5. `senior-dev` reviews the Marinator artifacts and calls `senior_dev_task_result` with `completed` or `blocked`.
6. Kanban terminal events notify the originating chat/thread.

`marinator_delegate` remains the OpenCode supervision boundary, but the Chat Agent should not bypass the Senior Dev Kanban lane for ordinary user code tasks.

### Tool schema

```json
{
  "job_id": "stable-identifier",
  "repo": "/abs/path/to/repo",
  "prompt_file": "/abs/path/to/prompt.md",
  "attachments": ["/optional/path"],
  "is_follow_up": false,
  "enable_per_minute_reports": true
}
```

- `job_id`: stable identifier for the delegation job (alphanumeric/hyphen/underscore/dot).
- `repo`: absolute path to the target repository.
- `prompt_file`: absolute path to a prompt file (`.md`) written by the orchestrator before calling the tool.
- `attachments`: optional list of absolute paths to attach as context.
- `is_follow_up`: if true, continue the most recent valid OpenCode session for this repo/task lineage. Default false. The tool resolves session ids internally; do not supply session ids.
- `enable_per_minute_reports`: defaults to `true` for debug visibility. Do not set to `false` unless the human explicitly asked to disable progress/debug messages.

### Workflow

This workflow is for the `senior-dev` profile, not the main Chat Agent:

1. Write the delegation prompt to a file, usually under `/tmp` or the profile run state directory.
2. Call `marinator_delegate` with the prompt file path and repo.
3. The tool returns immediately with `job_id`, `run_dir`, `runtime_mode`, and `status_path`.
4. In live Telegram sessions, `notify_on_complete` wakes the worker profile when the OpenCode run finishes.
5. In headless sessions, the wrapper calls `hermes chat --resume` to continue the worker profile session.
6. On wake, `senior-dev` reads `status.json`, `result.md`, stdout/stderr logs, inspects the repo diff, and decides: accept, fix, wait, kill, or block before calling `senior_dev_task_result`.

### Follow-up / fix loops

When a worker result is rejected, delegate a fix run with `is_follow_up: true`.
The tool resolves the prior OpenCode session id internally from the most recent
Marinator run for the same repo. Do not supply session ids directly.

```json
{
  "job_id": "fix-<original-job-id>-1",
  "repo": "/abs/path/to/repo",
  "prompt_file": "/abs/path/to/fix-prompt.md",
  "is_follow_up": true
}
```

### Key constraints

- Do not pass model/variant flags; OpenCode uses its configured defaults.
- Do not include chat ids, tokens, or profile names in the tool call.
- Runtime mode (`live_gateway` vs `headless`) is auto-detected.
- Suspected stalls are recorded but never auto-kill; the orchestrator decides.

## Deferred

- **Cron-bound session continuation**: deferred. Live sessions use `notify_on_complete`; headless sessions use `hermes chat --resume`.
- **PR/CI monitoring automation**: not configured by default; report PR/CI state only from verified local/remote evidence.

## Project-specific notes

TODO

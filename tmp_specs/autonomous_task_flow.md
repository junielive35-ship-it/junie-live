# Autonomous Work Window Plan — TaskFlow Variant

This is a TaskFlow-based variant of `autonomous.md`. It keeps the same product goal and final agreements, but uses OpenClaw TaskFlow as the primary durable lifecycle/state substrate for autonomous work (AW).

## Goal

Enable an owner request like “work autonomously for 3 hours” to start one bounded AW window where Junie repeatedly:

1. snapshots project state;
2. generates/updates backlog candidates;
3. selects eligible work by strategy/architecture/status fit;
4. executes selected code work only through the normal Junie/Marinator delegation loop;
5. reviews/verifies/records outcome;
6. continues until deadline, blocker, cancellation, or no eligible work.

AW is a planning/control layer around normal Junie behavior. It is not a replacement executor.

## Why TaskFlow

TaskFlow is OpenClaw’s durable orchestration layer above background tasks. It provides:

- owner session and requester origin;
- `currentStep`, `stateJson`, and `waitJson`;
- linked child tasks;
- waiting/blocked/finished/failed/cancelled lifecycle;
- revision-checked mutations;
- restart survival;
- CLI inspection/cancel via `openclaw tasks flow list/show/cancel`.

Use TaskFlow for AW because AW is multi-step, long-lived, owner-bound, waits on detached work/wakes, and needs durable state. Do not use TaskFlow as business logic: AW selection, scoring, prompt generation, and transition policy remain in the AW plugin/tool code and orchestrator protocol.

## Non-goals for this milestone

- No cron/checkpoint watchdog in M4. Deadline is checked on each AW step/wake.
- No parallel subagents in M4.
- No shell controller that makes product decisions.
- No direct code/script/test/config edits by the orchestrator; code work still goes through Marinator/opencode under the mutex.
- No AW-specific Marinator review state machine. Once a task is selected, normal Junie/Marinator delegation/review/fix/acceptance behavior owns it.

## Backlog planning surface

Durable backlog lives in the product repo, preferably Markdown unless an external tracker is chosen later:

```text
backlog/
  README.md
  items/
    BL-YYYYMMDD-001.md
  events.jsonl        # optional durable planning history, not runner logs
```

MVP uses one item shape with:

```text
kind: hypothesis | task | bug | chore | decision | cleanup
status: candidate | validated | ready | in_progress | blocked | done | archived
```

Each item should capture problem, evidence, strategy/architecture/status fit, acceptance, verification, approval/mutex gates, scores, and execution history.

Repo backlog stores durable planning state only. Runtime execution state belongs to TaskFlow and `.openclaw/state/...`, not repo root.

## Milestones

### M1 — Backlog contract

- Define `backlog/README.md`, item schema, lifecycle, scoring, and hygiene.
- Add initial backlog items from `implementation-status.md` gaps.

### M2 — Candidate generation

- Add behavior/protocol/skill for generating backlog candidates from implementation gaps, routines, Marinator results, doc drift, owner requests, and repo inspection.
- No daemon yet.
- Strategy/architecture/status fit is primary; `autonomous_fit` is only a gate/modifier.

### M3 — Prioritization/select-next

- Define eligibility gates: approval, mutex, verification clarity, time budget, repo scope, no Hermes edits unless explicit, no external/PR/deploy without authority.
- Select next work explainably and record why skipped items were ineligible.

### M4 — TaskFlow-backed AW v1

- Add AW tool plugin exposing `autonomous_work_start` and `autonomous_work_step`.
- Use TaskFlow managed flows as primary AW lifecycle/state.
- Use a thin supervised AW runner only for launching bounded OpenClaw steps and emitting deterministic continuation wakes.
- Verify wake/session behavior before claiming M4 works.

### M5 — Hardening

- cancellation UX;
- restart recovery tests;
- stuck-state handling;
- dry run;
- better failure budgets;
- optional cron/checkpoint watchdog later.

## TaskFlow state model

Create one managed TaskFlow per AW window.

Recommended mapping:

```text
TaskFlow.ownerKey/requesterOrigin = owner/orchestrator session + original delivery context
TaskFlow.controllerId             = "junie-live/autonomous-work"
TaskFlow.goal                     = owner AW request summary
TaskFlow.currentStep              = AW phase
TaskFlow.stateJson                = AW window state
TaskFlow.waitJson                 = external wait / selected-task wait metadata
```

Minimal AW phases in `currentStep`:

```text
planning
executing_task
finalizing
blocked
completed
cancelled
failed
```

Minimal `stateJson` shape:

```json
{
  "window_id": "AW-...",
  "prompt": "owner instruction, e.g. use feature_28_may branch",
  "status": "running",
  "phase": "planning",
  "started_at": "...",
  "end_at": "...",
  "selected_item": null,
  "continuation": "continue_now | wait_external | final | blocked",
  "failure_count": 0,
  "completed_items": [],
  "blocked_items": [],
  "artifact_dir": ".openclaw/state/autonomous/artifacts/AW-...",
  "last_step_started_at": "...",
  "last_step_finished_at": "..."
}
```

Use TaskFlow revision checks for every mutation. Carry forward the latest `flow.revision` after each `resume`, `setWaiting`, `finish`, or `fail`.

Heavy logs/artifacts may still live in workspace runtime files:

```text
.openclaw/state/autonomous/artifacts/<window_id>/
  events.jsonl
  logs/
  selection.md
  final-report.md
```

TaskFlow is the lifecycle source of truth; files are supporting artifacts.

## AW tool plugin

Implement as an OpenClaw tool plugin, not ad hoc shell commands:

```text
autonomous-work/
  src/index.ts                  # defineToolPlugin: autonomous_work_start, autonomous_work_step
  scripts/aw-runner.sh           # thin supervised runner
  openclaw.plugin.json
```

The plugin uses `api.runtime.tasks.flow.fromToolContext(ctx)` or equivalent runtime binding so TaskFlow gets owner session and requester origin.

Keep this plugin separate from `marinator-delegation` for now. AW control and Marinator code delegation are related but distinct responsibilities.

## `autonomous_work_start`

Call shape:

```text
autonomous_work_start(duration="2h", prompt="optional owner instruction")
```

Responsibilities:

- validate duration, prompt, and authority;
- refuse another active AW unless multi-window support is explicitly designed;
- create managed TaskFlow with `controllerId="junie-live/autonomous-work"`;
- initialize `currentStep="planning"`, `stateJson`, and optional `waitJson=null`;
- seed/record the dedicated AW session and always-in-context instruction;
- start `aw-runner.sh` detached, similar to `marinator_delegate` starting its runner;
- record runner metadata in TaskFlow state/artifacts;
- return `window_id`, `flowId`, and status.

`autonomous_work_start` is initialization only. It must not choose backlog work, execute a task, review Marinator output, or perform continuation transitions.

## `autonomous_work_step`

Call shape:

```text
autonomous_work_step()
autonomous_work_step(rationale="optional append-only note")
```

No `action` argument. `rationale` is append-only commentary only; it must not control transitions.

Responsibilities:

- resolve active AW TaskFlow for the current AW session/window;
- read `currentStep`, `stateJson`, `waitJson`, revision, and supporting artifacts;
- validate status, phase, deadline, cancellation, and artifacts;
- validate backlog schema/eligibility when needed;
- apply deterministic transition table: current phase + validated artifacts → next allowed operation;
- update TaskFlow through revision-checked `resume`, `setWaiting`, `finish`, or `fail`;
- write supporting artifact events/logs;
- return next instruction/status for the OpenClaw step/runner;
- refuse invalid transitions rather than guessing.

The LLM/orchestrator writes substantive artifacts such as backlog items, selection rationale, review notes, and final summary drafts. The tool validates those artifacts and advances TaskFlow state. The LLM must not directly set AW phase transitions.

Example deterministic transitions:

```text
planning + valid selected item
  → currentStep=executing_task
  → stateJson.selected_item=<item id>
  → stateJson.continuation=continue_now
  → return instruction to execute selected item via normal Junie/Marinator guidelines

planning + no eligible work + time remains
  → currentStep=planning
  → stateJson.continuation=continue_now
  → return instruction to generate/update backlog candidates

executing_task + selected item terminal outcome recorded
  → validate backlog/task outcome artifact
  → currentStep=planning | finalizing | blocked
  → update completed_items/blocked_items

any phase + deadline reached and no active selected task needs final handling
  → currentStep=finalizing | completed
```

## AW runner

`aw-runner.sh` is a thin supervisor, not a decision-maker.

Flow:

1. User asks Junie to work autonomously for `N` hours, optionally with a prompt like “use `feature_28_may` branch”.
2. Orchestrator calls `autonomous_work_start(duration=N, prompt=...)`.
3. The tool creates a managed TaskFlow and starts `aw-runner.sh`.
4. Runner invokes one non-interactive OpenClaw step in a dedicated AW session.
5. The OpenClaw step reads docs/backlog/TaskFlow state, does bounded orchestration work, updates artifacts, and calls `autonomous_work_step()`.
6. Runner reads TaskFlow state after the step exits.
7. If `stateJson.continuation=continue_now`, runner emits an AW continuation wake.
8. If `wait_external`, runner does not wake; an external event or selected-task completion continues the flow.
9. If final/blocked/cancelled/failed, runner stops.

Runner must not choose work, edit backlog semantically, review code, decide strategy, or bypass Marinator.

## OpenClaw step prompt requirements

Each AW step prompt must include:

- this is an internal autonomous-window step;
- do not ask the user live questions;
- if approval/clarification is required, record blocked/needs-approval artifact;
- read relevant docs/backlog/TaskFlow state;
- do one bounded transition, except an `executing_task` step may run the normal Marinator delegation/review/fix loop for the selected task;
- update artifacts and call `autonomous_work_step()`;
- preserve the always-in-context AW instruction.

The step should run in a dedicated AW session, not the Telegram DM lane.

## Marinator integration

When a backlog item is selected, AW hands it to the orchestrator as a normal Junie task:

1. `autonomous_work_step()` records `currentStep=executing_task` and `selected_item=<id>`.
2. It returns/records instruction to execute that item using standard Junie/Marinator guidelines.
3. Orchestrator owns task execution end to end: decompose if needed, call `marinator_delegate`, review, request fixes, verify, accept, mark partial/blocked, and update backlog artifacts.
4. AW must not impose `reviewing_marinator` or a single-run state. One selected task may use zero, one, or multiple Marinator runs.
5. After selected item reaches terminal outcome (`done`, `blocked`, `needs_approval`, equivalent), orchestrator calls `autonomous_work_step()` again.
6. The tool validates outcome and advances TaskFlow.

Important context requirement: while AW is active, the AW session must always say that Marinator wakes during a selected task are handled through ordinary Marinator review/fix/acceptance; after the selected backlog item reaches terminal outcome, update artifacts and call `autonomous_work_step()`.

Do not rely on LLM memory for this. Put it in AW session bootstrap, step prompts, and wake text.

## Wake policy

No cron in M4.

Wake sources:

1. AW runner emits deterministic continuation wake after a step when TaskFlow state says `continue_now`.
2. Marinator runner emits terminal wake for delegated code work; while `executing_task`, the orchestrator handles it normally and calls `autonomous_work_step()` only after selected item terminal outcome.

Deadline is checked on each AW step/wake. Without cron, exact finalization at `end_at` is not guaranteed if all wakes stop; report that honestly.

Wake text must include the AW handling rule, e.g.:

```text
AW continuation. If no selected task is currently executing, call autonomous_work_step() first. If this wake is part of a selected task's Marinator run, handle ordinary Marinator review/fix/acceptance; once the selected backlog item reaches terminal outcome, update artifacts and call autonomous_work_step().
```

## Supervision and debug reporting

AW runner supervision should record:

- flow id / window id;
- step start/finish timestamps;
- exit code;
- timeout;
- stdout/stderr;
- TaskFlow revision before/after;
- terminal status: `completed | failed | timed_out | stalled`;
- no continuation wake if state is invalid, step failed, or timed out.

For M4 live testing, debug Telegram summaries using `gpt-4.1-mini` are acceptable behind a feature flag, similar to Marinator debug summaries. Production reporting should go through AW final/checkpoint reports or OpenClaw wake/delivery paths.

## TaskFlow-specific spike gates

Before claiming this variant works:

- create managed TaskFlow from plugin tool context;
- store AW state in `stateJson` and phase in `currentStep`;
- mutate via revision-checked `resume`, `setWaiting`, `finish`, `fail`;
- verify `openclaw tasks flow list/show/cancel` sees AW;
- verify cancel intent stops future AW steps;
- verify state survives Gateway restart;
- verify runner can read TaskFlow state after OpenClaw step exits;
- verify continuation wake targets AW session, not human DM directly;
- verify Marinator wakes during `executing_task` preserve ordinary Marinator loop;
- verify final report reaches owner through orchestrator-owned delivery.

If TaskFlow API cannot support required AW state/wake/session behavior, pause and fall back to custom `.openclaw/state/autonomous/...` state only after documenting the gap.

## General testing gates

- fake OpenClaw step writes `continue_now` → runner emits wake;
- fake step writes `wait_external` → runner does not wake;
- fake step hangs → runner times out and marks failed/stalled;
- fake invalid state/revision conflict → runner does not continue;
- real OpenClaw step completes one planning cycle;
- selected docs-only task reaches terminal outcome and AW returns to planning/finalizing;
- selected code task runs ordinary Marinator delegation/review/fix/acceptance and then calls `autonomous_work_step()`;
- deadline reached after selected task completion → final summary instead of starting new work;
- failed/blocked selected item is recorded and AW can choose another eligible item if time remains.

## Authority and safety

- Strategy/architecture/status fit is the top criterion.
- `autonomous_fit` only matters after strategic fit.
- Code work remains serialized by code mutex.
- External/team-facing messages, PR open/merge, deploy/release, and major policy/architecture changes still require explicit authority.
- If approval is needed, block that item and continue only if another eligible item exists.
- Final reports must truthfully separate done, blocked, partial, planned-only, and verified work.

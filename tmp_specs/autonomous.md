# Autonomous Work Window Plan

This document captures the agreed design for the next Junie Live milestone: an admin can ask Junie to work autonomously on the project for a bounded duration (`N` hours). It records final agreements, not every intermediate idea from discussion.

## Goal

Enable a command like “поработай автономно 3 часа” to start a bounded autonomous work window where Junie:

1. understands the current product/project state;
2. generates or updates candidate work;
3. prioritizes eligible work against strategy and architecture;
4. executes selected code-changing work only through Marinator;
5. reviews, records, and reports results;
6. repeats the full cycle while time remains.

The central Marinator loop already exists and remains the execution kernel. The autonomous window is a planning/control layer around it, not a replacement executor.

## Non-goals for this milestone

- No cron/checkpoint watchdog in the first implementation. Cron had prior reliability issues and is deferred.
- No parallel subagents for this milestone. Future read-only candidate discovery may use them, but M4 stays sequential and observable.
- No shell controller that makes product decisions. Deterministic scripts/tools may supervise and transition state, but Junie remains the product/strategy decision-maker.
- No direct code edits by the orchestrator. Code/script/test/config changes still go through `marinator_delegate` / opencode under the mutex.

## Final milestone split

### M1 — Backlog contract (Markdown-only)

Deliverables:

- Design the durable, reviewable backlog planning surface. For this repo, prefer Markdown in the product repo unless an external tracker is chosen later.
- Define item/hypothesis lifecycle, required fields, scoring fields, and hygiene rules.
- Add initial backlog items from current `implementation-status.md` gaps.

Backlog should be custom, not a generic TODO list. It must capture problem, evidence, strategy/architecture fit, acceptance, verification, gates, scores, status, and execution history.

Intended structure:

```text
backlog/
  README.md
  items/
    BL-YYYYMMDD-001.md
    BL-YYYYMMDD-002.md
  events.jsonl        # optional append-only durable planning history, not runner logs
```

MVP can use one item file type with `kind: hypothesis | task | bug | chore | decision | cleanup` rather than separate `items/` and `hypotheses/` systems.

Example item shape:

```markdown
---
id: BL-20260530-001
kind: task
status: candidate # candidate | validated | ready | in_progress | blocked | done | archived
title: Remove debug direct Telegram sends from Marinator runner
source:
  - implementation-status.md
problem: Runner debug sends may violate executor isolation.
desired_outcome: Worker progress reaches the user only through orchestrator-reviewed paths.
acceptance:
  - No production runner path sends Telegram messages directly.
verification:
  - scripts/verify.sh
scores:
  strategy_fit: 5
  architecture_fit: 5
  impact: 4
  confidence: 4
  effort: 2
  risk: 2
  autonomous_fit: 5
approval_required: false
mutex_required: true
---

## Evidence

...

## Notes

...

## Execution history

...
```

Hypothesis vs item:

- Hypothesis = why a change may be valuable.
- Item = concrete executable work with outcome and verification.

Repo backlog stores durable planning state only. Volatile execution state stays in workspace `.openclaw/state/...`.

### M2 — Hypothesis/task generation

Deliverables:

- OpenClaw behavior/protocol/skill for generating backlog candidates.
- No background daemon or shell loop yet; M2 is orchestrator behavior plus docs/skill/protocol and Markdown artifact updates.
- Generation flow: signals → observations → strategy/architecture/status check → backlog candidates.
- Dedupe and junk-control rules.

Main signal sources:

- `implementation-status.md` gaps;
- `day_to_day_routines.md` contract-only routines;
- Marinator run results/logs;
- guidance/doc consistency issues;
- owner Telegram requests;
- repo inspection when relevant.

The main criterion is strategy/architecture/status fit, not autonomous convenience. `autonomous_fit` is only a gate/modifier after strategic fit is established.

### M3 — Prioritization / select-next

Deliverables:

- Eligibility rules: approval gates, mutex, verification clarity, deadline/time budget, repo scope, no Hermes edits unless explicitly requested, no deploy/PR/external actions without authority.
- Explainable scoring among eligible items.
- `select-next` behavior that can say what was selected, why, and why skipped items were blocked/ineligible.

Recommended ordering:

1. strategy fit;
2. architecture fit;
3. current implementation/status fit;
4. outcome/verification clarity;
5. autonomous fit;
6. effort/risk/uncertainty.

### M4 — Autonomous work window v1, no cron

Deliverables:

- Command recognition for bounded autonomous work requests.
- Durable autonomous-window state.
- Thin supervised AW runner around OpenClaw steps.
- Deterministic `autonomous_work_step` tool/state transition boundary.
- Marinator integration and wake-based continuation.
- Live/spike tests of wake and continuation behavior.

High-level cycle:

```text
snapshot → generate/update candidates → dedupe/score → select eligible item →
execute via Marinator → review/verify/report → reflect/update backlog/status →
repeat full cycle if time remains
```

Snapshot/preflight should include at least:

- `MEMORY.md` and relevant docs;
- `implementation-status.md`;
- git status / dirty working tree;
- code mutex state;
- active or recent Marinator runs;
- backlog state;
- recent blockers/approvals.

The repeat means the full cycle restarts. After each item, state has changed and must be re-snapshotted/re-prioritized.

### M5 — Hardening

Deliverables after M4 works:

- cancellation;
- recovery after restart;
- stuck-state handling;
- dry-run mode;
- better failure budgets;
- optional cron/checkpoint watchdog later;
- CI/automated tests where practical.

## Runtime architecture

Use three layers of state/artifacts:

1. Repo-visible planning state:
   - backlog Markdown files;
   - product docs/status updates;
   - review/selection artifacts if they are durable product context.

2. Workspace runtime state:
   - `.openclaw/state/autonomous_windows/<window_id>/window.json`;
   - `.openclaw/state/autonomous_windows/<window_id>/events.jsonl`;
   - AW runner logs;
   - links to Marinator runs.

3. Marinator runtime state:
   - existing `.openclaw/state/marinator/runs/<job_id>/...`.

Do not put OpenClaw runtime state in the repo root.

## AW state model

`window.json` is the source of truth for the autonomous window phase.

Minimal phases:

```text
planning
executing_task
finalizing
blocked
completed
cancelled
failed
```

`phase` means the current stable state, not the next action.

Important fields:

```json
{
  "window_id": "AW-...",
  "status": "running",
  "phase": "planning",
  "started_at": "...",
  "end_at": "...",
  "selected_item": null,
  "continuation": "continue_now | wait_external | final | blocked",
  "last_step_started_at": "...",
  "last_step_finished_at": "..."
}
```

## AW tools contract

M4 uses two tools because the human/LLM mental model is clearer:

- `autonomous_work_start(...)` initializes one autonomous window.
- `autonomous_work_step(...)` advances an existing autonomous window.

### `autonomous_work_start`

Initial call shape:

```text
autonomous_work_start(duration="2h", prompt="optional user instruction")
```

Responsibilities:

- validate duration, prompt, and authority;
- refuse if another active AW already exists unless multi-window support is explicitly designed;
- create durable AW state under `.openclaw/state/...`;
- seed/record the dedicated AW session and always-in-context AW instruction;
- start supervised `aw_runner`, similar to how `marinator_delegate` starts `delegate-coding-task.sh`;
- write initial `window.json` / `events.jsonl`;
- return the `window_id` and current status.

`autonomous_work_start` is only for initialization. It must not perform planning, backlog selection, task execution, Marinator review, or continuation transitions.

### Implementation placement

Implement these tools as an OpenClaw tool plugin, similar to `marinator-delegation`, rather than as ad hoc shell commands or LLM-managed file operations.

Recommended shape:

```text
autonomous-work/
  src/index.ts                  # defineToolPlugin: autonomous_work_start, autonomous_work_step
  scripts/aw-runner.sh           # supervised runner, bundled with plugin
  openclaw.plugin.json           # generated/validated plugin manifest
```

Rationale:

- plugin tools have access to OpenClaw `toolContext` such as session key and delivery context;
- `autonomous_work_start` needs the same durable-start pattern as `marinator_delegate`: write spec/state first, then spawn the runner detached;
- OpenClaw can discover, allowlist, validate, and inspect plugin-owned tools;
- bundled scripts avoid depending on repo-relative runtime paths;
- runtime state stays under `.openclaw/state/...`, not the product repo root.

State layout:

```text
.openclaw/state/autonomous/windows/<window_id>/
  window.json
  spec.json
  events.jsonl
  logs/
  control/
```

`autonomous_work_start` should write initial state and start `scripts/aw-runner.sh`. `autonomous_work_step` should locate the active window from the AW session/window id, take a lock, validate state/artifacts, apply the deterministic transition table, write state/events, and return the next instruction/status.

Keep this plugin separate from `marinator-delegation` unless a later refactor intentionally creates a broader Junie runtime plugin. Autonomous window control and Marinator code delegation are related but distinct responsibilities.

### `autonomous_work_step`

Final agreement: the tool should not require an `action` argument. It reads active AW state and artifacts, then performs the deterministic transition allowed by the current phase.

Preferred call shape:

```text
autonomous_work_step()
```

Optional:

```text
autonomous_work_step(rationale="...")
```

`rationale` is append-only commentary for `events.jsonl`; it must not control state transitions.

Responsibilities:

- read `window.json` and relevant artifacts;
- validate current phase/status/deadline;
- validate backlog schema/eligibility where needed;
- own the deterministic state machine: map current phase + validated artifacts to the next allowed operation;
- provide the next OpenClaw-step prompt/instructions when more orchestrator work is needed;
- provide the next task-execution prompt/instructions when a backlog item is selected;
- move AW into `executing_task` while the orchestrator handles that selected item through the standard delegation/review/fix/acceptance loop;
- write `phase`, `continuation`, and events;
- refuse invalid transitions rather than guessing.

The LLM/orchestrator writes or updates substantive artifacts: backlog items, selection rationale, review notes, final summary draft. The tool reads those artifacts and advances state. The LLM must not directly set phase transitions.

In other words, `autonomous_work_step` is not just a state writer. It must contain the AW transition table / policy for what happens next for each phase. Example shape:

```text
planning + valid selected item
  → set selected_item
  → return an OpenClaw-step prompt telling the orchestrator to execute that backlog item using standard Junie/Marinator guidelines
  → phase=executing_task, continuation=continue_now

planning + no eligible work + time remains
  → return next OpenClaw-step prompt to generate/update candidates
  → phase=planning, continuation=continue_now

executing_task + task artifact says done/blocked/needs_approval
  → validate task outcome artifact/backlog status
  → phase=planning, finalizing, or blocked depending on deadline and remaining eligible work

any phase + deadline reached and no active selected task needs final handling
  → phase=finalizing or completed
```

This mapping should be deterministic code/config, not something the LLM reconstructs from memory.

## AW runner

M4 uses a thin supervised runner, conceptually similar to the Marinator runner but not a decision-maker.

Flow:

1. User asks Junie to work autonomously for `N` hours, optionally with an instruction such as “use `feature_28_may` branch for your work”.
2. Orchestrator calls `autonomous_work_start(duration=N, prompt=...)`.
3. `autonomous_work_start` creates AW state and starts `aw_runner`.
4. `aw_runner` invokes one non-interactive OpenClaw step in a dedicated AW session.
5. The OpenClaw step reads docs/backlog/state, does bounded orchestration work, updates artifacts, and calls `autonomous_work_step()`.
6. After the step exits, `aw_runner` reads AW state.
7. If `continuation=continue_now`, `aw_runner` emits a wake to continue AW.
8. If `continuation=wait_external`, it does not wake; an external event or selected-task completion will continue the flow.
9. If final/blocked/cancelled/failed, it does not continue.

`aw_runner` must not:

- choose product work;
- edit backlog semantically;
- review code;
- decide strategy;
- bypass Marinator.

It only supervises OpenClaw step execution and generates deterministic continuation wakes based on machine-readable state.

## OpenClaw step

An OpenClaw step is one non-interactive agent turn through Gateway, likely using `openclaw agent ...` or the best equivalent API/CLI path after spike validation.

Prompt requirements:

- internal autonomous-window step;
- do not ask the user live questions;
- if approval/clarification is required, record a blocked/needs-approval state/artifact;
- do one bounded transition, except that an `executing_task` step may run the normal Marinator delegation/review/fix loop for the selected task;
- update artifacts and call `autonomous_work_step()`.

The step should run in a dedicated AW session, not the Telegram DM lane.

## Task execution and Marinator integration

When a backlog item is selected, `autonomous_work_step()` should hand the selected item to the orchestrator as a normal Junie task, then step out of the way:

1. `autonomous_work_step()` validates the selected item and records:
   - `phase=executing_task`;
   - `selected_item=<item id>`;
   - `continuation=continue_now`.
2. It returns/records an OpenClaw-step instruction telling the orchestrator to execute the selected backlog item using the standard Junie/Marinator guidelines.
3. The orchestrator owns the task end to end: decompose if needed, call `marinator_delegate`, review results, request fixes, verify, accept, mark partial/blocked when appropriate, and update backlog/review artifacts.
4. During this selected task, Marinator terminal wakes are handled by the ordinary delegation/review/fix/acceptance loop. AW must not impose a separate `reviewing_marinator` state or require a single Marinator run id; one selected task may require zero, one, or multiple Marinator runs.
5. Only after the selected backlog item reaches a terminal task outcome (`done`, `blocked`, `needs_approval`, or equivalent) should the orchestrator call `autonomous_work_step()` again.
6. `autonomous_work_step()` validates the task outcome artifact/backlog status and either returns to `planning`, moves to `finalizing`, or blocks/completes the AW.

This preserves the existing delegation principle: once a concrete task is selected, the orchestrator uses the out-of-the-box Marinator loop rather than a second AW-specific review state machine. `autonomous_work_step()` owns autonomous-window control flow before and after the selected task; it does not micromanage Marinator review/fix cycles inside the task.

Important context requirement: while an AW selected task is active, the AW orchestration session must always carry an instruction that after the selected backlog item reaches a terminal outcome, the orchestrator must update the task/backlog artifacts and call `autonomous_work_step()` to continue or finish the AW. Do not rely on the model remembering this from earlier chat history; put it in the AW step prompt, wake text, and/or AW session bootstrap context.

## Wake policy

Do not rely on the LLM to remember to wake itself.

Wake sources:

1. AW runner: emits deterministic continuation wake after an OpenClaw step when AW state says `continuation=continue_now`.
2. Marinator runner: emits terminal wake when delegated code work completes/fails/times out.

No cron in M4. Deadline is checked by `autonomous_work_step()` on every step/wake. Without cron, if all wakes stop, the window may not finalize exactly at `end_at`; this is an accepted M4 limitation and should be reported honestly.

Wake messages must include the AW-specific handling rule. Example: “AW-123 continuation. If no selected task is currently being executed, call `autonomous_work_step()` first. If this wake is part of a selected task's Marinator run, handle it through the ordinary Marinator review/fix/acceptance loop; once the selected backlog item reaches a terminal outcome, update backlog/task artifacts and call `autonomous_work_step()`.” The phase file/state determines what happens.

## Supervision and debug reporting

AW runner supervision should be close to Marinator/opencode supervision:

- durable state and logs;
- `started_at` / `finished_at`;
- exit code;
- timeout;
- stdout/stderr capture;
- state before/after;
- terminal status: `completed | failed | timed_out | stalled`;
- no continuation wake if state is invalid, step failed, or timed out.

For M4 live testing, debug Telegram summaries using a cheap model such as `gpt-4.1-mini` are acceptable behind a debug flag, similar to current Marinator debug summaries.

Default/production posture should avoid direct runner-to-user messages. Normal reporting should go through AW final/checkpoint reports or OpenClaw wake/delivery paths. Debug direct sends must be feature-flagged and documented as debug-only.

## Testing gates for M4

Before claiming M4 works, run a spike/test matrix:

- fake OpenClaw step writes `continue_now` → runner emits wake;
- fake step writes `wait_external` → runner does not wake;
- fake step hangs → runner times out and marks failed/stalled;
- fake invalid state → runner does not continue;
- real OpenClaw step without Marinator completes one planning cycle;
- selected docs-only task reaches terminal outcome and AW returns to planning/finalizing;
- selected code task can run the ordinary Marinator delegation/review/fix/acceptance loop and then call `autonomous_work_step()` after terminal task outcome;
- Marinator terminal wakes during `executing_task` are handled by the ordinary Marinator loop, not by an AW-specific `reviewing_marinator` state;
- deadline reached after selected task completion → final summary instead of starting new work;
- failed/blocked selected item is marked blocked and the window can choose another eligible item if time remains.

If the OpenClaw-inside-OpenClaw runner approach shows session locking, delivery, or wake reliability problems during spike, pause and redesign as a more native OpenClaw plugin/task instead of forcing the shell approach.

## Lessons from old controller (`f50ee12182b3aa38e8701ca933d8be9aca12230c`)

Keep:

- bounded window state;
- preflight checks;
- repeat full cycle until deadline;
- failure budget so one bad item does not waste the window;
- explicit blocked status;
- final report with selected/completed/blocked/verification;
- stuck-state detection as a hardening concern.

Do not keep:

- shell controller as product decision-maker;
- PID/watchdog as primary control plane;
- workspace-only JSON backlog as the planning source of truth;
- single numeric priority as the whole prioritization model;
- “empty backlog → invent anything” without strategy/architecture gate;
- default destructive cleanup (`reset --hard` / `clean`) as recovery;
- direct worker execution that bypasses the current Marinator boundary.

## Authority and safety

- Strategy/architecture/status fit is the top criterion for generated and selected work.
- `autonomous_fit` only matters after strategy/architecture fit is established.
- Code-changing work remains serialized by the code mutex.
- External/team-facing actions, PR opening/merging, deploy/release, and major policy/architecture changes still require explicit authority.
- If approval is needed during an autonomous window, block that item and continue only if another eligible item exists.
- Final reports must be truthful about what was actually completed, what was blocked, what was only planned, and what was verified.

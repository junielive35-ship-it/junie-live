# Autonomous Work Window on Hermes — implementation plan

Status: implementation plan for Junie Live / Hermes

Source inputs:
- OpenClaw counterpart: `tmp_specs/autonomous.md`
- Hermes Marinator spec: `tmp_specs/marinator_hermes.md`
- Current Hermes implementation: `hermes/initialization/plugins/marinator-delegation/`
- Validated spike: `hermes/scripts/spike-marinator-headless-stall-full-loop.sh`

## 0. Executive summary

Build Autonomous Work (AW) for Junie Live on Hermes as a deterministic state machine around normal Junie/Marinator behavior.

Do **not** implement AW as one large prompt, a cron job, a Kanban board, or a shell controller that chooses product work.

The architecture is:

```text
owner/live Junie session
  -> autonomous_work_start(duration, prompt?)
  -> creates AW window ledger + starts aw-runner
  -> aw-runner drives one bounded headless Hermes AW session turn at a time
  -> each turn follows a phase-specific prompt and calls autonomous_work_step()
  -> autonomous_work_step validates artifacts and chooses the next deterministic transition
  -> selected code work is executed by the ordinary Marinator protocol via marinator_delegate
  -> Marinator wakes the same AW session on completion/failure/attention
  -> AW repeats until deadline, no eligible work, blocker, cancellation, or failure budget
```

Keep the OpenClaw AW shape: state machine + step-specific prompts. Replace only the OpenClaw runtime primitives with Hermes primitives.

## 1. Product goal

Enable an owner request such as “поработай автономно 3 часа” to start one bounded autonomous work window where Junie repeatedly:

1. snapshots current project/product/runtime state;
2. generates or updates candidate work;
3. scores and selects eligible work against strategy/architecture/status;
4. executes the selected item through the ordinary Junie/Marinator loop;
5. records the outcome;
6. repeats while time remains.

AW is a planning/control layer. It is not a new executor and not a replacement for Marinator.

## 2. Non-goals for MVP

- No Kanban/board abstraction.
- No cron as the primary control plane.
- No parallel code-changing workers.
- No direct code edits by the orchestrator; code/script/test/config changes still go through `marinator_delegate` / OpenCode under the mutex.
- No AW-specific Marinator review state machine.
- No one-prompt “do the whole autonomous window” agent run.
- No shell controller that chooses product work, edits backlog semantically, accepts code, or decides strategy.
- No deploy/PR/external/team-facing actions unless current Junie authority docs explicitly allow them.

Cron may be added later only as recovery/watchdog, not as the core continuation path.

## 3. What to preserve from OpenClaw `autonomous.md`

Preserve:

- bounded window state;
- deterministic state transitions;
- step-specific prompts;
- full-cycle repeat after every item;
- deadline checks on every step/wake;
- failure budget;
- explicit blocked/final states;
- selected task executed by the normal Marinator loop;
- final report with attempted/completed/blocked/verified work.

Change:

- `.openclaw/state/...` -> Hermes profile-local state;
- OpenClaw plugin -> Hermes user plugin;
- `openclaw agent` / scheduled turns -> `hermes -p junie-live chat --resume <aw_session_id> -q <step_prompt>`;
- OpenClaw wake/event/cron workaround -> Hermes headless resume + Marinator async wake.

Do not carry over OpenClaw-specific TaskFlow, raw Cron/sessionTarget, heartbeat, or `system event` mechanics.

## 4. Runtime primitives already available

### Marinator

Current Hermes Marinator provides:

- `marinator_delegate` user plugin tool;
- durable run dirs under profile state;
- supervised OpenCode process group;
- no-log-progress detection;
- `control/kill` handling;
- live `terminal(background=true, notify_on_complete=true)` completion wake;
- headless `hermes chat --resume` continuation;
- async headless resume so wrapper supervision is not blocked.

The full-loop spike validated:

```text
silent OpenCode
  -> attention_required/no_log_progress
  -> async headless resume starts
  -> wrapper continues polling
  -> control/kill is observed
  -> first job killed
  -> second Marinator job completes
```

### Hermes headless sessions

Use `hermes -p junie-live chat --resume <session_id> -q <prompt>` for deterministic continuation of a headless AW session.

`aw-runner` must not rely on a live gateway loop after the parent `hermes chat -q` exits.

## 5. Implementation placement

Add a separate Hermes user plugin next to Marinator:

```text
hermes/initialization/plugins/autonomous-work/
  plugin.yaml
  __init__.py
  tools.py
  state.py
  runner.py
  prompts.py
  scripts/
    aw-runner.sh
```

Rationale:

- AW control and Marinator code delegation are related but separate responsibilities.
- The tool layer can validate state and expose a small public schema.
- The runner can be deterministic and testable.
- The profile seed can install/enable the plugin during `hire-junie.sh` just like `marinator-delegation`.

Do not implement AW as ad hoc shell snippets inside skills.

## 6. Public tools

### `autonomous_work_start`

Schema:

```json
{
  "duration": "2h",
  "prompt": "optional owner guidance"
}
```

Rules:

- `duration` is required and bounded.
- `prompt` is optional owner guidance, not a replacement for strategy/backlog/docs.
- The tool resolves runtime owner/session/delivery metadata internally.
- The public schema must not expose Telegram chat IDs, profile names, tokens, or delivery targets.

Responsibilities:

1. Validate duration/end time.
2. Refuse if another active AW window exists unless multi-window support is explicitly designed.
3. Resolve current Hermes owner/session metadata.
4. Create AW state directory and initial `window.json` / `events.jsonl`.
5. Create or bootstrap a dedicated AW headless Hermes session.
6. Start `aw-runner.sh` in the background.
7. Return `window_id`, `run_dir`, `aw_session_id`, `phase`, and status.

It must not select work, edit backlog, execute tasks, or perform phase transitions beyond initialization.

### `autonomous_work_step`

Schema:

```json
{
  "rationale": "optional append-only note"
}
```

Rules:

- No `action` argument.
- `rationale` is append-only commentary for events; it must not control transitions.
- The tool reads current AW state and artifacts, validates them, applies the transition table, writes state/events, and returns the next instruction/status.
- The LLM/orchestrator writes substantive artifacts; the tool controls phase transitions.

## 7. State layout

Store AW runtime state under the Hermes profile, not the target repo:

```text
$HERMES_HOME/junie-live/state/autonomous_work/
  windows/<window_id>/
    window.json
    spec.json
    events.jsonl
    step_prompt.md
    last_step_result.md
    selection.md
    final_report.md
    logs/
      aw-runner.log
      step-<n>.stdout.log
      step-<n>.stderr.log
    control/
      cancel
    locks/
      runner.lock
      step.lock
  active_window.json
  owner-session-locks/<aw_session_id>.lock
```

Use profile-local runtime state for machine state. Repo-visible/product planning state remains wherever the current Junie backlog/docs protocol says it lives.

Do not put AW runtime state in the target repo root.

## 8. `window.json` minimal shape

```json
{
  "window_id": "AW-20260601-001",
  "status": "running",
  "phase": "snapshot_preflight",
  "continuation": "continue_now",
  "started_at": "2026-06-01T00:00:00Z",
  "end_at": "2026-06-01T03:00:00Z",
  "owner_session_id": "...",
  "aw_session_id": "...",
  "repo": "/abs/path/to/owned/repo",
  "prompt": "optional owner guidance",
  "selected_item": null,
  "selected_item_started_at": null,
  "completed_items": [],
  "blocked_items": [],
  "failure_count": 0,
  "last_step_started_at": null,
  "last_step_finished_at": null,
  "last_step_prompt_path": null,
  "last_step_result_path": null,
  "last_error": null
}
```

`phase` is the current stable phase, not the next action.

`continuation` values:

```text
continue_now | wait_external | final | blocked
```

## 9. Phases

MVP phases:

```text
snapshot_preflight
candidate_generation
score_and_select
executing_task
record_outcome
finalizing
blocked
completed
cancelled
failed
```

Do not add a separate `review_marinator_result` phase.

`executing_task` is one phase and one step prompt that hands the selected item to the ordinary Junie/Marinator protocol. That prompt may span multiple Marinator runs and fix loops.

## 10. Phase responsibilities

### `snapshot_preflight`

The AW session reads enough state to understand what is safe and relevant now:

- current memory / strategic compass;
- profile docs and target repo `HERMES.md` / operational references;
- implementation status;
- backlog state;
- git status and current branch;
- code mutex state;
- active/recent Marinator runs;
- active AW state and prior blockers;
- owner prompt for this window.

Artifacts:

- append `snapshot_preflight` event;
- optionally write `snapshot.md` if useful.

Transition:

- unsafe preflight -> `blocked` or `failed` with evidence;
- deadline reached -> `finalizing`;
- safe -> `candidate_generation`.

### `candidate_generation`

The AW session generates/updates candidate work from current signals:

- implementation gaps;
- docs/status drift;
- failed or partial Marinator runs;
- owner requests;
- verification gaps;
- current backlog hygiene.

It must not invent random work just because the backlog is empty. Strategy/architecture/status fit is the primary gate.

Artifacts:

- created/updated backlog items or candidate notes using current Junie backlog protocol;
- event listing created/updated/skipped candidates.

Transition:

- candidates available or existing backlog sufficient -> `score_and_select`;
- no eligible work and no useful candidates -> `finalizing`.

### `score_and_select`

The AW session evaluates eligible items.

Eligibility gates:

- owner approval requirement;
- code mutex availability;
- branch safety;
- verification clarity;
- deadline/time budget;
- repo scope;
- no deploy/PR/external actions without authority;
- no Hermes Agent core edits unless explicitly requested.

Recommended priority order:

1. strategy fit;
2. architecture fit;
3. implementation/status fit;
4. outcome and verification clarity;
5. autonomous fit;
6. effort/risk/uncertainty.

Artifacts:

- `selection.md` with selected item and skipped/ineligible reasons.

Transition:

- selected item -> `executing_task`;
- no eligible item -> `finalizing` or `blocked`.

### `executing_task`

This is a single phase-specific prompt that tells Junie to execute the selected backlog item through the standard delegation protocol.

The prompt must instruct the AW session to:

1. read selected item acceptance and verification requirements;
2. follow `delegation-protocol.md`;
3. decompose if needed;
4. use `marinator_delegate` for code-changing work;
5. handle Marinator completion/failure/attention wakes in the ordinary Marinator loop;
6. inspect `run_dir`, `status.json`, `result.md`, logs, diff, and verification evidence;
7. decide accept/fix/wait/kill/block;
8. if fix is needed, call `marinator_delegate` again, passing `opencode_previous_session_id` when available;
9. update backlog/task artifacts with terminal outcome;
10. call `autonomous_work_step()` only after the selected item reaches a terminal task outcome.

Terminal selected-item outcomes:

```text
done | blocked | needs_approval | failed | skipped
```

During this phase, AW does not micromanage individual Marinator runs. Marinator owns worker supervision and wakes; the AW state machine waits for a terminal selected-item outcome.

Transition:

- selected item terminal and time remains -> `record_outcome`;
- selected item needs approval -> `blocked` or `record_outcome` depending on whether more eligible work can proceed;
- unrecoverable failure budget exceeded -> `failed`.

### `record_outcome`

The AW session records what happened for the selected item:

- item id;
- terminal outcome;
- Marinator job ids involved;
- verification evidence;
- blocked reasons;
- follow-up candidates;
- current git status.

Transition:

- deadline reached -> `finalizing`;
- time remains -> `snapshot_preflight` (full-cycle restart, not “next item” shortcut);
- failure budget exceeded -> `failed`.

### `finalizing`

The AW session writes a truthful final report:

- duration and goal;
- selected items;
- completed items;
- blocked/needs-approval items;
- verification performed;
- remaining risks;
- current git status;
- recommended next owner decisions.

Then it sends/reports via the current Junie communication protocol and marks the window `completed` or `blocked`.

## 11. Transition table

`autonomous_work_step()` owns this deterministic table.

```text
snapshot_preflight + safe + time_remains
  -> phase=candidate_generation, continuation=continue_now

snapshot_preflight + unsafe
  -> phase=blocked|failed, continuation=blocked|final

candidate_generation + candidates_or_backlog
  -> phase=score_and_select, continuation=continue_now

candidate_generation + no_candidates + time_remains
  -> phase=finalizing, continuation=continue_now

score_and_select + selected_item
  -> phase=executing_task, selected_item=<id>, continuation=continue_now

score_and_select + no_eligible_item
  -> phase=finalizing|blocked, continuation=continue_now|blocked

executing_task + no_terminal_selected_item
  -> phase=executing_task, continuation=wait_external

executing_task + selected_item_terminal
  -> phase=record_outcome, continuation=continue_now

record_outcome + time_remains + failure_budget_ok
  -> phase=snapshot_preflight, continuation=continue_now

record_outcome + deadline_reached
  -> phase=finalizing, continuation=continue_now

finalizing + report_written
  -> phase=completed, continuation=final

any_phase + control/cancel
  -> phase=cancelled, continuation=final

any_phase + invalid_state
  -> phase=failed, continuation=final
```

Refuse invalid transitions rather than guessing.

## 12. AW runner

`aw-runner.sh` is a thin deterministic supervisor.

It must not:

- choose product work;
- edit backlog semantically;
- review code;
- decide strategy;
- bypass Marinator.

It may:

- start one Hermes AW step;
- capture stdout/stderr;
- read `window.json` after the step exits;
- if `continuation=continue_now`, call the next AW step with `hermes chat --resume <aw_session_id>`;
- if `continuation=wait_external`, stop and wait for Marinator or another external wake;
- if final/blocked/cancelled/failed, stop.

Runner pseudo-flow:

```bash
while true; do
  read window.json
  case continuation in
    continue_now)
      prompt=$(autonomous_work_step returned/recorded prompt)
      hermes -p junie-live chat --resume "$aw_session_id" -q "$prompt"
      ;;
    wait_external|final|blocked)
      exit 0
      ;;
  esac
 done
```

In practice, implement with locks, logs, bounded step timeout, and exact status updates.

## 13. AW session bootstrap

`autonomous_work_start` needs an AW session id before the runner can use `--resume`.

Recommended MVP approach:

1. Create `window.json` with `aw_session_id=null`.
2. Run one bootstrap command:

```bash
hermes -p junie-live chat \
  -Q \
  --pass-session-id \
  --toolsets autonomous,marinator,terminal,file,messaging \
  -q "AW bootstrap for window <window_id>. Reply READY and wait for the runner."
```

3. Parse the `session_id:` footer from stdout.
4. Store it as `aw_session_id`.
5. Start `aw-runner.sh`, which resumes that session with the first phase prompt.

If Hermes exposes a cleaner session-create API by implementation time, use that instead. Keep the product contract the same: one durable AW session per window.

## 14. Prompt construction

Put prompt templates in `prompts.py` or markdown templates owned by the AW plugin.

Every AW step prompt must include:

- window id and phase;
- current deadline/end time;
- owner prompt;
- artifact paths (`window.json`, `events.jsonl`, selection/final report paths);
- rule: do not ask live questions; block/record needs-approval instead;
- rule: do not code directly; use Marinator for code changes;
- rule: update required artifacts;
- rule: call `autonomous_work_step()` at the end unless waiting on Marinator or blocked.

`executing_task` prompt must additionally include:

- selected item id/path;
- explicit instruction to follow `delegation-protocol.md`;
- explicit instruction that Marinator review/fix/acceptance is inside this single phase;
- explicit instruction to call `autonomous_work_step()` only after terminal selected-item outcome.

## 15. Wake policy

Do not rely on the LLM to remember to continue.

Wake sources:

1. AW runner after a step exits and `continuation=continue_now`.
2. Marinator headless resume for selected-task worker completion/failure/attention.
3. Optional future recovery watchdog.

Marinator attention during `executing_task` is handled by the ordinary Marinator protocol. The resumed AW session may wait, kill, or start a fix/restart worker according to `delegation-protocol.md`. AW should not have a separate `review_marinator_result` phase.

Deadline is checked by `autonomous_work_step()` on every step/wake. Without a recovery watchdog, a window may not finalize exactly at `end_at` if all wakes stop; document this as an MVP limitation.

## 16. Failure and cancellation

MVP should support at least:

- active-window refusal;
- invalid state -> `failed`;
- runner step timeout -> `failed` or `blocked` with evidence;
- selected item blocked/failed -> record and continue only if failure budget allows;
- `control/cancel` file -> `cancelled` and final report.

Do not use destructive cleanup such as `git reset --hard` or `git clean` as automatic recovery.

## 17. Tool implementation tasks

### Task 1 — Add plugin skeleton

Files:

```text
hermes/initialization/plugins/autonomous-work/plugin.yaml
hermes/initialization/plugins/autonomous-work/__init__.py
hermes/initialization/plugins/autonomous-work/tools.py
```

Register tools:

- `autonomous_work_start`
- `autonomous_work_step`

Toolset: `autonomous`.

### Task 2 — Add state helpers

File:

```text
hermes/initialization/plugins/autonomous-work/state.py
```

Implement:

- profile-aware AW base dir;
- `create_window_dir(window_id)`;
- atomic JSON read/write;
- append-only events;
- active-window lock/refusal;
- phase update helpers;
- artifact path helpers.

Use the Marinator plugin `state.py` as the reference pattern. Preserve explicit `HERMES_HOME` override behavior for tests/profile isolation.

### Task 3 — Implement `autonomous_work_start`

File:

```text
hermes/initialization/plugins/autonomous-work/tools.py
```

Test expectations:

- invalid duration rejected;
- active window rejected;
- creates state files;
- starts runner only after state is written;
- returns machine-readable result.

### Task 4 — Implement transition table

Files:

```text
hermes/initialization/plugins/autonomous-work/tools.py
hermes/initialization/plugins/autonomous-work/prompts.py
```

Implement `autonomous_work_step()` with deterministic transitions.

Do not let model-facing arguments choose the transition.

### Task 5 — Implement `aw-runner.sh`

File:

```text
hermes/initialization/plugins/autonomous-work/scripts/aw-runner.sh
```

Responsibilities:

- acquire runner lock;
- read `window.json`;
- run one headless Hermes AW step;
- capture stdout/stderr;
- read state after the step;
- continue only on `continuation=continue_now`;
- stop on `wait_external`, `final`, `blocked`, `failed`, `cancelled`;
- never make product decisions.

### Task 6 — Install plugin in hire script

Modify:

```text
hermes/scripts/hire-junie.sh
```

Install and enable `autonomous-work` like `marinator-delegation`.

Enable required toolsets for Junie channels:

```text
autonomous
marinator
terminal
file
messaging
```

Only add messaging if the existing Junie setup already uses it for owner communication; otherwise follow current gateway/send_message conventions.

### Task 7 — Update skills/docs

Modify:

```text
hermes/initialization/skills/junie-autonomous-work-window/SKILL.md
hermes/docs/overnight-routines.md
hermes/docs/implementation-status.md
hermes/initialization/docs/delegation-protocol.md (only if needed)
```

Replace cron-first AW instructions with:

```text
admin request -> autonomous_work_start(duration, prompt)
```

Document cron/watchdog as deferred recovery only.

## 18. Verification / spike matrix

Before claiming MVP works, run these gates.

### Unit-level / script gates

- `bash -n` for all plugin scripts.
- `python3 -m py_compile` for plugin Python files.
- State helper tests with isolated `HERMES_HOME`.
- Transition table tests for every phase.

### Runtime spikes

1. `autonomous_work_start` creates a window and AW session.
2. Fake AW step calls `autonomous_work_step()` and returns `continue_now`; runner resumes next step.
3. Fake AW step returns `wait_external`; runner stops and does not loop.
4. Fake invalid state; tool refuses transition and marks failed.
5. Fake selected docs-only item reaches terminal outcome; AW returns to full snapshot/preflight.
6. Fake selected code item calls `marinator_delegate`; Marinator completion wake resumes same AW session.
7. Marinator attention/no-log-progress during `executing_task`; resumed AW session can write `control/kill`; wrapper kills OpenCode; AW can start follow-up worker.
8. Deadline reached after selected item completion; AW finalizes instead of selecting new work.
9. No eligible work; AW finalizes truthfully.
10. Cancel file present; AW cancels and stops runner.

Use `hermes/scripts/spike-marinator-headless-stall-full-loop.sh` as the reference for Marinator attention/kill/restart behavior.

## 19. Acceptance criteria

MVP is accepted only when:

- owner can start one bounded AW window from Telegram or CLI;
- active-window refusal prevents overlapping windows;
- AW runs through at least one planning cycle in a dedicated AW headless session;
- AW selects work through deterministic `autonomous_work_step` transitions;
- selected code work uses ordinary Marinator and no direct coding path;
- selected task execution and Marinator review/fix/acceptance are one `executing_task` phase;
- AW returns to full snapshot/preflight after a terminal selected-item outcome;
- final report truthfully lists completed, blocked, skipped, and verified work;
- runtime state is profile-local and inspectable;
- no cron/Kanban dependency is required for the core loop;
- spike matrix passes.

## 20. Implementation cautions

- Keep the MVP linear.
- Do not introduce Kanban “just in case.”
- Do not let runner logic decide product work.
- Do not rely on model memory for continuation; put the continuation rule in state, step prompts, and wake prompts.
- Do not block supervisor loops on resume helpers.
- Do not expose delivery targets/tokens/profile internals in public tool schemas.
- Do not add config knobs for optional progress reports; use per-call behavior only when the owner explicitly asks.
- Do not silently change backlog architecture while implementing AW.
- Do not mark delayed/flaky wake behavior as accepted.

## 21. Suggested implementation order

1. Add plugin skeleton and tool registration.
2. Add state helpers and isolated state tests.
3. Implement `autonomous_work_start` without runner launch; verify state creation.
4. Implement transition table for `autonomous_work_step` using fake artifacts.
5. Add prompt generation.
6. Add `aw-runner.sh` with fake step tests.
7. Wire real headless Hermes resume.
8. Integrate Marinator selected-task flow.
9. Update skill/docs/hire script.
10. Run spike matrix.

Commit in small slices after each accepted task. If following Danila’s normal workflow, leave changes staged/ready and let the owner commit unless Junie’s current authority docs explicitly say otherwise.

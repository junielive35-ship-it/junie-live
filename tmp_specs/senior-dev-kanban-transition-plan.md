# Senior Dev Kanban Transition Plan

**Goal:** move Junie Live code-task execution to Hermes Kanban while using OpenCode as Senior Dev for now.

**Architecture reference:** root diagram [`junie-architecture-20260615.png`](../junie-architecture-20260615.png).

**Decision:** Chat Agent is only the user-facing router. Kanban is the active task queue for Senior Dev work: one user-visible code request becomes one Senior Dev Kanban task. Senior Dev is effectively OpenCode today. We wrap OpenCode in a real Hermes Agent profile (`senior-dev`) to get Kanban communication, task lifecycle, origin-chat notifications, and child-process monitoring through existing Hermes/Marinator machinery. Future Junie CLI replaces OpenCode inside this executor path, not the Chat Agent/Kanban flow.

**Do not patch Hermes core.** Use Junie profile/plugin surfaces.

---

## Verified facts

- Helper-style code can read gateway origin context via `gateway.session_context.get_session_env`:
  - `HERMES_SESSION_PLATFORM`
  - `HERMES_SESSION_CHAT_ID`
  - `HERMES_SESSION_THREAD_ID`
  - `HERMES_SESSION_USER_ID`
  - `HERMES_SESSION_KEY`
- Helper-style code can create a Kanban task with `hermes_cli.kanban_db.create_task`.
- Helper-style code can subscribe the origin chat/thread with `hermes_cli.kanban_db.add_notify_sub`.
- Prior smoke created task `t_f28f85f1` and inserted a Telegram subscription for this DM.
- Hermes gateway notifier delivers subscribed task events: `completed`, `blocked`, `gave_up`, `crashed`, `timed_out`.
- `blocked` intentionally keeps the subscription; `done` / `archived` removes it after delivery.
- `marinator_delegate` already runs OpenCode with process supervision, logs, stall detection, result artifacts, and headless wake/resume.

## Target lifecycle

1. User asks Chat Agent for code work.
2. Chat Agent checks active Senior Kanban tasks for duplicates/follow-ups.
3. If new, Chat Agent **must** call the Junie Senior-task helper.
4. Helper creates one Kanban task, stores origin/repo metadata, calls `add_notify_sub`, and returns `task_id`.
5. Hermes dispatcher starts `senior-dev` profile for that task.
6. `senior-dev` reads task context/comments and calls `marinator_delegate`.
7. `marinator_delegate` runs/supervises OpenCode.
8. When Marinator wakes/resumes `senior-dev`, `senior-dev` reviews `status.json`, `result.md`, logs, and repo state.
9. `senior-dev` writes Kanban outcome:
   - success: `complete_task(..., expected_run_id=...)` with PR URLs/tests/changed files;
   - needs input/stall/failure: `kanban_comment` with diagnostics, then `block_task(..., reason=<one concise question>, expected_run_id=...)`.
10. Hermes gateway notifier reports terminal Kanban events to the original chat/thread.

## Status mapping

- `ready`: queued for `senior-dev`.
- `running`: `senior-dev` / Marinator / OpenCode executing.
- `blocked`: needs user input, stall decision, repeated child failure, missing access, or external blocker.
- `done`: PR evidence produced and recorded.
- `archived`: task intentionally closed after it is no longer active.

## Required Chat Agent entrypoint

All Chat Agent code-task delegation to Senior Dev **must** go through the Senior-task helper.

Do not call `kanban_create` or `hermes_cli.kanban_db.create_task` directly from Chat Agent for Senior Dev work unless the caller also performs the full helper contract, especially `add_notify_sub`. A bare Kanban task may execute, but the origin chat will not automatically receive status updates.

## Task metadata convention

Store in task body and/or run metadata:

```json
{
  "junie_task_type": "senior_dev_code_task",
  "source": {
    "platform": "telegram|slack|...",
    "chat_id": "...",
    "thread_id": "...",
    "user_id": "...",
    "session_key": "..."
  },
  "repo": "/abs/path/to/repo",
  "owned_area": "optional path or label",
  "marinator_job_id": "optional",
  "opencode_session_id": "optional",
  "pr_urls": [],
  "duplicate_keys": ["normalized intent / repo / area"]
}
```

---

## Phase 1 — Senior-task helper: create task + subscribe origin

**Objective:** add a Junie profile/plugin helper that atomically creates a Senior Dev Kanban task and subscribes the originating gateway thread.

**Behavior:**
- Input: title, request/body, repo, optional backlog id, optional idempotency key, optional priority.
- Resolve origin via `gateway.session_context.get_session_env`.
- Create Kanban task assigned to `senior-dev` using default initial status (`ready`).
- Store origin/session/repo/duplicate metadata.
- Call `add_notify_sub` for origin platform/chat/thread/user.
- Return `task_id`, status, subscription target, and duplicate/idempotency outcome.

**Verification:**
- Fake session-context smoke creates task and subscription.
- `hermes kanban notify-list <task_id>` shows the subscription.
- `hermes kanban show <task_id>` shows task metadata.

## Phase 2 — `senior-dev` profile uses `marinator_delegate`

**Objective:** make Kanban-spawned `senior-dev` execute the task by reusing existing Marinator/OpenCode supervision.

**Existing code to reuse:**
- Tool/schema: `hermes/distribution/plugins/marinator-delegation/tools.py`
- Launcher/state: `hermes/distribution/plugins/marinator-delegation/runner.py`
- OpenCode supervisor: `hermes/distribution/plugins/marinator-delegation/scripts/marinator-worker.sh`

**What Marinator already provides:**
- OpenCode binary resolution.
- Run directory with `spec.json`, `status.json`, `events.jsonl`, `result.md`.
- stdout/stderr/runner logs.
- child PID/PGID tracking and `control/kill`.
- no-log-progress stall detection.
- OpenCode session id extraction.
- headless wake/resume of the owning Hermes session.

**Behavior:**
1. Hermes dispatcher starts `senior-dev` normally: `hermes -p senior-dev chat -q "work kanban task <id>"`.
2. `senior-dev` reads Kanban task body/comments.
3. `senior-dev` writes a Marinator prompt file with fixed policy:
   - work on a branch;
   - do not merge/deploy/release;
   - open PR(s);
   - report PR URLs, tests, changed files, blockers.
4. `senior-dev` calls `marinator_delegate(job_id=<task_id-derived>, repo=<repo>, prompt_file=<generated>, enable_per_minute_reports=false)`.
5. Marinator supervises OpenCode and wakes/resumes `senior-dev` on completion/failure/attention.
6. Resumed `senior-dev` reads Marinator artifacts and closes or blocks the Kanban task.

**Required Marinator changes for Kanban Senior mode:**
- Support a Kanban/Senior invocation path where `job_id` is derived from `HERMES_KANBAN_TASK`.
- Persist Kanban linkage in Marinator state/artifacts: task id, board/db, run id, claim lock, workspace, and Kanban task URL/path if available.
- Allow `senior-dev` to pass a generated prompt file built from Kanban task body + comments/follow-ups.
- Make the wake/resume prompt Kanban-aware: resumed `senior-dev` must read Marinator artifacts, then update the Kanban task with `complete_task` or `block_task` before reporting anything else.
- Preserve existing OpenCode supervision behavior: binary resolution, logs, PID/PGID, `control/kill`, stall detection, session id extraction, result.md.
- Do not require OpenCode or future Junie CLI to know Kanban APIs.

**Progress reports:**
- Default MVP: `enable_per_minute_reports=false` to keep chat quiet.
- Optional later/debug: route progress summaries to a debug channel, not the user task thread.

**Blocked/stall behavior:**
- OpenCode/Marinator should not update Kanban directly.
- `senior-dev` converts Marinator terminal/attention states into Kanban:
  - completed with PR evidence → `complete_task`;
  - no-log stall, repeated failure, missing access, or unclear result → diagnostic `kanban_comment` + `block_task`.
- Because `blocked` keeps the subscription, user reply/follow-up can unblock and later `done` still reaches the same chat.

**Verification:**
- Harmless task invokes real `senior-dev` profile.
- `senior-dev` calls `marinator_delegate` and records Marinator `run_dir` / `job_id` in Kanban metadata/comment.
- Success path produces Kanban `done` with PR-style metadata.
- Simulated Marinator failure/attention produces diagnostic comment + Kanban `blocked` notification.
- `blocked` subscription remains; later unblock/complete notifies origin chat.

## Phase 3 — duplicate and follow-up routing

**Objective:** ensure active work is discoverable and follow-ups route to the existing task/session.

**Behavior:**
- Before creating a Senior task, Chat Agent lists active Senior Dev tasks.
- Match by repo/area/request duplicate keys and active statuses.
- If duplicate found:
  - subscribe current thread if not already subscribed;
  - append user message as Kanban comment;
  - reply with existing task id/status.
- If same thread sends follow-up, append comment to linked task.

**Verification:**
- Two simulated requests for same work do not create duplicate active tasks.
- Second thread becomes subscribed and receives terminal notification.
- `kanban_show` includes follow-up comments for Senior Dev.

---

## Non-goals for this transition

- Do not integrate Junie CLI yet; OpenCode remains the Marinator child command.
- Do not build a new OpenCode supervisor while Marinator can be reused.
- Do not expose junior/reviewer subtasks in Kanban.
- Do not add parallel Senior Dev workers.
- Do not replace product backlog with Kanban.
- Backlog-to-Kanban cross-linking is out of scope.
- PR merge/close lifecycle tracking is out of scope; MVP `done` means PR evidence was produced.
- Do not patch Hermes core unless profile/plugin implementation hits a verified blocker.
- Do not let Chat Agent do code review or direct coding.

## Open decisions

1. Exact helper/tool name.
2. Exact `senior-dev` profile prompt/protocol for using `marinator_delegate` and closing/blocking Kanban tasks.
3. Duplicate-key generation strategy.
4. Dedicated Senior board vs default board with metadata.
5. Whether/where to send optional Marinator progress reports.

## Recommended next step

Implement Phase 1, then configure `senior-dev` for Phase 2 using existing `marinator_delegate`. Do not write a new supervisor unless this reuse path fails in a focused integration test.

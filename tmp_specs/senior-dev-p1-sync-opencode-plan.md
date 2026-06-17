# Senior Dev p1: Sync OpenCode Kanban Prototype Plan

**Goal:** prove Chat Agent can route code tasks and follow-ups through Hermes Kanban to a dummy Senior Dev, with user-visible status updates.

**Non-goals:** no watchdog, no live follow-up interrupt into a running Senior, no PR merge monitoring, no new Marinator async continuation, no `marinator_delegate` tool.

## Decisions

- Kanban is the cross-cutting queue for all code work.
- `senior-dev` is temporary: a thin synchronous adapter around vanilla OpenCode.
- Reuse useful Marinator wrapper pieces: run dir, `spec.json`, `status.json`, `events.jsonl`, logs, `result.md`.
- Do not use `marinator_delegate`; replace that tool path for p1.
- Do not patch Hermes core for this path; use Junie/Hermes profile and plugin
  surfaces (`senior-task`, `senior-runner`, and `profiles/senior-dev`).
- Use `blocked` for both user input and review-required states:
  - `blocked: needs-input: ...`
  - `blocked: review-required: PR ...`
- `done` is not used until PR merge monitoring exists.
- Duplicate/follow-up detection is Chat Agent judgment from Kanban state, not script fuzzy matching.

## Code-backed facts to preserve from the transition plan

- `create_senior_task` reads origin metadata through
  `gateway.session_context.get_session_env` with environment fallback:
  `HERMES_SESSION_PLATFORM`, `HERMES_SESSION_CHAT_ID`,
  `HERMES_SESSION_THREAD_ID`, `HERMES_SESSION_USER_ID`, and
  `HERMES_SESSION_KEY`.
- Senior task bodies carry a trailing `_junie_metadata:` JSON line with
  `junie_task_type`, `source`, `repo`, `owned_area`, `opencode_session_id`,
  `pr_urls`, and `duplicate_keys`.
- The Senior-task helper creates tasks assigned to `senior-dev`, subscribes the
  origin chat/thread through `add_notify_sub`, and resubscribes an existing
  idempotency match before returning it as a duplicate.
- `senior_active_tasks` is implemented for Chat Agent routing; it lists active
  `senior-dev` tasks in `ready`, `running`, `blocked`, and `scheduled`, can
  filter by repo/current origin, and can include comments for block/follow-up
  judgment.
- The synchronous runner stores state under the profile's
  `junie-live/state/senior/runs/<job_id>` tree unless `SENIOR_RUNNER_BASE`
  overrides it for tests.
- The runner writes `prompt.md` in addition to `spec.json`, `status.json`,
  `events.jsonl`, `result.md`, `opencode.stdout.log`, `opencode.stderr.log`,
  and `runner.log`.
- `run-coding-task.sh` resolves the OpenCode binary, runs
  `opencode run --format json --dangerously-skip-permissions` synchronously,
  extracts the OpenCode session id from NDJSON output when present, and
  normalizes or synthesizes the `VERDICT` block so the worker always has a
  Kanban-mappable result.
- `senior-dev` is started with Kanban environment such as
  `HERMES_KANBAN_TASK`, `HERMES_KANBAN_RUN_ID`, `HERMES_KANBAN_BOARD`, and
  `HERMES_KANBAN_WORKSPACES_ROOT`; terminal Kanban blocks should pass
  `expected_run_id=HERMES_KANBAN_RUN_ID`.

## Target flow

1. User sends code request to Chat Agent.
2. Chat Agent checks active Senior tasks for the same chat/thread/repo.
3. If new: create Senior Kanban task and subscribe origin chat.
4. If follow-up to blocked/review task: add `kanban_comment`, unblock/requeue.
5. Kanban dispatcher starts `senior-dev` worker.
6. Worker marks/observes task as `running` and calls sync OpenCode runner.
7. Runner writes Marinator-style artifacts.
8. Worker maps result to Kanban:
   - PR ready → `kanban_comment` with result/PR, then `kanban_block("review-required: ...")`
   - needs user input → `kanban_block("needs-input: ...")`
   - infrastructure failure → `kanban_block("failed: ...")`
9. Gateway notification reaches origin chat.

## Task 1: Remove current Senior result-report shape from the p1 path

**Objective:** stop treating `senior_dev_task_result` as the primary p1 completion mechanism.

**Files to inspect/modify:**
- `hermes/distribution/plugins/senior-task/__init__.py`
- `hermes/distribution/plugins/senior-task/tools.py`
- `hermes/distribution/profiles/senior-dev/` files

**Implementation notes:**
- Keep `create_senior_task` or equivalent origin-subscription helper.
- Do not expose/use `senior_dev_task_result` in the new p1 Senior worker prompt/path.
- It can remain temporarily if removing it is too invasive, but p1 must not depend on it.

**Verify:** `./scripts/verify.sh` still passes.

## Task 2: Add `senior_run_coding_task` tool/plugin

**Objective:** give the `senior-dev` Kanban worker one synchronous tool that runs the dummy Senior executor and returns artifact paths.

**New plugin:** `hermes/distribution/plugins/senior-runner/`

**New tool:** `senior_run_coding_task`

**Toolset:** `senior_runner` (enable only for the `senior-dev` profile, not Chat Agent)

**Files:**
- Create: `hermes/distribution/plugins/senior-runner/__init__.py`
- Create: `hermes/distribution/plugins/senior-runner/tools.py`
- Create: `hermes/distribution/plugins/senior-runner/runner.py`
- Create: `hermes/distribution/plugins/senior-runner/scripts/run-coding-task.sh`
- Reuse/copy minimal helpers from `hermes/distribution/plugins/marinator-delegation/state.py`
- Reuse/adapt worker logic from `hermes/distribution/plugins/marinator-delegation/scripts/marinator-worker.sh`
- Update install/profile config so `senior-dev` loads this plugin/toolset.

**Tool input schema:**
- `task_id` string, required
- `repo` string, required absolute path
- `request` string, required
- `context` string, optional
- `job_id` string, optional safe id; default derived from task id + timestamp

**Tool behavior:**
- Creates run dir under the existing Marinator-style run root.
- Writes `prompt.md` containing the assembled OpenCode prompt.
- Writes `spec.json` and initial `status.json`.
- Calls `scripts/run-coding-task.sh` in foreground.
- Waits until OpenCode exits; no p1 hard timeout.
- Returns JSON with `ok`, `job_id`, `run_dir`, `status_path`, `result_path`, `exit_code`.
- Does not mutate Kanban. The Kanban worker does that after reading artifacts.

**Artifacts:**
- `prompt.md`
- `spec.json`
- `status.json`
- `events.jsonl`
- `result.md`
- `opencode.stdout.log`
- `opencode.stderr.log`
- `runner.log`

**Result discipline:** prompt OpenCode/dummy Senior to end `result.md` with:

```text
VERDICT: pr-ready|needs-input|failed
SUMMARY: <one sentence>
USER_MESSAGE: <message safe to send to the user>
PR_URL: <url or empty>
```

This verdict block is output discipline, not a long-term Senior API.

**Verify:** call `senior_run_coding_task` from a `senior-dev` test/profile context on a harmless prompt and confirm artifacts are written.

## Task 3: Implement Senior Kanban worker behavior

**Objective:** make `senior-dev` worker a thin adapter: Kanban task → sync runner → Kanban status.

**Files:**
- `hermes/distribution/profiles/senior-dev/` prompt/config files
- Any Senior plugin/helper introduced in Task 2

**Behavior:**
- Start with `kanban_show()`.
- Do not review code independently.
- Run sync Senior runner.
- Read `result.md` and current `status.json`.
- Add a concise `kanban_comment` with artifact paths and PR URL if present.
- End with exactly one terminal Kanban action:
  - `kanban_block("review-required: ...")`
  - `kanban_block("needs-input: ...")`
  - `kanban_block("failed: ...")`

**Verify:** a fake/short Senior run produces a blocked Kanban task and no protocol violation.

## Task 4: Chat Agent active-task lookup and follow-up routing

**Objective:** before creating a Senior task, Chat Agent should inspect active Senior tasks for this origin/repo.

**Files:**
- `hermes/distribution/plugins/senior-task/tools.py`
- Chat Agent prompt/docs if needed

**Existing helper contract:**
- `create_senior_task` must be the Chat Agent entrypoint for new Senior Dev
  work because it creates the task and subscribes the origin chat/thread.
- A bare `kanban_create` or direct `kanban_db.create_task` call is insufficient
  unless it also performs the helper contract, especially origin subscription
  and metadata storage.
- Use `senior_active_tasks` before `create_senior_task` to inspect active
  Senior work by repo/origin and comments.

**Rules:**
- If no related active task: create a new task.
- If related `ready/running`: add comment; tell user it was attached. Do not live-interrupt in p1.
- If related `blocked`: add comment, unblock/requeue if the user answered the block/review ask.
- If related `done/archived`: create a new task or child task based on agent judgment.
- Duplicate decision is semantic agent judgment from Kanban state.

**Verify:** repeat/follow-up Telegram-style calls do not create duplicate tasks when an active related task exists.

## Task 5: Status notifications

**Objective:** ensure user sees useful updates without internal tool noise.

**Required user-visible updates:**
- queued/created
- picked up/running if feasible in current notifier path
- blocked needs input
- blocked review-required with PR URL

**Files to inspect/modify:**
- Hermes Kanban notification code in Hermes Agent gateway/kanban paths
- `create_senior_task` origin subscription code

**Acceptance:** origin Telegram chat receives terminal blocked notifications for needs-input and review-required.

## Task 6: Disable or bypass code mutex in the active p1 path

**Objective:** Kanban becomes the concurrency boundary for code work.

**Rules:**
- Do not remove mutex code yet.
- Ensure Chat Agent routing all go through Kanban for code work.
- Senior lane must not start parallel code runs for the same repo in p1.

**Verify:** two code requests create/attach to Kanban work rather than bypassing into direct code execution.

## Final verification checklist

- `cd /home/Danila.Savenkov/code/junie-live/hermes && ./scripts/verify.sh`
- Create one Senior task from Chat Agent path.
- Confirm task reaches `running` when picked up.
- Confirm sync OpenCode run writes artifacts.
- Confirm PR-ready result becomes `blocked(review-required: ...)`.
- Confirm origin Telegram notification is sent.
- Send follow-up to the same chat and confirm it attaches to existing task instead of creating a duplicate.

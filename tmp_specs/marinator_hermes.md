# Marinator on Hermes — spec + implementation plan

Status: draft spec/plan for Hermes MVP
Source inputs: OpenClaw root implementation, current `hermes/` baseline, `tmp_specs/marinator_*` continuation notes. The requested `tpm-specs/` directory was not present; the existing `tmp_specs/` Marinator docs were used.

## First 50-line summary

Marinator on Hermes keeps the same product contract as OpenClaw: one orchestrator session owns task validation, decomposition, coding-worker delegation, review, fix requests, verification, acceptance, reporting, and reflection. The orchestrator never writes code directly; code-changing work still goes to OpenCode (`/home/Danila.Savenkov/.opencode/bin/opencode`) using OpenCode's configured default model/settings.

Hermes changes the runtime substrate, not the delegation protocol:

```text
live Telegram/CLI/TUI orchestrator session
  -> calls marinator_delegate
  -> marinator_delegate writes run_dir/spec/prompt
  -> starts a Marinator wrapper with terminal(background=true, notify_on_complete=true)
  -> wrapper runs opencode, captures logs, writes ATTENTION/DONE markers to logs
  -> Hermes live session reliably wakes on wrapper completion/failure
  -> orchestrator reads durable run_dir and decides wait/kill/steer/fix/accept
```

For headless one-shot sessions, there is no live event loop to drain background notifications after the parent `hermes chat -q` exits. Headless Marinator therefore uses the already-validated primitive:

```text
wrapper/watchdog event
  -> hermes -p <profile> chat --resume <owner_session_id> -q "inspect run_dir ..."
```

Do **not** port OpenClaw's `system event` / raw-Cron continuation machinery as the main path. In Hermes, live sessions use `terminal(background=true, notify_on_complete=true)` for reliable completion/failure wake; headless sessions use `hermes chat --resume`. `watch_patterns` markers are still emitted for future upstream support, but are not the reliable MVP wake path.

Do **not** make the wrapper kill OpenCode on suspected stall. Suspected stall is evidence, not a decision. The wrapper records/prints `MARINATOR_ATTENTION_REQUIRED`; the orchestrator decides whether to wait, steer, kill, ask the user, or delegate a fix.

Do **not** use Kanban in the MVP. Kanban is useful later for multi-profile boards/backlog/fan-out, but it does not provide semantic OpenCode stall detection and would add an unnecessary abstraction over the linear delegation protocol.

The custom code that remains is intentionally small: a Hermes `marinator_delegate` tool/plugin, a Marinator wrapper script, a durable run ledger under the Hermes profile, and optional headless resume helper. Hermes owns process tracking, live routing, and notification delivery.

## 1. Goals

1. Preserve Junie Live's Marinator protocol from OpenClaw:
   - orchestrator owns context, planning, delegation, review, acceptance;
   - OpenCode performs scoped code changes;
   - user-visible outcome evidence gates "done";
   - fix loops remain in the same orchestrator session.
2. Replace OpenClaw-specific continuation mechanisms with Hermes-native primitives:
   - live interactive sessions: `terminal(background=true, notify_on_complete=true)`;
   - headless one-shot sessions: `hermes chat --resume <session_id> -q ...`.
3. Keep the MVP linear. No Kanban board abstraction for the delegation protocol.
4. Keep worker observability:
   - progress summaries every ~60s;
   - explicit attention-required events;
   - durable logs/result artifacts.
5. Keep kill/steer/wait decisions with the orchestrator, not with the wrapper.

## 2. Non-goals

- Do not implement Kanban-backed Marinator in the MVP.
- Do not make Hermes cron the primary continuation path.
- Do not auto-kill OpenCode on no-progress detection.
- Do not stream raw OpenCode logs directly into Telegram as the main UX.
- Do not rely on `notify_on_complete + watch_patterns` together; Hermes currently treats them as mutually exclusive.
- Do not copy OpenClaw's raw Cron/sessionTarget implementation into Hermes unless a later spike proves it is useful and simpler.
- Do not change the high-level delegation protocol to fit Hermes internals.

## 3. Existing evidence and conclusions

### 3.1 OpenClaw implementation

Current OpenClaw `marinator_delegate` is implemented under:

```text
initialization/marinator-delegation/
  src/index.ts
  scripts/delegate-coding-task.sh
```

The current runner is valuable because it provides:

- durable `run_dir` with `status.json`, `events.jsonl`, `result.md`, logs, pid/exit/control files;
- OpenCode stdout/stderr capture;
- progress delta summaries;
- terminal worker outcomes;
- continuation handoff back to the owning session.

But the OpenClaw continuation path required fragile system-event/Cron workarounds. Hermes should not inherit those workarounds when it has better primitives.

### 3.2 Hermes spike conclusions

Validated:

- `hermes chat --resume <session_id> -q "...inspect run_dir..."` works for headless continuation.
- The same CLI resume can read a Telegram-backed session transcript, but CLI stdout is not gateway delivery; live Telegram should use gateway/background-process routing instead.
- Hermes `terminal(background=true, notify_on_complete=true)` wakes live gateway/CLI/TUI loops on completion/failure; spike confirmed it triggers a full agent turn where tools can be called.
- Hermes `watch_patterns` can wake/notify while a background process is still running, but current live Telegram delivery is not prompt/reliable enough for Marinator. It has hard spam protection and is mutually exclusive with `notify_on_complete`.

Important constraints:

- Headless one-shot sessions have no live loop after the parent process exits; automatic background notifications are not enough there.
- Watch patterns are for rare markers, not frequent progress streaming. They are emitted for future upstream support but are not the reliable MVP wake path.
- Progress visibility must not use `watch_patterns` or trigger worker/orchestrator wake. Standard `send_message` may mirror; this is accepted for MVP.
- Live completion/failure wake uses `notify_on_complete`; orchestrator must read durable `run_dir` artifacts rather than trusting only notification text/exit code.

## 4. Runtime model

### 4.1 Live session path

A live session is a Hermes gateway/CLI/TUI process that remains alive and drains background notifications.

```text
orchestrator turn
  -> marinator_delegate(...)
  -> terminal(background=true, notify_on_complete=true) starts wrapper
  -> turn may end naturally
  -> wrapper sends optional progress reports through Telegram send_message and logs rare watch markers
  -> Hermes completion watcher routes completion/failure to the same live session
  -> orchestrator continues review/fix/acceptance
```

Use this for Telegram-first Junie operation.

### 4.2 Headless path

A headless owner session is a one-shot `hermes chat -q` whose process exits after returning.

```text
orchestrator one-shot starts wrapper
  -> parent Hermes exits
  -> wrapper reaches DONE or ATTENTION_REQUIRED
  -> wrapper invokes `hermes -p <profile> chat --resume <owner_session_id> -q <continuation prompt>`
  -> new Hermes process loads the same session and continues the Marinator loop
```

Use a per-owner-session lock to avoid concurrent resume processes writing the same transcript.

### 4.3 Optional recovery path

A no-agent cron/script may scan run ledgers for unconsumed events and call the same headless resume helper. This is a recovery watchdog only, not the primary live continuation mechanism.

## 5. Run ledger

Store Marinator state under the Hermes profile, not the target repo:

```text
$HERMES_HOME/junie-live/state/marinator/
  runs/<job_id>/
    spec.json
    prompt.md
    status.json
    events.jsonl
    result.md
    opencode.stdout.log
    opencode.stderr.log
    opencode.pid
    opencode.pgid
    opencode.exit
    opencode-waiter.pid
    runner.log
    control/
      kill
      steer.txt
    locks/
      wake.<event>
  owner-session-locks/<session_id>.lock
```

`status.json` minimal shape:

```json
{
  "job_id": "...",
  "owner_session_id": "20260531_...",
  "owner_session_key": "agent:main:telegram:dm:...",
  "runtime": {
    "mode": "live_gateway|headless",
    "detected_from": {
      "HERMES_SESSION_PLATFORM": "telegram",
      "HERMES_SESSION_CHAT_ID": "..."
    }
  },
  "repo": "/abs/path/to/repo",
  "run_dir": "/abs/path/to/run_dir",
  "opencode": {
    "bin": "/home/Danila.Savenkov/.opencode/bin/opencode",
    "pid": null,
    "pgid": null,
    "exit_code": null,
    "previous_session_id": null,
    "session_id": null,
    "skip_permissions": true
  },
  "worker_state": "queued|running|completed|failed|attention_required|cancelled",
  "attention": {
    "state": "none|suspected_stall|needs_decision",
    "reason": "no_log_progress|explicit_marker|runner_error",
    "detected_at": null
  },
  "wake": {
    "done_sent_at": null,
    "attention_sent_at": null,
    "last_resume_session_id": null,
    "last_error": null
  }
}
```

`events.jsonl` records append-only machine events:

- `job_created`
- `opencode_started`
- `progress_summary`
- `attention_required`
- `done_marker_emitted`
- `headless_resume_started`
- `headless_resume_completed`
- `orchestrator_decision_recorded`
- `cancel_requested`

## 6. Wrapper output contract

OpenCode raw logs go to files. Wrapper stdout is curated because Hermes may show it in Telegram.

Progress line, every ~60s:

```text
MARINATOR_PROGRESS job_id=<id> elapsed=<s> summary=<short factual summary>
```

`MARINATOR_PROGRESS` is **operator-visible debug output**. It must not be printed to wrapper stdout and must not be included in `watch_patterns`. It is disabled by default and only sent when `enable_per_minute_reports=true`. Deliver it through profile-aware standard Hermes Telegram `send_message`. It must not wake the orchestrator.

Attention marker, rare and watch-matched:

```text
MARINATOR_ATTENTION_REQUIRED job_id=<id> reason=<reason> run_dir=<path> status_path=<path>
```

Done marker, rare marker for logs and future watch support:

```text
MARINATOR_DONE job_id=<id> state=<completed|failed> exit_code=<n> run_dir=<path> result_path=<path>
```

Watch patterns to emit/support for live gateway mode once upstream delivery is reliable:

```python
[
  "MARINATOR_ATTENTION_REQUIRED",
  "MARINATOR_DONE"
]
```

Do not include `MARINATOR_PROGRESS` in watch patterns. Progress is debug visibility, not an agent wake request. Optional progress reports are controlled only by the `marinator_delegate.enable_per_minute_reports` tool argument; do not add a Hermes YAML/config knob for them.

Known MVP caveat: current Hermes `watch_patterns` delivery is not fully reliable/prompt in live Telegram sessions. The spike showed that a watch event can reach the same session and trigger an orchestrator turn, but delivery may be delayed until a later gateway queue drain instead of waking immediately. This is likely an upstream background-notification delivery bug/limitation, not a Marinator-specific issue. For MVP, the wrapper still writes `MARINATOR_ATTENTION_REQUIRED` / `MARINATOR_DONE` marker lines to logs/stdout so Marinator automatically benefits if/when upstream provides event-driven watch delivery, but live wake must rely on `notify_on_complete` until then.

Do not set both `notify_on_complete=true` and `watch_patterns` in the same Hermes terminal tool call in MVP; current Hermes ignores watch patterns when both are provided. The wrapper may still print marker lines, but `marinator_delegate` starts the wrapper with `notify_on_complete=true` and no `watch_patterns` for the reliable MVP live path.

## 7. OpenCode invocation and supervision contract

Reference implementation: `initialization/marinator-delegation/scripts/delegate-coding-task.sh` in the OpenClaw seed. The Hermes wrapper should preserve its useful OpenCode runner semantics while replacing only the OpenClaw-specific continuation/delivery path.

OpenCode binary resolution:

1. use `OPENCODE_BIN` if provided;
2. otherwise use `opencode` from `PATH` when available;
3. otherwise use `/home/Danila.Savenkov/.opencode/bin/opencode` when executable;
4. otherwise fail with `opencode_not_found`.

OpenCode is launched from the target repo directory as an isolated process group:

```bash
cd "$repo"
setsid "$OPENCODE_BIN" "${OPENCODE_ARGS[@]}" >"$stdout_log" 2>"$stderr_log" &
```

The wrapper records:

- `opencode.pid`;
- `opencode.pgid`;
- `opencode.exit`;
- `opencode-waiter.pid`;
- `opencode.stdout.log`;
- `opencode.stderr.log`.

Run OpenCode headlessly with permission prompts skipped. Treat `--dangerously-skip-permissions` as a required OpenCode capability for this integration, not as an optional feature to probe for:

```bash
opencode run --dangerously-skip-permissions <prompt>
```

This skip-permissions flag applies only to the delegated worker, not to the Hermes orchestrator. Safety is enforced by Marinator's bounded run, durable logs, mutex/protocol, orchestrator review, fix loop, and verification-before-reporting contract.

Follow-up/fix workers may continue the previous OpenCode context. If `opencode_previous_session_id` is provided:

1. inspect `opencode run --help`;
2. prefer `opencode run --session <id>` when supported;
3. fallback to `opencode run --resume <id>` when supported;
4. otherwise fail fast with `opencode_resume_not_supported` and wake the orchestrator.

The wrapper must capture the OpenCode session id produced by the run using the same extraction approach as the OpenClaw implementation, store it in `status.json.opencode.session_id`, include it in `result.md`, and return enough metadata for the orchestrator to pass it as `opencode_previous_session_id` in a follow-up/fix `marinator_delegate` call.

Progress supervision mirrors the OpenClaw runner:

- compare `opencode.stdout.log` and `opencode.stderr.log` byte sizes in the monitor loop;
- update `last_progress_epoch` whenever either log grows;
- every `update_interval_seconds` (default target for Hermes MVP: ~60s when reports are enabled), build a progress context from:
  - `status.json` tail;
  - recent `events.jsonl` lines;
  - `runner.log` tail;
  - stdout/stderr delta since the previous summary;
  - stdout/stderr tail;
- summarize that context into a concise human debug report;
- send the report through standard Hermes Telegram `send_message` only when `enable_per_minute_reports=true`, using the resolved progress delivery target from `spec.json`;
- always append the summary/evidence to `events.jsonl` even when Telegram reports are disabled.

Progress delivery routing is runtime-resolved, not LLM-provided. The public `marinator_delegate` schema must not include Telegram chat ids, tokens, targets, or profile fields. The LLM only decides whether `enable_per_minute_reports` should be `true` based on an explicit user request. `marinator_delegate` code resolves and stores internal delivery metadata in `spec.json` from the current Hermes session context:

- `HERMES_SESSION_PLATFORM`;
- `HERMES_SESSION_CHAT_ID`;
- `HERMES_SESSION_THREAD_ID` when present;
- active Hermes profile / configured Junie profile.

Internal `spec.json` shape:

```json
{
  "progress_delivery": {
    "enabled": true,
    "profile": "junie-live",
    "platform": "telegram",
    "target": "telegram:<chat_id>[:<thread_id>]",
    "source": "hermes_session_context"
  }
}
```

Tokens must never be written to `spec.json`, logs, result files, or prompts. They stay in the Hermes profile `.env`/config only.

Do not call `tools.send_message_tool` directly from an arbitrary inherited worker environment: it can inherit the wrong `TELEGRAM_BOT_TOKEN` from another profile/bot. For MVP, invoke progress send through a profile-aware Hermes child process such as:

```bash
hermes -p "$profile" chat -Q -t messaging \
  -q "Use send_message to send this exact message to target $target: $message. Then reply only SEND_DONE."
```

If no explicit target can be resolved, append `progress_send_skipped reason=missing_runtime_delivery_context` to `events.jsonl` and continue the worker. Do not ask the LLM/user for a chat id mid-run.

No-progress detection should use the same log-growth signal, but unlike the current OpenClaw wrapper it must not kill OpenCode automatically. On suspected stall, record evidence, emit `MARINATOR_ATTENTION_REQUIRED`, and keep supervising unless the orchestrator writes an explicit control action.

## 8. Stall / no-progress policy

The wrapper may detect suspected stall, but must not kill OpenCode automatically.

Detection examples:

- no stdout/stderr byte growth for `no_progress_seconds`;
- repeated identical summaries;
- runner-visible transport/tool loop errors;
- wrapper cannot read expected artifacts.

On suspected stall:

1. write `status.json.attention.state="suspected_stall"`;
2. append `attention_required` event;
3. emit `MARINATOR_ATTENTION_REQUIRED ...` marker lines for logs/future watch support;
4. keep OpenCode running unless the orchestrator later writes `control/kill` or equivalent;
5. continue low-frequency monitoring/progress if possible.

In live MVP, suspected stall is not guaranteed to interrupt the orchestrator immediately. It is visible through requested per-minute debug reports, durable `run_dir` state, eventual completion/failure wake, or future upstream reliable `watch_patterns` delivery.

The orchestrator decides:

- wait longer;
- inspect logs/diff;
- ask user;
- write `control/kill`;
- steer the worker if supported;
- start a follow-up/fix worker;
- mark blocked.

## 9. `marinator_delegate` Hermes tool behavior

Inputs:

```json
{
  "job_id": "stable-id",
  "repo": "/abs/path/to/repo",
  "prompt_file": "/abs/path/to/prompt.md",
  "attachments": ["/optional/path"],
  "opencode_previous_session_id": null,
  "enable_per_minute_reports": false
}
```

Runtime mode is auto-detected. The tool never asks the orchestrator, LLM, or user to choose live vs headless. A debug-only environment override such as `MARINATOR_FORCE_MODE=live_gateway|headless` may exist for tests, but it must not be part of the normal tool schema.

`enable_per_minute_reports` defaults to `false`. Set it to `true` only when the user explicitly asked to receive once-per-minute progress reports. The flag controls human-visible debug progress only; it must not affect orchestrator wake semantics.

`opencode_previous_session_id` is optional and is used for follow-up/fix delegation. When present, the wrapper continues the previous OpenCode session via `--session` or `--resume` as described in section 7.

Behavior:

1. Validate absolute paths and safe `job_id`.
2. Resolve owner metadata:
   - `HERMES_SESSION_ID` for owner session id;
   - gateway session env for live routing when present;
   - explicit tool context if Hermes exposes it.
3. Create `run_dir` and `spec.json`.
4. Write or copy `prompt.md`.
5. Detect runtime mode from Hermes context:
   - `live_gateway` when `HERMES_SESSION_PLATFORM` and `HERMES_SESSION_CHAT_ID` are present;
   - `headless` otherwise for MVP purposes.
6. In `live_gateway`, start wrapper with `terminal(background=true, notify_on_complete=true)` and no `watch_patterns` in the tool call. In `headless`, start the wrapper in background and rely on the wrapper's `hermes chat --resume` continuation helper.
7. Store `enable_per_minute_reports` in `spec.json`.
8. If `enable_per_minute_reports=true`, resolve `progress_delivery` from runtime session metadata and store only non-secret routing metadata in `spec.json`. If routing cannot be resolved, store disabled/skipped progress delivery and continue.
9. For `headless`, include `owner_session_id` and resume command details in `spec.json`; wrapper must call `hermes chat --resume` for done/attention events.
10. Return immediately with `job_id`, `run_dir`, process id/session id, detected runtime mode, and per-minute report setting.

Return shape:

```json
{
  "job_id": "...",
  "run_dir": "...",
  "process_session_id": "proc_...",
  "runtime_mode": "live_gateway|headless",
  "enable_per_minute_reports": false,
  "status_path": ".../status.json",
  "message": "Delegated coding task. I will review the result when Marinator wakes this session."
}
```

## 10. Headless resume helper

Wrapper calls this only when no live loop can be relied on.

Command shape:

```bash
cd "$repo"
hermes -p "$profile" chat \
  --resume "$owner_session_id" \
  --toolsets terminal,file \
  -q "Marinator worker job_id=$job_id reached state=$event. run_dir=$run_dir. Read status.json, result.md, stdout/stderr logs, inspect repo diff, then follow the Marinator delegation protocol: review, decide accept/fix/wait/kill/block, and do not report success unless the requested user-visible outcome is verified."
```

Rules:

- acquire per-owner-session lock before calling resume;
- mark wake event exactly once;
- launch the resume helper asynchronously and immediately return to the wrapper supervision loop;
- never block OpenCode supervision on `hermes chat --resume`; a resumed orchestrator may write `control/kill`, and the wrapper must keep polling that control file while resume is running;
- record the resume helper pid and stdout/stderr of the resume call under `run_dir`;
- never assume resume delivery to Telegram; headless continuation writes to the session transcript/stdout only.

## 11. Live Telegram behavior

The live Telegram UX has two separate channels:

1. **Orchestrator-visible semantic events** — rare events that wake the orchestrator and enter the reasoning loop.
2. **Operator-visible debug progress** — optional periodic status messages for the human.

Orchestrator-visible milestones:

- “Delegated job `<job_id>` to OpenCode.”
- “Worker needs attention; reviewing logs” after the completion wake and `status.json.attention` indicates attention is required.
- “Worker finished; reviewing result/diff” after `notify_on_complete` wakes the session and `status.json`/`result.md` confirms terminal state.
- if rejected: “Not accepted because ... delegating fixes.”
- final report only after outcome evidence is verified.

Operator-visible debug progress:

- every ~60s the wrapper may send/emit a concise `MARINATOR_PROGRESS` summary;
- this channel is disabled by default and is active only when `enable_per_minute_reports=true`;
- set `enable_per_minute_reports=true` only when the user explicitly requested once-per-minute progress reports;
- when disabled, live Telegram has no in-progress status stream; it wakes on completion/failure only. Mid-run progress visibility becomes available only through explicitly requested debug messages, and future reliable upstream `watch_patterns` delivery may allow more live attention/progress semantics later;
- these messages are for human debugging (“OpenCode is doing something”);
- they must not be watch-matched;
- they are sent with the profile-aware standard Hermes Telegram `send_message` path.

Do not patch Hermes or add a special no-mirror messaging path for this MVP. Use standard Hermes Telegram send only, and only when `enable_per_minute_reports=true`.

## 12. Kanban decision

Kanban is explicitly deferred for this MVP.

Reason:

- the delegation protocol remains a single linear orchestrator session;
- modern LLMs can decompose, delegate sequentially, review, request fixes, and add context without a board abstraction;
- Kanban does not provide semantic OpenCode stall detection;
- Kanban is useful later for multi-profile backlogs, dashboards, fan-out/fan-in, or operator queues.

Do not implement Marinator as Kanban tasks unless a later product decision changes the architecture.

## 13. How `marinator_delegate` becomes available

Implement `marinator_delegate` as a Hermes user plugin shipped with the Junie Live Hermes initialization, not as a core Hermes patch, not as an MCP server, and not as a standalone temporary shell wrapper.

The source of truth for the public tool schema is section 9 of this spec. The implementation should preserve that schema unless the spec is explicitly updated.

Source location in this repo:

```text
hermes/initialization/plugins/marinator-delegation/
```

Installed profile location after `hire-junie.sh`:

```text
~/.hermes/profiles/junie-live/plugins/marinator-delegation/
```

`hire-junie.sh` copies the plugin into the Junie Live Hermes profile, enables the plugin, and enables its `marinator` toolset for CLI and Telegram. Hot-swapping the plugin into an already-running Junie/Hermes session is not required for this MVP; it is acceptable that the tool only becomes available as part of the normal `hire-junie.sh` initialization flow and after the relevant Hermes gateway/CLI session is restarted or reset. After initialization, Junie should see one new tool:

```text
marinator_delegate
```

This matters because a future coding agent might otherwise choose a locally-working but wrong integration point, such as modifying Hermes core `tools/`, exposing an MCP server, or calling OpenCode directly. For this MVP, the approved integration point is the profile-installed Hermes plugin.

## 14. Files to add/modify

### New Hermes Marinator plugin package

Seed layout in this repo:

```text
hermes/initialization/plugins/marinator-delegation/
  plugin.yaml
  __init__.py
  tools.py
  runner.py
  state.py
  scripts/marinator-worker.sh
  tests/
```

Installed profile layout after `hire-junie.sh`:

```text
~/.hermes/profiles/junie-live/plugins/marinator-delegation/
  plugin.yaml
  __init__.py
  tools.py
  runner.py
  state.py
  scripts/marinator-worker.sh
```

`plugin.yaml`:

```yaml
name: marinator-delegation
version: 0.1.0
description: "Junie Live Marinator delegation tool: start supervised OpenCode worker runs and wake the owning Hermes session for review."
author: Danila Savenkov / Junie Live
kind: standalone
provides_tools:
  - marinator_delegate
```

`__init__.py` registers the tool:

```python
def register(ctx) -> None:
    from .tools import MARINATOR_DELEGATE_SCHEMA, handle_marinator_delegate, check_requirements
    ctx.register_tool(
        name="marinator_delegate",
        toolset="marinator",
        schema=MARINATOR_DELEGATE_SCHEMA,
        handler=handle_marinator_delegate,
        check_fn=check_requirements,
        description="Delegate a code-changing task to the Junie Live Marinator/OpenCode worker.",
        emoji="🧭",
    )
```

`tools.py` owns the public schema and thin handler. It validates inputs, calls `runner.start_job(...)`, and returns JSON. It does not run OpenCode directly.

`runner.py` owns runtime detection, run-dir creation, `spec.json` writing, and spawning `scripts/marinator-worker.sh` through Hermes terminal background semantics.

`state.py` owns JSON/event helpers and exactly-once wake markers.

`marinator-worker.sh` owns OpenCode execution, log capture, progress summaries, attention/done markers, and headless `hermes chat --resume` calls.

The hire script must:

1. copy `hermes/initialization/plugins/marinator-delegation/` to `$PROFILE_DIR/plugins/marinator-delegation/`;
2. enable the plugin in the profile config:

```bash
hermes -p junie-live config set plugins.enabled '["marinator-delegation"]'
```

3. enable the plugin toolset for CLI and Telegram:

```bash
hermes -p junie-live tools enable --platform cli marinator
hermes -p junie-live tools enable --platform telegram marinator
```

4. ensure the existing `terminal` and `file` toolsets remain enabled for Telegram/CLI, because `marinator_delegate` relies on Hermes terminal background process routing and later review reads run artifacts.

Initialization behavior:

- `INITIALIZATION.md` must mention that `marinator_delegate` is installed by the hire script and is the only approved code-changing delegation tool.
- `SOUL.md` / `HERMES.md` / `delegation-protocol.md` must tell Junie to call `marinator_delegate` for code-changing work instead of invoking OpenCode directly.
- During initialization, Junie should verify the tool exists by checking `hermes -p junie-live tools list` or by asking Hermes tool availability in-session; failure is blocking for code-changing work.

### Existing Hermes docs to update after implementation

```text
hermes/docs/implementation-status.md
hermes/docs/architecture.md
hermes/initialization/docs/delegation-protocol.md
hermes/initialization/docs/tools.md
hermes/scripts/verify.sh
```

### Do not modify for MVP

```text
OpenClaw root Marinator files
Kanban configuration
OpenClaw raw Cron continuation code
```

unless explicitly porting shared constants/docs.

## 15. Implementation plan

### Phase 0 — completed spikes / accepted evidence

1. Plugin registration PASS: a profile plugin under `$HERMES_HOME/plugins/marinator-delegation/` can register `marinator_delegate` under the `marinator` toolset after `hermes -p junie-live plugins enable marinator-delegation` and restart/reset.
2. Headless resume PASS: `hermes chat --resume <owner_session_id> -q ...` restores the prior headless context, sees the stored `run_dir`, and can inspect artifacts.
3. Live `notify_on_complete` PASS: `terminal(background=true, notify_on_complete=true)` wakes the live Telegram session on success and failure, and the resulting turn can call tools such as `read_file`.
4. `watch_patterns` PARTIAL / known limitation: marker lines can reach the same live Telegram session and trigger an orchestrator turn, but delivery may be delayed/opportunistic. Do not use it as the reliable MVP wake mechanism until upstream provides event-driven delivery.
5. Progress delivery PASS with constraints: profile-aware standard Hermes `send_message` can send progress through the correct Junie Live bot when invoked via `hermes -p junie-live ...` and an explicit runtime-resolved target. Directly importing `send_message_tool` from an inherited worker env can use the wrong bot and is not accepted.

### Phase 1 — implement run ledger helpers

1. Create run directory layout.
2. Implement safe JSON read/write helpers.
3. Implement idempotent event append.
4. Implement wake markers (`wake.<event>` files or JSON fields).
5. Add tests for duplicate event suppression and corrupt status handling.

### Phase 2 — implement wrapper script

1. Validate `spec.json`.
2. Resolve OpenCode absolute path: `/home/Danila.Savenkov/.opencode/bin/opencode` by default.
3. Run OpenCode with its configured default model/settings and `--dangerously-skip-permissions`. Do not pass model/variant flags from Marinator in MVP.
4. Support `opencode_previous_session_id` via `opencode run --session <id>` or `--resume <id>`; fail with `opencode_resume_not_supported` if neither is available.
5. Redirect OpenCode stdout/stderr to files and record pid/pgid/waiter/exit artifacts.
6. Capture the resulting OpenCode session id when available and store it in `status.json`/`result.md` for follow-up fix loops.
7. Monitor stdout/stderr byte growth, update progress timestamps, and summarize deltas using the OpenClaw runner pattern.
8. Resolve progress delivery from runtime Hermes session metadata when `enable_per_minute_reports=true`; never accept chat ids/tokens as LLM-provided public tool parameters.
9. If `enable_per_minute_reports=true` and a target was resolved, send curated progress summaries every ~60s through profile-aware standard Hermes Telegram `send_message`; if false or unresolved, keep summaries in `events.jsonl` only.
10. Detect suspected stall without killing.
11. Emit/write `MARINATOR_ATTENTION_REQUIRED` marker lines once per attention state for logs/future watch support, but do not rely on them for reliable live wake in MVP.
12. On OpenCode exit, write `result.md`, update status, emit/write `MARINATOR_DONE`, and let `notify_on_complete` wake live sessions.
13. If detected runtime mode is `headless`, call resume helper for attention/done events.

### Phase 3 — implement Hermes `marinator_delegate`

1. Register tool schema matching the OpenClaw tool shape where possible.
2. Validate inputs.
3. Auto-detect runtime mode from Hermes session environment; do not expose mode selection as a public parameter.
4. Write `spec.json` and prompt artifacts.
5. Start wrapper with Hermes terminal background. Use `notify_on_complete=true` for `live_gateway`; do not pass `watch_patterns` in the MVP tool call while `notify_on_complete` is enabled.
6. Return `job_id/run_dir/process_session_id` immediately.
7. Ensure orchestrator prompt receives explicit instruction to review future terminal events.

### Phase 4 — control actions

Add minimal controls for orchestrator decisions:

- `kill` by writing `control/kill` or invoking a helper script;
- `wait` by recording decision and continuing monitoring;
- `steer` deferred unless OpenCode supports reliable stdin/session steering;
- `cancel` marks status and terminates if orchestrator chooses.

The wrapper may execute a kill only after an explicit orchestrator control action.

### Phase 5 — verification

Required checks:

1. Shell syntax:

```bash
bash -n hermes/marinator-delegation/scripts/marinator-worker.sh
```

2. Hermes seed verification:

```bash
bash hermes/scripts/verify.sh
```

3. Live Telegram E2E:

```text
Telegram request -> marinator_delegate -> optional requested progress -> notify_on_complete completion/failure wake -> orchestrator reads run_dir -> review/fix/final report
```

4. Headless E2E:

```text
hermes chat -q starts Marinator -> parent exits -> wrapper calls --resume -> resumed session inspects run_dir
```

5. Suspected stall E2E:

```text
wrapper detects no progress -> does not kill -> records attention evidence/marker -> live MVP may wait for completion wake or explicit user/debug review; headless resume/fallback can wake orchestrator -> orchestrator decides kill/wait
```

6. Duplicate wake guard:

```text
replaying same status/event must not create duplicate resume turns
```

## 16. Acceptance criteria

MVP is done when:

1. `marinator_delegate` exists in the Hermes implementation.
2. Coding work is started through OpenCode, not performed by the orchestrator.
3. Live Telegram sessions use `notify_on_complete=true` for reliable completion/failure wake. `MARINATOR_ATTENTION_REQUIRED` / `MARINATOR_DONE` marker lines are still emitted for logs and future upstream `watch_patterns` support, but current-Hermes watch delivery is a known caveat, not the reliable MVP wake path. Optional per-minute progress reports are sent through profile-aware standard Hermes Telegram `send_message` only when `enable_per_minute_reports=true` and runtime routing metadata was resolved.
4. Headless sessions continue via `hermes chat --resume` and inspect `run_dir` correctly.
5. Suspected stall records attention evidence and marker lines but does not kill OpenCode automatically. In live MVP, immediate attention wake is best-effort/future-upstream via `watch_patterns`; reliable wake is on completion/failure. In headless, the resume/fallback path can wake the orchestrator.
6. Orchestrator can explicitly kill/cancel/wait based on context.
7. `run_dir` contains durable `spec.json`, `status.json`, `events.jsonl`, logs, pid/pgid/exit artifacts, and `result.md`.
8. The first fix loop is demonstrated: worker result rejected -> fix delegated -> re-reviewed.
9. OpenCode is invoked with `--dangerously-skip-permissions` and supports follow-up/fix runs via `opencode_previous_session_id` when the OpenCode CLI exposes `--session` or `--resume`.
10. Progress supervision follows the OpenClaw runner pattern: stdout/stderr byte-growth tracking, delta summaries, and durable event/log artifacts.
11. Documentation/status files state that Kanban and cron-bound session continuation are deferred.

## 17. Known limitations before implementation

1. `watch_patterns` marker lines are emitted for live attention/done, but current Hermes delivery may be delayed until a later gateway queue drain. They are not the reliable MVP wake path while `notify_on_complete=true` is active. Track upstream fixes around event-driven background-process watch delivery; if/when fixed, Marinator should benefit without changing its marker contract.
2. Hot-swap plugin installation is not required. `marinator_delegate` only needs to become available through the normal `hire-junie.sh` initialization flow plus gateway/CLI restart or reset.

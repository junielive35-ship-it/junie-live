# OpenClaw Long Async Task Pain Points

This document captures the current Junie Live pain around long-running asynchronous work in OpenClaw. It is intended as input for comparing OpenClaw with Hermes and for deciding whether to keep hardening the OpenClaw-based architecture.

## Our use case

Junie Live is meant to behave like a persistent product-owning senior software engineer for one project. The important code-changing loop is the Marinator loop:

1. validate a task against strategy, architecture, and current implementation status;
2. acquire the code mutex;
3. delegate implementation to opencode via `marinator_delegate`;
4. monitor the worker for progress, terminal success, failure, timeout, or stall;
5. wake Junie back up;
6. Junie reviews `result.md`, logs, and the repository diff;
7. Junie either requests a fix, verifies and accepts, or reports a truthful blocked/failed outcome.

This is not just "run a command in the background." The key product requirement is that the owning Junie session must be able to react after the worker finishes or stalls, even if the original LLM turn has ended.

We need this in three contexts:

1. **Telegram-bound main session** — Danila asks Junie to do code work in Telegram. This mostly works today because the live/main session can be woken and can deliver a final report back to Telegram.
2. **Standalone headless session** — `openclaw agent --session-key ...` starts a Junie turn that calls `marinator_delegate`. The CLI process exits after the first turn, while opencode continues asynchronously. The headless session still needs to resume later to review/fix/report.
3. **Autonomous Work (AW)** — a future bounded autonomous work window repeatedly plans, selects work, delegates through Marinator, waits for terminal worker outcomes, reviews/fixes, updates backlog/status, and continues until deadline/block/completion.

## Current Marinator implementation

The current OpenClaw plugin `marinator_delegate`:

- captures `toolContext.sessionKey` as `orchestrator_session_key`;
- requires the current delivery context (`channel`, `to`, optional thread/account);
- writes a resolved `spec.json` under `.openclaw/state/marinator/runs/<job_id>/`;
- starts `delegate-coding-task.sh` detached;
- returns immediately with `job_id`, `run_dir`, `spec_path`, and runner PID.

The runner:

- starts opencode;
- records logs, `status.json`, `events.jsonl`, `opencode.pid`, `opencode.exit`, and `result.md`;
- detects terminal states such as `completed`, `failed`, `timeout`, `killed`, and `stalled`;
- has guardrails to fail closed if the runner exits unexpectedly;
- currently wakes Junie via:

```bash
openclaw system event --session-key "$orchestrator_session_key" --mode now --text "$text"
```

The runner also still contains temporary debug-only direct Telegram sends. Those violate the desired executor-isolation invariant: workers should talk only to Junie, and Junie should be the only party that messages the user.

## The fundamental async problem

`marinator_delegate` is intentionally asynchronous. Blocking the LLM turn until opencode finishes is a bad default for AI SWE work because:

- implementation can take a long time;
- opencode can stall;
- arbitrary timeouts are crude and will create edge cases;
- holding one LLM turn open does not create a robust durable workflow.

But if `marinator_delegate` is asynchronous, a headless caller like `openclaw agent` exits after the first turn:

```text
openclaw agent turn starts
  → LLM calls marinator_delegate
  → marinator_delegate starts opencode and returns job_id
  → LLM says "started"
  → openclaw agent process exits

opencode is still running
```

So the shell process status means only "one agent turn completed," not "the coding task completed." The real coding workflow status must live somewhere else.

That is acceptable only if there is a reliable way to resume the correct Junie session after the worker reaches a terminal or stalled state. Current Marinator does not have that for arbitrary headless sessions.

## What we tried / verified

### 1. `openclaw system event` wake

Current Marinator uses `openclaw system event --session-key ... --mode now` as the terminal wake mechanism.

We spiked this against a detached/headless session:

- command returned `{ "ok": true }`;
- no new turn was started in the idle detached session;
- the session file did not change;
- the marker file was not written.

Conclusion: `system event` is not a reliable generic continuation mechanism for arbitrary detached/headless sessions. It may be usable as a main-session/heartbeat-class notification, but it cannot be the source of truth for Marinator continuation.

### 2. CLI cron path with `--session-key`

We tried the CLI-shaped cron route:

```bash
openclaw cron add --session-key agent:junie-live:aw-...
```

This was not good enough for persistent headless continuation:

- it created separate cron-run sessions;
- it did not preserve context between turns;
- it behaved more like isolated cron execution with grouping metadata than true named-session re-entry.

Conclusion: do not base Marinator continuation on this CLI path.

### 3. Raw/plugin-style scheduled named-session turn

We tested the lower-level cron job shape:

```json
{
  "sessionTarget": "session:<id>",
  "payload": { "kind": "agentTurn", "message": "..." },
  "delivery": { "mode": "none" }
}
```

This worked in the spike:

- it started a headless agent turn;
- it ran tools;
- it preserved context across a second scheduled turn in the same session;
- it did not send Telegram messages with `delivery.mode: "none"`.

Validated evidence included a first run summary `SPIKE_SESSIONTARGET_KEEP_DONE` and a second run summary `SESSIONTARGET_CONTEXT_YES` against the same session id/key.

Conclusion: named-session scheduled turns are the strongest tested OpenClaw primitive for headless continuation.

### 4. Task ledger metadata caveat

A mini-check showed that execution routing via `sessionTarget:"session:<id>"` worked, but the OpenClaw Task ledger metadata showed the wrong `childSessionKey` in at least one case: Telegram-main instead of the actual headless session. Cron history and the actual session file proved the headless execution was correct.

Conclusion: do not use Task ledger `childSessionKey` as a routing source of truth until this is fixed or fully understood. Use our own explicit `continuationSessionKey`, cron run history, and actual session records.

### 5. GitHub/community research

We searched public web/GitHub for patterns around:

- `scheduleSessionTurn`;
- `api.session.workflow.scheduleSessionTurn`;
- `sessionTarget:"session:"`;
- OpenClaw long-running tasks, background tasks, async completion, and continuation;
- `registerDetachedTaskRuntime`.

Findings:

- Direct community proof for `scheduleSessionTurn` is weak. GitHub code search found mostly OpenClaw source, docs mirrors, forks, and only limited real plugin usage. One real-looking usage was `aksika/abmind`, which schedules a recurring memory-consolidation/dreaming turn. That is evidence of scheduled turns as a plugin mechanism, but not of worker-terminal continuation as an established community pattern.
- Community/GitHub signals are stronger for the broader idea of persistent/named session targets for scheduled work. There are issues/requests around custom session IDs for cron jobs and routing cron work to persistent sessions.
- Community/GitHub signals are also strong that async reporting and long-running task continuation are painful: completion reports can be lost, background tasks can finish without useful relay, agents may stop continuing tasks, and users need to babysit long-running work.
- `registerDetachedTaskRuntime` exists in installed OpenClaw SDK/source, but we found no convincing public/documented/community proof that external plugins should build core product functionality on it. Given OpenClaw's fast-moving codebase, it should be treated as experimental/internal unless proven otherwise.

## Relevant OpenClaw primitives and why they are not sufficient by themselves

### `openclaw system event`

Useful as a notification/wake in some main-session flows. Not reliable enough for arbitrary headless detached-session continuation. We observed it returning success without starting a new turn.

### Cron / scheduled jobs

Cron is the underlying OpenClaw scheduler. Named-session scheduled turns appear to be the most promising tested continuation primitive.

Problems:

- the CLI `--session-key` route was misleading for our needs;
- raw/plugin-style `sessionTarget:"session:<id>"` worked, but the exact plugin convenience API has limited community proof;
- Task ledger metadata may be wrong for child session routing;
- using cron-like scheduling as a continuation substrate still needs a Marinator-owned adapter and regression tests.

### `api.session.workflow.scheduleSessionTurn(...)`

This appears to be the documented plugin convenience API over Cron-backed scheduled session turns. It is likely the right implementation detail for plugin code, but it should not be treated as the stable architectural foundation by name.

Safer product-level framing:

```text
Marinator needs a continuation adapter that schedules a real agent turn in an explicit persistent/named session.
```

Possible adapter strategies:

1. preferred: `api.session.workflow.scheduleSessionTurn(...)`;
2. fallback: raw cron job creation with `sessionTarget:"session:<continuationSessionKey>"`;
3. legacy/emergency only: `system event` for Telegram/main-session notification.

### Background Tasks

OpenClaw Background Tasks are useful as a ledger/status surface for detached work. They are not a scheduler and do not replace session continuation, heartbeats, cron, or our opencode-specific supervision.

They might help with:

- `openclaw tasks list/show` visibility;
- audit;
- cancel surfaces;
- stale/lost detection;
- linking child work to TaskFlow.

But they do not by themselves answer our core questions:

- Has opencode made meaningful progress?
- Is opencode semantically stuck?
- What logs/result should Junie review?
- Which session should be resumed to perform review/fix/report?

If integrated, Background Tasks should be a visibility/control layer, not a parallel second supervisor. Undocumented `registerDetachedTaskRuntime` might make this cleaner, but we should not depend on it without a dedicated spike and stronger proof.

### TaskFlow

TaskFlow is relevant for multi-step workflow state: AW window lifecycle, selected item, waits, cancellation, child tasks, and final status.

It does not replace Marinator supervision and it is not a scheduler. It needs scheduled turns or some other wake mechanism to advance future work.

TaskFlow seems most appropriate for Autonomous Work, where the state is larger than one opencode run:

```text
planning → executing_task → waiting_for_marinator → reviewing → fixing/accepting → planning/finalizing
```

For standalone Marinator hardening, TaskFlow may be useful but should not be forced into the minimal continuation fix until we decide the workflow boundary.

### `openclaw agent`

`openclaw agent` is a one-turn RPC/CLI surface. It should not be treated as the lifecycle of a long-running coding workflow.

If a headless agent turn starts Marinator asynchronously, the CLI process can exit successfully while the coding workflow is still running. External callers need a separate durable status surface (`job_id`, `flow_id`, `show`, `wait`, etc.) if they want final coding outcome from shell.

### Browser/Discord/community research

Browser automation is now enabled locally through the bundled `@openclaw/browser-plugin` after setting browser config to headless/no-sandbox and increasing launch/CDP timeouts. This can be used to inspect Discord manually/through the UI if Danila logs in and handles any 2FA/captcha. It is not yet a replacement for a Discord API/bot integration.

## Why current OpenClaw feels painful for this use case

The hard part is not starting detached work. The hard part is making long-running AI SWE work feel like one durable product-owned workflow across:

- the original Telegram session;
- headless `openclaw agent` sessions;
- detached opencode workers;
- future scheduled continuation turns;
- review/fix/acceptance loops;
- final user reporting;
- cancellation/recovery/restart scenarios.

OpenClaw has pieces that are relevant, but the boundaries are awkward:

- `system event` looks like a wake primitive but is not reliable for headless continuation;
- `openclaw agent` looks like a task runner but is only one turn;
- Background Tasks look like async task infrastructure but are primarily a ledger/status surface;
- TaskFlow is promising for lifecycle state but does not schedule or supervise by itself;
- Cron/scheduled named sessions work in our spike, but the community proof is thin and some metadata is unreliable;
- some powerful-looking SDK seams are undocumented and risky to depend on.

This means a robust Marinator on OpenClaw probably needs its own thin reliability layer rather than relying on one blessed platform primitive.

## Current best OpenClaw-compatible direction

If we continue in OpenClaw, the safest architecture appears to be:

1. Keep Marinator's opencode supervision logic: process management, progress/stall detection, logs, result artifacts, terminal status.
2. Replace terminal `system event` as the authoritative continuation path.
3. Add an explicit `continuationSessionKey` captured from the calling session.
4. Implement a Marinator continuation adapter that schedules a real agent turn into that session.
5. Use named-session scheduled turns as the underlying mechanism, with `scheduleSessionTurn` as preferred implementation and raw cron `sessionTarget:"session:<id>"` as fallback if necessary.
6. Keep `system event` only as legacy/best-effort/debug notification, not correctness.
7. Add regression tests/spikes for:
   - headless session continuation after terminal worker outcome;
   - context preserved across multiple continuation turns;
   - `delivery.mode:"none"` does not send Telegram;
   - terminal `completed/failed/stalled/timeout` each schedules exactly one continuation;
   - Task ledger metadata is not trusted for routing;
   - restart/recovery does not leave Marinator runs silently `running` forever.
8. Treat Background Tasks as optional visibility/control integration until we have a documented/stable way to make Marinator the true runtime owner.
9. Evaluate TaskFlow separately for AW, where multi-step durable lifecycle state is actually needed.

## Open questions before committing harder to OpenClaw

- Is named-session scheduled-turn continuation stable enough across OpenClaw versions, or will it require constant adapter maintenance?
- Can OpenClaw provide a documented/stable plugin API for long-running custom task runtimes, including progress, cancel, recovery, and terminal continuation?
- Should Junie Live invest in building a Marinator reliability layer around OpenClaw primitives, or is Hermes a better substrate for durable long-running AI SWE workflows?
- What external status UX do we want for headless use: `marinator show/wait`, TaskFlow status, OpenClaw tasks, or another surface?
- How much of AW should depend on OpenClaw TaskFlow versus a simpler Junie-owned state machine?

## Interim conclusion

OpenClaw can probably be made to work, but not by simply wiring `marinator_delegate` to one existing primitive. The least risky OpenClaw path is to preserve our Marinator supervisor and hide OpenClaw-specific continuation behind a small adapter using persistent scheduled session turns.

That still leaves real product risk: the pattern is not strongly community-proven, the OpenClaw codebase changes quickly, and long-running async workflow reliability appears to be a known pain area. This is why a Hermes comparison is warranted before investing deeply in OpenClaw-specific hardening.

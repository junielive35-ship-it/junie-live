# Marinator v2 Continuation — CLI-first Plan

Date: 2026-05-31
Status: approved direction, implementation plan
AW M4: paused until this is implemented and verified

## Summary

Marinator must distinguish two separate facts:

```text
1. opencode worker reached terminal state
2. owning OpenClaw agent session actually picked up that result
```

Current flow:

```text
delegate-coding-task.sh finishes opencode
-> writes status/result
-> openclaw system event
-> hope heartbeat/session drains it
```

New flow:

```text
delegate-coding-task.sh finishes opencode
-> writes terminal worker_state
-> sets handoff_state=pending
-> openclaw cron add --session "session:<same-session-key>" --no-deliver
-> if cron is created: handoff_state=scheduled + schedule_job_id
-> Gateway starts hidden agentTurn in the same OpenClaw session
-> before_agent_run records active_run and marks handoff_state=consumed
-> orchestrator reviews result/diff and continues review/fix/acceptance
-> agent_end marks the OpenClaw run ended
```

Use `openclaw cron add` from the bash runner. Do not use TS -> admin RPC for the first implementation.

## Why

The spike proved that a Gateway Cron job with:

```text
sessionTarget: session:<sessionKey>
payload.kind: agentTurn
delivery.mode: none
```

starts a hidden same-session OpenClaw run, does not deliver to Telegram, and fires `before_agent_run` / `agent_end` hooks.

The spike also showed:

- `openclaw system event` is not reliable enough as the correctness-critical continuation path for detached/headless continuation;
- `api.session.workflow.scheduleSessionTurn(...)` from an installed non-bundled plugin returns `handle:null` because the helper is bundled-only;
- `before_agent_finalize` is not reliable on the tested paths and must not be correctness-critical;
- Gateway restart can interrupt a Cron run, so scheduled-but-not-consumed handoffs need reconciliation.

## Concrete runner command

The runner should schedule a one-shot hidden continuation after terminal worker artifacts are written:

```bash
openclaw cron add \
  --name "marinator-continuation-$JOB_ID" \
  --at "$CONTINUATION_AT" \
  --session "session:$ORCHESTRATOR_SESSION_KEY" \
  --message "Marinator job $JOB_ID finished. Read .openclaw/state/marinator/runs/$JOB_ID/status.json and result.md, inspect the repo diff, and continue the review/fix/acceptance loop. Do not report success unless the requested user outcome is verified or explicitly blocked." \
  --no-deliver \
  --delete-after-run \
  --json
```

Before implementation, confirm the exact installed CLI flags with `openclaw cron add --help`.

## Handoff state

Add a small machine-owned handoff section to `runs/<job_id>/status.json`:

```json
{
  "state": "completed",
  "terminal": true,
  "handoff": {
    "state": "scheduled",
    "session_key": "agent:junie-live:...",
    "schedule_job_id": "cron-job-id",
    "scheduled_at": "...",
    "consumed_by_run_id": null,
    "consumed_at": null,
    "last_error": null
  }
}
```

Allowed handoff states:

```text
pending   = terminal worker result exists, continuation not scheduled yet
scheduled = continuation cron job was created
consumed  = matching OpenClaw run started and picked up the handoff
failed    = scheduling/consumption failed; needs reconcile or human-visible anomaly
```

`worker_state=completed|failed|timeout|killed|stalled` is only the worker outcome. It is not proof that the orchestrator reviewed or reported anything.

## Hook behavior

Permanent Marinator hooks:

1. `before_agent_run`
   - record `{sessionKey, runId, state:"active", startedAt}`;
   - find scheduled handoffs whose `session_key` exactly equals `ctx.sessionKey`;
   - mark them `handoff.state="consumed"`, `consumed_by_run_id=ctx.runId`, `consumed_at=...`.
2. `agent_end`
   - mark `{sessionKey, runId, state:"ended", endedAt}`.

`consumed` means “the owning OpenClaw run actually started and picked up the worker result.” It does not mean “workflow done.”

During review/tool activity after consumption, status should show:

```text
handoff_state=consumed
active_run.state=active
```

When the OpenClaw run ends, `agent_end` marks it ended.

## Completion predicate

A Marinator workflow is not complete just because opencode exited.

Completion requires:

```text
no active OpenClaw agent run
AND no non-terminal Marinator worker
AND no pending/scheduled/failed-retryable handoff
AND final workflow outcome is terminal/accepted/blocked/failed/cancelled
```

A terminal worker with `handoff.state != consumed` is still active for workflow accounting.

## Minimal implementation scope

1. In `delegate-coding-task.sh`, after terminal worker state/result are written, set `handoff.state=pending`.
2. Schedule same-session continuation with `openclaw cron add`.
3. On schedule success, store `handoff.state=scheduled`, `schedule_job_id`, `scheduled_at`.
4. On schedule failure, store `handoff.state=failed`, `last_error`, and surface an anomaly; do not silently mark done.
5. Add permanent hook handling for `before_agent_run` and `agent_end`.
6. Add a tiny status/reconcile helper for stale states:
   - `scheduled` too long and not `consumed`;
   - `consumed` with `active` too long;
   - missing/invalid `sessionKey` or `runId` in hook context.
7. Keep `openclaw system event` only as fallback/debug notification, not the correctness-critical path.

## Non-goals

Do not implement in this package:

- TS -> admin RPC continuation path;
- new workflow engine;
- AW M4;
- product-decision supervisor;
- LLM-maintained `review_state`;
- dependency on `before_agent_finalize`;
- broad migrations for old Marinator runs;
- native OpenClaw subagents as implementation workers.

## Acceptance

Done means:

1. A real terminal Marinator worker schedules a one-shot CLI Cron continuation.
2. The continuation runs in the same OpenClaw session.
3. It is hidden from Telegram (`--no-deliver` / delivery mode none).
4. `before_agent_run` marks the matching handoff `consumed` and records active run state.
5. `agent_end` records that the OpenClaw run ended.
6. Scheduled-but-not-consumed handoffs are visible as pending/anomaly, not treated as done.
7. The orchestrator reviews `result.md` and repo diff, then sends a truthful final report.
8. Final state has no active OpenClaw run, no active worker, and no pending/scheduled handoff.

## Deferred fallback options

Only revisit these if CLI continuation proves inadequate:

- TS adapter;
- admin HTTP RPC `cron.add`;
- packaging Marinator as bundled;
- upstream change to allow installed plugins to call `scheduleSessionTurn`.

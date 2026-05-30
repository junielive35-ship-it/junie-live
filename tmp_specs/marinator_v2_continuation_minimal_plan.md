# Marinator v2 Continuation — Minimal CLI-first Plan

Date: 2026-05-31
Status: draft, replaces the over-broad previous plan
AW M4: paused until this is implemented and verified

## What changes

Only the Marinator terminal continuation path changes.

Current path:

```text
delegate-coding-task.sh -> openclaw system event -> hope heartbeat/session drains it
```

New path:

```text
delegate-coding-task.sh -> openclaw cron add one-shot -> Gateway starts agentTurn in same session
```

Use the OpenClaw CLI first. Do not use TS -> admin RPC in the first implementation.

## Why

The spike proved that a raw Gateway Cron job with:

```text
sessionTarget = session:<sessionKey>
payload.kind = agentTurn
delivery.mode = none
```

starts a hidden same-session OpenClaw turn and fires `before_agent_run` / `agent_end` hooks.

The spike did not prove TS/plugin -> admin RPC. So RPC is deferred unless CLI is inadequate.

## Concrete command shape

The runner should create a one-shot hidden continuation roughly like:

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

Before implementation, confirm the exact CLI flags against installed `openclaw cron add --help`.

## Minimal implementation scope

1. In `delegate-coding-task.sh`, after terminal worker state is written, schedule the continuation with `openclaw cron add`.
2. Record the returned cron job id in the Marinator run state.
3. Add a small handoff state to `status.json`:

```json
{
  "handoff": {
    "state": "scheduled",
    "session_key": "...",
    "schedule_job_id": "...",
    "scheduled_at": "..."
  }
}
```

4. Keep `openclaw system event` only as fallback/debug, not correctness path.
5. Add hook handling:
   - `before_agent_run`: if `ctx.sessionKey` matches a scheduled handoff, mark it `consumed`.
   - `agent_end`: record run ended for debugging/status.
6. Add a tiny status/reconcile check for `scheduled` handoffs not yet `consumed` after a timeout.

## Explicit non-goals

Do not implement:

- TS -> admin RPC continuation path;
- new workflow engine;
- AW M4;
- product-decision supervisor;
- review_state maintained by the LLM;
- dependency on `before_agent_finalize`;
- broad migrations for old Marinator runs.

## Acceptance

Done means:

1. A real terminal Marinator worker schedules a one-shot CLI cron continuation.
2. The continuation runs in the same OpenClaw session.
3. It is hidden from Telegram (`--no-deliver`).
4. The matching handoff becomes `consumed` when the continuation run starts.
5. A scheduled-but-not-consumed handoff is visible as pending/anomaly, not silently treated as done.
6. The orchestrator reviews result/diff and sends the final truthful report.

## Deferred

Only if CLI continuation fails or is too brittle, revisit:

- TS adapter;
- admin HTTP RPC `cron.add`;
- packaging Marinator as bundled;
- upstream change to allow installed plugins to call `scheduleSessionTurn`.

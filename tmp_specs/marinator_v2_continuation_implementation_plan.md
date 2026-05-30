# Marinator v2 Continuation Implementation Plan

Date: 2026-05-31
Status: draft plan
Scope: Marinator v2 continuation/runtime reliability
AW M4 status: paused until Marinator v2 continuation is implemented and verified
Inputs:

- `tmp_specs/marinator_aw_runtime_continuation_spike_results.md`
- `tmp_specs/marinator_aw_runtime_continuation_notes.md`
- `implementation-status.md`
- `initialization/docs/delegation-protocol.md`

## 1. Goal

Make Marinator continuation reliable when `marinator_delegate` starts a detached opencode worker and the owning OpenClaw agent run naturally ends before the worker finishes.

The target invariant is:

> A Marinator workflow is not complete merely because the opencode worker exited. It remains active until the worker terminal result has been durably handed off to, and consumed by, the same owning OpenClaw session, and the session reaches an explicit terminal workflow outcome.

This is required before returning to Autonomous Work M4, because AW supervision must not falsely conclude that nothing is active in the gap between worker exit and orchestrator review.

## 2. Non-goals

- Do not implement AW M4 in this work package.
- Do not make `aw_runner` own product decisions, choose fixes, accept work, or edit the repo.
- Do not depend on `openclaw system event` as the correctness-critical continuation path.
- Do not depend on `api.session.workflow.scheduleSessionTurn(...)` from the installed non-bundled plugin while OpenClaw keeps that facade bundled-plugin-only.
- Do not rely on `before_agent_finalize` for correctness-critical workflow state; spike evidence says it is not reliably available on the tested PI/Cron paths.
- Do not introduce native OpenClaw subagents as implementation workers.

## 3. Architecture decisions from the spike

### 3.1 Continuation primitive

Use a Marinator-owned continuation adapter that schedules a persistent/named OpenClaw session turn through raw Gateway/Cron semantics:

```json
{
  "sessionTarget": "session:<sessionKey>",
  "payload": {
    "kind": "agentTurn",
    "message": "<Marinator continuation prompt>"
  },
  "delivery": { "mode": "none" },
  "deleteAfterRun": true
}
```

The adapter should hide the backend behind a small interface so the implementation can later switch to SDK `scheduleSessionTurn` if Marinator becomes bundled or OpenClaw opens that API to installed plugins.

### 3.2 Hook ledger

Use OpenClaw plugin hooks as machine truth for agent-run activity:

- `before_agent_run`: mark `{sessionKey, runId, agentId, state:"active", startedAt}`.
- `agent_end`: mark `{sessionKey, runId, state:"ended", endedAt}`.

Also in `before_agent_run`, consume matching scheduled Marinator handoffs for the exact session key.

Do not use CLI process lifetime as session/workflow truth.

### 3.3 Handoff ledger

Separate worker outcome from continuation handoff state:

```json
{
  "job_id": "...",
  "worker_state": "completed|failed|timeout|killed|stalled",
  "handoff_state": "none|pending|scheduled|consumed|failed",
  "continuation": {
    "session_key": "agent:junie-live:...",
    "backend": "raw-cron",
    "schedule_job_id": "...",
    "schedule_attempts": 1,
    "scheduled_at": "...",
    "consumed_by_run_id": "...",
    "consumed_at": "...",
    "last_error": null
  }
}
```

A Marinator job is active for workflow accounting while:

```text
worker_state is non-terminal
OR worker_state is terminal and handoff_state is pending/scheduled/failed-retryable
```

## 4. State/storage design

Keep state under the existing workspace runtime area:

```text
.openclaw/state/marinator/
  runs/<job_id>/
    spec.json
    status.json
    result.md
    events.jsonl
    ...existing logs...
  ledger/
    active-runs.json
    handoffs.json
    continuation-attempts.jsonl
```

Implementation detail can choose one combined ledger file or per-job files, but the public contract should remain:

- per-run `status.json` is enough to answer worker state and handoff state for that job;
- a plugin-owned ledger is enough to answer active OpenClaw session runs and pending handoffs across jobs;
- writes are atomic enough for crash recovery: write temp file then rename, append events JSONL, avoid partial JSON corruption.

Recommended status schema additions for `runs/<job_id>/status.json`:

```json
{
  "state": "completed",
  "terminal": true,
  "terminal_at": "...",
  "handoff": {
    "state": "scheduled",
    "session_key": "agent:junie-live:...",
    "backend": "raw-cron",
    "schedule_job_id": "...",
    "scheduled_at": "...",
    "attempts": 1,
    "consumed_by_run_id": null,
    "consumed_at": null,
    "last_error": null
  }
}
```

Backward compatibility: old statuses without `handoff` should be treated as `handoff.state="none"` unless the run was created under Marinator v2.

## 5. Implementation phases

### Phase 0 — freeze AW M4 and document the pivot

Deliverables:

1. Mark AW M4 as paused in the temporary AW plan/status surface.
2. Record that Marinator v2 continuation is now the prerequisite.
3. Keep the spike plugin/config cleanup as a separate operational task, not mixed into implementation unless it blocks tests.

Acceptance:

- Docs/status clearly say AW M4 is paused pending Marinator v2 continuation.
- No code behavior changes yet.

### Phase 1 — Marinator continuation/handoff state model

Implement shared state helpers in the Marinator plugin/runtime code:

1. Load/write per-run `status.json` with new `handoff` fields.
2. Append structured events to `events.jsonl` for:
   - `worker_terminal_recorded`
   - `handoff_pending`
   - `continuation_schedule_attempted`
   - `continuation_scheduled`
   - `continuation_schedule_failed`
   - `handoff_consumed`
3. Add idempotent transitions:
   - non-terminal worker -> terminal + `handoff.pending`;
   - `handoff.pending` -> `handoff.scheduled` after schedule success;
   - `handoff.scheduled` -> `handoff.consumed` on exact session-key hook match;
   - repeated terminal handling must not duplicate scheduled continuation turns.

Acceptance:

- Unit tests cover state transition idempotency.
- Old status files without `handoff` still load.
- Corrupt/partial handoff state fails closed and is visible as an anomaly, not silently ignored.

### Phase 2 — raw Cron continuation adapter

Add a Marinator-owned adapter with a narrow interface, for example:

```ts
type ScheduleContinuationInput = {
  jobId: string;
  sessionKey: string;
  message: string;
  idempotencyKey: string;
  delayMs?: number;
};

type ScheduleContinuationResult = {
  backend: "raw-cron" | "sdk-session-turn";
  scheduleJobId: string;
  scheduledAt: string;
};
```

Backend v1: raw Gateway/Cron job with:

- `sessionTarget: "session:<sessionKey>"`
- `payload.kind: "agentTurn"`
- `delivery.mode: "none"`
- one-shot `schedule.kind:"at"` or equivalent immediate/near-immediate schedule
- `deleteAfterRun:true` when supported

Continuation prompt should be explicit and machine-readable enough for the session:

```text
Marinator continuation reminder: opencode worker job <job_id> reached terminal state <state>.
Read .openclaw/state/marinator/runs/<job_id>/status.json and result.md, inspect the repo diff, then continue the delegated review/fix/acceptance loop. Do not report success until the requested user outcome is verified or explicitly blocked.
```

Acceptance:

- Adapter integration test schedules a named-session continuation with `delivery.mode:"none"`.
- Schedule result records durable Cron job id.
- Re-running the schedule path with the same already-scheduled job does not create an avoidable duplicate.
- No Telegram delivery is produced by hidden continuation turns.

### Phase 3 — replace terminal `system event` correctness path

Update `delegate-coding-task.sh` / runner integration so terminal worker handling does this ordering:

1. write terminal worker artifacts (`opencode.exit`, logs, `result.md`, final worker `status.json`);
2. set or update `handoff.state="pending"` with owning `session_key`;
3. call the continuation adapter;
4. on schedule success, record `handoff.state="scheduled"`, `schedule_job_id`, `scheduled_at`;
5. on schedule failure, keep visible failed/retryable state and wake/report anomaly through the best available legacy path.

`openclaw system event` may remain as best-effort legacy/debug notification, but must not be the only path that makes the workflow correct.

Acceptance:

- A terminal worker run creates a scheduled same-session continuation.
- Terminal failure/timeout/killed/stalled outcomes also schedule continuation so the orchestrator can review/report truthfully.
- Runner cannot leave a terminal worker result without either `handoff.scheduled`, retryable `handoff.failed`, or explicit anomaly evidence.

### Phase 4 — hook ledger and consumed acknowledgement

Add permanent Marinator plugin hooks:

1. `before_agent_run`
   - record active run keyed by `{sessionKey, runId}`;
   - find scheduled handoffs whose `continuation.session_key` exactly equals `ctx.sessionKey`;
   - mark them `consumed` with `consumed_by_run_id=ctx.runId`;
   - append per-run and global ledger events.
2. `agent_end`
   - mark the run ended;
   - retain enough history for status/debugging.

The consumed ack should be idempotent:

- if the handoff is already consumed by the same run, no-op;
- if already consumed by a different run, record anomaly and do not rewrite silently;
- unrelated sessions must not consume the handoff.

Acceptance:

- Scheduled continuation run consumes exactly the matching handoff.
- An unrelated named session does not consume it.
- Active-run ledger says active during a run and ended after `agent_end`.
- Tests/spike harness covers exact session-key matching.

### Phase 5 — reconciliation/supervision command or helper

Add a status/reconciliation helper that can be used by AW runner and by humans:

Responsibilities:

1. list Marinator runs with terminal worker state but unconsumed handoff;
2. inspect recorded Cron job id and, when possible, Cron run history;
3. retry scheduling when safe;
4. mark blocked/failed with evidence when retry is unsafe or repeatedly failing;
5. detect gateway-restart interruption cases where Cron says the run was interrupted and handoff never became consumed.

This can start as a script or plugin helper; the key is a stable machine-readable output.

Example output contract:

```json
{
  "active_openclaw_runs": 0,
  "active_marinator_jobs": 1,
  "pending_handoffs": [
    {
      "job_id": "...",
      "handoff_state": "scheduled",
      "schedule_job_id": "...",
      "age_seconds": 420,
      "recommended_action": "inspect_cron_or_retry"
    }
  ],
  "anomalies": []
}
```

Acceptance:

- Helper correctly reports active OpenClaw run state, active Marinator workflow state, pending/scheduled handoffs, and anomalies.
- Gateway restart/interrupted Cron case is represented as retryable or blocked with evidence.
- Output is usable by AW M4 without AW owning product decisions.

### Phase 6 — completion predicate update

Update Marinator/AW workflow completion logic to use:

```text
no active OpenClaw agent run
AND no active/unconsumed Marinator jobs for workflow accounting
AND no pending/scheduled continuation handoffs
AND final workflow outcome is terminal/accepted/blocked/failed/cancelled
```

For Telegram-bound normal delegation, the final user-visible assistant report remains the outcome, but machine state must still prevent false completion between worker terminal and continuation consumption.

For AW, the AW state should record only operational lifecycle and final terminal outcome; it must not replace orchestrator review/acceptance.

Acceptance:

- AW/status checks cannot report done while a terminal worker result is still unconsumed.
- Normal Marinator flow still reaches a final user report after orchestrator review.
- False-complete gap from the original design is closed.

### Phase 7 — docs, status, and cleanup

Update docs after implementation:

- `implementation-status.md`: Marinator/delegated flow status and evidence.
- `initialization/docs/delegation-protocol.md`: replace correctness-critical `system event` text with Marinator v2 continuation semantics.
- `tmp_specs/autonomous.md` or relevant AW planning doc: AW M4 can resume only after Marinator v2 acceptance evidence exists.
- Clean temporary spike plugin/config if no longer needed.

Acceptance:

- Docs distinguish implemented behavior from contract-only behavior.
- No stale claim remains that heartbeat/system-event wake is the correctness-critical path.
- Spike-only artifacts/config are removed or explicitly recorded as intentionally retained.

## 6. Verification plan

Minimum verification before calling Marinator v2 continuation done:

1. Unit tests
   - handoff state transitions;
   - idempotent schedule handling;
   - exact session-key consumed ack;
   - old status compatibility.
2. Integration/smoke test
   - create a Marinator-like worker terminal result;
   - schedule raw Cron same-session continuation;
   - verify hidden continuation starts in the same session;
   - verify hook consumes the handoff;
   - verify `agent_end` marks run ended;
   - verify no Telegram delivery for hidden continuation.
3. End-to-end Marinator test
   - run a tiny real delegated task through `marinator_delegate`;
   - allow the original OpenClaw activation to end;
   - worker terminal schedules continuation;
   - same session reviews `result.md`/diff and reports truthful outcome;
   - final state has no active run, no active Marinator job, no pending handoff.
4. Failure-path tests
   - schedule failure leaves visible retryable handoff anomaly;
   - duplicate terminal handler invocation does not create duplicate review turns;
   - simulated gateway restart/interrupted Cron is reconciled or clearly blocked.
5. Repository checks
   - `scripts/verify.sh`;
   - `scripts/check-repo-hygiene.sh`;
   - package tests/build for `initialization/marinator-delegation`.

## 7. Suggested delegation breakdown

Because this repo requires code/script/config/test changes to go through opencode/Marinator workers under the mutex, implement as sequential delegated tasks:

### Task A — state model + tests

Files likely involved:

- `initialization/marinator-delegation/src/index.ts`
- `initialization/marinator-delegation/src/index.test.ts`
- generated `dist/` outputs if this package tracks them

Outcome:

- schema helpers and idempotent handoff transitions with tests.

### Task B — continuation adapter

Outcome:

- raw Cron/Gateway scheduling backend behind adapter;
- no dependency on non-bundled `scheduleSessionTurn`;
- adapter tests with mocked Gateway/Cron API where possible.

### Task C — runner terminal integration

Files likely involved:

- `initialization/marinator-delegation/scripts/delegate-coding-task.sh`
- plugin code/config used by the runner

Outcome:

- terminal worker handling writes handoff state and schedules continuation;
- legacy `system event` downgraded to best-effort/debug.

### Task D — hook ledger / consumed ack

Outcome:

- plugin hooks maintain active-run ledger and consume exact matching handoffs;
- tests/spike harness proves scheduled continuation consumption.

### Task E — reconciliation/status helper

Outcome:

- machine-readable status/reconcile helper for AW and manual debugging;
- retry/block behavior defined for scheduled-but-unconsumed handoffs.

### Task F — e2e verification + docs/status

Outcome:

- one small real Marinator run proves continuation;
- docs/status updated;
- AW M4 remains paused or is explicitly unpaused only after evidence is recorded.

## 8. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Raw Cron API shape changes | Keep adapter narrow; record backend/version; fail visibly with retryable handoff anomaly. |
| Duplicate continuation turns | Use idempotency key based on `job_id` + terminal generation; check existing `schedule_job_id` before scheduling; consumed ack is idempotent. |
| Schedule succeeds but state write crashes | Reconciliation inspects Cron job/run history and handoff age; retry only when safe; record anomalies. |
| Gateway restart interrupts continuation run | Detect Cron interrupted run; leave handoff unconsumed; retry schedule or block with evidence. |
| Hidden continuation leaks to Telegram | Always set `delivery.mode:"none"`; include explicit no-leak integration check. |
| Hook data missing session key/run id | Fail closed: do not consume handoff; report anomaly; do not mark workflow complete. |
| `before_agent_finalize` unavailable | Do not make it critical; use prompt contract + ledgers + reconciliation. |
| AW runner oversteps product ownership | AW reads machine state and reports anomalies only; OpenClaw session owns review/fix/acceptance. |

## 9. Resume condition for AW M4

AW M4 may resume only after all are true:

1. Marinator terminal worker results schedule same-session continuation through the v2 adapter.
2. Hook ledger consumes matching handoffs and records active/ended OpenClaw runs.
3. Reconciliation can detect and handle scheduled-but-unconsumed handoffs.
4. Completion predicate includes unconsumed handoffs and active Marinator workflow state.
5. A real e2e Marinator run demonstrates: worker completes -> same-session hidden continuation runs -> orchestrator reviews -> final truthful report -> no active/pending machine state remains.

Until then, AW M4 should stay paused.

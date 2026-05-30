# Marinator / Autonomous Work Runtime Continuation Notes

Temporary design notes from the 2026-05-30 discussion. This is not an approved implementation plan yet. It captures the current shared understanding and the spike pack to run before committing to a plan.

## Why this exists

Junie Live's delegation protocol is one OpenClaw orchestrator session owning the full worker/delegation/review/fix/acceptance loop. Code work is delegated to opencode through Marinator, but the orchestrator remains responsible for reviewing results, requesting fixes, accepting, blocking, and reporting.

The hard runtime problem is that `marinator_delegate` is asynchronous:

1. OpenClaw session calls `marinator_delegate`.
2. `marinator_delegate` starts a detached opencode runner and quickly returns `job_id`.
3. The LLM may produce ordinary assistant text with no tool calls.
4. OpenClaw treats that as a natural final answer for the current agent run.
5. The OpenClaw session becomes inactive while opencode is still running.

That is acceptable only if opencode terminal outcome reliably reactivates the same OpenClaw session so the orchestrator can continue the same delegation protocol loop.

## Terminology used here

- **OpenClaw session**: the durable conversation/session key and transcript. The delegation protocol lives at this level.
- **OpenClaw agent run / activation**: one execution of the session in response to an input/event/scheduled turn. It may include multiple model calls and tool calls. It ends when the model returns natural text with no tool calls, or on timeout/error/abort.
- **Tool call**: one model-requested tool invocation inside an agent run.
- **Marinator run**: one opencode worker run started by `marinator_delegate`, represented by `.openclaw/state/marinator/runs/<job_id>/`.
- **opencode worker active**: the actual opencode process/runner is still executing.
- **Marinator job active for workflow accounting**: broader than process active. A job is active until its terminal result has been handed off to, and consumed by, the owning OpenClaw session.

## Evidence and findings so far

### OpenClaw agent termination

Local docs/source and internet/GitHub evidence agree on the basic loop:

```text
LLM response with tool_calls/tool_use -> OpenClaw executes tools and continues loop
LLM natural text with no tool calls -> OpenClaw accepts final answer and ends run
```

OpenClaw docs describe `before_agent_finalize` as running when a harness is about to accept a natural final assistant answer. It can request `action:"revise"` for one more model pass, with bounded retry metadata.

Community/GitHub evidence found issues where users complain that OpenClaw accepts plain text that simulates tool calls instead of enforcing real tool invocation. This supports the conclusion that plain text without tool calls is the final/escape path unless a hook or external runner catches it.

No config flag was found for “require a final tool before the run may end.” The realistic control points are:

- prompt instructions;
- `before_agent_finalize` hook to force a bounded revise before accepting final text;
- machine-owned state/ledger checked by runner/plugin after the run.

### Current Marinator artifacts

Each run has:

```text
~/.openclaw/workspace-junie-live/.openclaw/state/marinator/runs/<job_id>/
```

Important files include:

- `status.json` — current source of truth for worker outcome;
- `events.jsonl`;
- `result.md`;
- `runner.log`;
- `opencode.stdout.log`;
- `opencode.stderr.log`;
- `opencode.pid` / `opencode.pgid`;
- `opencode.exit`;
- `spec.json`.

Known terminal worker states:

```text
completed | failed | timeout | killed | stalled
```

This status is currently worker outcome only. It is not proof that Junie reviewed, accepted, requested fixes, blocked, or reported.

### `system event` is not sufficient

Current runner wakes via:

```bash
openclaw system event --session-key "$orchestrator_session_key" --mode now --text "$text"
```

A spike against a detached/headless session returned `{ "ok": true }` but did not start a new turn. Therefore `system event` cannot be the correctness-critical continuation mechanism for arbitrary headless sessions or AW.

### Scheduled named-session turns are the strongest tested continuation primitive

Raw/plugin-style cron job shape with:

```json
{
  "sessionTarget": "session:<id>",
  "payload": { "kind": "agentTurn", "message": "..." },
  "delivery": { "mode": "none" }
}
```

was spiked and worked:

- started a headless session turn;
- ran tools;
- preserved context across multiple scheduled turns in the same session;
- did not deliver Telegram messages when `delivery.mode:"none"`.

However, community proof for `scheduleSessionTurn` is weak, and OpenClaw Task ledger metadata showed at least one wrong `childSessionKey`. So the architecture should depend on “persistent/named scheduled session turn” behind a Marinator adapter, not on trusting a single metadata field or an undocumented internal runtime.

## Corrected architecture direction

### Keep the delegation protocol as one session-level loop

Do not split the delegation protocol into a separate explicit “review step” controlled by an external supervisor. The OpenClaw session owns the review/fix/acceptance loop.

The intended sequence is:

```text
OpenClaw session active
  -> calls marinator_delegate job A
  -> natural final text may end this activation
  -> session inactive while opencode A runs

opencode A terminal
  -> Marinator schedules same-session OpenClaw continuation
  -> same session becomes active again
  -> orchestrator reviews result.md + diff
  -> maybe calls marinator_delegate job B
  -> session may become inactive again

opencode B terminal
  -> Marinator schedules same-session continuation
  -> same session reviews/fixes/accepts
  -> eventually final answer / blocked / accepted outcome
```

Multiple `marinator_delegate` calls are therefore supported by repeated reactivations of the same OpenClaw session.

### `aw_runner` can supervise, but not own product decisions

For Autonomous Work, `aw_runner.sh` may supervise the lifecycle, logs, time budget, and anomalies. It must not choose backlog items, decide fixes/acceptance, edit the repo, or act as product owner.

Allowed `aw_runner` responsibilities:

- start an OpenClaw AW session/activation;
- observe OpenClaw run logs/status;
- observe Marinator `status.json` / machine ledger;
- detect stale/hung/corrupt state;
- report operational anomalies to the main orchestrator;
- enforce time budget/cancel boundary;
- avoid silent abandonment.

But the core review/fix/acceptance loop remains in the OpenClaw session.

### Machine-owned handoff ledger, not LLM-owned review state

Do not ask the LLM to maintain `review_state` or similar correctness-critical state. That is too fragile.

Instead, Marinator needs machine-owned handoff state.

Worker outcome and handoff should be separated:

```json
{
  "job_id": "...",
  "worker_state": "completed",
  "handoff_state": "pending|scheduled|consumed",
  "continuation": {
    "session_key": "...",
    "schedule_job_id": "...",
    "scheduled_at": "...",
    "consumed_by_run_id": "...",
    "consumed_at": "..."
  }
}
```

A job is counted as “active” for workflow completion until:

```text
worker_state is terminal
AND handoff_state is consumed by the owning OpenClaw session
```

This avoids the dangerous gap where opencode has exited, no process is active, and the same-session continuation has not actually started yet.

### Active OpenClaw agent run should be tracked by plugin hooks

Do not use the lifetime of the `openclaw agent` CLI process as source of truth after it exits.

The reliable approach is a plugin-owned active-run ledger:

- `before_agent_run` (or another appropriate early agent hook) marks `{ sessionKey, runId, state:"active", startedAt }`;
- `agent_end` marks `{ sessionKey, runId, state:"ended", endedAt }`;
- continuation consumption is marked when a run starts in the expected session and consumes a pending handoff.

The runner/supervisor reads this machine ledger instead of guessing from process state.

### `before_agent_finalize` role

`before_agent_finalize` is not the workflow-completion mechanism. It is a guard before accepting natural final text for the current activation.

Use it to prevent an unsafe handoff, e.g.:

- if this activation called `marinator_delegate`, ensure every returned `job_id` is registered in the machine ledger;
- ensure the session is allowed to become inactive only when outstanding Marinator work is represented by handoff/continuation state;
- optionally force a bounded revise if the agent is about to finalize without recording required state/tool results.

Do not use it to ask the LLM to maintain correctness-critical review states.

### Completion criteria

For a session-level workflow, “finished” must not mean simply:

```text
no active OpenClaw agent run
AND no active opencode process
```

Better criterion:

```text
no active OpenClaw agent run
AND no active Marinator jobs for workflow accounting
AND no pending/ scheduled/unconsumed continuations
AND final session outcome is terminal/accepted/blocked/failed/cancelled
```

For AW, the final outcome may additionally be represented in AW state. For normal Telegram-bound delegation, the final assistant response in the owning session is the user-visible outcome, but machine ledger still guards Marinator handoff.

## Open questions / risks

1. Do OpenClaw plugin hooks (`before_agent_run`, `agent_end`, `before_agent_finalize`) fire for scheduled same-session turns with `sessionTarget:"session:<id>"` and `delivery.mode:"none"`?
2. Do those hooks receive reliable `ctx.sessionKey` and `ctx.runId`?
3. Can a Marinator runner or plugin code schedule the same-session turn reliably from the detached runner context?
4. Can scheduled continuation start be correlated with the pending Marinator handoff without trusting broken Task ledger `childSessionKey` metadata?
5. Can handoff scheduling be made idempotent across crashes/retries?
6. Can we verify no Telegram delivery leaks from hidden/scheduled continuation turns?
7. Can `before_agent_finalize` robustly detect the relevant Marinator tool results / registered job ids for the current activation?
8. How should ordinary non-AW Telegram final acceptance be represented for machine checking, if at all?

## Spike pack before implementation plan

Do these before writing an implementation plan. If any of the first four fail, the architecture must be revised.

### Spike 1 — Hook coverage for scheduled named-session turns

Goal: prove hooks fire for scheduled same-session turns.

Setup:

- create a tiny temporary OpenClaw plugin or local plugin patch that writes hook events to a file;
- schedule a raw cron job with `sessionTarget:"session:<test-key>"`, `payload.kind:"agentTurn"`, `delivery.mode:"none"`;
- prompt should do something simple and produce a final answer.

Verify:

- `before_agent_run` fired;
- `agent_end` fired;
- `before_agent_finalize` fired for natural final answer;
- events contain `sessionKey`, `runId`, and enough data to correlate to the test session.

### Spike 2 — Active-run ledger

Goal: prove we can maintain machine truth for session active/inactive independent of CLI process lifetime.

Implementation:

- hook writes `{sessionKey, runId, state:"active", startedAt}` on start;
- hook writes `{sessionKey, runId, state:"ended", endedAt}` on end.

Verify:

- during a running scheduled turn, ledger says active;
- after completion, ledger says ended;
- after CLI process is gone, ledger still answers active/inactive.

### Spike 3 — Continuation consumed ack

Goal: prove pending Marinator handoff can be marked consumed by same-session activation.

Setup:

- manually create fake Marinator handoff record `{handoff_state:"scheduled", session_key:<test-key>}`;
- schedule same-session turn;
- hook detects pending handoff for that session and marks `{handoff_state:"consumed", consumed_by_run_id:<runId>}`.

Verify:

- consumed only when same-session run starts;
- unrelated sessions do not consume it;
- repeated hook calls are idempotent.

### Spike 4 — Schedule from runner/plugin context

Goal: prove detached Marinator runner can schedule a same-session continuation using a stable mechanism.

Options to compare:

1. preferred plugin API helper if accessible from plugin-owned code;
2. raw cron job creation with `sessionTarget:"session:<session-key>"`;
3. CLI route only if it can be made equivalent to raw cron shape.

Verify:

- continuation runs in same session;
- context is preserved;
- delivery is none;
- schedule result contains durable id or we can record our own idempotency key.

### Spike 5 — Fake Marinator chain

Goal: prove multiple Marinator jobs can chain through same-session continuation.

Flow:

1. scheduled/session run observes fake job A complete;
2. it “reviews” fake result;
3. it starts/registers fake job B or real noop Marinator-like job;
4. fake job B completes;
5. same-session continuation runs again;
6. final answer occurs.

Verify:

- both continuations are in same session;
- no external supervisor made product decisions;
- handoff ledger prevents “nothing active” false completion between jobs.

### Spike 6 — `before_agent_finalize` enforcement

Goal: prove final-answer guard can force a bounded revise.

Flow:

- create a tool or fake Marinator result that returns a `job_id`;
- prompt/model attempts to finish without registering required handoff state;
- `before_agent_finalize` returns `action:"revise"` with retry instruction;
- model gets another pass and fixes state, or maxAttempts is reached and runner/plugin records anomaly.

Verify:

- hook can inspect enough context to know the job id/tool result;
- revise actually triggers another model pass;
- maxAttempts prevents infinite loop.

### Spike 7 — Idempotency / crash boundary

Goal: identify safe ordering and idempotency keys around:

```text
result written -> schedule requested -> handoff_state updated
```

Test duplicate terminal handling:

- repeated terminal handler invocation for same job must not create duplicate continuation turns;
- if schedule succeeds but status update crashes, retry should detect/recover without duplicate or lost continuation;
- if schedule fails, handoff remains retryable and visible as anomaly.

### Spike 8 — No Telegram leakage

Goal: ensure hidden continuations stay hidden.

Verify scheduled same-session turns with `delivery.mode:"none"` do not DM Telegram. Final user reports must only be sent by the owning orchestrator when it intentionally replies.

## Tentative design if spikes pass

1. Extend Marinator run state with machine-owned handoff fields.
2. Add a Marinator/OpenClaw plugin ledger for active session runs and pending/consumed handoffs.
3. Replace correctness-critical terminal `system event` wake with scheduled named-session continuation.
4. Keep `system event` only as legacy/best-effort/debug notification where appropriate.
5. Add `before_agent_finalize` guard for unsafe finalization after Marinator delegation.
6. Teach AW runner to read machine ledger and Marinator state, supervise anomalies, and enforce time budget without making product decisions.
7. Only after that, update `autonomous.md` / AW implementation plan.

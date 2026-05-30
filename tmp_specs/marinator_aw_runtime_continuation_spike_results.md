# Marinator / AW Runtime Continuation Spike Results

Date: 2026-05-31
Workspace: `~/.openclaw/workspace-junie-live`
Spike dir: `~/.openclaw/workspace-junie-live/.tmp/openclaw-spikes/marinator-continuation-20260530`

## Verdict

The corrected Marinator continuation architecture is feasible, but with two important constraints:

1. Use a Marinator-owned continuation adapter that schedules a persistent/named session turn via Cron/raw Gateway semantics (`sessionTarget: "session:<sessionKey>"`), not `openclaw system event`.
2. Do not rely on `api.session.workflow.scheduleSessionTurn(...)` from the installed non-bundled Marinator plugin in the current OpenClaw version: the SDK facade returned `undefined` and source shows it is guarded to bundled plugins only.

`before_agent_run` + `agent_end` hooks are sufficient to maintain a plugin-owned active-run ledger and to mark machine-owned Marinator handoffs as consumed. `before_agent_finalize` is not reliable on the tested PI/Cron paths and must not be a correctness-critical guard.

## Validated

### Gateway/plugin recovery

- Gateway recovered after restart and was active.
- Temporary plugin `marinator-continuation-spike-hooks` loaded with:
  - `hookCount=3`
  - hooks: `before_agent_run`, `agent_end`, `before_agent_finalize`
  - `allowConversationAccess=true`
- Non-bundled conversation hooks required config:

```json
{
  "plugins": {
    "entries": {
      "marinator-continuation-spike-hooks": {
        "hooks": {
          "allowConversationAccess": true,
          "timeoutMs": 5000
        }
      }
    }
  }
}
```

### Scheduled same-session turn via raw Cron/sessionTarget

Raw Cron job shape works:

```json
{
  "sessionTarget": "session:agent:junie-live:spike-raw-cron-target-20260531b",
  "payload": {
    "kind": "agentTurn",
    "message": "Reply exactly SPIKE_RAW_CRON_FINAL_B"
  },
  "delivery": { "mode": "none" }
}
```

Evidence:

- Cron job id: `08cd91a6-bda3-4a92-b844-51c3c9816c5c`
- Run status: `ok`
- Summary: `SPIKE_RAW_CRON_FINAL_B`
- Run session key: `agent:junie-live:spike-raw-cron-target-20260531b`
- Delivery: `deliveryStatus=not-requested`, `delivered=false`

### Hook coverage for scheduled turns

For scheduled named-session turns, hooks fired:

- `before_agent_run`
- `agent_end`

They carried useful context:

- `ctx.sessionKey`
- `ctx.sessionId`
- `ctx.runId`
- `ctx.agentId`

Example from raw Cron spike:

```json
{
  "hook": "before_agent_run",
  "ctx": {
    "runId": "dbe60708-41de-45ab-9fbd-2badeadcf54c",
    "sessionId": "dbe60708-41de-45ab-9fbd-2badeadcf54c",
    "sessionKey": "agent:junie-live:spike-raw-cron-target-20260531b",
    "agentId": "junie-live"
  }
}
```

### Active-run ledger

Temporary hook ledger wrote active state:

- `before_agent_run` -> `state=active`
- `agent_end` -> `state=ended`

This validates that active OpenClaw agent run state can be tracked after the original CLI process is long gone. Do not use CLI process lifetime as workflow truth.

### Machine-owned handoff consumed ack

Temporary `handoffs.json` spike:

- matching handoff:
  - `sessionKey=agent:junie-live:spike-handoff-target-20260531b`
  - `handoff_state=scheduled`
- unrelated handoff:
  - `sessionKey=agent:junie-live:spike-handoff-other-20260531b`
  - `handoff_state=scheduled`

Raw Cron continuation:

- Cron job id: `dfcc5c41-d4cc-4901-99c5-e2b0ebf238ad`
- Run status: `ok`
- Summary: `SPIKE_HANDOFF_CONSUME_FINAL_B`
- Run session key: `agent:junie-live:spike-handoff-target-20260531b`

Result:

```json
{
  "jobId": "spike-handoff-good-20260531b",
  "sessionKey": "agent:junie-live:spike-handoff-target-20260531b",
  "worker_state": "completed",
  "handoff_state": "consumed",
  "consumedRunId": "d52b021d-0342-4180-96bb-2379c95afd9c"
}
```

The unrelated handoff remained `scheduled`. This validates exact session-key matching for consumed ack.

## Failed / blocked assumptions

### `api.session.workflow.scheduleSessionTurn(...)` from installed plugin

The temporary plugin registered a tool that called:

```js
api.session.workflow.scheduleSessionTurn({
  sessionKey,
  message,
  delayMs,
  deliveryMode: "none",
  deleteAfterRun: true,
  tag
})
```

The agent successfully called the tool, but the result was:

```json
{"handle": null}
```

No target session was created and no Cron run happened.

Source inspection found the reason in OpenClaw dist:

```js
async function schedulePluginSessionTurn(params) {
  if (params.origin !== "bundled") return;
  ...
}
```

So the SDK facade is currently bundled-plugin-only and is not usable by the installed Marinator plugin unless Marinator becomes bundled or OpenClaw changes this restriction.

### `before_agent_finalize`

`before_agent_finalize` did not fire for:

- scheduled same-session gpt-5.5/Codex-style run;
- scheduled same-session Claude Opus run;
- direct `openclaw agent` Claude/Pi run.

Source search suggests it is tied to native hook relay / harness paths, not the tested embedded PI paths. Treat it as unavailable for correctness-critical Marinator/AW guard logic.

### Cron run interruption on gateway restart

One handoff spike job failed because gateway restarted while the Cron run was in progress:

```text
cron: job interrupted by gateway restart
```

This is not a routing failure, but production design must include reconciliation for `scheduled` handoffs that never become `consumed`.

## Architecture implications

### Keep

- One durable OpenClaw session owns the Marinator delegation/review/fix/acceptance loop.
- `marinator_delegate` remains asynchronous.
- Worker terminal result schedules same-session continuation.
- Machine-owned handoff ledger separates:
  - `worker_state`
  - `handoff_state`
- A Marinator job remains active for workflow accounting while:
  - opencode worker is running, OR
  - terminal worker result has not been consumed by the owning OpenClaw session.
- Active OpenClaw run state is tracked by hooks, not by CLI process lifetime.

### Change from earlier plan

- Do not depend directly on `api.session.workflow.scheduleSessionTurn(...)` from the installed plugin.
- Implement a Marinator continuation adapter with at least two possible backends:
  1. raw Cron/Gateway `sessionTarget: "session:<sessionKey>"` backend (validated now);
  2. SDK `scheduleSessionTurn` backend only if/when Marinator is bundled or OpenClaw opens the API to non-bundled plugins.
- Do not use `before_agent_finalize` as the final guard. Use prompt contract + machine ledgers + reconciliation/supervision instead.

## Recommended next implementation plan

1. Pause AW M4 on current Marinator semantics.
2. Build Marinator v2 continuation adapter:
   - records `continuation.sessionKey`;
   - writes terminal worker artifacts;
   - creates/updates handoff record atomically enough for recovery;
   - schedules raw Cron same-session agent turn with `delivery.mode="none"`;
   - records Cron job id / schedule attempt.
3. Add hook/plugin ledger:
   - `before_agent_run`: mark active run and consume matching scheduled handoff for that session/job;
   - `agent_end`: mark run ended;
   - expose/read ledger for Marinator/AW status checks.
4. Add reconciliation:
   - find terminal worker results with `handoff_state=scheduled` but no consumed ack after timeout;
   - inspect Cron run status;
   - retry schedule or mark blocked/failed with evidence;
   - handle gateway restart interruption.
5. Update completion predicate:
   - no active OpenClaw agent run;
   - no active/unconsumed Marinator jobs for workflow;
   - no pending/scheduled continuation handoffs;
   - final workflow outcome terminal.
6. Only after this, return to `autonomous.md` / AW M4 implementation.

## Cleanup notes

Temporary config/plugin used during spike:

- Plugin: `marinator-continuation-spike-hooks`
- Install path: `~/.openclaw/extensions/marinator-continuation-spike-hooks`
- Tool allowlist temporarily included: `marinator-continuation-spike-hooks`
- Hook config temporarily allowed conversation access for this plugin.

Clean up after no more spike inspection is needed.

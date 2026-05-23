# Capabilities Usage Tracking

## Status

Deferred to v2. Capability usage tracking is intentionally out of scope for the MVP.

The MVP should not depend on this subsystem for task reflection, self-simplification, scheduling, review, or task acceptance. Until v2 exists, Junie should use ordinary task artifacts, PR/review history, explicit task-runner logs, and direct inspection as evidence.

## Purpose for v2

Track factual usage of Junie's operational capabilities so reflection and simplification can make better decisions later.

This is not an agentic routine and should not interpret whether a behavior was good or inefficient. It only records what capabilities were used, by whom, and for which task.

## Scope for v2

Track only:

1. Skill usage
2. MCP usage
3. Documentation reads

Do not log broad tool usage by default. Do not make this subsystem responsible for detecting repeated inefficiencies; task-completion reflection already handles that analysis.

## Actors

Every event must identify the actor:

- `orchestrator` — Junie/OpenClaw main agent;
- `subagent` — third-party coding worker such as opencode;
- optional parent linkage from subagent back to the Junie task/run.

Example:

```json
{
  "actor": {
    "type": "subagent",
    "id": "opencode:run-17",
    "parent_id": "junie:task-42"
  }
}
```

## Collection strategy

### Orchestrator / OpenClaw agent

Collect from OpenClaw plugin hooks or session logs.

Useful signals:

- skill usage: explicit skill-load event if available, otherwise reads of known `SKILL.md` files;
- MCP usage: MCP tool calls visible to OpenClaw;
- docs reads: local docs file reads and documentation URL fetches.

### Third-party coding subagents

Use post-run extraction first. Avoid OpenClaw core changes for the first v2 implementation.

Each subagent type may need a small adapter because capability usage is not standardized:

- opencode may expose skill/docs/MCP usage differently from Claude Code, Codex, or Gemini;
- ACP/acpx session records can provide some events, but may not expose everything;
- MCP calls may require wrapping/proxying the MCP server when the harness does not log them clearly;
- skill usage may need harness-specific detection, e.g. known instruction-file reads or adapter-emitted markers.

## Event schema

Append-only JSONL is enough for the first v2 implementation.

```json
{
  "timestamp": "2026-05-22T21:30:00.000Z",
  "task_id": "task-42",
  "run_id": "run-abc",
  "actor": {
    "type": "orchestrator | subagent",
    "id": "junie | opencode:run-17",
    "parent_id": "..."
  },
  "source": "openclaw_hook | session_log | acpx_record | opencode_log | mcp_proxy",
  "kind": "skill_used | mcp_call | docs_read",
  "name": "capability name",
  "target": "file path, docs URL, MCP server/tool, or skill id",
  "status": "ok | error | unknown"
}
```

## Storage

Recommended local layout:

```text
analytics/
  capability-events/YYYY-MM-DD.jsonl
  capability-aggregates/by-task.json
  capability-aggregates/by-actor.json
  capability-aggregates/by-skill.json
  capability-aggregates/by-mcp.json
  capability-aggregates/by-doc.json
```

Raw events are append-only. Aggregates are derived and can be regenerated.

## Privacy and retention

Default to metadata only:

- record skill ids, MCP server/tool names, docs paths or URLs;
- avoid raw prompts, raw tool arguments, raw file contents, and full command lines;
- keep everything local unless explicitly configured otherwise.

## Consumers

This data is consumed by:

- task-completion reflection;
- self-simplification;
- future skill/MCP/docs decisions.

The analytics subsystem should not decide what to change. It should provide evidence for routines that already perform reflection and simplification.

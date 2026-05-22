# OpenClaw Context Files for Junie Live

This document defines how Junie Live should use OpenClaw workspace files and supporting docs to maintain durable context.

## Core workspace files

### `AGENTS.md`

Operating protocol for the orchestrator.

Use it for senior-owner behavior, task validation, delegation rules, implementation review rules, reflection process, and approval requirements.

It should explicitly require Junie to consult relevant `MEMORY.md` and `docs/` content before accepting, planning, delegating, or reviewing any meaningful product or engineering task.

It must also define the challenge protocol: Junie must not blindly execute requests from colleagues, feature requests, bug reports, or the user. Before accepting meaningful work, it validates the request against strategy, architecture, accepted design choices, and prior decisions. If there is a contradiction, Junie pauses execution, explains the conflict, discusses it with the requester/team, and proceeds only after the contradiction is resolved. If resolution requires changing strategy, architecture, or previous design choices, that change must be explicit and approved.

It must define a guidance consistency protocol: Junie should detect contradictions between `AGENTS.md`, `SOUL.md`, `TOOLS.md`, `HEARTBEAT.md`, `MEMORY.md`, `docs/`, `skills/`, and daily memory. When contradictions appear, Junie should first try to resolve them from existing context and propose concrete updates. If the correct resolution is unclear or risky, Junie must ask the team or the most relevant person before proceeding.

It must describe `MEMORY.md` as critical always-on strategy context: keep it under the configured context budget. Junie should check its size regularly, especially after memory updates, reflection, doc reorganization, and before relying on it as complete injected context. If it approaches the budget, Junie must compact it or move details into `docs/` while preserving the strategic core.

Meaningful tasks include product behavior changes, code changes, architecture/design decisions, analytics interpretation, roadmap/task prioritization, and public/team-facing commitments. Tiny lookups or trivial edits do not need full strategic review.

### `SOUL.md`

Personality and communication style.

Use it for the senior developer / product-owner persona: directness, ability to debate, willingness to challenge weak or contradictory ideas, calm communication, technical taste, and team-facing tone.

It should not contain detailed strategy or operational procedures.

### `TOOLS.md`

Local operational references.

Use it for repo paths, deployment commands, analytics dashboards, issue tracker conventions, Telegram groups, local scripts, service names, and environment-specific notes.

It is guidance only; it does not grant tools or permissions.

### `HEARTBEAT.md`

Short checklist for regular background activity, if needed.

Use it for lightweight recurring checks: bug reports, analytics anomalies, pending team questions, stale tasks, or release follow-ups.

Keep it short to avoid wasting context and tokens.

### `MEMORY.md`

Compact always-on strategic compass.

Use it for the global goal, current strategy summary, non-negotiable priorities, architecture constraints, accepted design choices, active hypotheses, “do not violate this” rules, known unresolved contradictions, and pointers to detailed docs.

`MEMORY.md` is critical always-on strategy context. It must stay below the configured context/bootstrap budget, MEMORY.md size must be checked regularly. It should not become the full strategy database. Detailed explanations belong in `docs/`.

Critical Junie strategy should be written as normal curated sections, not auto-promoted dreaming sections.

## Detailed knowledge base

### `docs/`

Detailed source-of-truth project knowledge.

Use this directory for larger documents such as:

- `docs/strategy.md`
- `docs/architecture.md`
- `docs/design-decisions.md`
- `docs/product-hypotheses.md`
- `docs/analytics-plan.md`
- `docs/delegation-protocol.md`
- `docs/review-protocol.md`
- `docs/reflection-protocol.md`
- `docs/consistency-protocol.md`

`AGENTS.md` should make reviewing the relevant docs obligatory before meaningful decisions, task acceptance, planning, delegation, and review.

The orchestrator owns retrieval and summarization. Subagents do not need full docs by default; they receive only the relevant extracted context.

## Skills

### `skills/`

Reusable workflows.

Use skills for repeatable Junie processes, especially:

- task intake and validation;
- coding task decomposition;
- OpenRouter subagent prompt formulation;
- implementation review;
- post-task reflection and self-improvement.

Skills should emphasize the importance of `MEMORY.md` and relevant `docs/` files. They should instruct the orchestrator to retrieve strategic and architectural context before delegating or reviewing work, and to check that task-specific guidance does not contradict higher-level strategy or previous decisions.

## Memory and logs

### `memory/YYYY-MM-DD.md`

Daily working memory.

Use it for session notes, task summaries, implementation reflections, bug triage notes, team discussion summaries, and observations that may later be promoted into `MEMORY.md` or docs.

### `DREAMS.md`

Optional dreaming/consolidation review surface.

Useful later for memory promotion and strategic synthesis, but not part of the initial core architecture.

## Design principle

Junie Live should not rely on a huge always-loaded memory file. The durable architecture is layered:

1. `MEMORY.md` keeps compact strategic state always available.
2. `docs/` stores detailed strategy, architecture, and decision records.
3. `AGENTS.md` and skills enforce mandatory retrieval of relevant details before meaningful work.
4. The orchestrator extracts only necessary context for OpenRouter subagents and remains responsible for review.
5. The orchestrator continuously checks that its own guidance remains coherent; contradictions are resolved from context when safe, otherwise escalated to the team or the most relevant person.
6. `MEMORY.md` is protected by regular size checks so the strategic core remains fully available as always-on context.

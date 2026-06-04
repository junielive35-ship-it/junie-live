# Hermes Context Files for Junie Live

This document defines how Junie Live should use Hermes profile files, target-repo context files, memory, skills, and supporting docs to maintain durable context.

## Core profile and repo files

### `SOUL.md`

Profile-wide identity and always-on operating safety net.

Installed location:

```text
~/.hermes/profiles/junie-live/SOUL.md
```

Hermes auto-loads `SOUL.md` into the system prompt for the profile. Use it for:

- senior developer / product-owner persona;
- communication style and technical taste;
- initialization gate;
- no-direct-coding rule;
- challenge protocol;
- memory discipline;
- rules that must apply even when the current working directory is not the target repo.

It should not contain detailed project strategy, implementation status, or operational references. Those belong in memory and profile docs.

Avoid HTML comments or other prompt-injection-looking markup in `SOUL.md`, because Hermes may block auto-loaded context files that trip its injection scanner.

### `HERMES.md`

Target-repo operating protocol for the orchestrator. Although the file lives at the target repo root for Hermes auto-load semantics, treat it as Junie agent operating state, not ordinary repository documentation.

Installed location in an initialized target repo:

```text
<target-repo>/HERMES.md
```

Seed source:

```text
hermes/initialization/docs/seed-HERMES.md
```

Hermes auto-loads `HERMES.md` from the current working directory, walking up to the git root. Use it for project-level operating rules:

- senior-owner behavior for the assigned project/area;
- context retrieval before meaningful work;
- delegation rules;
- implementation review rules;
- repository hygiene;
- approval requirements;
- code mutex semantics;
- recurring routines and change rules.

`HERMES.md` is deliberately separate from `AGENTS.md`. Coding executors such as OpenCode, Codex, and Claude Code commonly read `AGENTS.md`, `CLAUDE.md`, or `.cursorrules`; they should not inherit orchestrator-only rules such as challenge protocol, no-direct-coding constraints for the orchestrator, or mutex escalation procedures. Keeping the Junie orchestrator protocol in `HERMES.md` keeps worker sessions cleaner.

For consistency checks, bucket conflicts involving `HERMES.md` as agent-state / project-contract conflicts, not as ordinary repo-doc conflicts, even when the file is physically stored in the repository.

### `INITIALIZATION.md`

One-shot initialization sentinel and workflow.

Installed location before initialization completes:

```text
~/.hermes/profiles/junie-live/INITIALIZATION.md
```

Use it to guide a newly hired Junie instance through multi-round project initialization. While this file exists, the profile is not initialized. The agent must read it before doing normal work, ask the required questions, build durable memory/docs, and delete or archive the sentinel only when initialization is complete.

`INITIALIZATION.md` should be deleted after successful initialization so future sessions enter normal operating mode.

### `memory-seed.md`

Initial memory template for hire/setup.

Installed location:

```text
~/.hermes/profiles/junie-live/memory-seed.md
```

Use it to define the initial durable facts that should be added to Hermes memory during or immediately after initialization. It is not the live memory store. Live memory is managed by Hermes memory tools and injected automatically into every turn.

### Hermes memory stores

Compact always-on strategic compass.

Hermes memory replaces a manually maintained `MEMORY.md` file. It has separate stores for:

- user facts: owner identity, communication preferences, escalation path;
- project/agent memory: strategy, architecture constraints, accepted decisions, owned area, stable environment facts.

Use memory for compact, durable facts that should affect future turns. Do not store full strategy docs, temporary task progress, PR numbers, issue numbers, commit SHAs, or logs in memory. Detailed explanations belong in profile docs.

Memory is auto-injected, so every entry must stay small and declarative. If a fact needs a procedure or checklist, put it in a skill or doc instead.

## Detailed knowledge base

### Profile `docs/`

Installed location:

```text
~/.hermes/profiles/junie-live/docs/
```

Seed source:

```text
hermes/initialization/docs/
```

Use this directory for detailed source-of-truth project knowledge that does not fit in memory:

- `strategy.md` — product strategy, goals, non-negotiable priorities;
- `architecture.md` — architecture, invariants, key design decisions;
- `design-decisions.md` — accepted and rejected design choices;
- `product-hypotheses.md` — hypotheses and their evidence/status;
- `analytics-plan.md` — signals and measurement plans;
- `tools.md` — operational cheat-sheet: repo paths, commands, git conventions, deploy/rollback, dashboards, escalation contacts, local caveats;
- `delegation-protocol.md` — Marinator delegation rules;
- `review-protocol.md` — implementation review and acceptance gates;
- `reflection-protocol.md` — post-task reflection workflow;
- `consistency-protocol.md` — contradiction detection/resolution;
- `implementation-status.md` — implemented/partial/contract-only/deferred status;
- `backlog-protocol.md` — Hermes-native backlog conventions;
- `code-mutex-protocol.md` — installed profile mutex protocol.

`HERMES.md` should make consulting relevant profile docs obligatory before meaningful product changes, code changes, architecture decisions, delegation, review, deployment-adjacent work, and mutex escalation.

The orchestrator owns retrieval and summarization. Coding workers do not receive the full docs by default; they receive only relevant extracted context. Markdown-only documentation/guidance updates can be handled directly by the orchestrator when no source code, scripts, tests, config, generated files, or external systems are changed.

### Repo `hermes/docs/`

Source-repo documentation for the Hermes implementation itself.

Location in this repository:

```text
hermes/docs/
```

Use it for implementation documentation that belongs with the reusable Hermes Junie Live codebase:

- setup guide;
- architecture overview;
- day-to-day routine contract;
- autonomous/overnight routine contract;
- implementation status;
- context-file model;
- code mutex design.

These files are not automatically installed into a hired profile unless they are also present under `hermes/initialization/docs/` or copied by the hire script. Keep that distinction explicit: `hermes/docs/` documents the implementation; `hermes/initialization/docs/` seeds live profile knowledge.

## Skills

### Profile `skills/`

Installed location:

```text
~/.hermes/profiles/junie-live/skills/
```

Seed source:

```text
hermes/initialization/skills/
```

Use skills for repeatable Junie workflows, especially:

- task intake and validation;
- coding task decomposition;
- implementation review;
- post-task reflection and self-improvement;
- bounded autonomous work windows.

Skills should emphasize memory and relevant docs retrieval before meaningful work. They should instruct the orchestrator to validate work against strategy, architecture, prior decisions, and existing Hermes capabilities before delegating or proposing implementation.

When a skill is incomplete, stale, or wrong, patch it immediately. Skills are procedural memory; stale procedures become liabilities.

## Plugins and tools

### Profile `plugins/`

Installed location:

```text
~/.hermes/profiles/junie-live/plugins/
```

Seed source:

```text
hermes/initialization/plugins/
```

Use plugins for Hermes-native tool integrations that Junie needs at runtime. Current core plugins include:

- `marinator-delegation` — exposes `marinator_delegate`, creates durable worker runs, supervises OpenCode, records status/log/result artifacts, and wakes the orchestrator;
- `autonomous-work` — exposes `autonomous_work_start` and `autonomous_work_step`, creates bounded window directories, and drives deterministic autonomous-window phases.

Plugin state belongs under profile-local Junie state, not in the target repo.

## Operational state

### Profile-local Junie state

Canonical location:

```text
~/.hermes/profiles/junie-live/junie-live/state/
```

Use this tree for runtime state:

```text
state/
  backlog/
    items/
    archive/
    events.jsonl
  code_mutex/
    holder.json
  marinator/
    runs/<job_id>/
  autonomous_work/
    windows/<window_id>/
  consistency/
    consistency-state.json
    PENDING_CONTRADICTIONS.md
    runs/<run_id>/
  reflections/
  overnight/
  logs/
```

Runtime state is not strategy memory and should not be copied into target repos. It is inspectable evidence for current work, debugging, and audit trails.

### Sessions and logs

Hermes session history and logs are managed by Hermes itself:

```text
~/.hermes/profiles/junie-live/state.db
~/.hermes/profiles/junie-live/sessions/
~/.hermes/profiles/junie-live/logs/
```

Use `session_search` for recalling previous conversations and decisions. Use logs for debugging gateway, scheduler, provider, or tool behavior.

## Design principle

Junie Live should not rely on one huge always-loaded context file. The durable architecture is layered:

1. `SOUL.md` carries identity and always-on safety rules.
2. Hermes memory keeps compact strategic state always available.
3. `HERMES.md` carries target-repo operating protocol when working in the repo.
4. Profile `docs/` stores detailed strategy, architecture, operational references, and protocols.
5. Skills enforce reusable workflows and retrieval discipline.
6. Plugins provide Hermes-native runtime tools.
7. Profile-local state stores mutable runtime evidence and work queues.
8. The orchestrator extracts only necessary context for coding workers and remains responsible for review, without doing coding work itself.
9. The orchestrator continuously checks that guidance remains coherent; contradictions are resolved from context when safe, otherwise escalated to the owner or relevant team.

This layered model keeps the strategic core available, the details inspectable, and coding-worker prompts focused.

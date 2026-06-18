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

Target-repo operating protocol for Team Lead. Although the file lives at the target repo root for Hermes auto-load semantics, treat it as Junie agent operating state, not ordinary repository documentation.

Installed location in an initialized target repo:

```text
<target-repo>/HERMES.md
```

Seed source:

```text
hermes/distribution/HERMES.seed.md
```

Hermes auto-loads `HERMES.md` from the current working directory, walking up to the git root. Use it for project-level operating rules:

- senior-owner behavior for the assigned project/area;
- context retrieval before meaningful work;
- Team Lead handoff rules;
- Senior Dev contract/reference rules;
- repository hygiene;
- approval requirements;
- code-work routing / concurrency semantics;
- recurring routines and change rules.

`HERMES.md` is deliberately separate from `AGENTS.md`. Coding executors and the headless Senior Dev runtime commonly read `AGENTS.md`, `CLAUDE.md`, or `.cursorrules`; they should not inherit Team Lead-only rules such as challenge protocol, no-direct-coding constraints for Team Lead, or user-facing escalation procedures. Keeping the Team Lead protocol in `HERMES.md` keeps Senior Dev sessions cleaner.

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
hermes/distribution/docs/
```

Use this directory for detailed source-of-truth project knowledge that does not fit in memory:

- `strategy.md` — product strategy, goals, non-negotiable priorities;
- `architecture.md` — architecture, invariants, key design decisions;
- `design-decisions.md` — accepted and rejected design choices;
- `product-hypotheses.md` — hypotheses and their evidence/status;
- `analytics-plan.md` — signals and measurement plans;
- `tools.md` — operational cheat-sheet: repo paths, commands, git conventions, deploy/rollback, dashboards, escalation contacts, local caveats;
- `delegation-protocol.md` — Team Lead → headless Senior Dev handoff rules;
- `review-protocol.md` — Senior Dev review reference and transition notes;
- `reflection-protocol.md` — post-task reflection workflow;
- `consistency-protocol.md` — contradiction detection/resolution;
- `implementation-status.md` — implemented/partial/contract-only/deferred status.

`HERMES.md` should make consulting relevant profile docs obligatory before meaningful product changes, code changes, architecture decisions, handoffs, reflection, and deployment-adjacent work.

Team Lead owns retrieval and summarization. Senior Dev does not receive the full docs by default; it receives only relevant extracted context in the handoff. Markdown-only documentation/guidance updates can be handled directly by Team Lead when no source code, scripts, tests, config, generated files, or external systems are changed.

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
- overnight routine contract;
- implementation status;
- context-file model.

These files are not automatically installed into a hired profile unless they are also present under `hermes/distribution/docs/` (the canonical seed source) or copied by the hire script. Keep that distinction explicit: `hermes/docs/` documents the implementation; `hermes/distribution/docs/` seeds live profile knowledge.

## Skills

### Profile `skills/`

Installed location:

```text
~/.hermes/profiles/junie-live/skills/
```

Seed source:

```text
hermes/distribution/skills/
```

Use skills for repeatable Team Lead workflows, especially:

- task intake and validation;
- post-task reflection and self-improvement.

Skills should emphasize memory and relevant docs retrieval before meaningful work. They should instruct Team Lead to validate work against strategy, architecture, prior decisions, and existing Hermes capabilities before sending a Senior Dev handoff or proposing implementation.

When a skill is incomplete, stale, or wrong, patch it immediately. Skills are procedural memory; stale procedures become liabilities.

## Plugins and tools

### Profile `plugins/`

Installed location:

```text
~/.hermes/profiles/junie-live/plugins/
```

Seed source:

```text
hermes/distribution/plugins/
```

Use plugins for Hermes-native tool integrations that Junie needs at runtime. Current core plugins include:

- `senior-task` — exposes compatibility tools such as `senior_active_tasks` and `create_senior_task` for Team Lead handoff/follow-up routing;
- `senior-runner` — exposes `senior_run_coding_task` for the `senior-dev` profile's synchronous headless Junie CLI run.

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
  reflections/
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
8. Team Lead extracts only necessary context for Senior Dev and remains responsible for handoff quality, without doing coding work itself.
9. Team Lead continuously checks that guidance remains coherent; contradictions are resolved from context when safe, otherwise escalated to the owner or relevant team.

This layered model keeps the strategic core available, the details inspectable, and coding-worker prompts focused.

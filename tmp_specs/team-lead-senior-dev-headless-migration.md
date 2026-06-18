# Team Lead + Headless Senior Dev Migration Plan

## Goal

Move Junie Live to the new contract:

- **Team Lead** is the Hermes user-facing agent: owns live context, intake, acceptance criteria, and handoff.
- **Senior Dev** is a headless Junie CLI delivery agent: owns implementation, review, verification, fix loop, and final verdict.
- Team Lead does **not** do implementation decomposition, code review, or hidden second verification after handoff.

## Non-goals

- Do not design Senior Dev internal subagents yet.
- Do not introduce Senior Dev skills yet.
- Do not store Junie internal state in the target repo.
- Do not rely on repo docs as guaranteed-current architecture/design-decision source of truth.

## 0. Support headless Junie CLI Senior Dev runtime

Implement/define the non-interactive Senior Dev invocation path.

Junie CLI key now lives in ~/junie.key, use it, don't bother too much about safety now. As LLM
use Opus 4.8.

Acceptance:

- Team Lead can hand off a task to headless Junie CLI with:
  - repo path;
  - user outcome;
  - acceptance criteria;
  - distilled context from Team Lead docs/memory;
  - constraints and non-goals;
  - expected report schema.
- Senior Dev returns structured final verdict:
  - `review-required`;
  - `needs-input`;
  - `failed`.
- The contract states Senior Dev owns implementation, review, verification, and fix loop end-to-end.

## 1. Add first-class `~/.junie/AGENTS.md`

`~/.junie/AGENTS.md` is the Senior Dev operating contract.

Acceptance:

- Add a seed version for `~/.junie/AGENTS.md` in Junie Live distribution.
- Hire/install creates it.
- Initialization knows it exists and validates/reconciles it.
- Dump/rehire preserves and restores it.
- Update/hot-swap has an explicit rule for seed vs live-edited version.
- Verification checks that it exists and contains the current Senior Dev contract.

## 2. Lifecycle integration

Ensure the new Senior runtime works across the whole Junie lifecycle.

Acceptance:

- Fresh hire/install produces working Team Lead + headless Senior Dev setup.
- Live runtime can execute Team Lead → Senior Dev handoff.
- Dump/rehire restores Hermes Team Lead state plus `~/.junie/AGENTS.md`.
- Verification covers the runtime and recovery paths.
- Docs describe what is implemented vs deferred.

## 3. Team Lead context and custom skills cleanup

Keep Team Lead focused on context and handoff.

Acceptance:

- Keep Team Lead context in Hermes profile/workspace:
  - `SOUL.md`;
  - memory;
  - profile docs;
  - Team Lead runtime skills.
- Drop custom skill `junie-coding-task-decomposition`.
- Move `junie-implementation-review` content into docs as historical/transition material or Senior-contract reference.
- Keep and update:
  - `junie-task-intake-validation`;
  - `junie-task-reflection`.
- Reflection improves context/protocol after Senior reports or user feedback; it does not review implementation.

## 4. Documentation and terminology migration

Update docs to match the new architecture.

Acceptance:

- Replace Junie role terminology from `orchestrator` to **Team Lead**.
- Keep `orchestrator` only for historical notes or generic external architecture pattern if needed.
- Remove old contract where Team Lead reviews Senior artifacts before acceptance.
- Document:
  - Team Lead = Hermes Agent;
  - Senior Dev = headless Junie CLI;
  - Team Lead owns live context and handoff;
  - Senior Dev owns delivery.
- Run a docs drift scan for old terms and old Marinator/Senior Kanban assumptions.

## 5. Verification checklist

Before calling migration done:

- `~/.junie/AGENTS.md` seed exists.
- Hire/install path creates Senior Dev runtime context.
- Initialization checks Senior Dev context.
- Dump/rehire preserves Senior Dev context.
- Team Lead custom skills no longer include decomposition/review behavior.
- Docs no longer describe Team Lead as implementation reviewer.
- Docs no longer use `orchestrator` as the primary Junie role.

## Open decisions

- Exact headless Junie CLI command and report schema.
- Whether `~/.junie/AGENTS.md` is fully overwritten on update or reconciled with live local edits.
- Where to store Senior run artifacts if they are needed outside the final report.

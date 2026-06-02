# MEMORY.md — Compact Strategy Context

This file starts as a seed. During bootstrap, replace placeholders with the compact strategic core for the assigned project or feature area.

Keep this file short enough to remain always available. Detailed explanations belong in `docs/`.

After each edit to this file, check its size. If it is too large or near the configured context/bootstrap budget, move details into `docs/` and keep only the strategic core here.

## Assignment

- Project/repo: TODO
- Owned area: TODO
- Primary communication channels: TODO
- Relevant people/teams: TODO
- Current initialization status: not initialized

## Strategic compass

TODO: summarize the product goal and current strategy in a few bullets.

## Owner operating preferences

TODO: capture durable owner preferences for authority, workflow, reporting, and interaction style.

Seed default: do not modify the target project, workspace guidance, docs, skills, tools, or external systems unless the owner/requester explicitly asked for that change or the initialized project has clearly delegated that authority. When a change seems useful but was not explicitly requested, propose the exact change first. If unsure whether a file should be changed, ask before editing.

## Durable product principles

TODO: list compact product principles that should guide tradeoffs and challenge requests.

## Autonomous ownership model

TODO: summarize what Junie monitors, recurring routines, when it may act without being asked, and how it reports.

## Non-negotiable priorities

TODO: list constraints Junie must not violate, such as reliability, privacy, compliance, UX, cost, or delivery commitments.

## Architecture constraints

TODO: summarize architecture constraints that should affect task intake, planning, delegation, and review.

Seed default: the orchestrator never does coding work itself. All coding work is delegated to opencode powered by Claude Opus 4.8 with low reasoning. Documentation-only Markdown edits are an explicit exception: the orchestrator may directly edit Markdown docs/guidance when no source code, scripts, tests, config, generated files, or external systems are changed.

## Accepted decisions

TODO: list durable decisions and link to `docs/design-decisions.md` for detail.

## Active hypotheses

TODO: list active product/technical hypotheses and link to `docs/product-hypotheses.md` for detail.

## Known unresolved contradictions

TODO: list unresolved conflicts that must block or constrain work until resolved.

## Docs index

- `docs/strategy.md` — detailed product strategy.
- `docs/architecture.md` — architecture and implementation context.
- `docs/design-decisions.md` — accepted and proposed decisions.
- `docs/product-hypotheses.md` — product/technical hypotheses.
- `docs/analytics-plan.md` — metrics and evidence plan.
- `docs/delegation-protocol.md` — coding worker delegation rules.
- `docs/review-protocol.md` — implementation review checklist.
- `docs/reflection-protocol.md` — post-task reflection workflow.
- `docs/consistency-protocol.md` — guidance and docs consistency workflow.

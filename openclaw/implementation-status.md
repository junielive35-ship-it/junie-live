# Junie Live Implementation Status

This document maps root product docs to current implementation reality. Use it before planning or accepting work so we do not confuse vision, contracts, and implemented behavior.

Status values:

- **implemented** — behavior exists and has verification evidence.
- **partial** — some behavior exists, but important gaps remain.
- **contract-only** — docs define intended behavior; implementation is missing or not complete.
- **deferred** — intentionally out of MVP/current scope.
- **unknown** — not verified yet.

## Strategic thread

Junie Live aims to be a persistent product-owning senior SWE agent for one assigned project/area, not a generic coding bot. The MVP priority is the autonomous ownership loop, also called the **Marinator** when referring to the task-solving loop itself: strategy/context → selected work item → mutex → delegated opencode worker → orchestrator review/fix/verification → meaningful commit/report → reflection/cleanup.

The Marinator delegation boundary now ships inside the reusable seed: the `initialization/marinator-delegation/` OpenClaw plugin exposes the `marinator_delegate` tool, which drives the bounded `initialization/marinator-delegation/scripts/delegate-coding-task.sh` opencode runner bundled inside the plugin. `hire-junie.sh` copies these into the workspace, installs (copies) the plugin, and patches OpenClaw config so a freshly hired instance can delegate without manual setup. The full opencode worker loop has now been exercised end to end, including the supervised wake-back path: worker completes → runner wakes the orchestrator → orchestrator reviews the run's result artifact (`.openclaw/state/marinator/runs/<job_id>/result.md`) and diff → orchestrator's report is delivered to the originating chat. `hire-junie.sh` bakes in the heartbeat wake-runner config (explicit fields, `target: last`, shared real session) and Telegram heartbeat visibility (`showOk: false`) that this loop depends on. Remaining work is exercising it across more real projects and in CI.

## Current status matrix

| Area / capability | Source docs | Status | Evidence | Gaps / notes |
| --- | --- | --- | --- | --- |
| Reusable initialization seed | `initialization.md`; `initialization/` | implemented | `hire-junie.sh`; seed files; bundled `initialization/scripts/` and `initialization/marinator-delegation/`; `scripts/verify.sh` seed checks | Seed now carries the Marinator delegation runtime so a hired instance is self-contained. Needs real usage across more projects. |
| Initialized project workspace model | `openclaw_files.md`; `initialization.md` | implemented for this repo | workspace `/home/Danila.Savenkov/.openclaw/workspace-junie-live` | Keep seed generic; project state belongs in initialized workspace/root docs. |
| Hermes-native baseline | `hermes/README.md`; `hermes/docs/implementation-status.md` | baseline exists; separate development | `hermes/` directory | Keep Hermes-specific implementation under `hermes/`; root docs only need high-level awareness unless platform direction changes. |
| Strategy/current-status awareness | `idea.md`; `day_to_day_routines.md`; this file | partial | this file; workspace `docs/implementation-status.md` | Keep current after meaningful changes. |
| Code mutex protocol | `code_mutex.md`; `day_to_day_routines.md` | implemented | `initialization/scripts/code-mutex-status.sh`; lock-directory contract | Helper scripts that depended on the removed backlog implementation were dropped. |
| Marinator / delegated code-changing flow | `idea.md`; `day_to_day_routines.md`; seed protocols | partial | `initialization/marinator-delegation/` plugin (`marinator_delegate` tool); bundled `initialization/marinator-delegation/scripts/delegate-coding-task.sh` runner; `hire-junie.sh` installs the plugin, patches OpenClaw config, and registers the heartbeat wake-runner (`target: last`, shared real session) + Telegram heartbeat visibility (`showOk: false`) | End-to-end opencode worker run + supervised wake-back to orchestrator + delivered report verified manually (2026-05-29). Executor-isolation invariant (runner talks only to orchestrator) documented in `initialization/docs/delegation-protocol.md`; runner still has DEBUG-ONLY direct `send_telegram` progress sends pending removal. Not yet exercised in CI. |
| User-outcome completion safeguards | seed protocols | implemented as guidance | seed `AGENTS.md`; `initialization/docs/review-protocol.md`; `initialization/docs/delegation-protocol.md`; verify checks | Must be enforced by reviewers; not just documented. |
| Repo-root hygiene | `day_to_day_routines.md`; `scripts/check-repo-hygiene.sh` | implemented | `scripts/check-repo-hygiene.sh`; `scripts/verify.sh` | Watch for OpenClaw bootstrap accidentally using repo root. |
| Admin autonomous work window | `day_to_day_routines.md` | contract-only | high-level routine intent remains | Previous `start-autonomous-window`, controller, watchdog, backlog, and worker scripts were removed. Do not claim this as implemented until rebuilt. |
| Overnight/watchdog cron install | `hire-junie.sh`; `initialization.md` | removed | no root cron installer script; no root watchdog script | Future scheduling should use an approved OpenClaw-native design. |
| Backlog scripts | `day_to_day_routines.md` | removed | no root `scripts/backlog*.sh` | Future planning surface is undecided. |
| Hypothesis generation | `day_to_day_routines.md` | contract-only | high-level routine intent remains | Previous file-backed hypothesis/backlog scripts were removed. |
| Routine health check | `day_to_day_routines.md` | contract-only | high-level routine intent remains | Previous shell routine-health implementation was removed. |
| PR/CI lifecycle | `day_to_day_routines.md` | partial/contract-only | `initialization/scripts/pr-status.sh`; `initialization/scripts/pr-follow-up.sh` smoke tests | PR authority, CI conventions, and real integration not configured. |
| MD consistency scan | `day_to_day_routines.md` | partial | `initialization/scripts/md-consistency.sh`; verify smoke tests | Detects stale file references; semantic contradiction detection not yet implemented. |
| Reflection/self-improvement | `day_to_day_routines.md`; seed docs | partial | `initialization/scripts/reflect.sh`; seed protocol docs | Reflection script is now standalone and no longer tied to backlog task release. |
| Capability usage analytics | `capabilities_usage_tracking.md` | deferred | doc explicitly says v2 | Must not block MVP routines. |
| Deployment/release process | `TOOLS.md`; `MEMORY.md` | unknown/not configured | no command/dashboard recorded | Ask Danila before deploy/release actions. |
| Team/group communication | `TOOLS.md`; `USER.md` | unknown/not configured | Telegram DM/group only | External/team-facing messages require approval. |

## How to use this file

Before a meaningful task:

1. Locate the relevant capability here.
2. Check the source docs and evidence.
3. If the row is stale or missing, update this file as part of the task or call out the gap.
4. Do not claim a user-visible outcome is done unless the status/evidence supports it.

## Maintenance rule

When root docs add or materially change a capability, update this file in the same change or explicitly state why status is unknown. `scripts/verify.sh` and direct inspection are evidence; aspirational docs alone are not.

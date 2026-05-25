# Junie Live Implementation Status

This document maps root product docs to current implementation reality. Use it before planning or accepting work so we do not confuse vision, contracts, and implemented behavior.

Status values:

- **implemented** — behavior exists and has verification evidence.
- **partial** — some behavior exists, but important gaps remain.
- **contract-only** — docs define intended behavior; implementation is missing or not complete.
- **deferred** — intentionally out of MVP/current scope.
- **unknown** — not verified yet.

## Strategic thread

Junie Live aims to be a persistent product-owning senior SWE agent for one assigned project/area, not a generic coding bot. The MVP priority is the autonomous ownership loop: strategy/context → backlog or next action → mutex → delegated opencode worker → orchestrator review/fix/verification → meaningful commit/report → reflection/cleanup.

Overnight/admin autonomous routines are the current priority because they exercise that full loop in a bounded, user-visible way. If this works, Junie is no longer just answering Telegram messages; it can own a work window and return verified outcomes or blockers.

## Current status matrix

| Area / capability                    | Source docs                                                        | Status                                | Evidence                                                                                                               | Gaps / notes                                                                  |
| ------------------------------------ | ------------------------------------------------------------------ | ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Reusable initialization seed         | `initialization.md`; `initialization/`                             | implemented                           | `hire-junie.sh`; seed files; `scripts/verify.sh` seed checks                                                           | Needs real usage across more projects.                                        |
| Initialized project workspace model  | `openclaw_files.md`; `initialization.md`                           | implemented for this repo             | workspace `/home/Danila.Savenkov/.openclaw/workspace-junie-live`                                                       | Keep seed generic; project state belongs in initialized workspace/root docs.  |
| Strategy/current-status awareness    | `idea.md`; `day_to_day_routines.md`; this file                     | partial                               | this file; workspace `docs/implementation-status.md`                                                                   | New and should be kept current after meaningful changes.                      |
| Code mutex protocol                  | `code_mutex.md`; `day_to_day_routines.md`                          | implemented                           | scripts `code-mutex-status.sh`; `task-acquire.sh`; `task-release.sh`; verify checks                                    | External queueing/distributed lock intentionally out of MVP.                  |
| Delegated code-changing flow         | `day_to_day_routines.md`; seed protocols                           | partial/implemented for local scripts | opencode boundary `scripts/run-backlog-worker.sh`; verify fake-worker tests                                            | Real long-running opencode path still needs production test.                  |
| User-outcome completion safeguards   | seed protocols                                                     | implemented                           | seed `AGENTS.md`; `docs/review-protocol.md`; `docs/delegation-protocol.md`; verify checks                              | Must be enforced by reviewers; not just documented.                           |
| Repo-root hygiene                    | `day_to_day_routines.md`; `docs/overnight-routines.md`             | implemented                           | `scripts/runtime-paths.sh`; `scripts/check-repo-hygiene.sh`; verify twice passed                                       | Watch for OpenClaw bootstrap accidentally using repo root.                    |
| Admin autonomous work window         | `day_to_day_routines.md`; `docs/overnight-routines.md`; seed skill | implemented; needs real run           | `scripts/start-autonomous-window.sh`; `scripts/overnight-controller.sh`; `scripts/run-backlog-worker.sh`; verify tests | No real multi-hour autonomous run has been accepted yet.                      |
| Verification fix retry loop          | `docs/overnight-routines.md`                                       | implemented                           | default `AUTONOMOUS_FIX_RETRIES=7`; verify retry tests                                                                 | Applies after verification failure; systemic failures still stop.             |
| Continue after local task failure    | `docs/overnight-routines.md`                                       | implemented                           | commit `2b7145f`; `--continue-on-local-failure`; `--max-local-failures 3`; verify tests                                | Stops on cleanup failure; too many local failures; or systemic blockers.      |
| Overnight cron install for new hires | `docs/overnight-routines.md`; `initialization.md`                  | implemented for future hires          | `scripts/install-overnight-crons.sh`; `hire-junie.sh`; verify dry-run tests                                            | Watchdog enabled by default; controller/report installed disabled unless explicitly enabled. |
| Watchdog/stuck worker handling       | `docs/overnight-routines.md`                                       | partial                               | `scripts/overnight-watchdog.sh`; cron schedule defaults; verify tests                                                  | Idle-safe; detects/cleans stale states; detects backlog items stuck in_progress without active owner (contract req 6); richer progress detection may still evolve. |
| Report generation                    | `docs/overnight-routines.md`                                       | partial                               | `scripts/overnight-report.sh`; verify smoke tests; kv format                                                           | Human and kv formats include backlog summary (with blocked count), commits-in-window, local failures, routine summary, and watchdog. Scheduled morning report is deprecated by default. |
| Backlog scripts                      | `day_to_day_routines.md`                                           | partial                               | `scripts/backlog*.sh`; `next-action.sh`; verify smoke tests                                                            | Local file-backed workflow; no external issue tracker configured.             |
| PR/CI lifecycle                      | `day_to_day_routines.md`                                           | partial/contract-only                 | `scripts/pr-status.sh`; `scripts/pr-follow-up.sh` smoke tests                                                          | PR authority; CI conventions; and real integration not configured.            |
| MD consistency scan                  | `day_to_day_routines.md`                                           | partial                               | `scripts/md-consistency.sh`; verify smoke tests                                                                        | Detects stale file references; semantic contradiction detection not yet implemented. |
| Hypothesis generation                | `day_to_day_routines.md`                                           | partial                               | `scripts/hypothesis-generate.sh`; backlog integration                                                                  | Needs real evidence loop and hygiene over time.                               |
| Routine health check                 | `day_to_day_routines.md`                                           | partial                               | `scripts/routine-health.sh`; verify smoke tests                                                                        | Reports blocked items separately; warns on >3 blocked. Needs real schedule/operations evidence.                                      |
| Reflection/self-improvement          | `day_to_day_routines.md`; seed docs                                | partial                               | `scripts/reflect.sh`; `task-release.sh --notes`; drive/controller pass outcome notes; verify tests | Capability analytics deferred; reflections capture worker outcome (success/failure/exit status) via task-release --notes and task duration_seconds computed from mutex holder started_at. |
| Capability usage analytics           | `capabilities_usage_tracking.md`                                   | deferred                              | doc explicitly says v2                                                                                                 | Must not block MVP routines.                                                  |
| Deployment/release process           | `TOOLS.md`; `MEMORY.md`                                            | unknown/not configured                | no command/dashboard recorded                                                                                          | Ask Danila before deploy/release actions.                                     |
| Team/group communication             | `TOOLS.md`; `USER.md`                                              | unknown/not configured                | Telegram DM only                                                                                                       | External/team-facing messages require approval.                               |

## How to use this file

Before a meaningful task:

1. Locate the relevant capability here.
2. Check the source docs and evidence.
3. If the row is stale or missing, update this file as part of the task or call out the gap.
4. Do not claim a user-visible outcome is done unless the status/evidence supports it.

## Maintenance rule

When root docs add or materially change a capability, update this file in the same change or explicitly state why status is unknown. `scripts/verify.sh` and direct inspection are evidence; aspirational docs alone are not.

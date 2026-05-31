# Hermes Junie Live — Implementation Status

This document maps the Junie Live product requirements to the Hermes implementation status.

Status values:
- **implemented** — behavior exists and has evidence.
- **partial** — some behavior exists, but important gaps remain.
- **contract-only** — docs define intended behavior; implementation needs integration testing.
- **deferred** — intentionally out of current scope.

## Current status

Junie Live's task-solving loop is called the **Marinator** when referring to the protocol that validates/decomposes tasks, delegates execution, checks results, requests fixes, verifies, accepts/reports, and reflects. In the Hermes baseline it is a named protocol across memory, skills, docs, and agent behavior, not a separate module.

| Area / capability | Status | Evidence | Gaps / notes |
| --- | --- | --- | --- |
| SOUL.md (personality + safety-net rules) | implemented | `initialization/SOUL.md` | Installed to profile root during hire; auto-loaded by Hermes on every turn |
| HERMES.md (project operating protocol) | implemented | `initialization/docs/seed-HERMES.md` | Copied to `<target-repo>/HERMES.md` by Junie during initialization; auto-loaded by Hermes from cwd |
| Memory seed | implemented | `initialization/memory-seed.md` | Seeded during hire; populated during initialization |
| Operational cheat-sheet (`tools.md`) | implemented | `initialization/docs/tools.md` | Structured template covering project paths, dev commands, git/PR conventions, mutex configuration, deployment & rollback, analytics references, local caveats; populated by Junie during initialization (Hermes equivalent of OpenClaw's TOOLS.md) |
| Initialization workflow | implemented | SOUL + seed-HERMES + memory seed + skills | Follows same multi-round Q&A as OpenClaw version |
| Skills (5 core workflows) | implemented | `initialization/skills/` | task-intake, decomposition, review, reflection, autonomous-window |
| Marinator / delegation protocol docs | implemented | `initialization/docs/delegation-protocol.md`; `initialization/plugins/marinator-delegation/`; `docs/architecture.md`; `docs/day-to-day-routines.md` | `marinator_delegate` Hermes plugin is the approved code-changing delegation path; installed by hire-junie.sh under the `marinator` toolset |
| Marinator delegation plugin | implemented | `initialization/plugins/marinator-delegation/` (plugin.yaml, __init__.py, tools.py, runner.py, state.py, scripts/marinator-worker.sh) | Profile-installed Hermes user plugin; creates durable run dirs, spawns supervised OpenCode, monitors progress, emits markers, wakes orchestrator via notify_on_complete (live) or hermes chat --resume (headless); Kanban and cron continuation deferred |
| Review protocol docs | implemented | `initialization/docs/review-protocol.md` | Same acceptance gates |
| Reflection protocol docs | implemented | `initialization/docs/reflection-protocol.md` | Uses Hermes memory tool |
| Consistency protocol docs | implemented | `initialization/docs/consistency-protocol.md` | Same scan/resolution flow |
| Code mutex | implemented | `hermes/scripts/code-mutex.sh` with `status`/`acquire`/`release`/`check-stale`; `--auto-recover` flag for BROKEN state (empty dir, no holder.json) added in commit `4aefe97` | File-based lock with holder metadata; atomic `mkdir` primitive; stale-by-age recovery intentionally requires manual release (see `code_mutex.md`) |
| Hire script | implemented | `scripts/hire-junie.sh` | Creates profile, installs SOUL.md / skills / docs / seed-HERMES.md |
| Verify script | implemented | `hermes/scripts/verify.sh` — runs bash syntax, local markdown link, **git whitespace (`git diff --check HEAD --`, commit `cc84b1e`)**, directory structure, and skill-frontmatter checks | Closes the `overnight-routines.md` minimum-verification contract (project verification + git whitespace check). Preflight clean-tree check still runs first |
| Opencode delegation model standardization | implemented | All seed prompts/skills use `--model openrouter/anthropic/claude-opus-4.6 --variant low`; typo sweep from `--variant minimal` landed in commit `58f5e2f` | Two skills in `~/.hermes/profiles/junie-live/skills/` still carry `v1.1` enriched content vs `v1.0` in seed — pending owner approval to sync seed forward |
| Telegram communication | contract-only | Hermes gateway handles this natively | Needs gateway setup per-deployment |
| Cron watchdog | contract-only | Documented in `docs/overnight-routines.md`; backlog item queued for owner approval to install a watchdog cron that calls `hermes/scripts/code-mutex.sh check-stale --auto-recover` every 15 min | Created during initialization, not pre-installed as crontab |
| Autonomous work windows | implemented; needs more real runs | Two bounded autonomous windows completed end-to-end on this branch: run #1 (commit `4aefe97`, mutex --auto-recover), run #2 (commit `cc84b1e`, verify.sh whitespace gate, plus 7 new backlog items + 4 status updates). Skill `junie-autonomous-work-window` v1.1.0 in profile captures both `$HOME`-indirection traps discovered | First sustained-load test pending. `$HOME` indirection still requires explicit `OPENROUTER_API_KEY` export from system-home key file at cron-run time — fix candidate logged in backlog |
| Overnight controller | contract-only | Documented flow using cron + delegation | No shell script; orchestrated by LLM |
| Morning report | contract-only | Documented in overnight-routines.md | Generated by cron job |
| Backlog management | partial (cross-stack) | Legacy stack: `scripts/backlog.sh`, `scripts/backlog-hygiene.sh`, `scripts/backlog-rescore.sh` (workspace-state JSON under `${JUNIE_WORKSPACE}/.openclaw/state/backlog/items/`). Hermes-native stack: relies on the same scripts via the shared `runtime-paths.sh`; no Hermes-specific reimplementation | The Hermes stack inherits the legacy backlog scripts; no separate implementation needed. Backlog items routinely created/updated/blocked during autonomous runs |
| PR/CI lifecycle | contract-only | Documented in day-to-day-routines.md; backlog item queued for owner approval to add minimal `.github/workflows/verify.yml` (run both verify scripts on PR) | Depends on target project |
| Hypothesis generation | contract-only | Documented | LLM-driven, no dedicated script in Hermes stack (legacy stack has `scripts/hypothesis-generate.sh`) |
| Capability usage analytics | deferred | Explicitly v2 (`capabilities_usage_tracking.md`); backlog item queued for owner approval to land a no-op append-only telemetry hook ahead of v2 | Same as OpenClaw version; v2 design hooks not yet implemented |

## Key difference from OpenClaw implementation

The OpenClaw version has ~25 shell scripts implementing detailed orchestration logic (backlog management, hypothesis generation, overnight controller loop, worker boundary, etc.). The Hermes version relies on the LLM agent itself to orchestrate these flows using native Hermes tools (delegate_task, cronjob, memory, terminal), guided by skills and docs.

This means:
- Fewer moving parts to maintain
- More flexible (the LLM adapts to situations)
- But less deterministic (shell scripts always do exactly the same thing)
- Needs real-world testing to validate reliability (two autonomous runs complete; sustained load not yet validated)

## Reusable lessons from autonomous runs

Captured here so the next reader doesn't re-discover them:

1. **`$HOME` indirection bites repeatedly under cron.** Hermes overrides `$HOME` to a profile-scoped path (`/home/<user>/.hermes/profiles/<profile>/home`) inside skill / cron / subagent sessions. This silently breaks:
   - `~/.opencode/bin/opencode` (use absolute system-home path `/home/<user>/.opencode/bin/opencode`)
   - `~/.hermes/junie-live/state/...` mutex/state paths
   - **Opencode auth fallback `$HOME/openrouter.key`** — discovered in run #2: the system-home `openrouter.key` file is invisible to a cron-invoked opencode because `$HOME` resolves to the profile home, where the key file does not exist. Workaround: explicitly `export OPENROUTER_API_KEY="$(cat /home/<user>/openrouter.key)"` before every `opencode run` invocation in a cron context.
2. **Backlog drain ≠ window done.** Run #1 ended early after 10 min of a 3 h cap because the queue ran dry. Run #2 added a backlog-generation mandate to the cron prompt to use the remaining time; this file's own refresh is one product of that mandate.
3. **`--variant low` vs `--variant minimal`** — the canonical reasoning effort is `low`, and the typo sweep is complete (commits `58f5e2f` + the autonomous-window v1.1.0 patch in the profile skill). A regression-guard backlog item (`bl-1779837234-78ec`) is queued.
4. **Mutex BROKEN-state auto-recovery** is safe (empty dir, no holder.json — nobody to ask). Stale-by-age recovery is **not** auto-recovered by design — `holder.json` exists, so there is someone to ask.
5. **Hermes cron sessions deliver their final summary via `deliver=`**. There is no streaming progress feed during the window; intra-window progress is observable via live `opencode` child processes, git commits arriving on the branch, and the cron output file appearing in `~/.hermes/profiles/<profile>/cron/output/<job_id>/` at exit.

## Maintenance rule

When adding or changing Hermes Junie Live capabilities, update this file in the same change.

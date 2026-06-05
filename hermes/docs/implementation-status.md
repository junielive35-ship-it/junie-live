# Hermes Junie Live — Implementation Status

This document maps Junie Live product requirements to the Hermes implementation status. Scope note: this Junie owns the whole repository except `openclaw/`; root docs (`idea.md`, `junie-live-architecture.jpg`) describe product intent, while this file tracks the Hermes-native implementation reality.

Status values:
- **implemented** — behavior exists and has evidence.
- **partial** — some behavior exists, but important gaps remain.
- **contract-only** — docs define intended behavior; implementation needs integration testing.
- **deferred** — intentionally out of current scope.
- **unknown** — mentioned or implied, but not yet inspected enough to classify.

## Current status

Junie Live's task-solving loop is the **Marinator**: validate/decompose tasks, delegate execution, check results, request fixes, verify, accept/report, and reflect. In the Hermes baseline it is a named protocol across memory, skills, docs, plugins, and agent behavior, not a separate monolithic runtime module.

| Area / capability | Status | Evidence | Gaps / notes |
| --- | --- | --- | --- |
| Product-level root intent | implemented as documentation | `idea.md`; `junie-live-architecture.jpg` | Root docs are the cross-implementation product north star. Keep this status file aligned when root docs mention capabilities. |
| SOUL.md (personality + safety-net rules) | implemented | `distribution/SOUL.md` | Installed to profile root via Hermes profile distribution; auto-loaded by Hermes on every turn. |
| HERMES.md (project operating protocol) | implemented | `distribution/HERMES.seed.md`; repo `HERMES.md` | Copied to `<target-repo>/HERMES.md` during initialization; auto-loaded by Hermes from cwd. |
| Memory model (long-term + short-term/session context) | implemented / partial | Hermes memory stores; `distribution/memory-seed.md`; `docs/hermes-context-files.md` | Long-term strategic memory exists; short-term/session context is native Hermes behavior. Capability-usage-derived memory simplification is deferred. |
| Operational cheat-sheet / team contacts / role references (`tools.md`) | implemented | `distribution/docs/tools.md`; profile `docs/tools.md` | Covers project paths, dev commands, git/PR conventions, mutex configuration, deployment/rollback, analytics references, local caveats, and Danila escalation path. |
| Initialization workflow | implemented | `SOUL.md`, `INITIALIZATION.md`, HERMES.seed.md, memory seed, skills, `scripts/hire-junie.sh` | Multi-round Q&A is installed for future hired profiles; this active profile is initialized. |
| Skills (5 core workflows) | implemented | `distribution/skills/` | task-intake, decomposition, review, reflection, autonomous-window. |
| Marinator / delegation protocol docs | implemented | `distribution/docs/delegation-protocol.md`; `docs/architecture.md`; `docs/day-to-day-routines.md` | `marinator_delegate` is the approved code-changing delegation path; installed under the `marinator` toolset. |
| Marinator delegation plugin | implemented | `distribution/plugins/marinator-delegation/` | Profile-installed Hermes plugin; creates durable run dirs, spawns supervised OpenCode, monitors progress, emits markers, wakes orchestrator via notify_on_complete (live) or async resume (headless). Per-minute progress reports are enabled by default for debug visibility, but remain observability only and do not replace orchestrator review/verification. Kanban and cron continuation are deferred. |
| Worker result validation and retry/fix loop | implemented as protocol; partially automated | `junie-implementation-review` skill; `review-protocol.md`; `marinator_delegate` follow-up support | Review/fix/acceptance loop is explicit and supported; final quality still depends on orchestrator verification. |
| Code promotion / commit / PR handoff | partial | `day-to-day-routines.md`; git conventions in profile `tools.md`; no `.github/` directory found | Local commits are supported by workflow; PR creation/monitoring and CI automation are not configured. |
| Review protocol docs | implemented | `distribution/docs/review-protocol.md` | Same acceptance gates. |
| Reflection on task completion | implemented | `distribution/docs/reflection-protocol.md`; `junie-task-reflection` skill | Uses Hermes memory/skills/docs updates; reflection is protocol-driven. |
| Self-simplification | contract-only / deferred | Root architecture image; capability usage analytics doc names future simplification consumers | No dedicated self-simplification routine exists beyond reflection and skill/doc cleanup. Capability analytics needed for stronger evidence is v2/deferred. |
| Regular consistency check / MD consistency scan | implemented | `consistency-check-prompt.md`; `consistency_check.py` (runner); `test_consistency_check.py` (tests); `consistency-protocol.md`; `day-to-day-routines.md`; verify.sh integration | Python runner with init/run/render-prompt subcommands, mutex preflight, incremental scan, state-file edit contract (agent edits PENDING_CONTRADICTIONS.md, not stdout sections), backup/restore on validation failure, and pending-contradiction lifecycle. Uses `junie_runtime` for path/state/mutex/events. No scheduled consistency cron is installed (requires owner approval). |
| Code mutex | implemented | `hermes/distribution/scripts/code-mutex.sh` with `status`/`acquire`/`release`/`check-stale`; `docs/code-mutex.md` | File-based lock with holder metadata; atomic `mkdir`; stale-by-age recovery intentionally requires owner review. |
| Hire script | implemented | `scripts/hire-junie.sh` | Creates profile, installs profile distribution, configures Telegram/model/provider/reasoning, enables toolsets, starts/restarts gateway. |
| Verify script | implemented | `hermes/scripts/verify.sh` | Runs clean-tree preflight, bash syntax, local markdown links, git whitespace, directory structure, skill-frontmatter, plugin syntax/regression checks, autonomous-work tests, and initialization-gate tests. |
| OpenCode delegation model standardization | implemented | Seed prompts/skills use `marinator_delegate`; worker does not pin OpenCode model | OpenCode model is operator-configured. Key-file permission hardening remains an accepted MVP deviation in the active profile. |
| Autonomous Work Window plugin | implemented | `distribution/plugins/autonomous-work/` | Exposes `autonomous_work_start` and `autonomous_work_step`; creates bounded window dirs with deterministic phase transitions; installed under `autonomous` toolset. AW start accepts `enable_debug_messages` defaulting true, and the runner can send step-level `[AW debug]` Telegram messages when delivery context is available. Sustained-load confidence still developing. |
| Telegram communication | implemented for active profile; setup-dependent generally | Hermes gateway; `hire-junie.sh`; current Telegram DM session | Per-deployment bot token/admin ID setup still required. |
| External monitoring inputs (messenger, GitHub, analytics, task tracker) | partial / mostly contract-only | Telegram active; git local inspection works; `day-to-day-routines.md` describes PR/CI/analytics/task tracker checks | No external issue tracker, analytics dashboard, GitHub Actions workflow, or PR monitoring integration discovered. |
| Cron watchdog | contract-only | `docs/overnight-routines.md`; `docs/setup.md` post-setup suggestions | Not pre-installed; requires explicit owner decision to create recurring cron behavior. |
| Autonomous work windows | implemented; needs more real runs | AW plugin plus prior bounded runs | First sustained-load test with current plugin remains a product risk. |
| Overnight controller | implemented via AW plugin | `docs/overnight-routines.md`; autonomous-work plugin | Plugin-based, not cron-loop based. Scheduled overnight start is optional/deferred. |
| Morning report | partial | `docs/overnight-routines.md`; AW finalizing phase | Final reports are produced by AW/session finalization; independent scheduled morning report job is not installed. |
| Backlog management: prioritization, deduplication, deprecation | partial | `distribution/plugins/autonomous-work/backlog.py`; `distribution/docs/backlog-protocol.md`; `day-to-day-routines.md` | Markdown/YAML helper supports items/status; scoring/dedup/deprecation are protocol-level, no user-facing CLI or external tracker. Legacy OpenClaw state is not read. |
| PR/CI lifecycle and PR monitoring | contract-only / unknown | `day-to-day-routines.md`; no `.github/` directory found | Confirm conventions or add CI only after approval. |
| Hypothesis generation, prioritization, deduplication, deprecation | contract-only | `product-hypotheses.md`; `day-to-day-routines.md`; root architecture image | LLM-driven; no dedicated Hermes script. Backlog helper can store outcomes, but hypothesis pipeline is not automated. |
| Capability usage analytics | deferred | `capabilities_usage_tracking.md`; root architecture image | v2 only; must not block MVP routines. |

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
    - `~/.hermes/profiles/junie-live/junie-live/state/...` mutex/state paths
   - **Opencode auth fallback `$HOME/openrouter.key`** — discovered in run #2: the system-home `openrouter.key` file is invisible to a cron-invoked opencode because `$HOME` resolves to the profile home, where the key file does not exist. The `marinator-worker.sh` script resolves the system home explicitly; direct `opencode run` invocations in a cron context must export `OPENROUTER_API_KEY` manually.
2. **Backlog drain ≠ window done.** Run #1 ended early after 10 min of a 3 h cap because the queue ran dry. Run #2 added a backlog-generation mandate to the cron prompt to use the remaining time; this file's own refresh is one product of that mandate.
3. **Model pinning removed** — model/variant forcing for OpenCode has been removed from all seed prompts, skills, and docs (this commit). OpenCode uses its operator-configured model. The `marinator_delegate` tool does not pass `--model` or `--variant` flags.
4. **Mutex BROKEN-state auto-recovery** is safe (empty dir, no holder.json — nobody to ask). Stale-by-age recovery is **not** auto-recovered by design — `holder.json` exists, so there is someone to ask.
5. **Autonomous-work observability is layered and not acceptance.** Hermes cron sessions still deliver their final summary via `deliver=`, but current AW windows also have debug/progress visibility: `autonomous_work_start(enable_debug_messages=true)` is the default, AW runner steps can emit `[AW debug]` Telegram messages when the session delivery target is available, and AW execution prompts map that setting to Marinator `enable_per_minute_reports=True` by default. These messages are progress/debug signals only. Completion still depends on final reports, backlog outcomes, git status, orchestrator review, and verification evidence; the extra visibility does not by itself prove sustained-load reliability.

## Maintenance rule

When adding or changing Hermes Junie Live capabilities, update this file in the same change.

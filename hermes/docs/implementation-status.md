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
| Senior Dev Kanban delegation protocol docs | implemented | `distribution/docs/delegation-protocol.md`; `docs/architecture.md`; `docs/day-to-day-routines.md` | `create_senior_task` is the Chat Agent code-changing delegation path. In the current p1 Senior path the `senior-dev` worker uses the synchronous `senior_run_coding_task` (toolset `senior_runner`) plus one terminal `kanban_block`. |
| Senior Dev Kanban task helper | implemented / partial follow-up ergonomics | `distribution/plugins/senior-task/`; `scripts/test-senior-task.sh`; `scripts/test-senior-dev-result.sh` | Chat Agent can create one Senior Dev Kanban task and subscribe the originating chat/thread, and can look up active Senior tasks via `senior_active_tasks`. `senior_dev_task_result` remains for the legacy async path but is not used by the p1 Senior worker. Full p1 follow-up routing still needs live-runtime verification that the Chat Agent can comment/unblock/requeue related `blocked` tasks through available Kanban tooling instead of creating duplicates. |
| Senior Dev synchronous runner | implemented (local integration tests) | `distribution/plugins/senior-runner/`; `scripts/test-senior-runner.sh` | `senior_run_coding_task` (toolset `senior_runner`, senior-dev only) runs one headless Junie CLI task synchronously in the foreground, writes Marinator-style artifacts (`spec.json`, `status.json`, `events.jsonl`, `result.md`, logs), records the exit code and runner state, and returns artifact paths. It emits no verdict and never mutates Kanban; the senior-dev worker reads the artifacts/exit code and chooses one terminal Kanban action itself (default `review-required`). |
| Senior Dev profile lane | implemented with local integration tests; live sustained usage still needs more runs | `distribution/profiles/senior-dev/`; `scripts/install-senior-dev-profile.sh`; `scripts/test-install-senior-dev.sh`; `scripts/test-dump-rehire.sh` | `senior-dev` is installed with `senior-task` and `senior-runner` plugins plus required toolsets (`senior`, `senior_runner`, `kanban`, `terminal`, `file`). The p1 worker protocol (`SOUL.md`) is a thin synchronous adapter: `kanban_show` → `senior_run_coding_task` → one terminal `kanban_block`. `hire-junie.sh` and `rehire-junie.sh` install/update it, so fresh hire and disaster recovery include the companion worker profile. |
| Worker result validation and retry/fix loop | implemented as protocol; partially automated | `junie-implementation-review` skill; `review-protocol.md`; Senior Dev Kanban blocked/requeue convention | Review/fix/acceptance loop is explicit: `blocked(review-required)` is an awaiting-review handoff, and fixes should normally comment/unblock/requeue the related Senior task. Final quality still depends on orchestrator verification. |
| Code promotion / commit / PR handoff | partial | `day-to-day-routines.md`; git conventions in profile `tools.md`; no `.github/` directory found | Local commits are supported by workflow; PR creation/monitoring and CI automation are not configured. |
| Review protocol docs | implemented | `distribution/docs/review-protocol.md` | Same acceptance gates. |
| Reflection on task completion | implemented | `distribution/docs/reflection-protocol.md`; `junie-task-reflection` skill | Uses Hermes memory/skills/docs updates; reflection is protocol-driven. |
| Self-simplification | contract-only / deferred | Root architecture image; capability usage analytics doc names future simplification consumers | No dedicated self-simplification routine exists beyond reflection and skill/doc cleanup. Capability analytics needed for stronger evidence is v2/deferred. |
| Regular consistency check / MD consistency scan | partial | `consistency-protocol.md`; `day-to-day-routines.md`; verify scripts catch links/structure | Semantic contradiction detection is protocol/LLM-driven; no scheduled consistency cron is installed. |
| Hire script | implemented | `scripts/hire-junie.sh`; `scripts/test-dump-rehire.sh` | Creates profile, installs profile distribution, configures Telegram/model/provider/reasoning, enables toolsets, installs/updates the companion `senior-dev` profile, and starts/restarts gateway. |
| Verify script | implemented | `hermes/scripts/verify.sh` | Runs clean-tree preflight, bash syntax, local markdown links, git whitespace, directory structure, skill-frontmatter, plugin syntax checks, Senior Dev install/result/helper tests, Senior p1 tests, initialization-gate tests, and `junie_runtime` tests. |
| OpenCode delegation model standardization | implemented | Chat Agent seed prompts/skills use `create_senior_task`; p1 senior-dev uses `senior_run_coding_task`; worker pins the OpenCode run model via `--model` using `OPENCODE_MODEL` or `openrouter/openai/gpt-5.5` | The Senior runner does not rely on OpenCode DB/session defaults. Key-file permission hardening remains an accepted MVP deviation in the active profile. |
| Telegram communication | implemented for active profile; setup-dependent generally | Hermes gateway; `hire-junie.sh`; current Telegram DM session | Per-deployment bot token/admin ID setup still required. |
| External monitoring inputs (messenger, GitHub, analytics, task tracker) | partial / mostly contract-only | Telegram active; git local inspection works; `day-to-day-routines.md` describes PR/CI/analytics/task tracker checks | No external issue tracker, analytics dashboard, GitHub Actions workflow, or PR monitoring integration discovered. |
| Cron watchdog | contract-only | `docs/overnight-routines.md`; `docs/setup.md` post-setup suggestions | Not pre-installed; requires explicit owner decision to create recurring cron behavior. |
| Autonomous work windows | implemented; needs more real runs | AW plugin plus prior bounded runs | First sustained-load test with current plugin remains a product risk. |
| Overnight controller | contract-only / deferred | `docs/overnight-routines.md` | Scheduled overnight start is optional/deferred; current code-changing execution still routes through Senior Dev Kanban. |
| Morning report | partial | `docs/overnight-routines.md`; AW finalizing phase | Final reports are produced by AW/session finalization; independent scheduled morning report job is not installed. |
| Backlog management: prioritization, deduplication, deprecation | partial | `distribution/docs/backlog-protocol.md`; `day-to-day-routines.md` | Backlog scoring/dedup/deprecation are protocol-level, no user-facing CLI or external tracker. Legacy OpenClaw state is not read. |
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
3. **Model pinning removed** — model/variant forcing for OpenCode has been removed from all seed prompts, skills, and docs. OpenCode uses its operator-configured model.
4. **Mutex BROKEN-state auto-recovery** is safe (empty dir, no holder.json — nobody to ask). Stale-by-age recovery is **not** auto-recovered by design — `holder.json` exists, so there is someone to ask.
5. **Progress visibility is not acceptance.** Cron or gateway summaries are progress/debug signals only. Completion still depends on final reports, backlog outcomes, Kanban task comments/artifacts, git status, orchestrator review, and verification evidence; extra visibility does not by itself prove sustained-load reliability.

## Maintenance rule

When adding or changing Hermes Junie Live capabilities, update this file in the same change.

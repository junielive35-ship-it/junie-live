# Hermes Junie Live — Implementation Status

This document maps Junie Live product requirements to the Hermes implementation status. Scope note: this Junie owns the whole repository except `openclaw/`; root docs (`idea.md`, `junie-live-architecture.jpg`) describe product intent, while this file tracks the Hermes-native implementation reality.

Status values:
- **implemented** — behavior exists and has evidence.
- **partial** — some behavior exists, but important gaps remain.
- **contract-only** — docs define intended behavior; implementation needs integration testing.
- **deferred** — intentionally out of current scope.
- **unknown** — mentioned or implied, but not yet inspected enough to classify.

## Current status

Junie Live's delivery loop is now split by role: Team Lead validates intake, prepares structured handoffs, reports Senior Dev final verdicts, and reflects on context/protocol quality; Senior Dev runs headless Junie CLI and owns implementation, review, verification, fix loop, and final verdict.

| Area / capability | Status | Evidence | Gaps / notes |
| --- | --- | --- | --- |
| Product-level root intent | implemented as documentation | `idea.md`; `junie-live-architecture.jpg` | Root docs are the cross-implementation product north star. Keep this status file aligned when root docs mention capabilities. |
| SOUL.md (personality + safety-net rules) | implemented | `distribution/SOUL.md` | Installed to profile root via Hermes profile distribution; auto-loaded by Hermes on every turn. |
| HERMES.md (project operating protocol) | implemented | `distribution/HERMES.seed.md`; repo `HERMES.md` | Copied to `<target-repo>/HERMES.md` during initialization; auto-loaded by Hermes from cwd. |
| Memory model (long-term + short-term/session context) | implemented / partial | Hermes memory stores; `distribution/memory-seed.md`; `docs/hermes-context-files.md` | Long-term strategic memory exists; short-term/session context is native Hermes behavior. Capability-usage-derived memory simplification is deferred. |
| Operational cheat-sheet / team contacts / role references (`tools.md`) | implemented | `distribution/docs/tools.md`; profile `docs/tools.md` | Covers project paths, dev commands, git/PR conventions, mutex configuration, deployment/rollback, analytics references, local caveats, and Danila escalation path. |
| Initialization workflow | implemented | `SOUL.md`, `INITIALIZATION.md`, HERMES.seed.md, memory seed, skills, `scripts/hire-junie.sh` | Multi-round Q&A is installed for future hired profiles; this active profile is initialized. |
| Skills (Team Lead workflows) | implemented | `distribution/skills/` | Active Team Lead skills are task-intake and reflection. Decomposition/review skills were removed from the distribution because Senior Dev owns implementation planning, review, verification, and fix loop. |
| Senior Dev handoff protocol docs | implemented | `distribution/docs/delegation-protocol.md`; `docs/architecture.md`; `docs/day-to-day-routines.md` | Code-changing work uses the Team Lead → headless Senior Dev contract: repo path, user outcome, acceptance criteria, context, constraints, non-goals, and report schema. |
| Senior Dev handoff helper | implemented / partial follow-up ergonomics | `distribution/plugins/senior-task/`; `scripts/test-senior-task.sh` | Current compatibility tools can create/inspect Senior Dev active work. Full follow-up routing still needs live-runtime verification for comment/unblock/requeue or equivalent configured follow-up actions. |
| Senior Dev synchronous runner | implemented (local integration tests) | `distribution/plugins/senior-runner/`; `distribution/junie/AGENTS.md`; `scripts/test-senior-runner.sh` | `senior_run_coding_task` runs one headless Junie CLI task synchronously in the foreground, writes run artifacts, records exit code/runner state, and returns artifact paths. The handoff requires `FINAL_VERDICT_SCHEMA` (`done` / `needs-input` / `failed`) from `~/.junie/AGENTS.md`. |
| Senior Dev profile/runtime | implemented with local integration tests; live sustained usage still needs more runs | `distribution/profiles/senior-dev/`; `distribution/junie/AGENTS.md`; `scripts/install-senior-dev-profile.sh`; `scripts/test-install-senior-dev.sh`; `scripts/test-dump-rehire.sh`; `scripts/test-initialization-gate.sh` | `hire-junie.sh`, initialization checks, dump/rehire, and verification create, reconcile, preserve, and validate the first-class Senior Dev `~/.junie/AGENTS.md` contract, so fresh hire and disaster recovery include both the companion worker profile and the headless Junie runtime contract. |
| Senior Dev result validation and retry/fix loop | implemented as Senior Dev contract | `distribution/junie/AGENTS.md`; `distribution/docs/senior-dev-review-reference.md`; `distribution/docs/review-protocol.md` | Senior Dev owns implementation review, verification, retry/fix loop, and final verdict. Team Lead must pass through `done`/`needs-input`/`failed` and reflect on future context/protocol quality rather than re-reviewing code. |
| Code promotion / commit / PR handoff | partial | `day-to-day-routines.md`; git conventions in profile `tools.md`; no `.github/` directory found | Local commits are supported by workflow; PR creation/monitoring and CI automation are not configured. |
| Review reference docs | implemented | `distribution/docs/review-protocol.md`; `distribution/docs/senior-dev-review-reference.md` | Preserves historical review checks as Senior Dev contract/reference material, not as an active Team Lead acceptance gate. |
| Reflection on task completion | implemented | `distribution/docs/reflection-protocol.md`; `junie-task-reflection` skill | Uses Hermes memory/skills/docs updates; reflection is protocol-driven. |
| Self-simplification | contract-only / deferred | Root architecture image; capability usage analytics doc names future simplification consumers | No dedicated self-simplification routine exists beyond reflection and skill/doc cleanup. Capability analytics needed for stronger evidence is v2/deferred. |
| Regular consistency check / MD consistency scan | partial | `consistency-protocol.md`; `day-to-day-routines.md`; verify scripts catch links/structure | Semantic contradiction detection is protocol/LLM-driven; no scheduled consistency cron is installed. |
| Hire script | implemented | `scripts/hire-junie.sh`; `distribution/junie/AGENTS.md`; `scripts/test-dump-rehire.sh` | Creates profile, installs profile distribution, reconciles the Senior Dev `~/.junie/AGENTS.md` contract without discarding live edits, configures Telegram/model/provider/reasoning, enables toolsets, installs/updates the companion `senior-dev` profile, and starts/restarts gateway. |
| Verify script | implemented | `hermes/scripts/verify.sh` | Runs clean-tree preflight, bash syntax, local markdown links, git whitespace, directory structure, skill-frontmatter, plugin syntax checks, Senior Dev install/result/helper tests, Senior p1 tests, initialization-gate tests, and `junie_runtime` tests. |
| Headless Senior Dev model standardization | implemented | Team Lead seed prompts/skills require structured Senior Dev handoffs; `senior-dev` uses `senior_run_coding_task`; `distribution/junie/AGENTS.md` defines the final verdict schema | The Senior runner uses headless Junie CLI rather than OpenCode session defaults. Auth/configuration remains environment-specific and is covered by setup docs. |
| Telegram communication | implemented for active profile; setup-dependent generally | Hermes gateway; `hire-junie.sh`; current Telegram DM session | Per-deployment bot token/admin ID setup still required. |
| External monitoring inputs (messenger, GitHub, analytics, task tracker) | partial / mostly contract-only | Telegram active; git local inspection works; `day-to-day-routines.md` describes PR/CI/analytics/task tracker checks | No external issue tracker, analytics dashboard, GitHub Actions workflow, or PR monitoring integration discovered. |
| Cron watchdog | contract-only | `docs/overnight-routines.md`; `docs/setup.md` post-setup suggestions | Not pre-installed; requires explicit owner decision to create recurring cron behavior. |
| Autonomous work windows | implemented; needs more real runs | AW plugin plus prior bounded runs | First sustained-load test with current plugin remains a product risk. |
| Overnight controller | contract-only / deferred | `docs/overnight-routines.md` | Scheduled overnight start is optional/deferred; current code-changing execution still routes through the Senior Dev handoff runtime. |
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
   - **Headless executor auth fallback through profile-scoped `$HOME`** — discovered in earlier runs: files visible from an interactive shell can be invisible to cron-invoked tools because `$HOME` resolves to the profile home. Configure Senior Dev auth through the supported Junie CLI mechanism instead of relying on ad-hoc `$HOME` lookups.
2. **Backlog drain ≠ window done.** Run #1 ended early after 10 min of a 3 h cap because the queue ran dry. Run #2 added a backlog-generation mandate to the cron prompt to use the remaining time; this file's own refresh is one product of that mandate.
3. **Model pinning removed** — model/variant forcing for the headless executor has been removed from Team Lead prompts, skills, and docs. Senior Dev uses its configured Junie CLI model/provider behavior.
4. **Mutex BROKEN-state auto-recovery** is safe (empty dir, no holder.json — nobody to ask). Stale-by-age recovery is **not** auto-recovered by design — `holder.json` exists, so there is someone to ask.
5. **Progress visibility is not acceptance.** Cron or gateway summaries are progress/debug signals only. Completion still depends on Senior Dev final verdicts, backlog outcomes, artifacts, git status, and verification evidence; extra visibility does not by itself prove sustained-load reliability.

## Maintenance rule

When adding or changing Hermes Junie Live capabilities, update this file in the same change.

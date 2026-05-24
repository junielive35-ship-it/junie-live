# Junie Live Day-to-Day Routines

Assumption for v1: Telegram is the only incoming event source. Junie can communicate with the team via Telegram, access GitHub code, and create/update pull requests.

## Core runtime principles

- Junie acts like a senior developer/product owner, not a passive executor.
- Meaningful work is validated against `MEMORY.md`, relevant `docs/`, architecture, strategy, and previous design choices.
- Only one code-changing task may run at a time. A code change mutex protects the repo from parallel conflicting edits. See [`code_mutex.md`](code_mutex.md).
- The orchestrator must never do coding work itself. All coding work is delegated to opencode subagents powered by Claude Opus 4.6 with low reasoning. Documentation-only Markdown changes are an explicit exception: the orchestrator may edit Markdown docs/guidance directly when no source code, scripts, tests, config, generated files, or external systems are changed.
- Code-changing opencode subagents are run sequentially under the mutex, never in parallel, to avoid branch/worktree conflicts and inconsistent reviews.
- `MEMORY.md` is critical always-on strategy context. It is not automatically compacted. Size checks run only after `MEMORY.md` edits.
- Schedules are project-dependent. “Hourly” or “daily” are configuration choices, not fixed rules.

## Event-triggered routines

### 1. Telegram intake

Triggered by DM, mention, or relevant group-chat request.

Flow:

1. Classify the message: question, task request, bug report, feature request, decision request, autonomous work window, FYI/no action.
2. Clarify if needed.
3. For meaningful tasks, retrieve relevant `MEMORY.md` and docs.
4. Validate against strategy, architecture, accepted design choices, and prior decisions.
5. Challenge contradictions instead of blindly accepting the request.
6. Confirm shared understanding for non-trivial tasks.
7. Queue, execute, defer, or ask for approval.

For admin messages like “поработай автономно 9 часов”, “иди улучшай продукт 9 часов”, “работай над проектом до утра”, or “start autonomous loop for 4h”, Junie should recognize a bounded autonomous work-window intent after initialization. The admin should not need to specify repo, backlog, mutex, opencode, verification, meaningful commits, or morning report details; Junie derives those from the initialized workspace. Resolve the duration/end time from the message or ask one concise question if it is missing/ambiguous, then use `scripts/start-autonomous-window.sh --duration ... --background` rather than ad hoc loops. Reply with started/blocked status, duration/end time, state/log/report location, and what to expect next.

### 2. Code task execution

Triggered when an accepted code-changing task is ready and the code change mutex is free.

Flow:

1. Acquire code change mutex using the lock-directory flow from [`code_mutex.md`](code_mutex.md).
2. Decompose task into scoped subagent tasks.
3. Delegate implementation to opencode powered by Claude Opus 4.6 with low reasoning; never implement code directly in the orchestrator. Markdown-only documentation/guidance edits may be made directly by the orchestrator when they are the whole change.
4. Run code-changing opencode subagents sequentially, not in parallel.
5. Give each subagent precise context, constraints, and verification expectations.
6. Review results against the full strategic/architectural context before starting the next code-changing subagent step.
7. Request fixes from opencode until the implementation is correct.
8. Open or update a GitHub pull request.
9. Release mutex when the code-changing work is done, blocked, cancelled, or handed off.

Concrete mutex state lives in `.openclaw/state/code_mutex/holder.json` inside the initialized OpenClaw workspace, not in the repo root. The lock is acquired by atomically creating `.openclaw/state/code_mutex/`; the metadata JSON is only for human-readable state and does not provide atomicity. Repo scripts default runtime state to `${JUNIE_WORKSPACE:-$HOME/.openclaw/workspace-junie-live}/.openclaw/state/...`; tests may override with temp dirs, but production/default runs must never create repo-root `.openclaw/` or `state/`.

If the mutex is already held, do not start code-changing work. Cron/scheduled jobs ask the configured administrator/owner whether to wait, abort, or override. Telegram intake asks the caller the same question and includes the current holder summary when available.

### 3. Pull request lifecycle

Triggered by opened PRs, CI results, review comments, requested changes, merge/close events, or stale PR checks.

Responsibilities:

- track CI status;
- respond to review comments;
- request opencode subagent fixes when needed;
- detect stale PRs;
- communicate blockers;
- update task/backlog state;
- run post-merge follow-up when needed.

### 4. `MEMORY.md` edit → size check

Triggered only when `MEMORY.md` changes.

Rules:

- No automatic compaction.
- If the file exceeds or approaches the configured budget, create an explicit fix candidate.
- The candidate should explain what would move to `docs/`, what would remain in `MEMORY.md`, and why the strategic core is preserved.
- Semantic changes to `MEMORY.md` require approval.

### 5. Task completion → reflection

Triggered after each valuable task.

Responsibilities:

- identify generalizable process/tooling/context improvements;
- avoid one-off “optimizations” that are unlikely to help future tasks;
- record self-improvement history;
- use task artifacts and available execution evidence;
- apply minor safe improvements;
- propose major changes for approval.

## Scheduled / continuous routines

The product/technical contract for stable out-of-box overnight cron work and admin-triggered autonomous work windows is defined in [`docs/overnight-routines.md`](docs/overnight-routines.md). Scheduled routines should preserve that controller/watchdog/morning-report contract even when implemented by smaller scripts. New instances get real OpenClaw cron jobs installed by default during `hire-junie.sh` initialization, plus workspace-local audit/fallback artifacts: `.openclaw/cron/overnight-routines.json` and `.openclaw/cron/overnight-routines.crontab`. The jobs run in isolated sessions, allow `exec,read`, and invoke non-interactive shell commands with explicit repo, state, and log paths; no separate enable/import admin step is required unless `--overnight-artifacts-only` was chosen.

### 6. Code mutex status check

Regular scheduled operation. It is not merely triggered by new queued code work.

Responsibilities:

- check whether the code change mutex is free or held;
- if held, inspect the worker/task holding it;
- verify recent progress, logs, branch/PR state, and expected next action;
- if the worker appears to be hanging or making no useful progress, cancel the task, stop the worker, and preserve relevant logs/state;
- analyze what went wrong before retrying;
- fix the prompt, decomposition, environment, or task constraints if needed;
- rerun only when the retry plan is clear and safe;
- release or transfer the mutex explicitly after cancellation, blockage, handoff, or completion.

### 7. MD consistency scan

Runs on a configurable schedule.

Inputs:

- recent Telegram messages;
- recent commits and PRs;
- changed md files;
- task/backlog/decision state.

Responsibilities:

- detect contradictions and stale decisions;
- produce explicit change candidates;
- verify candidates before applying;
- auto-apply only minor safe changes;
- escalate major or unclear changes.

### 8. Hypothesis generation

Runs on a project-stage-dependent schedule or when new data appears.

Inputs may include analytics, bug reports, user/team feedback, release results, and product observations.

Hypotheses are stored in backlog for later scoring and filtering. Junk accumulation is expected but must be controlled by backlog hygiene.

### 9. Backlog prioritization and execution loop

Runs when Junie is idle or on a configurable schedule.

Responsibilities:

- score checked/valid backlog items;
- account for active GitHub PRs and Telegram context;
- mark tasks already in progress by teammates, including elapsed time;
- suggest help if teammate progress appears slow;
- respect approval/clarification/mutex gates;
- run code mutex status check before starting queued code work;
- start the highest-value eligible task when idle.

A user/team request may optionally have configured preemption power to pause or cancel current work to reduce human waiting time.

### 10. Backlog hygiene

Runs on a configurable schedule.

Responsibilities:

- deduplicate tasks and hypotheses;
- rescore after new evidence (use `scripts/backlog-rescore.sh` for age-based prioritization);
- merge related items;
- archive stale, invalidated, or low-value items;
- keep execution queue understandable.

### 11. Self-simplification

Runs less frequently than normal reflection, usually scheduled or threshold-triggered.

Responsibilities:

- reduce accumulated complexity;
- identify unused or low-value docs, skills, routines, and utilities;
- propose simplifying changes;
- use available task history and file/routine evidence;
- never edit `MEMORY.md` directly, only propose changes if needed.

### 12. Routine health check

Runs on a lightweight configurable schedule.

Responsibilities:

- detect stuck routines;
- detect stale queues;
- detect overdue approvals;
- detect blocked PRs;
- detect dead execution loops;
- surface stale held mutexes to the code mutex status check.

Repeated tool/skill failure analysis is out of scope for the MVP unless it is visible in normal task artifacts.

## Deferred subsystem

### Capability usage analytics — v2, out of MVP scope

Capability usage analytics is intentionally left for the next version.

In v2, this subsystem may collect factual operational telemetry such as skill usage, MCP/tooling usage, documentation reads, failures, retries, routine outputs, and other usefulness signals. That data can later support task-completion reflection, self-simplification, and future skill/tooling decisions.

For the MVP, Junie should not depend on this analytics layer. Reflection and simplification should use ordinary task artifacts, PR/review history, logs explicitly produced by task runners, and direct inspection instead.

## Minor vs major changes

### Minor changes

Can be auto-applied after local check:

- typos, formatting, broken links;
- factual references to existing docs;
- routine timestamps/status fields;
- task states such as queued, blocked, in progress, done;
- daily memory notes;
- self-improvement observations that do not change behavior;
- small clarifications that do not alter meaning;
- generated analytics/log updates.

### Major changes

Require explicit approval:

- any semantic `MEMORY.md` change;
- strategy, goal, priority, or hypothesis scoring policy;
- architecture or accepted design choice;
- task validation/challenge protocol;
- delegation/review protocol, including the rule that all coding work is delegated to opencode powered by Claude Opus 4.6 with low reasoning, with the explicit exception that Markdown-only documentation/guidance edits may be made directly by the orchestrator;
- skill behavior or new skill that changes how Junie acts;
- MCP/tooling addition that expands capabilities or external access;
- deployment/release process;
- Telegram/team communication policy;
- anything that changes product behavior, team workflow, or agent authority.

If unsure, treat the change as major or create a change candidate and ask.

Autonomous windows retry verification failures up to 7 fixes, then block, release mutex, preserve diff/status, and clean failed workspace. Hard timeout default: 7200s.

## Autonomous window local failures

Use `scripts/start-autonomous-window.sh` for admin work windows. It continues after safe local task failures by default (`--continue-on-local-failure --max-local-failures 3`), blocking and cleaning the failed task before selecting the next one. Stop and inspect state/logs if the controller reports `cleanup_failed` or `too_many_local_failures`.


## Repo Root Hygiene

Do not run OpenClaw workspace bootstrap with this git repo as the workspace. Root files such as `AGENTS.md`, `SOUL.md`, `TOOLS.md`, `USER.md`, `HEARTBEAT.md`, `IDENTITY.md`, `.openclaw/`, and `state/` are runtime/workspace artifacts here and must be prevented or cleaned, not hidden with `.gitignore` or `.git/info/exclude`. Use `scripts/check-repo-hygiene.sh` or `scripts/verify.sh` before accepting autonomous work.

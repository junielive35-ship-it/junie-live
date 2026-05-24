# Overnight Routines Contract

This contract defines the stable behavior Junie Live provides for bounded autonomous work windows and the safety cron that monitors them.

## Out-of-box goal

An administrator should be able to say, conceptually, “work overnight on backlog filling and top task execution” immediately after initialization. Junie must not require the administrator to manually inspect mutex state, check for stuck workers, or remember which maintenance scripts to run. The routines coordinate those checks and report the result.

## Cron roles

The overnight setup is split into three cron-backed roles:

1. **Controller** — starts the overnight work window, fills or refreshes the backlog, selects eligible top-priority work, delegates implementation through `scripts/run-backlog-worker.sh`, verifies gates, releases/updates task and mutex state, and writes durable state as it progresses.
2. **Watchdog** — runs independently during and after the controller window to detect stuck agents, stale opencode workers, stale mutex holders, missing progress, and broken routine state. It may stop a stuck worker, preserve logs, mark work blocked, and release or transfer the mutex only according to the mutex contract.
3. **Morning report** — summarizes what happened overnight: work attempted, backlog changes, commits/PRs, verification results, blockers, cleanup actions, and recommended next decisions.

These roles are implemented locally by:

- `scripts/start-autonomous-window.sh` — admin-facing wrapper for bounded natural-language autonomous work windows;
- `scripts/overnight-controller.sh`
- `scripts/overnight-watchdog.sh`
- `scripts/overnight-report.sh`

They are intentionally plain shell scripts so scheduled jobs and Telegram-triggered admin work windows can run without an interactive terminal. `hire-junie.sh` now creates the OpenClaw agent first, then calls `scripts/install-overnight-crons.sh`, so every newly hired Junie instance receives workspace-local audit/fallback artifacts and an enabled watchdog cron out of the box:

- `.openclaw/cron/overnight-routines.json` — structured job definitions for the controller, watchdog, and morning report;
- `.openclaw/cron/overnight-routines.crontab` — equivalent host-cron lines for administrators/installers that use system cron.

The helper installs/updates OpenClaw cron jobs using stable `Junie Live overnight ...` names, removing only matching Junie Live jobs for the same agent before re-adding them. By default it installs the watchdog enabled, while the controller and morning-report jobs are installed disabled and remain audit/fallback definitions. Scheduled morning reports are deprecated by default; use `--enable-controller` only after explicit administrator approval and a non-`main` target branch are configured. Use `--enable-morning-report` only if a scheduled report is explicitly wanted. Use `--no-overnight-crons`, `--overnight-artifacts-only`, or `--overnight-disabled` to opt out, generate fallback artifacts only, or disable all jobs.

## Admin-triggered autonomous windows

After initialization, an administrator can ask in Telegram for bounded autonomous work with natural language such as “start autonomous loop for 4h”, “поработай автономно 9 часов”, or “работай над проектом до утра”. Junie should treat this as an operational autonomous-work request, not as a request for the admin to provide repo, backlog, mutex, opencode, verification, commit, or morning-report details.

Junie resolves the duration/end time from the message, asks one concise question only when that bound is missing or ambiguous, validates initialization/repo/mutex context, and starts `scripts/start-autonomous-window.sh --duration ... --background` with explicit workspace-local state. If preflight is unsafe, it reports the blocker and points to the preflight state/log file. This on-demand window uses the same controller/watchdog/report contract as scheduled overnight work, but it is manually triggered and bounded by the admin's requested duration rather than a scheduled cron start. The wrapper defaults to a multi-iteration controller limit for admin windows, so a request such as `/skill autonomous-work-window 9h` can keep selecting and completing backlog items until the time bound, max iterations, or a blocker stops it.

## Expected state and log files

Routine state must live under the initialized OpenClaw workspace, not in the repository root. Expected state includes:

- `.openclaw/state/code_mutex/holder.json` for the code-change mutex holder summary;
- routine run state such as controller run id, start/end timestamps, selected task id, worker id/session id, current phase, and expected next action;
- backlog item state for queued, in-progress, blocked, done, and archived items;
- watchdog findings and cleanup decisions;
- morning report artifacts or links.

Logs should be durable enough to debug a failed overnight run and should include command invocations, worker/session identifiers, verification output, commit hashes, PR links when present, timeout reasons, and cleanup actions. Logs and state are operational artifacts of the initialized workspace, not source files in the Junie Live repo. Generated cron definitions explicitly set the repository path, workspace state directory, logs directory, target branch, timeout values, and non-interactive environment. Commands use `/usr/bin/env bash` from a predictable repo cwd and write reports/logs to workspace-local paths instead of relying on an interactive terminal.

The scripts default runtime state to `${JUNIE_WORKSPACE:-$HOME/.openclaw/workspace-junie-live}/.openclaw/state/...` and accept explicit env/CLI overrides such as `--state-dir`/`OVERNIGHT_STATE_DIR`, `BACKLOG_DIR`, `MUTEX_DIR`, `REFLECTIONS_DIR`, and `HYPOTHESIS_STATE_DIR` for tests or alternate initialized workspaces. Installed definitions use the initialized workspace's `.openclaw/state/overnight` and `.openclaw/logs/overnight` paths explicitly; no script should default operational state to the repo root.

## Stuck detection requirements

The watchdog must be able to identify at least these stuck states:

- code mutex held past a configured stale threshold without recent `updated_at` progress;
- worker/opencode session alive but producing no useful progress for a configured interval;
- worker exited or disappeared while the mutex still appears held;
- controller state says work is running but no matching worker/session exists;
- repeated verification failure with no changed retry plan;
- backlog item stuck `in_progress` without an active owner;
- morning report missing after an overnight run should have ended.

Detection must prefer concrete evidence: mutex metadata, routine state, process/session status, logs, git status, commits, PR status, and verification output.

## Timeout, cleanup, and mutex behavior

The controller must check the code-change mutex before starting code-changing work. If the mutex is held, the controller records the holder summary and either waits, skips code work, or follows an administrator-approved override policy. It must not rely on manual mutex checks by the administrator.

Every delegated worker must have explicit timeouts and an expected next action. `scripts/run-backlog-worker.sh` is the opencode-compatible worker boundary: it writes prompts/logs under workspace state, accepts `AUTONOMOUS_WORKER_CMD`/`--worker-cmd-template` for noninteractive workers, passes backlog item context, and blocks explicitly if no worker command/opencode CLI is available. Without a custom worker command, the default is the supported `opencode run --model "$AUTONOMOUS_OPENCODE_MODEL" --variant "$AUTONOMOUS_OPENCODE_VARIANT" --agent "$AUTONOMOUS_OPENCODE_AGENT" "$(cat "$AUTONOMOUS_PROMPT_FILE")"` shape; defaults are `AUTONOMOUS_OPENCODE_MODEL=anthropic/claude-opus-4-6`, `AUTONOMOUS_OPENCODE_VARIANT=low`, and `AUTONOMOUS_OPENCODE_AGENT=build`. Cron environments may have a minimal `PATH`, so default opencode discovery first honors `AUTONOMOUS_OPENCODE_BIN`, then `command -v opencode`, then executable `$HOME/.opencode/bin/opencode` before blocking clearly. Do not use unsupported opencode flags such as `--prompt-file`. On timeout or stuck detection, the watchdog must:

1. preserve relevant logs and state;
2. stop or mark the worker/session as cancelled when safe;
3. inspect git state before cleanup;
4. avoid destructive cleanup of uncommitted work unless the policy explicitly allows it;
5. update the backlog item and routine state with the reason;
6. release or transfer the mutex only after the worker is stopped, blocked, completed, or safely handed off.

Mutex release must be explicit. Broken or stale mutex state must be reported rather than silently ignored.

## Commit and repository hygiene requirements

Autonomous commits must use meaningful subjects that describe the change. Iteration-counter subjects such as `Autonomous MVP loop iteration 7` are rejected as policy because they hide intent from reviewers and future routine reports.

The Junie Live repo must not contain initialized workspace trash or root workspace artifacts such as root `AGENTS.md`, `SOUL.md`, `USER.md`, `TOOLS.md`, `IDENTITY.md`, `HEARTBEAT.md`, root `.openclaw/`, or root `state/`. Those belong in an initialized OpenClaw workspace or in `initialization/` seed files as appropriate. Never run OpenClaw workspace bootstrap with the repository root as the workspace; initialize/use a separate workspace such as `$HOME/.openclaw/workspace-junie-live`.

The repo must also not hide such artifacts with `.git/info/exclude`. Local exclude masking makes verification lie: unwanted workspace trash can remain in the repo while appearing clean. Verification must fail if root workspace artifacts exist or if `.git/info/exclude` masks them.

## Verification and reporting expectations

Each controller run must record the verification commands it ran and their results. For code changes, the minimum expectation is the project verification command plus a git whitespace check, currently:

- `./scripts/verify.sh`
- `git diff --check`

The morning report must include:

- whether the controller, watchdog, and morning report roles ran;
- backlog items created, rescored, selected, completed, blocked, or deferred;
- mutex status transitions and any stale/broken mutex handling;
- worker/session ids and timeouts;
- commits and PRs created or updated;
- verification results;
- cleanup actions;
- unresolved risks and questions.

## Non-goals

- Implementing capability usage analytics; this remains out of scope.
- Requiring project-specific content in `initialization/` seed files.
- Letting cron routines bypass approvals, safety policies, or the code mutex.
- Running multiple code-changing workers in parallel in one repo.
- Hiding generated workspace artifacts through `.git/info/exclude`.
- Defining exact cron times; schedules are project-dependent configuration.

Autonomous verification failures retry through worker boundary up to AUTONOMOUS_FIX_RETRIES/--fix-retries (default 7). Exhaustion blocks the task, releases mutex, preserves status/diff, and cleans workspace. Hard timeout default is 7200s safety net.

## Local failure continuation policy

Admin-triggered autonomous windows default to `--continue-on-local-failure --max-local-failures 3` so one bad backlog task does not waste a long bounded work window. Local failures are worker nonzero exits, worker timeout exits `124`/`137`, and verification failure after the configured fix retry budget is exhausted. For each such failure the controller blocks/releases the current task, runs cleanup while preserving logs, git status, diffs, and untracked artifact names/content, then continues only if cleanup succeeds, the repo is clean, and the local failure budget has not been exceeded. Cleanup failure or remaining dirty state stops immediately with `cleanup_failed`; exceeding the budget stops with `too_many_local_failures`. Final state must keep blocked tasks visible and must not report a failed task as successful merely because the window reached its iteration/time bound afterward.

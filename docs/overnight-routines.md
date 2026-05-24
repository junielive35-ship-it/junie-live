# Overnight Routines Contract

This contract defines the stable out-of-box behavior Junie Live must provide for cron-backed overnight work after a new instance has completed initialization.

## Out-of-box goal

An administrator should be able to say, conceptually, “work overnight on backlog filling and top task execution” immediately after initialization. Junie must not require the administrator to manually inspect mutex state, check for stuck workers, or remember which maintenance scripts to run. The routines coordinate those checks and report the result.

## Cron roles

The overnight setup is split into three cron-backed roles:

1. **Controller** — starts the overnight work window, fills or refreshes the backlog, selects eligible top-priority work, verifies gates, delegates execution, and writes durable state as it progresses.
2. **Watchdog** — runs independently during and after the controller window to detect stuck agents, stale opencode workers, stale mutex holders, missing progress, and broken routine state. It may stop a stuck worker, preserve logs, mark work blocked, and release or transfer the mutex only according to the mutex contract.
3. **Morning report** — summarizes what happened overnight: work attempted, backlog changes, commits/PRs, verification results, blockers, cleanup actions, and recommended next decisions.

These roles are implemented locally by:

- `scripts/overnight-controller.sh`
- `scripts/overnight-watchdog.sh`
- `scripts/overnight-report.sh`

They are intentionally plain shell scripts so scheduled jobs can run without an interactive terminal. `hire-junie.sh` now creates the OpenClaw agent first, then calls `scripts/install-overnight-crons.sh`, so every newly hired Junie instance installs real OpenClaw cron jobs out of the box and also receives local audit/fallback artifacts:

- `.openclaw/cron/overnight-routines.json` — structured job definitions for the controller, watchdog, and morning report;
- `.openclaw/cron/overnight-routines.crontab` — equivalent host-cron lines for administrators/installers that use system cron.

The helper installs/updates OpenClaw cron jobs by default using stable `Junie Live overnight ...` names, removing only matching Junie Live jobs for the same agent before re-adding them. It does not mutate a host crontab, and verification uses dry-run/fake OpenClaw binaries so tests never touch the real cron registry. Schedules and timeouts are configurable from `hire-junie.sh`; use `--no-overnight-crons`, `--overnight-artifacts-only`, or `--overnight-disabled` to opt out, generate fallback artifacts only, or install disabled jobs.

## Expected state and log files

Routine state must live under the initialized OpenClaw workspace, not in the repository root. Expected state includes:

- `.openclaw/state/code_mutex/holder.json` for the code-change mutex holder summary;
- routine run state such as controller run id, start/end timestamps, selected task id, worker id/session id, current phase, and expected next action;
- backlog item state for queued, in-progress, blocked, done, and archived items;
- watchdog findings and cleanup decisions;
- morning report artifacts or links.

Logs should be durable enough to debug a failed overnight run and should include command invocations, worker/session identifiers, verification output, commit hashes, PR links when present, timeout reasons, and cleanup actions. Logs and state are operational artifacts of the initialized workspace, not source files in the Junie Live repo. Generated cron definitions explicitly set the repository path, workspace state directory, logs directory, target branch, timeout values, and non-interactive environment. Commands use `/usr/bin/env bash` from a predictable repo cwd and write reports/logs to workspace-local paths instead of relying on an interactive terminal.

The scripts default to `$HOME/.openclaw/workspace-junie-live/.openclaw/state/overnight` and accept `--state-dir`/`OVERNIGHT_STATE_DIR` for tests or alternate initialized workspaces. Installed definitions use the initialized workspace's `.openclaw/state/overnight` and `.openclaw/logs/overnight` paths explicitly.

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

Every delegated worker must have explicit timeouts and an expected next action. On timeout or stuck detection, the watchdog must:

1. preserve relevant logs and state;
2. stop or mark the worker/session as cancelled when safe;
3. inspect git state before cleanup;
4. avoid destructive cleanup of uncommitted work unless the policy explicitly allows it;
5. update the backlog item and routine state with the reason;
6. release or transfer the mutex only after the worker is stopped, blocked, completed, or safely handed off.

Mutex release must be explicit. Broken or stale mutex state must be reported rather than silently ignored.

## Commit and repository hygiene requirements

Autonomous commits must use meaningful subjects that describe the change. Iteration-counter subjects such as `Autonomous MVP loop iteration 7` are rejected as policy because they hide intent from reviewers and future routine reports.

The Junie Live repo must not contain initialized workspace trash or root workspace artifacts such as root `AGENTS.md`, `SOUL.md`, `USER.md`, `TOOLS.md`, `IDENTITY.md`, `HEARTBEAT.md`, or root `.openclaw/` state. Those belong in an initialized OpenClaw workspace or in `initialization/` seed files as appropriate.

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

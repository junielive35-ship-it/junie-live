# Overnight Routines Contract — Hermes Implementation

This contract defines the stable behavior Junie Live provides for bounded autonomous work windows and safety monitoring, implemented on Hermes.

## Out-of-box goal

An administrator should be able to say "work overnight on backlog items" immediately after initialization. Junie must not require the administrator to manually inspect mutex state, check for stuck workers, or remember which commands to run.

## Cron roles

### 1. Watchdog

Runs every 15 minutes via Hermes cron. Independently monitors:

- Code mutex held past stale threshold without recent progress
- Stuck backlog items (in_progress without active owner)
- Missing expected progress from overnight work
- Broken routine state

If issues are found, reports to the owner via Telegram.

### 2. Controller

Starts a bounded autonomous work window. Can be triggered by:

- Admin message in Telegram ("work autonomously for 9 hours")
- Hermes cron (scheduled overnight work, disabled by default)
- Manual `hermes -p junie-live chat -q '...'` invocation

The controller:
1. Selects the highest-priority eligible backlog item
2. Acquires the code mutex
3. Delegates implementation via `marinator_delegate` (`delegate_task` is for non-code subtasks only)
4. Reviews and verifies the result
5. Commits verified work / blocks failed work
6. Releases mutex and selects next item
7. Repeats until time bound, max iterations, or blocker

### 3. Morning report

Summarizes what happened overnight:
- Work attempted, completed, blocked, deferred
- Commits and PRs created/updated
- Verification results
- Blockers and recommended next decisions
- Mutex state transitions

Delivered via Telegram.

## Admin-triggered autonomous windows

After initialization, the admin can request bounded autonomous work via Telegram:

- "start autonomous loop for 4h"
- "поработай автономно 9 часов"
- "работай над проектом до утра"

Junie resolves the duration/end time, validates context, and starts work. The admin does not need to specify internal details.

## Implementation via Hermes cron

Instead of shell crontab entries, Junie creates Hermes cron jobs:

```python
# Watchdog
cronjob(action="create", name="junie-watchdog", schedule="*/15 * * * *",
        prompt="...", deliver="telegram")

# For admin-triggered work windows
cronjob(action="create", name="junie-autonomous-window",
        schedule="<computed-end-time>",
        prompt="...", skills=["junie-autonomous-work-window"],
        deliver="telegram")
```

For ad-hoc work windows, the orchestrator may also use a spawned background process:

```python
terminal(command="hermes -p junie-live chat -q '<autonomous work prompt>'",
         background=true, notify_on_complete=true)
```

## Verification failure handling

Verification failures get up to 7 fix attempts. Each retry delegates the fix back to a subagent with the verification failure context. If all retries fail:
1. Block the current task
2. Release the code mutex
3. Preserve diff/status/logs
4. Continue to next backlog item (if within failure budget)

## Local failure continuation

Default policy: continue after up to 3 safe local task failures. A local failure is:
- Worker nonzero exit
- Worker timeout
- Verification failure after fix retry budget exhausted

For each failure: block the task, release mutex, clean workspace, continue. Stop on cleanup failure or exceeding the failure budget.

## Commit and repository hygiene

- Commit subjects must describe the actual change (no generic iteration counters)
- Target repo must not contain Hermes runtime artifacts (this is already handled by Hermes storing state under `~/.hermes/`)
- Final git status should be clean or list only intentional changes

## Non-goals

- Capability usage analytics (deferred to v2)
- Requiring project-specific content in seed files
- Bypassing approvals, safety policies, or the code mutex
- Running multiple code-changing workers in parallel
- Defining exact cron times (schedules are project-dependent)

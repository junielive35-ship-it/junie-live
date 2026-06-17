# Overnight Routines Contract — Hermes Implementation

This contract defines the stable behavior Junie Live provides for bounded autonomous work windows and safety monitoring, implemented on Hermes.

## Out-of-box goal

An administrator should be able to say "work overnight on backlog items" immediately after initialization. Junie must not require the administrator to manually inspect Kanban state, mutex state for legacy/manual paths, stuck workers, or remember which commands to run.

## Cron roles

### 1. Watchdog

When explicitly approved and enabled, runs every 15 minutes via Hermes cron.
Setup does not install it by default. It independently monitors:

- Senior Dev Kanban tasks stuck in `ready`/`running`/`blocked` without clear recent progress or comments
- Code mutex held past stale threshold without recent progress on legacy/manual protected paths
- Stuck backlog items (in_progress without active owner)
- Missing expected progress from overnight work
- Broken routine state

If issues are found, reports to the owner via Telegram.

### 2. Controller

Starts a bounded autonomous work window. Can be triggered by:

- Admin message in Telegram ("work autonomously for 9 hours")
- Hermes cron (scheduled overnight work, optional and disabled by default)
- Manual `hermes -p junie-live chat -q '...'` invocation

The controller:
1. Selects the highest-priority eligible backlog item
2. Checks active Senior Dev Kanban tasks for the target repo/origin
3. Delegates implementation via `create_senior_task` to the `senior-dev` Kanban lane (`delegate_task` is for non-code subtasks only), or attaches/requeues a related active task
4. Reviews and verifies the `blocked(review-required)` result or handles `needs-input` / `failed` truthfully
5. Commits verified work / blocks failed work
6. Selects the next safe item only after the active Kanban handoff is resolved or explicitly deferred
7. Repeats until time bound, max iterations, or blocker

The legacy code mutex is consulted only for routines that mutate the repo outside this Senior Kanban path.

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

## Implementation

Instead of shell crontab entries or ad-hoc background processes, Junie uses the
Senior Dev Kanban lane for code-changing work: inspect `senior_active_tasks`,
create or update one `create_senior_task`, and rely on the `senior-dev` worker's
`senior_run_coding_task` artifacts plus terminal Kanban block reason for handoff.
Progress visibility is observability, not acceptance. It does not replace backlog
outcomes, final reports, orchestrator review, verification evidence, or git
status checks.

Cron is not the primary control plane. Owner/admin-requested work windows are the
default. Hermes cron may be used only after explicit owner/admin decision for:
- **Watchdog** (optional, every 15 min): independently monitors active Senior Dev Kanban tasks, stuck items, and routine health. Reports to the owner.
- **Scheduled overnight start** (optional, deferred): a cron job that starts the approved routine at a specific time.

Hook-style:

```python
cronjob(action="create", name="junie-watchdog", schedule="*/15 * * * *",
        prompt="Read state, check Senior Dev Kanban tasks and stuck items, report issues.",
        deliver="telegram")
```

## Verification failure handling

Verification failures are handled by the orchestrator's judgment, not by a hard-coded retry count. Each rejected `review-required` result may be followed by a comment plus unblock/requeue of the same Senior task with the verification failure context, or the orchestrator may restructure, wait, kill, or block based on evidence, risk, and the requested user outcome.

If the task remains blocked:
1. Leave the Kanban task blocked with evidence and gaps (`review-required`, `needs-input`, or `failed`)
2. Preserve diff/status/logs and artifact paths in comments or the final report
3. Continue to the next backlog item only if doing so is safe within the approved work window

## Local failure continuation

Default policy: continue after up to 3 safe local task failures. A local failure is:
- Worker nonzero exit
- Worker timeout
- Verification failure after fix retry budget exhausted

For each failure: block or keep blocked with evidence, preserve artifacts, clean workspace if safe, and continue only when that will not bypass review or create duplicate active code work. Release the legacy/manual mutex only if one was actually acquired. Stop on cleanup failure or exceeding the failure budget.

## Commit and repository hygiene

- Commit subjects must describe the actual change (no generic iteration counters)
- Target repo must not contain Hermes runtime artifacts (this is already handled by Hermes storing state under `~/.hermes/`)
- Final git status should be clean or list only intentional changes

## Non-goals

- Capability usage analytics (deferred to v2)
- Requiring project-specific content in seed files
- Bypassing approvals, safety policies, or the Senior Dev Kanban lane
- Running multiple code-changing workers in parallel for the same repo
- Defining exact cron times (schedules are project-dependent)

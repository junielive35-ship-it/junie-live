# Junie Live Day-to-Day Routines — Hermes Implementation

Telegram is the primary incoming event source. Junie communicates with the team via Telegram (Hermes gateway), accesses code via terminal/file tools, and manages PRs via git/gh.

## Core runtime principles

- Junie acts like a senior developer/product owner, not a passive executor.
- Meaningful work is validated against memory (strategic context) and relevant docs.
- The **Marinator** is Junie Live's task-solving loop: validate/decompose a task, delegate to an executor, check the result, request fixes when needed, verify, accept/report, and reflect. In the current Hermes baseline this is a protocol across memory, skills, docs, and agent behavior, not a separate architectural module.
- Normal Chat Agent code-changing work uses the Senior Dev Kanban lane as the active p1 concurrency boundary. The legacy/profile-local code mutex still exists for protected routines outside that lane.
- The orchestrator never writes code directly. Normal code-changing work is delegated via `senior_active_tasks` / `create_senior_task` to the `senior-dev` Kanban lane; `delegate_task` is for non-code subtasks (research, analysis, reading).
- Markdown-only doc edits are the exception.
- Memory stays compact — strategic compass only. Details in docs.
- Schedules are project-dependent.

## Event-triggered routines

### 1. Telegram intake

Triggered by DM or mention via Hermes gateway.

Flow:
1. Classify the message: question, task, bug, feature, decision, FYI.
2. Load relevant skills automatically (task-intake-validation matches).
3. Retrieve strategic context from memory.
4. Read relevant docs if needed.
5. Validate against strategy, architecture, decisions.
6. Challenge contradictions.
7. Confirm understanding for non-trivial tasks.
8. Queue, execute, defer, or ask for approval.

For proactive work-window requests ("work autonomously for 9h"), use initialized context to select work and route code-changing implementation through the Senior Dev Kanban lane.

### 2. Code task execution

Triggered when an accepted code-changing task is ready. This routine is the current code-changing path through the Marinator loop. In p1, Kanban is the active concurrency and handoff boundary; do not acquire the legacy code mutex for ordinary `create_senior_task` routing.

Flow:
1. Inspect repo status and call `senior_active_tasks` for the target repo/origin (include comments when deciding follow-up routing).
2. Decompose task (coding-task-decomposition skill).
3. If no related active task exists, delegate via `create_senior_task` with scoped context; for non-code subtasks (research, analysis) use `delegate_task` instead.
4. If a related task is `ready`/`running`, attach context as a comment and tell the user it was attached. Do not live-interrupt the running Senior in p1.
5. If a related task is `blocked`, read the reason/comments. For `review-required`, Junie reviews artifacts/diff/tests; for answered follow-ups or fix requests, add a comment and unblock/requeue instead of creating a duplicate.
6. Senior Dev runs `senior_run_coding_task` synchronously, comments artifacts/summary, and blocks as `review-required`, `needs-input`, or `failed`.
7. Review results (implementation-review skill). Request fixes by commenting/requeueing the same active task when appropriate.
8. Commit verified work / open PR only after Junie acceptance.

Use the profile-local mutex only for exceptional legacy/manual protected routines outside this Senior Kanban path.

### 3. Task completion → reflection

After each valuable task, the task-reflection skill triggers.

Responsibilities:
- Identify generalizable improvements
- Update memory with lessons learned
- Patch skills when issues are found
- Propose major changes for approval

### 4. Pull request lifecycle

Track CI status, respond to reviews, delegate fixes, detect stale PRs, communicate blockers, update backlog state.

## Optional scheduled routines (via Hermes cron)

Setup does not install these routines by default. Create them only after explicit
owner/admin decision, using Hermes cron rather than shell crontab entries.

### 5. Watchdog (optional, every 15 minutes)

Checks:
- Active Senior Dev Kanban tasks stuck in `ready`/`running`/`blocked` without clear comments or progress
- Code mutex state for legacy/manual protected routines (stale holders)
- Stuck backlog items
- Missing progress from active work
- Broken routine state

### 6. Health check (optional, daily)

Reports:
- Backlog summary (queued, in-progress, blocked)
- Open PRs and CI status
- Pending decisions/approvals
- Blocked work items

### 7. MD consistency scan

Detects contradictions between:
- Strategy and implementation
- Docs and code
- Memory and docs
- Skills and current workflow

### 8. Backlog management

Maintains the backlog:
- Score/rescore items
- Deduplicate and merge related items
- Archive stale items
- Generate hypotheses when backlog is empty

## Minor vs major changes

### Minor (auto-apply)
- Typos, formatting, broken links
- Task state updates
- Daily notes
- Self-improvement observations

### Major (need approval)
- Strategic memory changes
- Architecture or design decisions
- Delegation/review protocol changes
- Skill behavior changes
- Tooling additions
- Deploy process changes
- Communication policy changes

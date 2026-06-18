# Junie Live Day-to-Day Routines — Hermes Implementation

Telegram is the primary incoming event source. Junie communicates with the team via Telegram (Hermes gateway), accesses code via terminal/file tools, and manages PRs via git/gh.

## Core runtime principles

- Junie acts like a senior developer/product owner, not a passive executor.
- Meaningful work is validated against memory (strategic context) and relevant docs.
- Team Lead validates intake, prepares Senior Dev handoffs, reports final verdicts, and reflects on context/protocol quality.
- Normal Team Lead code-changing work uses the configured headless Senior Dev runtime as the active concurrency and delivery boundary. No separate code-mutex path is active by default in the current Hermes implementation.
- Team Lead never writes code directly. Normal code-changing work is handed off to Senior Dev with repository path, user-visible outcome, acceptance criteria, distilled context, constraints, non-goals, and expected report schema; `delegate_task` is for non-code subtasks (research, analysis, reading).
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

For proactive work-window requests ("work autonomously for 9h"), use initialized context to select work and route code-changing implementation through the Senior Dev handoff runtime.

### 2. Code task execution

Triggered when an accepted code-changing task is ready. This routine is the current code-changing path through the Team Lead → Senior Dev contract. The configured Senior Dev runtime is the active concurrency and handoff boundary; ordinary handoff routing must not acquire or depend on a separate mutex.

Flow:
1. Confirm repository path, requested user-visible outcome, and acceptance criteria.
2. Gather only relevant distilled context from memory, docs, task history, and current repo inspection.
3. If the configured runtime exposes active Senior Dev follow-ups, inspect them before creating a duplicate handoff.
4. Send one Senior Dev handoff with scoped context, constraints, non-goals, required verification, and final report schema.
5. Senior Dev runs headless Junie CLI synchronously and owns implementation, review, verification, and fix loop.
6. Senior Dev returns exactly one final verdict: `done`, `needs-input`, or `failed`.
7. Team Lead passes the verdict through accurately and answers `needs-input` follow-ups or creates clarified handoffs when needed.
8. Commit verified work / open PR only when the Senior Dev verdict and project workflow support it.

If a future exceptional/manual protected path outside the Senior Dev handoff runtime is introduced, it needs an explicit design decision, tests, and docs before use.

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
- Active Senior Dev handoffs stuck without clear comments, final verdicts, or progress
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
- Team Lead/Senior Dev handoff protocol changes
- Skill behavior changes
- Tooling additions
- Deploy process changes
- Communication policy changes

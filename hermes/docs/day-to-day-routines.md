# Junie Live Day-to-Day Routines — Hermes Implementation

Telegram is the primary incoming event source. Junie communicates with the team via Telegram (Hermes gateway), accesses code via terminal/file tools, and manages PRs via git/gh.

## Core runtime principles

- Junie acts like a senior developer/product owner, not a passive executor.
- Meaningful work is validated against memory (strategic context) and relevant docs.
- The **Marinator** is Junie Live's task-solving loop: validate/decompose a task, delegate to an executor, check the result, request fixes when needed, verify, accept/report, and reflect. In the current Hermes baseline this is a protocol across memory, skills, docs, and agent behavior, not a separate architectural module.
- Only one code-changing task may run at a time (code mutex).
- The orchestrator never writes code directly. All coding is delegated via `opencode run` (Claude Opus 4.6, `--variant low`); `delegate_task` is for non-code subtasks (research, analysis, reading).
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

For autonomous work window requests ("work autonomously for 9h"), the autonomous-work-window skill activates automatically.

### 2. Code task execution

Triggered when an accepted code-changing task is ready and mutex is free. This routine is the current code-changing path through the Marinator loop.

Flow:
1. Acquire code mutex via `hermes/scripts/code-mutex.sh acquire`.
2. Decompose task (coding-task-decomposition skill).
3. Delegate via `opencode run` (Claude Opus 4.6, `--variant low`) with scoped context; for non-code subtasks (research, analysis) use `delegate_task` instead.
4. Run subagents sequentially under the mutex.
5. Review results (implementation-review skill).
6. Request fixes from subagents until correct.
7. Commit verified work / open PR.
8. Release mutex via `hermes/scripts/code-mutex.sh release`.

### 3. Task completion → reflection

After each valuable task, the task-reflection skill triggers.

Responsibilities:
- Identify generalizable improvements
- Update memory with lessons learned
- Patch skills when issues are found
- Propose major changes for approval

### 4. Pull request lifecycle

Track CI status, respond to reviews, delegate fixes, detect stale PRs, communicate blockers, update backlog state.

## Scheduled routines (via Hermes cron)

### 5. Watchdog (every 15 minutes)

Checks:
- Code mutex state (stale holders)
- Stuck backlog items
- Missing progress from active work
- Broken routine state

### 6. Health check (daily)

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

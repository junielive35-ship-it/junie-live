# Junie Live Day-to-Day Routines

Assumption for v1: Telegram is the only incoming event source. Junie can communicate with the team via Telegram, access GitHub code, and create/update pull requests.

## Core runtime principles

- Junie acts like a senior developer/product owner, not a passive executor.
- Meaningful work is validated against `MEMORY.md`, relevant `docs/`, architecture, strategy, and previous design choices.
- Only one code-changing task may run at a time. A code change mutex protects the repo from parallel conflicting edits.
- Code-changing subagents are run sequentially under the mutex, never in parallel, to avoid branch/worktree conflicts and inconsistent reviews.
- `MEMORY.md` is critical always-on strategy context. It is not automatically compacted. Size checks run only after `MEMORY.md` edits.
- Schedules are project-dependent. “Hourly” or “daily” are configuration choices, not fixed rules.

## Event-triggered routines

### 1. Telegram intake

Triggered by DM, mention, or relevant group-chat request.

Flow:

1. Classify the message: question, task request, bug report, feature request, decision request, FYI/no action.
2. Clarify if needed.
3. For meaningful tasks, retrieve relevant `MEMORY.md` and docs.
4. Validate against strategy, architecture, accepted design choices, and prior decisions.
5. Challenge contradictions instead of blindly accepting the request.
6. Confirm shared understanding for non-trivial tasks.
7. Queue, execute, defer, or ask for approval.

### 2. Code task execution

Triggered when an accepted code-changing task is ready and the code change mutex is free.

Flow:

1. Acquire code change mutex.
2. Decompose task into scoped subagent tasks.
3. Run code-changing subagents sequentially, not in parallel.
4. Give each subagent precise context, constraints, and verification expectations.
5. Review results against the full strategic/architectural context before starting the next code-changing subagent step.
6. Request fixes until the implementation is correct.
7. Open or update a GitHub pull request.
8. Release mutex when the code-changing work is done, blocked, or handed off.

Suggested mutex state:

```yaml
code_mutex:
  status: free | held
  holder_task_id:
  started_at:
  branch:
  pr:
  reason:
```

Queued code tasks should explicitly reference the mutex blocker.

### 3. Pull request lifecycle

Triggered by opened PRs, CI results, review comments, requested changes, merge/close events, or stale PR checks.

Responsibilities:

- track CI status;
- respond to review comments;
- request subagent fixes when needed;
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
- use tool/skill usage analytics as evidence;
- apply minor safe improvements;
- propose major changes for approval.

## Scheduled / continuous routines

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
- rescore after new evidence;
- merge related items;
- archive stale, invalidated, or low-value items;
- keep execution queue understandable.

### 11. Self-simplification

Runs less frequently than normal reflection, usually scheduled or threshold-triggered.

Responsibilities:

- reduce accumulated complexity;
- identify unused or low-value docs, skills, routines, and utilities;
- propose simplifying changes;
- use telemetry from the usage analytics subsystem;
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

Repeated tool/skill failures are not handled here; they belong to the usage analytics subsystem.

## Always-on subsystem

### Tool/skill usage analytics

This is not an agentic routine. It is a telemetry subsystem that constantly records operational data.

It should track:

- tool usage;
- skill usage;
- failures and retries;
- repeated inefficiencies;
- docs read frequency;
- routine outputs and usefulness signals;
- context/token growth indicators where available.

This data is consumed by:

- task-completion reflection (self-improvement);
- self-simplification;
- future skill/tooling decisions.

The subsystem should collect facts. Agentic routines interpret those facts and decide whether changes are useful.

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
- delegation/review protocol;
- skill behavior or new skill that changes how Junie acts;
- MCP/tooling addition that expands capabilities or external access;
- deployment/release process;
- Telegram/team communication policy;
- anything that changes product behavior, team workflow, or agent authority.

If unsure, treat the change as major or create a change candidate and ask.

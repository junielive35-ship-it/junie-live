# Code Mutex

The code mutex is the MVP coordination mechanism that prevents multiple Junie Live routines from changing the same repository at the same time.

It protects the whole code-changing routine, not only a single opencode execution. A routine may include intake, planning, opencode delegation, review, fix requests, tests, PR updates, and final handoff. The mutex stays held until that routine reaches a terminal state: done, blocked, cancelled, or explicitly handed off.

## Scope

The mutex applies to code-changing work for one owned repository or feature area.

Protected work includes:

- editing source code, tests, build files, migrations, config, or generated code;
- running opencode workers that may edit the repository;
- review/fix loops where the orchestrator asks opencode for follow-up changes;
- PR update work that changes repository files.

Unprotected work includes read-only analysis, planning, questions, PR/CI inspection, documentation discussion, and other work that does not mutate the repository.

## Concrete MVP implementation

Use an atomic lock directory under the OpenClaw workspace:

```text
.openclaw/state/code_mutex/
  holder.json
```

The directory path is relative to the initialized OpenClaw workspace for the Junie instance, not necessarily this Junie Live product repository.

The existence of `.openclaw/state/code_mutex/` means the mutex is held. Absence means it is free.

Acquire is implemented by creating the directory atomically:

```bash
mkdir .openclaw/state/code_mutex
```

`mkdir` is the mutex operation. It succeeds for exactly one worker when the directory does not already exist. JSON is only metadata; it does not provide atomicity.

After successful acquisition, write `.openclaw/state/code_mutex/holder.json` with human-readable state.

Example:

```json
{
  "holder_id": "telegram:400847234:message-356",
  "holder_kind": "telegram_intake",
  "task_id": "task-123",
  "session_key": "agent:main:telegram:400847234",
  "repo": "/path/to/project",
  "branch": "junie/task-123",
  "pr": null,
  "reason": "Implement accepted onboarding fix",
  "started_at": "2026-05-23T17:30:00Z",
  "updated_at": "2026-05-23T17:45:00Z",
  "expected_next_action": "review opencode changes and request fixes if needed"
}
```

## Acquire flow

1. Before any code-changing routine starts, inspect repo status and try to create `.openclaw/state/code_mutex/`.
2. If `mkdir` succeeds:
   - the caller owns the mutex;
   - write `holder.json` immediately;
   - proceed with the code-changing routine;
   - keep `holder.json` reasonably current during long work.
3. If `mkdir` fails because the directory already exists:
   - treat the mutex as held;
   - read `holder.json` if present;
   - do not start code-changing work;
   - ask the appropriate human what to do.

## Held mutex behavior

If a cron/scheduled job hits a held mutex, message the configured administrator/owner and ask whether to wait, abort, or override.

If a Telegram intake request hits a held mutex, message the caller with the same choice, including a short summary of the current holder when available.

Suggested wording:

```text
Code mutex is currently held by <holder/reason> since <started_at>.
I should not start another code-changing routine in parallel.
Should I wait, abort this request, or should an owner override the mutex?
```

For MVP, do not auto-queue behind the mutex. Human-directed wait/abort/override is enough.

## Release flow

Release the mutex only when the protected routine is done, blocked, cancelled, or explicitly handed off.

Before releasing, verify that the current routine is the holder described by `holder.json`. Do not delete a mutex held by another task unless the owner explicitly approves an override.

Release by deleting the lock directory:

```bash
rm -r .openclaw/state/code_mutex
```

Prefer a safe deletion path in implementation code: verify holder identity first, then remove the directory. Use normal caution around destructive shell commands.

## Stale or broken mutex

A mutex can become stale if a worker crashes or a routine is abandoned.

Status checks should inspect:

- `started_at` and `updated_at`;
- current worker/session/task status;
- repo branch and PR state;
- whether there is recent useful progress;
- expected next action.

If the holder appears stale or broken, do not silently steal the mutex. Ask the owner/administrator whether to cancel, preserve state, and override.

## Non-goals for MVP

The MVP intentionally does not include:

- automatic FIFO queueing;
- append-only mutex logs;
- priority or preemption policy;
- cross-machine distributed locking;
- automatic stale lock stealing;
- parallel isolated worktree strategy.

Those can be added later if Junie Live needs more throughput or less human intervention.

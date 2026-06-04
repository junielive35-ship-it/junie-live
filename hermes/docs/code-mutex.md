# Code Mutex — Hermes Implementation

The code mutex is the MVP coordination mechanism that prevents multiple Junie Live routines from changing the same repository or owned feature area at the same time.

It protects the whole code-changing routine, not only a single coding-worker execution. A routine may include intake, planning, `marinator_delegate` delegation, worker-result review, fix requests, tests, PR updates, commits, and final handoff. The mutex stays held until that routine reaches a terminal state: done, blocked, failed, cancelled, or explicitly handed off.

## Scope

The mutex applies to code-changing work for one owned repository or feature area.

Protected work includes:

- editing source code, tests, build files, migrations, config, generated code, or scripts;
- running `marinator_delegate` workers that may edit the repository;
- review/fix loops where the orchestrator asks a coding worker for follow-up changes;
- PR update work that changes repository files;
- autonomous-window or scheduled work that may mutate the repository.

Unprotected work includes read-only analysis, planning, questions, PR/CI inspection, documentation discussion, and other work that does not mutate the repository. Markdown-only documentation edits are a Junie Live direct-edit exception, but they still require normal repo hygiene and explicit scope awareness.

## Concrete MVP implementation

Use an atomic lock directory under the Hermes profile-local Junie state directory:

```text
~/.hermes/profiles/junie-live/junie-live/state/code_mutex/
  holder.json
```

The concrete profile path may differ by profile name and Hermes home. Resolve it through `$HERMES_HOME` or the installed profile scripts rather than constructing it from `$HOME`, because Hermes profile sessions may rewrite `$HOME` to a profile-scoped home directory.

The existence of the `code_mutex/` directory means the mutex is held. Absence means it is free.

Acquire is implemented by creating the directory atomically:

```bash
mkdir ~/.hermes/profiles/junie-live/junie-live/state/code_mutex
```

`mkdir` is the mutex operation. It succeeds for exactly one worker when the directory does not already exist. JSON is only metadata; it does not provide atomicity.

After successful acquisition, write `holder.json` with human-readable state.

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
  "expected_next_action": "review Marinator changes and request fixes if needed"
}
```

## Implementation

The mutex logic lives in the shared `junie_runtime` Python package (`hermes/junie_runtime/src/junie_runtime/mutex.py`), which is the single source of truth. The `code-mutex.sh` shell script is a thin compatibility wrapper around `python -m junie_runtime.cli.mutex`; it contains no mutex logic itself.

The runtime package must be installed into the Hermes Python environment:

```bash
python3 -m pip install -e /path/to/junie-live/hermes/junie_runtime
```

## Installed command interface

The reusable seed ships the wrapper as `hermes/initialization/scripts/code-mutex.sh`. During hire, the script is installed into the profile and should be invoked from there:

```bash
~/.hermes/profiles/junie-live/scripts/code-mutex.sh status
~/.hermes/profiles/junie-live/scripts/code-mutex.sh acquire --holder ID --reason TEXT [--repo DIR]
~/.hermes/profiles/junie-live/scripts/code-mutex.sh release [--holder ID] [--force]
~/.hermes/profiles/junie-live/scripts/code-mutex.sh check-stale [--stale-minutes N] [--auto-recover]
```

Use the profile-local script instead of ad hoc shell snippets whenever possible. It centralizes path resolution, holder metadata, stale detection, and release checks. Note that the script delegates entirely to the Python runtime package, so `junie_runtime` must be importable.

Status states:

- `FREE` — lock directory absent.
- `HELD` — lock directory and readable holder metadata exist.
- `STALE` — holder metadata exists but the lock appears old enough to require owner review.
- `BROKEN` — lock directory exists but metadata is missing or unreadable.

## Acquire flow

1. Before any code-changing routine starts, inspect repo status and branch.
2. Verify the branch is not `main` unless the owner explicitly authorized direct main work.
3. Check or acquire the mutex with the profile-local `code-mutex.sh`.
4. If acquire succeeds:
   - the caller owns the mutex;
   - write or confirm `holder.json` immediately;
   - proceed with the code-changing routine;
   - keep metadata reasonably current during long work when the script supports updates.
5. If acquire fails because the directory already exists:
   - treat the mutex as held;
   - read holder metadata if present;
   - do not start code-changing work;
   - ask the appropriate human what to do.

## Held mutex behavior

If a cron, autonomous-window, or scheduled job hits a held mutex, message the configured administrator/owner and ask whether to wait, abort, or override.

If a Telegram intake request hits a held mutex, message the caller with the same choice, including a short summary of the current holder when available.

Suggested wording:

```text
Code mutex is currently held by <holder/reason> since <started_at>.
I should not start another code-changing routine in parallel.
Should I wait, abort this request, or should an owner override the mutex?
```

For MVP, do not auto-queue behind the mutex. Human-directed wait/abort/override is enough unless a later approved design adds queueing.

## Release flow

Release the mutex only when the protected routine is done, blocked, failed, cancelled, or explicitly handed off.

Before releasing, verify that the current routine is the holder described by `holder.json`. Do not delete a mutex held by another task unless the owner explicitly approves an override.

Preferred release:

```bash
~/.hermes/profiles/junie-live/scripts/code-mutex.sh release --holder <holder_id>
```

Manual release by deleting the directory is an emergency/debug fallback only. If used, verify holder identity first, then remove the directory. Use normal caution around destructive shell commands.

## Broken and stale mutex handling

A mutex can become stale if a worker crashes or a routine is abandoned. It can become broken if the lock directory exists but `holder.json` is missing or unreadable.

Status checks should inspect:

- `started_at` and `updated_at`;
- current worker/session/task status;
- repo branch and PR state;
- whether there is recent useful progress;
- expected next action.

If the holder appears stale, do not silently steal the mutex. Ask the owner/administrator whether to cancel, preserve state, and override.

`check-stale --auto-recover` may silently remove only a `BROKEN` mutex where the directory exists but no holder metadata exists. Stale-by-age locks with present holder metadata are not auto-recovered by design: there is someone to ask, and age is evidence rather than authority.

## Relationship to Marinator delegation

All code-changing work must go through `marinator_delegate`. Native Hermes `delegate_task`, direct terminal coding, or ad hoc worker processes are for non-code subtasks only unless a future approved protocol explicitly changes the boundary.

The mutex protects the orchestrator-owned routine, not the worker process alone. The orchestrator must keep holding the lock while it reviews worker output, requests fixes, runs verification, commits, or blocks the task.

## Non-goals for MVP

The MVP intentionally does not include:

- automatic FIFO queueing;
- append-only mutex logs beyond the current holder metadata and surrounding run artifacts;
- priority or preemption policy;
- cross-machine distributed locking;
- automatic stale lock stealing;
- parallel code-changing worktree strategy.

Those can be added later if Junie Live needs more throughput or less human intervention.

## Related

- `code-mutex-protocol.md` in `hermes/initialization/docs/` — seed/profile protocol version installed for hired agents.
- `delegation-protocol.md` — Marinator delegation rules and worker contract.
- `tools.md` — initialized profile operational quick reference for mutex commands and escalation contacts.
- `~/.hermes/profiles/junie-live/scripts/code-mutex.sh` — installed implementation for the active profile.

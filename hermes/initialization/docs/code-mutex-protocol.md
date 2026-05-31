# Code Mutex Protocol

## Purpose

Only one code-changing task runs at a time for the owned repo or area. The mutex prevents branch, worktree, and review conflicts when delegating to OpenCode (via `marinator_delegate`). Hermes Junie Live's mutex is a file-based lock under `~/.hermes/junie-live/state/code_mutex/`, managed by `scripts/code-mutex.sh`.

## Invariants

### 1. The directory IS the lock; holder.json is metadata

Acquiring the mutex is an atomic `mkdir` on the mutex directory. The directory's existence — not the contents of any file inside it — is the lock primitive. The `holder.json` file written inside is descriptive metadata: it records who holds the lock, why, and when it was acquired.

Deleting only `holder.json` does not release the lock. The directory itself must be removed (which `code-mutex.sh release` does correctly). An agent that deletes `holder.json` but leaves the directory has not released the mutex; it has created a `BROKEN` state where the directory exists but the metadata is missing. A `BROKEN` mutex blocks subsequent acquisition until the directory is cleaned up.

### 2. Verify holder identity before releasing or overriding

Before calling `code-mutex.sh release`, the agent must confirm that the recorded `holder_id` in `holder.json` matches its own session or task identifier. The same check applies before any manual force-override (e.g. removing the directory by hand). An agent must not blindly release a lock held by another session — that would defeat the purpose of the mutex.

When the holder_id matches, release is safe. When it does not, the agent must escalate rather than override (see invariant 3).

### 3. If the mutex is held, do not start code-changing work

When the mutex is already held, an agent that wants to start code-changing work must not proceed without an explicit decision from an authorized person.

- For cron or scheduled jobs (overnight batch, autonomous window), ask the configured administrator or project owner whether to wait, abort, or override. Include the current holder summary — `holder_id`, `reason`, `started_at`, and `expected_next_action` — when that information is available from `holder.json`.
- For interactive Telegram intake, ask the caller the same question with the same holder summary.

The escalation contact and conventions for each context are recorded in `tools.md`.

### 4. Code-changing work is sequential under the mutex; no substitutes

All code-changing work must go through `marinator_delegate`. The `delegate_task` mechanism (or any native Hermes subagent path) is for non-code subtasks only — research, analysis, reading, planning — and does not honor the code mutex by design.

Substituting `delegate_task` for `marinator_delegate` to bypass mutex acquisition or to "go faster" silently breaks the sequentiality invariant and can produce concurrent code-changing workers operating on the same repo. This is not allowed.

## Mechanics (quick reference)

- **Mutex directory:** `~/.hermes/junie-live/state/code_mutex/`
- **Holder metadata:** `~/.hermes/junie-live/state/code_mutex/holder.json`
- **Commands** (deployed by `hire-junie.sh` to the profile):
  - `scripts/code-mutex.sh status` — show current state
  - `scripts/code-mutex.sh acquire --holder ID --reason TEXT [--repo DIR]`
  - `scripts/code-mutex.sh release`
  - `scripts/code-mutex.sh check-stale [--stale-minutes N] [--auto-recover]`
- **Status states:** `FREE` / `HELD` / `STALE` / `BROKEN`
- **Auto-recover** (for `check-stale --auto-recover` only): silently removes a `BROKEN` mutex (directory exists, `holder.json` missing). Stale-by-age locks with a present `holder.json` are not auto-recovered by design — they require an owner decision, because the existing holder might still be working; age is evidence, not authority.

## When to consult this doc

- Before acquiring or releasing the mutex.
- When deciding whether to use `marinator_delegate` vs `delegate_task` for a task that involves any code change.
- When triaging a `BROKEN` or `STALE` mutex state.
- When designing an autonomous-window or cron job that may run while another holder is active.

## Related

- `delegation-protocol.md` — Marinator delegation rules and worker contract.
- `tools.md` — operational quick reference for mutex commands and escalation contacts.
- `scripts/code-mutex.sh` — the implementation in the installed profile.

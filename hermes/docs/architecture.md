# Junie Live — Hermes Architecture

## Overview

Junie Live on Hermes uses native Hermes features for orchestration, persistence, communication, and scheduling. The architecture eliminates the need for shell-script orchestration layers and OpenClaw workspace conventions.

Junie Live's named task-solving loop is the **Marinator**: validate/decompose a task, delegate to the executor, check results, request fixes, verify, accept/report, and reflect. In the current Hermes baseline this is a protocol carried by memory, skills, docs, and agent behavior rather than a separate module, and it does not imply parallel code-changing executors.

## Component mapping

```
┌─────────────────────────────────────────────────────────────┐
│                     Hermes Gateway                          │
│                    (Telegram adapter)                        │
└────────────┬────────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────────┐
│              Hermes Profile: junie-live                      │
│                                                              │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌────────────┐  │
│  │ Persona  │  │  Memory  │  │  Skills  │  │  Sessions  │  │
│  │ (SOUL)   │  │(strategy)│  │(protocols│  │  (history)  │  │
│  │          │  │          │  │ & flows) │  │            │  │
│  └──────────┘  └──────────┘  └──────────┘  └────────────┘  │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │           Agent Loop / Marinator                       │   │
│  │  - Receives messages from Telegram                    │   │
│  │  - Loads relevant skills automatically                │   │
│  │  - Consults memory for strategic context              │   │
│  │  - Reads project docs/ when needed                    │   │
│  │  - Delegates coding to subagents                      │   │
│  │  - Reviews and accepts/rejects work                   │   │
│  │  - Updates memory with lessons learned                │   │
│  └───────────┬──────────────────────┬───────────────────┘   │
│              │                      │                        │
│     ┌────────▼──────┐     ┌────────▼──────────┐            │
│     │ delegate_task │     │ Spawned Processes  │            │
│     │ (quick tasks) │     │ (long work)        │            │
│     └───────────────┘     └────────────────────┘            │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              Hermes Cron Scheduler                   │   │
│  │  - Optional watchdog (operator-configured)           │   │
│  │  - Optional health check (operator-configured)       │   │
│  │  - Optional overnight controller (on-demand/default) │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘

                  ┌────────────────────┐
                  │   Target Project   │
                  │   Repository       │
                  │   ~/code/myapp     │
                  └────────────────────┘
                          │
              ┌───────────┼───────────┐
              │           │           │
        ┌─────▼──┐  ┌────▼───┐  ┌───▼────┐
        │  Code  │  │ Tests  │  │  Git   │
        │  Files │  │ CI/CD  │  │ PRs    │
        └────────┘  └────────┘  └────────┘
```

## Key architectural decisions

### 1. Profile isolation

Junie runs as a Hermes profile (`junie-live`), giving it:
- Isolated configuration
- Separate memory stores
- Its own skill set
- Independent session history
- Dedicated .env for API keys

This replaces the OpenClaw workspace concept with something more native.

### 2. SOUL.md (profile-wide) + HERMES.md (target repo)

Hermes has two complementary context-file slots, and Junie Live uses both:

- **`SOUL.md`** lives at `~/.hermes/profiles/junie-live/SOUL.md` and is auto-loaded into slot #1 of the system prompt on **every turn**, regardless of working directory. Junie's `SOUL.md` carries the personality plus the always-on operating safety net: the initialization gate, the no-direct-coding rule, the challenge protocol. This keeps the critical rules active even when Junie is handling a Telegram message outside the target repo or running a cron job without `workdir` set.
- **`HERMES.md`** lives in the **target project repo root** and carries the full project-level operating protocol: detailed delegation rules, code mutex semantics, repo hygiene, change rules, recurring routines. Hermes auto-loads `HERMES.md` (and `.hermes.md`) from the current working directory, walking up to the git root. Junie installs it during initialization by copying `~/.hermes/profiles/junie-live/docs/seed-HERMES.md` to `<target-repo>/HERMES.md`.

Why `HERMES.md` and not `AGENTS.md` for the project-level slot: coding executors invoked by Junie (`opencode`, `codex`, `claude-code`) read `AGENTS.md` / `CLAUDE.md` / `.cursorrules`. They do **not** read `HERMES.md`. Putting the orchestrator-only protocol in `HERMES.md` keeps the executor sessions clean and prevents the orchestrator's challenge/delegation/mutex rules from contaminating coding workers. A target project's own `AGENTS.md` (if any) coexists with `HERMES.md` without conflict.

Approved cron jobs use the `workdir` parameter to set the target repo as cwd, which loads `HERMES.md` automatically. Setup does not install recurring cron jobs by default.

### 3. Memory instead of MEMORY.md

Hermes persistent memory replaces the `MEMORY.md` file:

- **User store**: who the owner is, communication preferences, escalation paths
- **Memory store**: strategic compass, architecture constraints, decisions, project facts

Advantages:
- Always loaded automatically — no need to read a file
- Structured add/replace/remove operations
- Size naturally managed by the memory system
- Searchable via session_search for historical context

### 4. Skills instead of protocol files + workspace hooks

OpenClaw uses protocol docs (`delegation-protocol.md`, `review-protocol.md`) loaded manually. Hermes skills are:
- Auto-loaded when task descriptions match
- First-class citizens with metadata (tags, version)
- Patchable in-session when issues are found
- Managed by the curator for lifecycle

### 5. marinator_delegate plugin instead of opencode scripts

OpenClaw shells out to `opencode run` via bash scripts with complex timeout/retry logic. The Hermes Marinator plugin (`marinator_delegate`) replaces the direct `opencode` invocation with a supervised delegation tool:
- Installed as a Hermes user plugin at `~/.hermes/profiles/junie-live/plugins/marinator-delegation/`
- Registered under the `marinator` toolset, enabled for CLI and Telegram by `hire-junie.sh`
- Creates a durable run directory (`~/.hermes/profiles/junie-live/junie-live/state/marinator/runs/<job_id>/`) with spec, status, events, logs, and result artifacts
- Spawns `marinator-worker.sh` which runs OpenCode in a separate process group with stdout/stderr capture, progress monitoring, stall detection (without auto-kill), and marker line emission
- Live sessions wake via `notify_on_complete=true`; headless sessions continue via `hermes chat --resume`
- The orchestrator reviews results, decides accept/fix/wait/kill/block, and verifies user-visible outcomes
- Per-minute progress reports via Telegram are enabled by default for debug visibility unless the user explicitly disables them; these are observability only, not acceptance or completion signals
- Follow-up/fix loops set `is_follow_up: true`; the plugin resolves the previous OpenCode session internally and keeps raw session ids out of the LLM-facing API

Kanban-backed Marinator and cron-bound session continuation are deferred for the MVP.

### 6. Native cron instead of system crontab

OpenClaw generates crontab entries and OpenClaw cron definitions. Hermes cron:
- Created and managed from within sessions
- Delivery targets (Telegram, local, etc.) built in
- Per-job model/provider/reasoning override
- Script + agent hybrid mode
- No system crontab dependency

### 7. Simplified code mutex

OpenClaw uses an atomic `mkdir` lock directory. The Hermes version uses the same approach:
- Atomic `mkdir` as the lock operation (succeeds for exactly one caller)
- `holder.json` inside the directory for human-readable metadata
- Same conceptual model, same implementation primitive
- Only the default path differs: `~/.hermes/profiles/junie-live/junie-live/state/code_mutex/` instead of `.openclaw/state/code_mutex/`

### 8. Minimal target-repo footprint

OpenClaw can leak workspace artifacts (`AGENTS.md`, `SOUL.md`, `TOOLS.md`, `.openclaw/`, `state/`) into the target repo unless careful hygiene scripts run. The Hermes version installs exactly **one** file in the target repo: `HERMES.md` (the project-level operating protocol). Everything else — `SOUL.md`, memory, skills, profile docs, mutex state, backlog, logs — lives under `~/.hermes/` and never touches the target repo. Whether `HERMES.md` is committed to git or kept in `.gitignore` is a per-project decision; committing it makes the orchestrator protocol part of the project's documented contract, ignoring it keeps the project history Junie-agnostic.

## Data flow

1. **Incoming message** → Hermes Gateway → Profile session
2. **Skill matching** → relevant skills loaded automatically
3. **Memory check** → strategic context available in prompt
4. **Task validation** → intake skill validates against strategy
5. **Marinator execution** → delegate with scoped context, review subagent output, request fixes if needed, and verify the result
6. **Commit** → verified changes committed to target repo
7. **Reflection** → lessons saved to memory/skills/docs
8. **Report** → results delivered via Telegram

## State management

| State | Location | Managed by |
| --- | --- | --- |
| Strategic context | Hermes memory stores | memory tool |
| Session history | `~/.hermes/profiles/junie-live/state.db` | Hermes sessions |
| Detailed docs | Target repo `docs/` or profile `docs/` | File read/write |
| Code mutex | `~/.hermes/profiles/junie-live/junie-live/state/code_mutex/` | `code-mutex.sh` |
| Marinator runs | `~/.hermes/profiles/junie-live/junie-live/state/marinator/runs/` | `marinator_delegate` plugin |
| Consistency state | `~/.hermes/profiles/junie-live/junie-live/state/consistency/` | `consistency_check.py` runner |
| Backlog items | `~/.hermes/profiles/junie-live/junie-live/state/backlog/` | Scripts/cron |
| Operational logs | `~/.hermes/profiles/junie-live/junie-live/state/logs/` | Scripts/cron |
| Skills | `~/.hermes/profiles/junie-live/skills/` | skill_manage |
| Identity (personality + safety-net rules) | `~/.hermes/profiles/junie-live/SOUL.md` | Manual/hire script |
| Project operating protocol | `<target-repo>/HERMES.md` (copied from seed during init) | Manual/Junie during init |

# Junie Live — Hermes Architecture

## Overview

Junie Live on Hermes uses native Hermes features for orchestration, persistence, communication, and scheduling. The architecture eliminates the need for shell-script orchestration layers and OpenClaw workspace conventions.

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
│  │               Agent Loop                              │   │
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
│  │              Hermes Cron Scheduler                     │   │
│  │  - Watchdog (every 15min)                             │   │
│  │  - Health check (daily)                               │   │
│  │  - Overnight controller (on-demand)                   │   │
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

### 2. AGENTS.md in workdir

Hermes auto-loads `AGENTS.md` from the current working directory into the system prompt. The Junie Live `AGENTS.md` seed carries the project-level operating protocol: challenge rules, delegation rules, code mutex conventions, change rules, repo hygiene.

This works the same as OpenClaw's `AGENTS.md` in principle — the difference is that Hermes also has persona (personality), memory (persistent state), and skills (auto-loaded protocols) as separate layers. The `AGENTS.md` doesn't need to carry everything.

Cron jobs use the `workdir` parameter to load `AGENTS.md` from the target repo automatically.

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

### 5. delegate_task instead of opencode scripts

OpenClaw shells out to `opencode run` via bash scripts with complex timeout/retry logic. Hermes provides:
- `delegate_task` for bounded subtasks (isolated context, terminal, tools)
- Spawned `hermes` processes for long-running work
- Hermes cron for scheduled/recurring work

Benefits:
- No shell-script orchestration layer
- Better error handling and reporting
- Subagent summaries returned directly to the orchestrator
- No need for custom worker binaries

### 6. Native cron instead of system crontab

OpenClaw generates crontab entries and OpenClaw cron definitions. Hermes cron:
- Created and managed from within sessions
- Delivery targets (Telegram, local, etc.) built in
- Per-job model/provider override
- Script + agent hybrid mode
- No system crontab dependency

### 7. Simplified code mutex

OpenClaw uses an atomic `mkdir` lock directory. The Hermes version uses the same approach:
- Atomic `mkdir` as the lock operation (succeeds for exactly one caller)
- `holder.json` inside the directory for human-readable metadata
- Same conceptual model, same implementation primitive
- Only the default path differs: `~/.hermes/junie-live/state/code_mutex/` instead of `.openclaw/state/code_mutex/`

### 8. No workspace artifacts to leak

OpenClaw creates runtime artifacts (`AGENTS.md`, `SOUL.md`, `TOOLS.md`, `.openclaw/`, `state/`) that can accidentally end up in the target repo. The Hermes version stores everything under `~/.hermes/` — the target repo is never polluted.

## Data flow

1. **Incoming message** → Hermes Gateway → Profile session
2. **Skill matching** → relevant skills loaded automatically
3. **Memory check** → strategic context available in prompt
4. **Task validation** → intake skill validates against strategy
5. **Delegation** → `delegate_task` with scoped context
6. **Review** → orchestrator reviews subagent output
7. **Commit** → verified changes committed to target repo
8. **Reflection** → lessons saved to memory/skills/docs
9. **Report** → results delivered via Telegram

## State management

| State | Location | Managed by |
| --- | --- | --- |
| Strategic context | Hermes memory stores | memory tool |
| Session history | `~/.hermes/profiles/junie-live/state.db` | Hermes sessions |
| Detailed docs | Target repo `docs/` or profile `docs/` | File read/write |
| Code mutex | `~/.hermes/junie-live/state/code_mutex/` | `code-mutex.sh` |
| Backlog items | `~/.hermes/junie-live/state/backlog/` | Scripts/cron |
| Operational logs | `~/.hermes/junie-live/state/logs/` | Scripts/cron |
| Skills | `~/.hermes/profiles/junie-live/skills/` | skill_manage |
| Persona | `~/.hermes/profiles/junie-live/persona.md` | Manual/hire script |

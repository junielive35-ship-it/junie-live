# Junie Live — Hermes Architecture

## Overview

Junie Live on Hermes uses native Hermes features for orchestration, persistence, communication, and scheduling. The architecture eliminates the need for shell-script orchestration layers and OpenClaw workspace conventions.

Junie Live's named task-solving loop is the **Marinator**: validate/decompose a task, delegate to the executor, check results, request fixes, verify, accept/report, and reflect. In the current Hermes p1 implementation, user-visible code tasks are routed from the Chat Agent into Hermes Kanban as one Senior Dev task. The `senior-dev` profile is a thin synchronous adapter: it runs OpenCode through `senior_run_coding_task`, writes Marinator-style artifacts, comments the result, then decides exactly one terminal Kanban action itself from the artifacts/exit code and the documented status rules — usually leaving the task `blocked` with a substatus (`review-required` by default, or `needs-input`/`failed`) for Junie/origin review. `kanban_complete`/`done` is reserved for genuinely terminal no-review work.

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
│  │  - Routes code work to Senior Dev Kanban tasks        │   │
│  │  - Reports Kanban terminal outcomes to the owner      │   │
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
- **`HERMES.md`** lives in the **target project repo root** and carries the full project-level operating protocol: detailed delegation rules, Senior Dev routing/concurrency semantics, repo hygiene, change rules, recurring routines. Hermes auto-loads `HERMES.md` (and `.hermes.md`) from the current working directory, walking up to the git root. Junie installs it during initialization by copying `~/.hermes/profiles/junie-live/HERMES.seed.md` to `<target-repo>/HERMES.md`.

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

### 5. Senior Dev Kanban lane with synchronous OpenCode p1 runner

Code-changing work now has a Hermes-native active-work lane instead of staying inside the Chat Agent session:
- `senior-task` plugin exposes `create_senior_task` and `senior_active_tasks` for the Chat Agent. `senior_dev_task_result` remains as a legacy async/Marinator reporting helper, but it is not the p1 Senior worker path.
- Before creating a task, the Chat Agent checks active Senior tasks for the same origin/repo and uses semantic judgment to attach follow-ups instead of duplicating.
- `create_senior_task` creates one Hermes Kanban task per user-visible code item and subscribes the originating chat/thread for terminal updates.
- `senior-dev` is a Hermes profile installed from `distribution/profiles/senior-dev/`; it is spawned by the Kanban dispatcher for tasks assigned to `senior-dev`.
- In p1, `senior-dev` calls `senior_run_coding_task` from the `senior-runner` plugin. That tool runs one foreground OpenCode execution, records the exit code and runner state, and returns artifact paths (`run_dir`, `status_path`, `result_path`). It emits no verdict.
- The runner writes Marinator-style artifacts (`spec.json`, `status.json`, `events.jsonl`, `result.md`, stdout/stderr logs, `runner.log`) under the Senior run root. It does not mutate Kanban and does not decide the outcome.
- The `senior-dev` profile reads the artifacts, exit code, and task context, adds a concise `kanban_comment`, and decides exactly one terminal Kanban action itself using the documented status rules: `review-required:` (default for successful code-changing work), `needs-input:` when external user/owner input is required, `failed:` for execution/verification/requested-outcome failure, or `done`/`kanban_complete` only for genuinely terminal no-review work.
- `kanban_complete`/`done` is intentionally rare in p1 and reserved for terminal no-review work. A `blocked(review-required: ...)` task is an awaiting-review handoff, not a failure by default.
- `hire-junie.sh` and `rehire-junie.sh` install/update the companion `senior-dev` profile and required plugins/toolsets so fresh installs and disaster recovery do not leave the pipeline half-working.

### 6. Native cron instead of system crontab

OpenClaw generates crontab entries and OpenClaw cron definitions. Hermes cron:
- Created and managed from within sessions
- Delivery targets (Telegram, local, etc.) built in
- Per-job model/provider/reasoning override
- Script + agent hybrid mode
- No system crontab dependency

### 7. Kanban-first code-work concurrency

For the current p1 Senior Dev lane, Hermes Kanban is the active concurrency boundary for normal Chat Agent code work. The Chat Agent routes code requests to `create_senior_task`; the Senior lane serializes execution and keeps active work visible as `ready`/`running`/`blocked`.

Older docs may mention a separate code mutex for legacy/manual protected paths, but no tracked `junie_runtime` mutex implementation exists in the current Hermes repo state. Docs and skills should route ordinary p1 code work through `create_senior_task`; Kanban is the source of truth for active code-changing work. If a future manual-path mutex is reintroduced, record it as an explicit design decision with tests and a clear bypass-risk story.

### 8. Minimal target-repo footprint

OpenClaw can leak workspace artifacts (`AGENTS.md`, `SOUL.md`, `TOOLS.md`, `.openclaw/`, `state/`) into the target repo unless careful hygiene scripts run. The Hermes version installs exactly **one** file in the target repo: `HERMES.md` (the project-level operating protocol). Everything else — `SOUL.md`, memory, skills, profile docs, mutex state, backlog, logs — lives under `~/.hermes/` and never touches the target repo. Whether `HERMES.md` is committed to git or kept in `.gitignore` is a per-project decision; committing it makes the orchestrator protocol part of the project's documented contract, ignoring it keeps the project history Junie-agnostic.

## Data flow

1. **Incoming message** → Hermes Gateway → Profile session
2. **Skill matching** → relevant skills loaded automatically
3. **Memory check** → strategic context available in prompt
4. **Task validation** → intake skill validates against strategy
5. **Senior Dev dispatch** → create a Kanban task for code work and subscribe the origin chat/thread
6. **Senior execution** → `senior-dev` runs synchronous OpenCode via `senior_run_coding_task` and writes Marinator-style artifacts
7. **Kanban result** → `senior-dev` comments with artifacts/summary, then blocks as `review-required`, `needs-input`, or `failed` for origin notification and Junie review
8. **Reflection/report** → lessons saved to memory/skills/docs; terminal task events notify Telegram

## State management

| State | Location | Managed by |
| --- | --- | --- |
| Strategic context | Hermes memory stores | memory tool |
| Session history | `~/.hermes/profiles/junie-live/state.db` | Hermes sessions |
| Detailed docs | Target repo `docs/` or profile `docs/` | File read/write |
| Senior p1 runs | `~/.hermes/profiles/senior-dev/junie-live/state/senior/runs/` by default, overridable for tests | `senior-runner` plugin |
| Active Senior Dev tasks | Hermes Kanban DB/tasks assigned to `senior-dev` | `senior-task` plugin + Kanban dispatcher |
| Backlog / work-window state | `~/.hermes/profiles/junie-live/junie-live/state/` when used by approved routines | Junie profile / approved routines |
| Operational logs | `~/.hermes/profiles/junie-live/junie-live/state/logs/` plus Hermes profile logs | Hermes / approved routines |
| Skills | `~/.hermes/profiles/junie-live/skills/` | skill_manage |
| Identity (personality + safety-net rules) | `~/.hermes/profiles/junie-live/SOUL.md` | Manual/hire script |
| Project operating protocol | `<target-repo>/HERMES.md` (copied from seed during init) | Manual/Junie during init |

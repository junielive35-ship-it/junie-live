# Junie Live — Hermes Architecture

## Overview

Junie Live on Hermes uses native Hermes features for orchestration, persistence, communication, and scheduling. The architecture eliminates the need for shell-script orchestration layers and OpenClaw workspace conventions.

Junie Live now separates user-facing leadership from delivery. **Team Lead** is the Hermes Agent profile: it validates intake, owns live context, shapes acceptance criteria, prepares handoffs, reports outcomes, and reflects on protocol/context quality. **Senior Dev** is the headless Junie CLI runtime: it owns implementation, review, verification, fix loop, and final verdict end-to-end after handoff. User-visible code tasks are routed from Team Lead into the configured Senior Dev handoff runtime with repository path, user-visible outcome, acceptance criteria, distilled context, constraints, non-goals, and expected report schema.

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
│  │           Team Lead Agent Loop                         │   │
│  │  - Receives messages from Telegram                    │   │
│  │  - Loads relevant skills automatically                │   │
│  │  - Consults memory for strategic context              │   │
│  │  - Reads project docs/ when needed                    │   │
│  │  - Sends code work to headless Senior Dev             │   │
│  │  - Reports Senior Dev final verdicts to the owner     │   │
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
- **`HERMES.md`** lives in the **target project repo root** and carries the full project-level Team Lead operating protocol: detailed handoff rules, Senior Dev routing/concurrency semantics, repo hygiene, change rules, recurring routines. Hermes auto-loads `HERMES.md` (and `.hermes.md`) from the current working directory, walking up to the git root. Junie installs it during initialization by copying `~/.hermes/profiles/junie-live/HERMES.seed.md` to `<target-repo>/HERMES.md`.

Why `HERMES.md` and not `AGENTS.md` for the project-level slot: coding executors and the headless Senior Dev runtime read their own contracts (`AGENTS.md` / `CLAUDE.md` / `.cursorrules` as applicable). They do **not** read `HERMES.md`. Putting Team Lead-only protocol in `HERMES.md` keeps Senior Dev sessions clean and prevents challenge/intake/handoff rules from contaminating coding workers. A target project's own `AGENTS.md` (if any) coexists with `HERMES.md` without conflict.

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

### 5. Senior Dev handoff runtime with synchronous headless Junie CLI runner

Code-changing work has a Hermes-native handoff path instead of staying inside the Team Lead session:
- Team Lead creates one structured Senior Dev handoff per user-visible code item with repository path, outcome, acceptance criteria, distilled context, constraints, non-goals, and expected report schema.
- `senior-task` still exposes compatibility tool names such as `create_senior_task` and `senior_active_tasks` where the current runtime uses Hermes active-work/task state.
- `senior-dev` is a Hermes companion profile installed from `distribution/profiles/senior-dev/`; it adapts configured task/runtime state into a headless Junie CLI request.
- `senior-dev` calls `senior_run_coding_task` from the `senior-runner` plugin. That tool runs one foreground headless Junie CLI execution, records the exit code and runner state, and returns artifact paths (`run_dir`, `status_path`, `result_path`).
- Senior Dev owns implementation, review, verification, fix loop, and final verdict. The final verdict is exactly `done`, `needs-input`, or `failed`; Team Lead passes it through and reflects on context/protocol quality rather than performing hidden second code review.
- `hire-junie.sh` and `rehire-junie.sh` install/update the companion `senior-dev` profile and required plugins/toolsets so fresh installs and disaster recovery do not leave the pipeline half-working.

### 6. Native cron instead of system crontab

OpenClaw generates crontab entries and OpenClaw cron definitions. Hermes cron:
- Created and managed from within sessions
- Delivery targets (Telegram, local, etc.) built in
- Per-job model/provider/reasoning override
- Script + agent hybrid mode
- No system crontab dependency

### 7. Senior Dev active-work concurrency

For the current Senior Dev path, configured Hermes active-work/task state is the concurrency boundary for normal Team Lead code handoffs. Team Lead routes code requests through the Senior Dev handoff runtime; the Senior path serializes execution and keeps active work visible when the runtime exposes task state.

Older docs may mention a separate code mutex, Marinator, or Senior Kanban review queue for legacy/manual protected paths. Current docs and skills should route ordinary code work through the Team Lead → Senior Dev handoff contract. If a future manual-path mutex or alternate queue is introduced, record it as an explicit design decision with tests and a clear bypass-risk story.

### 8. Minimal target-repo footprint

OpenClaw can leak workspace artifacts (`AGENTS.md`, `SOUL.md`, `TOOLS.md`, `.openclaw/`, `state/`) into the target repo unless careful hygiene scripts run. The Hermes version installs exactly **one** file in the target repo: `HERMES.md` (the project-level operating protocol). Everything else — `SOUL.md`, memory, skills, profile docs, mutex state, backlog, logs — lives under `~/.hermes/` and never touches the target repo. Whether `HERMES.md` is committed to git or kept in `.gitignore` is a per-project decision; committing it makes the orchestrator protocol part of the project's documented contract, ignoring it keeps the project history Junie-agnostic.

## Data flow

1. **Incoming message** → Hermes Gateway → Profile session
2. **Skill matching** → relevant skills loaded automatically
3. **Memory check** → strategic context available in prompt
4. **Task validation** → intake skill validates against strategy
5. **Senior Dev handoff** → Team Lead sends a structured code-work handoff to the configured Senior Dev runtime
6. **Senior execution** → `senior-dev` runs synchronous headless Junie CLI via `senior_run_coding_task` and writes artifacts
7. **Final verdict** → Senior Dev returns `done`, `needs-input`, or `failed` with summary, changes, verification, and blockers when applicable
8. **Reflection/report** → lessons saved to memory/skills/docs; terminal task events notify Telegram

## State management

| State | Location | Managed by |
| --- | --- | --- |
| Strategic context | Hermes memory stores | memory tool |
| Session history | `~/.hermes/profiles/junie-live/state.db` | Hermes sessions |
| Detailed docs | Target repo `docs/` or profile `docs/` | File read/write |
| Senior p1 runs | `~/.hermes/profiles/senior-dev/junie-live/state/senior/runs/` by default, overridable for tests | `senior-runner` plugin |
| Active Senior Dev tasks | Configured Hermes active-work/task state for `senior-dev` | `senior-task` plugin/runtime dispatcher where enabled |
| Backlog / work-window state | `~/.hermes/profiles/junie-live/junie-live/state/` when used by approved routines | Junie profile / approved routines |
| Operational logs | `~/.hermes/profiles/junie-live/junie-live/state/logs/` plus Hermes profile logs | Hermes / approved routines |
| Skills | `~/.hermes/profiles/junie-live/skills/` | skill_manage |
| Identity (personality + safety-net rules) | `~/.hermes/profiles/junie-live/SOUL.md` | Manual/hire script |
| Project operating protocol | `<target-repo>/HERMES.md` (copied from seed during init) | Manual/Junie during init |

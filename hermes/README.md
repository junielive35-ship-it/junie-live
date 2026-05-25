# Junie Live — Hermes Implementation

Hermes-native implementation of [Junie Live](../idea.md): a persistent, product-owning senior SWE agent.

## What is this?

This directory contains everything needed to run Junie Live on top of [Hermes Agent](https://hermes-agent.nousresearch.com/docs/) instead of OpenClaw. The behavioral contract — product ownership, strategic validation, delegation, review, reflection, autonomous work windows — stays the same. The implementation leverages Hermes-native features instead of shell scripts and OpenClaw workspace conventions.

## Key architectural differences from OpenClaw version

| Concern | OpenClaw | Hermes |
|---------|----------|--------|
| Orchestration | OpenClaw agent with `AGENTS.md` workspace | Hermes profile with persona, memory, skills, and `AGENTS.md` in workdir |
| Persistent context | `MEMORY.md` file in workspace | Hermes native memory (user + memory stores) |
| Coding delegation | `opencode run` subagent via shell scripts | `delegate_task` or spawned `hermes`/`claude-code`/`codex` process |
| Scheduled routines | System crontab / OpenClaw cron | Hermes native cron jobs |
| Skills | OpenClaw skill files in workspace | Hermes skills (first-class, auto-loaded by matching) |
| Repo hygiene | Shell scripts checking for workspace artifacts | Simpler — no workspace artifacts to leak into repo |

## Setup

```bash
./hermes/scripts/hire-junie.sh \
  --telegram-token "$JUNIE_TELEGRAM_BOT_TOKEN" \
  --admin-telegram-id YOUR_ID

# Then send /start to the Junie bot in Telegram.
```

The hire script does everything: creates a Hermes profile, installs persona/skills/docs, configures Telegram with DM restricted to the admin, and starts the gateway. See [docs/setup.md](docs/setup.md) for details and manual setup options.

## Directory structure

```
hermes/
├── README.md                          # This file
├── initialization/                    # Reusable seed for new Junie instances
│   ├── AGENTS.md                      # Project-level operating protocol (loaded by Hermes from workdir)
│   ├── persona.md                     # Hermes persona (replaces SOUL.md)
│   ├── memory-seed.md                 # Initial memory entries to inject
│   ├── docs/                          # Detailed knowledge base (same concept)
│   │   ├── strategy.md
│   │   ├── architecture.md
│   │   ├── design-decisions.md
│   │   ├── product-hypotheses.md
│   │   ├── analytics-plan.md
│   │   ├── delegation-protocol.md
│   │   ├── review-protocol.md
│   │   ├── reflection-protocol.md
│   │   ├── consistency-protocol.md
│   │   └── implementation-status.md
│   └── skills/                        # Hermes skills (SKILL.md format)
│       ├── autonomous-work-window/
│       ├── coding-task-decomposition/
│       ├── implementation-review/
│       ├── task-intake-validation/
│       └── task-reflection/
├── scripts/
│   ├── hire-junie.sh                  # Creates profile, installs skills, sets up gateway
│   ├── verify.sh                      # Repo verification (bash syntax, links, tables)
│   └── code-mutex.sh                  # Lightweight mutex using state files
├── docs/
│   ├── setup.md                       # Full setup guide
│   ├── architecture.md                # Hermes-specific architecture
│   ├── overnight-routines.md          # Autonomous work window contract
│   └── day-to-day-routines.md         # Operational routines
└── openclaw-hermes-comparison.md      # Platform comparison for decision-making
```

## How it works

1. **Profile** — Junie runs as a Hermes profile (`junie-live`), with its own config, memory, skills, and sessions.

2. **Persona** — `initialization/persona.md` defines the senior product-owner personality (replaces OpenClaw's `SOUL.md`).

3. **AGENTS.md** — `initialization/AGENTS.md` is the project-level operating protocol. Hermes auto-loads it from the working directory into the system prompt when running in the target repo. This carries the challenge protocol, delegation rules, code mutex conventions, and change rules — the same role as OpenClaw's `AGENTS.md`, but loaded natively by Hermes.

4. **Memory** — Hermes native memory stores durable strategic context (replaces `MEMORY.md`). Compact facts in user/memory stores; detailed docs read from `docs/` on demand.

5. **Skills** — Hermes skills replace OpenClaw protocols. They're auto-loaded when relevant tasks match, and they carry the delegation, review, reflection, and intake workflows.

6. **Delegation** — Coding work is delegated via `delegate_task` (for bounded subtasks) or spawned processes (for long autonomous work). The orchestrator never codes directly.

7. **Cron** — Hermes cron jobs replace shell crontab entries. Watchdog, health checks, and overnight routines are native cron jobs created during setup.

8. **Telegram** — Hermes gateway provides native Telegram integration with DM allowlisting, the same as the OpenClaw version.

9. **Code Mutex** — A lightweight state-file mutex under `~/.hermes/junie-live/state/code_mutex/` prevents parallel code-changing work. Simpler than the OpenClaw version because Hermes sessions are better isolated.

## Current implementation status

See [docs/implementation-status.md](docs/implementation-status.md).

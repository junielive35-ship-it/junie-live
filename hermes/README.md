# Junie Live — Hermes Implementation

Hermes-native implementation of [Junie Live](../idea.md): a persistent, product-owning senior SWE agent.

## What is this?

This directory contains everything needed to run Junie Live on top of [Hermes Agent](https://hermes-agent.nousresearch.com/docs/) instead of OpenClaw. The behavioral contract — product ownership, strategic validation, delegation, review, reflection, autonomous work windows — stays the same. Junie Live's task-solving loop is called the **Marinator** when referring to validation/decomposition, delegation, result checking, fix requests, verification, acceptance/reporting, and reflection as one loop. The implementation leverages Hermes-native features instead of shell scripts and OpenClaw workspace conventions.

## Key architectural differences from OpenClaw version

| Concern | OpenClaw | Hermes |
|---------|----------|--------|
| Orchestration | OpenClaw agent with `AGENTS.md` workspace | Hermes profile with `SOUL.md`, memory, skills, and `HERMES.md` in the target repo |
| Persistent context | `MEMORY.md` file in workspace | Hermes native memory (user + memory stores) |
| Coding delegation | `opencode run` subagent via shell scripts | `delegate_task` or spawned `hermes`/`claude-code`/`codex` process |
| Scheduled routines | System crontab / OpenClaw cron | Hermes native cron jobs |
| Skills | OpenClaw skill files in workspace | Hermes skills (first-class, auto-loaded by matching) |
| Repo hygiene | Shell scripts checking for workspace artifacts | Single tracked file in the target repo (`HERMES.md`); all other state under `~/.hermes/` |

## Setup

```bash
./hermes/scripts/hire-junie.sh \
  --telegram-token "$JUNIE_TELEGRAM_BOT_TOKEN" \
  --admin-telegram-id YOUR_ID

# Then send /start to the Junie bot in Telegram.
```

The hire script does everything: creates a Hermes profile, installs `SOUL.md` / skills / docs / `seed-HERMES.md` / `memory-seed.md` / `INITIALIZATION.md`, configures Telegram with DM restricted to the admin, and starts the gateway. See [docs/setup.md](docs/setup.md) for details and manual setup options.

## Directory structure

```
hermes/
├── README.md                          # This file
├── initialization/                    # Reusable seed for new Junie instances
│   ├── SOUL.md                        # Personality + always-on operating rules (auto-loaded by Hermes from profile)
│   ├── INITIALIZATION.md              # One-shot init workflow (deleted by Junie when init completes)
│   ├── memory-seed.md                 # Initial memory entries to inject during init
│   ├── docs/                          # Detailed knowledge base + protocol templates
│   │   ├── seed-HERMES.md             # Project-level operating protocol; copied to <target-repo>/HERMES.md during init
│   │   ├── tools.md                   # Operational cheat-sheet (commands, git conventions, deploy, escalation) — filled during init
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
│       ├── junie-autonomous-work-window/
│       ├── junie-coding-task-decomposition/
│       ├── junie-implementation-review/
│       ├── junie-task-intake-validation/
│       └── junie-task-reflection/
├── scripts/
│   ├── hire-junie.sh                  # Creates profile, installs skills, sets up gateway
│   ├── verify.sh                      # Repo verification (bash syntax, links, structure)
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

2. **SOUL.md** — `initialization/SOUL.md` is installed into the profile root as `~/.hermes/profiles/junie-live/SOUL.md`. Hermes auto-loads it as the agent identity (slot #1 in the system prompt) on every turn, regardless of working directory. It carries Junie's personality plus the always-on operating safety net (initialization gate, no-direct-coding rule, challenge protocol). Replaces OpenClaw's `SOUL.md`.

3. **HERMES.md** — `initialization/docs/seed-HERMES.md` is copied into the target project repo root as `HERMES.md` during initialization. Hermes auto-loads `HERMES.md` (and `.hermes.md`) from the current working directory, walking up to the git root, so the full project-level protocol is active whenever Junie works in the target repo. We pick `HERMES.md` over `AGENTS.md` because coding executors (opencode, codex, claude-code) read `AGENTS.md` — keeping the orchestrator protocol in `HERMES.md` prevents executor sessions from being polluted by orchestrator-only rules.

4. **Memory** — Hermes native memory stores durable strategic context (replaces `MEMORY.md`). Compact facts in user/memory stores; detailed knowledge in profile `docs/` read on demand.

5. **Skills** — Hermes skills replace OpenClaw protocols. They're auto-loaded when relevant tasks match, and they carry the delegation, review, reflection, and intake workflows.

6. **Delegation** — Coding work is delegated via `~/.opencode/bin/opencode run` (the orchestrator never codes directly). Non-code subtasks may use `delegate_task` instead.

7. **Cron** — Hermes cron jobs replace shell crontab entries. Watchdog, health checks, and overnight routines are native cron jobs created during setup.

8. **Telegram** — Hermes gateway provides native Telegram integration with DM allowlisting, the same as the OpenClaw version.

9. **Code Mutex** — A lightweight state-file mutex under `~/.hermes/junie-live/state/code_mutex/` prevents parallel code-changing work. Same atomic-`mkdir` primitive as OpenClaw, just under `~/.hermes/`.

## Current implementation status

See [docs/implementation-status.md](docs/implementation-status.md).

# Junie Live — Hermes Setup Guide

## Prerequisites

- [Hermes Agent](https://hermes-agent.nousresearch.com/docs/) installed
- A Telegram bot token (from [@BotFather](https://t.me/BotFather))
- Your Telegram user ID
- An LLM provider configured in Hermes (OpenRouter, Anthropic, etc.) — for orchestrator turns
- [opencode](https://github.com/sst/opencode) installed at `~/.opencode/bin/opencode` — for code-changing delegations
- An OpenRouter API key — for opencode (see step 5 below for installation)
- Python 3.10+ with `pip` available

## Quick Setup

```bash
cd ~/code/junie-live

# Run the hire script (installs junie_runtime package automatically)
./hermes/scripts/hire-junie.sh \
  --telegram-token "$JUNIE_TELEGRAM_BOT_TOKEN" \
  --admin-telegram-id YOUR_TELEGRAM_ID
```

## Manual Setup

### 1. Create a Hermes profile

```bash
hermes profile create junie-live
```

### 2. Install seed files

Copy the entire initialization directory to the profile (`SOUL.md`, skills, docs, `INITIALIZATION.md`, `memory-seed.md`):
```bash
cp -a hermes/initialization/. ~/.hermes/profiles/junie-live/
```

### 3. Install shared runtime package

The `junie_runtime` package provides the code mutex and other shared primitives. Install it into the Python environment:

```bash
python3 -m pip install -e hermes/junie_runtime
```

This is a shared package used by all Junie profiles in this Hermes install, not profile-local code. It must be importable for `code-mutex.sh` to work.

### 4. Configure Telegram

Add the Telegram token to the profile's .env:
```bash
echo "TELEGRAM_BOT_TOKEN=your-token-here" >> ~/.hermes/profiles/junie-live/.env
```

Configure the gateway:
```bash
hermes -p junie-live gateway setup
```

### 5. Configure opencode for code-changing delegations

Junie delegates all code-changing work to [opencode](https://github.com/sst/opencode) via the `marinator_delegate` Hermes plugin. OpenCode authenticates *independently* of Hermes — it does not read the profile's `.env`. You must configure it once at the system level:

```bash
# One-time: install your OpenRouter key where opencode can find it from the system home
echo "your-openrouter-key" > ~/openrouter.key
chmod 600 ~/openrouter.key
```

Then verify opencode can authenticate:

```bash
/home/$USER/.opencode/bin/opencode auth list
```

You should see either `OpenRouter ~/.local/share/opencode/auth.json` under `Credentials`, or `OpenRouter OPENROUTER_API_KEY` under `Environment`. If both are empty, opencode delegations will fail with `UnknownError`/`err_*` references and Junie cannot do any code-changing work.

**Important for cron / autonomous-window sessions:** when Hermes invokes a skill, cron job, or subagent, `$HOME` is rewritten to the profile-scoped home (`~/.hermes/profiles/junie-live/home/`), where `openrouter.key` does NOT exist. The fallback `$HOME/openrouter.key` lookup that works from an interactive shell silently breaks under cron. The `marinator-worker.sh` script handles this by resolving the system home explicitly.

If you write your own cron prompts or skills that invoke opencode directly (rather than via `marinator_delegate`), export `OPENROUTER_API_KEY` explicitly. See `docs/tools.md` ("$HOME indirection trap") and `marinator-worker.sh` for the canonical invocation pattern.

### 5. Set up Telegram DM allowlist

Configure pairing for your Telegram user:
```bash
hermes -p junie-live pairing approve YOUR_TELEGRAM_ID
```

### 6. Start the gateway

```bash
hermes -p junie-live gateway start
```

### 7. Initialize Junie

Send `/start` to the Telegram bot, then provide:
- The path to the target project repository
- Your area of responsibility for Junie
- Expectations, constraints, and team/product context
- Communication channels and relevant people

Junie will follow the initialization workflow, inspect the project, ask questions, and build its durable context.

## Post-Setup: Optional Cron Jobs

Setup and initialization do not install cron jobs by default. Autonomous-work
windows are normally started by owner/admin request through Telegram or another
Hermes session. Add recurring Hermes cron jobs only after explicit owner/admin
decision, because watchdog, health-check, and scheduled overnight-start jobs
change Junie's operational behavior.

### Watchdog (optional, operator-configured)

If enabled, create from a `hermes -p junie-live` session:
```
Create a cron job named "junie-watchdog" that runs every 15 minutes.
It should check: code mutex state (stale holders), stuck backlog items,
recent progress. If something looks wrong, report via Telegram.
```

### Health check (optional, operator-configured)

If enabled:
```
Create a daily cron job named "junie-health-check" at 9am.
It should check: backlog status, open PRs, pending decisions.
Report a brief summary via Telegram.
```

### Overnight controller (optional, disabled by default)

Only enable after explicit admin decision:
```
Create a cron job named "junie-overnight" at 1am, paused.
It should run an autonomous work window selecting and completing
backlog items until 8am or blockers.
```

## Directory Layout After Setup

```
~/.hermes/profiles/junie-live/
├── config.yaml           # Profile-specific config
├── .env                  # Telegram token, API keys
├── SOUL.md               # Junie personality + always-on operating rules (auto-loaded by Hermes)
├── INITIALIZATION.md     # Initialization guide (deleted after init)
├── memory-seed.md        # Initial memory entries template
├── docs/                 # Profile docs (strategy, architecture, etc.)
│   ├── seed-HERMES.md    # Project-level operating protocol; copied to <target-repo>/HERMES.md during init
│   └── tools.md          # Operational cheat-sheet (commands, git conventions, deploy, escalation) — filled during init
├── skills/               # Installed skills
│   ├── junie-autonomous-work-window/
│   ├── junie-coding-task-decomposition/
│   ├── junie-implementation-review/
│   ├── junie-task-intake-validation/
│   └── junie-task-reflection/
├── sessions/             # Session history
└── state.db              # Session database

~/.hermes/profiles/junie-live/junie-live/
└── state/
    ├── code_mutex/       # Mutex state files
    ├── backlog/          # Hermes-native backlog items (Markdown + YAML frontmatter)
    │   ├── items/        # Active items (*.md)
    │   ├── archive/      # Done/dropped items
    │   └── events.jsonl  # Backlog operation log
    ├── reflections/      # Post-task reflections
    ├── overnight/        # Overnight routine state
    ├── autonomous_work/  # AW window directories and artifacts
    └── logs/             # Operational logs

The duplicate-looking `junie-live/junie-live` is expected in the current implementation: the first segment is the Hermes profile name, and the second is Junie Live's app-state namespace inside that profile. Legacy `~/.hermes/junie-live/state/` is used only for backup/cleanup compatibility.

<target-repo>/
└── HERMES.md             # Project-level operating protocol (installed by Junie during init)
```

## Updating

To update the Junie Live seed files after improvements:

```bash
# Re-run hire with existing profile (preserves memory and sessions)
./hermes/scripts/hire-junie.sh \
  --telegram-token "$JUNIE_TELEGRAM_BOT_TOKEN" \
  --admin-telegram-id YOUR_TELEGRAM_ID
```

To update the shared `junie_runtime` package after changes:

```bash
python3 -m pip install -e hermes/junie_runtime  # re-installs to pick up changes
```

### Disaster recovery (dump / rehire)

`dump-junie.sh` now includes exact `junie_runtime` wheel and provenance manifest in the archive (under `runtime/`). `rehire-junie.sh` restores the exact wheel from the archive, verifies its SHA-256 hash, and writes restore metadata to the profile runtime manifest. If the runtime artifact is missing from the dump archive, rehire fails clearly instead of silently installing from a sibling source directory. There is no profile-local venv — the wheel is installed into the system Python environment.

Or selectively update a skill:
```bash
cp hermes/initialization/skills/junie-task-reflection/SKILL.md \
   ~/.hermes/profiles/junie-live/skills/junie-task-reflection/SKILL.md
```

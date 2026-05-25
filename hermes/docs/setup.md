# Junie Live — Hermes Setup Guide

## Prerequisites

- [Hermes Agent](https://hermes-agent.nousresearch.com/docs/) installed
- A Telegram bot token (from [@BotFather](https://t.me/BotFather))
- Your Telegram user ID
- An LLM provider configured in Hermes (OpenRouter, Anthropic, etc.)

## Quick Setup

```bash
cd ~/code/junie-live

# Run the hire script
./hermes/scripts/hire-junie.sh \
  --telegram-token "$JUNIE_TELEGRAM_BOT_TOKEN" \
  --admin-telegram-id YOUR_TELEGRAM_ID \
  --repo ~/code/your-target-project
```

## Manual Setup

### 1. Create a Hermes profile

```bash
hermes profile create junie-live
```

### 2. Configure the persona

Copy the persona file:
```bash
cp hermes/initialization/persona.md ~/.hermes/profiles/junie-live/persona.md
```

### 3. Install skills

Copy skills to the profile's skill directory:
```bash
for skill_dir in hermes/initialization/skills/*/; do
  skill_name=$(basename "$skill_dir")
  mkdir -p ~/.hermes/profiles/junie-live/skills/junie-live/$skill_name
  cp -r "$skill_dir"/* ~/.hermes/profiles/junie-live/skills/junie-live/$skill_name/
done
```

### 4. Configure Telegram

Add the Telegram token to the profile's .env:
```bash
echo "TELEGRAM_BOT_TOKEN=your-token-here" >> ~/.hermes/profiles/junie-live/.env
```

Configure the gateway:
```bash
hermes -p junie-live gateway setup
```

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

## Post-Setup: Create Cron Jobs

After initialization, create the recommended cron jobs from a Hermes session:

### Watchdog (recommended, runs every 15 minutes)

From a `hermes -p junie-live` session:
```
Create a cron job named "junie-watchdog" that runs every 15 minutes.
It should check: code mutex state (stale holders), stuck backlog items,
recent progress. If something looks wrong, report via Telegram.
```

### Health check (daily)

```
Create a daily cron job named "junie-health-check" at 9am.
It should check: backlog status, open PRs, pending decisions.
Report a brief summary via Telegram.
```

### Overnight controller (disabled by default)

Only enable after explicit admin approval:
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
├── persona.md            # Junie personality
├── skills/               # Installed skills
│   └── junie-live/
│       ├── junie-autonomous-work-window/
│       ├── junie-coding-task-decomposition/
│       ├── junie-implementation-review/
│       ├── junie-task-intake-validation/
│       └── junie-task-reflection/
├── sessions/             # Session history
└── state.db              # Session database

~/.hermes/junie-live/
└── state/
    ├── code_mutex/       # Mutex state files
    ├── backlog/          # Backlog items
    │   └── items/
    ├── reflections/      # Post-task reflections
    ├── overnight/        # Overnight routine state
    └── logs/             # Operational logs
```

## Updating

To update the Junie Live seed files after improvements:

```bash
# Re-run hire with existing profile (preserves memory and sessions)
./hermes/scripts/hire-junie.sh \
  --telegram-token "$JUNIE_TELEGRAM_BOT_TOKEN" \
  --admin-telegram-id YOUR_TELEGRAM_ID
```

Or selectively update skills:
```bash
cp hermes/initialization/skills/task-reflection/SKILL.md \
   ~/.hermes/profiles/junie-live/skills/junie-live/junie-task-reflection/SKILL.md
```

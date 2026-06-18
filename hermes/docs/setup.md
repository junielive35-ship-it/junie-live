# Junie Live — Hermes Setup Guide

## Prerequisites

- [Hermes Agent](https://hermes-agent.nousresearch.com/docs/) installed
- A Telegram bot token (from [@BotFather](https://t.me/BotFather))
- Your Telegram user ID
- An LLM provider configured in Hermes (OpenRouter, Anthropic, etc.) — for Team Lead turns
- Junie CLI installed and authenticated for headless Senior Dev code-changing handoffs
- A Junie CLI auth token/key appropriate for the target environment (see step 5 below)
- Python 3.10+ with `pip` available

## Quick Setup

```bash
cd ~/code/junie-live

# Run the hire script (installs junie_runtime package automatically)
./hermes/scripts/hire-junie.sh \
  --telegram-token "$JUNIE_TELEGRAM_BOT_TOKEN" \
  --admin-telegram-id YOUR_TELEGRAM_ID
```

### Optional: Slack credentials

If a `~/slack-tokens` file is present (override the path with the `SLACK_TOKENS_FILE`
environment variable), `hire-junie.sh` forwards recognized Slack keys
(`SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`, `SLACK_ALLOWED_USERS`,
`SLACK_ALLOW_ALL_USERS`, `SLACK_HOME_CHANNEL`, `SLACK_HOME_CHANNEL_NAME`,
`SLACK_ALLOWED_CHANNELS`) into the profile `.env`.

**Suppressing the "No home channel is set for Slack" notice.** Junie Live
installs intentionally run without a Slack *service* home channel. The Hermes
gateway otherwise delivers a one-time "No home channel is set for Slack" notice
on every new Slack thread/session whenever `SLACK_HOME_CHANNEL` is unset. When
Slack credentials are forwarded but no real `SLACK_HOME_CHANNEL` is provided,
`hire-junie.sh` writes `SLACK_SUPPRESS_HOME_CHANNEL_NOTICE=true` to the profile
`.env`, which tells the gateway to skip that notice. This is a Hermes-native,
per-platform opt-out flag (`<PLATFORM>_SUPPRESS_HOME_CHANNEL_NOTICE`); it does
**not** set a fake `SLACK_HOME_CHANNEL`, so real cron / cross-platform delivery
semantics are preserved.

You can later set a real Slack home channel at any time with `/hermes sethome`
in the desired Slack channel; that still works regardless of the suppression
flag. Removing `SLACK_SUPPRESS_HOME_CHANNEL_NOTICE` (or setting it to a falsey
value) restores the original notice behavior. The flag lives in the profile
`.env`, so it is preserved across `dump-junie.sh` / `rehire-junie.sh` (native
`hermes profile export` / `import`).

## Manual Setup

### 1. Create a Hermes profile

```bash
hermes profile create junie-live
```

### 2. Install profile distribution

Install the Junie profile distribution, which provides `SOUL.md`, skills, docs, `INITIALIZATION.md`, `memory-seed.md`, plugins, and scripts:
```bash
hermes profile install hermes/distribution --name junie-live --alias
```

### 3. Install shared runtime package

The `junie_runtime` package provides shared runtime primitives. Install it into the Python environment:

```bash
python3 -m pip install -e hermes/junie_runtime
```

This is a shared package used by all Junie profiles in this Hermes install, not profile-local code.

### 4. Configure Telegram

Add the Telegram token to the profile's .env:
```bash
echo "TELEGRAM_BOT_TOKEN=your-token-here" >> ~/.hermes/profiles/junie-live/.env
```

Configure the gateway:
```bash
hermes -p junie-live gateway setup
```

### 5. Configure Junie CLI for Senior Dev code-changing handoffs

Junie routes normal code-changing work through the Team Lead → headless Senior Dev contract. The `senior-dev` companion profile runs Junie CLI synchronously through the `senior_run_coding_task` tool (`senior-runner` plugin) and reports exactly one final verdict: `done`, `needs-input`, or `failed`. Junie CLI authenticates independently of Hermes profile memory and must be configured once at the system level:

```bash
# One-time: install/configure Junie CLI auth for headless Senior Dev runs.
# The exact command depends on your deployment and account policy.
junie --version
```

Then verify Junie CLI readiness with a small headless smoke execution:

```bash
junie "Respond with exactly: JUNIE_SMOKE_OK"
# Expected: output contains JUNIE_SMOKE_OK, exit 0
```

The canonical readiness check is a real headless execution that tests the full runtime path Senior Dev uses for coding runs.

**Important for cron sessions:** when Hermes invokes a skill, cron job, or subagent, `$HOME` may be rewritten to the profile-scoped home (`~/.hermes/profiles/junie-live/home/`). Configure Senior Dev auth through the supported Junie CLI mechanism for the environment, and avoid ad-hoc scripts that assume the interactive shell's `$HOME`.

If you write your own cron prompts or skills that invoke code-changing runs directly, route them through the Senior Dev handoff runtime instead of bypassing the contract. See `docs/tools.md` and `senior-runner` for canonical invocation patterns.

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

Setup and initialization do not install cron jobs by default. Work windows are
normally started by owner/admin request through Telegram or another Hermes
session. Add recurring Hermes cron jobs only after explicit owner/admin
decision, because watchdog, health-check, and scheduled overnight-start jobs
change Junie's operational behavior.

### Watchdog (optional, operator-configured)

If enabled, create from a `hermes -p junie-live` session:
```
Create a cron job named "junie-watchdog" that runs every 15 minutes.
It should check: stuck backlog items,
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
It should run a bounded work window selecting and completing
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
│   ├── HERMES.seed.md    # Project-level operating protocol; copied to <target-repo>/HERMES.md during init
│   └── tools.md          # Operational cheat-sheet (commands, git conventions, deploy, escalation) — filled during init
├── skills/               # Installed skills
│   ├── junie-task-intake-validation/
│   └── junie-task-reflection/
├── sessions/             # Session history
└── state.db              # Session database

~/.hermes/profiles/junie-live/junie-live/
└── state/
    ├── backlog/          # Hermes-native backlog items (Markdown + YAML frontmatter)
    │   ├── items/        # Active items (*.md)
    │   ├── archive/      # Done/dropped items
    │   └── events.jsonl  # Backlog operation log
    ├── reflections/      # Post-task reflections
    ├── overnight/        # Overnight routine state
    └── logs/             # Operational logs

The duplicate-looking `junie-live/junie-live` is expected in the current implementation: the first segment is the Hermes profile name, and the second is Junie Live's app-state namespace inside that profile. Legacy `~/.hermes/junie-live/state/` is used only for backup/cleanup compatibility.

<target-repo>/
└── HERMES.md             # Project-level operating protocol (installed by Junie during init)
```

## Updating

### Via profile distribution update

```bash
hermes profile update junie-live
```

To update the shared `junie_runtime` package after changes:

```bash
python3 -m pip install -e hermes/junie_runtime  # re-installs to pick up changes
```

Or run the hire script for a full re-hire (deletes then reinstalls the profile):
```bash
./hermes/scripts/hire-junie.sh \
  --telegram-token "$JUNIE_TELEGRAM_BOT_TOKEN" \
  --admin-telegram-id YOUR_TELEGRAM_ID
```

### Disaster recovery (dump / rehire)

`dump-junie.sh` (in the profile's `scripts/`) wraps `hermes profile export`, then embeds the exact `junie_runtime` wheel and provenance manifest inside the single native-import-compatible profile directory at `junie-live/runtime_artifact/`. It also embeds Hermes active-work state where present so Senior Dev routing state can survive disaster recovery. `rehire-junie.sh` wraps `hermes profile import`, restores active-work state beside `profiles/` in the target Hermes root, restores the exact wheel from the embedded artifact, verifies its SHA-256 hash, and writes restore metadata to the profile runtime manifest. If target active-work state already exists, rehire requires `--force` and moves the old state aside. If the runtime artifact is missing from the dump archive, rehire fails clearly instead of silently installing from a sibling source directory. There is no profile-local venv — the wheel is installed into the system Python environment.

Or selectively update a skill:
```bash
cp hermes/distribution/skills/junie-task-reflection/SKILL.md \
   ~/.hermes/profiles/junie-live/skills/junie-task-reflection/SKILL.md
```

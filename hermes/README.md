# Junie Live — Hermes Implementation

Hermes-native implementation of [Junie Live](../idea.md): a persistent, product-owning senior SWE agent.

## Setup

1. Install [Hermes Agent](https://hermes-agent.nousresearch.com/docs/getting-started/installation):
   ```bash
   curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
   hermes setup
   ```

2. Create a Telegram bot and token:
   - Open [@BotFather](https://t.me/BotFather).
   - Send `/newbot`.
   - Choose a display name and a username ending in `bot`.
   - Copy the API token BotFather returns.

3. Find your Telegram numeric user ID:
   - Message [@userinfobot](https://t.me/userinfobot).
   - Copy the number it returns. It is not your `@username`.

4. Hire Junie:
   ```bash
   cd ~/code/junie-live
   export JUNIE_TELEGRAM_BOT_TOKEN="paste-token-here"
   ./hermes/scripts/hire-junie.sh \
     --telegram-token "$JUNIE_TELEGRAM_BOT_TOKEN" \
     --admin-telegram-id YOUR_NUMERIC_TELEGRAM_ID
   ```

5. Send `/start` to the Junie bot in Telegram.

The hire script creates the Hermes profile, installs Junie seed files, configures Telegram DM access for the admin ID, installs the shared `junie_runtime` package into the Hermes Python environment, and starts the gateway. See [docs/setup.md](docs/setup.md) for manual setup options.

## Dump / rehire

After hire, Junie can dump its live Hermes profile from inside the profile:

```bash
~/.hermes/profiles/junie-live/scripts/dump-junie.sh --output /tmp/junie-live.tgz
```

Restore is an operator action from this repo:

```bash
JUNIE_HERMES_ROOT=~/.hermes ./hermes/scripts/rehire-junie.sh /tmp/junie-live.tgz --profile junie-live
```

The dump includes config, `.env`, `state.db`, sessions, skills, plugins, Junie state, and Hermes active-work state where present. `rehire-junie.sh` restores the profile and restarts the gateway without running `gateway install`.

## What is this?

This directory contains everything needed to run Junie Live on top of [Hermes Agent](https://hermes-agent.nousresearch.com/docs/) instead of OpenClaw. The behavioral contract is now split by role: Team Lead owns product context, strategic validation, intake, handoff quality, reporting, reflection, and autonomous work windows; Senior Dev owns implementation, review, verification, fix loop, and final verdict after handoff. The implementation leverages Hermes-native features instead of shell scripts and OpenClaw workspace conventions.

## Key architectural differences from OpenClaw version

| Concern | OpenClaw | Hermes |
|---------|----------|--------|
| Team Lead context | OpenClaw agent with `AGENTS.md` workspace | Hermes profile with `SOUL.md`, memory, skills, and `HERMES.md` in the target repo |
| Persistent context | `MEMORY.md` file in workspace | Hermes native memory (user + memory stores) |
| Code handoff | Shell-script worker delegation | Structured Team Lead → headless Senior Dev handoff; `senior_run_coding_task` runs Junie CLI and returns `done`, `needs-input`, or `failed`; `delegate_task` only for non-code subtasks |
| Scheduled routines | System crontab / OpenClaw cron | Hermes native cron jobs |
| Skills | OpenClaw skill files in workspace | Hermes skills (first-class, auto-loaded by matching) |
| Repo hygiene | Shell scripts checking for workspace artifacts | Single tracked file in the target repo (`HERMES.md`); all other state under `~/.hermes/` |

## Directory structure

```
hermes/
├── README.md                          # This file
├── junie_runtime/                     # Shared Python package (pip-installable)
│   ├── pyproject.toml
│   ├── src/junie_runtime/
│   │   ├── __init__.py
│   │   ├── paths.py                   # Hermes profile path resolution
│   │   ├── state.py                   # Atomic state file helpers
│   │   ├── events.py                  # JSONL event helpers
│   └── tests/
│       ├── test_paths.py
│       └── test_state.py
├── distribution/                      # Canonical Hermes profile distribution (install via `hermes profile install`)
│   ├── distribution.yaml              # Distribution manifest
│   ├── SOUL.md                        # Personality + always-on operating rules (auto-loaded by Hermes from profile)
│   ├── INITIALIZATION.md              # One-shot init workflow (deleted by Junie when init completes)
│   ├── memory-seed.md                 # Initial memory entries to inject during init
│   ├── HERMES.seed.md                 # Project-level operating protocol; copied to <target-repo>/HERMES.md during init
│   ├── config.yaml                    # Shipped defaults (preserved on update)
│   ├── .env                           # Created by hire-junie.sh with Telegram creds
│   ├── docs/                          # Profile-internal Junie docs (strategy, protocols, etc.)
│   ├── skills/                        # Installed skills
│   ├── plugins/                       # Senior task/runner and autonomous work plugins
│   ├── scripts/                       # Profile-local helper scripts (dump, initialization, etc.)
│   └── cron/                          # Optional profile cron jobs
├── initialization/                    # Superseded by distribution/; kept for migration compatibility
├── scripts/
│   ├── hire-junie.sh                  # Creates profile, installs skills, sets up gateway
│   ├── verify.sh                      # Repo verification (bash syntax, links, structure)
│   ├── rehire-junie.sh                # Restore profile from disaster recovery archive
│   └── test-*.sh                      # Regression test suites
├── docs/
│   ├── setup.md                       # Full setup guide
│   ├── architecture.md                # Hermes-specific architecture
│   ├── overnight-routines.md          # Autonomous work window contract
│   └── day-to-day-routines.md         # Operational routines
└── openclaw-hermes-comparison.md      # Platform comparison for decision-making
```

## How it works

1. **Profile** — Junie runs as a Hermes profile (`junie-live`), with its own config, memory, skills, and sessions.

2. **SOUL.md** — `distribution/SOUL.md` is installed into the profile root as `~/.hermes/profiles/junie-live/SOUL.md` via Hermes profile distribution. Hermes auto-loads it as the agent identity (slot #1 in the system prompt) on every turn, regardless of working directory. It carries Junie's personality plus the always-on operating safety net (initialization gate, no-direct-coding rule, challenge protocol). Replaces OpenClaw's `SOUL.md`.

3. **HERMES.md** — `distribution/HERMES.seed.md` is installed into the profile as `HERMES.seed.md` via profile distribution. During initialization, the agent copies it to the target project repo root as `HERMES.md`. Hermes auto-loads `HERMES.md` (and `.hermes.md`) from the current working directory, walking up to the git root, so the full project-level Team Lead protocol is active whenever Junie works in the target repo. We pick `HERMES.md` over `AGENTS.md` because Senior Dev and coding executors read their own contracts — keeping Team Lead protocol in `HERMES.md` prevents executor sessions from being polluted by Team Lead-only rules.

4. **Memory** — Hermes native memory stores durable strategic context (replaces `MEMORY.md`). Compact facts in user/memory stores; detailed knowledge in profile `docs/` read on demand.

5. **Skills** — Hermes skills replace OpenClaw protocols. They're auto-loaded when relevant tasks match, and active Team Lead skills carry intake and reflection workflows.

6. **Senior Dev handoff** — Normal code-changing work is handed off to the `senior-dev` headless Junie CLI runtime with repository path, user-visible outcome, acceptance criteria, distilled context, constraints, non-goals, and expected report schema. Senior Dev returns exactly one final verdict: `done`, `needs-input`, or `failed`. Team Lead never codes directly. Non-code subtasks may use `delegate_task` instead.

7. **Cron** — Hermes cron jobs replace shell crontab entries when recurring routines are explicitly approved. Setup does not install watchdog, health-check, or overnight-start jobs by default.

8. **Telegram** — Hermes gateway provides native Telegram integration with DM allowlisting, the same as the OpenClaw version.

9. **Code-work concurrency** — The active code-work concurrency boundary is the configured Senior Dev handoff/runtime state. Normal Team Lead code tasks go through Senior Dev; older code-mutex or Senior Kanban review-queue references are historical unless a future approved design reintroduces a separate protected manual path.

## Current implementation status

See [docs/implementation-status.md](docs/implementation-status.md).

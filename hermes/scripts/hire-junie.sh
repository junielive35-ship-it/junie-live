#!/usr/bin/env bash
set -euo pipefail

# hire-junie.sh — Set up a Junie Live instance on Hermes Agent
#
# One command does everything: creates a Hermes profile, backs up any existing
# profile, installs SOUL.md / skills / docs / HERMES.seed.md / memory-seed.md /
# INITIALIZATION.md via Hermes profile distribution (cleanly replacing any prior
# distribution files of the same name while preserving runtime state like memory,
# sessions, and config), configures Telegram with DM restriction, creates state
# directories, installs and starts the gateway. Mirrors the OpenClaw
# hire-junie.sh experience.

usage() {
  cat <<'EOF'
Usage:
  hire-junie.sh --telegram-token TOKEN --admin-telegram-id ID [options]

Creates a Junie Live Hermes profile with Telegram gateway, installs the
distribution, and starts the gateway. After success, send /start to the bot.

Required:
  --telegram-token TOKEN      Telegram BotFather token for the Junie bot.
                              Can also be supplied as JUNIE_TELEGRAM_BOT_TOKEN.
  --admin-telegram-id ID      Telegram admin/user id allowed to DM the bot.

Options:
  --profile NAME              Hermes profile name. Default: junie-live
  --seed-dir DIR              Hermes profile distribution directory.
                              Default: hermes/distribution/.
  --model MODEL               Main model for the profile. Default: openai/gpt-5.5
                              (provider-relative ID; combined with --provider).
  --provider NAME             Inference provider for the profile. Default: openrouter
  --reasoning LEVEL            Reasoning effort for the model. Default: medium.
                              Allowed: none|minimal|low|medium|high|xhigh.
  --no-restart                Configure everything but do not start/restart gateway.
  --no-backup                 Skip the pre-hire backup (not recommended).
  --no-forward-keys           Do not forward LLM provider API keys from \$HERMES_HOME/.env into
                              the junie-live profile .env. By default, common provider keys
                              (OPENROUTER_API_KEY, ANTHROPIC_API_KEY, OPENAI_API_KEY, etc.) are
                              copied from the root .env so the profile can authenticate to the
                              configured model.
  --help                      Show this help.

After it succeeds, open the Junie bot in Telegram and send /start.
EOF
}

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

need_value() {
  local opt="$1" value="${2:-}"
  [[ -n "$value" && "$value" != --* ]] || { err "$opt requires a value"; exit 2; }
}

TOKEN="${JUNIE_TELEGRAM_BOT_TOKEN:-}"
ADMIN_TELEGRAM_ID=""
PROFILE="junie-live"
SEED_DIR=""
MODEL="openai/gpt-5.5"
PROVIDER="openrouter"
REASONING="medium"
RESTART=1
BACKUP=1
FORWARD_KEYS=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_VERSION_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --telegram-token) need_value "$1" "${2:-}"; TOKEN="$2"; shift 2 ;;
    --admin-telegram-id) need_value "$1" "${2:-}"; ADMIN_TELEGRAM_ID="$2"; shift 2 ;;
    --profile) need_value "$1" "${2:-}"; PROFILE="$2"; shift 2 ;;
    --seed-dir) need_value "$1" "${2:-}"; SEED_DIR="$2"; shift 2 ;;
    --model) need_value "$1" "${2:-}"; MODEL="$2"; shift 2 ;;
    --provider) need_value "$1" "${2:-}"; PROVIDER="$2"; shift 2 ;;
    --reasoning) need_value "$1" "${2:-}"; case "$2" in none|minimal|low|medium|high|xhigh) ;; *) err "invalid --reasoning value: $2 (allowed: none|minimal|low|medium|high|xhigh)"; usage; exit 2 ;; esac; REASONING="$2"; shift 2 ;;
    --no-restart) RESTART=0; shift ;;
    --no-backup) BACKUP=0; shift ;;
    --no-forward-keys) FORWARD_KEYS=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage; exit 2 ;;
  esac
done

if [[ -z "$SEED_DIR" || ! -d "$SEED_DIR" ]]; then
  # Default to the canonical distribution directory.
  # The --seed-dir option is preserved for backwards compatibility but the
  # canonical source is hermes/distribution/.
  SEED_DIR="$HERMES_VERSION_ROOT/distribution"
fi

log "Will use distribution directory: $SEED_DIR"

# ── Validation ──
[[ -n "$TOKEN" ]] || { err "missing --telegram-token or JUNIE_TELEGRAM_BOT_TOKEN"; exit 2; }
[[ -n "$ADMIN_TELEGRAM_ID" ]] || { err "missing required --admin-telegram-id"; exit 2; }
[[ -d "$SEED_DIR" ]] || { err "distribution directory not found: $SEED_DIR"; exit 1; }
[[ -f "$SEED_DIR/distribution.yaml" ]] || { err "distribution directory must contain distribution.yaml: $SEED_DIR"; exit 1; }
[[ -f "$SEED_DIR/INITIALIZATION.md" ]] || { err "distribution directory must contain INITIALIZATION.md: $SEED_DIR"; exit 1; }
if [[ -e "$SEED_DIR/BOOTSTRAP.md" ]]; then
  err "distribution directory must not contain BOOTSTRAP.md for Junie multi-round initialization: $SEED_DIR/BOOTSTRAP.md"
  exit 1
fi
command -v hermes >/dev/null || { err "hermes CLI not found in PATH"; exit 1; }
[[ "$BACKUP" -eq 1 ]] && { command -v tar >/dev/null || { err "tar not found in PATH (required for backup; pass --no-backup to skip)"; exit 1; }; }

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
PROFILE_DIR="$HERMES_HOME/profiles/$PROFILE"
STATE_DIR="$PROFILE_DIR/junie-live/state"
BACKUP_DIR="$HERMES_HOME/backups"

# ── Step 1: Back up any existing profile + state ──
if [[ "$BACKUP" -eq 1 ]]; then
  ts="$(date +%Y%m%d-%H%M%S)"
  items=()
  [[ -e "$PROFILE_DIR" ]] && items+=("profiles/$PROFILE")
  # Back up both old and new state locations for compatibility
  OLD_STATE="$HERMES_HOME/junie-live/state"
  [[ -e "$OLD_STATE" ]] && items+=("junie-live/state")
  [[ -e "$STATE_DIR" ]] && items+=("profiles/$PROFILE/junie-live/state")
  if [[ "${#items[@]}" -gt 0 ]]; then
    mkdir -p "$BACKUP_DIR"
    backup="$BACKUP_DIR/${PROFILE}-before-hire-$ts.tgz"
    tar -czf "$backup" -C "$HERMES_HOME" "${items[@]}"
    log "Backup: $backup"
  fi
fi

# ── Step 2: Create profile (or note it exists) ──
# Use `hermes profile show` to test existence (rc=0 if exists, rc=1 if not).
# Parsing `profile list` is fragile — the active profile gets a "◆" marker
# but inactive ones have no marker at all, so regex matching breaks for
# profiles created but never set as default.
log "Creating Hermes profile: $PROFILE"
if hermes profile show "$PROFILE" >/dev/null 2>&1; then
  log "Profile $PROFILE already exists — config and .env will be preserved; seed files, memory, sessions, and state will be reset for fresh initialization"
else
  hermes profile create "$PROFILE" --no-alias || { err "Failed to create profile $PROFILE"; exit 1; }
fi

# ── Step 3: Remove stale seed-owned paths, then install via Hermes-native distribution ──
# We surgically remove only the top-level paths that have ever belonged to the
# Junie seed. This guarantees stale seed files from earlier versions (e.g. an
# old persona.md that has since been renamed/removed) don't survive a re-hire.
# Runtime state (memories, sessions, state.db, cron, operational state) is
# cleared separately in Step 3b after the fresh seed is installed.
#
# After cleanup, profile assets are installed via Hermes-native profile
# distribution (hermes profile install) instead of manual cp -a.
#
# KEEP THIS LIST IN SYNC with the actual seed layout. Add historical names too
# so that re-hiring an old install reliably cleans them out.
SEED_OWNED_PATHS=(
  # Current distribution layout
  SOUL.md
  INITIALIZATION.md
  memory-seed.md
  HERMES.seed.md
  docs
  skills
  plugins
  scripts
  # Historical names — kept here so a re-hire over an older install cleans them
  persona.md
)
log "Removing prior seed entries (if any)..."
mkdir -p "$PROFILE_DIR"
seed_removed=0
for rel in "${SEED_OWNED_PATHS[@]}"; do
  target="$PROFILE_DIR/$rel"
  if [[ -e "$target" || -L "$target" ]]; then
    rm -rf -- "$target"
    seed_removed=$((seed_removed + 1))
  fi
done
log "  Removed $seed_removed prior seed entries"

log "Installing profile distribution..."
if [[ -d "$SEED_DIR" ]]; then
  hermes profile install "$SEED_DIR" --name "$PROFILE" --alias --force -y || {
    err "Failed to install profile from distribution: $SEED_DIR"
    exit 1
  }
  log "  Profile distribution installed from $SEED_DIR"
else
  err "Distribution directory not found: $SEED_DIR"
  exit 1
fi

# ── Step 3b: Clear runtime state that would contradict fresh initialization ──
# On re-hire the agent needs to re-initialize from scratch. Memory stores
# from a previous initialization carry "INITIALIZED" and project-specific
# context that would cause the agent to skip the initialization gate even
# though INITIALIZATION.md was just reinstalled. Sessions carry conversation
# history that reinforces the stale initialized state.
#
# The backup in Step 1 already preserved the old profile, so this is safe.
log "Clearing runtime state for fresh initialization..."
runtime_cleared=0

# Memory stores — the agent's persistent memory (MEMORY.md, USER.md).
# These are auto-injected into every turn. Stale "INITIALIZED" entries
# here directly conflict with the fresh INITIALIZATION.md.
if [[ -d "$PROFILE_DIR/memories" ]]; then
  rm -rf -- "$PROFILE_DIR/memories"
  runtime_cleared=$((runtime_cleared + 1))
  log "  Cleared: memories/"
fi

# Sessions and session database — past conversation context could make
# the agent believe it's already initialized. The backup preserves them.
if [[ -f "$PROFILE_DIR/state.db" ]]; then
  rm -f -- "$PROFILE_DIR/state.db" "$PROFILE_DIR/state.db-shm" "$PROFILE_DIR/state.db-wal"
  runtime_cleared=$((runtime_cleared + 1))
  log "  Cleared: state.db"
fi
if [[ -d "$PROFILE_DIR/sessions" ]]; then
  rm -rf -- "$PROFILE_DIR/sessions"
  runtime_cleared=$((runtime_cleared + 1))
  log "  Cleared: sessions/"
fi

# Junie-live operational state (backlog, mutex, reflections, overnight,
# logs) — stale state from a previous initialization.
# Clear both old and new state locations for compatibility.
OLD_STATE="$HERMES_HOME/junie-live/state"
if [[ -d "$OLD_STATE" ]]; then
  rm -rf -- "$OLD_STATE"
  runtime_cleared=$((runtime_cleared + 1))
  log "  Cleared: $OLD_STATE (legacy)"
fi
if [[ -d "$STATE_DIR" ]]; then
  rm -rf -- "$STATE_DIR"
  runtime_cleared=$((runtime_cleared + 1))
  log "  Cleared: $STATE_DIR"
fi

# Cron jobs — stale cron definitions from a previous initialization
# would fire against the old context.
if [[ -d "$PROFILE_DIR/cron" ]]; then
  rm -rf -- "$PROFILE_DIR/cron"
  runtime_cleared=$((runtime_cleared + 1))
  log "  Cleared: cron/"
fi

log "  Cleared $runtime_cleared runtime state entries"

# Post-copy sanity check (mirrors OpenClaw)
[[ -f "$PROFILE_DIR/INITIALIZATION.md" ]] || { err "copied profile missing INITIALIZATION.md: $PROFILE_DIR"; exit 1; }
if [[ -e "$PROFILE_DIR/BOOTSTRAP.md" ]]; then
  err "copied profile unexpectedly contains BOOTSTRAP.md: $PROFILE_DIR/BOOTSTRAP.md"
  exit 1
fi

# Verify the initialization sentinel files are in place
if [[ -f "$PROFILE_DIR/INITIALIZATION.md" ]]; then
  log "  INITIALIZATION.md sentinel present."
else
  err "INITIALIZATION.md missing after seed copy."
  exit 1
fi
if [[ -f "$PROFILE_DIR/docs/tools.md" ]]; then
  log "  docs/tools.md present (seed TODOs intact for agent to resolve)."
else
  err "docs/tools.md missing after seed copy."
  exit 1
fi

# ── Step 4: Install shared junie_runtime package ──
# junie_runtime is a shared Python package installed into the Hermes Python
# environment, not copied into the profile payload. The code-mutex.sh wrapper
# requires it.
RUNTIME_DIR="$HERMES_VERSION_ROOT/junie_runtime"
if [[ -d "$RUNTIME_DIR" ]]; then
  log "Installing junie_runtime package..."
  if python3 -m pip install -e "$RUNTIME_DIR" -q 2>/dev/null; then
    log "  junie_runtime installed from $RUNTIME_DIR"
  else
    err "Failed to install junie_runtime from $RUNTIME_DIR"
    exit 1
  fi
else
  err "junie_runtime directory not found: $RUNTIME_DIR"
  exit 1
fi

# ── Step 4b: Create state directories ──
log "Creating state directories..."
mkdir -p "$STATE_DIR"/{backlog/items,backlog/archive,reflections,overnight,logs}
mkdir -p "$STATE_DIR"/marinator/runs
mkdir -p "$STATE_DIR"/autonomous_work/windows

# ── Step 4c: Write runtime manifest ──
RUNTIME_MANIFEST_DIR="$PROFILE_DIR/junie-live/runtime"
mkdir -p "$RUNTIME_MANIFEST_DIR"
python3 "$HERMES_VERSION_ROOT/distribution/scripts/junie-runtime-artifact.py" write-install-manifest \
  --runtime-dir "$RUNTIME_DIR" \
  --repo-root "$HERMES_VERSION_ROOT" \
  --manifest-dir "$RUNTIME_MANIFEST_DIR" \
  --installed-python "python3"
log "  Package: junie-runtime, version: $(python3 "$HERMES_VERSION_ROOT/distribution/scripts/junie-runtime-artifact.py" read-manifest-field "$RUNTIME_MANIFEST_DIR/junie_runtime.json" version 2>/dev/null || echo 'unknown')"

# ── Plugin enable helper (preserves existing plugins.enabled) ──

# _ensure_plugin PROFILE_DIR PROFILE plugin_name
# Tries `plugins enable` first. Falls back to reading config.yaml,
# appending the plugin to plugins.enabled, and writing back via
# `config set` so other enabled plugins are preserved.
_ensure_plugin() {
  local profile_dir="$1"
  local profile="$2"
  local plugin_name="$3"

  if hermes -p "$profile" plugins enable "$plugin_name" >/dev/null 2>&1; then
    log "  Plugin '$plugin_name' enabled via 'plugins enable'"
    return 0
  fi

  local merged
  merged=$(PD="$profile_dir" PN="$plugin_name" python3 2>/dev/null <<'PYENSURE'
import json, os
config_file = os.path.join(os.environ['PD'], 'config.yaml')
plugin = os.environ['PN']
existing = []
if os.path.isfile(config_file):
    try:
        import yaml
        with open(config_file) as f:
            cfg = yaml.safe_load(f) or {}
        enabled = (cfg.get('plugins') or {}).get('enabled') or []
        existing = enabled if isinstance(enabled, list) else []
    except ImportError:
        pass
if plugin not in existing:
    existing.append(plugin)
print(json.dumps(existing))
PYENSURE
  ) || merged='["marinator-delegation","autonomous-work","'"$plugin_name"'"]'

  if hermes -p "$profile" config set plugins.enabled "$merged" >/dev/null 2>&1; then
    log "  Plugin '$plugin_name' enabled via config set fallback (preserving existing plugins)"
  else
    log "  WARNING: could not enable plugin '$plugin_name'; enable manually after hire"
  fi
}

# ── Step 4b: Enable Marinator delegation plugin + toolsets ──
# The plugin source was installed from distribution/plugins/ into
# $PROFILE_DIR/plugins/ during profile install. Now enable it and its
# toolsets for CLI and Telegram so marinator_delegate is available.
if [[ -d "$PROFILE_DIR/plugins/marinator-delegation" ]]; then
  log "Enabling Marinator delegation plugin..."
  _ensure_plugin "$PROFILE_DIR" "$PROFILE" "marinator-delegation"

  # Enable marinator toolset for CLI and Telegram
  for platform in cli telegram; do
    for toolset in marinator terminal file; do
      hermes -p "$PROFILE" tools enable --platform "$platform" "$toolset" >/dev/null 2>&1 || true
    done
  done
  log "  Toolsets enabled: marinator, terminal, file (cli + telegram)"
else
  log "  WARNING: plugins/marinator-delegation not found in seed; skipping plugin setup"
fi

# ── Step 4c: Enable Autonomous Work plugin + toolsets ──
if [[ -d "$PROFILE_DIR/plugins/autonomous-work" ]]; then
  log "Enabling Autonomous Work plugin..."
  _ensure_plugin "$PROFILE_DIR" "$PROFILE" "autonomous-work"

  for platform in cli telegram; do
    for toolset in autonomous marinator terminal file; do
      hermes -p "$PROFILE" tools enable --platform "$platform" "$toolset" >/dev/null 2>&1 || true
    done
  done
  log "  Toolsets enabled: autonomous, marinator, terminal, file (cli + telegram)"
else
  log "  WARNING: plugins/autonomous-work not found in seed; skipping plugin setup"
fi

# ═══════════════════════════════════════════════════════════════════
#  Step 5: Secrets / env — Telegram, provider keys, Slack tokens
# ═══════════════════════════════════════════════════════════════════
#
# Junie runs under its own Hermes profile, which loads ONLY
# $HERMES_HOME/profiles/<profile>/.env (not the root $HERMES_HOME/.env).
# So we copy credentials into the junie-live .env here.
#
# The Telegram home channel for a DM equals the user's Telegram ID, so we
# default it to the admin's ID — that makes cron deliveries land in the
# admin's DM automatically (no manual /sethome needed).
log "Configuring profile .env..."
PROFILE_ENV="$PROFILE_DIR/.env"
ROOT_ENV="$HERMES_HOME/.env"

# Provider API keys (and any other env vars) that should be forwarded from
# the root .env if present. Keep this list aligned with what Hermes treats
# as inference-provider credentials.
FORWARDABLE_KEYS=(
  OPENROUTER_API_KEY
  ANTHROPIC_API_KEY
  OPENAI_API_KEY
  GOOGLE_API_KEY
  GEMINI_API_KEY
  DEEPSEEK_API_KEY
  XAI_API_KEY
  GROQ_API_KEY
  MISTRAL_API_KEY
  HF_TOKEN
  GLM_API_KEY
  MINIMAX_API_KEY
  KIMI_API_KEY
  DASHSCOPE_API_KEY
  COPILOT_GITHUB_TOKEN
)

# Build the .env body
{
  echo "# Junie Live — auto-generated by hire-junie.sh"
  echo "TELEGRAM_BOT_TOKEN=$TOKEN"
  echo "TELEGRAM_ALLOWED_USERS=$ADMIN_TELEGRAM_ID"
  echo "TELEGRAM_ALLOW_ALL_USERS=false"
  echo "TELEGRAM_HOME_CHANNEL=$ADMIN_TELEGRAM_ID"
} > "$PROFILE_ENV"

forwarded_count=0
forwarded_names=()
if [[ "$FORWARD_KEYS" -eq 1 && -f "$ROOT_ENV" ]]; then
  echo "" >> "$PROFILE_ENV"
  echo "# Forwarded from $ROOT_ENV by hire-junie.sh" >> "$PROFILE_ENV"
  for key in "${FORWARDABLE_KEYS[@]}"; do
    # Match KEY=VALUE at start of line, ignore commented lines and empty values.
    # Use grep -m1 to take the last-wins semantics that .env-style parsers use
    # (actually first match here — Hermes's dotenv loader takes the first too).
    line="$(grep -E "^${key}=." "$ROOT_ENV" | head -n1 || true)"
    if [[ -n "$line" ]]; then
      echo "$line" >> "$PROFILE_ENV"
      forwarded_count=$((forwarded_count + 1))
      forwarded_names+=("$key")
    fi
  done
fi

# ── Slack tokens from ~/slack-tokens ──
SLACK_TOKENS_SOURCE="$(getent passwd "$(id -u)" | cut -d: -f6)/slack-tokens"
if [[ -f "$SLACK_TOKENS_SOURCE" ]]; then
  SLACK_FORWARDABLE_KEYS=(
    SLACK_BOT_TOKEN
    SLACK_APP_TOKEN
    SLACK_ALLOWED_USERS
    SLACK_ALLOW_ALL_USERS
    SLACK_HOME_CHANNEL
    SLACK_HOME_CHANNEL_NAME
    SLACK_ALLOWED_CHANNELS
  )
  slack_count=0
  slack_names=()
  echo "" >> "$PROFILE_ENV"
  echo "# Slack tokens from $SLACK_TOKENS_SOURCE" >> "$PROFILE_ENV"
  for key in "${SLACK_FORWARDABLE_KEYS[@]}"; do
    line="$(grep -E "^${key}=." "$SLACK_TOKENS_SOURCE" | head -n1 || true)"
    if [[ -n "$line" ]]; then
      echo "$line" >> "$PROFILE_ENV"
      slack_count=$((slack_count + 1))
      slack_names+=("$key")
    fi
  done
  if [[ "$slack_count" -gt 0 ]]; then
    log "  Forwarded $slack_count Slack credential(s) from $SLACK_TOKENS_SOURCE: ${slack_names[*]}"
  fi
fi

log "  Telegram configured (DM restricted to admin $ADMIN_TELEGRAM_ID; home channel set to admin DM)"
if [[ "$forwarded_count" -gt 0 ]]; then
  log "  Forwarded $forwarded_count provider key(s) from root .env: ${forwarded_names[*]}"
elif [[ "$FORWARD_KEYS" -eq 1 ]]; then
  log "  No provider keys found in $ROOT_ENV to forward."
  log "  WARNING: junie-live profile has no LLM credentials. Set one via:"
  log "    hermes -p $PROFILE setup           # interactive"
  log "    echo 'OPENROUTER_API_KEY=...' >> $PROFILE_ENV"
fi

# ── Step 6: Set model + provider + reasoning effort in profile config ──
log "Setting model: $MODEL (provider: $PROVIDER, reasoning: $REASONING)"
hermes -p "$PROFILE" config set model.default "$MODEL" 2>/dev/null || true
hermes -p "$PROFILE" config set model.provider "$PROVIDER" 2>/dev/null || true
hermes -p "$PROFILE" config set agent.reasoning_effort "$REASONING" 2>/dev/null || true

# ── Step 6b: Configure /start → initialization turn quick command alias ──
# Maps /start to a normal agent turn so the "send /start to the bot"
# instruction starts Junie initialization immediately. /new only resets the
# session and returns the gateway banner; it does not run SOUL.md / INITIALIZATION.md.
# Uses direct config.yaml editing (preferred) with hermes CLI fallback.
START_ALIAS_TARGET="/steer Start Junie Live initialization now. Follow the initialization gate: greet the owner, briefly introduce yourself in a couple of sentences, then ask the two initialization questions."
log "Configuring /start → initialization quick command alias..."
_ensure_quick_start_alias() {
  local profile_dir="$1"
  local profile="$2"
  local target="$3"

  local ok
  ok=$(PD="$profile_dir" START_ALIAS_TARGET="$target" python3 2>/dev/null <<'PYQC'
import os, sys
cf = os.path.join(os.environ['PD'], 'config.yaml')
target = os.environ['START_ALIAS_TARGET']
try:
    import yaml
except ImportError:
    sys.exit(2)
cfg = {}
if os.path.isfile(cf):
    with open(cf) as f:
        cfg = yaml.safe_load(f) or {}
qc = cfg.setdefault('quick_commands', {})
st = qc.setdefault('start', {})
st['type'] = 'alias'
st['target'] = target
with open(cf, 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False, sort_keys=False)
print('OK')
PYQC
  ) || ok=""

  if [[ "$ok" == "OK" ]]; then
    log "  /start → initialization quick command alias configured in config.yaml"
    return 0
  fi

  # Fallback: try hermes CLI
  if hermes -p "$profile" config set quick_commands.start.type alias 2>/dev/null && \
     hermes -p "$profile" config set quick_commands.start.target "$target" 2>/dev/null; then
    log "  /start → initialization quick command alias configured via hermes (fallback)"
    return 0
  fi

  log "  WARNING: could not configure /start quick command alias"
  log "  Add it manually after hire:"
  log "    hermes -p $profile config set quick_commands.start.type alias"
  log "    hermes -p $profile config set quick_commands.start.target '$target'"
  log "    hermes -p $profile gateway restart"
  return 1
}
_ensure_quick_start_alias "$PROFILE_DIR" "$PROFILE" "$START_ALIAS_TARGET"

# ── Step 7: Install and start gateway (Ubuntu / Linux + systemd) ──
# `hermes gateway install` asks two yes/no questions on Linux (start now?
# start on login?). Both default to yes, so we feed two newlines via stdin
# and the install proceeds non-interactively. Whole thing is wrapped in
# `timeout` so the script fails fast instead of hanging.
if [[ "$RESTART" -eq 1 ]]; then
  log "Installing gateway as a user systemd service..."

  install_log="$(mktemp)"
  trap 'rm -f "$install_log"' EXIT

  if timeout 120s bash -c "printf '\n\n' | hermes -p '$PROFILE' gateway install --force" >"$install_log" 2>&1; then
    log "  Gateway service installed."
    grep -E '^(✓|↻|Installing|Service)' "$install_log" | sed 's/^/    /' || true
  else
    rc=$?
    err "gateway install failed (rc=$rc). Output:"
    sed 's/^/  /' "$install_log" >&2
    log ""
    log "Recover with one of:"
    log "  hermes -p $PROFILE gateway install         # interactive"
    log "  hermes -p $PROFILE gateway run             # foreground"
    exit 1
  fi

  # `gateway install` with start_now=Y already started the service.
  # Force a restart so a re-hire over an already-installed unit reloads
  # the new .env / config without manual intervention.
  log "Restarting gateway to pick up new configuration..."
  if timeout 60s hermes -p "$PROFILE" gateway restart >/dev/null 2>&1; then
    log "  Gateway restarted."
  else
    log "  Note: restart did not complete; checking status..."
    hermes -p "$PROFILE" gateway status 2>&1 | sed 's/^/    /' | head -10 || true
  fi
fi

# ── Done ──
log ""
log "Junie Live hiring complete."
log "Profile:          $PROFILE"
log "Profile dir:      $PROFILE_DIR"
log "State dir:        $STATE_DIR"
[[ "$BACKUP" -eq 1 && -n "${backup:-}" ]] && log "Backup:           $backup"
log "Telegram admin:   $ADMIN_TELEGRAM_ID"
log "Model:            $MODEL (provider: $PROVIDER, reasoning: $REASONING)"
log ""
log "Next: open the Junie bot in Telegram and send /start."

#!/usr/bin/env bash
set -euo pipefail

# hire-junie.sh — Set up a Junie Live instance on Hermes Agent
#
# One command does everything: backs up any existing profile, deletes it via
# Hermes-native profile delete, then installs a fresh profile from the
# distribution (SOUL.md / skills / docs / HERMES.seed.md / memory-seed.md /
# INITIALIZATION.md), configures Telegram with DM restriction, creates state
# directories, installs the shared runtime package, enables plugins, configures
# model/provider/reasoning, installs and starts the gateway.

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
# ── Early: install/check junie_runtime before any profile ops ──
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

# ── Step 1: Back up any existing profile via dump-junie.sh ──
if [[ "$BACKUP" -eq 1 ]]; then
  if hermes profile show "$PROFILE" >/dev/null 2>&1; then
    backup="$(python3 -m junie_runtime.paths backup-path --profile "$PROFILE" --kind before-hire)"
    mkdir -p "$(dirname "$backup")"
    log "Creating pre-hire backup via dump-junie.sh..."
    "$HERMES_VERSION_ROOT/distribution/scripts/dump-junie.sh" --profile "$PROFILE" --output "$backup" >/dev/null || {
      err "Backup via dump-junie.sh failed"
      exit 1
    }
    log "Backup: $backup"
  else
    log "Profile $PROFILE does not exist — skipping backup"
  fi
fi

# ── Step 2: Delete existing profile if present ──
# Use `hermes profile show` to test existence (rc=0 if exists, rc=1 if not).
# If the profile exists, delete it via Hermes-native profile delete, which
# removes config, API keys, memories, sessions, skills, cron jobs, state,
# and alias/service references in one step. Backup was done in Step 1.
if hermes profile show "$PROFILE" >/dev/null 2>&1; then
  log "Profile $PROFILE exists — deleting for fresh reinstall"
  hermes profile delete "$PROFILE" -y || { err "Failed to delete profile $PROFILE"; exit 1; }
  log "  Profile $PROFILE deleted"
else
  log "Profile $PROFILE does not exist — will install fresh"
fi

# ── Step 3: Install via Hermes-native profile distribution ──
# Hermes-native profile install creates the profile and installs all
# distribution assets (SOUL.md, INITIALIZATION.md, skills, docs, plugins,
# scripts, etc.) in one step. No manual cleanup is needed because either
# the profile was just deleted (native delete handles it) or it didn't
# exist.
log "Installing profile distribution..."
if [[ -d "$SEED_DIR" ]]; then
  hermes profile install "$SEED_DIR" --name "$PROFILE" --alias -y || {
    err "Failed to install profile from distribution: $SEED_DIR"
    exit 1
  }
  log "  Profile distribution installed from $SEED_DIR"
else
  err "Distribution directory not found: $SEED_DIR"
  exit 1
fi

# Post-install sanity checks
PROFILE_DIR="$(python3 -m junie_runtime.paths profile-dir --profile "$PROFILE")"
[[ -f "$PROFILE_DIR/INITIALIZATION.md" ]] || { err "installed profile missing INITIALIZATION.md: $PROFILE_DIR"; exit 1; }
if [[ -e "$PROFILE_DIR/BOOTSTRAP.md" ]]; then
  err "installed profile unexpectedly contains BOOTSTRAP.md: $PROFILE_DIR/BOOTSTRAP.md"
  exit 1
fi

# Verify the initialization sentinel files are in place
if [[ -f "$PROFILE_DIR/INITIALIZATION.md" ]]; then
  log "  INITIALIZATION.md sentinel present."
else
  err "INITIALIZATION.md missing after install."
  exit 1
fi
if [[ -f "$PROFILE_DIR/docs/tools.md" ]]; then
  log "  docs/tools.md present (seed TODOs intact for agent to resolve)."
else
  err "docs/tools.md missing after install."
  exit 1
fi

# ── Step 4b: Create state directories ──
STATE_DIR="$(python3 -m junie_runtime.paths state-root --profile "$PROFILE")"
log "Creating state directories..."
mkdir -p "$STATE_DIR"/{backlog/items,backlog/archive,reflections,overnight,logs}
mkdir -p "$STATE_DIR"/marinator/runs
mkdir -p "$STATE_DIR"/autonomous_work/windows

# ── Step 4c: Write runtime manifest ──
RUNTIME_MANIFEST_DIR="$(python3 -m junie_runtime.paths runtime-manifest-dir --profile "$PROFILE")"
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

# ── Step 4b: Enable Marinator delegation plugin without Chat Agent toolset ──
# The plugin source was installed from distribution/plugins/ into
# $PROFILE_DIR/plugins/ during profile install. Keep the plugin source and
# enabled plugin available for the companion senior-dev profile/install path,
# but do not expose the marinator toolset to the main Chat Agent.
if [[ -d "$PROFILE_DIR/plugins/marinator-delegation" ]]; then
  log "Enabling Marinator delegation plugin..."
  _ensure_plugin "$PROFILE_DIR" "$PROFILE" "marinator-delegation"

  for platform in cli telegram; do
    hermes -p "$PROFILE" tools disable --platform "$platform" marinator >/dev/null 2>&1 || true
  done

  for platform in cli telegram; do
    for toolset in terminal file; do
      hermes -p "$PROFILE" tools enable --platform "$platform" "$toolset" >/dev/null 2>&1 || true
    done
  done
  log "  Toolsets enabled: terminal, file (cli + telegram); marinator remains senior-dev only"
else
  log "  WARNING: plugins/marinator-delegation not found in seed; skipping plugin setup"
fi

# ── Step 4c: Enable Autonomous Work plugin + toolsets ──
if [[ -d "$PROFILE_DIR/plugins/autonomous-work" ]]; then
  log "Enabling Autonomous Work plugin..."
  _ensure_plugin "$PROFILE_DIR" "$PROFILE" "autonomous-work"

  for platform in cli telegram; do
    for toolset in autonomous terminal file; do
      hermes -p "$PROFILE" tools enable --platform "$platform" "$toolset" >/dev/null 2>&1 || true
    done
  done
  log "  Toolsets enabled: autonomous, terminal, file (cli + telegram)"
else
  log "  WARNING: plugins/autonomous-work not found in seed; skipping plugin setup"
fi

# ── Step 4d: Enable Senior Task plugin + toolsets ──
if [[ -d "$PROFILE_DIR/plugins/senior-task" ]]; then
  log "Enabling Senior Task plugin..."
  _ensure_plugin "$PROFILE_DIR" "$PROFILE" "senior-task"

  for platform in cli telegram; do
    for toolset in senior terminal file; do
      hermes -p "$PROFILE" tools enable --platform "$platform" "$toolset" >/dev/null 2>&1 || true
    done
  done
  log "  Toolsets enabled: senior, terminal, file (cli + telegram)"
else
  log "  WARNING: plugins/senior-task not found in seed; skipping plugin setup"
fi

# ── Step 4e: Install senior-dev profile for Kanban-backed code execution ──
if [[ -f "$SCRIPT_DIR/install-senior-dev-profile.sh" ]]; then
  log "Installing senior-dev profile..."
  if "$SCRIPT_DIR/install-senior-dev-profile.sh" --force; then
    log "  senior-dev profile installed."
  else
    err "Failed to install senior-dev profile"
    exit 1
  fi
else
  log "  WARNING: install-senior-dev-profile.sh not found — senior-dev profile not installed"
  log "  Senior Kanban pipeline will be incomplete without it."
fi

# ═══════════════════════════════════════════════════════════════════
#  Step 5: Secrets / env — Telegram, provider keys, Slack tokens
# ═══════════════════════════════════════════════════════════════════
#
# Junie runs under its own Hermes profile, which loads ONLY
# $HERMES_ROOT/profiles/<profile>/.env (not the root $HERMES_ROOT/.env).
# So we copy credentials into the junie-live .env here.
#
# The Telegram home channel for a DM equals the user's Telegram ID, so we
# default it to the admin's ID — that makes cron deliveries land in the
# admin's DM automatically (no manual /sethome needed).
log "Configuring profile .env..."
PROFILE_ENV="$PROFILE_DIR/.env"
HERMES_ROOT="$(python3 -m junie_runtime.paths hermes-root --profile "$PROFILE")"
ROOT_ENV="$HERMES_ROOT/.env"

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

# ── Step 6: Set model + provider + reasoning effort + approvals in profile config ──
log "Setting model: $MODEL (provider: $PROVIDER, reasoning: $REASONING)"
hermes -p "$PROFILE" config set model.default "$MODEL" 2>/dev/null || true
hermes -p "$PROFILE" config set model.provider "$PROVIDER" 2>/dev/null || true
hermes -p "$PROFILE" config set agent.reasoning_effort "$REASONING" 2>/dev/null || true

# Bypass dangerous-command approval prompts during Junie initialization/finalization.
# Hermes hardline blocklist rules still apply; only approvable prompts are skipped.
hermes -p "$PROFILE" config set approvals.mode off 2>/dev/null || true
hermes -p "$PROFILE" config set approvals.destructive_slash_confirm false 2>/dev/null || true
log "  approvals.mode set to off (Junie internal ops skip owner approval prompts)"

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

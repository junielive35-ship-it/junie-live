#!/usr/bin/env bash
set -euo pipefail

# hire-junie.sh — Set up a Junie Live instance on Hermes Agent
#
# One command does everything: creates a Hermes profile, backs up any existing
# profile, installs SOUL.md / skills / docs / seed-HERMES.md / memory-seed.md /
# INITIALIZATION.md (cleanly replacing any prior seed files of the same name
# while preserving runtime state like memory, sessions, and config), configures
# Telegram with DM restriction, creates state directories, installs and starts
# the gateway. Mirrors the OpenClaw hire-junie.sh experience.

usage() {
  cat <<'EOF'
Usage:
  hire-junie.sh --telegram-token TOKEN --admin-telegram-id ID [options]

Creates a Junie Live Hermes profile with Telegram gateway, installs all
seed files, and starts the gateway. After success, send /start to the bot.

Required:
  --telegram-token TOKEN      Telegram BotFather token for the Junie bot.
                              Can also be supplied as JUNIE_TELEGRAM_BOT_TOKEN.
  --admin-telegram-id ID      Telegram admin/user id allowed to DM the bot.

Options:
  --profile NAME              Hermes profile name. Default: junie-live
  --seed-dir DIR              Junie seed dir. Default: auto-detected from script location.
  --model MODEL               Main model for the profile. Default: openrouter/anthropic/claude-opus-4.6
  --no-restart                Configure everything but do not start/restart gateway.
  --no-backup                 Skip the pre-hire backup (not recommended).
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
MODEL="openrouter/anthropic/claude-opus-4.6"
RESTART=1
BACKUP=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_VERSION_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --telegram-token) need_value "$1" "${2:-}"; TOKEN="$2"; shift 2 ;;
    --admin-telegram-id) need_value "$1" "${2:-}"; ADMIN_TELEGRAM_ID="$2"; shift 2 ;;
    --profile) need_value "$1" "${2:-}"; PROFILE="$2"; shift 2 ;;
    --seed-dir) need_value "$1" "${2:-}"; SEED_DIR="$2"; shift 2 ;;
    --model) need_value "$1" "${2:-}"; MODEL="$2"; shift 2 ;;
    --no-restart) RESTART=0; shift ;;
    --no-backup) BACKUP=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage; exit 2 ;;
  esac
done

if [[ -z "$SEED_DIR" || ! -d "$SEED_DIR" ]]; then
  SEED_DIR="$HERMES_VERSION_ROOT/initialization"
fi

log "Will use $SEED_DIR as directory with seed files for Junie Live initialization"

# ── Validation ──
[[ -n "$TOKEN" ]] || { err "missing --telegram-token or JUNIE_TELEGRAM_BOT_TOKEN"; exit 2; }
[[ -n "$ADMIN_TELEGRAM_ID" ]] || { err "missing required --admin-telegram-id"; exit 2; }
[[ -d "$SEED_DIR" ]] || { err "seed dir not found: $SEED_DIR"; exit 1; }
[[ -f "$SEED_DIR/INITIALIZATION.md" ]] || { err "seed dir must contain INITIALIZATION.md: $SEED_DIR"; exit 1; }
if [[ -e "$SEED_DIR/BOOTSTRAP.md" ]]; then
  err "seed dir must not contain BOOTSTRAP.md for Junie multi-round initialization: $SEED_DIR/BOOTSTRAP.md"
  exit 1
fi
command -v hermes >/dev/null || { err "hermes CLI not found in PATH"; exit 1; }
[[ "$BACKUP" -eq 1 ]] && { command -v tar >/dev/null || { err "tar not found in PATH (required for backup; pass --no-backup to skip)"; exit 1; }; }

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
PROFILE_DIR="$HERMES_HOME/profiles/$PROFILE"
STATE_DIR="$HERMES_HOME/junie-live/state"
BACKUP_DIR="$HERMES_HOME/backups"

# ── Step 1: Back up any existing profile + state ──
if [[ "$BACKUP" -eq 1 ]]; then
  ts="$(date +%Y%m%d-%H%M%S)"
  items=()
  [[ -e "$PROFILE_DIR" ]] && items+=("profiles/$PROFILE")
  [[ -e "$STATE_DIR" ]] && items+=("junie-live/state")
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
  log "Profile $PROFILE already exists — runtime state (memory, sessions, config, .env) will be preserved; seed files will be replaced cleanly"
else
  hermes profile create "$PROFILE" --no-alias || { err "Failed to create profile $PROFILE"; exit 1; }
fi

# ── Step 3: Remove previously-installed seed files, then copy fresh seed ──
# We surgically remove only the top-level paths that have ever belonged to the
# Junie seed. This guarantees stale seed files from earlier versions (e.g. an
# old persona.md that has since been renamed/removed) don't survive a re-hire,
# while leaving runtime state (memories/, sessions/, state.db, config.yaml,
# .env, logs/, anything else not in this list) untouched.
#
# KEEP THIS LIST IN SYNC with the actual seed layout. Add historical names too
# so that re-hiring an old install reliably cleans them out.
SEED_OWNED_PATHS=(
  # Current seed (initialization/* top-level entries)
  SOUL.md
  INITIALIZATION.md
  memory-seed.md
  docs
  skills
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

log "Installing seed files..."
cp -a "$SEED_DIR/." "$PROFILE_DIR/"
log "  Copied: SOUL.md, INITIALIZATION.md, memory-seed.md, skills, docs (incl. seed-HERMES.md)"

# Post-copy sanity check (mirrors OpenClaw)
[[ -f "$PROFILE_DIR/INITIALIZATION.md" ]] || { err "copied profile missing INITIALIZATION.md: $PROFILE_DIR"; exit 1; }
if [[ -e "$PROFILE_DIR/BOOTSTRAP.md" ]]; then
  err "copied profile unexpectedly contains BOOTSTRAP.md: $PROFILE_DIR/BOOTSTRAP.md"
  exit 1
fi

# ── Step 4: Create state directories ──
log "Creating state directories..."
mkdir -p "$STATE_DIR"/{backlog/items,reflections,overnight,logs}

# ── Step 5: Configure Telegram + model in profile .env ──
log "Configuring profile .env..."
PROFILE_ENV="$PROFILE_DIR/.env"
cat > "$PROFILE_ENV" <<ENV
# Junie Live — auto-generated by hire-junie.sh
TELEGRAM_BOT_TOKEN=$TOKEN
TELEGRAM_ALLOWED_USERS=$ADMIN_TELEGRAM_ID
TELEGRAM_ALLOW_ALL_USERS=false
ENV
log "  Telegram configured (DM restricted to admin $ADMIN_TELEGRAM_ID)"

# ── Step 6: Set model in profile config ──
log "Setting model: $MODEL"
hermes -p "$PROFILE" config set model.default "$MODEL" 2>/dev/null || true

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
log "Model:            $MODEL"
log ""
log "Next: open the Junie bot in Telegram and send /start."

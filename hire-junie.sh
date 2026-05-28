#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF_USAGE'
Usage:
  hire-junie.sh --telegram-token TOKEN --admin-telegram-id ID [options]

Creates or replaces a Junie Live OpenClaw agent workspace, configures a Telegram
bot account for it, allowlists the admin Telegram id, approves pending local
device scope upgrades when possible, restarts the Gateway, and prints next steps.

Required:
  --telegram-token TOKEN      Telegram BotFather token for the Junie bot.
                              Can also be supplied as JUNIE_TELEGRAM_BOT_TOKEN.
  --admin-telegram-id ID      Telegram admin/user id allowed to DM the bot.

Options:
  --agent-id ID               OpenClaw agent id. Default: junie-live
  --workspace DIR             Agent workspace dir. Default: ~/.openclaw/workspace-junie-live
  --seed-dir DIR              Junie seed dir. Default: ./initialization
  --model MODEL               OpenClaw model id. Default: openrouter/openai/gpt-5.5
  --no-restart                Configure everything but do not restart Gateway.
  --help                      Show this help.

By default this script backs up and replaces existing Junie state, then reseeds
from the seed dir. After it succeeds, open the Junie bot in Telegram and send
/start. Junie should continue initialization from Telegram using INITIALIZATION.md.
EOF_USAGE
}

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

need_value() {
  local opt="$1"
  local value="${2:-}"
  [[ -n "$value" && "$value" != --* ]] || { err "$opt requires a value"; exit 2; }
}

expand_path() {
  local p="$1"
  case "$p" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s/%s\n' "$HOME" "${p#~/}" ;;
    *) printf '%s\n' "$p" ;;
  esac
}

TOKEN="${JUNIE_TELEGRAM_BOT_TOKEN:-}"
ADMIN_TELEGRAM_ID=""
AGENT_ID="junie-live"
WORKSPACE="$HOME/.openclaw/workspace-junie-live"
SEED_DIR="./initialization"
MODEL="openrouter/openai/gpt-5.5"
RESTART=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --telegram-token)
      need_value "$1" "${2:-}"; TOKEN="$2"; shift 2 ;;
    --admin-telegram-id)
      need_value "$1" "${2:-}"; ADMIN_TELEGRAM_ID="$2"; shift 2 ;;
    --agent-id)
      need_value "$1" "${2:-}"; AGENT_ID="$2"; shift 2 ;;
    --workspace)
      need_value "$1" "${2:-}"; WORKSPACE="$2"; shift 2 ;;
    --seed-dir)
      need_value "$1" "${2:-}"; SEED_DIR="$2"; shift 2 ;;
    --model)
      need_value "$1" "${2:-}"; MODEL="$2"; shift 2 ;;
    --no-restart)
      RESTART=0; shift ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      err "unknown argument: $1"; usage; exit 2 ;;
  esac
done

TELEGRAM_ACCOUNT="$AGENT_ID"
WORKSPACE="$(expand_path "$WORKSPACE")"
SEED_DIR="$(expand_path "$SEED_DIR")"
BACKUP_DIR="$HOME/.openclaw/backups"
AGENT_STATE_DIR="$HOME/.openclaw/agents/$AGENT_ID"

[[ -n "$TOKEN" ]] || { err "missing --telegram-token or JUNIE_TELEGRAM_BOT_TOKEN"; exit 2; }
[[ -n "$ADMIN_TELEGRAM_ID" ]] || { err "missing required --admin-telegram-id"; exit 2; }
[[ -d "$SEED_DIR" ]] || { err "seed dir not found: $SEED_DIR"; exit 1; }
[[ -f "$SEED_DIR/INITIALIZATION.md" ]] || { err "seed dir must contain INITIALIZATION.md: $SEED_DIR"; exit 1; }
if [[ -e "$SEED_DIR/BOOTSTRAP.md" ]]; then
  err "seed dir must not contain BOOTSTRAP.md for Junie multi-round initialization: $SEED_DIR/BOOTSTRAP.md"
  exit 1
fi
command -v openclaw >/dev/null || { err "openclaw CLI not found in PATH"; exit 1; }
command -v tar >/dev/null || { err "tar not found in PATH"; exit 1; }

existing=0
if openclaw agents list 2>/dev/null | grep -qE "^- ${AGENT_ID}( |$)"; then existing=1; fi

mkdir -p "$BACKUP_DIR"
ts="$(date +%Y%m%d-%H%M%S)"
items=()
[[ -e "$WORKSPACE" ]] && items+=("${WORKSPACE#$HOME/.openclaw/}")
[[ -e "$AGENT_STATE_DIR" ]] && items+=("agents/$AGENT_ID")
if [[ "${#items[@]}" -gt 0 ]]; then
  backup="$BACKUP_DIR/${AGENT_ID}-before-hire-$ts.tgz"
  tar -czf "$backup" -C "$HOME/.openclaw" "${items[@]}"
  log "Backup: $backup"
fi

if [[ "$existing" -eq 1 ]]; then
  openclaw agents delete "$AGENT_ID" --force || true
fi

rm -rf "$WORKSPACE" "$AGENT_STATE_DIR"
mkdir -p "$WORKSPACE"
cp -a "$SEED_DIR/." "$WORKSPACE/"

[[ -f "$WORKSPACE/INITIALIZATION.md" ]] || { err "copied workspace missing INITIALIZATION.md: $WORKSPACE"; exit 1; }
if [[ -e "$WORKSPACE/BOOTSTRAP.md" ]]; then
  err "copied workspace unexpectedly contains BOOTSTRAP.md: $WORKSPACE/BOOTSTRAP.md"
  exit 1
fi

openclaw agents add "$AGENT_ID" \
  --workspace "$WORKSPACE" \
  --model "$MODEL" \
  --non-interactive

openclaw channels add \
  --channel telegram \
  --account "$TELEGRAM_ACCOUNT" \
  --token "$TOKEN"

patch_file="$(mktemp)"
trap 'rm -f "$patch_file"' EXIT
cat >"$patch_file" <<JSON
{
  channels: {
    telegram: {
      accounts: {
        "$TELEGRAM_ACCOUNT": {
          dmPolicy: "allowlist",
          allowFrom: ["$ADMIN_TELEGRAM_ID"]
        }
      }
    }
  }
}
JSON
openclaw config patch --file "$patch_file"

openclaw agents bind \
  --agent "$AGENT_ID" \
  --bind "telegram:$TELEGRAM_ACCOUNT"

if ! approve_output="$(openclaw devices approve --latest 2>&1)"; then
  printf '%s\n' "$approve_output" >&2
  exact_cmd="$(printf '%s\n' "$approve_output" | sed -n 's/^Approve this exact request with: //p' | tail -1)"
  if [[ -n "$exact_cmd" ]]; then
    log "Trying exact approval command requested by OpenClaw..."
    $exact_cmd || true
  fi
fi

if [[ "$RESTART" -eq 1 ]]; then
  openclaw gateway restart || {
    err "gateway restart failed; run openclaw status for details"
    exit 1
  }
  openclaw channels status --probe || true
fi

log ""
log "Junie hiring configured."
log "Agent:            $AGENT_ID"
log "Workspace:        $WORKSPACE"
log "Telegram account: $TELEGRAM_ACCOUNT"
log "Allowed admin id: $ADMIN_TELEGRAM_ID"
log ""
log "Next: open the Junie bot in Telegram and send /start."

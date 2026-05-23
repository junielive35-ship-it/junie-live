#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  hire-junie.sh --telegram-token TOKEN [options]

Creates/reseeds a Junie Live OpenClaw agent workspace, configures a Telegram bot
account for it, binds that account to the agent, approves pending local device
scope upgrades when possible, restarts the Gateway, and prints verification.

Options:
  --telegram-token TOKEN      Telegram BotFather token for the Junie bot.
                              Can also be supplied as JUNIE_TELEGRAM_BOT_TOKEN.
  --admin-telegram-id ID      Telegram admin/user id allowed to DM the bot.
  --agent-id ID               OpenClaw agent id. Default: junie-live
  --telegram-account ID       OpenClaw Telegram account id. Default: same as agent id
  --workspace DIR             Agent workspace dir. Default: ~/.openclaw/workspace-junie-live
  --seed-dir DIR              Junie seed dir. Default: `.`
  --model MODEL               OpenClaw model id. Default: openrouter/openai/gpt-5.5
  --no-reseed                 Do not delete/re-copy workspace if it already exists.
  --override                  Replace existing agent/workspace if present.
  --force                     Alias for --override.
  --no-restart                Configure everything but do not restart Gateway.
  --help                      Show this help.

After this script succeeds, open the Junie bot in Telegram and send /start.
Junie should continue initialization from Telegram using INITIALIZATION.md.
EOF
}

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

expand_path() {
  local p="$1"
  case "$p" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s/%s\n' "$HOME" "${p#~/}" ;;
    *) printf '%s\n' "$p" ;;
  esac
}

TOKEN="${JUNIE_TELEGRAM_BOT_TOKEN:-}"
AGENT_ID="junie-live"
TELEGRAM_ACCOUNT=""
WORKSPACE="~/.openclaw/workspace-junie-live"
SEED_DIR="."
MODEL="openrouter/openai/gpt-5.5"
RESEED=1
OVERRIDE=0
RESTART=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --telegram-token)
      TOKEN="${2:-}"; shift 2 ;;
    --admin-telegram-id)
      ADMIN_TELEGRAM_ID="${2:-}"; shift 2 ;;
    --agent-id)
      AGENT_ID="${2:-}"; shift 2 ;;
    --telegram-account)
      TELEGRAM_ACCOUNT="${2:-}"; shift 2 ;;
    --workspace)
      WORKSPACE="${2:-}"; shift 2 ;;
    --seed-dir)
      SEED_DIR="${2:-}"; shift 2 ;;
    --model)
      MODEL="${2:-}"; shift 2 ;;
    --no-reseed)
      RESEED=0; shift ;;
    --override|--force)
      OVERRIDE=1; shift ;;
    --no-restart)
      RESTART=0; shift ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      err "unknown argument: $1"; usage; exit 2 ;;
  esac
done

TELEGRAM_ACCOUNT="${TELEGRAM_ACCOUNT:-$AGENT_ID}"
WORKSPACE="$(expand_path "$WORKSPACE")"
SEED_DIR="$(expand_path "$SEED_DIR")"
BACKUP_DIR="$HOME/.openclaw/backups"
AGENT_STATE_DIR="$HOME/.openclaw/agents/$AGENT_ID"

[[ -n "$TOKEN" ]] || { err "missing --telegram-token or JUNIE_TELEGRAM_BOT_TOKEN"; exit 2; }
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
if [[ -e "$WORKSPACE" || -e "$AGENT_STATE_DIR" || "$existing" -eq 1 ]]; then
  if [[ "$OVERRIDE" -ne 1 ]]; then
    cat >&2 <<EOF
This will replace existing Junie state if present:
  agent:     $AGENT_ID
  workspace: $WORKSPACE
  state dir: $AGENT_STATE_DIR

Re-run with --override to proceed.
EOF
    exit 2
  fi
fi

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

if [[ "$RESEED" -eq 1 ]]; then
  rm -rf "$WORKSPACE" "$AGENT_STATE_DIR"
  mkdir -p "$WORKSPACE"
  cp -a "$SEED_DIR/." "$WORKSPACE/"
else
  mkdir -p "$WORKSPACE"
fi

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

# Restrict the Telegram account to the admin id. The token is deliberately not
# written into this patch; channels add already stored it in OpenClaw config.
patch_file="$(mktemp)"
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
rm -f "$patch_file"

openclaw agents bind \
  --agent "$AGENT_ID" \
  --bind "telegram:$TELEGRAM_ACCOUNT"

# Best-effort approval. Some OpenClaw versions require the exact approval id and
# print it for the operator instead of approving via --latest.
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

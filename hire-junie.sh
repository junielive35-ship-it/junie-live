#!/usr/bin/env bash
set -euo pipefail

# Resolve this script's own directory so it can be run from any cwd and still
# find its bundled initialization seed (which includes the Marinator delegation
# runtime assets and operational scripts every Junie Live instance needs).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
  --seed-dir DIR              Junie seed dir. Default: <script dir>/initialization
  --model MODEL               OpenClaw model id. Default: openrouter/anthropic/claude-opus-4.8
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
SEED_DIR="$SCRIPT_DIR/initialization"
MODEL="openrouter/anthropic/claude-opus-4.8"
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
INGRESS_SPOOL_DIR="$HOME/.openclaw/telegram/ingress-spool-$TELEGRAM_ACCOUNT"
# Chat-scoped Telegram message store. OpenClaw keeps inbound Telegram messages
# for a chat in one JSONL store (one record per line, key="<account>:<chatId>:<msgId>").
# This store is shared across agents in the same chat; the "Conversation context"
# block injected into a session is filtered by account prefix. Stale
# "$TELEGRAM_ACCOUNT:*" records survive workspace/agent-state cleanup and leak
# previous Junie history into a freshly hired instance, so they must be purged
# selectively (without touching other accounts' records, e.g. the main agent's).
TELEGRAM_MSG_STORE="$HOME/.openclaw/agents/main/sessions/sessions.json.telegram-messages.json"

[[ -n "$TOKEN" ]] || { err "missing --telegram-token or JUNIE_TELEGRAM_BOT_TOKEN"; exit 2; }
[[ -n "$ADMIN_TELEGRAM_ID" ]] || { err "missing required --admin-telegram-id"; exit 2; }
[[ -d "$SEED_DIR" ]] || { err "seed dir not found: $SEED_DIR"; exit 1; }
[[ -f "$SEED_DIR/INITIALIZATION.md" ]] || { err "seed dir must contain INITIALIZATION.md: $SEED_DIR"; exit 1; }
if [[ -e "$SEED_DIR/BOOTSTRAP.md" ]]; then
  err "seed dir must not contain BOOTSTRAP.md for Junie multi-round initialization: $SEED_DIR/BOOTSTRAP.md"
  exit 1
fi
[[ -f "$SEED_DIR/marinator-delegation/scripts/delegate-coding-task.sh" ]] || { err "seed dir missing Marinator runner: $SEED_DIR/marinator-delegation/scripts/delegate-coding-task.sh"; exit 1; }
[[ -f "$SEED_DIR/marinator-delegation/dist/index.js" ]] || { err "seed dir missing built Marinator delegation plugin: $SEED_DIR/marinator-delegation/dist/index.js"; exit 1; }
command -v openclaw >/dev/null || { err "openclaw CLI not found in PATH"; exit 1; }
command -v tar >/dev/null || { err "tar not found in PATH"; exit 1; }

existing=0
if openclaw agents list 2>/dev/null | grep -qE "^- ${AGENT_ID}( |$)"; then existing=1; fi

mkdir -p "$BACKUP_DIR"
ts="$(date +%Y%m%d-%H%M%S)"
items=()
[[ -e "$WORKSPACE" ]] && items+=("${WORKSPACE#$HOME/.openclaw/}")
[[ -e "$AGENT_STATE_DIR" ]] && items+=("agents/$AGENT_ID")
[[ -e "$INGRESS_SPOOL_DIR" ]] && items+=("telegram/ingress-spool-$TELEGRAM_ACCOUNT")
if [[ "${#items[@]}" -gt 0 ]]; then
  backup="$BACKUP_DIR/${AGENT_ID}-before-hire-$ts.tgz"
  tar -czf "$backup" -C "$HOME/.openclaw" "${items[@]}"
  log "Backup: $backup"
fi

if [[ "$existing" -eq 1 ]]; then
  openclaw agents delete "$AGENT_ID" --force || true
fi

# Stop the Gateway before deleting state so it cannot recreate sessions or
# replay the telegram ingress spool mid-cleanup. The Gateway is started again
# by the restart step at the end of this script (unless --no-restart).
log "Stopping Gateway before cleanup..."
openclaw gateway stop || true

rm -rf "$WORKSPACE" "$AGENT_STATE_DIR" "$INGRESS_SPOOL_DIR"
mkdir -p "$WORKSPACE"
cp -a "$SEED_DIR/." "$WORKSPACE/"

# Purge stale Telegram message-store records for this account so the freshly
# hired Junie does not get prior history injected as "Conversation context".
# Back up the whole store first, then drop only "$TELEGRAM_ACCOUNT:*" lines
# (other accounts, e.g. the main agent, are left untouched). Done while the
# Gateway is stopped so the store is not concurrently rewritten.
if [[ -f "$TELEGRAM_MSG_STORE" ]]; then
  store_backup="$BACKUP_DIR/${AGENT_ID}-telegram-messages-before-hire-$ts.json"
  cp "$TELEGRAM_MSG_STORE" "$store_backup"
  log "Telegram message-store backup: $store_backup"
  removed_count="$(TELEGRAM_ACCOUNT="$TELEGRAM_ACCOUNT" STORE="$TELEGRAM_MSG_STORE" python3 - <<'PY'
import json, os
store = os.environ["STORE"]
prefix = os.environ["TELEGRAM_ACCOUNT"] + ":"
kept = []
removed = 0
with open(store, "r", encoding="utf-8") as fh:
    for line in fh:
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except Exception:
            kept.append(line if line.endswith("\n") else line + "\n")
            continue
        if str(obj.get("key", "")).startswith(prefix):
            removed += 1
            continue
        kept.append(line if line.endswith("\n") else line + "\n")
tmp = store + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write("".join(kept))
os.replace(tmp, store)
print(removed)
PY
)"
  log "Purged $removed_count stale '$TELEGRAM_ACCOUNT:' Telegram message-store records."
else
  log "Telegram message store not found ($TELEGRAM_MSG_STORE); skipping message purge."
fi

[[ -f "$WORKSPACE/INITIALIZATION.md" ]] || { err "copied workspace missing INITIALIZATION.md: $WORKSPACE"; exit 1; }
if [[ -e "$WORKSPACE/BOOTSTRAP.md" ]]; then
  err "copied workspace unexpectedly contains BOOTSTRAP.md: $WORKSPACE/BOOTSTRAP.md"
  exit 1
fi
PLUGIN_DIR="$WORKSPACE/marinator-delegation"
RUNNER="$WORKSPACE/marinator-delegation/scripts/delegate-coding-task.sh"
[[ -f "$PLUGIN_DIR/dist/index.js" ]] || { err "copied workspace missing Marinator plugin: $PLUGIN_DIR/dist/index.js"; exit 1; }
[[ -f "$RUNNER" ]] || { err "copied workspace missing Marinator runner: $RUNNER"; exit 1; }

openclaw agents add "$AGENT_ID" \
  --workspace "$WORKSPACE" \
  --model "$MODEL" \
  --non-interactive

openclaw channels add \
  --channel telegram \
  --account "$TELEGRAM_ACCOUNT" \
  --token "$TOKEN"

# Temp config patch files. Declared up front and cleaned by a single EXIT trap
# so cleanup is safe under `set -u` regardless of where the script exits.
patch_file=""
marinator_patch=""
load_paths_patch=""
heartbeat_patch=""
cleanup() { rm -f "${patch_file:-}" "${marinator_patch:-}" "${load_paths_patch:-}" "${heartbeat_patch:-}"; }
trap cleanup EXIT

patch_file="$(mktemp)"
cat >"$patch_file" <<JSON
{
  channels: {
    telegram: {
      accounts: {
        "$TELEGRAM_ACCOUNT": {
          dmPolicy: "allowlist",
          allowFrom: ["$ADMIN_TELEGRAM_ID"],
          heartbeat: {
            showOk: false,
            showAlerts: true,
            useIndicator: false
          }
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

# --- Marinator delegation runtime ---
# Every working Junie Live instance delegates coding work through the bundled
# marinator-delegation OpenClaw plugin, which drives the supervised opencode
# runner copied into the workspace. Configure the plugin, the config it depends
# on, and the runtime models so the instance is ready to delegate out of the box.

# 1) Make the marinator-delegation tool visible under the coding tools profile.
#    tools.alsoAllow is an array, and `config patch` replaces arrays wholesale,
#    so read the current list and merge our entry without clobbering others.
also_allow_current="$(openclaw config get tools.alsoAllow --json 2>/dev/null || printf '[]')"
also_allow_merged="$(MARINATOR_TOOL="marinator-delegation" python3 - "$also_allow_current" <<'PY'
import json, os, sys
try:
    current = json.loads(sys.argv[1]) if sys.argv[1].strip() else []
    if not isinstance(current, list):
        current = []
except Exception:
    current = []
want = os.environ["MARINATOR_TOOL"]
if want not in current:
    current.append(want)
print(json.dumps(current))
PY
)"
marinator_patch="$(mktemp)"
cat >"$marinator_patch" <<JSON
{
  tools: {
    alsoAllow: $also_allow_merged
  },
  agents: {
    defaults: {
      models: {
        "openrouter/openai/gpt-4.1-mini": {}
      }
    }
  }
}
JSON
openclaw config patch --file "$marinator_patch"

# 2) Drop any plugins.load.paths entries that point at a marinator-delegation
#    source directory BEFORE installing the bundled copy. Such an entry is
#    "config-selected" and wins over a copy install, so OpenClaw would load the
#    path-resolved plugin (this source repo's checkout) instead of the
#    self-contained install and emit a "duplicate plugin id ... global plugin
#    will be overridden by config plugin" warning. It must be removed first so
#    the subsequent install records the plugin with a `global` origin from the
#    start; removing it only after install leaves a stale config-origin entry in
#    the plugin discovery cache that keeps shadowing the install until the next
#    install/refresh. plugins.load.paths is an array and `config patch` replaces
#    arrays wholesale, so read the current list, filter out marinator-delegation
#    source paths, and write it back.
load_paths_current="$(openclaw config get plugins.load.paths --json 2>/dev/null || printf '[]')"
load_paths_filtered="$(python3 - "$load_paths_current" <<'PY'
import json, os, sys
try:
    current = json.loads(sys.argv[1]) if sys.argv[1].strip() else []
    if not isinstance(current, list):
        current = []
except Exception:
    current = []
def is_marinator(p):
    return isinstance(p, str) and os.path.basename(os.path.normpath(p)) == "marinator-delegation"
filtered = [p for p in current if not is_marinator(p)]
print(json.dumps({"filtered": filtered, "removed": len(filtered) != len(current)}))
PY
)"
if printf '%s' "$load_paths_filtered" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["removed"] else 1)'; then
  load_paths_array="$(printf '%s' "$load_paths_filtered" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["filtered"]))')"
  load_paths_patch="$(mktemp)"
  cat >"$load_paths_patch" <<JSON
{
  plugins: {
    load: {
      paths: $load_paths_array
    }
  }
}
JSON
  if openclaw config patch --replace-path plugins.load.paths --file "$load_paths_patch"; then
    log "Removed conflicting marinator-delegation entry from plugins.load.paths"
  else
    err "failed to remove marinator-delegation entry from plugins.load.paths"
    exit 1
  fi
fi

# 3) Register a heartbeat wake-runner for THIS agent so targeted Marinator
#    completion wakes reach the junie-live orchestrator session.
#    OpenClaw only registers an agent's heartbeat wake-runner when that agent
#    has a non-zero heartbeat interval. The supervised runner notifies the
#    orchestrator on completion via `openclaw system event --session-key
#    <orchestrator_session_key> --mode now`; that targeted wake fires
#    immediately (intent "immediate", bypassing the not-due gate) but is only
#    dispatched if the agent owns a wake-runner. Without this, the wake falls
#    back to the default `main` agent and the orchestrator never gets the turn.
#    The periodic heartbeat itself must stay low-noise and low-cost: a long
#    interval with target "none" (no chat delivery) and no system-prompt
#    section. It deliberately runs in the agent's SHARED real session (no
#    isolatedSession): a targeted wake must land in the real session so its
#    enqueued system event is inspected and injected as a turn. Cost stays low
#    via target "none" + the long interval, not via session isolation.
#    agents.list is an array and `config patch` replaces arrays
#    wholesale, so read the current list, merge the heartbeat object into the
#    entry whose id == "$AGENT_ID" (preserving every other entry/field), and
#    write it back. Idempotent: an existing heartbeat is overwritten in place.
agents_list_current="$(openclaw config get agents.list --json 2>/dev/null || printf '[]')"
agents_list_merged="$(AGENT_ID="$AGENT_ID" python3 - "$agents_list_current" <<'PY'
import json, os, sys
try:
    current = json.loads(sys.argv[1]) if sys.argv[1].strip() else []
    if not isinstance(current, list):
        current = []
except Exception:
    current = []
agent_id = os.environ["AGENT_ID"]
# Heartbeat wake-runner config. Every field is set EXPLICITLY here so the
# instance never depends on OpenClaw API defaults.
#
# - target "last": the orchestrator's wake-driven report is delivered to the
#   last external channel (the chat that started the delegation). This is the
#   fix; target "none" ran the wake turn but SILENTLY dropped the report so it
#   never reached Telegram.
# - isolatedSession False and lightContext False are REQUIRED. For a targeted
#   wake (`system event --session-key <agent main session> --mode now`), the
#   heartbeat preflight only inspects and injects the session's pending system
#   events when the run targets the agent's REAL shared session. With
#   isolatedSession=true the runner resolves an isolated session key that does
#   NOT match the forced real-session key, so shouldInspectPendingEvents becomes
#   false and the enqueued wake text is never injected as a turn -- it stays
#   parked until an unrelated inbound message drains it. That is exactly the
#   Marinator supervisor-wake bug. Keep the shared real session so wake events
#   drain on idle.
# - every "6h": keep the periodic tick rare. Routine ticks reply HEARTBEAT_OK
#   and are suppressed by the channel visibility config (see the telegram
#   heartbeat block above), so they do NOT spam chat.
# - directPolicy "allow": permit DM delivery (Telegram direct).
heartbeat = {
    "every": "6h",
    "target": "last",
    "includeSystemPromptSection": False,
    "isolatedSession": False,
    "lightContext": False,
    "directPolicy": "allow",
    "skipWhenBusy": False,
}
for entry in current:
    if isinstance(entry, dict) and entry.get("id") == agent_id:
        entry["heartbeat"] = heartbeat
        break
print(json.dumps(current))
PY
)"
heartbeat_patch="$(mktemp)"
cat >"$heartbeat_patch" <<JSON
{
  agents: {
    list: $agents_list_merged
  }
}
JSON
if openclaw config patch --replace-path agents.list --file "$heartbeat_patch"; then
  log "Registered heartbeat wake-runner for agent $AGENT_ID (every 6h, target last, shared real session; routine HEARTBEAT_OK suppressed)"
else
  err "failed to register heartbeat wake-runner for agent $AGENT_ID"
  exit 1
fi

# 4) Install the bundled plugin (copy, not link) from the initialized workspace
#    so the instance is self-contained and does not depend on this source repo's
#    path. The plugin now bundles its runner under marinator-delegation/scripts/,
#    so a copy install carries everything it needs. `--force` overwrites any prior
#    install for idempotent re-runs (it is invalid alongside `--link`). The plugin
#    spawns a child process (the opencode runner), so OpenClaw treats it as an
#    unsafe install and requires the explicit force-unsafe bypass.
if openclaw plugins install --force --dangerously-force-unsafe-install "$PLUGIN_DIR"; then
  log "Marinator delegation plugin installed from $PLUGIN_DIR"
else
  err "failed to install marinator-delegation plugin from $PLUGIN_DIR"
  exit 1
fi

# 5) Best-effort verification: report plugin load status and tool contract.
if plugin_status="$(openclaw plugins inspect marinator-delegation --json 2>/dev/null)"; then
  printf '%s\n' "$plugin_status" | python3 - <<'PY' || true
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
plugin = data.get("plugin", data)
status = plugin.get("status")
source = plugin.get("source")
tools = (plugin.get("contracts") or {}).get("tools") or plugin.get("toolNames") or []
print(f"  plugin status: {status}")
print(f"  plugin source: {source}")
print(f"  plugin tools:  {tools}")
PY
else
  log "  (could not inspect marinator-delegation plugin status; continuing)"
fi
# --- end Marinator delegation runtime ---

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
else
  # We stopped the Gateway before cleanup; bring it back even with --no-restart
  # so the host is not left with a stopped Gateway. Use start (not restart).
  log "Starting Gateway (was stopped for cleanup; --no-restart skips the probe/restart step)..."
  openclaw gateway start || {
    err "gateway start failed; run openclaw status for details"
    exit 1
  }
fi

log ""
log "Junie hiring configured."
log "Agent:            $AGENT_ID"
log "Workspace:        $WORKSPACE"
log "Telegram account: $TELEGRAM_ACCOUNT"
log "Allowed admin id: $ADMIN_TELEGRAM_ID"
log "Marinator plugin: $PLUGIN_DIR (installed copy)"
log ""
log "Next: open the Junie bot in Telegram and send /start."

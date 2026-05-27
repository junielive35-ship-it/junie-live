#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/runtime-paths.sh
source "$ROOT/scripts/runtime-paths.sh"
repo="${REPO:-$ROOT}"
backlog_dir="${BACKLOG_DIR:-$(junie_backlog_dir_default)}"
state_dir="${AUTONOMOUS_WORKER_STATE_DIR:-$(junie_autonomous_worker_state_dir_default)}"
worker_cmd_template="${AUTONOMOUS_WORKER_CMD:-}"
timeout_seconds="${AUTONOMOUS_WORKER_TIMEOUT_SECONDS:-0}"
opencode_bin="${AUTONOMOUS_OPENCODE_BIN:-}"
opencode_model="${AUTONOMOUS_OPENCODE_MODEL:-openrouter/anthropic/claude-opus-4.6}"
opencode_variant="${AUTONOMOUS_OPENCODE_VARIANT:-low}"
opencode_agent="${AUTONOMOUS_OPENCODE_AGENT:-build}"
item_id=""
item_title=""
item_type=""
item_description=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --backlog-dir) backlog_dir="$2"; shift 2 ;;
    --state-dir) state_dir="$2"; shift 2 ;;
    --worker-cmd-template) worker_cmd_template="$2"; shift 2 ;;
    --timeout-seconds) timeout_seconds="$2"; shift 2 ;;
    --item-id) item_id="$2"; shift 2 ;;
    --item-title) item_title="$2"; shift 2 ;;
    --item-type) item_type="$2"; shift 2 ;;
    --item-description) item_description="$2"; shift 2 ;;
    *) printf 'Unknown: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ -n "$item_id" ]] || { printf 'worker_status=blocked\nreason=missing item id\n' >&2; exit 2; }
repo="$(cd "$repo" 2>/dev/null && pwd)" || { printf 'worker_status=blocked\nreason=repo not found: %s\n' "$repo" >&2; exit 2; }
mkdir -p "$state_dir/logs"
run_id="backlog-worker-$(date -u +%Y%m%dT%H%M%SZ)-$$"
prompt_file="$state_dir/${run_id}-prompt.md"
log_file="$state_dir/logs/${run_id}.log"

cat >"$prompt_file" <<PROMPT
You are an autonomous code-changing worker for this repository.

Backlog item:
- id: $item_id
- type: $item_type
- title: $item_title
- description: $item_description

Repository: $repo
Backlog directory: $backlog_dir

Constraints:
- Work only on this backlog item unless a tiny prerequisite is required.
- Respect repository hygiene; do not leave root workspace artifacts such as AGENTS.md, USER.md, TOOLS.md, IDENTITY.md, HEARTBEAT.md, .openclaw/, or state/ in the repo root.
- Make meaningful implementation changes, not just acquisition/scaffolding.
- Run the repo verification command when practical (normally ./scripts/verify.sh) and git diff --check.
- Commit meaningful completed work with a subject that describes the actual change; do not use generic iteration-counter subjects.
- If blocked, leave a clear blocker in output and do not claim success.
PROMPT


mask_secret_line() {
  sed -E 's/(sk-or-v1-[A-Za-z0-9_-]+)/<masked>/g; s/(apiKey|apikey|api_key|key|token|authorization|Bearer)[^,}[:space:]]*/\1=<masked>/Ig'
}

ensure_opencode_openrouter_auth() {
  local auth_file key_file key
  key_file="${HOME:-}/openrouter.key"
  auth_file="${XDG_DATA_HOME:-${HOME:-}/.local/share}/opencode/auth.json"

  if [[ -f "$auth_file" ]] && python3 - "$auth_file" <<'PY' >/dev/null 2>&1
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
entry = data.get("openrouter", {})
if entry.get("type") == "api" and entry.get("key"):
    raise SystemExit(0)
raise SystemExit(1)
PY
  then
    return 0
  fi

  [[ -f "$key_file" ]] || return 0
  key="$(tr -d '\r\n' <"$key_file")"
  [[ -n "$key" ]] || return 0

  mkdir -p "$(dirname "$auth_file")"
  python3 - "$auth_file" "$key" <<'PY'
import json, os, sys
path, key = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path) and os.path.getsize(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except json.JSONDecodeError:
        data = {}
data["openrouter"] = {"type": "api", "key": key}
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
os.chmod(path, 0o600)
PY
  unset key
}

opencode_config_diagnostics() {
  printf 'opencode_config_diagnostics_begin\n'
  printf 'opencode_config_files='
  local found=0 f
  for f in "${HOME:-}/.config/opencode/config.json" "${HOME:-}/.config/opencode/opencode.json" "${HOME:-}/.config/opencode/opencode.jsonc" "${HOME:-}/.opencode/opencode.json" "${HOME:-}/.opencode/opencode.jsonc"; do
    if [[ -f "$f" ]]; then
      [[ "$found" -eq 0 ]] || printf ','
      printf '%s' "$f"
      found=1
    fi
  done
  [[ "$found" -eq 1 ]] || printf 'none'
  printf '\n'
  printf 'openrouter_key_file_present=%s\n' "$([[ -f "${HOME:-}/openrouter.key" ]] && printf yes || printf no)"
  printf 'openrouter_env_present=%s\n' "$([[ -n "${OPENROUTER_API_KEY:-}" ]] && printf yes || printf no)"
  printf 'opencode_auth_file_present=%s\n' "$([[ -f "${XDG_DATA_HOME:-${HOME:-}/.local/share}/opencode/auth.json" ]] && printf yes || printf no)"
  if "$opencode_bin" auth list >/tmp/junie-opencode-auth-$$.txt 2>&1; then
    printf 'opencode_auth_list='
    tr '\n' ' ' </tmp/junie-opencode-auth-$$.txt | mask_secret_line
    printf '\n'
  else
    printf 'opencode_auth_list=unavailable\n'
  fi
  rm -f /tmp/junie-opencode-auth-$$.txt
  printf 'opencode_config_diagnostics_end\n'
}

use_default_opencode=false
if [[ -z "$worker_cmd_template" ]]; then
  if [[ -n "$opencode_bin" ]]; then
    :
  elif command -v opencode >/dev/null 2>&1; then
    opencode_bin="$(command -v opencode)"
  elif [[ -x "${HOME:-}/.opencode/bin/opencode" ]]; then
    opencode_bin="${HOME}/.opencode/bin/opencode"
  else
    printf 'worker_status=blocked\n'
    printf 'reason=opencode not found and AUTONOMOUS_OPENCODE_BIN/AUTONOMOUS_WORKER_CMD/--worker-cmd-template not set\n'
    printf 'prompt_file=%s\nlog_file=%s\n' "$prompt_file" "$log_file"
    exit 2
  fi
  [[ -x "$opencode_bin" || "$opencode_bin" != */* ]] || {
    printf 'worker_status=blocked\n'
    printf 'reason=opencode binary is not executable: %s\n' "$opencode_bin"
    printf 'prompt_file=%s\nlog_file=%s\n' "$prompt_file" "$log_file"
    exit 2
  }
  use_default_opencode=true
fi

if [[ "$use_default_opencode" == true ]]; then
  ensure_opencode_openrouter_auth
  # Export OPENROUTER_API_KEY for cron/background environments where opencode
  # may check the env var as an alternative to native auth.json.
  if [[ -z "${OPENROUTER_API_KEY:-}" ]] && [[ -f "${HOME:-}/openrouter.key" ]]; then
    OPENROUTER_API_KEY="$(tr -d '\r\n' <"${HOME}/openrouter.key")"
    export OPENROUTER_API_KEY
  fi
fi

export AUTONOMOUS_ITEM_ID="$item_id"
export AUTONOMOUS_ITEM_TITLE="$item_title"
export AUTONOMOUS_ITEM_TYPE="$item_type"
export AUTONOMOUS_ITEM_DESCRIPTION="$item_description"
export AUTONOMOUS_REPO="$repo"
export AUTONOMOUS_BACKLOG_DIR="$backlog_dir"
export AUTONOMOUS_PROMPT_FILE="$prompt_file"
export AUTONOMOUS_WORKER_LOG="$log_file"
export AUTONOMOUS_OPENCODE_BIN="$opencode_bin"
export AUTONOMOUS_OPENCODE_MODEL="$opencode_model"
export AUTONOMOUS_OPENCODE_VARIANT="$opencode_variant"
export AUTONOMOUS_OPENCODE_AGENT="$opencode_agent"

printf 'worker_status=running\nitem_id=%s\nprompt_file=%s\nlog_file=%s\n' "$item_id" "$prompt_file" "$log_file"
if [[ "$use_default_opencode" == true ]]; then
  printf 'opencode_bin=%s\nopencode_model=%s\nopencode_variant=%s\nopencode_agent=%s\n' "$opencode_bin" "$opencode_model" "$opencode_variant" "$opencode_agent"
fi

set +e
if [[ "$use_default_opencode" == true ]]; then
  # ACP mode: start opencode serve (ACP server), execute through --attach.
  # This routes all implementation work through the ACP protocol layer instead
  # of direct `opencode run`.
  acp_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  acp_log="$state_dir/logs/${run_id}-acp-server.log"
  printf 'acp_mode=serve\nacp_port=%s\n' "$acp_port"

  (cd "$repo" && exec "$opencode_bin" serve --port "$acp_port" --hostname 127.0.0.1) >"$acp_log" 2>&1 &
  acp_pid=$!
  printf 'acp_pid=%s\n' "$acp_pid"

  acp_ready=false
  for _acp_wait in $(seq 1 60); do
    if curl -sf "http://127.0.0.1:$acp_port/global/health" >/dev/null 2>&1; then
      acp_ready=true
      break
    fi
    if ! kill -0 "$acp_pid" 2>/dev/null; then
      break
    fi
    sleep 1
  done

  if [[ "$acp_ready" != true ]]; then
    kill "$acp_pid" 2>/dev/null; wait "$acp_pid" 2>/dev/null || true
    set -e
    printf 'worker_status=blocked\nreason=ACP server did not become healthy within 60s\n'
    printf 'acp_server_log=%s\nprompt_file=%s\nlog_file=%s\n' "$acp_log" "$prompt_file" "$log_file"
    exit 2
  fi

  if [[ "${timeout_seconds:-0}" -gt 0 ]]; then
    timeout --foreground --kill-after=5s "$timeout_seconds" \
      "$opencode_bin" run --attach "http://127.0.0.1:$acp_port" \
        --model "$AUTONOMOUS_OPENCODE_MODEL" --variant "$AUTONOMOUS_OPENCODE_VARIANT" \
        --agent "$AUTONOMOUS_OPENCODE_AGENT" \
        "$(cat "$AUTONOMOUS_PROMPT_FILE")" >>"$log_file" 2>&1
  else
    "$opencode_bin" run --attach "http://127.0.0.1:$acp_port" \
      --model "$AUTONOMOUS_OPENCODE_MODEL" --variant "$AUTONOMOUS_OPENCODE_VARIANT" \
      --agent "$AUTONOMOUS_OPENCODE_AGENT" \
      "$(cat "$AUTONOMOUS_PROMPT_FILE")" >>"$log_file" 2>&1
  fi
  status=$?

  # Cleanup ACP server
  kill "$acp_pid" 2>/dev/null; wait "$acp_pid" 2>/dev/null || true
else
  if [[ "${timeout_seconds:-0}" -gt 0 ]]; then
    (cd "$repo" && timeout --foreground --kill-after=5s "$timeout_seconds" bash -c "$worker_cmd_template") >>"$log_file" 2>&1
  else
    (cd "$repo" && bash -c "$worker_cmd_template") >>"$log_file" 2>&1
  fi
  status=$?
fi
set -e

if [[ "$status" -eq 0 ]]; then
  printf 'worker_status=success\nitem_id=%s\nlog_file=%s\n' "$item_id" "$log_file"
  exit 0
fi

if [[ "$use_default_opencode" == true ]] && { grep -Eiq 'model not found|invalid model|provider.*not found|unknown provider|models? (is|are) invalid' "$log_file" || { [[ -f "${acp_log:-}" ]] && grep -Eiq 'model not found|invalid model|provider.*not found|unknown provider|models? (is|are) invalid' "$acp_log"; }; }; then
  printf 'worker_status=blocked\n'
  printf 'item_id=%s\nexit_status=%s\nlog_file=%s\n' "$item_id" "$status" "$log_file"
  printf 'reason=opencode model/provider configuration failed before work started\n'
  printf 'opencode_model=%s\nopencode_variant=%s\nopencode_agent=%s\n' "$opencode_model" "$opencode_variant" "$opencode_agent"
  printf 'diagnostic=opencode requires a configured provider/model. The production default is OpenRouter Claude Opus 4.6 (%s). The default worker provisions OpenCode-native OpenRouter auth at $XDG_DATA_HOME/opencode/auth.json or $HOME/.local/share/opencode/auth.json from $HOME/openrouter.key when needed, without printing the key. OpenRouter models used by opencode must either exist in provider.openrouter.models (for example anthropic/claude-opus-4.6, referenced as openrouter/anthropic/claude-opus-4.6) or use an OpenCode/OpenRouter alias that the provider accepts. Allowed production providers are OpenAI GPT-5.2+, Anthropic Sonnet/Opus 4.6+, or Google Gemini 3.1 Pro+. Run: %q models openrouter and %q auth list; then set AUTONOMOUS_OPENCODE_MODEL to an available allowed model.\n' "$opencode_model" "$opencode_bin" "$opencode_bin"
  opencode_config_diagnostics
  exit 2
fi

printf 'worker_status=failed\nitem_id=%s\nexit_status=%s\nlog_file=%s\n' "$item_id" "$status" "$log_file"
exit "$status"

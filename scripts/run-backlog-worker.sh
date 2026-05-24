#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="${REPO:-$ROOT}"
backlog_dir="${BACKLOG_DIR:-$ROOT/state/backlog}"
state_dir="${AUTONOMOUS_WORKER_STATE_DIR:-${HOME:-$ROOT}/.openclaw/workspace-junie-live/.openclaw/state/autonomous-worker}"
worker_cmd_template="${AUTONOMOUS_WORKER_CMD:-}"
timeout_seconds="${AUTONOMOUS_WORKER_TIMEOUT_SECONDS:-0}"
opencode_bin="${AUTONOMOUS_OPENCODE_BIN:-}"
opencode_model="${AUTONOMOUS_OPENCODE_MODEL:-anthropic/claude-opus-4-6}"
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

set +e
if [[ "$use_default_opencode" == true ]]; then
  if [[ "${timeout_seconds:-0}" -gt 0 ]]; then
    (cd "$repo" && timeout --foreground --kill-after=5s "$timeout_seconds" "$opencode_bin" run --model "$AUTONOMOUS_OPENCODE_MODEL" --variant "$AUTONOMOUS_OPENCODE_VARIANT" --agent "$AUTONOMOUS_OPENCODE_AGENT" "$(cat "$AUTONOMOUS_PROMPT_FILE")") >>"$log_file" 2>&1
  else
    (cd "$repo" && "$opencode_bin" run --model "$AUTONOMOUS_OPENCODE_MODEL" --variant "$AUTONOMOUS_OPENCODE_VARIANT" --agent "$AUTONOMOUS_OPENCODE_AGENT" "$(cat "$AUTONOMOUS_PROMPT_FILE")") >>"$log_file" 2>&1
  fi
else
  if [[ "${timeout_seconds:-0}" -gt 0 ]]; then
    (cd "$repo" && timeout --foreground --kill-after=5s "$timeout_seconds" bash -c "$worker_cmd_template") >>"$log_file" 2>&1
  else
    (cd "$repo" && bash -c "$worker_cmd_template") >>"$log_file" 2>&1
  fi
fi
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  printf 'worker_status=success\nitem_id=%s\nlog_file=%s\n' "$item_id" "$log_file"
  exit 0
fi

printf 'worker_status=failed\nitem_id=%s\nexit_status=%s\nlog_file=%s\n' "$item_id" "$status" "$log_file"
exit "$status"

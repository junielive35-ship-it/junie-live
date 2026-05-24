#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF_USAGE'
Usage:
  scripts/install-overnight-crons.sh --workspace DIR --repo DIR [options]

Writes Junie Live overnight cron definitions into an initialized OpenClaw
workspace. By default this only creates local, installable artifacts and does not
mutate the host crontab or OpenClaw cron registry.

Options:
  --agent-id ID                         Agent id. Default: junie-live
  --branch NAME                         Expected branch. Default: current repo branch
  --state-dir DIR                       Default: WORKSPACE/.openclaw/state/overnight
  --logs-dir DIR                        Default: WORKSPACE/.openclaw/logs/overnight
  --controller-schedule CRON            Default: 0 1 * * *
  --watchdog-schedule CRON              Default: */15 * * * *
  --morning-report-schedule CRON        Default: 0 8 * * *
  --worker-timeout-seconds SECONDS      Default: 900
  --stale-seconds SECONDS               Default: 1800
  --max-iterations N                    Default: 1
  --disabled                            Generate disabled definitions
  --dry-run                             Validate and print paths; still writes local artifacts
  --help                                Show this help
EOF_USAGE
}

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
need_value() { local opt="$1" value="${2:-}"; [[ -n "$value" && "$value" != --* ]] || { err "$opt requires a value"; exit 2; }; }
expand_path() { local p="$1"; case "$p" in "~") printf '%s\n' "$HOME" ;; "~/"*) printf '%s/%s\n' "$HOME" "${p#~/}" ;; *) printf '%s\n' "$p" ;; esac; }
abs_path() { local p; p="$(expand_path "$1")"; mkdir -p "$(dirname "$p")"; (cd "$(dirname "$p")" && printf '%s/%s\n' "$PWD" "$(basename "$p")"); }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
cron_escape() { printf '%s' "$1" | sed "s/'/'\\''/g"; }

workspace=""
repo=""
agent_id="junie-live"
branch=""
state_dir=""
logs_dir=""
controller_schedule="0 1 * * *"
watchdog_schedule="*/15 * * * *"
morning_report_schedule="0 8 * * *"
worker_timeout_seconds="900"
stale_seconds="1800"
max_iterations="1"
enabled=true
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) need_value "$1" "${2:-}"; workspace="$2"; shift 2 ;;
    --repo) need_value "$1" "${2:-}"; repo="$2"; shift 2 ;;
    --agent-id) need_value "$1" "${2:-}"; agent_id="$2"; shift 2 ;;
    --branch) need_value "$1" "${2:-}"; branch="$2"; shift 2 ;;
    --state-dir) need_value "$1" "${2:-}"; state_dir="$2"; shift 2 ;;
    --logs-dir) need_value "$1" "${2:-}"; logs_dir="$2"; shift 2 ;;
    --controller-schedule) need_value "$1" "${2:-}"; controller_schedule="$2"; shift 2 ;;
    --watchdog-schedule) need_value "$1" "${2:-}"; watchdog_schedule="$2"; shift 2 ;;
    --morning-report-schedule) need_value "$1" "${2:-}"; morning_report_schedule="$2"; shift 2 ;;
    --worker-timeout-seconds) need_value "$1" "${2:-}"; worker_timeout_seconds="$2"; shift 2 ;;
    --stale-seconds) need_value "$1" "${2:-}"; stale_seconds="$2"; shift 2 ;;
    --max-iterations) need_value "$1" "${2:-}"; max_iterations="$2"; shift 2 ;;
    --disabled) enabled=false; shift ;;
    --dry-run) dry_run=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage; exit 2 ;;
  esac
done

[[ -n "$workspace" ]] || { err "missing --workspace"; exit 2; }
[[ -n "$repo" ]] || { err "missing --repo"; exit 2; }
workspace="$(abs_path "$workspace")"
repo="$(abs_path "$repo")"
[[ -d "$repo" ]] || { err "repo not found: $repo"; exit 1; }
[[ -f "$repo/scripts/overnight-controller.sh" ]] || { err "missing overnight controller in repo: $repo"; exit 1; }
[[ -f "$repo/scripts/overnight-watchdog.sh" ]] || { err "missing overnight watchdog in repo: $repo"; exit 1; }
[[ -f "$repo/scripts/overnight-report.sh" ]] || { err "missing overnight report in repo: $repo"; exit 1; }
if [[ -z "$branch" ]]; then
  branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || printf junie/autonomous-mvp-loop)"
fi
[[ "$branch" != "main" ]] || { err "refusing to install overnight routines targeting main"; exit 2; }
state_dir="$(abs_path "${state_dir:-$workspace/.openclaw/state/overnight}")"
logs_dir="$(abs_path "${logs_dir:-$workspace/.openclaw/logs/overnight}")"
def_dir="$workspace/.openclaw/cron"
def_file="$def_dir/overnight-routines.json"
crontab_file="$def_dir/overnight-routines.crontab"
mkdir -p "$def_dir" "$state_dir" "$logs_dir"

enabled_json=false; $enabled && enabled_json=true
write_job() {
  local id="$1" schedule="$2" command="$3" comma="$4"
  cat <<JSON
    {
      "id": "$(json_escape "$id")",
      "schedule": "$(json_escape "$schedule")",
      "enabled": $enabled_json,
      "cwd": "$(json_escape "$repo")",
      "shell": "/usr/bin/env bash",
      "non_interactive": true,
      "state_dir": "$(json_escape "$state_dir")",
      "logs_dir": "$(json_escape "$logs_dir")",
      "command": "$(json_escape "$command")"
    }$comma
JSON
}

controller_cmd="cd '$repo' && OCL_NONINTERACTIVE=1 OVERNIGHT_STATE_DIR='$state_dir' OVERNIGHT_LOGS_DIR='$logs_dir' OVERNIGHT_EXPECTED_BRANCH='$branch' OVERNIGHT_ITERATION_TIMEOUT_SECONDS='$worker_timeout_seconds' OVERNIGHT_MAX_ITERATIONS='$max_iterations' exec /usr/bin/env bash '$repo/scripts/overnight-controller.sh' --state-dir '$state_dir' --expected-branch '$branch' --iteration-timeout '$worker_timeout_seconds' --max-iterations '$max_iterations' >> '$logs_dir/controller.cron.log' 2>&1"
watchdog_cmd="cd '$repo' && OCL_NONINTERACTIVE=1 OVERNIGHT_STATE_DIR='$state_dir' OVERNIGHT_LOGS_DIR='$logs_dir' OVERNIGHT_STALE_SECONDS='$stale_seconds' exec /usr/bin/env bash '$repo/scripts/overnight-watchdog.sh' --state-dir '$state_dir' --stale-seconds '$stale_seconds' --dry-run >> '$logs_dir/watchdog.cron.log' 2>&1"
report_cmd="cd '$repo' && OCL_NONINTERACTIVE=1 OVERNIGHT_STATE_DIR='$state_dir' OVERNIGHT_LOGS_DIR='$logs_dir' exec /usr/bin/env bash '$repo/scripts/overnight-report.sh' --state-dir '$state_dir' --repo '$repo' >> '$logs_dir/morning-report.cron.log' 2>&1"

cat >"$def_file" <<JSON
{
  "schema": "junie-live.overnight-crons.v1",
  "agent_id": "$(json_escape "$agent_id")",
  "enabled": $enabled_json,
  "workspace": "$(json_escape "$workspace")",
  "repo": "$(json_escape "$repo")",
  "branch": "$(json_escape "$branch")",
  "state_dir": "$(json_escape "$state_dir")",
  "logs_dir": "$(json_escape "$logs_dir")",
  "timeouts": {
    "worker_timeout_seconds": $worker_timeout_seconds,
    "stale_seconds": $stale_seconds,
    "max_iterations": $max_iterations
  },
  "jobs": [
$(write_job "overnight-controller" "$controller_schedule" "$controller_cmd" ",")
$(write_job "overnight-watchdog" "$watchdog_schedule" "$watchdog_cmd" ",")
$(write_job "morning-report" "$morning_report_schedule" "$report_cmd" "")
  ]
}
JSON

{
  printf '# Generated by scripts/install-overnight-crons.sh for %s\n' "$agent_id"
  printf '# Import manually or through the OpenClaw cron installer; do not edit in the repo.\n'
  if ! $enabled; then printf '# DISABLED: remove leading # after review to enable.\n'; fi
  prefix=""; $enabled || prefix="# "
  printf "%s%s %s\n" "$prefix" "$controller_schedule" "$controller_cmd"
  printf "%s%s %s\n" "$prefix" "$watchdog_schedule" "$watchdog_cmd"
  printf "%s%s %s\n" "$prefix" "$morning_report_schedule" "$report_cmd"
} >"$crontab_file"

log "Overnight cron artifacts written."
log "definitions=$def_file"
log "crontab=$crontab_file"
log "state_dir=$state_dir"
log "logs_dir=$logs_dir"
if $dry_run; then
  log "dry_run=true (no external cron registry was mutated)"
fi

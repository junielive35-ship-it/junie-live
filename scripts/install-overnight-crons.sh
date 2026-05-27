#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF_USAGE'
Usage:
  scripts/install-overnight-crons.sh --workspace DIR --repo DIR [options]

Writes Junie Live overnight OpenClaw cron definitions into an initialized
workspace and installs/updates a branch-independent watchdog OpenClaw cron job
by default. Controller work is started manually via scripts/start-autonomous-window.sh;
this helper does not install or keep scheduled controller cron definitions.

Options:
  --agent-id ID                         Agent id. Default: junie-live
  --branch NAME                         Expected branch. Default: current repo branch
  --state-dir DIR                       Default: WORKSPACE/.openclaw/state/overnight
  --logs-dir DIR                        Default: WORKSPACE/.openclaw/logs/overnight
  --watchdog-schedule CRON              Default: */15 * * * *
  --worker-timeout-seconds SECONDS      Default: 900
  --stale-seconds SECONDS               Default: 1800
  --max-iterations N                    Default: 1
  --timezone TZ                         OpenClaw cron timezone. Default: Europe/Belgrade
  --openclaw-bin PATH                   OpenClaw CLI path. Default: OPENCLAW_BIN or openclaw
  --install-openclaw                    Install/update OpenClaw cron jobs (default: watchdog enabled)
  --artifacts-only                      Only write local JSON definitions; do not call OpenClaw
  --disabled                            Generate disabled definitions and disabled OpenClaw jobs
  --dry-run                             Validate and print planned OpenClaw commands; no mutation
  --help                                Show this help
EOF_USAGE
}

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
need_value() { local opt="$1" value="${2:-}"; [[ -n "$value" && "$value" != --* ]] || { err "$opt requires a value"; exit 2; }; }
expand_path() { local p="$1"; case "$p" in "~") printf '%s\n' "$HOME" ;; "~/"*) printf '%s/%s\n' "$HOME" "${p#~/}" ;; *) printf '%s\n' "$p" ;; esac; }
abs_path() { local p; p="$(expand_path "$1")"; mkdir -p "$(dirname "$p")"; (cd "$(dirname "$p")" && printf '%s/%s\n' "$PWD" "$(basename "$p")"); }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
quote_args() { printf ' %q' "$@"; printf '\n'; }
run_openclaw() { if $dry_run; then printf 'DRY-RUN:'; quote_args "$openclaw_bin" "$@"; else "$openclaw_bin" "$@"; fi; }

workspace=""; repo=""; agent_id="junie-live"; branch=""; state_dir=""; logs_dir=""
watchdog_schedule="*/15 * * * *"
worker_timeout_seconds="900"; stale_seconds="1800"; max_iterations="1"
enabled=true; dry_run=false; install_openclaw=true; openclaw_bin="${OPENCLAW_BIN:-openclaw}"; timezone="Europe/Belgrade"
cron_prefix="Junie Live overnight"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) need_value "$1" "${2:-}"; workspace="$2"; shift 2 ;;
    --repo) need_value "$1" "${2:-}"; repo="$2"; shift 2 ;;
    --agent-id) need_value "$1" "${2:-}"; agent_id="$2"; shift 2 ;;
    --branch) need_value "$1" "${2:-}"; branch="$2"; shift 2 ;;
    --state-dir) need_value "$1" "${2:-}"; state_dir="$2"; shift 2 ;;
    --logs-dir) need_value "$1" "${2:-}"; logs_dir="$2"; shift 2 ;;
    --watchdog-schedule) need_value "$1" "${2:-}"; watchdog_schedule="$2"; shift 2 ;;
    --worker-timeout-seconds) need_value "$1" "${2:-}"; worker_timeout_seconds="$2"; shift 2 ;;
    --stale-seconds) need_value "$1" "${2:-}"; stale_seconds="$2"; shift 2 ;;
    --max-iterations) need_value "$1" "${2:-}"; max_iterations="$2"; shift 2 ;;
    --timezone|--tz) need_value "$1" "${2:-}"; timezone="$2"; shift 2 ;;
    --openclaw-bin) need_value "$1" "${2:-}"; openclaw_bin="$2"; shift 2 ;;
    --install-openclaw) install_openclaw=true; shift ;;
    --artifacts-only) install_openclaw=false; shift ;;
    --disabled) enabled=false; shift ;;
    --dry-run) dry_run=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage; exit 2 ;;
  esac
done

[[ -n "$workspace" ]] || { err "missing --workspace"; exit 2; }
[[ -n "$repo" ]] || { err "missing --repo"; exit 2; }
workspace="$(abs_path "$workspace")"; repo="$(abs_path "$repo")"
[[ -d "$repo" ]] || { err "repo not found: $repo"; exit 1; }
[[ -f "$repo/scripts/overnight-watchdog.sh" ]] || { err "missing overnight watchdog in repo: $repo"; exit 1; }
if [[ -z "$branch" ]]; then branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || printf junie/autonomous-mvp-loop)"; fi
state_dir="$(abs_path "${state_dir:-$workspace/.openclaw/state/overnight}")"
logs_dir="$(abs_path "${logs_dir:-$workspace/.openclaw/logs/overnight}")"
def_dir="$workspace/.openclaw/cron"; def_file="$def_dir/overnight-routines.json"
mkdir -p "$def_dir" "$state_dir" "$logs_dir"

enabled_json=false; $enabled && enabled_json=true
watchdog_enabled_json=false
$enabled && watchdog_enabled_json=true
watchdog_cmd="cd '$repo' && OCL_NONINTERACTIVE=1 OVERNIGHT_STATE_DIR='$state_dir' OVERNIGHT_LOGS_DIR='$logs_dir' OVERNIGHT_STALE_SECONDS='$stale_seconds' exec /usr/bin/env bash '$repo/scripts/overnight-watchdog.sh' --state-dir '$state_dir' --stale-seconds '$stale_seconds' --cleanup >> '$logs_dir/watchdog.cron.log' 2>&1"

write_job() {
  local id="$1" schedule="$2" command="$3" job_enabled="$4" comma="$5"
  cat <<JSON
    {
      "id": "$(json_escape "$id")",
      "schedule": "$(json_escape "$schedule")",
      "enabled": $job_enabled,
      "cwd": "$(json_escape "$repo")",
      "shell": "/usr/bin/env bash",
      "non_interactive": true,
      "state_dir": "$(json_escape "$state_dir")",
      "logs_dir": "$(json_escape "$logs_dir")",
      "command": "$(json_escape "$command")"
    }$comma
JSON
}

make_prompt() {
  local label="$1" command="$2"
  cat <<EOF_PROMPT
Run the Junie Live overnight ${label} routine non-interactively.

Use the exec tool to run exactly this shell command from the repository, then summarize the result concisely:

${command}

Do not open a terminal UI. Do not ask for confirmation. If the command fails, report the exit status and the relevant log path. State dir: ${state_dir}. Logs dir: ${logs_dir}. Target branch: ${branch}.
EOF_PROMPT
}

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
  "timeouts": { "worker_timeout_seconds": $worker_timeout_seconds, "stale_seconds": $stale_seconds, "max_iterations": $max_iterations },
  "openclaw": { "timezone": "$(json_escape "$timezone")", "tools": "exec,read", "session": "isolated" },
  "jobs": [
$(write_job "overnight-watchdog" "$watchdog_schedule" "$watchdog_cmd" "$watchdog_enabled_json" "")
  ]
}
JSON

remove_existing_jobs() {
  if $dry_run; then printf 'DRY-RUN:'; quote_args "$openclaw_bin" cron list --agent "$agent_id" --all --json; return 0; fi
  local list_json ids
  list_json="$($openclaw_bin cron list --agent "$agent_id" --all --json)" || { err "failed to list OpenClaw cron jobs for agent $agent_id"; exit 1; }
  ids="$(LIST_JSON="$list_json" PREFIX="$cron_prefix" AGENT_ID="$agent_id" python3 - <<'PY_IDS'
import json, os, sys
raw = os.environ.get("LIST_JSON", "")
if not raw.strip():
    sys.exit(0)
try:
    data = json.loads(raw)
except json.JSONDecodeError as exc:
    # Some OpenClaw versions can occasionally return empty/non-JSON output while still
    # exiting 0 during agent/config churn. Do not make hiring fail because cleanup
    # could not list existing jobs; adding stable-name jobs is safer than aborting setup.
    sys.exit(0)
jobs = data.get("jobs") if isinstance(data, dict) else data
prefix = os.environ["PREFIX"]
agent = os.environ["AGENT_ID"]
for job in jobs or []:
    if not isinstance(job, dict):
        continue
    name = str(job.get("name") or job.get("title") or "")
    job_agent = str(job.get("agent") or job.get("agentId") or job.get("agent_id") or "")
    if name.startswith(prefix) and (not job_agent or job_agent == agent):
        job_id = job.get("id") or job.get("jobId") or job.get("job_id") or job.get("name")
        if job_id:
            print(str(job_id))
PY_IDS
  )" || { err "warning: failed to parse OpenClaw cron list output; continuing without removing existing jobs"; ids=""; }
  if [[ -n "$ids" ]]; then
    while IFS= read -r id; do [[ -n "$id" ]] && run_openclaw cron rm "$id"; done <<<"$ids"
  fi
}
install_job() {
  local suffix="$1" schedule="$2" timeout_seconds="$3" prompt="$4" job_enabled="$5" name="$cron_prefix $1 ($agent_id)"
  local args=(cron add --name "$name" --cron "$schedule" --tz "$timezone" --session isolated --agent "$agent_id" --message "$prompt" --tools exec,read --timeout-seconds "$timeout_seconds" --no-deliver --description "Junie Live overnight $suffix for $repo")
  [[ "$job_enabled" == true ]] || args+=(--disabled)
  run_openclaw "${args[@]}"
}

log "Overnight OpenClaw cron definitions written."
log "definitions=$def_file"
log "state_dir=$state_dir"
log "logs_dir=$logs_dir"
if $dry_run; then log "dry_run=true (no external cron registry was mutated)"; fi

if $install_openclaw; then
  if ! $dry_run; then
    command -v "$openclaw_bin" >/dev/null || { err "OpenClaw cron install requested but CLI not found: $openclaw_bin"; exit 1; }
    command -v python3 >/dev/null || { err "python3 not found; required to parse OpenClaw cron list JSON"; exit 1; }
  fi
  remove_existing_jobs
  install_job watchdog "$watchdog_schedule" 900 "$(make_prompt watchdog "$watchdog_cmd")" "$watchdog_enabled_json"
  log "OpenClaw cron jobs installed/updated for agent=$agent_id"
else
  log "artifacts_only=true (OpenClaw cron registry was not mutated)"
fi

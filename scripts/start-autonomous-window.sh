#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$ROOT"
workspace="${HOME:-$ROOT}/.openclaw/workspace-junie-live"
state_dir=""
expected_branch="${OVERNIGHT_EXPECTED_BRANCH:-junie/autonomous-mvp-loop}"
max_iterations="${OVERNIGHT_MAX_ITERATIONS:-99}"
iteration_timeout="${OVERNIGHT_ITERATION_TIMEOUT_SECONDS:-900}"
duration=""
hours=""
dry_run=false
background=false
allow_main_for_tests=false
allow_dirty_for_tests="${AUTONOMOUS_ALLOW_DIRTY_FOR_TESTS:-false}"
skip_verify=false
worker_cmd="${OVERNIGHT_WORKER_CMD:-}"

usage() {
  cat <<'USAGE'
Usage: scripts/start-autonomous-window.sh (--duration 9h|--hours 9) [options]

Starts a bounded autonomous controller window using scripts/overnight-controller.sh.

Options:
  --duration DURATION        Duration like 9h, 90m, 3600s, or 1h30m
  --hours HOURS              Duration in hours; decimals allowed (for example 4 or 0.25)
  --state-dir DIR            Workspace-local controller state directory
  --repo DIR                 Owned repository path (default: this repo)
  --workspace DIR            Initialized OpenClaw workspace path
  --expected-branch BRANCH   Required branch (default: junie/autonomous-mvp-loop)
  --max-iterations N         Controller max iterations
  --iteration-timeout SECS   Worker timeout seconds per iteration
  --worker-cmd CMD           Optional worker command override, mainly for tests
  --background               Start controller in the background and return status quickly
  --dry-run                  Print planned command/state without starting long work
  --skip-verify              Pass through to controller (mainly tests)
  --allow-main-for-tests     Permit main branch only for isolated tests
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) duration="$2"; shift 2 ;;
    --hours) hours="$2"; shift 2 ;;
    --state-dir) state_dir="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --workspace) workspace="$2"; shift 2 ;;
    --expected-branch) expected_branch="$2"; shift 2 ;;
    --max-iterations) max_iterations="$2"; shift 2 ;;
    --iteration-timeout) iteration_timeout="$2"; shift 2 ;;
    --worker-cmd) worker_cmd="$2"; shift 2 ;;
    --background) background=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    --skip-verify) skip_verify=true; shift ;;
    --allow-main-for-tests) allow_main_for_tests=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

fail() { printf 'BLOCKED: %s\n' "$*" >&2; exit 2; }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

parse_duration_seconds() {
  local input="$1"
  if [[ "$input" =~ ^([0-9]+)([smhd])$ ]]; then
    local n="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}"
    case "$unit" in s) printf '%s\n' "$n" ;; m) printf '%s\n' "$((n * 60))" ;; h) printf '%s\n' "$((n * 3600))" ;; d) printf '%s\n' "$((n * 86400))" ;; esac
  elif [[ "$input" =~ ^([0-9]+)h([0-9]+)m$ ]]; then
    printf '%s\n' "$((BASH_REMATCH[1] * 3600 + BASH_REMATCH[2] * 60))"
  else
    return 1
  fi
}

if [[ -n "$duration" && -n "$hours" ]]; then
  fail 'use only one of --duration or --hours'
fi
if [[ -n "$hours" ]]; then
  seconds=$(awk -v h="$hours" 'BEGIN { if (h !~ /^[0-9]+([.][0-9]+)?$/ || h <= 0) exit 1; printf "%d\n", h * 3600 }') || fail "invalid --hours: $hours"
elif [[ -n "$duration" ]]; then
  seconds=$(parse_duration_seconds "$duration") || fail "invalid --duration: $duration (use 9h, 90m, 3600s, or 1h30m)"
else
  fail 'missing duration; ask the admin one concise question for the desired duration/end time'
fi
[[ "$seconds" -gt 0 ]] || fail 'duration must be positive'

repo="$(cd "$repo" 2>/dev/null && pwd)" || fail "repo not found: $repo"
[[ -d "$repo/.git" ]] || fail "not a git repo: $repo"
if [[ ! -d "$workspace" ]]; then
  fail "initialized workspace not found: $workspace"
fi
workspace="$(cd "$workspace" && pwd)"
if [[ -z "$state_dir" ]]; then
  state_dir="$workspace/.openclaw/state/autonomous-window"
fi
mkdir -p "$state_dir/logs"

branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
if [[ "$branch" == "main" && "$allow_main_for_tests" != true ]]; then
  fail 'refusing to start autonomous work on main'
fi
if [[ -n "$expected_branch" && "$branch" != "$expected_branch" ]]; then
  fail "unexpected branch: $branch (expected $expected_branch)"
fi

status_file="$state_dir/preflight-status.txt"
git -C "$repo" status --short --branch --untracked-files=all >"$status_file"
if git -C "$repo" status --porcelain --untracked-files=all | grep -q .; then
  if [[ "$allow_dirty_for_tests" == true ]]; then
    printf 'WARNING: repo dirty but AUTONOMOUS_ALLOW_DIRTY_FOR_TESTS=true; preflight status: %s\n' "$status_file" >&2
  else
    fail "repo has uncommitted/untracked changes; preflight status: $status_file"
  fi
fi

mutex_dir="$workspace/.openclaw/state/code_mutex"
mutex_file="$state_dir/preflight-mutex.txt"
mutex_status=0
"$repo/scripts/code-mutex-status.sh" --mutex-dir "$mutex_dir" --repo "$repo" >"$mutex_file" 2>&1 || mutex_status=$?
if [[ "$mutex_status" -eq 2 ]]; then
  fail "code mutex is broken; details: $mutex_file"
fi
if grep -qE '^(HELD|STALE) code mutex$' "$mutex_file"; then
  fail "code mutex is not free; details: $mutex_file"
fi

end_epoch=$(( $(date +%s) + seconds ))
run_id="autonomous-window-$(date -u +%Y%m%dT%H%M%SZ)-$$"
log_file="$state_dir/logs/controller-$run_id.log"
pid_file="$state_dir/controller.pid"
window_state="$state_dir/window.json"

cmd=("$repo/scripts/overnight-controller.sh"
  --state-dir "$state_dir/controller"
  --expected-branch "$expected_branch"
  --max-iterations "$max_iterations"
  --iteration-timeout "$iteration_timeout"
  --end-epoch "$end_epoch")
if [[ -n "$worker_cmd" ]]; then
  cmd+=(--worker-cmd "$worker_cmd")
fi
if $skip_verify; then
  cmd+=(--skip-verify)
fi

cat >"$window_state" <<JSON
{
  "run_id": "$(json_escape "$run_id")",
  "started_at": "$(now_utc)",
  "status": "planned",
  "repo": "$(json_escape "$repo")",
  "workspace": "$(json_escape "$workspace")",
  "state_dir": "$(json_escape "$state_dir")",
  "branch": "$(json_escape "$branch")",
  "duration_seconds": $seconds,
  "end_epoch": $end_epoch,
  "controller_log": "$(json_escape "$log_file")",
  "preflight_status": "$(json_escape "$status_file")",
  "preflight_mutex": "$(json_escape "$mutex_file")"
}
JSON

printf 'Autonomous window plan\n'
printf 'repo=%s\nworkspace=%s\nstate_dir=%s\nbranch=%s\nduration_seconds=%s\nend_epoch=%s\nlog=%s\n' "$repo" "$workspace" "$state_dir" "$branch" "$seconds" "$end_epoch" "$log_file"
printf 'controller_cmd='
printf '%q ' "${cmd[@]}"
printf '\n'

if $dry_run; then
  printf 'dry_run=true; controller not started\n'
  exit 0
fi

if $background; then
  (
    cd "$repo"
    "${cmd[@]}" >>"$log_file" 2>&1
  ) &
  pid=$!
  printf '%s\n' "$pid" >"$pid_file"
  sed 's/"status": "planned"/"status": "running"/' "$window_state" >"$window_state.tmp" && mv "$window_state.tmp" "$window_state"
  printf 'started=true\npid=%s\npid_file=%s\nstate=%s\nlog=%s\n' "$pid" "$pid_file" "$window_state" "$log_file"
else
  cd "$repo"
  "${cmd[@]}" 2>&1 | tee -a "$log_file"
fi

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$ROOT"
state_dir="${OVERNIGHT_STATE_DIR:-${HOME:-$ROOT}/.openclaw/workspace-junie-live/.openclaw/state/overnight}"
worker_cmd="${OVERNIGHT_WORKER_CMD:-$ROOT/scripts/drive.sh}"
expected_branch="${OVERNIGHT_EXPECTED_BRANCH:-junie/autonomous-mvp-loop}"
max_iterations="${OVERNIGHT_MAX_ITERATIONS:-1}"
iteration_timeout="${OVERNIGHT_ITERATION_TIMEOUT_SECONDS:-900}"
end_epoch="${OVERNIGHT_END_EPOCH:-}"
dry_run=false
skip_verify=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-dir) state_dir="$2"; shift 2 ;;
    --worker-cmd) worker_cmd="$2"; shift 2 ;;
    --expected-branch) expected_branch="$2"; shift 2 ;;
    --max-iterations) max_iterations="$2"; shift 2 ;;
    --iteration-timeout) iteration_timeout="$2"; shift 2 ;;
    --end-epoch) end_epoch="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    --skip-verify) skip_verify=true; shift ;;
    *) printf 'Unknown: %s\n' "$1" >&2; exit 2 ;;
  esac
done

mkdir -p "$state_dir/logs"
run_id="overnight-$(date -u +%Y%m%dT%H%M%SZ)-$$"
state_file="$state_dir/state.json"
log_file="$state_dir/logs/controller-$run_id.log"
worker_log="$state_dir/logs/worker-$run_id.log"

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
write_state() {
  local phase="$1" status="${2:-running}" expected="${3:-continue overnight routine}" worker_pid="${4:-}" last_verify="${5:-unknown}"
  local branch last_commit
  branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || printf unknown)
  last_commit=$(git -C "$repo" log -1 --format=%H 2>/dev/null || true)
  cat >"$state_file" <<JSON
{
  "run_id": "$(json_escape "$run_id")",
  "started_at": "$(json_escape "$started_at")",
  "updated_at": "$(now)",
  "phase": "$(json_escape "$phase")",
  "status": "$(json_escape "$status")",
  "pid": $$,
  "worker_pid": "$(json_escape "$worker_pid")",
  "iteration": $iteration,
  "branch": "$(json_escape "$branch")",
  "repo": "$(json_escape "$repo")",
  "expected_next_action": "$(json_escape "$expected")",
  "last_commit": "$(json_escape "$last_commit")",
  "last_verify_status": "$(json_escape "$last_verify")",
  "commit_policy": "commits are worker responsibility; iteration-counter subjects such as Autonomous MVP loop iteration N are rejected by verify"
}
JSON
}

log() { printf '[%s] %s\n' "$(now)" "$*" | tee -a "$log_file"; }

cd "$repo"
branch=$(git rev-parse --abbrev-ref HEAD)
if [[ "$branch" == "main" ]]; then
  printf 'Refusing to run overnight controller on main\n' >&2
  exit 2
fi
if [[ -n "$expected_branch" && "$branch" != "$expected_branch" ]]; then
  printf 'Unexpected branch: %s (expected %s)\n' "$branch" "$expected_branch" >&2
  exit 2
fi

started_at="$(now)"
iteration=0
last_verify="not_run"
write_state starting running "check branch and prepare worker"
log "run_id=$run_id branch=$branch state_dir=$state_dir"

while [[ "$iteration" -lt "$max_iterations" ]]; do
  if [[ -n "$end_epoch" && "$(date +%s)" -ge "$end_epoch" ]]; then
    log "end epoch reached"
    break
  fi
  iteration=$((iteration + 1))
  write_state worker_starting running "run timeout-wrapped worker command"
  log "iteration=$iteration worker_cmd=$worker_cmd timeout=${iteration_timeout}s"
  if $dry_run; then
    printf 'dry_run worker skipped\n' >>"$worker_log"
    worker_status=0
  else
    set +e
    timeout --foreground --kill-after=5s "$iteration_timeout" bash -c "$worker_cmd" >>"$worker_log" 2>&1 &
    worker_pid=$!
    write_state worker_running running "worker should finish or timeout" "$worker_pid" "$last_verify"
    wait "$worker_pid"
    worker_status=$?
    set -e
  fi
  if [[ "$worker_status" -eq 124 || "$worker_status" -eq 137 ]]; then
    log "worker timed out with status=$worker_status"
    write_state worker_timeout timeout "watchdog should inspect and preserve logs" "" "$last_verify"
    exit 124
  elif [[ "$worker_status" -ne 0 ]]; then
    log "worker failed with status=$worker_status"
    write_state worker_failed failed "inspect worker log" "" "$last_verify"
    exit "$worker_status"
  fi

  write_state verifying running "run verification gates" "" "$last_verify"
  if $skip_verify || $dry_run; then
    last_verify="skipped"
    log "verification skipped"
  else
    set +e
    ./scripts/verify.sh >>"$log_file" 2>&1
    verify_status=$?
    git diff --check >>"$log_file" 2>&1
    diff_status=$?
    set -e
    if [[ "$verify_status" -eq 0 && "$diff_status" -eq 0 ]]; then
      last_verify="passed"
    else
      last_verify="failed:verify=$verify_status,diff=$diff_status"
      write_state verify_failed failed "fix verification failures" "" "$last_verify"
      exit 1
    fi
  fi
  write_state iteration_complete running "continue until max iterations or end time" "" "$last_verify"
done

write_state complete complete "run morning report" "" "$last_verify"
log "complete iterations=$iteration last_verify=$last_verify"

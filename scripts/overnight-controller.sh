#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/runtime-paths.sh
source "$ROOT/scripts/runtime-paths.sh"
repo="$ROOT"
state_dir="${OVERNIGHT_STATE_DIR:-$(junie_overnight_state_dir_default)}"
worker_cmd="${OVERNIGHT_WORKER_CMD:-$ROOT/scripts/drive.sh}"
expected_branch="${OVERNIGHT_EXPECTED_BRANCH:-junie/autonomous-mvp-loop}"
max_iterations="${OVERNIGHT_MAX_ITERATIONS:-1}"
iteration_timeout="${OVERNIGHT_ITERATION_TIMEOUT_SECONDS:-7200}"
fix_retries="${AUTONOMOUS_FIX_RETRIES:-7}"
cleanup_cmd="${AUTONOMOUS_CLEANUP_CMD:-$ROOT/scripts/cleanup-failed-task.sh}"
verify_cmd="${AUTONOMOUS_VERIFY_CMD:-./scripts/verify.sh}"
end_epoch="${OVERNIGHT_END_EPOCH:-}"
dry_run=false
skip_verify=false
allow_main_for_tests=false
continue_on_local_failure=false
max_local_failures="${AUTONOMOUS_MAX_LOCAL_FAILURES:-0}"
local_failures=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-dir) state_dir="$2"; shift 2 ;;
    --worker-cmd) worker_cmd="$2"; shift 2 ;;
    --expected-branch) expected_branch="$2"; shift 2 ;;
    --max-iterations) max_iterations="$2"; shift 2 ;;
    --iteration-timeout) iteration_timeout="$2"; shift 2 ;;
    --fix-retries) fix_retries="$2"; shift 2 ;;
    --verify-cmd) verify_cmd="$2"; shift 2 ;;
    --end-epoch) end_epoch="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    --skip-verify) skip_verify=true; shift ;;
    --continue-on-local-failure) continue_on_local_failure=true; shift ;;
    --allow-main-for-tests) allow_main_for_tests=true; shift ;;
    --max-local-failures) max_local_failures="$2"; shift 2 ;;
    *) printf 'Unknown: %s\n' "$1" >&2; exit 2 ;;
  esac
done

mkdir -p "$state_dir/logs"
run_id="overnight-$(date -u +%Y%m%dT%H%M%SZ)-$$"
state_file="$state_dir/state.json"
log_file="$state_dir/logs/controller-$run_id.log"
worker_log="$state_dir/logs/worker-$run_id.log"
fix_log="$state_dir/logs/fix-$run_id.log"
verify_log="$state_dir/logs/verify-$run_id.log"

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
  "fix_retries": $fix_retries,
  "continue_on_local_failure": $continue_on_local_failure,
  "max_local_failures": $max_local_failures,
  "local_failures": $local_failures,
  "commit_policy": "commits are worker responsibility; iteration-counter subjects such as Autonomous MVP loop iteration N are rejected by verify"
}
JSON
}

run_verify(){ local out="$1"; : >"$out"; if $skip_verify || $dry_run; then echo skipped >>"$out"; return 0; fi; set +e; bash -c "$verify_cmd" >>"$out" 2>&1; local vs=$?; git diff --check >>"$out" 2>&1; local ds=$?; set -e; [[ $vs -eq 0 && $ds -eq 0 ]]; }
block_task(){
  BACKLOG_DIR="${BACKLOG_DIR:-$(junie_backlog_dir_default)}" MUTEX_DIR="${MUTEX_DIR:-$(junie_mutex_dir_default)}" REFLECTIONS_DIR="${REFLECTIONS_DIR:-$(junie_reflections_dir_default)}" "$ROOT/scripts/task-release.sh" --status blocked >>"$log_file" 2>&1 || true
  "$cleanup_cmd" --repo "$repo" --state-dir "$state_dir/cleanup" --reason "$1" >>"$log_file" 2>&1
}
repo_dirty(){ git -C "$repo" status --porcelain --untracked-files=all | grep -q .; }
handle_local_failure(){
  local phase="$1" exit_status="$2" reason="$3" lastv="${4:-$last_verify}"
  if ! $continue_on_local_failure; then
    local status="failed"; [[ "$phase" == "worker_timeout" ]] && status="timeout"
    write_state "$phase" "$status" "$reason; task blocked and workspace cleaned" "" "$lastv"; block_task "$reason"; exit "$exit_status"
  fi
  local_failures=$((local_failures + 1))
  write_state task_blocked_continue running "$reason; block task, clean workspace, maybe continue" "" "$lastv"
  log "task_blocked_continue local_failures=$local_failures max_local_failures=$max_local_failures reason=$reason"
  if ! block_task "$reason"; then write_state cleanup_failed failed "cleanup failed after local task failure; stop immediately" "" "$lastv"; log "cleanup_failed reason=$reason"; exit 1; fi
  if repo_dirty; then write_state cleanup_failed failed "cleanup left dirty workspace after local task failure; stop immediately" "" "$lastv"; log "cleanup_failed dirty remains reason=$reason"; exit 1; fi
  if [[ "$local_failures" -gt "$max_local_failures" ]]; then write_state too_many_local_failures failed "local failure budget exceeded after blocking task" "" "$lastv"; log "too_many_local_failures local_failures=$local_failures max_local_failures=$max_local_failures"; exit 1; fi
  write_state task_blocked_continue running "blocked failed task and cleaned workspace; continue next iteration" "" "$lastv"; return 0
}
log() { printf '[%s] %s\n' "$(now)" "$*" | tee -a "$log_file"; }

cd "$repo"
branch=$(git rev-parse --abbrev-ref HEAD)
if [[ "$branch" == "main" && "$allow_main_for_tests" != true ]]; then
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
  log "iteration=$iteration worker_cmd=$worker_cmd timeout=${iteration_timeout}s fix_retries=$fix_retries"
  if $dry_run; then
    printf 'dry_run worker skipped\n' >>"$worker_log"
    worker_status=0
  else
    set +e
    AUTONOMOUS_SOLVER_RUN=true AUTONOMOUS_FORCE_HYPOTHESIS_WHEN_EMPTY=true timeout --foreground --kill-after=5s "$iteration_timeout" bash -c "$worker_cmd" >>"$worker_log" 2>&1 &
    worker_pid=$!
    write_state worker_running running "worker should finish or timeout" "$worker_pid" "$last_verify"
    wait "$worker_pid"
    worker_status=$?
    set -e
  fi
  if [[ "$worker_status" -eq 124 || "$worker_status" -eq 137 ]]; then
    log "worker timed out with status=$worker_status"
    handle_local_failure worker_timeout 124 "worker timeout status=$worker_status" "$last_verify"
    continue
  elif [[ "$worker_status" -ne 0 ]]; then
    log "worker failed with status=$worker_status"
    handle_local_failure worker_failed "$worker_status" "worker failed status=$worker_status" "$last_verify"
    continue
  fi

  write_state verifying running "run verification gates" "" "$last_verify"
  if run_verify "$verify_log"; then
    if $skip_verify || $dry_run; then last_verify="skipped"; log "verification skipped"; else last_verify="passed"; fi
  else
    last_verify="failed"; attempt=0; fixed=false
    while [[ "$attempt" -lt "$fix_retries" ]]; do
      attempt=$((attempt+1)); write_state fix_running running "fix verification failure attempt $attempt/$fix_retries" "" "$last_verify"
      set +e; AUTONOMOUS_SOLVER_RUN=true AUTONOMOUS_FORCE_HYPOTHESIS_WHEN_EMPTY=true AUTONOMOUS_FIX_ATTEMPT="$attempt" AUTONOMOUS_VERIFY_LOG="$verify_log" timeout --foreground --kill-after=5s "$iteration_timeout" bash -c "$worker_cmd" <"$verify_log" >>"$fix_log" 2>&1; fs=$?; set -e
      [[ "$fs" -eq 124 || "$fs" -eq 137 ]] && break
      run_verify "$verify_log" && { last_verify="passed_after_fix_$attempt"; fixed=true; break; }
      last_verify="failed_after_fix_$attempt"
    done
    [[ "$fixed" == true ]] || { handle_local_failure verify_failed 1 "verification failed after $fix_retries fix attempts" "$last_verify"; continue; }
  fi
  write_state iteration_complete running "continue until max iterations or end time" "" "$last_verify"
done

write_state complete complete "run report on demand or scheduled if explicitly enabled" "" "$last_verify"
log "complete iterations=$iteration last_verify=$last_verify"

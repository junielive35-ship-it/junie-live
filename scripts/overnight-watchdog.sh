#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/runtime-paths.sh
source "$ROOT/scripts/runtime-paths.sh"
state_dir="${OVERNIGHT_STATE_DIR:-$(junie_overnight_state_dir_default)}"
mutex_dir="${MUTEX_DIR:-$(junie_mutex_dir_default)}"
backlog_dir="${BACKLOG_DIR:-$(junie_backlog_dir_default)}"
repo="$ROOT"
stale_seconds="${OVERNIGHT_STALE_SECONDS:-1800}"
dry_run=true
cleanup=false
release_mutex=false
force_mutex=false
cleanup_cmd="$ROOT/scripts/cleanup-failed-task.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-dir) state_dir="$2"; shift 2 ;;
    --mutex-dir) mutex_dir="$2"; shift 2 ;;
    --backlog-dir) backlog_dir="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --cleanup-cmd) cleanup_cmd="$2"; shift 2 ;;
    --stale-seconds) stale_seconds="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    --cleanup) dry_run=false; cleanup=true; shift ;;
    --release-mutex) release_mutex=true; shift ;;
    --force-mutex) force_mutex=true; shift ;;
    *) printf 'Unknown: %s
' "$1" >&2; exit 2 ;;
  esac
done

mkdir -p "$state_dir/logs"
findings="$state_dir/watchdog-findings.txt"
: >"$findings"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
field() { local f="$1" k="$2"; grep -o '"'"$k"'"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*"'"$k"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true; }
numfield() { local f="$1" k="$2"; grep -o '"'"$k"'"[[:space:]]*:[[:space:]]*[0-9]*' "$f" 2>/dev/null | head -1 | sed 's/.*"'"$k"'"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/' || true; }
say() { printf '%s
' "$*" | tee -a "$findings"; }
is_terminal_status() { case "$1" in complete|failed|timeout) return 0 ;; *) return 1 ;; esac; }
mark_state_failed() {
  local reason="$1"
  [[ -f "$state_file" ]] || return 0
  python3 - "$state_file" "$reason" "$(now)" <<'PY'
import json, sys
path, reason, now = sys.argv[1:]
with open(path, encoding="utf-8") as fh:
    state = json.load(fh)
state["updated_at"] = now
state["phase"] = "stale_controller"
state["status"] = "failed"
state["expected_next_action"] = reason
state["worker_pid"] = ""
with open(path, "w", encoding="utf-8") as fh:
    json.dump(state, fh, indent=2)
    fh.write("\n")
PY
}
cleanup_repo_if_needed() {
  if $cleanup && [[ "$status" -ge 2 && -x "$cleanup_cmd" ]]; then
    "$cleanup_cmd" --repo "$repo" --state-dir "$state_dir/cleanup" --reason "watchdog cleanup for stale or broken overnight state" >>"$findings" 2>&1 || { say "cleanup_repo_status=failed"; return 1; }
    say "cleanup_repo_status=clean"
  fi
}

state_file="$state_dir/state.json"
status=0
say "watchdog_ran_at=$(now)"
if [[ ! -f "$state_file" ]]; then
  say "watchdog_status=idle"
  say "reason=no controller state found at $state_file"
  if [[ ! -d "$mutex_dir" ]]; then
    say "mutex_status=free"
    exit 0
  fi
  say "NOTE mutex exists while no controller state is present; checking mutex health"
fi

run_id=""; phase=""; run_status=""; updated_at=""; pid=""; worker_pid=""
if [[ -f "$state_file" ]]; then
  run_id=$(field "$state_file" run_id)
  phase=$(field "$state_file" phase)
  run_status=$(field "$state_file" status)
  updated_at=$(field "$state_file" updated_at)
  pid=$(numfield "$state_file" pid)
  worker_pid=$(field "$state_file" worker_pid)
fi
say "run_id=${run_id:-none} phase=${phase:-none} status=${run_status:-none}"
terminal=false
if is_terminal_status "${run_status:-}"; then
  terminal=true
  say "terminal_status=true"
  if [[ "$run_status" != "complete" ]]; then say "WARNING terminal controller status is $run_status"; status=1; fi
else
  say "terminal_status=false"
fi

age=999999
if [[ -n "$updated_at" ]]; then ts=$(date -d "$updated_at" +%s 2>/dev/null || echo 0); age=$(( $(date +%s) - ts )); fi
say "state_age_seconds=$age"
if [[ -f "$state_file" && "$age" -gt "$stale_seconds" && "$terminal" != true ]]; then say "WARNING stale controller progress"; status=1; fi

if [[ ! -f "$state_file" ]]; then
  say "controller_pid_check=skipped_idle"
elif [[ "$terminal" == true ]]; then
  say "controller_pid_check=skipped_terminal_status"
else
  if [[ -n "$pid" && "$pid" != "0" ]]; then
    if kill -0 "$pid" 2>/dev/null; then
      say "controller_pid_alive=true"
    else
      say "WARNING controller pid not alive: $pid"; status=1
      if $cleanup && [[ "$age" -gt "$stale_seconds" && -z "$worker_pid" ]]; then
        mark_state_failed "stale controller pid $pid is not alive; inspect controller log and restart explicitly if needed"
        say "state_action=marked_failed_stale_controller"
        terminal=true
        run_status=failed
      fi
    fi
  else
    say "WARNING controller pid missing"; status=1
    if $cleanup && [[ "$age" -gt "$stale_seconds" && -z "$worker_pid" ]]; then
      mark_state_failed "stale controller pid missing; inspect controller log and restart explicitly if needed"
      say "state_action=marked_failed_stale_controller"
      terminal=true
      run_status=failed
    fi
  fi
fi

if [[ -n "$worker_pid" ]]; then
  if [[ "$terminal" == true ]]; then
    say "worker_pid_check=skipped_terminal_status pid=$worker_pid"
  elif kill -0 "$worker_pid" 2>/dev/null; then
    say "worker_pid_alive=true pid=$worker_pid"
    if [[ "$age" -gt "$stale_seconds" ]]; then
      say "CRITICAL worker appears stuck pid=$worker_pid"; status=2
      if $cleanup; then kill -TERM "-$worker_pid" 2>/dev/null || kill -TERM "$worker_pid" 2>/dev/null || true; say "cleanup=sent_TERM_to_worker_$worker_pid"; else say "cleanup=would_terminate_worker_$worker_pid"; fi
    fi
  else
    say "WARNING worker pid not alive: $worker_pid"; status=1
  fi
fi

if [[ -d "$mutex_dir" ]]; then
  holder="$mutex_dir/holder.json"
  if [[ ! -f "$holder" ]]; then
    say "CRITICAL mutex directory missing holder.json"; status=2
  else
    holder_id=$(field "$holder" holder_id)
    updated=$(field "$holder" updated_at); [[ -z "$updated" ]] && updated=$(field "$holder" started_at)
    mage=999999
    if [[ -n "$updated" ]]; then mts=$(date -d "$updated" +%s 2>/dev/null || echo 0); mage=$(( $(date +%s) - mts )); fi
    say "mutex_holder=${holder_id:-unknown} mutex_age_seconds=$mage"
    if [[ "$mage" -gt "$stale_seconds" ]]; then
      if { [[ -n "${run_id:-}" && "${holder_id:-}" == "$run_id" ]] || [[ "$force_mutex" == true ]]; }; then
        say "WARNING stale mutex releasable"; [[ "$status" -lt 1 ]] && status=1
        if $release_mutex && ! $dry_run; then
          cleanup_repo_if_needed || status=2
          BACKLOG_DIR="$backlog_dir" MUTEX_DIR="$mutex_dir" "$ROOT/scripts/task-release.sh" --status blocked >>"$findings" 2>&1 || { rm -rf "$mutex_dir"; say "mutex_action=force_released_after_task_release_failed"; }
          [[ -d "$mutex_dir" ]] || say "mutex_action=released"
        else
          say "mutex_action=would_release"
        fi
      else
        say "CRITICAL stale mutex holder does not match overnight run"; status=2
      fi
    fi
  fi
else
  say "mutex_status=free"
fi

# ---- Backlog in_progress items without active owner (contract: stuck detection requirement 6) ----
if [[ -d "$backlog_dir/items" ]]; then
  orphan_count=0
  for bf in "$backlog_dir/items"/*.json; do
    [[ -f "$bf" ]] || continue
    bstatus=$(field "$bf" status)
    [[ "$bstatus" == "in_progress" ]] || continue
    bupdated=$(field "$bf" updated_at)
    bage=999999
    if [[ -n "$bupdated" ]]; then
      bts=$(date -d "$bupdated" +%s 2>/dev/null || echo 0)
      bage=$(( $(date +%s) - bts ))
    fi
    if [[ "$bage" -gt "$stale_seconds" ]]; then
      bid=$(field "$bf" id)
      # Check if there is an active (non-terminal) controller that might own this item
      if [[ "$terminal" == true || ! -f "$state_file" ]]; then
        orphan_count=$((orphan_count + 1))
        say "WARNING backlog item stuck in_progress without active owner: ${bid:-unknown} (age=${bage}s)"
        [[ "$status" -lt 1 ]] && status=1
      fi
    fi
  done
  say "backlog_stuck_in_progress=$orphan_count"
fi

exit "$status"

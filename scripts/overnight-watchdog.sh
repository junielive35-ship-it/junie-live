#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/runtime-paths.sh
source "$ROOT/scripts/runtime-paths.sh"
state_dir="${OVERNIGHT_STATE_DIR:-$(junie_overnight_state_dir_default)}"
mutex_dir="${MUTEX_DIR:-$(junie_mutex_dir_default)}"
stale_seconds="${OVERNIGHT_STALE_SECONDS:-1800}"
dry_run=true
cleanup=false
release_mutex=false
force_mutex=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-dir) state_dir="$2"; shift 2 ;;
    --mutex-dir) mutex_dir="$2"; shift 2 ;;
    --stale-seconds) stale_seconds="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    --cleanup) dry_run=false; cleanup=true; shift ;;
    --release-mutex) release_mutex=true; shift ;;
    --force-mutex) force_mutex=true; shift ;;
    *) printf 'Unknown: %s\n' "$1" >&2; exit 2 ;;
  esac
done

mkdir -p "$state_dir/logs"
findings="$state_dir/watchdog-findings.txt"
: >"$findings"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
field() { local f="$1" k="$2"; grep -o '"'"$k"'"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*"'"$k"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true; }
numfield() { local f="$1" k="$2"; grep -o '"'"$k"'"[[:space:]]*:[[:space:]]*[0-9]*' "$f" 2>/dev/null | head -1 | sed 's/.*"'"$k"'"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/' || true; }
say() { printf '%s\n' "$*" | tee -a "$findings"; }
is_terminal_status() {
  case "$1" in
    complete|failed|timeout) return 0 ;;
    *) return 1 ;;
  esac
}

state_file="$state_dir/state.json"
status=0
say "watchdog_ran_at=$(now)"
if [[ ! -f "$state_file" ]]; then
  say "CRITICAL no controller state found at $state_file"
  exit 2
fi

run_id=$(field "$state_file" run_id)
phase=$(field "$state_file" phase)
run_status=$(field "$state_file" status)
updated_at=$(field "$state_file" updated_at)
pid=$(numfield "$state_file" pid)
worker_pid=$(field "$state_file" worker_pid)
say "run_id=${run_id:-unknown} phase=${phase:-unknown} status=${run_status:-unknown}"
terminal=false
if is_terminal_status "${run_status:-}"; then
  terminal=true
  say "terminal_status=true"
  if [[ "$run_status" != "complete" ]]; then
    say "WARNING terminal controller status is $run_status"
    status=1
  fi
else
  say "terminal_status=false"
fi

age=999999
if [[ -n "$updated_at" ]]; then
  ts=$(date -d "$updated_at" +%s 2>/dev/null || echo 0)
  age=$(( $(date +%s) - ts ))
fi
say "state_age_seconds=$age"
if [[ "$age" -gt "$stale_seconds" && "$terminal" != true ]]; then
  say "WARNING stale controller progress"
  status=1
fi

if [[ "$terminal" == true ]]; then
  say "controller_pid_check=skipped_terminal_status"
else
  if [[ -n "$pid" && "$pid" != "0" ]]; then
    if kill -0 "$pid" 2>/dev/null; then say "controller_pid_alive=true"; else say "WARNING controller pid not alive: $pid"; status=1; fi
  else
    say "WARNING controller pid missing"
    status=1
  fi
fi

if [[ -n "$worker_pid" ]]; then
  if [[ "$terminal" == true ]]; then
    say "worker_pid_check=skipped_terminal_status pid=$worker_pid"
  elif kill -0 "$worker_pid" 2>/dev/null; then
    say "worker_pid_alive=true pid=$worker_pid"
    if [[ "$age" -gt "$stale_seconds" ]]; then
      say "CRITICAL worker appears stuck pid=$worker_pid"
      status=2
      if $cleanup; then
        kill -TERM "-$worker_pid" 2>/dev/null || kill -TERM "$worker_pid" 2>/dev/null || true
        say "cleanup=sent_TERM_to_worker_$worker_pid"
      else
        say "cleanup=would_terminate_worker_$worker_pid"
      fi
    fi
  else
    say "WARNING worker pid not alive: $worker_pid"
    status=1
  fi
fi

if [[ -d "$mutex_dir" ]]; then
  holder="$mutex_dir/holder.json"
  if [[ ! -f "$holder" ]]; then
    say "CRITICAL mutex directory missing holder.json"
    status=2
  else
    holder_id=$(field "$holder" holder_id)
    updated=$(field "$holder" updated_at); [[ -z "$updated" ]] && updated=$(field "$holder" started_at)
    mage=999999
    if [[ -n "$updated" ]]; then mts=$(date -d "$updated" +%s 2>/dev/null || echo 0); mage=$(( $(date +%s) - mts )); fi
    say "mutex_holder=${holder_id:-unknown} mutex_age_seconds=$mage"
    if [[ "$mage" -gt "$stale_seconds" ]]; then
      if [[ "${holder_id:-}" == "$run_id" || "$force_mutex" == true ]]; then
        say "WARNING stale mutex releasable"
        status=1
        if $release_mutex && ! $dry_run; then rm -rf "$mutex_dir"; say "mutex_action=released"; else say "mutex_action=would_release"; fi
      else
        say "CRITICAL stale mutex holder does not match overnight run"
        status=2
      fi
    fi
  fi
else
  say "mutex_status=free"
fi

if [[ "$run_status" == "complete" && ! -f "$state_dir/morning-report.txt" ]]; then
  say "WARNING morning report missing after completed run"
  [[ "$status" -lt 1 ]] && status=1
fi

exit "$status"

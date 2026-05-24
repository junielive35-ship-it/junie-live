#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backlog_dir="${BACKLOG_DIR:-$ROOT/state/backlog}"
mutex_dir="${MUTEX_DIR:-$ROOT/.openclaw/state/code_mutex}"
hypothesis_state_dir="${HYPOTHESIS_STATE_DIR:-$ROOT/state/hypothesis}"
repo="${REPO:-$ROOT}"
stale_minutes=60
stale_hours=24
hypothesis_interval_hours=24

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backlog-dir) backlog_dir="$2"; shift 2 ;;
    --mutex-dir) mutex_dir="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --stale-minutes) stale_minutes="$2"; shift 2 ;;
    --stale-hours) stale_hours="$2"; shift 2 ;;
    --hypothesis-interval-hours) hypothesis_interval_hours="$2"; shift 2 ;;
    *) printf 'Unknown: %s\n' "$1" >&2; exit 2 ;;
  esac
done

rpt="$(mktemp)"
rpt_exit=0
BACKLOG_DIR="$backlog_dir" MUTEX_DIR="$mutex_dir" REPO="$repo" \
  "$ROOT/scripts/report.sh" \
  --stale-minutes "$stale_minutes" --stale-hours "$stale_hours" \
  >"$rpt" 2>/dev/null || rpt_exit=$?

read_val() { grep "^${1}=" "$rpt" 2>/dev/null | sed 's/^[^=]*=//' || true; }

mutex=$(read_val mutex)
backlog_queued=$(read_val backlog_queued)
backlog_ip=$(read_val backlog_in_progress)
backlog_next=$(read_val backlog_next)
pr_check=$(read_val pr_check_available)
pr_failing=$(read_val pr_failing)
pr_stale=$(read_val pr_stale)
overall_status=$(read_val status)

rm -f "$rpt"

action=""
reason=""

if [[ "$mutex" == "BROKEN" ]]; then
  action="fix_mutex"
  reason="Code mutex is broken (missing or invalid holder.json)"
elif [[ "$mutex" == "STALE" ]]; then
  action="release_stale_mutex"
  reason="Code mutex is stale; investigate and release if worker is dead"
elif [[ "$mutex" == "HELD" ]]; then
  holder_json="$mutex_dir/holder.json"
  held_task_id=""
  if [[ -f "$holder_json" ]]; then
    held_task_id=$(grep -o '"task_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$holder_json" 2>/dev/null | head -1 | sed 's/.*"task_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || true
  fi
  if [[ -n "$held_task_id" ]]; then
    item_file="$backlog_dir/items/$held_task_id.json"
    if [[ -f "$item_file" ]]; then
      item_status=$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$item_file" 2>/dev/null | head -1 | sed 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || true
      case "$item_status" in
        done|cancelled|blocked|archived)
          action="release_completed_task"
          reason="Task ${held_task_id} is ${item_status} but mutex is still held"
          ;;
      esac
    fi
  fi
fi

if [[ -n "$action" ]]; then
  : # action already set by priority checks above
elif [[ "$overall_status" == "CRITICAL" ]]; then
  action="investigate_critical"
  reason="Overall status is CRITICAL; investigate before starting new work"
elif [[ "$pr_check" == "true" && "${pr_failing:-0}" -gt 0 ]]; then
  action="address_failing_ci"
  reason="${pr_failing} PR(s) have failing CI checks"
elif [[ "$pr_check" == "true" && "${pr_stale:-0}" -gt 0 ]]; then
  action="address_stale_prs"
  reason="${pr_stale} PR(s) are stale (no recent activity)"
elif [[ "$mutex" == "FREE" && -n "$backlog_next" && "$backlog_next" != "none" && "${backlog_ip:-0}" -eq 0 ]]; then
  action="start_backlog_item"
  reason="Backlog item ${backlog_next} is highest priority and mutex is free"
elif [[ "$mutex" == "FREE" && -n "$backlog_next" && "$backlog_next" != "none" && "${backlog_ip:-0}" -gt 0 ]]; then
  action="check_stale_in_progress"
  reason="Backlog has in_progress items but mutex is free; may be stale"
elif [[ "$mutex" == "FREE" && "${backlog_ip:-0}" -gt 0 ]]; then
  action="check_stale_in_progress"
  reason="Backlog has in_progress items but mutex is free; may be stale"
elif [[ "$mutex" == "HELD" ]]; then
  action="wait_for_mutex"
  reason="Code mutex is held; cannot start new code work"
elif [[ -z "$backlog_next" || "$backlog_next" == "none" ]]; then
  hyp_last=""
  [[ -f "$hypothesis_state_dir/last_generated" ]] && hyp_last=$(cat "$hypothesis_state_dir/last_generated")
  hyp_interval_seconds=$((hypothesis_interval_hours * 3600))
  now_epoch=$(date +%s)
  if [[ -z "$hyp_last" ]] || [[ $((now_epoch - hyp_last)) -ge $hyp_interval_seconds ]]; then
    action="generate_hypotheses"
    reason="No pending backlog items and hypothesis generation interval has elapsed"
  else
    action="idle"
    reason="No pending backlog items and no issues requiring attention"
  fi
else
  action="idle"
  reason="No actionable items detected"
fi

printf 'action=%s\n' "$action"
printf 'reason=%s\n' "$reason"
printf 'mutex=%s\n' "${mutex:-UNKNOWN}"
printf 'backlog_queued=%s\n' "${backlog_queued:-0}"
printf 'backlog_in_progress=%s\n' "${backlog_ip:-0}"
printf 'backlog_next=%s\n' "${backlog_next:-none}"
printf 'overall_status=%s\n' "${overall_status:-UNKNOWN}"

case "$action" in
  fix_mutex|release_stale_mutex|investigate_critical|address_failing_ci)
    exit 2 ;;
  address_stale_prs|start_backlog_item|check_stale_in_progress)
    exit 1 ;;
  release_completed_task|generate_hypotheses|wait_for_mutex|idle)
    exit 0 ;;
esac

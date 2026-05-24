#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backlog_dir="${BACKLOG_DIR:-$ROOT/state/backlog}"
mutex_dir="${MUTEX_DIR:-$ROOT/.openclaw/state/code_mutex}"
repo="${REPO:-$ROOT}"
stale_minutes=60
stale_hours=24

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backlog-dir) backlog_dir="$2"; shift 2 ;;
    --mutex-dir) mutex_dir="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --stale-minutes) stale_minutes="$2"; shift 2 ;;
    --stale-hours) stale_hours="$2"; shift 2 ;;
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
elif [[ "$mutex" == "HELD" ]]; then
  action="wait_for_mutex"
  reason="Code mutex is held; cannot start new code work"
elif [[ -z "$backlog_next" || "$backlog_next" == "none" ]]; then
  action="idle"
  reason="No pending backlog items and no issues requiring attention"
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
  wait_for_mutex|idle)
    exit 0 ;;
esac

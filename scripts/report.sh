#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/runtime-paths.sh
source "$ROOT/scripts/runtime-paths.sh"

backlog_dir="${BACKLOG_DIR:-$(junie_backlog_dir_default)}"
mutex_dir="${MUTEX_DIR:-$(junie_mutex_dir_default)}"
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

rh_out=$(mktemp)
rh_exit=0
BACKLOG_DIR="$backlog_dir" MUTEX_DIR="$mutex_dir" \
  "$ROOT/scripts/routine-health.sh" --stale-minutes "$stale_minutes" >"$rh_out" 2>/dev/null || rh_exit=$?

pr_out=$(mktemp)
pr_exit=0
"$ROOT/scripts/pr-status.sh" --repo "$repo" --stale-hours "$stale_hours" >"$pr_out" 2>/dev/null || pr_exit=$?

read_val() {
  local f="$1" k="$2"
  grep "^${k}=" "$f" 2>/dev/null | sed 's/^[^=]*=//' || true
}

rh_mutex=$(read_val "$rh_out" mutex_status) || rh_mutex="UNKNOWN"
rh_details=$(read_val "$rh_out" details) || rh_details=""
rh_backlog_total=$(read_val "$rh_out" backlog_total_items) || rh_backlog_total="0"
rh_backlog_queued=$(read_val "$rh_out" backlog_queued) || rh_backlog_queued="0"
rh_backlog_queued_hyp=$(read_val "$rh_out" backlog_queued_hypothesis) || rh_backlog_queued_hyp="0"
rh_backlog_queued_task=$(read_val "$rh_out" backlog_queued_task) || rh_backlog_queued_task="0"
rh_backlog_queued_fix=$(read_val "$rh_out" backlog_queued_fix) || rh_backlog_queued_fix="0"
rh_backlog_ip=$(read_val "$rh_out" backlog_in_progress) || rh_backlog_ip="0"
rh_backlog_completed=$(read_val "$rh_out" backlog_completed) || rh_backlog_completed="0"
rh_backlog_blocked=$(read_val "$rh_out" backlog_blocked) || rh_backlog_blocked="0"
rh_backlog_next=$(read_val "$rh_out" backlog_next) || rh_backlog_next="none"

mutex_holder_id=""
mutex_task_id=""
if [[ -d "$mutex_dir" && -f "$mutex_dir/holder.json" ]]; then
  mutex_holder_id=$(grep -o '"holder_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$mutex_dir/holder.json" 2>/dev/null | head -1 | sed 's/.*"holder_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || true
  mutex_task_id=$(grep -o '"task_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$mutex_dir/holder.json" 2>/dev/null | head -1 | sed 's/.*"task_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || true
fi

pr_available=$(read_val "$pr_out" pr_check_available) || pr_available="false"
pr_open=$(read_val "$pr_out" open_prs) || pr_open="0"
pr_stale=$(read_val "$pr_out" stale_prs) || pr_stale="0"
pr_failing=$(read_val "$pr_out" failing_ci) || pr_failing="0"
pr_pending=$(read_val "$pr_out" pending_ci) || pr_pending="0"
pr_details=$(read_val "$pr_out" details) || pr_details=""

rm -f "$rh_out" "$pr_out"

overall_exit=0
overall_status="OK"
if [[ "$rh_exit" -ge 2 || "$pr_exit" -ge 2 ]]; then
  overall_status="CRITICAL"
  overall_exit=2
elif [[ "$rh_exit" -ge 1 || "$pr_exit" -ge 1 ]]; then
  overall_status="WARNING"
  overall_exit=1
fi

summary="mutex=$rh_mutex"
if [[ "$rh_backlog_total" -gt 0 ]]; then
  summary="${summary}, backlog=${rh_backlog_total} (${rh_backlog_queued} queued"
  [[ "$rh_backlog_queued_hyp" -gt 0 ]] && summary="${summary}, ${rh_backlog_queued_hyp} hypotheses"
  [[ "$rh_backlog_queued_task" -gt 0 ]] && summary="${summary}, ${rh_backlog_queued_task} tasks"
    [[ "$rh_backlog_queued_fix" -gt 0 ]] && summary="${summary}, ${rh_backlog_queued_fix} fixes"
    summary="${summary}, ${rh_backlog_ip} in_progress, ${rh_backlog_completed} completed"
    [[ "$rh_backlog_blocked" -gt 0 ]] && summary="${summary}, ${rh_backlog_blocked} blocked"
    summary="${summary})"
else
  summary="${summary}, backlog=empty"
fi
if [[ "$pr_available" == "true" ]]; then
  summary="${summary}, prs=${pr_open} open"
  [[ "$pr_failing" -gt 0 ]] && summary="${summary}, ${pr_failing} failing"
  [[ "$pr_stale" -gt 0 ]] && summary="${summary}, ${pr_stale} stale"
  [[ "$pr_pending" -gt 0 ]] && summary="${summary}, ${pr_pending} pending"
else
  summary="${summary}, prs=unavailable"
fi
[[ -n "$rh_details" && "$rh_details" != "All nominal" ]] && summary="${summary} | health: ${rh_details}"
if [[ -n "$pr_details" && "$pr_details" != "No open PRs" && "$pr_details" != "gh CLI not available" ]]; then
  summary="${summary} | pr: ${pr_details}"
fi

printf 'status=%s\n' "$overall_status"
printf 'mutex=%s\n' "$rh_mutex"
printf 'backlog_total=%s\n' "$rh_backlog_total"
printf 'backlog_queued=%s\n' "$rh_backlog_queued"
printf 'backlog_queued_hypothesis=%s\n' "$rh_backlog_queued_hyp"
printf 'backlog_queued_task=%s\n' "$rh_backlog_queued_task"
printf 'backlog_queued_fix=%s\n' "$rh_backlog_queued_fix"
printf 'backlog_in_progress=%s\n' "$rh_backlog_ip"
printf 'backlog_completed=%s\n' "$rh_backlog_completed"
printf 'backlog_blocked=%s\n' "$rh_backlog_blocked"
printf 'backlog_next=%s\n' "$rh_backlog_next"
printf 'mutex_holder_id=%s\n' "${mutex_holder_id:-}"
printf 'mutex_task_id=%s\n' "${mutex_task_id:-}"
printf 'pr_check_available=%s\n' "$pr_available"
printf 'open_prs=%s\n' "$pr_open"
printf 'pr_failing=%s\n' "$pr_failing"
printf 'pr_stale=%s\n' "$pr_stale"
printf 'pr_pending=%s\n' "$pr_pending"
printf 'summary=%s\n' "$summary"

exit "$overall_exit"

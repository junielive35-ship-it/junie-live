#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

backlog_dir="${BACKLOG_DIR:-$ROOT/state/backlog}"
mutex_dir="${MUTEX_DIR:-$ROOT/.openclaw/state/code_mutex}"
repo="${REPO:-$ROOT}"
hypothesis_state_dir="${HYPOTHESIS_STATE_DIR:-$ROOT/state/hypothesis}"
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

na_out=$(mktemp)
trap 'rm -f "$na_out"' EXIT

backlog_has_queued_source() {
  local source="$1"
  for f in "$backlog_dir/items"/*.json; do
    [[ -f "$f" ]] || continue
    s=$(grep -o '"source"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*"source"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || true
    st=$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || true
    [[ "$s" == "$source" && "$st" == "queued" ]] && return 0
  done
  return 1
}

BACKLOG_DIR="$backlog_dir" MUTEX_DIR="$mutex_dir" REPO="$repo" \
  "$ROOT/scripts/next-action.sh" \
  --stale-minutes "$stale_minutes" --stale-hours "$stale_hours" \
  --hypothesis-interval-hours "$hypothesis_interval_hours" \
  >"$na_out" 2>/dev/null || true

read_val() { grep "^${1}=" "$na_out" 2>/dev/null | sed 's/^[^=]*=//' || true; }

action=$(read_val action)

printf 'action=%s\n' "$action"

case "$action" in
  idle|wait_for_mutex)
    exit 0 ;;
  fix_mutex|release_stale_mutex)
    "$ROOT/scripts/mutex-release-stale.sh" \
      --mutex-dir "$mutex_dir" --backlog-dir "$backlog_dir" \
      --stale-minutes "$stale_minutes" ;;
  start_backlog_item)
    BACKLOG_DIR="$backlog_dir" MUTEX_DIR="$mutex_dir" \
      "$ROOT/scripts/task-acquire.sh" ;;
  release_completed_task)
    BACKLOG_DIR="$backlog_dir" MUTEX_DIR="$mutex_dir" \
      "$ROOT/scripts/task-release.sh" ;;
  check_stale_in_progress)
    BACKLOG_DIR="$backlog_dir" "$ROOT/scripts/backlog-hygiene.sh" \
      --stale-minutes "$stale_minutes" 2>/dev/null || true ;;
  investigate_critical|address_failing_ci|address_stale_prs)
    rpt=$(mktemp)
    BACKLOG_DIR="$backlog_dir" MUTEX_DIR="$mutex_dir" REPO="$repo" \
      "$ROOT/scripts/report.sh" \
      --stale-minutes "$stale_minutes" --stale-hours "$stale_hours" >"$rpt" 2>/dev/null || true
    cat "$rpt"

    pr_failing=$(grep '^pr_failing=' "$rpt" | sed 's/^pr_failing=//')
    pr_stale=$(grep '^pr_stale=' "$rpt" | sed 's/^pr_stale=//')

    if [[ "${pr_failing:-0}" -gt 0 ]] && ! backlog_has_queued_source "system:ci_failure"; then
      BACKLOG_DIR="$backlog_dir" "$ROOT/scripts/backlog.sh" add \
        --type fix --title "Address ${pr_failing} PR(s) with failing CI checks" \
        --source "system:ci_failure" --priority 70 2>/dev/null || true
    fi
    if [[ "${pr_stale:-0}" -gt 0 ]] && ! backlog_has_queued_source "system:stale_pr"; then
      BACKLOG_DIR="$backlog_dir" "$ROOT/scripts/backlog.sh" add \
        --type fix --title "Address ${pr_stale} stale PR(s)" \
        --source "system:stale_pr" --priority 65 2>/dev/null || true
    fi

    rm -f "$rpt" ;;
  generate_hypotheses)
    HYPOTHESIS_STATE_DIR="$hypothesis_state_dir" \
      "$ROOT/scripts/hypothesis-generate.sh" \
      --title "Periodic system health review" \
      --desc "Automated trigger: hypothesis generation interval elapsed. Review current system state and backlog for improvement opportunities." \
      --source "system" \
      --priority 50 2>/dev/null || true
    exit 0 ;;
  *)
    printf 'Unknown action: %s\n' "$action" >&2
    exit 2 ;;
esac

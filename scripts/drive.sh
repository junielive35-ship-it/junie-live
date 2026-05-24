#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

backlog_dir="${BACKLOG_DIR:-$ROOT/state/backlog}"
mutex_dir="${MUTEX_DIR:-$ROOT/.openclaw/state/code_mutex}"
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

na_out=$(mktemp)
trap 'rm -f "$na_out"' EXIT

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
  investigate_critical|address_failing_ci|address_stale_prs|check_stale_in_progress)
    BACKLOG_DIR="$backlog_dir" MUTEX_DIR="$mutex_dir" REPO="$repo" \
      "$ROOT/scripts/report.sh" \
      --stale-minutes "$stale_minutes" --stale-hours "$stale_hours" ;;
  generate_hypotheses)
    exit 0 ;;
  *)
    printf 'Unknown action: %s\n' "$action" >&2
    exit 2 ;;
esac

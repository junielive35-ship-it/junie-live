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

# Periodic backlog hygiene and rescore before the drive decision
"$ROOT/scripts/backlog-hygiene.sh" \
  --stale-minutes "$stale_minutes" \
  --archive-days 7 \
  2>/dev/null || true

"$ROOT/scripts/backlog-rescore.sh" \
  --backlog-dir "$backlog_dir" \
  --max-boost 20 \
  2>/dev/null || true

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
    fup_out=$(mktemp)
    REPO="$repo" "$ROOT/scripts/pr-follow-up.sh" \
      --stale-hours "$stale_hours" >"$fup_out" 2>/dev/null || true
    cat "$fup_out"
    fup_updated=$(grep '^updated=' "$fup_out" | sed 's/^updated=//')
    fup_commented=$(grep '^commented=' "$fup_out" | sed 's/^commented=//')

    rpt=$(mktemp)
    BACKLOG_DIR="$backlog_dir" MUTEX_DIR="$mutex_dir" REPO="$repo" \
      "$ROOT/scripts/report.sh" \
      --stale-minutes "$stale_minutes" --stale-hours "$stale_hours" >"$rpt" 2>/dev/null || true

    pr_failing=$(grep '^pr_failing=' "$rpt" | sed 's/^pr_failing=//')
    pr_stale=$(grep '^pr_stale=' "$rpt" | sed 's/^pr_stale=//')

    remaining_failing=$(( ${pr_failing:-0} - ${fup_commented:-0} ))
    remaining_stale=$(( ${pr_stale:-0} - ${fup_updated:-0} ))

    if [[ "${remaining_failing}" -gt 0 ]] && ! backlog_has_queued_source "system:ci_failure"; then
      BACKLOG_DIR="$backlog_dir" "$ROOT/scripts/backlog.sh" add \
        --type fix --title "Address ${remaining_failing} PR(s) with failing CI checks" \
        --source "system:ci_failure" --priority 70 2>/dev/null || true
    fi
    if [[ "${remaining_stale}" -gt 0 ]] && ! backlog_has_queued_source "system:stale_pr"; then
      BACKLOG_DIR="$backlog_dir" "$ROOT/scripts/backlog.sh" add \
        --type fix --title "Address ${remaining_stale} stale PR(s)" \
        --source "system:stale_pr" --priority 65 2>/dev/null || true
    fi

    rm -f "$rpt" "$fup_out" ;;
  generate_hypotheses)
    pr_failing=$(read_val pr_failing)
    pr_stale=$(read_val pr_stale)
    backlog_queued=$(read_val backlog_queued)
    overall_status=$(read_val overall_status)

    ctx_parts=()
    [[ "${overall_status:-OK}" != "OK" ]] && ctx_parts+=("status=${overall_status}")
    [[ "${backlog_queued:-0}" -gt 0 ]] && ctx_parts+=("${backlog_queued} queued")
    [[ "${pr_failing:-0}" -gt 0 ]] && ctx_parts+=("${pr_failing} failing CI")
    [[ "${pr_stale:-0}" -gt 0 ]] && ctx_parts+=("${pr_stale} stale PRs")

    if [[ "${#ctx_parts[@]}" -gt 0 ]]; then
      ctx_str=$(IFS=', '; printf '%s' "${ctx_parts[*]}")
      title="System health review: ${ctx_str}"
      desc="Automated trigger: hypothesis generation interval elapsed. Current signals: ${ctx_str}."
    else
      title="Periodic system health review"
      desc="Automated trigger: hypothesis generation interval elapsed. All nominal — review for latent improvement opportunities."
    fi

    HYPOTHESIS_STATE_DIR="$hypothesis_state_dir" \
      "$ROOT/scripts/hypothesis-generate.sh" \
      --title "$title" \
      --desc "$desc" \
      --source "system" \
      --priority 50 2>/dev/null || true
    exit 0 ;;
  *)
    printf 'Unknown action: %s\n' "$action" >&2
    exit 2 ;;
esac

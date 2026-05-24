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

# Autonomous loop: repeatedly process cleanup actions until a terminal
# action (idle, wait_for_mutex, start_backlog_item, etc.) is reached.
max_iterations=10
iteration=0
loop_action=""
summary_parts=()
acquire_id=""
acquire_title=""
acquire_type=""
acquire_desc=""

add_summary() { summary_parts+=("$1"); }

hygiene_out=$(mktemp)
"$ROOT/scripts/backlog-hygiene.sh" \
  --stale-minutes "$stale_minutes" \
  --archive-days 7 \
  >"$hygiene_out" 2>/dev/null || true

rh() { grep "^${1}=" "$hygiene_out" 2>/dev/null | sed 's/^[^=]*=//' || true; }
ha=$(rh archived); hr=$(rh reset_in_progress); hs=$(rh stale_queued)
[[ "${ha:-0}" -gt 0 ]] && add_summary "archived ${ha} backlog items"
[[ "${hr:-0}" -gt 0 ]] && add_summary "reset ${hr} stale in-progress items"
[[ "${hs:-0}" -gt 0 ]] && add_summary "${hs} stale queued items"
rm -f "$hygiene_out"

rescore_out=$(mktemp)
"$ROOT/scripts/backlog-rescore.sh" \
  --backlog-dir "$backlog_dir" \
  --max-boost 20 \
  >"$rescore_out" 2>/dev/null || true

rc=$(grep '^rescored=' "$rescore_out" 2>/dev/null | sed 's/^rescored=//' || true)
[[ "${rc:-0}" -gt 0 ]] && add_summary "rescored ${rc} items"
rm -f "$rescore_out"

while [[ $iteration -lt $max_iterations ]]; do
  iteration=$((iteration + 1))

  na_out=$(mktemp)

  HYPOTHESIS_STATE_DIR="$hypothesis_state_dir" \
  BACKLOG_DIR="$backlog_dir" MUTEX_DIR="$mutex_dir" REPO="$repo" \
    "$ROOT/scripts/next-action.sh" \
    --stale-minutes "$stale_minutes" --stale-hours "$stale_hours" \
    --hypothesis-interval-hours "$hypothesis_interval_hours" \
    >"$na_out" 2>/dev/null || true

  read_val() { grep "^${1}=" "$na_out" 2>/dev/null | sed 's/^[^=]*=//' || true; }

  action=$(read_val action)
  reason=$(read_val reason)
  mutex=$(read_val mutex)
  backlog_queued=$(read_val backlog_queued)
  backlog_in_progress=$(read_val backlog_in_progress)
  backlog_next=$(read_val backlog_next)
  pr_failing=$(read_val pr_failing)
  pr_stale=$(read_val pr_stale)
  overall_status=$(read_val overall_status)

  _cont=false

  case "$action" in
    fix_mutex|release_stale_mutex)
      mrs_out=$(mktemp)
      "$ROOT/scripts/mutex-release-stale.sh" \
        --mutex-dir "$mutex_dir" --backlog-dir "$backlog_dir" \
        --stale-minutes "$stale_minutes" >"$mrs_out" 2>/dev/null || true
      mrs_action=$(grep '^action=' "$mrs_out" 2>/dev/null | sed 's/^action=//') || true
      mrs_holder=$(grep '^holder_id=' "$mrs_out" 2>/dev/null | sed 's/^holder_id=//') || true
      case "$mrs_action" in
        released) add_summary "released stale mutex (was: ${mrs_holder:-unknown})" ;;
        removed) add_summary "removed broken mutex" ;;
      esac
      rm -f "$mrs_out"
      _cont=true ;;
    release_completed_task)
      tr_out=$(mktemp)
      BACKLOG_DIR="$backlog_dir" MUTEX_DIR="$mutex_dir" \
        "$ROOT/scripts/task-release.sh" >"$tr_out" 2>/dev/null || true
      tr_id=$(grep '^task_id=' "$tr_out" 2>/dev/null | sed 's/^task_id=//') || true
      tr_status=$(grep '^new_status=' "$tr_out" 2>/dev/null | sed 's/^new_status=//') || true
      [[ -n "$tr_id" ]] && add_summary "released completed task ${tr_id} (status=${tr_status:-done})"
      rm -f "$tr_out"
      _cont=true ;;
    check_stale_in_progress)
      cs_out=$(mktemp)
      BACKLOG_DIR="$backlog_dir" "$ROOT/scripts/backlog-hygiene.sh" \
        --stale-minutes "$stale_minutes" >"$cs_out" 2>/dev/null || true
      csr=$(grep '^reset_in_progress=' "$cs_out" 2>/dev/null | sed 's/^reset_in_progress=//') || true
      [[ "${csr:-0}" -gt 0 ]] && add_summary "reset ${csr} stale in-progress items"
      rm -f "$cs_out"
      _cont=true ;;
    start_backlog_item)
      acquire_out=$(mktemp)
      BACKLOG_DIR="$backlog_dir" MUTEX_DIR="$mutex_dir" \
        "$ROOT/scripts/task-acquire.sh" >"$acquire_out" 2>/dev/null || true
      cat "$acquire_out"
      acquire_mutex=$(grep '^mutex=' "$acquire_out" 2>/dev/null | sed 's/^mutex=//') || true
      if [[ "$acquire_mutex" == "ACQUIRED" ]]; then
        mutex="ACQUIRED"
        backlog_in_progress=1
        acquire_id=$(grep '^id=' "$acquire_out" 2>/dev/null | sed 's/^id=//') || true
        acquire_title=$(grep '^title=' "$acquire_out" 2>/dev/null | sed 's/^title=//') || true
        acquire_type=$(grep '^type=' "$acquire_out" 2>/dev/null | sed 's/^type=//') || true
        acquire_desc=$(grep '^description=' "$acquire_out" 2>/dev/null | sed 's/^description=//') || true
        add_summary "acquired backlog item ${acquire_id} (${acquire_title})"
      fi
      rm -f "$acquire_out" ;;
    investigate_critical|address_failing_ci|address_stale_prs)
      fup_out=$(mktemp)
      REPO="$repo" "$ROOT/scripts/pr-follow-up.sh" \
        --stale-hours "$stale_hours" >"$fup_out" 2>/dev/null || true
      cat "$fup_out"
      fup_updated=$(grep '^updated=' "$fup_out" | sed 's/^updated=//')
      fup_commented=$(grep '^commented=' "$fup_out" | sed 's/^commented=//')
      fup_details=$(grep '^details=' "$fup_out" 2>/dev/null | sed 's/^details=//') || true
      [[ "${fup_updated:-0}" -gt 0 ]] && add_summary "rebased ${fup_updated} stale PR(s)"
      [[ "${fup_commented:-0}" -gt 0 ]] && add_summary "commented on ${fup_commented} stale PR(s)"

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

      rm -f "$rpt" "$fup_out"
      _cont=true ;;
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

      hg_out=$(mktemp)
      HYPOTHESIS_STATE_DIR="$hypothesis_state_dir" \
        "$ROOT/scripts/hypothesis-generate.sh" \
        --title "$title" \
        --desc "$desc" \
        --source "system" \
        --priority 50 >"$hg_out" 2>/dev/null || true
      hg_id=$(cat "$hg_out" 2>/dev/null || true)
      [[ -n "$hg_id" ]] && add_summary "generated hypothesis ${hg_id}"
      rm -f "$hg_out"
      _cont=true ;;
    idle|wait_for_mutex)
      ;;
    *)
      printf 'Unknown action: %s\n' "$action" >&2
      exit 2 ;;
  esac

  rm -f "$na_out"

  if $_cont; then
    continue
  fi
  loop_action="$action"
  break
done

if [[ -z "$loop_action" ]]; then
  loop_action="${action:-idle}"
fi

summary_line=""
if [[ "${#summary_parts[@]}" -gt 0 ]]; then
  IFS='; ' summary_line="${summary_parts[*]}"
  unset IFS
fi
if [[ -z "$summary_line" ]]; then
  case "$loop_action" in
    idle) summary_line="All nominal" ;;
    wait_for_mutex) summary_line="Waiting for mutex release" ;;
    start_backlog_item) summary_line="Acquired backlog item" ;;
    *) summary_line="${reason:-No changes}" ;;
  esac
fi

printf 'action=%s\n' "$loop_action"
printf 'reason=%s\n' "${reason:-}"
printf 'summary=%s\n' "$summary_line"
printf 'mutex=%s\n' "${mutex:-UNKNOWN}"
printf 'backlog_queued=%s\n' "${backlog_queued:-0}"
printf 'backlog_in_progress=%s\n' "${backlog_in_progress:-0}"
printf 'backlog_next=%s\n' "${backlog_next:-none}"
printf 'pr_failing=%s\n' "${pr_failing:-0}"
printf 'pr_stale=%s\n' "${pr_stale:-0}"
printf 'health=%s\n' "${overall_status:-UNKNOWN}"
printf 'acquired_id=%s\n' "${acquire_id:-}"
printf 'acquired_title=%s\n' "${acquire_title:-}"
printf 'acquired_type=%s\n' "${acquire_type:-}"
printf 'acquired_description=%s\n' "${acquire_desc:-}"

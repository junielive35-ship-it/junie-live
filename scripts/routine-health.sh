#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/runtime-paths.sh
source "$ROOT/scripts/runtime-paths.sh"
backlog_dir="${BACKLOG_DIR:-$(junie_backlog_dir_default)}"
mutex_dir="${MUTEX_DIR:-$(junie_mutex_dir_default)}"
stale_minutes=60
stale_queue_hours=24

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backlog-dir) backlog_dir="$2"; shift 2 ;;
    --mutex-dir) mutex_dir="$2"; shift 2 ;;
    --stale-minutes) stale_minutes="$2"; shift 2 ;;
    *) printf 'Unknown: %s\n' "$1" >&2; exit 2 ;;
  esac
done

now_epoch=$(date +%s)

# ---- Mutex state ----
mutex_status="FREE"
mutex_age_minutes=0
if [[ -d "$mutex_dir" ]]; then
  holder_json="$mutex_dir/holder.json"
  if [[ -f "$holder_json" ]]; then
    holder_id=$(grep -o '"holder_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$holder_json" 2>/dev/null | head -1 | sed 's/.*"holder_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || true
    if [[ -z "$holder_id" ]]; then
      mutex_status="BROKEN"
    else
      started_at=$(grep -o '"started_at"[[:space:]]*:[[:space:]]*"[^"]*"' "$holder_json" 2>/dev/null | head -1 | sed 's/.*"started_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || true
      updated_at=$(grep -o '"updated_at"[[:space:]]*:[[:space:]]*"[^"]*"' "$holder_json" 2>/dev/null | head -1 | sed 's/.*"updated_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || true
      ts="$updated_at"
      [[ -z "$ts" ]] && ts="$started_at"
      if [[ -n "$ts" ]]; then
        ts_epoch=$(date -d "$ts" +%s 2>/dev/null || echo 0)
        mutex_age_minutes=$(( (now_epoch - ts_epoch) / 60 ))
      fi
      if [[ "$mutex_age_minutes" -gt "$stale_minutes" ]]; then
        mutex_status="STALE"
      else
        mutex_status="HELD"
      fi
    fi
  else
    mutex_status="BROKEN"
  fi
fi

# ---- Backlog state ----
total_items=0
total_queued=0
queued_hypothesis=0
queued_task=0
queued_fix=0
total_in_progress=0
total_completed=0
total_blocked=0
stale_in_progress=0
stale_queued=0
next_id=""

items_dir="$backlog_dir/items"
if [[ -d "$items_dir" ]]; then
  best_priority=-1
  for f in "$items_dir"/*.json; do
    [[ -f "$f" ]] || continue
    total_items=$((total_items + 1))

    status=$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || true
    created_at=$(grep -o '"created_at"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*"created_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || true
    updated_at=$(grep -o '"updated_at"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*"updated_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || true
    priority=$(grep -o '"priority"[[:space:]]*:[[:space:]]*[0-9]*' "$f" 2>/dev/null | head -1 | sed 's/.*"priority"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/') || true
    priority="${priority:-0}"
    id=$(grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || true

    f_type=$(grep -o '"type"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*"type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || true

    case "$status" in
      queued)
        total_queued=$((total_queued + 1))
        case "$f_type" in
          hypothesis) queued_hypothesis=$((queued_hypothesis + 1)) ;;
          task)       queued_task=$((queued_task + 1)) ;;
          fix)        queued_fix=$((queued_fix + 1)) ;;
        esac
        if [[ -n "$id" && "$priority" -gt "$best_priority" ]]; then
          best_priority="$priority"
          next_id="$id"
        fi
        if [[ -n "$created_at" ]]; then
          created_epoch=$(date -d "$created_at" +%s 2>/dev/null || echo 0)
          if [[ "$created_epoch" -gt 0 ]]; then
            age_hours=$(( (now_epoch - created_epoch) / 3600 ))
            if [[ "$age_hours" -ge "$stale_queue_hours" ]]; then
              stale_queued=$((stale_queued + 1))
            fi
          fi
        fi
        ;;
      in_progress)
        total_in_progress=$((total_in_progress + 1))
        if [[ -n "$updated_at" ]]; then
          updated_epoch=$(date -d "$updated_at" +%s 2>/dev/null || echo 0)
          if [[ "$updated_epoch" -gt 0 ]]; then
            age_minutes=$(( (now_epoch - updated_epoch) / 60 ))
            if [[ "$age_minutes" -ge "$stale_minutes" ]]; then
              stale_in_progress=$((stale_in_progress + 1))
            fi
          fi
        fi
        ;;
      blocked)
        total_blocked=$((total_blocked + 1))
        ;;
      done|archived|cancelled)
        total_completed=$((total_completed + 1))
        ;;
    esac
  done
fi

# ---- Health determination ----
health="OK"
if [[ "$mutex_status" == "STALE" || "$mutex_status" == "BROKEN" ]]; then
  health="CRITICAL"
elif [[ "$stale_in_progress" -gt 0 ]]; then
  health="WARNING"
elif [[ "$total_in_progress" -gt 0 && "$mutex_status" == "FREE" ]]; then
  health="WARNING"
elif [[ "$total_blocked" -gt 3 ]]; then
  health="WARNING"
elif [[ "$stale_queued" -gt 3 ]]; then
  health="WARNING"
fi

# ---- Output ----
printf 'status=%s\n' "$health"
printf 'mutex_status=%s\n' "$mutex_status"
printf 'mutex_age_minutes=%s\n' "$mutex_age_minutes"
printf 'backlog_total_items=%s\n' "$total_items"
printf 'backlog_queued=%s\n' "$total_queued"
printf 'backlog_queued_hypothesis=%s\n' "$queued_hypothesis"
printf 'backlog_queued_task=%s\n' "$queued_task"
printf 'backlog_queued_fix=%s\n' "$queued_fix"
printf 'backlog_in_progress=%s\n' "$total_in_progress"
printf 'backlog_stale_in_progress=%s\n' "$stale_in_progress"
printf 'backlog_stale_queued=%s\n' "$stale_queued"
printf 'backlog_completed=%s\n' "$total_completed"
printf 'backlog_blocked=%s\n' "$total_blocked"
printf 'backlog_next=%s\n' "${next_id:-none}"

details=""
if [[ "$mutex_status" == "HELD" ]]; then
  details="Mutex held (${mutex_age_minutes}m)"
elif [[ "$mutex_status" == "STALE" ]]; then
  details="Mutex STALE (${mutex_age_minutes}m)"
elif [[ "$mutex_status" == "BROKEN" ]]; then
  details="Mutex BROKEN"
fi
if [[ "$stale_in_progress" -gt 0 ]]; then
  details="${details}, ${stale_in_progress} stale in-progress"
fi
if [[ "$total_blocked" -gt 0 ]]; then
  details="${details}, ${total_blocked} blocked"
fi
if [[ "$stale_queued" -gt 0 ]]; then
  details="${details}, ${stale_queued} stale queued"
fi
[[ -z "$details" ]] && details="All nominal"
printf 'details=%s\n' "$details"

case "$health" in
  OK) exit 0 ;;
  WARNING) exit 1 ;;
  CRITICAL) exit 2 ;;
esac

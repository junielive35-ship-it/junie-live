#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mutex_dir="${MUTEX_DIR:-$ROOT/.openclaw/state/code_mutex}"
backlog_dir="${BACKLOG_DIR:-$ROOT/state/backlog}"
stale_minutes=60
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mutex-dir) mutex_dir="$2"; shift 2 ;;
    --backlog-dir) backlog_dir="$2"; shift 2 ;;
    --stale-minutes) stale_minutes="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    *) printf 'Unknown: %s\n' "$1" >&2; exit 2 ;;
  esac
done

read_field() {
  local file="$1" field="$2"
  local val
  val=$(grep -o '"'"$field"'"[[:space:]]*:[[:space:]]*"[^"]*"' "$file" 2>/dev/null | head -1 | sed 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || true
  if [[ -z "$val" ]]; then
    val=$(grep -o '"'"$field"'"[[:space:]]*:[[:space:]]*[0-9]*' "$file" 2>/dev/null | head -1 | sed 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/') || true
  fi
  printf '%s' "$val"
}

if [[ ! -d "$mutex_dir" ]]; then
  printf 'status=FREE\n'
  printf 'action=none\n'
  printf 'reason=mutex already free\n'
  exit 0
fi

holder_json="$mutex_dir/holder.json"
if [[ ! -f "$holder_json" ]]; then
  printf 'status=BROKEN\n'
  if $dry_run; then
    printf 'action=WOULD_REMOVE\n'
    printf 'reason=mutex directory exists but holder.json missing\n'
  else
    rm -rf "$mutex_dir"
    printf 'action=removed\n'
    printf 'reason=removed broken mutex (missing holder.json)\n'
  fi
  exit 0
fi

holder_id=$(read_field "$holder_json" holder_id)
task_id=$(read_field "$holder_json" task_id)
started_at=$(read_field "$holder_json" started_at)
updated_at=$(read_field "$holder_json" updated_at)

if [[ -z "$holder_id" ]]; then
  printf 'status=BROKEN\n'
  if $dry_run; then
    printf 'action=WOULD_REMOVE\n'
    printf 'reason=holder.json missing holder_id\n'
  else
    rm -rf "$mutex_dir"
    printf 'action=removed\n'
    printf 'reason=removed broken mutex (no holder_id)\n'
  fi
  exit 0
fi

ts="$updated_at"
[[ -z "$ts" ]] && ts="$started_at"

age_minutes=0
if [[ -n "$ts" ]]; then
  ts_epoch=$(date -d "$ts" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  age_minutes=$(( (now_epoch - ts_epoch) / 60 ))
fi

if [[ "$age_minutes" -le "$stale_minutes" ]]; then
  printf 'status=HELD\n'
  printf 'action=none\n'
  printf 'age_minutes=%s\n' "$age_minutes"
  printf 'holder_id=%s\n' "$holder_id"
  printf 'reason=mutex not stale\n'
  exit 1
fi

printf 'status=STALE\n'
printf 'age_minutes=%s\n' "$age_minutes"
printf 'holder_id=%s\n' "$holder_id"

if $dry_run; then
  printf 'action=WOULD_RELEASE\n'
  if [[ -n "$task_id" ]]; then
    printf 'task_id=%s\n' "$task_id"
  fi
  exit 0
fi

if [[ -n "$task_id" ]]; then
  item_file="$backlog_dir/items/$task_id.json"
  if [[ -f "$item_file" ]]; then
    item_status=$(read_field "$item_file" status)
    if [[ "$item_status" == "in_progress" ]]; then
      sed -i 's/"status"[[:space:]]*:[[:space:]]*"[^"]*"/"status": "queued"/' "$item_file"
      new_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      sed -i 's/"updated_at"[[:space:]]*:[[:space:]]*"[^"]*"/"updated_at": "'"$new_ts"'"/' "$item_file"
      printf 'task_id=%s\n' "$task_id"
      printf 'task_reset_to=queued\n'
    fi
  fi
fi

rm -rf "$mutex_dir"
printf 'action=released\n'

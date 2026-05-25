#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/runtime-paths.sh
source "$ROOT/scripts/runtime-paths.sh"
backlog_dir="${BACKLOG_DIR:-$(junie_backlog_dir_default)}"
items_dir="$backlog_dir/items"
archive_dir="$backlog_dir/archive"
stale_minutes=120
stale_queued_days=14
archive_days=7
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stale-minutes) stale_minutes="$2"; shift 2 ;;
    --stale-queued-days) stale_queued_days="$2"; shift 2 ;;
    --archive-days) archive_days="$2"; shift 2 ;;
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

mk_ts() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

now_epoch=$(date +%s)
actions_taken=0
stale_found=0
archived_count=0
reset_count=0

mkdir -p "$items_dir" "$archive_dir"

for f in "$items_dir"/*.json; do
  [[ -f "$f" ]] || continue

  status=$(read_field "$f" "status")
  created_at=$(read_field "$f" "created_at")
  updated_at=$(read_field "$f" "updated_at")

  created_epoch=0
  updated_epoch=0
  if [[ -n "$created_at" ]]; then
    created_epoch=$(date -d "$created_at" +%s 2>/dev/null || echo 0)
  fi
  if [[ -n "$updated_at" ]]; then
    updated_epoch=$(date -d "$updated_at" +%s 2>/dev/null || echo 0)
  fi

  case "$status" in
    done|archived|cancelled|blocked)
      if [[ "$created_epoch" -gt 0 ]]; then
        age_days=$(( (now_epoch - created_epoch) / 86400 ))
        if [[ "$age_days" -ge "$archive_days" ]]; then
          if $dry_run; then
            printf 'WOULD_ARCHIVE\t%s\t%s\n' "$(basename "$f")" "$status"
          else
            mv "$f" "$archive_dir/"
            archived_count=$((archived_count + 1))
            actions_taken=$((actions_taken + 1))
          fi
        fi
      fi
      ;;

    in_progress)
      ts="$updated_at"
      [[ -z "$ts" ]] && ts="$created_at"
      if [[ -n "$ts" ]]; then
        ts_epoch=$(date -d "$ts" +%s 2>/dev/null || echo 0)
        if [[ "$ts_epoch" -gt 0 ]]; then
          age_minutes=$(( (now_epoch - ts_epoch) / 60 ))
          if [[ "$age_minutes" -ge "$stale_minutes" ]]; then
            if $dry_run; then
              printf 'WOULD_RESET\t%s\tin_progress\n' "$(basename "$f")"
            else
              sed -i 's/"status"[[:space:]]*:[[:space:]]*"[^"]*"/"status": "queued"/' "$f"
              new_ts=$(mk_ts)
              sed -i 's/"updated_at"[[:space:]]*:[[:space:]]*"[^"]*"/"updated_at": "'"$new_ts"'"/' "$f"
              reset_count=$((reset_count + 1))
              actions_taken=$((actions_taken + 1))
            fi
          fi
        fi
      fi
      ;;

    queued)
      if [[ "$created_epoch" -gt 0 ]]; then
        age_days=$(( (now_epoch - created_epoch) / 86400 ))
        if [[ "$age_days" -ge "$stale_queued_days" ]]; then
          stale_found=$((stale_found + 1))
        fi
      fi
      ;;
  esac
done

printf 'archived=%s\n' "$archived_count"
printf 'reset_in_progress=%s\n' "$reset_count"
printf 'stale_queued=%s\n' "$stale_found"
printf 'actions_taken=%s\n' "$actions_taken"

if [[ "$archived_count" -gt 0 || "$reset_count" -gt 0 ]]; then
  exit 2
elif [[ "$stale_found" -gt 0 ]]; then
  exit 1
fi
exit 0

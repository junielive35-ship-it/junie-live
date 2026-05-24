#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backlog_dir="${BACKLOG_DIR:-$ROOT/state/backlog}"
items_dir="$backlog_dir/items"

dry_run=false
age_weight_tenths=5
max_boost=20

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=true; shift ;;
    --age-weight-tenths) age_weight_tenths="$2"; shift 2 ;;
    --max-boost) max_boost="$2"; shift 2 ;;
    --backlog-dir) backlog_dir="$2"; shift 2 ;;
    --help|-h)
      printf 'Usage: backlog-rescore.sh [--dry-run] [--age-weight-tenths <n>] [--max-boost <n>]\n'
      exit 0 ;;
    *) printf 'Unknown: %s\n' "$1" >&2; exit 2 ;;
  esac
done

items_dir="$backlog_dir/items"
[[ -d "$items_dir" ]] || { printf 'rescored=0\nskipped=0\nerror=no_items_dir\n'; exit 0; }

read_field() {
  local file="$1" field="$2"
  local val
  val=$(grep -o '"'"$field"'"[[:space:]]*:[[:space:]]*"[^"]*"' "$file" 2>/dev/null | head -1 | sed 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || true
  if [[ -z "$val" ]]; then
    val=$(grep -o '"'"$field"'"[[:space:]]*:[[:space:]]*[0-9]*' "$file" 2>/dev/null | head -1 | sed 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/') || true
  fi
  printf '%s' "$val"
}

mk_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

now_epoch=$(date +%s)
rescored=0
skipped=0

for f in "$items_dir"/*.json; do
  [[ -f "$f" ]] || continue

  status=$(read_field "$f" "status")
  [[ "$status" != "queued" ]] && continue

  id=$(read_field "$f" "id")
  cur_priority=$(read_field "$f" "priority")
  cur_priority="${cur_priority:-0}"

  # Use rescore_base as the anchor if set, otherwise current priority
  rescore_base=$(read_field "$f" "rescore_base")
  if [[ -z "$rescore_base" ]]; then
    rescore_base=$cur_priority
    first_rescore=true
  else
    first_rescore=false
  fi

  created_at=$(read_field "$f" "created_at")
  [[ -z "$created_at" ]] && { skipped=$((skipped + 1)); continue; }

  created_epoch=$(date -d "$created_at" +%s 2>/dev/null || echo 0)
  [[ "$created_epoch" -eq 0 ]] && { skipped=$((skipped + 1)); continue; }

  age_hours=$(( (now_epoch - created_epoch) / 3600 ))
  boost=$(( age_hours * age_weight_tenths / 10 ))
  [[ "$boost" -gt "$max_boost" ]] && boost=$max_boost

  new_priority=$(( rescore_base + boost ))
  # Skip if priority is already at or above target
  [[ "$new_priority" -le "$cur_priority" ]] && continue

  if $dry_run; then
    printf 'WOULD_RESCORE\t%s\t%d\t%d\t+%d\t%dh\n' "$id" "$cur_priority" "$new_priority" "$((new_priority - cur_priority))" "$age_hours"
  else
    ts="$(mk_ts)"
    # Update priority in-place
    sed -i 's/"priority"[[:space:]]*:[[:space:]]*[0-9]*/"priority": '"$new_priority"'/' "$f"
    sed -i 's/"updated_at"[[:space:]]*:[[:space:]]*"[^"]*"/"updated_at": "'"$ts"'"/' "$f"
    # Add rescore_base if first time
    if $first_rescore; then
      sed -i 's/^}$/,\n  "rescore_base": '"$rescore_base"'\n}/' "$f"
    fi
    printf 'rescored\t%s\t%d\t%d\t+%d\t%dh\n' "$id" "$cur_priority" "$new_priority" "$((new_priority - cur_priority))" "$age_hours"
  fi
  rescored=$((rescored + 1))
done

printf 'rescored=%s\n' "$rescored"
printf 'skipped=%s\n' "$skipped"

if [[ "$rescored" -gt 0 ]]; then
  if $dry_run; then
    exit 0
  else
    exit 1
  fi
fi
exit 0

#!/usr/bin/env bash
set -euo pipefail

mutex_dir=""
repo=""
stale_minutes=60

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mutex-dir) mutex_dir="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --stale-minutes) stale_minutes="$2"; shift 2 ;;
    *) printf 'Unknown: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [[ -z "$mutex_dir" ]]; then
  printf 'Missing --mutex-dir\n' >&2
  exit 2
fi

if [[ ! -d "$mutex_dir" ]]; then
  printf 'FREE code mutex\n'
  exit 0
fi

holder_json="$mutex_dir/holder.json"

if [[ ! -f "$holder_json" ]]; then
  printf 'BROKEN code mutex\n'
  exit 2
fi

holder_id=$(grep -o '"holder_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$holder_json" 2>/dev/null | head -1 | sed 's/.*"holder_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || true

if [[ -z "$holder_id" ]]; then
  printf 'BROKEN code mutex\n'
  exit 2
fi

reason=$(grep -o '"reason"[[:space:]]*:[[:space:]]*"[^"]*"' "$holder_json" 2>/dev/null | head -1 | sed 's/.*"reason"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true)
started_at=$(grep -o '"started_at"[[:space:]]*:[[:space:]]*"[^"]*"' "$holder_json" 2>/dev/null | head -1 | sed 's/.*"started_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true)
updated_at=$(grep -o '"updated_at"[[:space:]]*:[[:space:]]*"[^"]*"' "$holder_json" 2>/dev/null | head -1 | sed 's/.*"updated_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true)
expected_next_action=$(grep -o '"expected_next_action"[[:space:]]*:[[:space:]]*"[^"]*"' "$holder_json" 2>/dev/null | head -1 | sed 's/.*"expected_next_action"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true)

ts="$updated_at"
[[ -z "$ts" ]] && ts="$started_at"

age_minutes=0
if [[ -n "$ts" ]]; then
  ts_epoch=$(date -d "$ts" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  age_minutes=$(( (now_epoch - ts_epoch) / 60 ))
fi

status="HELD"
if [[ "$age_minutes" -gt "$stale_minutes" ]]; then
  status="STALE"
fi

printf '%s code mutex\n' "$status"
[[ -n "$holder_id" ]] && printf 'holder_id=%s\n' "$holder_id"
[[ -n "$reason" ]] && printf 'reason=%s\n' "$reason"
[[ -n "$started_at" ]] && printf 'started_at=%s\n' "$started_at"
[[ -n "$updated_at" ]] && printf 'updated_at=%s\n' "$updated_at"
[[ -n "$expected_next_action" ]] && printf 'expected_next_action=%s\n' "$expected_next_action"
printf 'age_minutes=%s\n' "$age_minutes"

if [[ "$status" == "STALE" ]]; then
  exit 1
fi
exit 0

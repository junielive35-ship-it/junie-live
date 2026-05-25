#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/runtime-paths.sh
source "$ROOT/scripts/runtime-paths.sh"
backlog_dir="${BACKLOG_DIR:-$(junie_backlog_dir_default)}"
mutex_dir="${MUTEX_DIR:-$(junie_mutex_dir_default)}"
new_status="done"
notes=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backlog-dir) backlog_dir="$2"; shift 2 ;;
    --mutex-dir) mutex_dir="$2"; shift 2 ;;
    --status) new_status="$2"; shift 2 ;;
    --notes) notes="$2"; shift 2 ;;
    *) printf 'Unknown: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$mutex_dir" ]]; then
  printf 'released=false\n'
  printf 'reason=mutex already free\n'
  exit 0
fi

holder_json="$mutex_dir/holder.json"
if [[ ! -f "$holder_json" ]]; then
  rm -rf "$mutex_dir"
  printf 'released=true\n'
  printf 'reason=no holder.json, force-released\n'
  exit 0
fi

task_id=$(grep -o '"task_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$holder_json" 2>/dev/null | head -1 | sed 's/.*"task_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || true

if [[ -n "$task_id" ]]; then
  current_status=""
  item_file="$backlog_dir/items/$task_id.json"
  if [[ -f "$item_file" ]]; then
    current_status=$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$item_file" 2>/dev/null | head -1 | sed 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || true
  fi
  case "$current_status" in
    done|cancelled|blocked|archived) ;;
    *) BACKLOG_DIR="$backlog_dir" "$ROOT/scripts/backlog.sh" update "$task_id" --status "$new_status" >/dev/null 2>&1 || true ;;
  esac
fi

# Compute task duration from holder.json started_at before removing mutex
duration=""
started_at=$(grep -o '"started_at"[[:space:]]*:[[:space:]]*"[^"]*"' "$holder_json" 2>/dev/null | head -1 | sed 's/.*"started_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || true
if [[ -n "$started_at" ]]; then
  start_epoch=$(date -d "$started_at" +%s 2>/dev/null || echo "")
  if [[ -n "$start_epoch" && "$start_epoch" -gt 0 ]]; then
    now_epoch=$(date +%s)
    duration=$((now_epoch - start_epoch))
    [[ "$duration" -lt 0 ]] && duration=0
  fi
fi

rm -rf "$mutex_dir"

reflect_args=("${task_id:-}" "$new_status")
[[ -n "$notes" ]] && reflect_args+=(--notes "$notes")
[[ -n "$duration" ]] && reflect_args+=(--duration "$duration")
REFLECTIONS_DIR="${REFLECTIONS_DIR:-$backlog_dir/../reflections}" "$ROOT/scripts/reflect.sh" "${reflect_args[@]}" 2>/dev/null || true

printf 'released=true\n'
printf 'task_id=%s\n' "${task_id:-}"
printf 'new_status=%s\n' "$new_status"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backlog_dir="${BACKLOG_DIR:-$ROOT/state/backlog}"
mutex_dir="${MUTEX_DIR:-$ROOT/.openclaw/state/code_mutex}"
new_status="done"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backlog-dir) backlog_dir="$2"; shift 2 ;;
    --mutex-dir) mutex_dir="$2"; shift 2 ;;
    --status) new_status="$2"; shift 2 ;;
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

rm -rf "$mutex_dir"

"$ROOT/scripts/reflect.sh" "${task_id:-}" "$new_status" 2>/dev/null || true

printf 'released=true\n'
printf 'task_id=%s\n' "${task_id:-}"
printf 'new_status=%s\n' "$new_status"

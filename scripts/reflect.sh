#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_id="${1:-}"
new_status="${2:-done}"

[[ -z "$task_id" ]] && exit 0

backlog_dir="${BACKLOG_DIR:-$ROOT/state/backlog}"
reflections_dir="${REFLECTIONS_DIR:-$ROOT/state/reflections}"
mkdir -p "$reflections_dir"

item_file="$backlog_dir/archive/$task_id.json"
[[ ! -f "$item_file" ]] && item_file="$backlog_dir/items/$task_id.json"
[[ ! -f "$item_file" ]] && exit 0

read_field() {
  local f="$1" field="$2"
  local val
  val=$(grep -o '"'"$field"'"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || true
  if [[ -z "$val" ]]; then
    val=$(grep -o '"'"$field"'"[[:space:]]*:[[:space:]]*[0-9]*' "$f" 2>/dev/null | head -1 | sed 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/') || true
  fi
  printf '%s' "$val"
}

title=$(read_field "$item_file" title)
type=$(read_field "$item_file" type)
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "$reflections_dir/${task_id}.json" <<EOF
{
  "task_id": "$(printf '%s' "$task_id" | sed 's/"/\\"/g')",
  "type": "$(printf '%s' "$type" | sed 's/"/\\"/g')",
  "title": "$(printf '%s' "$title" | sed 's/"/\\"/g')",
  "status": "$(printf '%s' "$new_status" | sed 's/"/\\"/g')",
  "reflected_at": "$ts"
}
EOF

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/runtime-paths.sh
source "$ROOT/scripts/runtime-paths.sh"
task_id="${1:-}"
new_status="${2:-done}"
notes=""
duration=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes) notes="$2"; shift 2 ;;
    --duration) duration="$2"; shift 2 ;;
    *) shift ;;
  esac
done

[[ -z "$task_id" ]] && exit 0

backlog_dir="${BACKLOG_DIR:-$(junie_backlog_dir_default)}"
reflections_dir="${REFLECTIONS_DIR:-$(junie_reflections_dir_default)}"
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

escape_json() {
  printf '%s' "$1" | sed 's/["\]/\\&/g'
}

title=$(read_field "$item_file" title)
type=$(read_field "$item_file" type)
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "$reflections_dir/${task_id}.json" <<EOF
{
  "task_id": "$(escape_json "$task_id")",
  "type": "$(escape_json "$type")",
  "title": "$(escape_json "$title")",
  "status": "$(escape_json "$new_status")",
  "reflected_at": "$ts"$(if [[ -n "$duration" ]]; then printf ',\n  "duration_seconds": %s' "$duration"; fi)$(if [[ -n "$notes" ]]; then printf ',\n  "notes": "%s"' "$(escape_json "$notes")"; fi)
}
EOF

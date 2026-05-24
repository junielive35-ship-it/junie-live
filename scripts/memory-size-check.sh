#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
max_lines=500
max_bytes=32768
dry_run=false
backlog_dir="${BACKLOG_DIR:-$ROOT/state/backlog}"
file="$ROOT/MEMORY.md"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) file="$2"; shift 2 ;;
    --max-lines) max_lines="$2"; shift 2 ;;
    --max-bytes) max_bytes="$2"; shift 2 ;;
    --backlog-dir) backlog_dir="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    *) printf 'Unknown: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$file" ]]; then
  printf 'exists=false\n'
  printf 'status=OK\n'
  printf 'reason=file not found\n'
  exit 0
fi

line_count=$(wc -l < "$file" | tr -d ' ')
byte_count=$(wc -c < "$file" | tr -d ' ')

over_lines=false
over_bytes=false
if [[ "$line_count" -gt "$max_lines" ]]; then over_lines=true; fi
if [[ "$byte_count" -gt "$max_bytes" ]]; then over_bytes=true; fi

printf 'exists=true\n'
printf 'line_count=%s\n' "$line_count"
printf 'byte_count=%s\n' "$byte_count"
printf 'max_lines=%s\n' "$max_lines"
printf 'max_bytes=%s\n' "$max_bytes"

if ! $over_lines && ! $over_bytes; then
  printf 'status=OK\n'
  printf 'reason=within budget\n'
  exit 0
fi

candidate_created=false
if ! $dry_run; then
  existing=false
  items_dir="$backlog_dir/items"
  if [[ -d "$items_dir" ]]; then
    for f in "$items_dir"/*.json; do
      [[ -f "$f" ]] || continue
      t=$(grep -o '"title"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1) || true
      s=$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1) || true
      if [[ "$t" == *"MEMORY.md"* && "$s" == *"queued"* ]]; then
        existing=true
        break
      fi
    done
  fi

  if ! $existing; then
    budget_msg=""
    $over_lines && budget_msg="${budget_msg} lines=${line_count}/${max_lines}"
    $over_bytes && budget_msg="${budget_msg} bytes=${byte_count}/${max_bytes}"
    budget_msg="${budget_msg# }"

    BACKLOG_DIR="$backlog_dir" "$ROOT/scripts/backlog.sh" add \
      --type fix \
      --title "MEMORY.md exceeds budget (${budget_msg})" \
      --desc "MEMORY.md has ${line_count} lines / ${byte_count} bytes (budget: ${max_lines} lines / ${max_bytes} bytes). Consider moving non-strategic content to docs/ while preserving the strategic core." \
      --source "system:memory_size_check" \
      --priority 70 >/dev/null 2>&1 || true
    candidate_created=true
  fi
fi

printf 'status=OVER_LIMIT\n'
printf 'over_lines=%s\n' "$over_lines"
printf 'over_bytes=%s\n' "$over_bytes"
printf 'candidate_created=%s\n' "$candidate_created"
exit 2

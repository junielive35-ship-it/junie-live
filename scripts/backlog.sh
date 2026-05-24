#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backlog_dir="${BACKLOG_DIR:-$ROOT/state/backlog}"
items_dir="$backlog_dir/items"
archive_dir="$backlog_dir/archive"

mkdir -p "$items_dir" "$archive_dir"

escape_json() {
  printf '%s' "$1" | sed 's/["\]/\\&/g'
}

read_field() {
  local file="$1" field="$2"
  local val
  val=$(grep -o '"'"$field"'"[[:space:]]*:[[:space:]]*"[^"]*"' "$file" 2>/dev/null | head -1 | sed 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || true
  if [[ -z "$val" ]]; then
    val=$(grep -o '"'"$field"'"[[:space:]]*:[[:space:]]*[0-9]*' "$file" 2>/dev/null | head -1 | sed 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/') || true
  fi
  printf '%s' "$val"
}

usage() {
  cat >&2 <<'USAGE'
Usage: backlog.sh <command> [options]

Commands:
  add     --type <type> --title <title> [--desc <desc>]
          [--source <source>] [--priority <n>]
  list    [--status <status>] [--type <type>]
  next
  update  <id> --status <status> [--priority <n>]
  archive
USAGE
  exit 2
}

cmd="${1:-}"; [[ -n "$cmd" ]] && shift

case "$cmd" in
  add)
    type=""; title=""; desc=""; source=""; priority=50
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --type) type="$2"; shift 2 ;;
        --title) title="$2"; shift 2 ;;
        --desc) desc="$2"; shift 2 ;;
        --source) source="$2"; shift 2 ;;
        --priority) priority="$2"; shift 2 ;;
        *) printf 'Unknown: %s\n' "$1" >&2; usage ;;
      esac
    done
    [[ -z "$type" ]] && { printf 'Missing --type\n' >&2; exit 2; }
    [[ -z "$title" ]] && { printf 'Missing --title\n' >&2; exit 2; }

    id="bl-$(date +%s)-$(printf '%04x' $RANDOM 2>/dev/null || echo $$)"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    cat > "$items_dir/$id.json" <<EOF
{
  "id": "$id",
  "type": "$(escape_json "$type")",
  "title": "$(escape_json "$title")",
  "description": "$(escape_json "$desc")",
  "status": "queued",
  "priority": $priority,
  "source": "$(escape_json "$source")",
  "created_at": "$ts",
  "updated_at": "$ts"
}
EOF
    printf '%s\n' "$id"
    ;;

  list)
    status=""; type=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --status) status="$2"; shift 2 ;;
        --type) type="$2"; shift 2 ;;
        *) printf 'Unknown: %s\n' "$1" >&2; usage ;;
      esac
    done

    for f in "$items_dir"/*.json; do
      [[ -f "$f" ]] || continue
      s=$(read_field "$f" "status")
      [[ -n "$status" && "$s" != "$status" ]] && continue
      t=$(read_field "$f" "type")
      [[ -n "$type" && "$t" != "$type" ]] && continue

      id=$(read_field "$f" "id")
      p=$(read_field "$f" "priority")
      title=$(read_field "$f" "title")
      printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$t" "$s" "$p" "$title"
    done | sort -t"$(printf '\t')" -k4,4rn
    ;;

  next)
    best_id=""; best_priority=-1
    for f in "$items_dir"/*.json; do
      [[ -f "$f" ]] || continue
      s=$(read_field "$f" "status")
      [[ "$s" != "queued" ]] && continue
      p=$(read_field "$f" "priority")
      p="${p:-0}"
      if [[ "$p" -gt "$best_priority" ]]; then
        best_priority="$p"
        best_id=$(read_field "$f" "id")
      fi
    done

    if [[ -z "$best_id" ]]; then
      exit 0
    fi

    f="$items_dir/$best_id.json"
    for field in id type title description status priority source created_at updated_at; do
      val=$(read_field "$f" "$field")
      printf '%s=%s\n' "$field" "$val"
    done
    ;;

  update)
    id="${1:-}"; shift || true
    [[ -z "$id" ]] && { printf 'Missing item id\n' >&2; usage; }
    f="$items_dir/$id.json"
    [[ ! -f "$f" ]] && { printf 'Item not found: %s\n' "$id" >&2; exit 2; }

    new_status=""; new_priority=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --status) new_status="$2"; shift 2 ;;
        --priority) new_priority="$2"; shift 2 ;;
        *) printf 'Unknown: %s\n' "$1" >&2; usage ;;
      esac
    done
    [[ -z "$new_status" && -z "$new_priority" ]] && { printf 'Nothing to update\n' >&2; exit 2; }

    [[ -n "$new_status" ]] && sed -i 's/"status"[[:space:]]*:[[:space:]]*"[^"]*"/"status": "'"$(escape_json "$new_status")"'"/' "$f"
    [[ -n "$new_priority" ]] && sed -i 's/"priority"[[:space:]]*:[[:space:]]*[0-9]*/"priority": '"$new_priority"'/' "$f"

    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sed -i 's/"updated_at"[[:space:]]*:[[:space:]]*"[^"]*"/"updated_at": "'"$ts"'"/' "$f"
    ;;

  archive)
    count=0
    for f in "$items_dir"/*.json; do
      [[ -f "$f" ]] || continue
      s=$(read_field "$f" "status")
      if [[ "$s" == "done" || "$s" == "archived" || "$s" == "cancelled" ]]; then
        mv "$f" "$archive_dir/"
        count=$((count + 1))
      fi
    done
    printf 'Archived %d items\n' "$count"
    ;;

  help|--help|-h)
    usage
    ;;

  *)
    printf 'Unknown command: %s\n' "$cmd" >&2
    usage
    ;;
esac

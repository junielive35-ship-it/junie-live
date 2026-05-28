#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/reflect.sh --task-id ID --title TITLE --status STATUS [--type TYPE] [--notes TEXT] [--duration SECONDS] [--reflections-dir DIR]

Writes a small JSON reflection artifact. This helper is intentionally standalone;
it does not read or mutate backlog/task state.
EOF
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/runtime-paths.sh
source "$ROOT/scripts/runtime-paths.sh"

task_id=""
title=""
type="task"
status="done"
notes=""
duration=""
reflections_dir="${REFLECTIONS_DIR:-$(junie_state_root_default)/reflections}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id) task_id="$2"; shift 2 ;;
    --title) title="$2"; shift 2 ;;
    --type) type="$2"; shift 2 ;;
    --status) status="$2"; shift 2 ;;
    --notes) notes="$2"; shift 2 ;;
    --duration) duration="$2"; shift 2 ;;
    --reflections-dir) reflections_dir="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$task_id" ]] || { printf 'ERROR: --task-id is required\n' >&2; exit 2; }
[[ -n "$title" ]] || { printf 'ERROR: --title is required\n' >&2; exit 2; }

mkdir -p "$reflections_dir"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

python3 - "$reflections_dir/${task_id}.json" "$task_id" "$type" "$title" "$status" "$ts" "$duration" "$notes" <<'PY'
import json, sys
path, task_id, typ, title, status, ts, duration, notes = sys.argv[1:]
out = {
    "task_id": task_id,
    "type": typ,
    "title": title,
    "status": status,
    "reflected_at": ts,
}
if duration:
    out["duration_seconds"] = int(duration)
if notes:
    out["notes"] = notes
with open(path, "w", encoding="utf-8") as fh:
    json.dump(out, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY

printf 'reflection_written=%s\n' "$reflections_dir/${task_id}.json"

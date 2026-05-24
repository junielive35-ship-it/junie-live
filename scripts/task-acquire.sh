#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/runtime-paths.sh
source "$ROOT/scripts/runtime-paths.sh"
backlog_dir="${BACKLOG_DIR:-$(junie_backlog_dir_default)}"
mutex_dir="${MUTEX_DIR:-$(junie_mutex_dir_default)}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backlog-dir) backlog_dir="$2"; shift 2 ;;
    --mutex-dir) mutex_dir="$2"; shift 2 ;;
    *) printf 'Unknown: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [[ -d "$mutex_dir" ]]; then
  printf 'mutex=HELD\n'
  exit 2
fi

mkdir "$mutex_dir" 2>/dev/null || {
  printf 'mutex=RACE\n'
  exit 2
}

acq_out=$(mktemp)
trap 'rm -f "$acq_out"' EXIT
BACKLOG_DIR="$backlog_dir" "$ROOT/scripts/backlog.sh" acquire >"$acq_out" 2>/dev/null || true

if [[ ! -s "$acq_out" ]]; then
  rm -rf "$mutex_dir"
  printf 'backlog=empty\n'
  exit 0
fi

read_val() {
  grep "^${1}=" "$acq_out" 2>/dev/null | sed 's/^[^=]*=//' || true
}

task_id=$(read_val id)
task_title=$(read_val title)

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$mutex_dir/holder.json" <<JSON
{
  "holder_id": "task-acquire:${task_id}",
  "holder_kind": "backlog_execution",
  "task_id": "${task_id}",
  "repo": "$ROOT",
  "reason": "Execute backlog item: ${task_title}",
  "started_at": "${ts}",
  "updated_at": "${ts}",
  "expected_next_action": "delegate implementation and review"
}
JSON

cat "$acq_out"
printf 'mutex=ACQUIRED\n'

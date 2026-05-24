#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/runtime-paths.sh
source "$ROOT/scripts/runtime-paths.sh"
backlog_dir="${BACKLOG_DIR:-$(junie_backlog_dir_default)}"
hypothesis_state_dir="${HYPOTHESIS_STATE_DIR:-$(junie_hypothesis_state_dir_default)}"

usage() {
  cat >&2 <<'USAGE'
Usage: hypothesis-generate.sh --title <title> [options]

Options:
  --title <title>      Hypothesis title (required)
  --desc <desc>        Description / supporting evidence
  --source <source>    Source of the hypothesis (e.g. analytics, bug report)
  --priority <n>       Priority score (default: 50)
USAGE
  exit 2
}

title=""; desc=""; source=""; priority=50

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) title="$2"; shift 2 ;;
    --desc) desc="$2"; shift 2 ;;
    --source) source="$2"; shift 2 ;;
    --priority) priority="$2"; shift 2 ;;
    --help|-h) usage ;;
    *) printf 'Unknown: %s\n' "$1" >&2; usage ;;
  esac
done

[[ -z "$title" ]] && { printf 'Missing --title\n' >&2; exit 2; }

id=$(BACKLOG_DIR="$backlog_dir" "$ROOT/scripts/backlog.sh" add \
  --type hypothesis --title "$title" \
  --desc "$desc" --source "$source" --priority "$priority")

mkdir -p "$hypothesis_state_dir"
date -u +%s > "$hypothesis_state_dir/last_generated"

printf '%s\n' "$id"

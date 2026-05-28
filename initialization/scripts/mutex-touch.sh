#!/usr/bin/env bash
set -euo pipefail

# runtime-paths.sh is always a sibling of this script, both in the source repo
# (initialization/scripts/) and in a hired workspace (scripts/). Resolve it
# relative to this script's own directory so both layouts work.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=initialization/scripts/runtime-paths.sh
source "$SCRIPT_DIR/runtime-paths.sh"
mutex_dir="${MUTEX_DIR:-$(junie_mutex_dir_default)}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mutex-dir) mutex_dir="$2"; shift 2 ;;
    *) printf 'Unknown: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$mutex_dir" ]]; then
  printf 'touched=false\n'
  printf 'reason=mutex not held\n'
  exit 0
fi

holder_json="$mutex_dir/holder.json"
if [[ ! -f "$holder_json" ]]; then
  printf 'touched=false\n'
  printf 'reason=holder.json missing\n'
  exit 0
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
sed -i 's/"updated_at"[[:space:]]*:[[:space:]]*"[^"]*"/"updated_at": "'"$ts"'"/' "$holder_json"

printf 'touched=true\n'
printf 'updated_at=%s\n' "$ts"

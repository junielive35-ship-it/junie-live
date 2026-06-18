#!/usr/bin/env bash
set -euo pipefail

# Compatibility wrapper for the synchronous Senior Dev OpenCode executor.
# Runtime logic lives in ../worker.py; inline Python in shell is prohibited.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_dir="$(cd "$script_dir/.." && pwd)"
parent_dir="$(cd "$plugin_dir/.." && pwd)"

export PYTHONPATH="$parent_dir${PYTHONPATH:+:$PYTHONPATH}"
exec python3 "$plugin_dir/worker.py"

#!/usr/bin/env bash
set -euo pipefail

# code-mutex.sh — Thin compatibility wrapper around junie_runtime Python mutex CLI
#
# Delegates to python3 -m junie_runtime.cli.mutex. The Python implementation
# is the single source of truth for all mutex logic.
# Requires junie-runtime to be installed.
#
# Usage:
#   code-mutex.sh status [--mutex-dir DIR]
#   code-mutex.sh acquire --holder ID --reason TEXT [--repo DIR] [--mutex-dir DIR]
#   code-mutex.sh release [--mutex-dir DIR]
#   code-mutex.sh check-stale [--stale-minutes N] [--auto-recover] [--mutex-dir DIR]

# Fail clearly if the runtime package is not installed.
if ! python3 -m pip show junie-runtime >/dev/null 2>&1; then
  echo "ERROR: junie_runtime package not installed." >&2
  echo "Run: python3 -m pip install -e <repo_root>/hermes/junie_runtime" >&2
  exit 1
fi

exec python3 -m junie_runtime.cli.mutex "$@"

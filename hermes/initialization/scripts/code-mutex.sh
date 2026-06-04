#!/usr/bin/env bash
set -euo pipefail

# code-mutex.sh — Thin compatibility wrapper around junie_runtime Python mutex CLI
#
# Delegates to python -m junie_runtime.cli.mutex. The Python implementation
# is the single source of truth for all mutex logic.
# Requires junie-runtime to be installed in the Hermes Python environment.
#
# Usage:
#   code-mutex.sh status [--mutex-dir DIR]
#   code-mutex.sh acquire --holder ID --reason TEXT [--repo DIR] [--mutex-dir DIR]
#   code-mutex.sh release [--mutex-dir DIR]
#   code-mutex.sh check-stale [--stale-minutes N] [--auto-recover] [--mutex-dir DIR]

# Source shared helpers for Hermes Python resolution
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./runtime-paths.sh
. "$SCRIPT_DIR/runtime-paths.sh"

# Resolve Hermes Python: JUNIE_HERMES_PYTHON > manifest installed_python > python3
HERMES_PY=""
if [[ -z "${JUNIE_HERMES_PYTHON:-}" ]]; then
  # Try manifest-installed Python for profile context
  MANIFEST_DIR=""
  if [[ -d "$SCRIPT_DIR/../junie-live/runtime" ]]; then
    MANIFEST_DIR="$(cd "$SCRIPT_DIR/../junie-live/runtime" && pwd)"
  fi
  if [[ -n "$MANIFEST_DIR" && -f "$MANIFEST_DIR/junie_runtime.json" ]]; then
    MANIFEST_PY=$(python3 -c "
import json
try:
    m = json.load(open('$MANIFEST_DIR/junie_runtime.json'))
    print(m.get('installed_python', ''))
except Exception:
    print('')
" 2>/dev/null || true)
    if [[ -n "$MANIFEST_PY" ]] && "$MANIFEST_PY" -c 'import sys; print(sys.executable)' >/dev/null 2>&1; then
      HERMES_PY="$MANIFEST_PY"
    fi
  fi
fi

if [[ -z "$HERMES_PY" ]]; then
  HERMES_PY="$(resolve_hermes_python)" || exit 1
fi

# Fail clearly if the runtime package is not installed.
if ! "$HERMES_PY" -c "import junie_runtime" 2>/dev/null; then
  echo "ERROR: junie_runtime package not installed." >&2
  echo "Run: $HERMES_PY -m pip install -e <repo_root>/hermes/junie_runtime" >&2
  exit 1
fi

exec "$HERMES_PY" -m junie_runtime.cli.mutex "$@"

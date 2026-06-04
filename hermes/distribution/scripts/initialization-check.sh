#!/usr/bin/env bash
set -euo pipefail

# initialization-check.sh — Gate check before finalizing Hermes Junie initialization
#
# Fails if:
#   1. INITIALIZATION.md is missing (not in initialization mode)
#   2. docs/tools.md has obvious required TODOs for project path, mutex
#      scope/escalation, or core dev commands that are not marked N/A
#      with a reason
#
# Usage:
#   initialization-check.sh [--profile-dir DIR]
#
# Default profile dir: resolved via runtime-paths.sh (or ~/.hermes/profiles/junie-live)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_PATHS="$SCRIPT_DIR/runtime-paths.sh"

PROFILE_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile-dir) PROFILE_DIR="$2"; shift 2 ;;
    *) printf 'Unknown: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [[ -z "$PROFILE_DIR" ]]; then
  if [[ -f "$RUNTIME_PATHS" ]]; then
    source "$RUNTIME_PATHS"
    PROFILE_DIR="$(hermes_profile_dir_default)"
  else
    PROFILE_DIR="${HERMES_HOME:-$HOME/.hermes}/profiles/${HERMES_PROFILE:-junie-live}"
  fi
fi

errcode=0

# 1. INITIALIZATION.md must exist (we are in initialization mode)
if [[ ! -f "$PROFILE_DIR/INITIALIZATION.md" ]]; then
  printf 'FAIL: INITIALIZATION.md not found in %s\n' "$PROFILE_DIR" >&2
  errcode=$((errcode + 1))
else
  printf 'OK: INITIALIZATION.md present\n'
fi

# 2. docs/tools.md must exist
TOOLS="$PROFILE_DIR/docs/tools.md"
if [[ ! -f "$TOOLS" ]]; then
  printf 'FAIL: docs/tools.md not found in %s\n' "$PROFILE_DIR/docs/" >&2
  errcode=$((errcode + 2))
else
  printf 'OK: docs/tools.md present\n'
fi

# 3. Check for critical unresolved TODOs in docs/tools.md
if [[ -f "$TOOLS" ]]; then
  check_todo() {
    local label="$1"
    local field="$2"
    local line
    line=$(grep -n "$field.*TODO" "$TOOLS" | head -1 || true)
    if [[ -n "$line" ]]; then
      # Check if marked N/A on the same or next line
      local lineno
      lineno=$(echo "$line" | cut -d: -f1)
      local na_check
      na_check=$(sed -n "${lineno},$((lineno + 2))p" "$TOOLS" | grep -c 'N/A\|N/A' || true)
      if [[ "$na_check" -eq 0 ]]; then
        printf 'WARN: %s TODO remains in docs/tools.md (line %s): %s\n' "$label" "$line" >&2
        printf '  Mark as N/A with reason if not applicable, or confirm and fill.\n' >&2
        errcode=$((errcode + 4))
      else
        printf 'OK: %s marked N/A in docs/tools.md\n' "$label"
      fi
    else
      printf 'OK: %s resolved or absent in docs/tools.md\n' "$label"
    fi
  }

  check_todo 'project path' 'Repository:'
  check_todo 'mutex scope' 'Mutex directory\|Protected repository\|Protected.*scope'
  check_todo 'mutex escalation' 'escalation\|contact for held'
  check_todo 'install command' 'Install dependencies'
  check_todo 'build command' 'Build:'
  check_todo 'test command' 'Test:'
  check_todo 'lint command' 'Lint'
fi

if [[ "$errcode" -eq 0 ]]; then
  printf '\nInitialization gate check PASSED.\n'
else
  printf '\nInitialization gate check FAILED (code %d).\n' "$errcode" >&2
fi

exit "$errcode"

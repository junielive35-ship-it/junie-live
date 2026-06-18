#!/usr/bin/env bash
set -euo pipefail

# initialization-check.sh — Gate check before finalizing Hermes Junie initialization
#
# Fails if:
#   1. INITIALIZATION.md is missing (not in initialization mode)
#   2. docs/tools.md has obvious required TODOs for project path or core dev
#      commands that are not marked N/A with a reason
#
# Usage:
#   initialization-check.sh [--profile-dir DIR] [--junie-home DIR]
#
# Default profile dir: resolved via junie_runtime.paths.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROFILE_DIR=""
JUNIE_HOME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile-dir) PROFILE_DIR="$2"; shift 2 ;;
    --junie-home) JUNIE_HOME="$2"; shift 2 ;;
    *) printf 'Unknown: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [[ -z "$PROFILE_DIR" ]]; then
  PROFILE_DIR="$(python3 -m junie_runtime.paths profile-dir)"
fi
if [[ -z "$JUNIE_HOME" ]]; then
  JUNIE_HOME="${JUNIE_HOME:-$HOME/.junie}"
fi

errcode=0

SENIOR_CONTRACT_MARKER="Senior Dev Operating Contract v2026-06-18"
SENIOR_CONTRACT_SEED="$PROFILE_DIR/junie/AGENTS.md"
SENIOR_CONTRACT_LIVE="$JUNIE_HOME/AGENTS.md"

reconcile_senior_contract() {
  [[ -f "$SENIOR_CONTRACT_SEED" ]] || return 0
  mkdir -p "$JUNIE_HOME"

  if [[ ! -f "$SENIOR_CONTRACT_LIVE" ]]; then
    cp "$SENIOR_CONTRACT_SEED" "$SENIOR_CONTRACT_LIVE"
    printf 'OK: created ~/.junie/AGENTS.md from profile seed\n'
    return 0
  fi

  cp "$SENIOR_CONTRACT_SEED" "$JUNIE_HOME/AGENTS.seed.md"
  if grep -q "$SENIOR_CONTRACT_MARKER" "$SENIOR_CONTRACT_LIVE"; then
    printf 'OK: ~/.junie/AGENTS.md already contains current Senior Dev contract\n'
    return 0
  fi

  ts="$(date +%Y%m%d-%H%M%S)"
  mv "$SENIOR_CONTRACT_LIVE" "$JUNIE_HOME/AGENTS.local-before-senior-contract-$ts.md"
  cp "$SENIOR_CONTRACT_SEED" "$SENIOR_CONTRACT_LIVE"
  printf 'OK: reconciled ~/.junie/AGENTS.md and preserved previous file as AGENTS.local-before-senior-contract-%s.md\n' "$ts"
}

reconcile_senior_contract

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
  check_todo 'install command' 'Install dependencies'
  check_todo 'build command' 'Build:'
  check_todo 'test command' 'Test:'
  check_todo 'lint command' 'Lint'
fi

# 4. Senior Dev operating contract must exist and contain the current schema.
if [[ ! -f "$SENIOR_CONTRACT_SEED" ]]; then
  printf 'FAIL: Senior Dev AGENTS.md seed not found in profile: %s\n' "$SENIOR_CONTRACT_SEED" >&2
  errcode=$((errcode + 8))
else
  printf 'OK: Senior Dev AGENTS.md seed present\n'
fi

if [[ ! -f "$SENIOR_CONTRACT_LIVE" ]]; then
  printf 'FAIL: ~/.junie/AGENTS.md not found at %s\n' "$SENIOR_CONTRACT_LIVE" >&2
  errcode=$((errcode + 16))
elif ! grep -q "$SENIOR_CONTRACT_MARKER" "$SENIOR_CONTRACT_LIVE" || ! grep -q 'FINAL_VERDICT_SCHEMA' "$SENIOR_CONTRACT_LIVE"; then
  printf 'FAIL: ~/.junie/AGENTS.md does not contain the current Senior Dev contract marker/schema\n' >&2
  errcode=$((errcode + 16))
else
  printf 'OK: ~/.junie/AGENTS.md contains current Senior Dev contract\n'
fi

if [[ "$errcode" -eq 0 ]]; then
  printf '\nInitialization gate check PASSED.\n'
else
  printf '\nInitialization gate check FAILED (code %d).\n' "$errcode" >&2
fi

exit "$errcode"

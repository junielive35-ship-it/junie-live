#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

forbidden=(SOUL.md USER.md TOOLS.md IDENTITY.md HEARTBEAT.md .openclaw state)

for artifact in "${forbidden[@]}"; do
  if [[ -e "$ROOT/$artifact" ]]; then
    fail "repo root contains forbidden OpenClaw/runtime artifact: $artifact"
  fi
done

if [[ -f .git/info/exclude ]]; then
  active_excludes="$(grep -Ev '^[[:space:]]*(#|$)' .git/info/exclude || true)"
  for artifact in "${forbidden[@]}"; do
    if grep -Fxq "$artifact" <<<"$active_excludes" || grep -Fxq "/$artifact" <<<"$active_excludes"; then
      fail ".git/info/exclude must not mask root OpenClaw/runtime artifact: $artifact"
    fi
  done
fi

printf 'repo_hygiene=OK\n'

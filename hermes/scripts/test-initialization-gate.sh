#!/usr/bin/env bash
# Test the initialization gate profile-dir resolution for Junie Live Hermes.
# Run from the hermes/ subtree root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_SCRIPT="$ROOT/distribution/scripts/initialization-check.sh"

fail_count=0
pass_count=0

pass() { pass_count=$((pass_count + 1)); }
fail() { printf '  FAIL: %s\n' "$*" >&2; fail_count=$((fail_count + 1)); }

printf '=== initialization-check.sh: uses junie_runtime.paths ===\n'
grep -q 'junie_runtime.paths profile-dir' "$CHECK_SCRIPT" && pass || fail "initialization-check.sh does not use junie_runtime.paths profile-dir"

printf '\n=== SOUL.md: initialization gate does not depend on env vars ===\n'

SOUL_MD="$ROOT/distribution/SOUL.md"
# The gate instruction should not reference $HERMES_PROFILE_DIR (which may be
# unset in tool subprocesses). Use of $HERMES_HOME or $HERMES_PROFILE is ok
# because the instruction tells the agent to verify with shell commands.
if grep -q '\$HERMES_PROFILE_DIR/INITIALIZATION' "$SOUL_MD" 2>/dev/null; then
  fail "SOUL.md still references \$HERMES_PROFILE_DIR in the initialization gate"
else
  pass
fi

printf '\n=== SOUL.md: warns about profile-scoped \$HOME pitfall ===\n'
if grep -qi 'profile.*HOME.*rewrite\|rewrite.*\$HOME\|HOME.*profile.*dir\|\$HOME.*bogus\|profile.*session.*\$HOME' "$SOUL_MD" 2>/dev/null; then
  pass
else
  fail "SOUL.md does not mention the profile-scoped \$HOME pitfall"
fi

printf '\n=== SOUL.md: does NOT contain a large shell snippet ===\n'
if grep -q 'pdir="\${HERMES_PROFILE_DIR:-}"' "$SOUL_MD" 2>/dev/null || grep -q 'INITIALIZATION=present' "$SOUL_MD" 2>/dev/null; then
  fail "SOUL.md still contains a large shell snippet (pdir or INITIALIZATION=present)"
else
  pass
fi

printf '\n=== INITIALIZATION.md: first response greets, introduces Junie, then asks two questions ===\n'
INIT_MD="$ROOT/distribution/INITIALIZATION.md"
if grep -qi 'greet.*owner\|brief.*greeting\|say hello\|hello' "$INIT_MD" 2>/dev/null && \
   grep -qi 'two.*sentence\|couple.*sentence\|briefly.*introduce\|tell.*about.*yourself' "$INIT_MD" 2>/dev/null && \
   grep -qi 'MUST ask exactly those two questions and stop\|ask exactly those two questions and stop\|ask the owner the two initialization questions' "$INIT_MD" 2>/dev/null; then
  pass
else
  fail "INITIALIZATION.md must greet, briefly introduce Junie, then ask the two initialization questions"
fi

printf '\n=== initialization-check.sh: creates and validates Senior Dev AGENTS.md ===\n'
TMP_INIT="$(mktemp -d)"
trap 'rm -rf "$TMP_INIT"' EXIT
PROFILE_TMP="$TMP_INIT/profile"
JUNIE_HOME_TMP="$TMP_INIT/junie-home"
mkdir -p "$PROFILE_TMP/docs" "$PROFILE_TMP/junie" "$JUNIE_HOME_TMP"
cp "$ROOT/distribution/junie/AGENTS.md" "$PROFILE_TMP/junie/AGENTS.md"
cp "$ROOT/distribution/INITIALIZATION.md" "$PROFILE_TMP/INITIALIZATION.md"
cat > "$PROFILE_TMP/docs/tools.md" <<'TOOLS'
Repository: /tmp/project
Install dependencies: N/A - test fixture
Build: N/A - test fixture
Test: N/A - test fixture
Lint: N/A - test fixture
TOOLS
if "$CHECK_SCRIPT" --profile-dir "$PROFILE_TMP" --junie-home "$JUNIE_HOME_TMP" >/dev/null 2>&1 && \
   grep -q 'Senior Dev Operating Contract v2026-06-18' "$JUNIE_HOME_TMP/AGENTS.md" && \
   grep -q 'FINAL_VERDICT_SCHEMA' "$JUNIE_HOME_TMP/AGENTS.md"; then
  pass
else
  fail "initialization-check.sh did not create/validate the Senior Dev AGENTS.md contract"
fi

printf '\n=== HERMES.seed.md: no Initialization mode section ===\n'
SEED_MD="$ROOT/distribution/HERMES.seed.md"
if grep -q '## Initialization mode' "$SEED_MD" 2>/dev/null; then
  fail "HERMES.seed.md still has an Initialization mode section"
else
  pass
fi

printf '\n=== INITIALIZATION.md: required profile config includes approvals.mode off ===\n'
if grep -q 'approvals.mode.*off' "$INIT_MD" && \
   grep -q 'config set approvals.mode' "$INIT_MD" && \
   grep -q 'grep.*mode:' "$INIT_MD" && \
   grep -qE 'approvals\.mode: off' "$INIT_MD"; then
  pass
else
  fail "INITIALIZATION.md required profile config must include approvals.mode off with set and verify commands"
fi

printf '\n=== INITIALIZATION.md: required profile config includes destructive_slash_confirm false ===\n'
if grep -q 'approvals.destructive_slash_confirm' "$INIT_MD" && \
   grep -q 'config set approvals.destructive_slash_confirm' "$INIT_MD"; then
  pass
else
  fail "INITIALIZATION.md required profile config must include destructive_slash_confirm false"
fi

printf '\n=== Seed/guidance files: no removed runtime references ===\n'
# Guidance/seed files should not mention removed runtime mechanisms.
# not reference $HERMES_PROFILE_DIR (which may be unset in tool subprocesses).
# Plugin code (e.g. state.py) where HERMES_PROFILE_DIR is an optional override
# is exempt.
for doc in \
  "$ROOT/distribution/memory-seed.md" \
  "$ROOT/distribution/docs/tools.md" \
  "$ROOT/distribution/HERMES.seed.md" \
  "$ROOT/distribution/skills/junie-coding-task-decomposition/SKILL.md"; do
  if grep -q '\$HERMES_PROFILE_DIR' "$doc" 2>/dev/null; then
    fail "$doc still references \$HERMES_PROFILE_DIR"
  else
    pass
  fi
done

# ---- Summary ----
printf '\n--- Results ---\n'
printf 'Passed: %d, Failed: %d\n' "$pass_count" "$fail_count"

if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi

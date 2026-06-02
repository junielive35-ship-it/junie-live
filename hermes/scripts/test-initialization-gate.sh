#!/usr/bin/env bash
# Test the initialization gate profile-dir resolution for Junie Live Hermes.
# Run from the hermes/ subtree root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_PATHS="$ROOT/initialization/scripts/runtime-paths.sh"
CHECK_SCRIPT="$ROOT/initialization/scripts/initialization-check.sh"

fail_count=0
pass_count=0

pass() { pass_count=$((pass_count + 1)); }
fail() { printf '  FAIL: %s\n' "$*" >&2; fail_count=$((fail_count + 1)); }

if [[ ! -f "$RUNTIME_PATHS" ]]; then
  printf 'ERROR: runtime-paths.sh not found at %s\n' "$RUNTIME_PATHS" >&2
  exit 1
fi

# Run a function from runtime-paths.sh with given env vars.
# Usage: run_with_env "HERMES_HOME=/x; HERMES_PROFILE=y" <func_name>
run_with_env() {
  local env_block="$1" func="$2"
  bash -c "
    unset HERMES_HOME HERMES_PROFILE HERMES_PROFILE_DIR
    source '$RUNTIME_PATHS'
    $env_block
    $func
  " 2>&1
}

# ---- hermes_profile_dir_default tests ----
printf '=== runtime-paths.sh: hermes_profile_dir_default ===\n'

# Test 1: Root-scoped HERMES_HOME with HERMES_PROFILE (standard layout)
r1=$(run_with_env "HERMES_HOME=/home/user/.hermes; HERMES_PROFILE=junie-live" hermes_profile_dir_default)
if [[ "$r1" == "/home/user/.hermes/profiles/junie-live" ]]; then
  pass
else
  fail "root-scoped HERMES_HOME: got '$r1', expected '/home/user/.hermes/profiles/junie-live'"
fi

# Test 2: Profile-scoped HERMES_HOME (THE BUG — current code double-nests)
r2=$(run_with_env "HERMES_HOME=/home/user/.hermes/profiles/junie-live; HERMES_PROFILE=junie-live" hermes_profile_dir_default)
if [[ "$r2" == "/home/user/.hermes/profiles/junie-live" ]]; then
  pass
else
  fail "profile-scoped HERMES_HOME: got '$r2', expected '/home/user/.hermes/profiles/junie-live'"
fi

# Test 3: Profile-scoped HERMES_HOME without HERMES_PROFILE
r3=$(run_with_env "HERMES_HOME=/home/user/.hermes/profiles/junie-live" hermes_profile_dir_default)
if [[ "$r3" == "/home/user/.hermes/profiles/junie-live" ]]; then
  pass
else
  fail "profile-scoped HERMES_HOME, no HERMES_PROFILE: got '$r3', expected '/home/user/.hermes/profiles/junie-live'"
fi

# Test 4: No env vars at all (default to ~/.hermes) — HOME must be set
r4=$(run_with_env "HOME=/home/user" hermes_profile_dir_default)
if [[ "$r4" == "/home/user/.hermes/profiles/junie-live" ]]; then
  pass
else
  fail "no env vars (defaults): got '$r4', expected '/home/user/.hermes/profiles/junie-live'"
fi

# Test 5: Root-scoped HERMES_HOME with custom profile
r5=$(run_with_env "HERMES_HOME=/home/user/.hermes; HERMES_PROFILE=my-app" hermes_profile_dir_default)
if [[ "$r5" == "/home/user/.hermes/profiles/my-app" ]]; then
  pass
else
  fail "root-scoped HERMES_HOME, custom profile: got '$r5', expected '/home/user/.hermes/profiles/my-app'"
fi

# Test 6: Profile-scoped HERMES_HOME matching custom profile
r6=$(run_with_env "HERMES_HOME=/home/user/.hermes/profiles/my-app; HERMES_PROFILE=my-app" hermes_profile_dir_default)
if [[ "$r6" == "/home/user/.hermes/profiles/my-app" ]]; then
  pass
else
  fail "profile-scoped HERMES_HOME, custom profile: got '$r6', expected '/home/user/.hermes/profiles/my-app'"
fi

# ---- initialization-check.sh delegates to runtime-paths.sh ----
# The check script now sources runtime-paths.sh, so the same
# hermes_profile_dir_default tests above cover its resolution logic.
# Verify the delegation works end-to-end:
printf '\n=== initialization-check.sh: sources runtime-paths.sh ===\n'

grep -q 'source.*RUNTIME_PATHS' "$CHECK_SCRIPT" && pass || fail "initialization-check.sh does not source runtime-paths.sh"

printf '\n=== SOUL.md: initialization gate does not depend on env vars ===\n'

SOUL_MD="$ROOT/initialization/SOUL.md"
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

printf '\n=== SOUL.md: prioritizes \$HERMES_HOME before \$HOME fallback ===\n'
if grep -q 'HERMES_HOME.*first\|resolve.*through.*HERMES_HOME\|Always resolve.*HERMES_HOME' "$SOUL_MD" 2>/dev/null; then
  pass
else
  fail "SOUL.md does not explicitly prioritize \$HERMES_HOME before \$HOME fallback"
fi

printf '\n=== SOUL.md: does NOT contain a large shell snippet ===\n'
if grep -q 'pdir="\${HERMES_PROFILE_DIR:-}"' "$SOUL_MD" 2>/dev/null || grep -q 'INITIALIZATION=present' "$SOUL_MD" 2>/dev/null; then
  fail "SOUL.md still contains a large shell snippet (pdir or INITIALIZATION=present)"
else
  pass
fi

printf '\n=== INITIALIZATION.md: first response greets, introduces Junie, then asks two questions ===\n'
INIT_MD="$ROOT/initialization/INITIALIZATION.md"
if grep -qi 'greet.*owner\|brief.*greeting\|say hello\|hello' "$INIT_MD" 2>/dev/null && \
   grep -qi 'two.*sentence\|couple.*sentence\|briefly.*introduce\|tell.*about.*yourself' "$INIT_MD" 2>/dev/null && \
   grep -qi 'MUST ask exactly those two questions and stop\|ask exactly those two questions and stop\|ask the owner the two initialization questions' "$INIT_MD" 2>/dev/null; then
  pass
else
  fail "INITIALIZATION.md must greet, briefly introduce Junie, then ask the two initialization questions"
fi

printf '\n=== seed-HERMES.md: no Initialization mode section ===\n'
SEED_MD="$ROOT/initialization/docs/seed-HERMES.md"
if grep -q '## Initialization mode' "$SEED_MD" 2>/dev/null; then
  fail "seed-HERMES.md still has an Initialization mode section"
else
  pass
fi

printf '\n=== Seed/guidance files: no \044HERMES_PROFILE_DIR mutex references ===\n'
# Guidance/seed files that instruct agents about mutex/profile operations should
# not reference $HERMES_PROFILE_DIR (which may be unset in tool subprocesses).
# Plugin code (e.g. state.py) where HERMES_PROFILE_DIR is an optional override
# is exempt.
for doc in \
  "$ROOT/initialization/memory-seed.md" \
  "$ROOT/initialization/docs/code-mutex-protocol.md" \
  "$ROOT/initialization/docs/tools.md" \
  "$ROOT/initialization/docs/seed-HERMES.md" \
  "$ROOT/initialization/skills/junie-coding-task-decomposition/SKILL.md"; do
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

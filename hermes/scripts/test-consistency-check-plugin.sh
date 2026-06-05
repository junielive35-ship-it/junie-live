#!/usr/bin/env bash
# Test consistency-check plugin: syntax, registration, INITIALIZATION.md wiring,
# hire-junie.sh integration, and doc consistency.
# Run from the hermes/ subtree root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_DIR="$ROOT/distribution/plugins/consistency-check"

fail_count=0
pass_count=0

pass() { pass_count=$((pass_count + 1)); }
fail() { printf '  FAIL: %s\n' "$*" >&2; fail_count=$((fail_count + 1)); }

py_eval() {
  python3 -c "$1" 2>&1
}

# ════════════════════════════════════════════════════════════════
printf '=== Test 1: plugin.yaml exists and is valid ===\n'
if [[ -f "$PLUGIN_DIR/plugin.yaml" ]]; then
  grep -q '^name: consistency-check' "$PLUGIN_DIR/plugin.yaml" || fail "plugin.yaml missing name"
  grep -q '^kind: standalone' "$PLUGIN_DIR/plugin.yaml" || fail "plugin.yaml missing kind"
  pass
  printf '  OK: plugin.yaml has name and kind\n'
else
  fail "plugin.yaml not found at $PLUGIN_DIR/plugin.yaml"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 2: __init__.py registers check-consistency command via ctx.register_command ===\n'
if grep -qF 'ctx.register_command' "$PLUGIN_DIR/__init__.py" && \
   grep -qF 'check-consistency' "$PLUGIN_DIR/__init__.py" && \
   grep -qF 'handle_check_consistency' "$PLUGIN_DIR/__init__.py"; then
  pass
  printf '  OK: __init__.py registers check-consistency command\n'
else
  fail "__init__.py missing register_command with check-consistency"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 3: __init__.py has valid Python syntax ===\n'
if python3 -m py_compile "$PLUGIN_DIR/__init__.py" 2>/dev/null; then
  pass
  printf '  OK: __init__.py syntax valid\n'
else
  fail "__init__.py syntax error"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 4: INITIALIZATION.md contains consistency init command ===\n'
INIT="$ROOT/distribution/INITIALIZATION.md"
if [[ -f "$INIT" ]]; then
  if grep -qF 'consistency_check.py' "$INIT" && \
     grep -qF 'init --repo' "$INIT" && \
     grep -qF 'foreground' "$INIT"; then
    pass
    printf '  OK: INITIALIZATION.md has consistency init step with foreground/blocking\n'
  else
    fail "INITIALIZATION.md missing consistency init details"
  fi
else
  fail "INITIALIZATION.md not found"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 5: hire-junie.sh enables consistency-check plugin ===\n'
HIRE="$ROOT/scripts/hire-junie.sh"
if [[ -f "$HIRE" ]]; then
  if grep -qE 'consistency-check' "$HIRE" && \
     grep -qE '_ensure_plugin.*consistency-check' "$HIRE"; then
    pass
    printf '  OK: hire-junie.sh references consistency-check plugin\n'
  else
    fail "hire-junie.sh missing consistency-check plugin enable block"
  fi
else
  fail "hire-junie.sh not found"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 6: consistency-protocol.md documents slash command ===\n'
PROTOCOL="$ROOT/distribution/docs/consistency-protocol.md"
if [[ -f "$PROTOCOL" ]]; then
  if grep -qF '/check_consistency' "$PROTOCOL" || grep -qF 'check-consistency' "$PROTOCOL"; then
    pass
    printf '  OK: consistency-protocol.md documents slash command\n'
  else
    fail "consistency-protocol.md missing slash command reference"
  fi
else
  fail "consistency-protocol.md not found"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 7: day-to-day-routines.md mentions /check_consistency without "deferred" ===\n'
ROUTINES="$ROOT/../docs/day-to-day-routines.md"
if [[ -f "$ROUTINES" ]]; then
  if grep -qF '/check_consistency' "$ROUTINES" && \
     ! grep -qF 'deferred' "$ROUTINES"; then
    pass
    printf '  OK: day-to-day-routines.md has /check_consistency as primary entrypoint\n'
  else
    fail "day-to-day-routines.md missing /check_consistency or still says deferred"
  fi
else
  # The file is at hermes/docs/day-to-day-routines.md
  ROUTINES2="$ROOT/docs/day-to-day-routines.md"
  if [[ -f "$ROUTINES2" ]]; then
    if grep -qF '/check_consistency' "$ROUTINES2" && \
       ! grep -qF 'deferred' "$ROUTINES2"; then
      pass
      printf '  OK: day-to-day-routines.md has /check_consistency as primary entrypoint\n'
    else
      fail "day-to-day-routines.md missing /check_consistency or still says deferred"
    fi
  else
    fail "day-to-day-routines.md not found at either location"
  fi
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 8: implementation-status.md has consistency check row ===\n'
STATUS="$ROOT/distribution/docs/implementation-status.md"
if [[ -f "$STATUS" ]]; then
  if grep -qF 'Consistency check' "$STATUS"; then
    pass
    printf '  OK: implementation-status.md has consistency check row\n'
  else
    fail "implementation-status.md missing consistency check row"
  fi
else
  fail "implementation-status.md not found"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 9: verify.sh includes consistency-check plugin files ===\n'
VERIFY="$ROOT/scripts/verify.sh"
if [[ -f "$VERIFY" ]]; then
  if grep -qF 'consistency-check' "$VERIFY"; then
    pass
    printf '  OK: verify.sh references consistency-check plugin\n'
  else
    fail "verify.sh missing consistency-check plugin references"
  fi
else
  fail "verify.sh not found"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 10: _normalize_repo_path strips backticks and quotes ===\n'
if py_eval '
import sys; sys.path.insert(0, "'"$PLUGIN_DIR"'")
from importlib import util
spec = util.spec_from_file_location("plugin", "'"$PLUGIN_DIR/__init__.py"'")
mod = util.module_from_spec(spec)
loader = spec.loader
loader.exec_module(mod)
assert mod._normalize_repo_path("`/home/user/repo`") == "/home/user/repo"
assert mod._normalize_repo_path("\"/home/user/repo\"") == "/home/user/repo"
assert mod._normalize_repo_path("'"'"'/home/user/repo'"'"'") == "/home/user/repo"
assert mod._normalize_repo_path("/home/user/repo") == "/home/user/repo"
assert mod._normalize_repo_path("  /home/user/repo  ") == "/home/user/repo"
print("OK")
' 2>&1 | grep -q '^OK$'; then
  pass
  printf '  OK: _normalize_repo_path strips backticks and common quotes\n'
else
  fail "_normalize_repo_path test(s) failed"
  py_eval '
import sys; sys.path.insert(0, "'"$PLUGIN_DIR"'")
from importlib import util
spec = util.spec_from_file_location("plugin", "'"$PLUGIN_DIR/__init__.py"'")
mod = util.module_from_spec(spec)
loader = spec.loader
loader.exec_module(mod)
for raw in [
    "`/home/user/repo`",
    "\"/home/user/repo\"",
    "'"'"'/home/user/repo'"'"'",
    "/home/user/repo",
    "  /home/user/repo  ",
]:
    result = mod._normalize_repo_path(raw)
    print(f"  _normalize_repo_path({raw!r}) => {result!r}")
'
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 11: _resolve_repo handles backtick-wrapped --repo value ===\n'
# Simulate raw_args as Hermes would pass them: --repo `path`
# Using shlex.split ensures backticks are literal characters, then _normalize strips them
if py_eval '
import sys; sys.path.insert(0, "'"$PLUGIN_DIR"'")
from importlib import util
spec = util.spec_from_file_location("plugin", "'"$PLUGIN_DIR/__init__.py"'")
mod = util.module_from_spec(spec)
loader = spec.loader
loader.exec_module(mod)
result = mod._resolve_repo("--repo `/home/user/repo`")
assert result == "/home/user/repo", f"expected /home/user/repo, got {result!r}"
# Also test shlex handles quoted paths
result2 = mod._resolve_repo("--repo \"/home/user/repo with spaces\"")
assert result2 == "/home/user/repo with spaces", f"expected quoted path, got {result2!r}"
print("OK")
' 2>&1 | grep -q '^OK$'; then
  pass
  printf '  OK: _resolve_repo with --repo strips backticks/quotes\n'
else
  fail "_resolve_repo --repo test(s) failed"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 12: _resolve_repo with JUNIE_REPO env var strips backticks ===\n'
if JUNIE_REPO='`/env/var/repo`' py_eval '
import os; import sys
sys.path.insert(0, "'"$PLUGIN_DIR"'")
from importlib import util
spec = util.spec_from_file_location("plugin", "'"$PLUGIN_DIR/__init__.py"'")
mod = util.module_from_spec(spec)
loader = spec.loader
loader.exec_module(mod)
# Force JUNIE_REPO by passing empty args so --repo and tools.md aren''t used
result = mod._resolve_repo("")
assert result == "/env/var/repo", f"expected /env/var/repo, got {result!r}"
print("OK")
' 2>&1 | grep -q '^OK$'; then
  pass
  printf '  OK: JUNIE_REPO backticks stripped\n'
else
  fail "JUNIE_REPO normalization test(s) failed"
fi

# ════════════════════════════════════════════════════════════════
printf '\n'
printf '=== Results ===\n'
printf 'Passed: %d, Failed: %d\n' "$pass_count" "$fail_count"

if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi

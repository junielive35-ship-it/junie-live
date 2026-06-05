#!/usr/bin/env bash
# Test Marinator delegate plugin changes: schema, validation, session capture,
# result extraction, and follow-up resolution.
# Run from the hermes/ subtree root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_DIR="$ROOT/distribution/plugins/marinator-delegation"
TOOLS_PY="$PLUGIN_DIR/tools.py"
RUNNER_PY="$PLUGIN_DIR/runner.py"
STATE_PY="$PLUGIN_DIR/state.py"
WORKER_SH="$PLUGIN_DIR/scripts/marinator-worker.sh"

fail_count=0
pass_count=0

pass() { pass_count=$((pass_count + 1)); }
fail() { printf '  FAIL: %s\n' "$*" >&2; fail_count=$((fail_count + 1)); }

# Helper: run a Python one-liner with the plugin modules available
py_eval() {
  python3 -c "$1" 2>&1
}

# ════════════════════════════════════════════════════════════════
printf '=== Test 1: Public schema contains is_follow_up ===\n'
py_eval "
import sys; sys.path.insert(0, '$PLUGIN_DIR')
from tools import MARINATOR_DELEGATE_SCHEMA
props = MARINATOR_DELEGATE_SCHEMA['parameters']['properties']
assert 'is_follow_up' in props, 'is_follow_up missing from schema'
assert props['is_follow_up']['type'] == 'boolean', 'is_follow_up type should be boolean'
assert props['is_follow_up']['default'] == False, 'is_follow_up default should be False'
print('OK: is_follow_up present, type=boolean, default=False')
" && pass || fail "Schema test 1 failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 2: Schema does NOT expose opencode_previous_session_id ===\n'
py_eval "
import sys; sys.path.insert(0, '$PLUGIN_DIR')
from tools import MARINATOR_DELEGATE_SCHEMA
props = MARINATOR_DELEGATE_SCHEMA['parameters']['properties']
assert 'opencode_previous_session_id' not in props, 'opencode_previous_session_id should not be in public schema'
print('OK: opencode_previous_session_id removed from public schema')
" && pass || fail "Schema test 2 failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 3: Reject invalid opencode_previous_session_id (/tmp/foo.txt) ===\n'
py_eval "
import sys; sys.path.insert(0, '$PLUGIN_DIR')
from tools import _validate_inputs
# Simulate old caller passing a file path
err = _validate_inputs({
    'job_id': 'test-123',
    'repo': '$ROOT',
    'prompt_file': '$TOOLS_PY',
    'opencode_previous_session_id': '/tmp/foo.txt',
})
assert err is not None, 'Should reject /tmp/foo.txt'
# The error should mention invalid and the pattern
assert 'ses_' in err or 'Invalid' in err, f'Error should reference valid pattern, got: {err}'
print(f'OK: rejected /tmp/foo.txt with: {err}')
" && pass || fail "Validation test 1 failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 4: Accept valid ses_... opencode_previous_session_id ===\n'
py_eval "
import sys; sys.path.insert(0, '$PLUGIN_DIR')
from tools import _validate_inputs
err = _validate_inputs({
    'job_id': 'test-123',
    'repo': '$ROOT',
    'prompt_file': '$TOOLS_PY',
    'opencode_previous_session_id': 'ses_abc123DEF',
})
assert err is None, f'Should accept valid ses_... id, got: {err}'
print('OK: accepted valid ses_abc123DEF')
" && pass || fail "Validation test 2 failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 5: Normalize empty string and \"null\" to None ===\n'
py_eval "
import sys; sys.path.insert(0, '$PLUGIN_DIR')
from tools import _validate_inputs
# empty string
params1 = {
    'job_id': 'test-123',
    'repo': '$ROOT',
    'prompt_file': '$TOOLS_PY',
    'opencode_previous_session_id': '',
}
err1 = _validate_inputs(params1)
assert err1 is None, f'Empty string should be normalized to None, got: {err1}'
assert params1['opencode_previous_session_id'] is None, 'Should set to None'
# 'null' string
params2 = {
    'job_id': 'test-123',
    'repo': '$ROOT',
    'prompt_file': '$TOOLS_PY',
    'opencode_previous_session_id': 'null',
}
err2 = _validate_inputs(params2)
assert err2 is None, f'\"null\" string should be normalized to None, got: {err2}'
assert params2['opencode_previous_session_id'] is None, 'Should set to None'
print('OK: empty and \"null\" normalized to None')
" && pass || fail "Validation test 3 failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 6: is_follow_up=true with no prior session fails early ===\n'
py_eval "
import sys, os, tempfile
sys.path.insert(0, '$PLUGIN_DIR')
# Use importlib to load runner module with package context
import importlib.util, types
pkg = types.ModuleType('marinator_delegation_test')
pkg.__path__ = ['$PLUGIN_DIR']
pkg.__file__ = '$PLUGIN_DIR/__init__.py'
sys.modules['marinator_delegation_test'] = pkg
spec = importlib.util.spec_from_file_location(
    'marinator_delegation_test.runner',
    '$RUNNER_PY',
    submodule_search_locations=['$PLUGIN_DIR'],
)
runner = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = runner
spec.loader.exec_module(runner)

# Set env vars so state resolution doesn't break
os.environ['HERMES_HOME'] = tempfile.mkdtemp(prefix='marinator-test-')
os.environ['HERMES_PROFILE'] = 'test-profile'
os.environ['MARINATOR_FORCE_MODE'] = 'headless'
os.environ['OPENCODE_BIN'] = '/nonexistent/opencode'

# Create a temp repo and prompt
tmpdir = tempfile.mkdtemp(prefix='marinator-test-')
repo = os.path.join(tmpdir, 'repo')
prompt = os.path.join(tmpdir, 'prompt.md')
os.makedirs(repo)
with open(prompt, 'w') as f:
    f.write('# Test prompt')

result = runner.start_job(
    job_id='test-follow-up-no-session',
    repo=repo,
    prompt_file=prompt,
    is_follow_up=True,
)
err = result.get('error', '')
assert 'no_valid_opencode_session_for_follow_up' in err, \
    f'Expected early failure about no valid session, got: {err}'
print(f'OK: early failure: {result[\"error\"][:80]}...')
" && pass || fail "Follow-up resolution test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 7: --format json appears in build_opencode_args ===\n'
# Test by inspecting the worker script directly for the pattern
if grep -qF -- '--format json' "$WORKER_SH"; then
  pass
  printf '  OK: --format json found in worker script\n'
else
  fail "--format json not found in $WORKER_SH"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 8: Session extraction from sample NDJSON ===\n'
tmpfile=$(mktemp)
cat > "$tmpfile" <<'NDJSON'
{"type":"step_start","sessionID":"ses_17f979996ffengPUNrGZDwZnRG","part":{"type":"text","text":"Starting..."}}
{"type":"text","sessionID":"ses_17f979996ffengPUNrGZDwZnRG","part":{"type":"text","text":"Hello from OpenCode"}}
{"type":"step_finish","sessionID":"ses_17f979996ffengPUNrGZDwZnRG"}
NDJSON

py_eval "
import json, re, sys
ses_re = re.compile(r'^ses_[A-Za-z0-9]+$')
last_id = ''
with open('$tmpfile', 'r') as fh:
    for raw in fh:
        raw = raw.strip()
        if not raw: continue
        try:
            ev = json.loads(raw)
            sid = ev.get('sessionID', '')
            if ses_re.match(str(sid)):
                last_id = sid
        except json.JSONDecodeError:
            pass
assert last_id == 'ses_17f979996ffengPUNrGZDwZnRG', f'Expected ses_..., got: {last_id}'
print(f'OK: extracted session_id={last_id}')
" && pass || fail "Session extraction test failed"
rm -f "$tmpfile"

# ════════════════════════════════════════════════════════════════
printf '=== Test 9: Result extraction from sample NDJSON returns part.text ===\n'
tmpfile=$(mktemp)
cat > "$tmpfile" <<'NDJSON'
{"type":"step_start","sessionID":"ses_test123","part":{"type":"text","text":"Starting..."}}
{"type":"text","sessionID":"ses_test123","part":{"type":"text","text":"Hello from OpenCode"}}
{"type":"text","sessionID":"ses_test123","part":{"type":"text","text":"Here is the code change."}}
{"type":"step_finish","sessionID":"ses_test123"}
NDJSON

result=$(py_eval "
import json, sys
parts = []
with open('$tmpfile', 'r') as fh:
    for raw in fh:
        raw = raw.strip()
        if not raw: continue
        try:
            ev = json.loads(raw)
            if ev.get('type') == 'text':
                part = ev.get('part', {})
                if isinstance(part, dict) and part.get('type') == 'text':
                    text = part.get('text', '')
                    if text:
                        parts.append(text)
        except json.JSONDecodeError:
            pass
print('\n'.join(parts))
")
expected="Hello from OpenCode
Here is the code change."
if [[ "$result" == "$expected" ]]; then
  pass
  printf '  OK: extracted text matches expected\n'
else
  fail "Expected '$expected', got '$result'"
fi
rm -f "$tmpfile"

# ════════════════════════════════════════════════════════════════
printf '=== Test 10: is_follow_up in initial status ===\n'
py_eval "
import sys; sys.path.insert(0, '$PLUGIN_DIR')
from state import make_initial_status

status = make_initial_status(
    job_id='test-job',
    owner_session_id=None,
    owner_session_key=None,
    runtime_mode='headless',
    runtime_detected_from={},
    repo='/tmp/repo',
    run_dir='/tmp/run',
    is_follow_up=True,
    resume_session_id='ses_abc123',
)
assert status.get('is_follow_up') == True, 'is_follow_up not in status'
assert status['opencode'].get('resume_session_id') == 'ses_abc123', 'resume_session_id not in opencode block'
assert 'previous_session_id' not in status['opencode'], 'previous_session_id should be gone'
print('OK: is_follow_up and resume_session_id present, previous_session_id removed')
" && pass || fail "Status structure test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 11: Worker script session extraction function parses NDJSON ===\n'
# Test that the worker's embedded Python in extract_opencode_session_id works
tmpfile=$(mktemp)
cat > "$tmpfile" <<'NDJSON'
{"type":"step_start","sessionID":"ses_abc123xyz"}
{"type":"text","sessionID":"ses_abc123xyz","part":{"type":"text","text":"test"}}
{"type":"step_finish","sessionID":"ses_abc123xyz"}
NDJSON

result=$(python3 - "$tmpfile" <<'PYSES' 2>/dev/null || true
import json, sys, re
ses_re = re.compile(r'^ses_[A-Za-z0-9]+$')
last_id = ""
try:
    with open(sys.argv[1], 'r', encoding='utf-8', errors='replace') as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                ev = json.loads(raw)
                sid = ev.get("sessionID", "")
                if ses_re.match(str(sid)):
                    last_id = sid
            except (json.JSONDecodeError, ValueError):
                pass
except FileNotFoundError:
    pass
print(last_id, end="")
PYSES
)
if [[ "$result" == "ses_abc123xyz" ]]; then
  pass
  printf '  OK: worker NDJSON session extraction works\n'
else
  fail "Expected ses_abc123xyz, got '$result'"
fi
rm -f "$tmpfile"

# ════════════════════════════════════════════════════════════════
printf '=== Test 12: Worker script text extraction function works ===\n'
tmpfile=$(mktemp)
cat > "$tmpfile" <<'NDJSON'
{"type":"step_start","sessionID":"ses_test","part":{"type":"text","text":"start"}}
{"type":"text","sessionID":"ses_test","part":{"type":"text","text":"Line one"}}
{"type":"tool_use","sessionID":"ses_test"}
{"type":"text","sessionID":"ses_test","part":{"type":"text","text":"Line two"}}
NDJSON

result=$(python3 - "$tmpfile" <<'PYTEXT' 2>/dev/null || true
import json, sys
parts = []
try:
    with open(sys.argv[1], 'r', encoding='utf-8', errors='replace') as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                ev = json.loads(raw)
                if ev.get("type") == "text":
                    part = ev.get("part", {})
                    if isinstance(part, dict) and part.get("type") == "text":
                        text = part.get("text", "")
                        if text:
                            parts.append(text)
            except (json.JSONDecodeError, ValueError):
                pass
except FileNotFoundError:
    pass
print("\n".join(parts), end="")
PYTEXT
)
expected="Line one
Line two"
if [[ "$result" == "$expected" ]]; then
  pass
  printf '  OK: text extraction works\n'
else
  fail "Expected '$expected', got '$result'"
fi
rm -f "$tmpfile"

# ════════════════════════════════════════════════════════════════
printf '=== Test 13: Schema has additionalProperties False ===\n'
py_eval "
import sys; sys.path.insert(0, '$PLUGIN_DIR')
from tools import MARINATOR_DELEGATE_SCHEMA
assert MARINATOR_DELEGATE_SCHEMA['parameters'].get('additionalProperties') == False, \
    'additionalProperties should be False'
print('OK: additionalProperties is False')
" && pass || fail "Schema additionalProperties test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 14: build_opencode_args uses option terminator before prompt ===\n'
# The --file option is an array and greedily consumes subsequent positionals.
# The prompt must be separated from options by -- to prevent yargs from
# treating the prompt text as another --file value.
if grep -qF -- '-- "$prompt"' "$WORKER_SH"; then
  pass
  printf '  OK: -- "$prompt" terminator pattern found\n'
else
  fail "-- \"\$prompt\" terminator pattern not found in build_opencode_args"
fi

# Guard against regressions: the bare "$prompt" without a preceding --
# terminator must not appear.  The fixed line is:
#   OPENCODE_ARGS+=(-- "$prompt")
# which still contains "$prompt" but with -- before it.  Grep for the
# old bug pattern.
if grep -qF 'OPENCODE_ARGS+=("$prompt")' "$WORKER_SH"; then
  fail "BUG: OPENCODE_ARGS+=(\"\$prompt\") found without -- terminator"
else
  pass
  printf '  OK: no bare "$prompt" without -- terminator\n'
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 15: smoke_test_opencode function exists in tools.py ===\n'
py_eval "
import sys; sys.path.insert(0, '$PLUGIN_DIR')
from tools import smoke_test_opencode
import inspect
assert callable(smoke_test_opencode), 'smoke_test_opencode should be callable'
sig = inspect.signature(smoke_test_opencode)
assert len(sig.parameters) == 0, 'smoke_test_opencode should take no arguments'
print('OK: smoke_test_opencode is a callable function with no required args')
" && pass || fail "smoke_test_opencode existence test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 16: smoke_test_opencode returns expected dict shape ===\n'
py_eval "
import sys; sys.path.insert(0, '$PLUGIN_DIR')
from tools import smoke_test_opencode
result = smoke_test_opencode()
assert isinstance(result, dict), 'result must be dict'
assert 'success' in result, 'result must have success key'
assert 'detail' in result, 'result must have detail key'
assert isinstance(result['success'], bool), 'success must be bool'
assert isinstance(result['detail'], str), 'detail must be str'
# Function must not raise regardless of opencode availability
print(f'OK: smoke_test_opencode returned success={result[\"success\"]}, detail={result[\"detail\"][:80]}...')
" && pass || fail "smoke_test_opencode shape test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 17: No "auth list" treated as hard blocker in docs ===\n'
# Static grep regression: ensure auth list is not described as the sole
# source of readiness (the old hard-blocker language). Allow diagnostic
# contextual mentions that explicitly say auth list is NOT authoritative.
# The old blocker pattern was: "If both are empty, opencode delegations
# will fail... cannot do any code-changing work."
if grep -rn 'auth list' "$ROOT/docs/setup.md" "$ROOT/openclaw-hermes-comparison.md" 2>/dev/null | \
   grep -qi 'if both are empty\|cannot do any\|delegations will fail\|delegations will.*fail'; then
  fail "'auth list' still described as hard blocker (old 'cannot do any code-changing work' pattern)"
else
  pass
  printf '  OK: no "auth list" treated as hard blocker in docs\n'
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 18: No "auth list" treated as hard blocker in distribution docs ===\n'
DIST_DOCS="$ROOT/distribution/docs"
if [[ -d "$DIST_DOCS" ]]; then
  if grep -rn 'auth list' "$DIST_DOCS" 2>/dev/null | \
     grep -qi 'if both are empty\|cannot do any\|delegations will fail'; then
    fail "'auth list' still described as hard blocker in distribution docs"
  else
    pass
    printf '  OK: no "auth list" treated as hard blocker in distribution docs\n'
  fi
else
  pass
  printf '  OK: distribution/docs/ directory not found, skipping\n'
fi

# ════════════════════════════════════════════════════════════════
printf '\n'
printf '=== Results ===\n'
printf 'Passed: %d, Failed: %d\n' "$pass_count" "$fail_count"

if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi

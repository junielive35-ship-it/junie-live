#!/usr/bin/env bash
# Test Autonomous Work plugin: state helpers, duration parsing, window lifecycle,
# and transition table. Run from the hermes/ subtree root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_DIR="$ROOT/distribution/plugins/autonomous-work"
HOT_SWAP_SCRIPT="$ROOT/scripts/hot-swap-autonomous-work-plugin.sh"

fail_count=0
pass_count=0

pass() { pass_count=$((pass_count + 1)); }
fail() { printf '  FAIL: %s\n' "$*" >&2; fail_count=$((fail_count + 1)); }

# Run Python code with state.py loaded directly
run_state_test() {
  python3 -c "
import sys, importlib.util, importlib.machinery
loader = importlib.machinery.SourceFileLoader('aw_state', '$PLUGIN_DIR/state.py')
spec = importlib.util.spec_from_loader('aw_state', loader)
state = importlib.util.module_from_spec(spec)
loader.exec_module(state)
$1
" 2>&1
}

# Run Python code with prompts.py loaded directly
run_prompts_test() {
  python3 -c "
import sys, importlib.util, importlib.machinery
sloader = importlib.machinery.SourceFileLoader('aw_state', '$PLUGIN_DIR/state.py')
sspec = importlib.util.spec_from_loader('aw_state', sloader)
state_mod = importlib.util.module_from_spec(sspec)
sloader.exec_module(state_mod)
ploader = importlib.machinery.SourceFileLoader('aw_prompts', '$PLUGIN_DIR/prompts.py')
pspec = importlib.util.spec_from_loader('aw_prompts', ploader)
prompts_mod = importlib.util.module_from_spec(pspec)
ploader.exec_module(prompts_mod)
$1
" 2>&1
}

# Run Python code with backlog.py loaded directly
run_backlog_test() {
  python3 -c "
import sys, importlib.util, importlib.machinery, types

# Load state module
sloader = importlib.machinery.SourceFileLoader('aw_state', '$PLUGIN_DIR/state.py')
sspec = importlib.util.spec_from_loader('aw_state', sloader)
state_mod = importlib.util.module_from_spec(sspec)
sys.modules['aw_state'] = state_mod
sloader.exec_module(state_mod)

# Create package so relative imports work
pkg = types.ModuleType('aw_pkg')
pkg.__path__ = ['$PLUGIN_DIR']
pkg.__package__ = 'aw_pkg'
pkg.state = state_mod
sys.modules['aw_pkg'] = pkg
sys.modules['aw_pkg.state'] = state_mod

# Load backlog as aw_pkg.backlog
bloader = importlib.machinery.SourceFileLoader('aw_pkg.backlog', '$PLUGIN_DIR/backlog.py')
bspec = importlib.util.spec_from_loader('aw_pkg.backlog', bloader)
backlog = importlib.util.module_from_spec(bspec)
sys.modules['aw_pkg.backlog'] = backlog
bloader.exec_module(backlog)
$1
" 2>&1
}

# Run Python code with tools.py loaded (resolves relative imports via package)
run_tools_test() {
  python3 -c "
import sys, importlib.util, importlib.machinery, types

# Load state module
sloader = importlib.machinery.SourceFileLoader('aw_state', '$PLUGIN_DIR/state.py')
sspec = importlib.util.spec_from_loader('aw_state', sloader)
state_mod = importlib.util.module_from_spec(sspec)
sys.modules['aw_state'] = state_mod
sloader.exec_module(state_mod)

# Load prompts module
ploader = importlib.machinery.SourceFileLoader('aw_prompts', '$PLUGIN_DIR/prompts.py')
pspec = importlib.util.spec_from_loader('aw_prompts', ploader)
prompts_mod = importlib.util.module_from_spec(pspec)
sys.modules['aw_prompts'] = prompts_mod
ploader.exec_module(prompts_mod)

# Create package so relative imports work
pkg = types.ModuleType('aw_pkg')
pkg.__path__ = ['$PLUGIN_DIR']
pkg.__package__ = 'aw_pkg'
pkg.state = state_mod
pkg.prompts = prompts_mod
sys.modules['aw_pkg'] = pkg
sys.modules['aw_pkg.state'] = state_mod
sys.modules['aw_pkg.prompts'] = prompts_mod

# Load backlog module (needed by tools)
bloader = importlib.machinery.SourceFileLoader('aw_pkg.backlog', '$PLUGIN_DIR/backlog.py')
bspec = importlib.util.spec_from_loader('aw_pkg.backlog', bloader)
backlog_mod = importlib.util.module_from_spec(bspec)
sys.modules['aw_pkg.backlog'] = backlog_mod
bloader.exec_module(backlog_mod)

# Load tools as aw_pkg.tools
tloader = importlib.machinery.SourceFileLoader('aw_pkg.tools', '$PLUGIN_DIR/tools.py')
tspec = importlib.util.spec_from_loader('aw_pkg.tools', tloader)
tools_mod = importlib.util.module_from_spec(tspec)
sys.modules['aw_pkg.tools'] = tools_mod
tloader.exec_module(tools_mod)
$1
" 2>&1
}

# ════════════════════════════════════════════════════════════════
printf '=== Test 1: Duration parsing ===\n'
run_state_test "
assert state.parse_duration('2h') == 7200, '2h should be 7200s'
assert state.parse_duration('90m') == 5400, '90m should be 5400s'
assert state.parse_duration('30s') == 30, '30s should be 30s'
assert state.parse_duration('1 hour') == 3600, '1 hour should be 3600s'
assert state.parse_duration('5 minutes') == 300, '5 minutes should be 300s'
assert state.parse_duration('invalid') is None, 'invalid should return None'
assert state.parse_duration('') is None, 'empty should return None'
assert state.parse_duration('-1h') is None, 'negative should return None'
print('OK: all duration tests passed')
" && pass || fail "Duration parsing test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 2: Valid window id ===\n'
run_state_test "
assert state.is_valid_window_id('AW-20260601-001'), 'valid id'
assert state.is_valid_window_id('AW-20260101-999'), 'valid id high'
assert not state.is_valid_window_id('AW-20260101-'), 'incomplete'
assert not state.is_valid_window_id('foo'), 'random string'
assert not state.is_valid_window_id(''), 'empty'
print('OK: window id validation works')
" && pass || fail "Window id validation failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 3: Window id sequence ===\n'
run_state_test "
import os, tempfile
os.environ['HERMES_HOME'] = tempfile.mkdtemp(prefix='aw-test-')
os.environ['HERMES_PROFILE'] = 'test-profile'
wid1 = state.generate_window_id()
assert wid1.startswith('AW-'), f'should start with AW-, got {wid1}'
print(f'OK: generated window id: {wid1}')
" && pass || fail "Window id generation failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 4: Initial window shape ===\n'
run_state_test "
win = state.make_initial_window(
    window_id='AW-20260601-001',
    duration_seconds=7200,
    owner_prompt='Test owner guidance',
    owner_session_id='ses_test123',
    repo='/tmp/test-repo',
)
assert win['window_id'] == 'AW-20260601-001'
assert win['phase'] == 'snapshot_preflight'
assert win['continuation'] == 'continue_now'
assert win['status'] == 'running'
assert win['duration_seconds'] == 7200
assert win['prompt'] == 'Test owner guidance'
assert win['owner_session_id'] == 'ses_test123'
assert win['selected_item'] is None
assert win['completed_items'] == []
assert win['blocked_items'] == []
assert win['failure_count'] == 0
assert win['failure_budget'] == 3
assert win['enable_debug_messages'] == True, 'debug messages default true'
print('OK: initial window has correct shape')

# Also verify the flag can be set to False
win_no_debug = state.make_initial_window(
    window_id='AW-20260601-002',
    duration_seconds=3600,
    owner_prompt=None,
    owner_session_id=None,
    repo='/tmp/repo',
    enable_debug_messages=False,
)
assert win_no_debug['enable_debug_messages'] == False
print('OK: enable_debug_messages=False works')
" && pass || fail "Initial window shape failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 5: Atomic write/read ===\n'
run_state_test "
import os, tempfile
tmpdir = tempfile.mkdtemp(prefix='aw-test-')
path = os.path.join(tmpdir, 'test.json')
data = {'hello': 'world', 'nested': {'a': 1}}
state.atomic_write_json(path, data)
result = state.read_json(path)
assert result == data, f'round-trip failed: {result} != {data}'
none_result = state.read_json(os.path.join(tmpdir, 'nonexistent.json'))
assert none_result is None, 'missing file should return None'
corrupt = os.path.join(tmpdir, 'corrupt.json')
with open(corrupt, 'w') as f:
    f.write('not json')
corrupt_result = state.read_json(corrupt)
assert corrupt_result is None, 'corrupt file should return None'
print('OK: atomic write/read works')
" && pass || fail "Atomic write/read failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 6: Append event ===\n'
run_state_test "
import os, tempfile
tmpdir = tempfile.mkdtemp(prefix='aw-test-')
events_path = os.path.join(tmpdir, 'events.jsonl')
event1 = state.append_event(events_path, 'test_event', {'key': 'val1'})
assert event1['type'] == 'test_event'
assert event1['data']['key'] == 'val1'
event2 = state.append_event(events_path, 'test_event2')
assert event2['type'] == 'test_event2'
with open(events_path, 'r') as f:
    lines = f.readlines()
assert len(lines) == 2, f'expected 2 lines, got {len(lines)}'
print('OK: append event works')
" && pass || fail "Append event failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 7: Active window management ===\n'
run_state_test "
import os, tempfile
os.environ['HERMES_HOME'] = tempfile.mkdtemp(prefix='aw-test-')
os.environ['HERMES_PROFILE'] = 'test-profile'
assert state.get_active_window() is None, 'should be None initially'
state.set_active_window('AW-test-001')
active = state.get_active_window()
assert active is not None
assert active['window_id'] == 'AW-test-001'
state.clear_active_window()
assert state.get_active_window() is None, 'should be None after clear'
print('OK: active window management works')
" && pass || fail "Active window management failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 8: Window directory creation ===\n'
run_state_test "
import os, tempfile
os.environ['HERMES_HOME'] = tempfile.mkdtemp(prefix='aw-test-')
os.environ['HERMES_PROFILE'] = 'test-profile'
window_dir = state.create_window_dir('AW-test-002')
assert os.path.isdir(window_dir), f'dir should exist: {window_dir}'
assert os.path.isdir(os.path.join(window_dir, 'logs'))
assert os.path.isdir(os.path.join(window_dir, 'control'))
assert os.path.isdir(os.path.join(window_dir, 'locks'))
print(f'OK: window directory created at {window_dir}')
" && pass || fail "Window directory creation failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 9: Artifact path helpers ===\n'
run_state_test "
window_dir = '/tmp/aw-test-window'
assert state.get_window_json_path(window_dir) == '/tmp/aw-test-window/window.json'
assert state.get_events_path(window_dir) == '/tmp/aw-test-window/events.jsonl'
assert state.get_selection_path(window_dir) == '/tmp/aw-test-window/selection.md'
assert state.get_final_report_path(window_dir) == '/tmp/aw-test-window/final_report.md'
assert state.get_cancel_path(window_dir) == '/tmp/aw-test-window/control/cancel'
assert state.get_runner_lock_path(window_dir) == '/tmp/aw-test-window/locks/runner.lock'
assert state.get_step_lock_path(window_dir) == '/tmp/aw-test-window/locks/step.lock'
print('OK: artifact path helpers')
" && pass || fail "Artifact path helpers failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 10: Phase/continuation validation ===\n'
run_state_test "
assert state.is_terminal('final'), 'final should be terminal'
assert state.is_terminal('blocked'), 'blocked should be terminal'
assert not state.is_terminal('continue_now'), 'continue_now should not be terminal'
assert not state.is_terminal('wait_external'), 'wait_external should not be terminal'
assert state.is_terminal_phase('completed'), 'completed should be terminal'
assert state.is_terminal_phase('cancelled'), 'cancelled should be terminal'
assert state.is_terminal_phase('failed'), 'failed should be terminal'
assert not state.is_terminal_phase('running'), 'running should not be terminal'
assert 'snapshot_preflight' in state.VALID_PHASES
assert 'candidate_generation' in state.VALID_PHASES
assert 'executing_task' in state.VALID_PHASES
assert 'continue_now' in state.VALID_CONTINUATIONS
print('OK: phase/continuation validation')
" && pass || fail "Phase validation failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 11: Tool schemas correct ===\n'
run_tools_test "
# start schema
start_props = tools_mod.AUTONOMOUS_WORK_START_SCHEMA['parameters']['properties']
assert 'duration' in start_props, 'duration required'
assert start_props['duration']['type'] == 'string'
assert 'prompt' in start_props, 'prompt optional'
assert 'enable_debug_messages' in start_props, 'enable_debug_messages in schema'
assert start_props['enable_debug_messages']['type'] == 'boolean'
assert start_props['enable_debug_messages'].get('default') == True, 'default should be True'
assert tools_mod.AUTONOMOUS_WORK_START_SCHEMA['parameters']['required'] == ['duration']
assert tools_mod.AUTONOMOUS_WORK_START_SCHEMA['parameters'].get('additionalProperties') == False
# step schema
step_props = tools_mod.AUTONOMOUS_WORK_STEP_SCHEMA['parameters']['properties']
assert 'rationale' in step_props, 'rationale in schema'
assert step_props['rationale']['type'] == 'string'
assert tools_mod.AUTONOMOUS_WORK_STEP_SCHEMA['parameters']['required'] == []
assert tools_mod.AUTONOMOUS_WORK_STEP_SCHEMA['parameters'].get('additionalProperties') == False
print('OK: tool schemas correct')
" && pass || fail "Tool schemas test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 12: Prompt construction ===\n'
run_prompts_test "
import os, tempfile
window = {
    'window_id': 'AW-20260601-001',
    'end_at': 9999999999,
    'prompt': 'test guidance',
    'repo': '/tmp/test-repo',
}
tmpdir = tempfile.mkdtemp(prefix='aw-test-')
result = prompts_mod.build_step_prompt(window, tmpdir, 'snapshot_preflight')
assert result['phase'] == 'snapshot_preflight'
assert os.path.isfile(result['prompt_path']), 'prompt file should exist'
prompt_content = open(result['prompt_path']).read()
assert 'snapshot_preflight' in prompt_content, f'snapshot_preflight phase not in prompt content'
print(f'OK: prompt built for snapshot_preflight')

result2 = prompts_mod.build_step_prompt(window, tmpdir, 'executing_task', selected_item='ITEM-001')
assert 'ITEM-001' in open(result2['prompt_path']).read()
print(f'OK: prompt built for executing_task with selected_item')

result3 = prompts_mod.build_step_prompt(window, tmpdir, 'finalizing')
assert 'final_report.md' in open(result3['prompt_path']).read()
print(f'OK: prompt built for finalizing')
" && pass || fail "Prompt construction failed"

# ════════════════════════════════════════════════════════════════
# ════════════════════════════════════════════════════════════════
printf '=== Test 13: executing_task prompt includes Senior Dev debug flag ===\n'
run_prompts_test "
import os, tempfile

# Test with debug enabled (default)
window_debug_true = {
    'window_id': 'AW-20260601-001',
    'end_at': 9999999999,
    'prompt': 'test',
    'repo': '/tmp/test-repo',
    'enable_debug_messages': True,
}
tmpdir = tempfile.mkdtemp(prefix='aw-test-')
result = prompts_mod.build_step_prompt(window_debug_true, tmpdir, 'executing_task', selected_item='ITEM-001')
content = open(result['prompt_path']).read()
assert 'create_senior_task' in content, f'expected create_senior_task in prompt, got content:\\n{content}'
assert 'enable_per_minute_reports=True' in content, f'expected True flag in prompt, got content:\\n{content}'
assert 'marinator_delegate' not in content, f'unexpected direct marinator_delegate in prompt:\\n{content}'
print('OK: executing_task prompt has create_senior_task and enable_per_minute_reports=True when debug enabled')

# Test with debug disabled
window_debug_false = {
    'window_id': 'AW-20260601-002',
    'end_at': 9999999999,
    'prompt': 'test',
    'repo': '/tmp/test-repo',
    'enable_debug_messages': False,
}
tmpdir2 = tempfile.mkdtemp(prefix='aw-test-')
result2 = prompts_mod.build_step_prompt(window_debug_false, tmpdir2, 'executing_task', selected_item='ITEM-002')
content2 = open(result2['prompt_path']).read()
assert 'create_senior_task' in content2, f'expected create_senior_task in prompt, got content:\\n{content2}'
assert 'enable_per_minute_reports=False' in content2, f'expected False flag in prompt, got content:\\n{content2}'
assert 'marinator_delegate' not in content2, f'unexpected direct marinator_delegate in prompt:\\n{content2}'
print('OK: executing_task prompt has create_senior_task and enable_per_minute_reports=False when debug disabled')

# Test backward compatibility: omitted defaults to True
window_no_flag = {
    'window_id': 'AW-20260601-003',
    'end_at': 9999999999,
    'prompt': 'test',
    'repo': '/tmp/test-repo',
}
tmpdir3 = tempfile.mkdtemp(prefix='aw-test-')
result3 = prompts_mod.build_step_prompt(window_no_flag, tmpdir3, 'executing_task', selected_item='ITEM-003')
content3 = open(result3['prompt_path']).read()
assert 'create_senior_task' in content3, 'prompt should route through create_senior_task'
assert 'enable_per_minute_reports=True' in content3, 'omitted flag should default to True'
assert 'marinator_delegate' not in content3, 'prompt should not expose direct marinator_delegate'
print('OK: omitted enable_debug_messages defaults to True')
" && pass || fail "executing_task Senior Dev debug flag test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 14: Transition detection helpers ===\n'
run_tools_test "
import os, tempfile
# Outcome parsing
assert tools_mod._parse_outcome_from_text('outcome: done') == 'done'
assert tools_mod._parse_outcome_from_text('outcome: blocked') == 'blocked'
assert tools_mod._parse_outcome_from_text('outcome: deferred') == 'deferred'
assert tools_mod._parse_outcome_from_text('outcome: failed') == 'failed'
assert tools_mod._parse_outcome_from_text('outcome: needs_approval') == 'needs_approval'
assert tools_mod._parse_outcome_from_text('outcome: skipped') == 'skipped'
assert tools_mod._parse_outcome_from_text('outcome_status=done') == 'done'
assert tools_mod._parse_outcome_from_text('outcome_status=deferred') == 'deferred'
assert tools_mod._parse_outcome_from_text('outcome_status: deferred') == 'deferred'
assert tools_mod._parse_outcome_from_text('random text') is None

# Candidates detection with selection.md
os.environ['HERMES_HOME'] = tempfile.mkdtemp(prefix='aw-test-')
os.environ['HERMES_PROFILE'] = 'test-profile'
tmpdir = tempfile.mkdtemp(prefix='aw-test-')
sel_path = state_mod.get_selection_path(tmpdir)
assert not tools_mod._detect_candidates(tmpdir), 'empty dir should have no candidates'
with open(sel_path, 'w') as f:
    f.write('## Candidates\\n- ITEM-001: Fix bug\\n- ITEM-002: Add feature\\n')
assert tools_mod._detect_candidates(tmpdir), 'should detect candidates from selection.md'
print('OK: transition detection helpers')
" && pass || fail "Transition detection failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 15: Marker once ===\n'
run_state_test "
import os, tempfile
tmpdir = tempfile.mkdtemp(prefix='aw-test-')
locks_dir = os.path.join(tmpdir, 'locks')
os.makedirs(locks_dir, exist_ok=True)
assert state.marker_once(tmpdir, 'test_marker'), 'first call should create marker'
assert not state.marker_once(tmpdir, 'test_marker'), 'second call should not create marker'
print('OK: marker once works')
" && pass || fail "Marker once test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 16: Update window ===\n'
run_state_test "
import os, tempfile
tmpdir = tempfile.mkdtemp(prefix='aw-test-')
win_path = os.path.join(tmpdir, 'window.json')
win = state.make_initial_window('AW-001', 3600, None, None, '/tmp/repo')
state.atomic_write_json(win_path, win)
updated = state.update_window(win_path, {'phase': 'candidate_generation', 'continuation': 'continue_now'})
assert updated['phase'] == 'candidate_generation'
assert updated['window_id'] == 'AW-001'
# Dotted key update
updated2 = state.update_window(win_path, {'selected_item': 'ITEM-001'})
assert updated2['selected_item'] == 'ITEM-001'
print('OK: update window works')
" && pass || fail "Update window test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 17: Atomic active-window acquire ===\n'
run_state_test "
import os, tempfile
os.environ['HERMES_HOME'] = tempfile.mkdtemp(prefix='aw-test-')
os.environ['HERMES_PROFILE'] = 'test-profile'

# 1. First acquire should succeed
assert state.try_acquire_active_window('AW-TEST-001'), 'first acquire should succeed'

# 2. Second acquire while lock+json exist should fail
assert not state.try_acquire_active_window('AW-TEST-002'), 'second acquire should fail while active'

# 3. Clear and retry
state.clear_active_window()
assert state.try_acquire_active_window('AW-TEST-003'), 'acquire after clear should succeed'

# 4. Verify active_window.json was written
active = state.get_active_window()
assert active is not None
assert active['window_id'] == 'AW-TEST-003'

# 5. json-only refusal: create active_window.json without lock, then try acquiring
state.clear_active_window()
state.set_active_window('AW-TEST-004')
# Manually remove the lock file to simulate older state
lock_path = os.path.join(state.get_aw_base(), 'active_window.lock')
if os.path.isfile(lock_path):
    os.unlink(lock_path)
# Now try_acquire should still refuse because json exists
assert not state.try_acquire_active_window('AW-TEST-005'), 'should refuse when json exists even without lock'

print('OK: atomic active-window acquire works (lock + json-only refusal)')
" && pass || fail "Atomic active-window acquire test failed"

# ════════════════════════════════════════════════════════════════
# ════════════════════════════════════════════════════════════════
printf '=== Test 18: Repo resolution ordering ===\n'
run_tools_test "
import os, tempfile

# Create a temp git repo to serve as the 'real' target
target_repo = tempfile.mkdtemp(prefix='aw-repo-resolve-')
os.system(f'git -C \"{target_repo}\" init -q')

# Create a different temp git repo to serve as cwd fake
fake_repo = tempfile.mkdtemp(prefix='aw-fake-cwd-')
os.system(f'git -C \"{fake_repo}\" init -q')

# Create a temp profile dir with docs/tools.md pointing at target_repo
# Use chr(96) for backtick to avoid shell command substitution
bt = chr(96)
profile_dir = tempfile.mkdtemp(prefix='aw-profile-')
os.makedirs(os.path.join(profile_dir, 'docs'), exist_ok=True)
with open(os.path.join(profile_dir, 'docs', 'tools.md'), 'w') as f:
    f.write(f'- Repository: {bt}{target_repo}{bt}\\n')
    f.write('- Workspace / monorepo subdir (if relevant): TODO\\n')

os.environ['HERMES_PROFILE_DIR'] = profile_dir
os.environ['JUNIE_REPO'] = ''

# Test 1: no JUNIE_REPO, tools.md should resolve
orig_cwd = os.getcwd()
os.chdir(fake_repo)
try:
    result = tools_mod._resolve_repo()
    assert result == os.path.abspath(target_repo), f'Expected target_repo from tools.md, got {result}'
finally:
    os.chdir(orig_cwd)
print('OK: repo resolves from tools.md when cwd is different git repo')

# Test 2: JUNIE_REPO takes priority over both tools.md and cwd
os.environ['JUNIE_REPO'] = fake_repo
try:
    result2 = tools_mod._resolve_repo()
    assert result2 == os.path.abspath(fake_repo), f'Expected fake_repo from JUNIE_REPO, got {result2}'
finally:
    del os.environ['JUNIE_REPO']
print('OK: JUNIE_REPO takes priority over tools.md')

# Test 3: no JUNIE_REPO, no tools.md Repository -> falls back to cwd git root
profile_dir2 = tempfile.mkdtemp(prefix='aw-profile2-')
os.makedirs(os.path.join(profile_dir2, 'docs'), exist_ok=True)
with open(os.path.join(profile_dir2, 'docs', 'tools.md'), 'w') as f:
    f.write('# tools.md\\n- Workspace / monorepo subdir: TODO\\n')
os.environ['HERMES_PROFILE_DIR'] = profile_dir2
orig_cwd = os.getcwd()
os.chdir(fake_repo)
try:
    result3 = tools_mod._resolve_repo()
    assert result3 == os.path.abspath(fake_repo), f'Expected fake_repo from cwd, got {result3}'
finally:
    os.chdir(orig_cwd)
print('OK: falls back to cwd git root when tools.md has no Repository line')

# Cleanup
import shutil
shutil.rmtree(target_repo, ignore_errors=True)
shutil.rmtree(fake_repo, ignore_errors=True)
shutil.rmtree(profile_dir, ignore_errors=True)
shutil.rmtree(profile_dir2, ignore_errors=True)
del os.environ['HERMES_PROFILE_DIR']
" && pass || fail "Repo resolution ordering test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 19: Backlog path resolves under temp HERMES_HOME (not .openclaw) ===\n'
run_backlog_test "
import os, tempfile
os.environ['HERMES_HOME'] = tempfile.mkdtemp(prefix='aw-test-')
os.environ['HERMES_PROFILE'] = 'test-profile'
root = backlog.get_backlog_root()
assert '.openclaw' not in root, f'backlog root must not reference .openclaw: {root}'
assert root.endswith('test-profile/junie-live/state/backlog'), f'unexpected backlog root: {root}'
items_dir = backlog.get_items_dir()
assert items_dir.endswith('/items'), f'unexpected items dir: {items_dir}'
archive_dir = backlog.get_archive_dir()
assert archive_dir.endswith('/archive'), f'unexpected archive dir: {archive_dir}'
events_path = backlog.get_events_path()
assert events_path.endswith('/events.jsonl'), f'unexpected events path: {events_path}'
print(f'OK: backlog path resolves correctly: {root}')
" && pass || fail "Backlog path resolution failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 20: Ensure backlog dirs creates structure ===\n'
run_backlog_test "
import os, tempfile
os.environ['HERMES_HOME'] = tempfile.mkdtemp(prefix='aw-test-')
os.environ['HERMES_PROFILE'] = 'test-profile'
backlog.ensure_backlog_dirs()
assert os.path.isdir(backlog.get_items_dir()), 'items dir should exist'
assert os.path.isdir(backlog.get_archive_dir()), 'archive dir should exist'
print('OK: backlog directories created')
" && pass || fail "Ensure backlog dirs failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 21: Generate item id ===\n'
run_backlog_test "
import os, tempfile
os.environ['HERMES_HOME'] = tempfile.mkdtemp(prefix='aw-test-')
os.environ['HERMES_PROFILE'] = 'test-profile'
backlog.ensure_backlog_dirs()
item_id = backlog.generate_item_id()
assert item_id.startswith('BL-'), f'item id should start with BL-, got {item_id}'
assert '-001' in item_id or item_id.endswith('-001'), f'first item should end with -001, got {item_id}'
print(f'OK: generated item id: {item_id}')
" && pass || fail "Generate item id failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 22: Write and read backlog item ===\n'
run_backlog_test "
import os, tempfile
os.environ['HERMES_HOME'] = tempfile.mkdtemp(prefix='aw-test-')
os.environ['HERMES_PROFILE'] = 'test-profile'
backlog.ensure_backlog_dirs()

fm = {
    'id': 'BL-20260601-001',
    'kind': 'feature',
    'status': 'candidate',
    'title': 'Test item',
    'source': 'test',
    'problem': 'Something is wrong',
    'desired_outcome': 'Something works',
    'approval_required': False,
    'scores': {'strategy_fit': 8, 'effort': 3},
}
body = 'Optional body text'
item_path = os.path.join(backlog.get_items_dir(), 'BL-20260601-001.md')
backlog.write_item(item_path, fm, body)
assert os.path.isfile(item_path), 'item file should exist'

read_fm, read_body = backlog.read_item(item_path)
assert read_fm['id'] == 'BL-20260601-001', f'id mismatch: {read_fm[\"id\"]}'
assert read_fm['status'] == 'candidate'
assert read_fm['approval_required'] == False
assert read_fm['scores']['strategy_fit'] == 8
assert read_body == body, f'body mismatch: {read_body}'
print('OK: write/read backlog item works')
" && pass || fail "Write/read backlog item failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 23: List and filter backlog items ===\n'
run_backlog_test "
import os, tempfile
os.environ['HERMES_HOME'] = tempfile.mkdtemp(prefix='aw-test-')
os.environ['HERMES_PROFILE'] = 'test-profile'
backlog.ensure_backlog_dirs()

# Create two items
fm1 = {'id': 'BL-001', 'kind': 'feature', 'status': 'candidate', 'title': 'Item 1', 'source': 'test'}
fm2 = {'id': 'BL-002', 'kind': 'bug', 'status': 'ready', 'title': 'Item 2', 'source': 'test'}
fm3 = {'id': 'BL-003', 'kind': 'chore', 'status': 'done', 'title': 'Item 3', 'source': 'test'}
backlog.write_item(os.path.join(backlog.get_items_dir(), 'BL-001.md'), fm1)
backlog.write_item(os.path.join(backlog.get_items_dir(), 'BL-002.md'), fm2)
backlog.write_item(os.path.join(backlog.get_items_dir(), 'BL-003.md'), fm3)

all_items = backlog.list_items()
assert len(all_items) == 3, f'expected 3 items, got {len(all_items)}'

filtered = backlog.filter_by_status(all_items, {'candidate', 'ready'})
assert len(filtered) == 2, f'expected 2 filtered items, got {len(filtered)}'

active = backlog.list_active_items()
assert len(active) == 2, f'expected 2 active items, got {len(active)}'

candidates = backlog.get_candidate_paths()
assert len(candidates) == 2, f'expected 2 candidate paths, got {len(candidates)}'
print('OK: list/filter backlog items works')
" && pass || fail "List/filter backlog items failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 24: Update item status ===\n'
run_backlog_test "
import os, tempfile
os.environ['HERMES_HOME'] = tempfile.mkdtemp(prefix='aw-test-')
os.environ['HERMES_PROFILE'] = 'test-profile'
backlog.ensure_backlog_dirs()

fm = {'id': 'BL-001', 'kind': 'feature', 'status': 'candidate', 'title': 'Test', 'source': 'test'}
item_path = os.path.join(backlog.get_items_dir(), 'BL-001.md')
backlog.write_item(item_path, fm)

backlog.update_item_status(item_path, 'in_progress', 'Starting work')
read_fm, _ = backlog.read_item(item_path)
assert read_fm['status'] == 'in_progress', f'status should be in_progress, got {read_fm[\"status\"]}'
assert 'history' in read_fm, 'should have history'
assert 'Starting work' in read_fm['history']
print('OK: update item status works')
" && pass || fail "Update item status failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 25: Candidate detection from backlog items (no selection.md) ===\n'
run_tools_test "
import os, tempfile
os.environ['HERMES_HOME'] = tempfile.mkdtemp(prefix='aw-test-')
os.environ['HERMES_PROFILE'] = 'test-profile'

# Create a backlog item with status candidate
backlog_mod.ensure_backlog_dirs()
fm = {'id': 'BL-001', 'kind': 'feature', 'status': 'candidate', 'title': 'Backlog candidate', 'source': 'test'}
backlog_mod.write_item(os.path.join(backlog_mod.get_items_dir(), 'BL-001.md'), fm)

# Empty window dir with no selection.md
tmpdir = tempfile.mkdtemp(prefix='aw-test-')
# Candidate detection should find the backlog item
assert tools_mod._detect_candidates(tmpdir), 'should detect candidates from backlog even without selection.md'
print('OK: candidate detection finds backlog items without selection.md')
" && pass || fail "Candidate detection from backlog failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 26: Prompt mentions Hermes backlog path as source of truth ===\n'
run_prompts_test "
import os, tempfile
window = {
    'window_id': 'AW-20260601-001',
    'end_at': 9999999999,
    'prompt': 'test',
    'repo': '/tmp/test-repo',
}
tmpdir = tempfile.mkdtemp(prefix='aw-test-')
result = prompts_mod.build_step_prompt(window, tmpdir, 'snapshot_preflight')
content = open(result['prompt_path']).read()
assert 'Hermes backlog' in content, 'prompt should mention Hermes backlog'
assert 'backlog/items' in content.lower() or 'items:' in content, 'prompt should mention backlog items path'
# Prohibition text may mention .openclaw as forbidden; that is intentional.
print('OK: prompts mention Hermes backlog path as source of truth')
" && pass || fail "Prompt backlog path test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 27: Backlog frontmatter roundtrip (booleans, nested dicts, multiline) ===\n'
run_backlog_test "
import os, tempfile
os.environ['HERMES_HOME'] = tempfile.mkdtemp(prefix='aw-test-')
os.environ['HERMES_PROFILE'] = 'test-profile'
backlog.ensure_backlog_dirs()

fm = {
    'id': 'BL-002',
    'kind': 'refactor',
    'status': 'validated',
    'title': 'Complex item',
    'source': 'owner',
    'approval_required': True,
    'scores': {'strategy_fit': 9, 'effort': 5, 'risk': 2},
}
item_path = os.path.join(backlog.get_items_dir(), 'BL-002.md')
backlog.write_item(item_path, fm)
read_fm, _ = backlog.read_item(item_path)
assert read_fm['approval_required'] == True, f'bool: {read_fm[\"approval_required\"]}'
assert read_fm['scores']['strategy_fit'] == 9
assert read_fm['scores']['risk'] == 2
print('OK: complex frontmatter roundtrips correctly')
" && pass || fail "Complex frontmatter roundtrip failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 28: Backlog list fields roundtrip ===\n'
run_backlog_test "
import os, tempfile
os.environ['HERMES_HOME'] = tempfile.mkdtemp(prefix='aw-test-')
os.environ['HERMES_PROFILE'] = 'test-profile'
backlog.ensure_backlog_dirs()

fm = {
    'id': 'BL-003',
    'kind': 'feature',
    'status': 'validated',
    'title': 'List roundtrip',
    'source': 'test',
    'acceptance': ['Criterion 1', 'Criterion 2'],
    'verification': ['Verify A', 'Verify B', 'Verify C'],
}
item_path = os.path.join(backlog.get_items_dir(), 'BL-003.md')
backlog.write_item(item_path, fm)
read_fm, _ = backlog.read_item(item_path)
assert isinstance(read_fm['acceptance'], list), f'acceptance should be list, got {type(read_fm[\"acceptance\"]).__name__}: {read_fm[\"acceptance\"]}'
assert read_fm['acceptance'] == ['Criterion 1', 'Criterion 2'], f'acceptance mismatch: {read_fm[\"acceptance\"]}'
assert isinstance(read_fm['verification'], list), f'verification should be list, got {type(read_fm[\"verification\"]).__name__}: {read_fm[\"verification\"]}'
assert read_fm['verification'] == ['Verify A', 'Verify B', 'Verify C'], f'verification mismatch: {read_fm[\"verification\"]}'
print(f'OK: list fields roundtrip as lists: acceptance={read_fm[\"acceptance\"]} verification={read_fm[\"verification\"]}')
" && pass || fail "List fields roundtrip test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 29: aw-runner.sh has no --resume (regression) ===\n'
if grep -qF -- '--resume' "$PLUGIN_DIR/scripts/aw-runner.sh"; then
  fail "aw-runner.sh contains --resume (must start fresh sessions per step)"
else
  pass
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 30: aw-runner.sh has no AW_SESSION_ID (regression) ===\n'
if grep -qF 'AW_SESSION_ID' "$PLUGIN_DIR/scripts/aw-runner.sh"; then
  fail "aw-runner.sh references AW_SESSION_ID (should not persist/resume sessions)"
else
  pass
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 31: tools.py has no bootstrap/resume patterns (regression) ===\n'
if grep -qE '_bootstrap_aw_session|aw_session_bootstrapped' "$PLUGIN_DIR/tools.py"; then
  fail "tools.py contains _bootstrap_aw_session or aw_session_bootstrapped"
else
  pass
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 32: tools.py aw_session_id is None-only (backward-compatible) ===\n'
if grep -n 'aw_session_id' "$PLUGIN_DIR/tools.py" | grep -qv '": None'; then
  fail "tools.py has non-None aw_session_id (should only appear as backward-compatible None)"
else
  pass
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 33: aw-runner.sh has AW_ENABLE_DEBUG and AW_DEBUG_DELIVERY_TARGET gating ===\n'
if grep -qF 'AW_ENABLE_DEBUG' "$PLUGIN_DIR/scripts/aw-runner.sh"; then
  pass
else
  fail "aw-runner.sh missing AW_ENABLE_DEBUG gating"
fi
if grep -qF 'AW_DEBUG_DELIVERY_TARGET' "$PLUGIN_DIR/scripts/aw-runner.sh"; then
  pass
else
  fail "aw-runner.sh missing AW_DEBUG_DELIVERY_TARGET"
fi
if grep -qF 'Use send_message' "$PLUGIN_DIR/scripts/aw-runner.sh"; then
  pass
else
  fail "aw-runner.sh missing send_message call for debug"
fi
if grep -qF -- '-t messaging' "$PLUGIN_DIR/scripts/aw-runner.sh"; then
  pass
else
  fail "aw-runner.sh debug message hermes call missing -t messaging toolset"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 34: tools.py _resolve_debug_delivery_target and return payload ===\n'
if grep -qF '_resolve_debug_delivery_target' "$PLUGIN_DIR/tools.py"; then
  pass
else
  fail "tools.py missing _resolve_debug_delivery_target helper"
fi
# Regression: start return JSON must include enable_debug_messages
if grep -A10 'return json.dumps({' "$PLUGIN_DIR/tools.py" | grep -qF 'enable_debug_messages'; then
  pass
else
  fail "tools.py start return JSON missing enable_debug_messages"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 35: hot-swap script stages safely and excludes generated artifacts ===\n'
tmp_root="$(mktemp -d)"
cleanup_hot_swap_test() { rm -rf -- "$tmp_root"; }
trap cleanup_hot_swap_test EXIT
test_repo="$tmp_root/repo"
test_profile="$tmp_root/hermes-home/profiles/junie-live"
test_seed="$test_repo/hermes/distribution/plugins/autonomous-work"
mkdir -p "$test_seed/__pycache__" "$test_profile/plugins/autonomous-work" "$test_profile/junie-live/state/backlog/items"
printf 'name: autonomous-work\n' > "$test_seed/plugin.yaml"
printf 'print("new")\n' > "$test_seed/tools.py"
printf 'cached' > "$test_seed/__pycache__/tools.cpython-312.pyc"
printf 'cached' > "$test_seed/tools.pyc"
printf 'old' > "$test_profile/plugins/autonomous-work/old.py"
printf 'state' > "$test_profile/junie-live/state/backlog/items/keep.md"

if "$HOT_SWAP_SCRIPT" --repo "$test_repo" --profile-dir "$test_profile" --dry-run >/dev/null; then
  pass
else
  fail "hot-swap dry-run failed"
fi

if HERMES_HOME="$test_profile" "$HOT_SWAP_SCRIPT" --repo "$test_repo" --dry-run >/dev/null; then
  pass
else
  fail "hot-swap dry-run failed when HERMES_HOME points at active profile dir"
fi

if "$HOT_SWAP_SCRIPT" --repo "$test_repo" --profile-dir "$test_profile" >/dev/null; then
  if [[ -f "$test_profile/plugins/autonomous-work/plugin.yaml" ]] && \
     [[ -f "$test_profile/plugins/autonomous-work/tools.py" ]] && \
     [[ ! -e "$test_profile/plugins/autonomous-work/__pycache__" ]] && \
     [[ ! -e "$test_profile/plugins/autonomous-work/tools.pyc" ]] && \
     [[ -f "$test_profile/junie-live/state/backlog/items/keep.md" ]] && \
     compgen -G "$test_profile/backups/autonomous-work-hot-swap/autonomous-work-*" >/dev/null; then
    pass
  else
    fail "hot-swap did not install expected files, exclude caches, preserve state, or create backup"
  fi
else
  fail "hot-swap execution failed"
fi

printf '\n'
printf '=== Results ===\n'
printf 'Passed: %d, Failed: %d\n' "$pass_count" "$fail_count"

if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi

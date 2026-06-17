#!/usr/bin/env bash
# Test the senior-runner synchronous Senior Dev coding runner:
# schema, input validation, job_id derivation, prompt discipline, a full
# synchronous run against a fake opencode, and VERDICT normalization.
# Does NOT call the hermes CLI or modify live profiles/Kanban.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_DIR="$ROOT/distribution/plugins/senior-runner"

fail_count=0
pass_count=0

pass() { pass_count=$((pass_count + 1)); }
fail() { printf '  FAIL: %s\n' "$*" >&2; fail_count=$((fail_count + 1)); }

# Load the senior-runner package modules under a unique 'sr_plugin' package.
load_plugin() {
  python3 -c "
import importlib.util, sys, types
plugin_dir = '$PLUGIN_DIR'
pkg = types.ModuleType('sr_plugin'); pkg.__path__ = [plugin_dir]; sys.modules['sr_plugin'] = pkg
for name in ['state', 'runner', 'tools']:
    spec = importlib.util.spec_from_file_location('sr_plugin.' + name, plugin_dir + '/' + name + '.py')
    m = importlib.util.module_from_spec(spec)
    sys.modules['sr_plugin.' + name] = m
    spec.loader.exec_module(m)
state = sys.modules['sr_plugin.state']
runner = sys.modules['sr_plugin.runner']
tools = sys.modules['sr_plugin.tools']
for mod in (state, runner, tools):
    for n in dir(mod):
        if not n.startswith('__'):
            globals()[n] = getattr(mod, n)
$1
" 2>&1
}

# ════════════════════════════════════════════════════════════════
printf '=== Test 1: Schema has required fields ===\n'
load_plugin '
props = SENIOR_RUN_CODING_TASK_SCHEMA["parameters"]["properties"]
required = SENIOR_RUN_CODING_TASK_SCHEMA["parameters"]["required"]
assert SENIOR_RUN_CODING_TASK_SCHEMA["name"] == "senior_run_coding_task"
for f in ("task_id", "repo", "request", "context", "job_id"):
    assert f in props, f
assert set(required) == {"task_id", "repo", "request"}, required
assert SENIOR_RUN_CODING_TASK_SCHEMA["parameters"].get("additionalProperties") is False
print("OK: %d properties, required=%s" % (len(props), sorted(required)))
' && pass || fail "Schema test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 2: Input validation ===\n'
load_plugin '
import json
# missing task_id
r = json.loads(handle_senior_run_coding_task({"repo": "/tmp", "request": "x"}))
assert r["ok"] is False and "task_id" in r["error"], r
# relative repo
r = json.loads(handle_senior_run_coding_task({"task_id": "t_1", "repo": "rel", "request": "x"}))
assert r["ok"] is False and "absolute" in r["error"], r
# nonexistent repo
r = json.loads(handle_senior_run_coding_task({"task_id": "t_1", "repo": "/nope/54321_x", "request": "x"}))
assert r["ok"] is False, r
# missing request
r = json.loads(handle_senior_run_coding_task({"task_id": "t_1", "repo": "/tmp", "request": "  "}))
assert r["ok"] is False and "request" in r["error"], r
# bad job_id
r = json.loads(handle_senior_run_coding_task({"task_id": "t_1", "repo": "/tmp", "request": "x", "job_id": "../escape"}))
assert r["ok"] is False and "job_id" in r["error"], r
print("OK: all input validations pass")
' && pass || fail "Input validation test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 3: job_id derivation is path-safe ===\n'
load_plugin '
import os
jid = _derive_job_id("t_abc/../x")
# Path separators must be stripped so the id is safe as a directory name.
assert "/" not in jid, jid
assert os.sep not in jid, jid
assert jid.startswith("senior-"), jid
# And the derived id must satisfy the tool-side safe-id pattern.
assert _SAFE_JOB_ID_RE.match(jid), jid
print("OK: derived job_id=%s" % jid)
' && pass || fail "job_id derivation test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 4: prompt includes the VERDICT discipline block ===\n'
load_plugin '
p = _build_prompt("do the thing", context="extra ctx")
assert "do the thing" in p
assert "extra ctx" in p
assert "VERDICT: pr-ready|needs-input|failed" in p
assert "USER_MESSAGE:" in p
print("OK: prompt carries VERDICT discipline")
' && pass || fail "prompt discipline test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 5: full synchronous run writes artifacts + verdict (pr-ready) ===\n'
load_plugin '
import json, os, tempfile, stat

tmp = tempfile.mkdtemp(prefix="sr-")
repo = os.path.join(tmp, "repo"); os.makedirs(repo)
fake = os.path.join(tmp, "opencode")
with open(fake, "w") as f:
    f.write(
        "#!/usr/bin/env bash\n"
        "echo '"'"'{\"sessionID\":\"ses_ABC123\",\"type\":\"start\"}'"'"'\n"
        "echo '"'"'{\"type\":\"text\",\"part\":{\"type\":\"text\",\"text\":\"Did work.\\nVERDICT: pr-ready\\nSUMMARY: Implemented X\\nUSER_MESSAGE: All done.\\nPR_URL: https://example.com/pr/9\"}}'"'"'\n"
        "exit 0\n"
    )
os.chmod(fake, 0o755)

os.environ["SENIOR_RUNNER_BASE"] = os.path.join(tmp, "senior")
os.environ["OPENCODE_BIN"] = fake

res = json.loads(handle_senior_run_coding_task({
    "task_id": "t_run1", "repo": repo, "request": "do something",
}))
assert res["ok"] is True, res
assert res["exit_code"] == 0, res
assert res["verdict"] == "pr-ready", res
for key in ("run_dir", "status_path", "result_path"):
    assert os.path.isfile(res[key]) or os.path.isdir(res[key]), (key, res[key])
for artifact in ("spec.json", "status.json", "events.jsonl", "result.md", "opencode.stdout.log"):
    assert os.path.isfile(os.path.join(res["run_dir"], artifact)), artifact
result_md = open(res["result_path"]).read()
assert "VERDICT: pr-ready" in result_md, result_md
assert "https://example.com/pr/9" in result_md, result_md
status = json.load(open(res["status_path"]))
assert status["worker_state"] == "completed", status
assert status["opencode"]["session_id"] == "ses_ABC123", status
print("OK: artifacts written, verdict=pr-ready, session captured")
' && pass || fail "synchronous pr-ready run test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 6: failed exit yields failed verdict ===\n'
load_plugin '
import json, os, tempfile

tmp = tempfile.mkdtemp(prefix="sr-")
repo = os.path.join(tmp, "repo"); os.makedirs(repo)
fake = os.path.join(tmp, "opencode")
with open(fake, "w") as f:
    f.write("#!/usr/bin/env bash\necho boom >&2\nexit 3\n")
os.chmod(fake, 0o755)

os.environ["SENIOR_RUNNER_BASE"] = os.path.join(tmp, "senior")
os.environ["OPENCODE_BIN"] = fake

res = json.loads(handle_senior_run_coding_task({
    "task_id": "t_run2", "repo": repo, "request": "break it",
}))
assert res["ok"] is False, res
assert res["exit_code"] == 3, res
assert res["verdict"] == "failed", res
print("OK: failed run mapped to verdict=failed exit_code=3")
' && pass || fail "failed run test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 7: runner never imports kanban_db (no Kanban mutation) ===\n'
if grep -q "kanban" "$PLUGIN_DIR/runner.py" "$PLUGIN_DIR/tools.py" "$PLUGIN_DIR/state.py"; then
  fail "senior-runner references kanban; it must not mutate the board"
else
  printf '  OK: senior-runner does not reference kanban\n'
  pass
fi

# ════════════════════════════════════════════════════════════════
printf '\n'
printf '=== Results ===\n'
printf 'Passed: %d, Failed: %d\n' "$pass_count" "$fail_count"

if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi

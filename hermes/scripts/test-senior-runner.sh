#!/usr/bin/env bash
# Test the senior-runner synchronous Senior Dev coding runner:
# schema, input validation, job_id derivation, prompt assembly, and a full
# synchronous run against a fake junie CLI (artifacts + exit code + runner
# state). The runner requires a structured Senior Dev final verdict but still
# leaves the Kanban action to the senior-dev worker. Does NOT call the hermes
# CLI or modify live profiles/Kanban.
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
for f in ("task_id", "repo", "user_outcome", "acceptance_criteria", "distilled_context", "context", "job_id"):
    assert f in props, f
assert set(required) == {"task_id", "repo", "user_outcome", "acceptance_criteria"}, required
assert SENIOR_RUN_CODING_TASK_SCHEMA["parameters"].get("additionalProperties") is False
print("OK: %d properties, required=%s" % (len(props), sorted(required)))
' && pass || fail "Schema test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 2: Input validation ===\n'
load_plugin '
import json
# missing task_id
r = json.loads(handle_senior_run_coding_task({"repo": "/tmp", "user_outcome": "x", "acceptance_criteria": "done"}))
assert r["ok"] is False and "task_id" in r["error"], r
# relative repo
r = json.loads(handle_senior_run_coding_task({"task_id": "t_1", "repo": "rel", "user_outcome": "x", "acceptance_criteria": "done"}))
assert r["ok"] is False and "absolute" in r["error"], r
# nonexistent repo
r = json.loads(handle_senior_run_coding_task({"task_id": "t_1", "repo": "/nope/54321_x", "user_outcome": "x", "acceptance_criteria": "done"}))
assert r["ok"] is False, r
# missing user_outcome
r = json.loads(handle_senior_run_coding_task({"task_id": "t_1", "repo": "/tmp", "user_outcome": "  ", "acceptance_criteria": "done"}))
assert r["ok"] is False and "user_outcome" in r["error"], r
# missing acceptance_criteria
r = json.loads(handle_senior_run_coding_task({"task_id": "t_1", "repo": "/tmp", "user_outcome": "x", "acceptance_criteria": "  "}))
assert r["ok"] is False and "acceptance_criteria" in r["error"], r
# bad job_id
r = json.loads(handle_senior_run_coding_task({"task_id": "t_1", "repo": "/tmp", "user_outcome": "x", "acceptance_criteria": "done", "job_id": "../escape"}))
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
printf '=== Test 4: prompt carries request + context + verdict protocol ===\n'
load_plugin '
p = _build_prompt("do the thing", context="extra ctx")
# The runner must append the Senior Dev contract so the headless worker returns
# a machine-readable final state without Team Lead re-review.
assert p.startswith("do the thing\n\n## Additional context\n\nextra ctx"), p
assert "## Required final verdict" in p, p
assert "FINAL_VERDICT_SCHEMA" in p, p
assert "needs-input" in p and "failed" in p and "done" in p, p
assert "FINAL_VERDICT_SCHEMA" in _build_prompt("just the request")
print("OK: prompt carries request/context with required verdict protocol")
' && pass || fail "prompt assembly test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 5: full synchronous run writes artifacts + completed state ===\n'
load_plugin '
import json, os, tempfile, stat

tmp = tempfile.mkdtemp(prefix="sr-")
repo = os.path.join(tmp, "repo"); os.makedirs(repo)
fake = os.path.join(tmp, "junie")
with open(fake, "w") as f:
    f.write(
        "#!/usr/bin/env bash\n"
        "echo '"'"'{\"type\":\"text\",\"part\":{\"type\":\"text\",\"text\":\"Did work. Implemented X. PR: https://example.com/pr/9\"}}'"'"'\n"
        "exit 0\n"
    )
os.chmod(fake, 0o755)
auth = os.path.join(tmp, "junie.key")
with open(auth, "w") as f:
    f.write("test-key")

os.environ["SENIOR_RUNNER_BASE"] = os.path.join(tmp, "senior")
os.environ["JUNIE_BIN"] = fake
os.environ["JUNIE_SENIOR_AUTH_FILE"] = auth

res = json.loads(handle_senior_run_coding_task({
    "task_id": "t_run1",
    "repo": repo,
    "user_outcome": "do something",
    "acceptance_criteria": "the work is done",
}))
assert res["ok"] is True, res
assert res["exit_code"] == 0, res
assert res["worker_state"] == "completed", res
for key in ("run_dir", "status_path", "result_path"):
    assert os.path.isfile(res[key]) or os.path.isdir(res[key]), (key, res[key])
for artifact in ("spec.json", "status.json", "events.jsonl", "result.md", "junie.stdout.log"):
    assert os.path.isfile(os.path.join(res["run_dir"], artifact)), artifact
result_md = open(res["result_path"]).read()
assert "Implemented X" in result_md, result_md
assert "runner_state: completed" in result_md, result_md
assert "https://example.com/pr/9" in result_md, result_md
status = json.load(open(res["status_path"]))
assert status["worker_state"] == "completed", status
assert status["junie"]["exit_code"] == 0, status
assert status["junie"]["bin"] == fake, status
assert status["junie"]["model"] == "opus-4.8", status
print("OK: artifacts written, runner_state=completed, Junie status captured")
' && pass || fail "synchronous run test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 6: nonzero exit yields failed runner state ===\n'
load_plugin '
import json, os, tempfile

tmp = tempfile.mkdtemp(prefix="sr-")
repo = os.path.join(tmp, "repo"); os.makedirs(repo)
fake = os.path.join(tmp, "junie")
with open(fake, "w") as f:
    f.write("#!/usr/bin/env bash\necho boom >&2\nexit 3\n")
os.chmod(fake, 0o755)
auth = os.path.join(tmp, "junie.key")
with open(auth, "w") as f:
    f.write("test-key")

os.environ["SENIOR_RUNNER_BASE"] = os.path.join(tmp, "senior")
os.environ["JUNIE_BIN"] = fake
os.environ["JUNIE_SENIOR_AUTH_FILE"] = auth

res = json.loads(handle_senior_run_coding_task({
    "task_id": "t_run2",
    "repo": repo,
    "user_outcome": "break it",
    "acceptance_criteria": "failure is reported",
}))
assert res["ok"] is False, res
assert res["exit_code"] == 3, res
assert res["worker_state"] == "failed", res
status = json.load(open(res["status_path"]))
assert status["worker_state"] == "failed", status
print("OK: nonzero exit mapped to worker_state=failed exit_code=3")
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

#!/usr/bin/env bash
# Test senior_dev_task_result tool: completed and blocked paths,
# Marinator artifact reads, validation.
# Run from the hermes/ subtree root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_DIR="$ROOT/distribution/plugins/senior-task"
HERMES_AGENT="/home/Danila.Savenkov/.hermes/hermes-agent"

fail_count=0
pass_count=0

pass() { pass_count=$((pass_count + 1)); }
fail() { printf '  FAIL: %s\n' "$*" >&2; fail_count=$((fail_count + 1)); }

# Load plugin with Hermes agent on sys.path
run_with_hermes() {
  python3 -c "
import importlib.util, sys, types
spec = importlib.util.spec_from_file_location('st_plugin', '$PLUGIN_DIR/tools.py')
module = importlib.util.module_from_spec(spec)
sys.modules['st_plugin'] = module
spec.loader.exec_module(module)
for name in dir(module):
    globals()[name] = getattr(module, name)
sys.path.insert(0, '$HERMES_AGENT')
$1
" 2>&1
}

# ════════════════════════════════════════════════════════════════
printf '=== Test 1: Schema has required fields ===\n'
run_with_hermes '
props = SENIOR_DEV_TASK_RESULT_SCHEMA["parameters"]["properties"]
required = SENIOR_DEV_TASK_RESULT_SCHEMA["parameters"]["required"]
assert "task_id" in props
assert "run_dir" in props
assert "outcome" in props
assert "summary" in props
assert "pr_urls" in props
assert "expected_run_id" in props
assert "task_id" in required
assert "run_dir" in required
assert "outcome" in required
assert "summary" in required
assert len(required) == 4
outcome_enum = props["outcome"]["enum"]
assert "completed" in outcome_enum
assert "blocked" in outcome_enum
print("OK: %d properties, %d required, outcome enum: %s" % (len(props), len(required), outcome_enum))
' && pass || fail "Schema test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 2: Schema has additionalProperties False ===\n'
run_with_hermes '
assert SENIOR_DEV_TASK_RESULT_SCHEMA["parameters"].get("additionalProperties") == False
print("OK: additionalProperties is False")
' && pass || fail "Schema additionalProperties test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 3: Validation - missing task_id ===\n'
run_with_hermes '
import json
r = json.loads(handle_senior_dev_task_result({"run_dir": "/tmp", "outcome": "completed", "summary": "test"}))
assert "error" in r and "task_id" in r["error"]
print("OK: missing task_id rejected")
' && pass || fail "Missing task_id test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 4: Validation - missing run_dir ===\n'
run_with_hermes '
import json
r = json.loads(handle_senior_dev_task_result({"task_id": "t_test", "outcome": "completed", "summary": "test"}))
assert "error" in r and "run_dir" in r["error"]
print("OK: missing run_dir rejected")
' && pass || fail "Missing run_dir test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 5: Validation - invalid outcome ===\n'
run_with_hermes '
import json
r = json.loads(handle_senior_dev_task_result({"task_id": "t_test", "run_dir": "/tmp", "outcome": "invalid", "summary": "test"}))
assert "error" in r and "outcome" in r["error"]
print("OK: invalid outcome rejected")
' && pass || fail "Invalid outcome test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 6: Validation - missing summary ===\n'
run_with_hermes '
import json
r = json.loads(handle_senior_dev_task_result({"task_id": "t_test", "run_dir": "/tmp", "outcome": "completed"}))
assert "error" in r and "summary" in r["error"]
print("OK: missing summary rejected")
' && pass || fail "Missing summary test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 7: Completed path - task becomes done ===\n'
TEST_REPO="$ROOT" run_with_hermes '
import json, os, sqlite3, tempfile
from pathlib import Path

os.environ["HERMES_KANBAN_DB"] = str(Path(tempfile.mkdtemp(prefix="sdresult-")) / "kanban.db")
os.environ["HERMES_SESSION_PLATFORM"] = "telegram"
os.environ["HERMES_SESSION_CHAT_ID"] = "400847234"
os.environ["HERMES_SESSION_THREAD_ID"] = ""
os.environ["HERMES_SESSION_USER_ID"] = "user_test"

from hermes_cli import kanban_db as kb
kb.init_db(Path(os.environ["HERMES_KANBAN_DB"]))

repo = os.environ.get("TEST_REPO", os.getcwd())

create_result = json.loads(handle_create_senior_task({
    "title": "Test completed path",
    "request": "Do something",
    "repo": repo,
    "idempotency_key": "result-test-complete-001",
}))
task_id = create_result["task_id"]
assert create_result["status"] == "ready", "status: " + create_result["status"]

# Create fake Marinator run dir
run_dir = tempfile.mkdtemp(prefix="mr-")
with open(os.path.join(run_dir, "status.json"), "w") as f:
    json.dump({"opencode": {"session_id": "ses_complete_test", "exit_code": 0}}, f)
with open(os.path.join(run_dir, "result.md"), "w") as f:
    f.write("## Result\n\nPR created at https://github.com/test/pull/1\n")

# Report completed
r = json.loads(handle_senior_dev_task_result({
    "task_id": task_id,
    "run_dir": run_dir,
    "outcome": "completed",
    "summary": "Implemented feature X",
    "pr_urls": ["https://github.com/test/pull/1"],
}))
assert r["ok"] == True, "ok: " + str(r)
assert r["status"] == "done", "status: " + str(r["status"])
assert r["action"] == "completed"

# Verify in DB
conn = sqlite3.connect(os.environ["HERMES_KANBAN_DB"])
conn.row_factory = sqlite3.Row
row = conn.execute("SELECT status FROM tasks WHERE id = ?", (task_id,)).fetchone()
assert row["status"] == "done", "DB status: " + str(row["status"])
conn.close()
print("OK: task %s completed -> done, PR URLs recorded" % task_id)
' && pass || fail "Completed path test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 8: Blocked path - task becomes blocked ===\n'
TEST_REPO="$ROOT" run_with_hermes '
import json, os, sqlite3, tempfile
from pathlib import Path

os.environ["HERMES_KANBAN_DB"] = str(Path(tempfile.mkdtemp(prefix="sdresult-")) / "kanban.db")
os.environ["HERMES_SESSION_PLATFORM"] = "telegram"
os.environ["HERMES_SESSION_CHAT_ID"] = "400847234"
os.environ["HERMES_SESSION_THREAD_ID"] = ""
os.environ["HERMES_SESSION_USER_ID"] = "user_test"

from hermes_cli import kanban_db as kb
kb.init_db(Path(os.environ["HERMES_KANBAN_DB"]))

repo = os.environ.get("TEST_REPO", os.getcwd())

create_result = json.loads(handle_create_senior_task({
    "title": "Test blocked path",
    "request": "Do something that fails",
    "repo": repo,
    "idempotency_key": "result-test-blocked-001",
}))
task_id = create_result["task_id"]
assert create_result["status"] == "ready"

# Create fake Marinator run dir
run_dir = tempfile.mkdtemp(prefix="mr-")
with open(os.path.join(run_dir, "status.json"), "w") as f:
    json.dump({"opencode": {"session_id": "ses_blocked_test", "exit_code": 1}}, f)
with open(os.path.join(run_dir, "result.md"), "w") as f:
    f.write("## Result\n\nFailed: missing API key.\n")

# Report blocked
r = json.loads(handle_senior_dev_task_result({
    "task_id": task_id,
    "run_dir": run_dir,
    "outcome": "blocked",
    "summary": "Missing API key for external service",
}))
assert r["ok"] == True
assert r["status"] == "blocked"
assert r["action"] == "blocked"

# Verify in DB
conn = sqlite3.connect(os.environ["HERMES_KANBAN_DB"])
conn.row_factory = sqlite3.Row
row = conn.execute("SELECT status FROM tasks WHERE id = ?", (task_id,)).fetchone()
assert row["status"] == "blocked", "DB status: " + str(row["status"])
conn.close()
print("OK: task %s blocked" % task_id)
' && pass || fail "Blocked path test failed"

# ════════════════════════════════════════════════════════════════
printf '\n'
printf '=== Results ===\n'
printf 'Passed: %d, Failed: %d\n' "$pass_count" "$fail_count"

if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi

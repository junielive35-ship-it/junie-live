#!/usr/bin/env bash
# Test Senior Dev Kanban task helper plugin: schema, task creation,
# subscription, idempotency, origin metadata.
# Run from the hermes/ subtree root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_DIR="$ROOT/distribution/plugins/senior-task"
HERMES_AGENT="/home/Danila.Savenkov/.hermes/hermes-agent"

fail_count=0
pass_count=0

pass() { pass_count=$((pass_count + 1)); }
fail() { printf '  FAIL: %s\n' "$*" >&2; fail_count=$((fail_count + 1)); }

# Load the plugin tools module under a unique name ('st_plugin') to avoid
# shadowing the Hermes agent's "tools" package.
load_plugin() {
  python3 -c "
import importlib.util, sys, types
spec = importlib.util.spec_from_file_location('st_plugin', '$PLUGIN_DIR/tools.py')
module = importlib.util.module_from_spec(spec)
sys.modules['st_plugin'] = module
spec.loader.exec_module(module)
for name in dir(module):
    globals()[name] = getattr(module, name)
$1
" 2>&1
}

# Same as load_plugin, but also adds the Hermes agent to sys.path so
# kanban_db and its transitive dependencies are importable.
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
load_plugin '
props = CREATE_SENIOR_TASK_SCHEMA["parameters"]["properties"]
required = CREATE_SENIOR_TASK_SCHEMA["parameters"]["required"]
assert "title" in props
assert "request" in props
assert "repo" in props
assert "idempotency_key" in props
assert "priority" in props
assert "title" in required
assert "request" in required
assert "repo" in required
assert len(required) == 3
print("OK: %d properties, %d required" % (len(props), len(required)))
' && pass || fail "Schema test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 2: Schema has additionalProperties False ===\n'
load_plugin '
assert CREATE_SENIOR_TASK_SCHEMA["parameters"].get("additionalProperties") == False
print("OK: additionalProperties is False")
' && pass || fail "Schema additionalProperties test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 3: _session_env falls back to os.environ ===\n'
load_plugin '
import os
os.environ["TEST_SENIOR_VAR"] = "test_value"
val = _session_env("TEST_SENIOR_VAR", "fallback")
assert val == "test_value"
val2 = _session_env("TEST_NONEXISTENT_VAR", "fallback")
assert val2 == "fallback"
print("OK: _session_env works")
' && pass || fail "_session_env test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 4: _resolve_origin reads from env ===\n'
load_plugin '
import os
os.environ["HERMES_SESSION_PLATFORM"] = "telegram"
os.environ["HERMES_SESSION_CHAT_ID"] = "12345"
os.environ["HERMES_SESSION_THREAD_ID"] = "678"
os.environ["HERMES_SESSION_USER_ID"] = "user_abc"
os.environ["HERMES_SESSION_KEY"] = "key_xyz"
origin = _resolve_origin()
assert origin["platform"] == "telegram"
assert origin["chat_id"] == "12345"
assert origin["thread_id"] == "678"
assert origin["user_id"] == "user_abc"
assert origin["session_key"] == "key_xyz"
print("OK: all origin fields resolved")
' && pass || fail "_resolve_origin test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 5: _build_task_body embeds metadata ===\n'
load_plugin '
import json
origin = {"platform": "telegram", "chat_id": "123", "thread_id": "", "user_id": "u1", "session_key": ""}
body = _build_task_body("Fix the login bug", "/home/repo", origin)
assert "Fix the login bug" in body
assert "senior_dev_code_task" in body
assert "/home/repo" in body
assert "_junie_metadata:" in body
meta_prefix = "_junie_metadata: "
idx = body.index(meta_prefix)
meta_json = body[idx + len(meta_prefix):]
meta = json.loads(meta_json.strip())
assert meta["junie_task_type"] == "senior_dev_code_task"
assert meta["repo"] == "/home/repo"
assert meta["source"]["platform"] == "telegram"
print("OK: metadata embedded correctly")
' && pass || fail "_build_task_body test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 6: handle_create_senior_task validates inputs ===\n'
load_plugin '
import json
r = json.loads(handle_create_senior_task({"request": "test", "repo": "/tmp"}))
assert "error" in r and "title" in r["error"]

r = json.loads(handle_create_senior_task({"title": "test", "repo": "/tmp"}))
assert "error" in r

r = json.loads(handle_create_senior_task({"title": "test", "request": "test", "repo": "relative/path"}))
assert "error" in r

r = json.loads(handle_create_senior_task({"title": "test", "request": "test", "repo": "/nonexistent/path/54321_test_nope"}))
assert "error" in r
print("OK: all input validations pass")
' && pass || fail "Input validation test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 7: Full create task + subscription on isolated DB ===\n'
TEST_REPO="$ROOT" run_with_hermes '
import json, os, sqlite3, tempfile
from pathlib import Path

os.environ["HERMES_KANBAN_DB"] = str(Path(tempfile.mkdtemp(prefix="st-")) / "kanban.db")
os.environ["HERMES_SESSION_PLATFORM"] = "telegram"
os.environ["HERMES_SESSION_CHAT_ID"] = "400847234"
os.environ["HERMES_SESSION_THREAD_ID"] = ""
os.environ["HERMES_SESSION_USER_ID"] = "user_test"
os.environ.pop("HERMES_PROFILE", None)
os.environ["HERMES_HOME"] = str(Path(tempfile.mkdtemp(prefix="st-home-")) / ".hermes" / "profiles" / "junie-live-test")

from hermes_cli import kanban_db as kb
kb.init_db(Path(os.environ["HERMES_KANBAN_DB"]))

repo = os.environ.get("TEST_REPO", os.getcwd())
result = json.loads(handle_create_senior_task({
    "title": "Test senior task",
    "request": "Implement a test feature",
    "repo": repo,
    "idempotency_key": "test-idem-001",
    "priority": 5,
}))

assert result["task_id"].startswith("t_"), "task_id should start with t_: " + result["task_id"]
assert result["status"] == "ready"
assert result["duplicate"] == False
assert result["idempotency"] == "created"

conn2 = sqlite3.connect(os.environ["HERMES_KANBAN_DB"])
conn2.row_factory = sqlite3.Row
row = conn2.execute("SELECT * FROM tasks WHERE id = ?", (result["task_id"],)).fetchone()
assert row is not None
assert row["assignee"] == "senior-dev", "assignee: " + str(row["assignee"])
assert row["status"] == "ready", "status: " + str(row["status"])
assert row["priority"] == 5, "priority: " + str(row["priority"])
assert "Implement a test feature" in row["body"]

subs = conn2.execute("SELECT * FROM kanban_notify_subs WHERE task_id = ?", (result["task_id"],)).fetchall()
assert len(subs) == 1, "expected 1 subscription, got %d" % len(subs)
assert subs[0]["platform"] == "telegram"
assert subs[0]["chat_id"] == "400847234"
assert subs[0]["notifier_profile"] == "junie-live-test", dict(subs[0])
conn2.close()
print("OK: task + subscription created correctly with notifier_profile=%s" % subs[0]["notifier_profile"])
' && pass || fail "Full create + subscription test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 8: Subscription failure is surfaced without failing task creation ===\n'
TEST_REPO="$ROOT" run_with_hermes '
import json, os, tempfile
from pathlib import Path

os.environ["HERMES_KANBAN_DB"] = str(Path(tempfile.mkdtemp(prefix="st-")) / "kanban.db")
os.environ["HERMES_SESSION_PLATFORM"] = "telegram"
os.environ["HERMES_SESSION_CHAT_ID"] = "400847234"
os.environ["HERMES_SESSION_THREAD_ID"] = ""
os.environ["HERMES_SESSION_USER_ID"] = "user_test"
os.environ.pop("HERMES_PROFILE", None)

from hermes_cli import kanban_db as kb
kb.init_db(Path(os.environ["HERMES_KANBAN_DB"]))

def fail_add_notify_sub(*args, **kwargs):
    raise RuntimeError("subscription table unavailable")

kb.add_notify_sub = fail_add_notify_sub

repo = os.environ.get("TEST_REPO", os.getcwd())
result = json.loads(handle_create_senior_task({
    "title": "Test senior task subscription failure",
    "request": "Implement a test feature",
    "repo": repo,
}))

assert result["task_id"].startswith("t_"), result
assert result["status"] == "ready", result
assert result["duplicate"] == False, result
assert result["subscription"] is None, result
assert result["subscription_error"] == "subscription table unavailable", result
print("OK: subscription failure is visible and task is still created")
' && pass || fail "Subscription failure surfacing test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 9: Idempotency returns existing task ===\n'
TEST_REPO="$ROOT" run_with_hermes '
import json, os, sqlite3, tempfile
from pathlib import Path

os.environ["HERMES_KANBAN_DB"] = str(Path(tempfile.mkdtemp(prefix="st-")) / "kanban.db")
os.environ["HERMES_SESSION_PLATFORM"] = "telegram"
os.environ["HERMES_SESSION_CHAT_ID"] = "400847234"
os.environ["HERMES_SESSION_THREAD_ID"] = ""
os.environ["HERMES_SESSION_USER_ID"] = "user_test"
os.environ["HERMES_PROFILE"] = "junie-live-test"

from hermes_cli import kanban_db as kb
kb.init_db(Path(os.environ["HERMES_KANBAN_DB"]))

repo = os.environ.get("TEST_REPO", os.getcwd())

r1 = json.loads(handle_create_senior_task({
    "title": "Test idempotency",
    "request": "Some request",
    "repo": repo,
    "idempotency_key": "idem-test-001",
}))
task_id = r1["task_id"]
assert r1["duplicate"] == False

r2 = json.loads(handle_create_senior_task({
    "title": "Test idempotency (dup)",
    "request": "Some other request",
    "repo": repo,
    "idempotency_key": "idem-test-001",
}))
assert r2["task_id"] == task_id, "should return same task_id: %s vs %s" % (r2["task_id"], task_id)
assert r2["duplicate"] == True
assert r2["idempotency"] == "existing"

conn2 = sqlite3.connect(os.environ["HERMES_KANBAN_DB"])
conn2.row_factory = sqlite3.Row
rows = conn2.execute(
    "SELECT id, status FROM tasks WHERE idempotency_key = ? AND status NOT IN (\"done\", \"archived\")",
    ("idem-test-001",),
).fetchall()
assert len(rows) == 1, "expected 1 active task, got %d" % len(rows)
subs = conn2.execute("SELECT * FROM kanban_notify_subs WHERE task_id = ?", (task_id,)).fetchall()
assert len(subs) == 1, "expected 1 subscription, got %d" % len(subs)
assert subs[0]["notifier_profile"] == "junie-live-test", dict(subs[0])
conn2.close()
print("OK: idempotency returns existing task with notifier_profile=%s" % subs[0]["notifier_profile"])
' && pass || fail "Idempotency test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 10: check_requirements passes with Hermes CLI ===\n'
load_plugin '
import shutil
expected = shutil.which("hermes") is not None
assert check_requirements() == expected
print("OK: check_requirements returned %s" % expected)
' && pass || fail "check_requirements test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 11: senior_active_tasks schema + metadata parsing ===\n'
load_plugin '
import json
props = SENIOR_ACTIVE_TASKS_SCHEMA["parameters"]["properties"]
assert SENIOR_ACTIVE_TASKS_SCHEMA["name"] == "senior_active_tasks"
for f in ("repo", "only_current_origin", "include_comments"):
    assert f in props, f
# senior_active_tasks takes no required fields
assert "required" not in SENIOR_ACTIVE_TASKS_SCHEMA["parameters"] or \
    SENIOR_ACTIVE_TASKS_SCHEMA["parameters"].get("required") in (None, []), SENIOR_ACTIVE_TASKS_SCHEMA

# _parse_task_metadata round-trips a create_senior_task body
origin = {"platform": "telegram", "chat_id": "999", "thread_id": "", "user_id": "u", "session_key": ""}
body = _build_task_body("Fix bug", "/home/repo", origin)
meta = _parse_task_metadata(body)
assert meta["repo"] == "/home/repo", meta
assert meta["junie_task_type"] == "senior_dev_code_task", meta
assert _parse_task_metadata("no metadata here") == {}
print("OK: senior_active_tasks schema + metadata parse")
' && pass || fail "senior_active_tasks schema/parse test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 12: senior_active_tasks finds active task, filters by repo/origin ===\n'
TEST_REPO="$ROOT" run_with_hermes '
import json, os, tempfile
from pathlib import Path

os.environ["HERMES_KANBAN_DB"] = str(Path(tempfile.mkdtemp(prefix="st-")) / "kanban.db")
os.environ["HERMES_SESSION_PLATFORM"] = "telegram"
os.environ["HERMES_SESSION_CHAT_ID"] = "555000"
os.environ["HERMES_SESSION_THREAD_ID"] = ""
os.environ["HERMES_SESSION_USER_ID"] = "user_test"

from hermes_cli import kanban_db as kb
kb.init_db(Path(os.environ["HERMES_KANBAN_DB"]))

repo = os.environ.get("TEST_REPO", os.getcwd())
created = json.loads(handle_create_senior_task({
    "title": "Active lookup task",
    "request": "Do work",
    "repo": repo,
}))
task_id = created["task_id"]

# No filter: should include the new task
r = json.loads(handle_senior_active_tasks({}))
ids = [t["task_id"] for t in r["tasks"]]
assert task_id in ids, (task_id, ids)
hit = [t for t in r["tasks"] if t["task_id"] == task_id][0]
assert hit["repo"] == repo, hit
assert hit["status"] in ("ready", "running"), hit

# Matching origin filter: still present
r2 = json.loads(handle_senior_active_tasks({"only_current_origin": True}))
assert task_id in [t["task_id"] for t in r2["tasks"]], r2

# Non-matching repo filter: absent
r3 = json.loads(handle_senior_active_tasks({"repo": "/nonexistent/other/repo"}))
assert task_id not in [t["task_id"] for t in r3["tasks"]], r3

# Different origin filter: simulate another chat -> absent
os.environ["HERMES_SESSION_CHAT_ID"] = "111222"
r4 = json.loads(handle_senior_active_tasks({"only_current_origin": True}))
assert task_id not in [t["task_id"] for t in r4["tasks"]], r4
print("OK: active-task lookup filters by repo and origin")
' && pass || fail "senior_active_tasks lookup test failed"

# ════════════════════════════════════════════════════════════════
printf '\n'
printf '=== Results ===\n'
printf 'Passed: %d, Failed: %d\n' "$pass_count" "$fail_count"

if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi

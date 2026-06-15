"""Public tool schema and handler for create_senior_task.

Creates a Hermes Kanban task assigned to "senior-dev", stores origin/session
/repo metadata in the task body, subscribes the originating gateway thread
for terminal-state notifications (completed, blocked, gave_up, crashed,
timed_out), and handles idempotency.
"""

import json
import os
from typing import Any, Optional

CREATE_SENIOR_TASK_SCHEMA = {
    "name": "create_senior_task",
    "description": (
        "Create a Senior Dev Kanban task and subscribe the originating "
        "gateway thread for status updates."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "title": {
                "type": "string",
                "description": "Short title for the Kanban task.",
            },
            "request": {
                "type": "string",
                "description": (
                    "Full request/body for the task — the prompt the "
                    "Senior Dev will execute."
                ),
            },
            "repo": {
                "type": "string",
                "description": "Absolute path to the target repository.",
            },
            "backlog_id": {
                "type": "string",
                "description": "Optional originating backlog item id.",
            },
            "idempotency_key": {
                "type": "string",
                "description": (
                    "Optional idempotency key. If the same key is submitted "
                    "for an active matching Senior task, returns the existing "
                    "task_id without creating a duplicate."
                ),
            },
            "priority": {
                "type": "integer",
                "description": "Optional priority (0 = default, higher = more important).",
                "default": 0,
            },
        },
        "required": ["title", "request", "repo"],
        "additionalProperties": False,
    },
}

_SENIOR_ASSIGNEE = "senior-dev"


def _session_env(name: str, default: str = "") -> str:
    """Read Hermes session metadata from contextvars, falling back to env."""
    try:
        from gateway.session_context import get_session_env
        value = get_session_env(name, default)
        if value is not None:
            return str(value)
    except Exception:
        pass
    return os.environ.get(name, default)


def _resolve_origin() -> dict:
    """Resolve origin metadata from gateway session context with env fallback."""
    return {
        "platform": _session_env("HERMES_SESSION_PLATFORM", ""),
        "chat_id": _session_env("HERMES_SESSION_CHAT_ID", ""),
        "thread_id": _session_env("HERMES_SESSION_THREAD_ID", ""),
        "user_id": _session_env("HERMES_SESSION_USER_ID", ""),
        "session_key": _session_env("HERMES_SESSION_KEY", ""),
    }


def _build_task_body(request: str, repo: str, origin: dict, backlog_id: str = "") -> str:
    """Build Kanban task body with metadata embedded as trailing JSON section."""
    metadata = {
        "junie_task_type": "senior_dev_code_task",
        "source": origin if origin.get("platform") else None,
        "repo": repo,
        "owned_area": "",
        "marinator_job_id": None,
        "opencode_session_id": None,
        "pr_urls": [],
        "duplicate_keys": [],
    }
    if backlog_id:
        metadata["backlog_id"] = backlog_id

    meta_line = "_junie_metadata: " + json.dumps(metadata, separators=(",", ":"))
    parts = [request, "", "---", meta_line]
    return "\n".join(parts)


def check_requirements() -> bool:
    """Return True if Hermes CLI is available (kanban_db dependency)."""
    import shutil
    return shutil.which("hermes") is not None


def handle_create_senior_task(params: dict, plugin_ctx: Any = None, **kwargs) -> str:
    """Handle a create_senior_task tool call."""
    try:
        return _do_create(params, plugin_ctx)
    except Exception as e:
        return json.dumps({"error": f"create_senior_task failed: {e}"})


def _do_create(params: dict, plugin_ctx: Any = None) -> str:
    title = params.get("title", "").strip()
    request = params.get("request", "").strip()
    repo = params.get("repo", "").strip()
    backlog_id = params.get("backlog_id", "").strip()
    idempotency_key = params.get("idempotency_key", "").strip() or None
    priority = params.get("priority", 0)

    if not title:
        return json.dumps({"error": "title is required"})
    if not request:
        return json.dumps({"error": "request is required"})
    if not repo:
        return json.dumps({"error": "repo is required"})
    if not os.path.isabs(repo):
        return json.dumps({"error": f"repo must be an absolute path, got: {repo}"})
    if not os.path.isdir(repo):
        return json.dumps({"error": f"repo directory does not exist: {repo}"})

    origin = _resolve_origin()
    has_origin = bool(origin.get("platform") and origin.get("chat_id"))

    body = _build_task_body(request, repo, origin, backlog_id)

    try:
        from hermes_cli import kanban_db as kb
    except ImportError as e:
        return json.dumps({"error": f"Failed to import kanban_db: {e}"})

    conn = kb.connect()

    if idempotency_key:
        existing = conn.execute(
            "SELECT id, status FROM tasks WHERE idempotency_key = ? "
            "AND assignee = ? AND status NOT IN ('done', 'archived') "
            "ORDER BY created_at DESC LIMIT 1",
            (idempotency_key, _SENIOR_ASSIGNEE),
        ).fetchone()
        if existing:
            task_id = existing["id"]
            status = existing["status"]
            sub_target = None
            if has_origin:
                try:
                    kb.add_notify_sub(
                        conn,
                        task_id=task_id,
                        platform=origin["platform"],
                        chat_id=origin["chat_id"],
                        thread_id=origin.get("thread_id") or None,
                        user_id=origin.get("user_id") or None,
                    )
                    sub_target = f"{origin['platform']}:{origin['chat_id']}"
                except Exception:
                    pass
            return json.dumps({
                "task_id": task_id,
                "status": status,
                "subscription": sub_target,
                "duplicate": True,
                "idempotency": "existing",
                "message": f"Returning existing task {task_id} with status '{status}'",
            })

    task_id = kb.create_task(
        conn,
        title=title,
        body=body,
        assignee=_SENIOR_ASSIGNEE,
        initial_status="running",
        idempotency_key=idempotency_key,
        priority=priority,
        created_by="senior_task_helper",
    )

    subscribed = False
    subscription_info = {}
    if has_origin:
        try:
            kb.add_notify_sub(
                conn,
                task_id=task_id,
                platform=origin["platform"],
                chat_id=origin["chat_id"],
                thread_id=origin.get("thread_id") or None,
                user_id=origin.get("user_id") or None,
            )
            subscribed = True
            subscription_info = {
                "platform": origin["platform"],
                "chat_id": origin["chat_id"],
                "thread_id": origin.get("thread_id") or None,
            }
        except Exception as e:
            subscription_info = {"error": str(e)}

    return json.dumps({
        "task_id": task_id,
        "status": "ready",
        "subscription": subscription_info if subscribed else None,
        "duplicate": False,
        "idempotency": "created" if idempotency_key else "none",
        "message": f"Created Senior Dev task {task_id}",
    })


# ── senior_dev_task_result: update Kanban from Marinator artifacts ──

SENIOR_DEV_TASK_RESULT_SCHEMA = {
    "name": "senior_dev_task_result",
    "description": (
        "Report the outcome of a completed Marinator/OpenCode run back to "
        "the Senior Dev Kanban task. Called by the senior-dev profile when "
        "Marinator wakes it after the worker finishes or needs attention. "
        "Reads run_dir/status.json and run_dir/result.md if they exist."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "task_id": {
                "type": "string",
                "description": "Kanban task ID (t_<hex>) to update.",
            },
            "run_dir": {
                "type": "string",
                "description": (
                    "Absolute path to the Marinator run directory containing "
                    "status.json, result.md, etc."
                ),
            },
            "outcome": {
                "type": "string",
                "enum": ["completed", "blocked"],
                "description": (
                    "'completed' when the worker finished successfully with "
                    "PR evidence. 'blocked' when it needs user input, "
                    "stalled, or hit a failure."
                ),
            },
            "summary": {
                "type": "string",
                "description": (
                    "Human-readable summary of what was done, tests run, "
                    "files changed, PR URLs, or the block reason."
                ),
            },
            "pr_urls": {
                "type": "array",
                "items": {"type": "string"},
                "description": "Optional list of PR URLs created.",
                "default": [],
            },
            "expected_run_id": {
                "type": "integer",
                "description": (
                    "Optional run id for CAS completion. Usually from "
                    "kanban_db.current_run_id for this task."
                ),
            },
        },
        "required": ["task_id", "run_dir", "outcome", "summary"],
        "additionalProperties": False,
    },
}


def handle_senior_dev_task_result(params: dict, plugin_ctx: Any = None, **kwargs) -> str:
    """Handle a senior_dev_task_result tool call.

    Reads Marinator artifacts (status.json / result.md if available),
    then calls kanban_db.complete_task or kanban_db.block_task.
    """
    try:
        return _do_report_result(params, plugin_ctx)
    except Exception as e:
        return json.dumps({"error": f"senior_dev_task_result failed: {e}"})


def _do_report_result(params: dict, plugin_ctx: Any = None) -> str:
    task_id = params.get("task_id", "").strip()
    run_dir = params.get("run_dir", "").strip()
    outcome = params.get("outcome", "").strip()
    summary = params.get("summary", "").strip()
    pr_urls = params.get("pr_urls", [])
    expected_run_id = params.get("expected_run_id")

    if not task_id:
        return json.dumps({"error": "task_id is required"})
    if not run_dir:
        return json.dumps({"error": "run_dir is required"})
    if outcome not in ("completed", "blocked"):
        return json.dumps({"error": "outcome must be 'completed' or 'blocked'"})
    if not summary:
        return json.dumps({"error": "summary is required"})

    # Read Marinator artifacts
    marinator_info = {}
    status_path = os.path.join(run_dir, "status.json")
    result_path = os.path.join(run_dir, "result.md")

    if os.path.isfile(status_path):
        try:
            with open(status_path) as f:
                marinator_status = json.load(f)
            marinator_info["status"] = marinator_status
        except (json.JSONDecodeError, IOError):
            pass

    if os.path.isfile(result_path):
        try:
            with open(result_path) as f:
                marinator_info["result_md"] = f.read()
        except IOError:
            pass

    # Build metadata from PR URLs and marinator info
    metadata = {
        "marinator_run_dir": run_dir,
        "pr_urls": list(pr_urls),
    }
    if marinator_info.get("status"):
        opencode_info = marinator_info["status"].get("opencode", {})
        if opencode_info.get("session_id"):
            metadata["opencode_session_id"] = opencode_info["session_id"]
        if opencode_info.get("exit_code") is not None:
            metadata["opencode_exit_code"] = opencode_info["exit_code"]

    try:
        from hermes_cli import kanban_db as kb
    except ImportError as e:
        return json.dumps({"error": f"Failed to import kanban_db: {e}"})

    conn = kb.connect()

    if outcome == "completed":
        result_text = summary
        if pr_urls:
            result_text += "\n\nPRs: " + ", ".join(pr_urls)

        ok = kb.complete_task(
            conn,
            task_id=task_id,
            result=result_text,
            summary=summary,
            metadata=metadata,
            expected_run_id=expected_run_id,
        )
        if ok:
            return json.dumps({
                "ok": True,
                "task_id": task_id,
                "status": "done",
                "action": "completed",
                "message": f"Task {task_id} completed as done",
            })
        else:
            return json.dumps({
                "error": (
                    f"Failed to complete task {task_id}: CAS mismatch or "
                    f"task not in running/ready state"
                ),
                "task_id": task_id,
            })

    else:  # blocked
        ok = kb.block_task(
            conn,
            task_id=task_id,
            reason=summary,
            expected_run_id=expected_run_id,
        )
        if ok:
            return json.dumps({
                "ok": True,
                "task_id": task_id,
                "status": "blocked",
                "action": "blocked",
                "message": f"Task {task_id} blocked",
            })
        else:
            return json.dumps({
                "error": (
                    f"Failed to block task {task_id}: CAS mismatch or "
                    f"task not in running/ready state"
                ),
                "task_id": task_id,
            })

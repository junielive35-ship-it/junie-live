"""Public tool schema and handler for create_senior_task.

Creates a Hermes Kanban task assigned to "senior-dev", stores origin/session
/repo metadata in the task body, subscribes the originating gateway thread
for terminal-state notifications (completed, blocked, gave_up, crashed,
timed_out), and handles idempotency.
"""

import json
import os
from pathlib import Path
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

# Statuses that count as "active" for follow-up / duplicate detection. A task
# in any of these states should usually be attached to / followed up on rather
# than spawning a fresh duplicate Senior task for the same origin+repo.
_ACTIVE_STATUSES = ("ready", "running", "blocked", "scheduled")


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


def _resolve_notifier_profile(plugin_ctx: Any = None) -> Optional[str]:
    """Resolve the active Hermes profile for Kanban notification ownership."""
    for attr in ("_kanban_notifier_profile", "kanban_notifier_profile", "profile", "profile_name"):
        value = getattr(plugin_ctx, attr, None) if plugin_ctx is not None else None
        if value:
            return str(value)

    active_profile = getattr(plugin_ctx, "_active_profile_name", None) if plugin_ctx is not None else None
    if callable(active_profile):
        try:
            value = active_profile()
            if value:
                return str(value)
        except Exception:
            pass

    env_profile = os.environ.get("HERMES_PROFILE")
    if env_profile:
        return env_profile

    hermes_home = os.environ.get("HERMES_HOME")
    if hermes_home:
        path = Path(hermes_home)
        parts = path.parts
        if len(parts) >= 3 and parts[-3] == ".hermes" and parts[-2] == "profiles" and parts[-1]:
            return parts[-1]

    return None


def _build_task_body(request: str, repo: str, origin: dict) -> str:
    """Build Kanban task body with metadata embedded as trailing JSON section."""
    metadata = {
        "junie_task_type": "senior_dev_code_task",
        "source": origin if origin.get("platform") else None,
        "repo": repo,
        "owned_area": "",
        "opencode_session_id": None,
        "pr_urls": [],
        "duplicate_keys": [],
    }
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
    notifier_profile = _resolve_notifier_profile(plugin_ctx)

    body = _build_task_body(request, repo, origin)

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
            subscription_error = None
            if has_origin:
                try:
                    kb.add_notify_sub(
                        conn,
                        task_id=task_id,
                        platform=origin["platform"],
                        chat_id=origin["chat_id"],
                        thread_id=origin.get("thread_id") or None,
                        user_id=origin.get("user_id") or None,
                        notifier_profile=notifier_profile,
                    )
                    sub_target = f"{origin['platform']}:{origin['chat_id']}"
                except Exception as e:
                    subscription_error = str(e)
            response = {
                "task_id": task_id,
                "status": status,
                "subscription": sub_target,
                "duplicate": True,
                "idempotency": "existing",
                "message": f"Returning existing task {task_id} with status '{status}'",
            }
            if subscription_error:
                response["subscription_error"] = subscription_error
            return json.dumps(response)

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
    subscription_error = None
    if has_origin:
        try:
            kb.add_notify_sub(
                conn,
                task_id=task_id,
                platform=origin["platform"],
                chat_id=origin["chat_id"],
                thread_id=origin.get("thread_id") or None,
                user_id=origin.get("user_id") or None,
                notifier_profile=notifier_profile,
            )
            subscribed = True
            subscription_info = {
                "platform": origin["platform"],
                "chat_id": origin["chat_id"],
                "thread_id": origin.get("thread_id") or None,
            }
        except Exception as e:
            subscription_error = str(e)

    response = {
        "task_id": task_id,
        "status": "ready",
        "subscription": subscription_info if subscribed else None,
        "duplicate": False,
        "idempotency": "created" if idempotency_key else "none",
        "message": f"Created Senior Dev task {task_id}",
    }
    if subscription_error:
        response["subscription_error"] = subscription_error
    return json.dumps(response)


# ── senior_active_tasks: active-task lookup for follow-up routing ──

SENIOR_ACTIVE_TASKS_SCHEMA = {
    "name": "senior_active_tasks",
    "description": (
        "List active Senior Dev Kanban tasks (ready/running/blocked/scheduled), "
        "optionally filtered by repo and/or the current origin chat. Use this "
        "BEFORE create_senior_task to decide whether a new code request is a "
        "follow-up to an existing task (attach via kanban_comment / unblock) "
        "or genuinely new. Duplicate/follow-up detection is your judgment from "
        "this Kanban state, not fuzzy matching."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "repo": {
                "type": "string",
                "description": (
                    "Optional absolute repo path to filter tasks by "
                    "_junie_metadata.repo."
                ),
            },
            "only_current_origin": {
                "type": "boolean",
                "description": (
                    "If true, only return tasks whose embedded origin matches "
                    "the current gateway chat (platform + chat_id). Defaults to "
                    "false (return all active Senior tasks)."
                ),
                "default": False,
            },
            "include_comments": {
                "type": "boolean",
                "description": (
                    "If true, include each task's comments so you can read "
                    "prior block reasons / review asks. Defaults to false."
                ),
                "default": False,
            },
        },
        "additionalProperties": False,
    },
}


def _parse_task_metadata(body: str) -> dict:
    """Extract the trailing _junie_metadata JSON from a task body, if present."""
    marker = "_junie_metadata:"
    idx = body.rfind(marker)
    if idx == -1:
        return {}
    raw = body[idx + len(marker):].strip()
    # Metadata is on a single line; take the first line only.
    raw = raw.splitlines()[0] if raw else ""
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        return {}


def handle_senior_active_tasks(params: dict, plugin_ctx: Any = None, **kwargs) -> str:
    """Handle a senior_active_tasks tool call."""
    try:
        return _do_active_tasks(params, plugin_ctx)
    except Exception as e:
        return json.dumps({"error": f"senior_active_tasks failed: {e}"})


def _do_active_tasks(params: dict, plugin_ctx: Any = None) -> str:
    repo_filter = (params.get("repo") or "").strip()
    only_current_origin = bool(params.get("only_current_origin", False))
    include_comments = bool(params.get("include_comments", False))

    origin = _resolve_origin()
    cur_platform = origin.get("platform") or ""
    cur_chat = origin.get("chat_id") or ""

    try:
        from hermes_cli import kanban_db as kb
    except ImportError as e:
        return json.dumps({"error": f"Failed to import kanban_db: {e}"})

    conn = kb.connect()

    tasks_out = []
    seen_ids = set()
    for status in _ACTIVE_STATUSES:
        try:
            rows = kb.list_tasks(conn, assignee=_SENIOR_ASSIGNEE, status=status)
        except Exception:
            rows = []
        for t in rows:
            task_id = getattr(t, "id", None) or (t["id"] if isinstance(t, dict) else None)
            if not task_id or task_id in seen_ids:
                continue
            body = getattr(t, "body", None)
            if body is None and isinstance(t, dict):
                body = t.get("body", "")
            body = body or ""
            meta = _parse_task_metadata(body)

            task_repo = meta.get("repo", "")
            if repo_filter and task_repo != repo_filter:
                continue

            source = meta.get("source") or {}
            if only_current_origin:
                if not (cur_platform and cur_chat):
                    continue
                if not (source.get("platform") == cur_platform
                        and str(source.get("chat_id")) == str(cur_chat)):
                    continue

            seen_ids.add(task_id)
            entry = {
                "task_id": task_id,
                "title": getattr(t, "title", None) or (t.get("title") if isinstance(t, dict) else ""),
                "status": status,
                "repo": task_repo,
                "origin": source or None,
                "pr_urls": meta.get("pr_urls", []),
            }
            if include_comments:
                try:
                    comments = kb.list_comments(conn, task_id)
                    entry["comments"] = [
                        {
                            "author": getattr(c, "author", None) or "",
                            "body": getattr(c, "body", None) or "",
                            "created_at": getattr(c, "created_at", None),
                        }
                        for c in comments
                    ]
                except Exception:
                    entry["comments"] = []
            tasks_out.append(entry)

    return json.dumps({
        "count": len(tasks_out),
        "repo_filter": repo_filter or None,
        "only_current_origin": only_current_origin,
        "current_origin": {"platform": cur_platform, "chat_id": cur_chat} if cur_platform else None,
        "tasks": tasks_out,
    })

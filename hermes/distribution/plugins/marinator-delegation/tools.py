"""Public tool schema and handler for marinator_delegate.

This module owns the public schema (section 9 of the spec) and a thin handler
that validates inputs, delegates to runner.start_job(), and returns JSON.
It does not run OpenCode directly.
"""

import json
import os
import re
from typing import Any

# Valid OpenCode session id pattern: ses_<alphanumeric>
_SES_ID_RE = re.compile(r"^ses_[A-Za-z0-9]+$")

MARINATOR_DELEGATE_SCHEMA = {
    "name": "marinator_delegate",
    "description": "Delegate a code-changing task to the Junie Live Marinator/OpenCode worker.",
    "parameters": {
        "type": "object",
        "properties": {
            "job_id": {
                "type": "string",
                "description": (
                    "A stable identifier for this delegation job. Must be alphanumeric "
                    "with hyphens/underscores, no path separators."
                ),
            },
            "repo": {
                "type": "string",
                "description": "Absolute path to the target repository.",
            },
            "prompt_file": {
                "type": "string",
                "description": "Absolute path to the prompt file (.md) for the worker.",
            },
            "attachments": {
                "type": "array",
                "items": {"type": "string"},
                "description": "Optional list of absolute paths to attach as context.",
                "default": [],
            },
            "is_follow_up": {
                "type": "boolean",
                "description": (
                    "If true, continue the most recent valid OpenCode session for this "
                    "repo/task lineage. Defaults to false. The tool resolves session ids "
                    "internally; do not supply session ids."
                ),
                "default": False,
            },
            "enable_per_minute_reports": {
                "type": "boolean",
                "description": (
                    "Enable periodic progress reports (~60s) via Telegram. "
                    "Defaults to true for debug visibility. Do not set to false "
                    "unless the human explicitly asked to disable progress/debug messages."
                ),
                "default": True,
            },
            "kanban_linkage": {
                "type": "object",
                "description": (
                    "Optional Kanban task linkage for Senior Dev mode. "
                    "When set, Marinator persists the linkage in spec.json "
                    "and the wake/resume prompt can access it."
                ),
                "properties": {
                    "task_id": {
                        "type": "string",
                        "description": "Kanban task ID (t_<hex>).",
                    },
                    "board": {
                        "type": "string",
                        "description": "Kanban board slug (default or custom).",
                    },
                    "workspace_path": {
                        "type": "string",
                        "description": "Optional workspace path for the task.",
                    },
                },
                "required": ["task_id"],
                "additionalProperties": False,
            },
        },
        "required": ["job_id", "repo", "prompt_file"],
        "additionalProperties": False,
    },
}

# Safe job_id pattern: alphanumeric, hyphens, underscores, dots. No path separators.
_SAFE_JOB_ID_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$")


def check_requirements() -> bool:
    """Return True if prerequisites are available, else False."""
    return _resolve_opencode_bin() is not None


def _resolve_opencode_bin() -> str | None:
    """Resolve the OpenCode binary path (local helper, mirrors runner logic)."""
    opencode_bin = os.environ.get("OPENCODE_BIN", "")
    if opencode_bin and os.path.isfile(opencode_bin) and os.access(opencode_bin, os.X_OK):
        return opencode_bin
    import shutil
    path_bin = shutil.which("opencode")
    if path_bin:
        return path_bin
    for fallback in [
        "/home/Danila.Savenkov/.opencode/bin/opencode",
        os.path.expanduser("~/.opencode/bin/opencode"),
    ]:
        if os.path.isfile(fallback) and os.access(fallback, os.X_OK):
            return fallback
    return None


def smoke_test_opencode() -> dict:
    """Run a real opencode smoke execution to verify readiness.

    Uses the same binary resolution as the Marinator runner.
    Returns a dict with 'success' (bool) and 'detail' (str).
    This is the canonical readiness check — NOT ``opencode auth list``,
    which can report 0 credentials on an otherwise operational install.
    """
    opencode_bin = _resolve_opencode_bin()
    if opencode_bin is None:
        return {"success": False, "detail": "opencode binary not found"}

    import subprocess
    try:
        result = subprocess.run(
            [opencode_bin, "run", 'Respond with exactly: OPENCODE_SMOKE_OK'],
            capture_output=True, text=True, timeout=120,
        )
        output = (result.stdout or "") + (result.stderr or "")
        ok = result.returncode == 0 and "OPENCODE_SMOKE_OK" in output
        return {
            "success": ok,
            "detail": (
                f"exit={result.returncode}, "
                f"stdout_tail={result.stdout[-200:]!r}, "
                f"stderr_tail={result.stderr[-200:]!r}"
            ),
        }
    except FileNotFoundError:
        return {"success": False, "detail": f"opencode binary not found at {opencode_bin}"}
    except subprocess.TimeoutExpired:
        return {"success": False, "detail": "opencode smoke timed out after 120s"}
    except Exception as e:
        return {"success": False, "detail": f"opencode smoke failed: {e}"}


def _validate_inputs(params: dict) -> str | None:
    """Validate marinator_delegate inputs. Returns error string or None."""
    job_id = params.get("job_id", "")
    if not _SAFE_JOB_ID_RE.match(job_id):
        return (
            f"Invalid job_id '{job_id}': must be 1-128 chars, alphanumeric/hyphen/"
            "underscore/dot, no path separators."
        )

    repo = params.get("repo", "")
    if not os.path.isabs(repo):
        return f"repo must be an absolute path, got: {repo}"
    if not os.path.isdir(repo):
        return f"repo directory does not exist: {repo}"

    prompt_file = params.get("prompt_file", "")
    if not os.path.isabs(prompt_file):
        return f"prompt_file must be an absolute path, got: {prompt_file}"
    if not os.path.isfile(prompt_file):
        return f"prompt_file does not exist: {prompt_file}"

    for att in params.get("attachments", []):
        if not os.path.isabs(att):
            return f"attachment must be an absolute path, got: {att}"
        if not os.path.exists(att):
            return f"attachment does not exist: {att}"

    # Backward compat: if older caller still passes opencode_previous_session_id,
    # validate it strictly. Do not let raw paths reach OpenCode.
    prev_session = params.get("opencode_previous_session_id")
    if prev_session is not None:
        if not isinstance(prev_session, str):
            return "opencode_previous_session_id must be a string or null"
        # Normalize empty and "null" string to None
        if prev_session in ("", "null", "None"):
            params["opencode_previous_session_id"] = None
        elif not _SES_ID_RE.match(prev_session):
            return (
                f"Invalid opencode_previous_session_id '{prev_session}': "
                "must match pattern ^ses_[A-Za-z0-9]+$"
            )

    return None


def handle_marinator_delegate(params: dict, plugin_ctx: Any = None, **kwargs) -> str:
    """Handle a marinator_delegate tool call.

    Validates inputs, delegates to runner.start_job(), returns JSON string.
    """
    # Apply defaults for optional fields
    params.setdefault("attachments", [])
    params.setdefault("is_follow_up", False)
    params.setdefault("enable_per_minute_reports", True)

    error = _validate_inputs(params)
    if error:
        return json.dumps({"error": error})

    from .runner import start_job

    try:
        result = start_job(
            job_id=params["job_id"],
            repo=params["repo"],
            prompt_file=params["prompt_file"],
            attachments=params.get("attachments", []),
            is_follow_up=params.get("is_follow_up", False),
            opencode_previous_session_id=params.get("opencode_previous_session_id"),
            enable_per_minute_reports=params.get("enable_per_minute_reports", True),
            kanban_linkage=params.get("kanban_linkage"),
            ctx=plugin_ctx,
        )
        return json.dumps(result)
    except Exception as e:
        return json.dumps({"error": f"Failed to start Marinator job: {e}"})

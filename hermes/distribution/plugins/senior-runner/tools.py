"""Public tool schema and handler for senior_run_coding_task.

The synchronous Senior Dev coding tool. The senior-dev Kanban worker calls
this once per task: it runs the dummy Senior executor (vanilla OpenCode) in
the foreground and returns the artifact paths. It does NOT mutate the Kanban
board — the worker reads result.md/status.json and applies the single
terminal Kanban action itself.
"""

import json
import os
import re
import time
from typing import Any

# Safe job_id pattern: alphanumeric, hyphens, underscores, dots. No path separators.
_SAFE_JOB_ID_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$")

SENIOR_RUN_CODING_TASK_SCHEMA = {
    "name": "senior_run_coding_task",
    "description": (
        "Run a single coding task synchronously via the dummy Senior executor "
        "(vanilla OpenCode) and return Marinator-style artifact paths. Blocks "
        "until OpenCode exits. Does not touch the Kanban board."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "task_id": {
                "type": "string",
                "description": "Kanban task id (t_<hex>) this run belongs to.",
            },
            "repo": {
                "type": "string",
                "description": "Absolute path to the target repository.",
            },
            "request": {
                "type": "string",
                "description": (
                    "The full request/prompt the Senior executor should work on."
                ),
            },
            "context": {
                "type": "string",
                "description": (
                    "Optional additional context (relevant comments, prior "
                    "block reasons, the user's follow-up answer)."
                ),
                "default": "",
            },
            "job_id": {
                "type": "string",
                "description": (
                    "Optional safe job id. Defaults to a value derived from "
                    "task_id + timestamp. Alphanumeric/hyphen/underscore/dot, "
                    "no path separators."
                ),
            },
        },
        "required": ["task_id", "repo", "request"],
        "additionalProperties": False,
    },
}


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


def check_requirements() -> bool:
    """Return True if prerequisites (OpenCode binary) are available."""
    return _resolve_opencode_bin() is not None


def _derive_job_id(task_id: str) -> str:
    """Derive a safe job id from a task id and the current timestamp."""
    safe_task = re.sub(r"[^a-zA-Z0-9._-]", "_", task_id) or "task"
    return f"senior-{safe_task}-{int(time.time())}"


def _validate_inputs(params: dict) -> str | None:
    """Validate senior_run_coding_task inputs. Returns error string or None."""
    task_id = params.get("task_id", "").strip()
    if not task_id:
        return "task_id is required"

    repo = params.get("repo", "").strip()
    if not repo:
        return "repo is required"
    if not os.path.isabs(repo):
        return f"repo must be an absolute path, got: {repo}"
    if not os.path.isdir(repo):
        return f"repo directory does not exist: {repo}"

    request = params.get("request", "").strip()
    if not request:
        return "request is required"

    job_id = params.get("job_id")
    if job_id:
        if not _SAFE_JOB_ID_RE.match(job_id):
            return (
                f"Invalid job_id '{job_id}': must be 1-128 chars, alphanumeric/"
                "hyphen/underscore/dot, no path separators."
            )

    return None


def handle_senior_run_coding_task(params: dict, plugin_ctx: Any = None, **kwargs) -> str:
    """Handle a senior_run_coding_task tool call.

    Validates inputs, delegates to runner.run_coding_task (blocking),
    returns a JSON string with artifact paths.
    """
    error = _validate_inputs(params)
    if error:
        return json.dumps({"ok": False, "error": error})

    task_id = params["task_id"].strip()
    repo = params["repo"].strip()
    request = params["request"].strip()
    context = (params.get("context") or "").strip()
    job_id = (params.get("job_id") or "").strip() or _derive_job_id(task_id)

    from .runner import run_coding_task

    try:
        result = run_coding_task(
            job_id=job_id,
            task_id=task_id,
            repo=repo,
            request=request,
            context=context,
        )
        return json.dumps(result)
    except Exception as e:
        return json.dumps({"ok": False, "error": f"senior_run_coding_task failed: {e}"})

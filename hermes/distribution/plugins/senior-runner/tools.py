"""Public tool schema and handler for senior_run_coding_task.

The synchronous Senior Dev coding tool. The senior-dev Kanban worker calls
this once per task: it runs the headless Junie CLI Senior executor in the
foreground and returns the artifact paths. It does NOT mutate the Kanban
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
        "Run a single coding task synchronously via the headless Junie CLI "
        "Senior executor and return artifact paths. Blocks until Junie CLI "
        "exits. Does not touch the Kanban board."
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
            "user_outcome": {
                "type": "string",
                "description": (
                    "User-visible outcome the Senior executor must achieve."
                ),
            },
            "acceptance_criteria": {
                "type": "string",
                "description": (
                    "Concrete checks that define done for the requested outcome."
                ),
            },
            "distilled_context": {
                "type": "string",
                "description": (
                    "Relevant local findings, task history, comments, and constraints "
                    "distilled for the Senior executor."
                ),
                "default": "",
            },
            "constraints": {
                "type": "string",
                "description": "Hard constraints the Senior executor must obey.",
                "default": "",
            },
            "non_goals": {
                "type": "string",
                "description": "Explicit work that is out of scope for this handoff.",
                "default": "",
            },
            "expected_report_schema": {
                "type": "string",
                "description": (
                    "Additional report fields the Senior executor should include in "
                    "its raw final response. No fixed result protocol is imposed; "
                    "the senior-dev worker reads the artifacts and decides the "
                    "Kanban action itself."
                ),
                "default": "",
            },
            "context": {
                "type": "string",
                "description": (
                    "Deprecated compatibility field. Prefer distilled_context."
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
        "required": ["task_id", "repo", "user_outcome", "acceptance_criteria"],
        "additionalProperties": False,
    },
}


def _resolve_junie_bin() -> str | None:
    """Resolve the Junie CLI binary path (local helper, mirrors runner logic)."""
    junie_bin = os.environ.get("JUNIE_BIN", "")
    if junie_bin and os.path.isfile(junie_bin) and os.access(junie_bin, os.X_OK):
        return junie_bin
    import shutil
    path_bin = shutil.which("junie")
    if path_bin:
        return path_bin
    for fallback in [
        os.path.expanduser("~/.local/bin/junie"),
    ]:
        if os.path.isfile(fallback) and os.access(fallback, os.X_OK):
            return fallback
    return None


def check_requirements() -> bool:
    """Return True if prerequisites (Junie CLI binary) are available."""
    return _resolve_junie_bin() is not None


def _build_handoff_prompt(params: dict) -> str:
    """Build the structured p.0 Team Lead -> Senior Dev handoff prompt."""
    parts = [
        "# Team Lead -> Senior Dev handoff",
        "",
        "## Repository",
        params["repo"].strip(),
        "",
        "## User-visible outcome",
        params["user_outcome"].strip(),
        "",
        "## Acceptance criteria",
        params["acceptance_criteria"].strip(),
    ]
    optional_sections = [
        ("Distilled context", (params.get("distilled_context") or params.get("context") or "").strip()),
        ("Constraints", (params.get("constraints") or "").strip()),
        ("Non-goals", (params.get("non_goals") or "").strip()),
        ("Expected report schema", (params.get("expected_report_schema") or "").strip()),
    ]
    for title, value in optional_sections:
        if value:
            parts.extend(["", f"## {title}", value])
    return "\n".join(parts)


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

    user_outcome = params.get("user_outcome", "").strip()
    if not user_outcome:
        return "user_outcome is required"

    acceptance_criteria = params.get("acceptance_criteria", "").strip()
    if not acceptance_criteria:
        return "acceptance_criteria is required"

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
    request = _build_handoff_prompt(params)
    context = ""
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

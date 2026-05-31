"""Public tool schema and handler for marinator_delegate.

This module owns the public schema (section 9 of the spec) and a thin handler
that validates inputs, delegates to runner.start_job(), and returns JSON.
It does not run OpenCode directly.
"""

import json
import os
import re
from typing import Any

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
            "opencode_previous_session_id": {
                "type": ["string", "null"],
                "description": (
                    "Optional OpenCode session id from a previous run, for follow-up/fix loops. "
                    "When provided, the worker continues the previous OpenCode context."
                ),
                "default": None,
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
        },
        "required": ["job_id", "repo", "prompt_file"],
        "additionalProperties": False,
    },
}

# Safe job_id pattern: alphanumeric, hyphens, underscores, dots. No path separators.
_SAFE_JOB_ID_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$")


def check_requirements() -> bool:
    """Return True if prerequisites are available, else False."""
    # Check OPENCODE_BIN env var
    opencode_bin = os.environ.get("OPENCODE_BIN", "")
    if opencode_bin and os.path.isfile(opencode_bin) and os.access(opencode_bin, os.X_OK):
        return True
    # Check PATH
    import shutil
    if shutil.which("opencode"):
        return True
    # Check hardcoded absolute path
    hardcoded = "/home/Danila.Savenkov/.opencode/bin/opencode"
    if os.path.isfile(hardcoded) and os.access(hardcoded, os.X_OK):
        return True
    # Check expanded ~ fallback
    fallback = os.path.expanduser("~/.opencode/bin/opencode")
    if os.path.isfile(fallback) and os.access(fallback, os.X_OK):
        return True
    return False


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

    prev_session = params.get("opencode_previous_session_id")
    if prev_session is not None and not isinstance(prev_session, str):
        return "opencode_previous_session_id must be a string or null"

    return None


def handle_marinator_delegate(params: dict, plugin_ctx: Any = None, **kwargs) -> str:
    """Handle a marinator_delegate tool call.

    Validates inputs, delegates to runner.start_job(), returns JSON string.
    """
    # Apply defaults for optional fields
    params.setdefault("attachments", [])
    params.setdefault("opencode_previous_session_id", None)
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
            opencode_previous_session_id=params.get("opencode_previous_session_id"),
            enable_per_minute_reports=params.get("enable_per_minute_reports", True),
            ctx=plugin_ctx,
        )
        return json.dumps(result)
    except Exception as e:
        return json.dumps({"error": f"Failed to start Marinator job: {e}"})

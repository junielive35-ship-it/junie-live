"""Synchronous runner for the Senior Dev coding lane.

Owns run-dir creation, spec.json/status.json/events.jsonl writing, and a
*blocking* invocation of the plugin-local Python worker. Unlike the Marinator
runner, this does not background the worker or wake any session: the call
returns only after OpenCode has exited and the artifacts are written.

The runner never mutates the Kanban board. The senior-dev worker agent reads
the returned artifact paths and performs the single terminal Kanban action.
"""

import os
import shutil
import time
from typing import Optional

from . import state
from . import worker


def _resolve_opencode_bin() -> Optional[str]:
    """Resolve the OpenCode binary path.

    Priority:
      1. OPENCODE_BIN env var
      2. 'opencode' from PATH
      3. /home/Danila.Savenkov/.opencode/bin/opencode  (profile-home)
      4. ~/.opencode/bin/opencode  (expanded ~)
    """
    env_bin = os.environ.get("OPENCODE_BIN", "")
    if env_bin and os.path.isfile(env_bin) and os.access(env_bin, os.X_OK):
        return env_bin

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


# Result discipline appended to every Senior prompt: OpenCode must end its
# response with this block. The worker script normalizes / synthesizes it,
# but asking for it directly produces far better verdicts.
_VERDICT_INSTRUCTIONS = """\

---

When you are finished, end your response with exactly this block (no code fence):

VERDICT: pr-ready|needs-input|failed
SUMMARY: <one sentence>
USER_MESSAGE: <message safe to send to the user>
PR_URL: <url or empty>
"""


def _build_prompt(request: str, context: str = "") -> str:
    """Assemble the OpenCode prompt from the request, optional context, and
    the fixed result-discipline block."""
    parts = [request.strip()]
    if context.strip():
        parts.append("\n## Additional context\n\n" + context.strip())
    parts.append(_VERDICT_INSTRUCTIONS)
    return "\n".join(parts)


def run_coding_task(
    job_id: str,
    task_id: str,
    repo: str,
    request: str,
    context: str = "",
) -> dict:
    """Create run dir, write spec/status/events, run the worker synchronously.

    Blocks until OpenCode exits. Returns a dict with ok, job_id, run_dir,
    status_path, result_path, exit_code.
    """
    opencode_bin = _resolve_opencode_bin()
    if not opencode_bin:
        return {
            "ok": False,
            "error": (
                "opencode_not_found: could not resolve OpenCode binary. "
                "Set OPENCODE_BIN, add opencode to PATH, or install to "
                "~/.opencode/bin/opencode."
            ),
            "job_id": job_id,
        }

    # Create run directory and write the prompt.
    run_dir = state.create_run_dir(job_id)
    prompt_text = _build_prompt(request, context)
    prompt_dest = state.write_prompt(run_dir, prompt_text)

    # Write spec.json
    spec = {
        "job_id": job_id,
        "task_id": task_id,
        "repo": repo,
        "prompt_file": prompt_dest,
        "opencode_bin": opencode_bin,
        "created_at": time.time(),
        "created_iso": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }
    spec_path = os.path.join(run_dir, "spec.json")
    state.atomic_write_json(spec_path, spec)

    # Write initial status.json
    status_path = os.path.join(run_dir, "status.json")
    initial_status = state.make_initial_status(
        job_id=job_id,
        task_id=task_id,
        repo=repo,
        run_dir=run_dir,
        opencode_bin=opencode_bin,
    )
    state.atomic_write_json(status_path, initial_status)

    # Initialize events.jsonl
    events_path = os.path.join(run_dir, "events.jsonl")
    state.append_event(events_path, "job_created", {
        "job_id": job_id,
        "task_id": task_id,
        "repo": repo,
    })

    result_path = os.path.join(run_dir, "result.md")

    # Synchronous, blocking invocation. This call returns only after OpenCode exits.
    state.append_event(events_path, "worker_started", {
        "worker_module": "senior-runner.worker",
        "dispatch_method": "in_process_sync",
    })

    try:
        exit_code = worker.run_from_spec(run_dir, job_id, spec_path)
    except Exception as e:
        state.update_status(status_path, {"worker_state": "failed"})
        state.append_event(events_path, "worker_start_failed", {
            "error": str(e),
            "dispatch_method": "in_process_sync",
        })
        return {
            "ok": False,
            "error": f"Failed to run Senior worker: {e}",
            "job_id": job_id,
            "run_dir": run_dir,
            "status_path": status_path,
            "result_path": result_path,
            "exit_code": None,
        }

    final_status = state.read_json(status_path) or {}

    return {
        "ok": exit_code == 0,
        "job_id": job_id,
        "task_id": task_id,
        "run_dir": run_dir,
        "status_path": status_path,
        "result_path": result_path,
        "exit_code": exit_code,
        "verdict": final_status.get("verdict"),
        "message": (
            "Synchronous Senior coding run finished. Read result.md and "
            "status.json, then apply exactly one terminal Kanban action."
        ),
    }

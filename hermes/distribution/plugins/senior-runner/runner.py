"""Synchronous runner for the Senior Dev coding lane.

Owns run-dir creation, spec.json/status.json/events.jsonl writing, and a
*blocking* invocation of the plugin-local Python worker. Unlike the Marinator
runner, this does not background the worker or wake any session: the call
returns only after Junie CLI has exited and the artifacts are written.

The runner never mutates the Kanban board and never decides a semantic
outcome. The senior-dev worker agent reads the returned artifact paths,
exit code, and run status, then chooses the single terminal Kanban action
itself using the repo-documented status rules.
"""

import os
import shutil
import time
from typing import Optional

from . import state
from . import worker


def _resolve_junie_bin() -> Optional[str]:
    """Resolve the Junie CLI binary path.

    Priority:
      1. JUNIE_BIN env var
      2. 'junie' from PATH
      3. ~/.local/bin/junie  (expanded ~)
    """
    env_bin = os.environ.get("JUNIE_BIN", "")
    if env_bin and os.path.isfile(env_bin) and os.access(env_bin, os.X_OK):
        return env_bin

    path_bin = shutil.which("junie")
    if path_bin:
        return path_bin

    for fallback in [
        os.path.expanduser("~/.local/bin/junie"),
    ]:
        if os.path.isfile(fallback) and os.access(fallback, os.X_OK):
            return fallback

    return None


def _build_prompt(request: str, context: str = "") -> str:
    """Assemble the Junie CLI prompt from the request and optional context.

    The runner appends the Senior Dev final verdict contract so the headless
    executor returns a machine-readable done/needs-input/failed verdict while
    still preserving the raw response as artifacts.
    """
    parts = [request.strip()]
    if context.strip():
        parts.append("\n## Additional context\n\n" + context.strip())
    parts.append(
        "\n## Required final verdict\n\n"
        "End with a JSON object matching FINAL_VERDICT_SCHEMA from "
        "~/.junie/AGENTS.md. The `verdict` value must be exactly one of "
        "`done`, `needs-input`, or `failed`. Senior Dev owns implementation, "
        "review, verification, and the fix loop end-to-end before returning "
        "`done`."
    )
    return "\n".join(parts)


def run_coding_task(
    job_id: str,
    task_id: str,
    repo: str,
    request: str,
    context: str = "",
) -> dict:
    """Create run dir, write spec/status/events, run the worker synchronously.

    Blocks until Junie CLI exits. Returns a dict with ok, job_id, run_dir,
    status_path, result_path, exit_code.
    """
    junie_bin = _resolve_junie_bin()
    if not junie_bin:
        return {
            "ok": False,
            "error": (
                "junie_not_found: could not resolve Junie CLI binary. "
                "Set JUNIE_BIN, add junie to PATH, or install to "
                "~/.local/bin/junie."
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
        "junie_bin": junie_bin,
        "auth_file": os.environ.get("JUNIE_SENIOR_AUTH_FILE", "~/junie.key"),
        "model": os.environ.get("JUNIE_SENIOR_MODEL", "claude-opus-4.8"),
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
        junie_bin=junie_bin,
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

    # Synchronous, blocking invocation. This call returns only after Junie CLI exits.
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
        "worker_state": final_status.get("worker_state"),
        "message": (
            "Synchronous Senior coding run finished. Read result.md and "
            "status.json, then decide and apply exactly one terminal Kanban "
            "action yourself."
        ),
    }

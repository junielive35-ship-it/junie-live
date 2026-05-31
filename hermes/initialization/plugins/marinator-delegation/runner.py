"""Runner module for Marinator delegation.

Owns runtime detection, run-dir creation, spec.json writing, and spawning
the marinator-worker.sh wrapper. Live gateway sessions use Hermes terminal
background semantics; headless/fallback sessions use subprocess. Does not run
OpenCode inline — that is the wrapper script's job.
"""

import json
import os
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any, Optional

from . import state


def _session_env(name: str, default: str = "") -> str:
    """Read Hermes session metadata from contextvars, falling back to env.

    Gateway sessions store HERMES_SESSION_* values in gateway.session_context
    contextvars, not process-global os.environ. Plugin tools run inside the
    same Hermes process, so env-only detection misclassifies live Telegram
    calls as headless.
    """
    try:
        from gateway.session_context import get_session_env  # type: ignore

        value = get_session_env(name, default)
        if value is not None:
            return str(value)
    except Exception:
        pass
    return os.environ.get(name, default)


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


def _detect_runtime_mode() -> tuple[str, dict]:
    """Detect runtime mode from Hermes session environment.

    Returns (mode, detected_from) where mode is 'live_gateway' or 'headless'.
    """
    platform = _session_env("HERMES_SESSION_PLATFORM", "")
    chat_id = _session_env("HERMES_SESSION_CHAT_ID", "")

    # Allow debug override
    force_mode = os.environ.get("MARINATOR_FORCE_MODE", "")
    if force_mode in ("live_gateway", "headless"):
        return force_mode, {"MARINATOR_FORCE_MODE": force_mode}

    detected_from = {}
    if platform:
        detected_from["HERMES_SESSION_PLATFORM"] = platform
    if chat_id:
        detected_from["HERMES_SESSION_CHAT_ID"] = chat_id

    if platform and chat_id:
        return "live_gateway", detected_from
    else:
        return "headless", detected_from


def _resolve_progress_delivery(enable: bool) -> dict:
    """Resolve progress delivery routing from runtime session metadata.

    Returns the progress_delivery dict for spec.json. Never includes tokens.
    """
    if not enable:
        return {
            "enabled": False,
            "profile": None,
            "platform": None,
            "target": None,
            "source": "disabled",
        }

    platform = _session_env("HERMES_SESSION_PLATFORM", "")
    chat_id = _session_env("HERMES_SESSION_CHAT_ID", "")
    thread_id = _session_env("HERMES_SESSION_THREAD_ID", "")
    profile = os.environ.get("HERMES_PROFILE", "junie-live")

    if not platform or not chat_id:
        return {
            "enabled": False,
            "profile": profile,
            "platform": platform or None,
            "target": None,
            "source": "missing_runtime_delivery_context",
        }

    target = f"telegram:{chat_id}"
    if thread_id:
        target += f":{thread_id}"

    return {
        "enabled": True,
        "profile": profile,
        "platform": platform,
        "target": target,
        "source": "hermes_session_context",
    }


def _get_wrapper_script() -> str:
    """Return the absolute path to the marinator-worker.sh script."""
    return os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "scripts",
        "marinator-worker.sh",
    )


def start_job(
    job_id: str,
    repo: str,
    prompt_file: str,
    attachments: list[str] | None = None,
    opencode_previous_session_id: str | None = None,
    enable_per_minute_reports: bool = True,
    ctx: Any = None,
) -> dict:
    """Create run directory, write spec/status/events, and spawn the wrapper.

    Returns the tool result dict per spec section 9.
    """
    attachments = attachments or []

    # Resolve OpenCode binary
    opencode_bin = _resolve_opencode_bin()
    if not opencode_bin:
        return {
            "error": (
                "opencode_not_found: could not resolve OpenCode binary. "
                "Set OPENCODE_BIN, add opencode to PATH, or install to "
                "~/.opencode/bin/opencode."
            )
        }

    # Detect runtime mode
    runtime_mode, detected_from = _detect_runtime_mode()

    # Resolve owner session metadata from gateway contextvars when present.
    owner_session_id = _session_env("HERMES_SESSION_ID", "")
    owner_session_key = _session_env("HERMES_SESSION_KEY", "")
    hermes_profile = os.environ.get("HERMES_PROFILE", "junie-live")

    # Create run directory
    run_dir = state.create_run_dir(job_id)

    # Copy prompt
    prompt_dest = state.write_prompt(run_dir, prompt_file)

    # Copy attachments
    attachments_dir = os.path.join(run_dir, "attachments")
    copied_attachments = []
    if attachments:
        os.makedirs(attachments_dir, exist_ok=True)
        for att in attachments:
            dest = os.path.join(attachments_dir, os.path.basename(att))
            if os.path.isfile(att):
                shutil.copy2(att, dest)
                copied_attachments.append(dest)

    # Resolve progress delivery
    progress_delivery = _resolve_progress_delivery(enable_per_minute_reports)

    # Write spec.json
    spec = {
        "job_id": job_id,
        "repo": repo,
        "prompt_file": prompt_dest,
        "attachments": copied_attachments,
        "opencode_bin": opencode_bin,
        "opencode_previous_session_id": opencode_previous_session_id,
        "enable_per_minute_reports": enable_per_minute_reports,
        "runtime_mode": runtime_mode,
        "owner_session_id": owner_session_id,
        "owner_session_key": owner_session_key,
        "hermes_profile": hermes_profile,
        "progress_delivery": progress_delivery,
        "created_at": time.time(),
        "created_iso": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }
    spec_path = os.path.join(run_dir, "spec.json")
    state.atomic_write_json(spec_path, spec)

    # Write initial status.json
    status_path = os.path.join(run_dir, "status.json")
    initial_status = state.make_initial_status(
        job_id=job_id,
        owner_session_id=owner_session_id or None,
        owner_session_key=owner_session_key or None,
        runtime_mode=runtime_mode,
        runtime_detected_from=detected_from,
        repo=repo,
        run_dir=run_dir,
        opencode_bin=opencode_bin,
        opencode_previous_session_id=opencode_previous_session_id,
        skip_permissions=True,
    )
    state.atomic_write_json(status_path, initial_status)

    # Initialize events.jsonl
    events_path = os.path.join(run_dir, "events.jsonl")
    state.append_event(events_path, "job_created", {
        "job_id": job_id,
        "repo": repo,
        "runtime_mode": runtime_mode,
        "enable_per_minute_reports": enable_per_minute_reports,
    })

    # Spawn wrapper script
    wrapper_script = _get_wrapper_script()
    if not os.path.isfile(wrapper_script):
        return {
            "error": f"Wrapper script not found: {wrapper_script}",
            "job_id": job_id,
            "run_dir": run_dir,
        }

    runner_log = os.path.join(run_dir, "runner.log")
    process_session_id: Optional[str] = None

    # ── Live gateway path: dispatch via Hermes terminal(background, notify_on_complete) ──
    if runtime_mode == "live_gateway":
        import shlex

        shell_cmd = (
            f"export MARINATOR_RUN_DIR={shlex.quote(run_dir)} "
            f"MARINATOR_JOB_ID={shlex.quote(job_id)} "
            f"MARINATOR_SPEC_PATH={shlex.quote(spec_path)}; "
            f"bash {shlex.quote(wrapper_script)}"
        )
        dispatch_args = {
            "command": shell_cmd,
            "background": True,
            "notify_on_complete": True,
            "workdir": repo,
        }

        try:
            if ctx is not None and hasattr(ctx, "dispatch_tool"):
                result = ctx.dispatch_tool("terminal", dispatch_args)
            else:
                # PluginContext.dispatch_tool is unavailable in some test/plugin
                # loading contexts. The registry path still runs the real
                # terminal tool in-process, so gateway session contextvars are
                # preserved for notify_on_complete routing.
                from tools.registry import registry  # type: ignore

                result = registry.dispatch("terminal", dispatch_args)

            # Parse JSON result if possible
            if isinstance(result, str):
                try:
                    result = json.loads(result)
                except (json.JSONDecodeError, TypeError):
                    pass

            dispatch_error = None
            if isinstance(result, dict):
                process_session_id = result.get(
                    "session_id", result.get("process_session_id")
                )
                dispatch_error = result.get("error")

            if dispatch_error or not process_session_id:
                raise RuntimeError(
                    f"terminal dispatch did not start a background process: {result}"
                )

            state.update_status(status_path, {
                "worker_state": "running",
                "wrapper.dispatch_method": "terminal",
                "wrapper.process_session_id": process_session_id,
            })
            state.append_event(events_path, "wrapper_started", {
                "dispatch_method": "terminal",
                "wrapper_script": wrapper_script,
                "process_session_id": process_session_id,
                "notify_on_complete": True,
            })

        except Exception as e:
            state.update_status(status_path, {
                "worker_state": "failed",
                "wake.last_error": f"live terminal dispatch failed: {e}",
            })
            state.append_event(events_path, "wrapper_start_failed", {
                "error": str(e),
                "dispatch_method": "terminal",
                "fallback": "none",
            })
            return {
                "error": f"live_gateway terminal dispatch failed: {e}",
                "job_id": job_id,
                "run_dir": run_dir,
                "runtime_mode": runtime_mode,
            }

    # ── Headless / fallback path: subprocess.Popen ──
    else:
        process_session_id = _spawn_wrapper_subprocess(
            wrapper_script=wrapper_script,
            run_dir=run_dir,
            job_id=job_id,
            spec_path=spec_path,
            repo=repo,
            runner_log=runner_log,
            status_path=status_path,
            events_path=events_path,
        )
        if process_session_id is None:
            return {
                "error": "Failed to spawn wrapper via subprocess",
                "job_id": job_id,
                "run_dir": run_dir,
            }

    return {
        "job_id": job_id,
        "run_dir": run_dir,
        "process_session_id": process_session_id or f"job_{job_id}",
        "runtime_mode": runtime_mode,
        "enable_per_minute_reports": enable_per_minute_reports,
        "status_path": status_path,
        "message": (
            "Delegated coding task. I will review the result when "
            "Marinator wakes this session."
        ),
    }


def _spawn_wrapper_subprocess(
    *,
    wrapper_script: str,
    run_dir: str,
    job_id: str,
    spec_path: str,
    repo: str,
    runner_log: str,
    status_path: str,
    events_path: str,
    fallback_reason: str | None = None,
) -> Optional[str]:
    """Spawn the wrapper via subprocess.Popen. Returns process_session_id or None."""
    wrapper_env = os.environ.copy()
    wrapper_env["MARINATOR_RUN_DIR"] = run_dir
    wrapper_env["MARINATOR_JOB_ID"] = job_id
    wrapper_env["MARINATOR_SPEC_PATH"] = spec_path

    try:
        with open(runner_log, "w") as log_f:
            proc = subprocess.Popen(
                ["bash", wrapper_script],
                cwd=repo,
                env=wrapper_env,
                stdout=log_f,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )

        status_update: dict[str, Any] = {
            "worker_state": "running",
            "wrapper.pid": proc.pid,
            "wrapper.dispatch_method": "subprocess",
        }
        if fallback_reason:
            status_update["wake.last_error"] = (
                f"dispatch_tool failed, fell back to subprocess: {fallback_reason}"
            )
        state.update_status(status_path, status_update)

        state.append_event(events_path, "wrapper_started", {
            "wrapper_pid": proc.pid,
            "wrapper_script": wrapper_script,
            "dispatch_method": "subprocess",
            "fallback_reason": fallback_reason,
        })

        return f"proc_{proc.pid}"

    except Exception as e:
        state.update_status(status_path, {
            "worker_state": "failed",
            "wake.last_error": str(e),
        })
        state.append_event(events_path, "wrapper_start_failed", {
            "error": str(e),
            "dispatch_method": "subprocess",
        })
        return None

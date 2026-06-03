"""Public tool schemas and handlers for autonomous_work_start and autonomous_work_step.

The tool layer validates inputs, manages deterministic state transitions,
and delegates runner/spawning to helpers. It does not select work, edit
backlog, or execute tasks.
"""

import json
import os
import shutil
import subprocess
import sys
import time
from typing import Any, Optional

from . import state
from . import prompts
from . import backlog


AUTONOMOUS_WORK_START_SCHEMA = {
    "name": "autonomous_work_start",
    "description": "Start a bounded autonomous work window.",
    "parameters": {
        "type": "object",
        "properties": {
            "duration": {
                "type": "string",
                "description": (
                    "Duration of the autonomous work window, e.g. '2h', '90m', '30m'. "
                    "Required and bounded."
                ),
            },
            "prompt": {
                "type": "string",
                "description": (
                    "Optional owner guidance for this window. Not a replacement for "
                    "strategy/backlog/docs context."
                ),
                "default": "",
            },
            "enable_debug_messages": {
                "type": "boolean",
                "description": (
                    "Enable debug/progress messages sent via Telegram on each "
                    "autonomous step. Defaults to true for visibility. Set to false "
                    "only when the user explicitly asks to disable debug messages."
                ),
                "default": True,
            },
        },
        "required": ["duration"],
        "additionalProperties": False,
    },
}

AUTONOMOUS_WORK_STEP_SCHEMA = {
    "name": "autonomous_work_step",
    "description": (
        "Advance the autonomous work window state machine. Reads current AW state "
        "and artifacts, validates them, applies the deterministic transition table, "
        "writes state/events, and returns the next instruction and status."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "rationale": {
                "type": "string",
                "description": (
                    "Optional append-only commentary for the events log. Must not control "
                    "transitions; the tool determines transitions from artifacts alone."
                ),
                "default": "",
            },
        },
        "required": [],
        "additionalProperties": False,
    },
}


def check_requirements() -> bool:
    return shutil.which("hermes") is not None


# ── Session metadata helpers ──

def _session_env(name: str, default: str = "") -> str:
    try:
        from gateway.session_context import get_session_env
        value = get_session_env(name, default)
        if value is not None:
            return str(value)
    except Exception:
        pass
    return os.environ.get(name, default)


def _resolve_repo_from_tools_doc() -> Optional[str]:
    """Read Repository path from profile docs/tools.md if present.
    Returns None if tools.md is missing or has no Repository line.
    """
    try:
        profile_dir = state.get_profile_dir()
        tools_md = os.path.join(profile_dir, "docs", "tools.md")
        if not os.path.isfile(tools_md):
            return None
        with open(tools_md) as f:
            for line in f:
                stripped = line.strip()
                if stripped.startswith("- Repository:"):
                    parts = stripped.split(":", 1)
                    if len(parts) == 2:
                        repo = parts[1].strip().strip("`").strip()
                        if repo and repo.upper() not in {"TODO", "N/A", "NA"}:
                            repo = os.path.expanduser(repo)
                            if os.path.isdir(os.path.join(repo, ".git")):
                                return os.path.abspath(repo)
    except Exception:
        pass
    return None


def _resolve_repo() -> Optional[str]:
    """Resolve the target repo root, preferring JUNIE_REPO, then
    profile docs/tools.md Repository line, then cwd git root.
    Never returns a non-git directory.
    """
    repo = os.environ.get("JUNIE_REPO", "")
    if repo:
        repo = repo.strip()
        if repo and os.path.isdir(os.path.join(repo, ".git")):
            return os.path.abspath(repo)
    tools_repo = _resolve_repo_from_tools_doc()
    if tools_repo:
        return tools_repo
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            top = result.stdout.strip()
            if top:
                return top
    except Exception:
        pass
    return None


def _resolve_debug_delivery_target() -> Optional[str]:
    """Resolve a delivery target string for debug messages.
    Returns e.g. 'telegram:12345:6789' or None if runtime delivery
    context is unavailable.
    """
    try:
        platform = _session_env("HERMES_SESSION_PLATFORM", "")
        chat_id = _session_env("HERMES_SESSION_CHAT_ID", "")
        if platform and chat_id:
            thread_id = _session_env("HERMES_SESSION_THREAD_ID", "")
            target = f"{platform}:{chat_id}"
            if thread_id:
                target += f":{thread_id}"
            return target
    except Exception:
        pass
    return None


# ── autonomous_work_start handler ──

def handle_autonomous_work_start(params: dict, plugin_ctx: Any = None, **kwargs) -> str:
    try:
        return _do_start(params, plugin_ctx)
    except Exception as e:
        return json.dumps({"error": f"autonomous_work_start failed: {e}"})


def _do_start(params: dict, plugin_ctx: Any) -> str:
    duration_str = params.get("duration", "")
    duration_seconds = state.parse_duration(duration_str)
    if duration_seconds is None:
        return json.dumps({
            "error": (
                f"Invalid duration '{duration_str}': must be a positive number followed "
                "by h/hours, m/minutes, or s/seconds (e.g. '2h', '90m')."
            )
        })

    if duration_seconds < 60:
        return json.dumps({
            "error": f"Duration too short ({duration_seconds}s): minimum is 60 seconds."
        })

    max_duration = 24 * 3600
    if duration_seconds > max_duration:
        return json.dumps({
            "error": (
                f"Duration too long ({duration_seconds}s): maximum is {max_duration}s (24h)."
            )
        })

    owner_prompt = params.get("prompt", "")
    enable_debug_messages = params.get("enable_debug_messages", True)
    if not isinstance(enable_debug_messages, bool):
        enable_debug_messages = True
    owner_session_id = _session_env("HERMES_SESSION_ID", "") or None
    hermes_profile = os.environ.get("HERMES_PROFILE", "junie-live")
    repo = _resolve_repo()
    if not repo:
        return json.dumps({
            "error": (
                "Could not resolve target repo: not in a git directory and "
                "JUNIE_REPO not set."
            )
        })

    window_id = state.generate_window_id()
    window_dir = state.create_window_dir(window_id)

    window = state.make_initial_window(
        window_id=window_id,
        duration_seconds=duration_seconds,
        owner_prompt=owner_prompt,
        owner_session_id=owner_session_id,
        repo=repo,
        enable_debug_messages=enable_debug_messages,
    )

    events_path = state.get_events_path(window_dir)
    state.append_event(events_path, "window_created", {
        "window_id": window_id,
        "duration_seconds": duration_seconds,
        "owner_prompt": owner_prompt or None,
    })

    window_path = state.get_window_json_path(window_dir)
    state.atomic_write_json(window_path, window)

    spec_path = state.get_spec_json_path(window_dir)
    state.atomic_write_json(spec_path, {
        "window_id": window_id,
        "duration_seconds": duration_seconds,
        "repo": repo,
        "prompt": owner_prompt or "",
        "started_at": window.get("started_at"),
        "started_iso": window.get("started_iso"),
        "end_at": window.get("end_at"),
        "end_iso": window.get("end_iso"),
        "enable_debug_messages": enable_debug_messages,
    })

    if not state.try_acquire_active_window(window_id):
        shutil.rmtree(window_dir, ignore_errors=True)
        return json.dumps({
            "error": (
                "Another autonomous work window was started concurrently. "
                "Only one window at a time is supported."
            )
        })

    runner_pid = _start_runner(window_dir, window_id, hermes_profile, enable_debug_messages)
    if runner_pid is None:
        state.clear_active_window()
        return json.dumps({
            "error": "Failed to start AW runner script. Check runner script path and permissions."
        })

    state.update_window(window_path, {"runner_pid": runner_pid})
    state.append_event(events_path, "runner_started", {
        "runner_pid": runner_pid,
    })

    return json.dumps({
        "window_id": window_id,
        "run_dir": window_dir,
        "aw_session_id": None,
        "phase": "snapshot_preflight",
        "status": "running",
        "duration": duration_str,
        "end_at": window["end_at"],
        "enable_debug_messages": enable_debug_messages,
    })


def _start_runner(
    window_dir: str,
    window_id: str,
    profile: str,
    enable_debug_messages: bool = True,
) -> Optional[int]:
    """Start aw-runner.sh in the background. Returns PID or None."""
    runner_script = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "scripts",
        "aw-runner.sh",
    )
    if not os.path.isfile(runner_script):
        return None

    runner_env = os.environ.copy()
    runner_env["AW_WINDOW_DIR"] = window_dir
    runner_env["AW_WINDOW_ID"] = window_id
    runner_env["HERMES_PROFILE"] = profile
    runner_env["AW_ENABLE_DEBUG"] = "true" if enable_debug_messages else "false"

    delivery_target = _resolve_debug_delivery_target()
    if delivery_target:
        runner_env["AW_DEBUG_DELIVERY_TARGET"] = delivery_target

    runner_log = os.path.join(window_dir, "logs", "aw-runner.log")
    try:
        with open(runner_log, "a") as log_f:
            proc = subprocess.Popen(
                ["bash", runner_script],
                cwd=os.path.dirname(window_dir),
                env=runner_env,
                stdout=log_f,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        return proc.pid
    except Exception:
        return None


# ── autonomous_work_step handler ──

def handle_autonomous_work_step(params: dict, plugin_ctx: Any = None, **kwargs) -> str:
    try:
        return _do_step(params, plugin_ctx)
    except Exception as e:
        return json.dumps({"error": f"autonomous_work_step failed: {e}"})


def _resolve_window() -> Optional[dict]:
    """Resolve window from active_window.json, with AW_WINDOW_ID/AW_WINDOW_DIR env fallback."""
    active = state.get_active_window()
    if active is not None:
        window_id = active.get("window_id", "")
        window_dir = state.get_window_dir(window_id)
        window_path = state.get_window_json_path(window_dir)
        window = state.read_json(window_path)
        if isinstance(window, dict):
            return {"window_id": window_id, "window_dir": window_dir, "window_path": window_path, "window": window}
    # Env var fallback for runner-driven calls
    window_id = os.environ.get("AW_WINDOW_ID", "")
    window_dir_env = os.environ.get("AW_WINDOW_DIR", "")
    if window_id or window_dir_env:
        window_dir = window_dir_env or state.get_window_dir(window_id)
        window_path = state.get_window_json_path(window_dir)
        window = state.read_json(window_path)
        if isinstance(window, dict):
            window_id = window.get("window_id", window_id)
            return {"window_id": window_id, "window_dir": window_dir, "window_path": window_path, "window": window}
    return None


def _do_step(params: dict, plugin_ctx: Any) -> str:
    resolved = _resolve_window()
    if resolved is None:
        return json.dumps({
            "error": "No active autonomous work window found. Start one with autonomous_work_start first.",
            "status": "no_window",
        })

    window_id = resolved["window_id"]
    window_dir = resolved["window_dir"]
    window_path = resolved["window_path"]
    window = resolved["window"]
    events_path = state.get_events_path(window_dir)

    phase = window.get("phase", "snapshot_preflight")
    continuation = window.get("continuation", "continue_now")
    rationale = params.get("rationale", "")

    now = time.time()
    end_at = window.get("end_at", now)
    deadline_reached = now >= end_at
    cancel_path = state.get_cancel_path(window_dir)
    cancel_present = os.path.isfile(cancel_path)
    failure_count = window.get("failure_count", 0)
    failure_budget = window.get("failure_budget", 3)

    if rationale:
        state.append_event(events_path, "step_rationale", {
            "phase": phase,
            "rationale": rationale,
        })

    # ── Cancel check (highest priority) ──
    if cancel_present:
        state.update_window(window_path, {
            "phase": "cancelled",
            "continuation": "final",
            "status": "cancelled",
            "last_step_finished_at": now,
        })
        state.clear_active_window()
        state.append_event(events_path, "cancelled", {
            "phase": phase,
            "reason": "control/cancel file present",
        })
        return json.dumps({
            "window_id": window_id,
            "phase": "cancelled",
            "continuation": "final",
            "status": "cancelled",
            "instruction": "Window cancelled.",
        })

    # ── Invalid state check ──
    if phase not in state.VALID_PHASES:
        _fail_window(window, window_path, events_path, f"Invalid phase: {phase}")
        return json.dumps({
            "window_id": window_id,
            "phase": "failed",
            "continuation": "final",
            "status": "failed",
            "error": f"Invalid phase: {phase}",
        })

    if continuation not in state.VALID_CONTINUATIONS:
        _fail_window(window, window_path, events_path, f"Invalid continuation: {continuation}")
        return json.dumps({
            "window_id": window_id,
            "phase": "failed",
            "continuation": "final",
            "status": "failed",
            "error": f"Invalid continuation: {continuation}",
        })

    # ── Terminal phase guard ──
    if state.is_terminal_phase(phase):
        state.append_event(events_path, "step_refused", {
            "reason": f"Window already in terminal phase: {phase}",
        })
        return json.dumps({
            "window_id": window_id,
            "phase": phase,
            "continuation": "final",
            "status": phase,
            "error": f"Window already in terminal phase: {phase}",
        })

    # ── Apply transition table ──
    transition = _apply_transitions(
        window=window,
        window_dir=window_dir,
        window_path=window_path,
        events_path=events_path,
        deadline_reached=deadline_reached,
        phase=phase,
        failure_count=failure_count,
        failure_budget=failure_budget,
    )

    state.update_window(window_path, {
        "last_step_finished_at": time.time(),
        "last_error": transition.get("error"),
    })

    return json.dumps(transition)


def _apply_transitions(
    *,
    window: dict,
    window_dir: str,
    window_path: str,
    events_path: str,
    deadline_reached: bool,
    phase: str,
    failure_count: int,
    failure_budget: int,
) -> dict:
    window_id = window.get("window_id", "")

    # ── snapshot_preflight ──
    if phase == "snapshot_preflight":
        if deadline_reached:
            return _transition_to(
                window_path, events_path,
                phase="finalizing", continuation="continue_now",
                note="Deadline reached during snapshot_preflight",
            )

        state.append_event(events_path, "phase_transition", {
            "from": "snapshot_preflight",
            "to": "candidate_generation",
            "reason": "preflight_complete",
        })
        return _step_prompt_result(
            window_id=window_id,
            window=window,
            window_dir=window_dir,
            new_phase="candidate_generation",
            continuation="continue_now",
        )

    # ── candidate_generation ──
    if phase == "candidate_generation":
        if deadline_reached:
            return _transition_to(
                window_path, events_path,
                phase="finalizing", continuation="continue_now",
                note="Deadline reached during candidate_generation",
            )

        candidates_found = _detect_candidates(window_dir)
        if candidates_found:
            state.append_event(events_path, "phase_transition", {
                "from": "candidate_generation",
                "to": "score_and_select",
                "reason": "candidates_available",
            })
            return _step_prompt_result(
                window_id=window_id,
                window=window,
                window_dir=window_dir,
                new_phase="score_and_select",
                continuation="continue_now",
            )
        else:
            return _transition_to(
                window_path, events_path,
                phase="finalizing", continuation="continue_now",
                note="No candidates or eligible backlog items found",
            )

    # ── score_and_select ──
    if phase == "score_and_select":
        if deadline_reached:
            return _transition_to(
                window_path, events_path,
                phase="finalizing", continuation="continue_now",
                note="Deadline reached during score_and_select",
            )

        selected = _detect_selected_item(window_dir, window)
        if selected:
            selected_id = selected.get("item_id") or selected.get("id", "unknown")
            state.update_window(window_path, {
                "selected_item": selected_id,
                "selected_item_started_at": time.time(),
            })
            state.append_event(events_path, "phase_transition", {
                "from": "score_and_select",
                "to": "executing_task",
                "selected_item": selected_id,
            })
            return _step_prompt_result(
                window_id=window_id,
                window=window,
                window_dir=window_dir,
                new_phase="executing_task",
                continuation="continue_now",
                selected_item=selected_id,
            )
        else:
            return _transition_to(
                window_path, events_path,
                phase="finalizing", continuation="continue_now",
                note="No eligible item selected",
            )

    # ── executing_task ──
    if phase == "executing_task":
        terminal_outcome = _detect_terminal_selected_item_outcome(window_dir, window)
        if terminal_outcome:
            state.update_window(window_path, {
                "selected_item": None,
                "selected_item_started_at": None,
            })
            outcome = terminal_outcome.get("outcome", "done")
            if outcome in ("blocked", "failed", "needs_approval", "deferred"):
                blocked = window.get("blocked_items", [])
                blocked.append(terminal_outcome)
                state.update_window(window_path, {"blocked_items": blocked})
                if outcome == "failed":
                    new_failure_count = failure_count + 1
                    state.update_window(window_path, {"failure_count": new_failure_count})

            completed = outcome == "done"
            if completed:
                done_items = window.get("completed_items", [])
                done_items.append(terminal_outcome)
                state.update_window(window_path, {"completed_items": done_items})

            state.append_event(events_path, "phase_transition", {
                "from": "executing_task",
                "to": "record_outcome",
                "outcome": outcome,
            })
            return _step_prompt_result(
                window_id=window_id,
                window=window,
                window_dir=window_dir,
                new_phase="record_outcome",
                continuation="continue_now",
            )

        state.update_window(window_path, {"continuation": "wait_external"})
        return {
            "window_id": window_id,
            "phase": "executing_task",
            "continuation": "wait_external",
            "status": "running",
            "instruction": "Waiting for selected task to reach a terminal outcome.",
        }

    # ── record_outcome ──
    if phase == "record_outcome":
        if deadline_reached:
            return _transition_to(
                window_path, events_path,
                phase="finalizing", continuation="continue_now",
                note="Deadline reached after recording outcome",
            )

        if failure_count >= failure_budget:
            state.append_event(events_path, "failure_budget_exceeded", {
                "failure_count": failure_count,
                "failure_budget": failure_budget,
            })
            return _transition_to(
                window_path, events_path,
                phase="failed", continuation="final",
                note=f"Failure budget exceeded ({failure_count}/{failure_budget})",
            )

        return _step_prompt_result(
            window_id=window_id,
            window=window,
            window_dir=window_dir,
            new_phase="snapshot_preflight",
            continuation="continue_now",
        )

    # ── finalizing ──
    if phase == "finalizing":
        report_path = state.get_final_report_path(window_dir)
        if os.path.isfile(report_path):
            state.update_window(window_path, {
                "phase": "completed",
                "continuation": "final",
                "status": "completed",
                "report_path": report_path,
            })
            state.clear_active_window()
            state.append_event(events_path, "completed", {
                "report_path": report_path,
            })
            return {
                "window_id": window_id,
                "phase": "completed",
                "continuation": "final",
                "status": "completed",
                "instruction": "Window completed. Final report written.",
                "report_path": report_path,
            }
        else:
            return _step_prompt_result(
                window_id=window_id,
                window=window,
                window_dir=window_dir,
                new_phase="finalizing",
                continuation="continue_now",
            )

    return {
        "window_id": window_id,
        "phase": "failed",
        "continuation": "final",
        "status": "failed",
        "error": f"No transition rule for phase: {phase}",
    }


def _transition_to(
    window_path: str,
    events_path: str,
    phase: str,
    continuation: str,
    note: str = "",
) -> dict:
    updates = {
        "phase": phase,
        "continuation": continuation,
    }
    if phase == "failed":
        updates["status"] = "failed"
        state.clear_active_window()
    elif phase == "completed":
        updates["status"] = "completed"
        state.clear_active_window()
    elif phase == "cancelled":
        updates["status"] = "cancelled"
        state.clear_active_window()

    state.update_window(window_path, updates)
    state.append_event(events_path, "phase_transition", {
        "to": phase,
        "reason": note or "transition",
    })
    return {
        "phase": phase,
        "continuation": continuation,
        "status": updates.get("status", "running"),
        "note": note or None,
    }


def _step_prompt_result(
    window_id: str,
    window: dict,
    window_dir: str,
    new_phase: str,
    continuation: str,
    selected_item: Optional[str] = None,
) -> dict:
    prompt_info = prompts.build_step_prompt(
        window=window,
        window_dir=window_dir,
        phase=new_phase,
        selected_item=selected_item,
    )

    state.update_window(window_path=state.get_window_json_path(window_dir), updates={
        "phase": new_phase,
        "continuation": continuation,
        "last_step_prompt_path": prompt_info.get("prompt_path"),
    })

    state.append_event(
        state.get_events_path(window_dir),
        "step_prompt_built",
        {
            "phase": new_phase,
            "continuation": continuation,
            "selected_item": selected_item,
        },
    )

    return {
        "window_id": window_id,
        "phase": new_phase,
        "continuation": continuation,
        "status": "running",
        "instruction": prompt_info.get("instruction", "Continue autonomous work window."),
        "prompt_path": prompt_info.get("prompt_path"),
    }


# ── Artifact detection helpers ──

def _detect_candidates(window_dir: str) -> bool:
    selection_path = state.get_selection_path(window_dir)
    if os.path.isfile(selection_path):
        content = _read_text_file_safe(selection_path)
        if content:
            stripped = content.strip()
            lower = stripped.lower()
            if "candidates: none" in lower or "no_eligible" in lower:
                return False
            if "selected:" in lower or "selected_item:" in lower:
                return True
            if len(stripped) > 20:
                return True
    window_path = state.get_window_json_path(window_dir)
    window = state.read_json(window_path)
    if isinstance(window, dict):
        if window.get("selected_item"):
            return True
    # Also check Hermes backlog for candidate/validated/ready items
    try:
        if backlog.get_candidate_paths():
            return True
    except Exception:
        pass
    return False


def _detect_selected_item(window_dir: str, window: dict) -> Optional[dict]:
    selection_path = state.get_selection_path(window_dir)
    selected_id = None
    if os.path.isfile(selection_path):
        content = _read_text_file_safe(selection_path)
        if content:
            for line in content.splitlines():
                lower_line = line.strip().lower()
                if lower_line.startswith("selected_item:"):
                    selected_id = line.split(":", 1)[1].strip()
                    break
                if lower_line.startswith("selected:"):
                    selected_id = line.split(":", 1)[1].strip()
                    break
    # Fallback to window state
    if not selected_id:
        selected_id = window.get("selected_item")
    if not selected_id:
        return None
    # Validate against Hermes backlog if possible
    try:
        if backlog.get_items_dir():
            item_path = os.path.join(backlog.get_items_dir(), f"{selected_id}.md")
            if not os.path.isfile(item_path):
                item_path = os.path.join(backlog.get_items_dir(), selected_id)
                if not os.path.isfile(item_path):
                    for p in backlog.list_items():
                        if os.path.basename(p).startswith(selected_id):
                            item_path = p
                            break
    except Exception:
        pass
    return {"id": selected_id, "outcome": None}


def _detect_terminal_selected_item_outcome(window_dir: str, window: dict) -> Optional[dict]:
    result_path = state.get_last_step_result_path(window_dir)
    if os.path.isfile(result_path):
        content = _read_text_file_safe(result_path)
        if content:
            outcome = _parse_outcome_from_text(content)
            if outcome:
                return {"outcome": outcome, "path": result_path}
    return None


def _parse_outcome_from_text(text: str) -> Optional[str]:
    lines = text.strip().splitlines()
    for line in lines:
        stripped = line.strip().lower()
        for outcome in ("done", "blocked", "deferred", "needs_approval", "failed", "skipped"):
            if stripped.startswith(f"outcome: {outcome}") or stripped == outcome:
                return outcome
            if stripped.startswith(f"outcome_status={outcome}"):
                return outcome
            if stripped.startswith(f"outcome_status: {outcome}"):
                return outcome
    return None


def _read_text_file_safe(path: str) -> Optional[str]:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except Exception:
        return None


def _fail_window(window: dict, window_path: str, events_path: str, reason: str) -> None:
    state.update_window(window_path, {
        "phase": "failed",
        "continuation": "final",
        "status": "failed",
        "last_error": reason,
    })
    state.clear_active_window()
    state.append_event(events_path, "failed", {"reason": reason})

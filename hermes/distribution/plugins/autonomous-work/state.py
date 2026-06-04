"""Durable state helpers for Autonomous Work Window ledger.

Provides profile-aware path resolution, atomic JSON read/write, JSONL event
append, phase update helpers, artifact path helpers, and active-window locking.
"""

import json
import os
import re
import time
import tempfile
import fcntl
from pathlib import Path
from typing import Any, Optional


def get_hermes_home() -> str:
    env_home = os.environ.get("HERMES_HOME")
    if env_home:
        return env_home
    try:
        from hermes_constants import get_hermes_home as _sdk_home
        return str(_sdk_home())
    except (ImportError, AttributeError):
        pass
    try:
        from hermes.utils import get_hermes_home as _sdk_home
        return str(_sdk_home())
    except (ImportError, AttributeError):
        pass
    return os.path.expanduser("~/.hermes")


def get_profile_dir() -> str:
    explicit = os.environ.get("HERMES_PROFILE_DIR")
    if explicit:
        return explicit
    home = Path(get_hermes_home()).expanduser()
    profile = os.environ.get("HERMES_PROFILE", "junie-live")
    if home.name == profile and home.parent.name == "profiles":
        return str(home)
    return str(home / "profiles" / profile)


def get_aw_base() -> str:
    return os.path.join(get_profile_dir(), "junie-live", "state", "autonomous_work")


def get_window_dir(window_id: str) -> str:
    return os.path.join(get_aw_base(), "windows", window_id)


# --- Atomic JSON helpers ---

def atomic_write_json(path: str, data: Any) -> None:
    parent = os.path.dirname(path)
    os.makedirs(parent, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=parent, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2, default=str)
            f.write("\n")
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def read_json(path: str) -> Optional[Any]:
    try:
        with open(path, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None


# --- JSONL event helpers ---

def append_event(events_path: str, event_type: str, data: Optional[dict] = None) -> dict:
    event = {
        "ts": time.time(),
        "iso": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "type": event_type,
    }
    if data:
        event["data"] = data

    parent = os.path.dirname(events_path)
    os.makedirs(parent, exist_ok=True)

    line = json.dumps(event, default=str) + "\n"
    with open(events_path, "a") as f:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX)
        try:
            f.write(line)
        finally:
            fcntl.flock(f.fileno(), fcntl.LOCK_UN)

    return event


# --- Window state helpers ---

_WINDOW_ID_RE = re.compile(r"^AW-\d{8}-\d{3}$")


def is_valid_window_id(window_id: str) -> bool:
    return bool(_WINDOW_ID_RE.match(window_id))


def generate_window_id() -> str:
    now = time.strftime("%Y%m%d")
    base = get_aw_base()
    windows_base = os.path.join(base, "windows")
    highest = 0
    if os.path.isdir(windows_base):
        for entry in os.listdir(windows_base):
            m = re.match(rf"^AW-{now}-(\d{{3}})$", entry)
            if m:
                num = int(m.group(1))
                if num > highest:
                    highest = num
    return f"AW-{now}-{highest + 1:03d}"


def make_initial_window(
    window_id: str,
    duration_seconds: int,
    owner_prompt: Optional[str],
    owner_session_id: Optional[str],
    repo: str,
    enable_debug_messages: bool = True,
) -> dict:
    now_iso = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    started_at = time.time()
    end_at_ts = started_at + duration_seconds
    end_iso = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.gmtime(end_at_ts))
    return {
        "window_id": window_id,
        "status": "running",
        "phase": "snapshot_preflight",
        "continuation": "continue_now",
        "started_at": started_at,
        "started_iso": now_iso,
        "end_at": end_at_ts,
        "end_iso": end_iso,
        "duration_seconds": duration_seconds,
        "owner_session_id": owner_session_id,
        "aw_session_id": None,
        "repo": repo,
        "prompt": owner_prompt or "",
        "selected_item": None,
        "selected_item_started_at": None,
        "completed_items": [],
        "blocked_items": [],
        "failure_count": 0,
        "failure_budget": 3,
        "last_step_started_at": None,
        "last_step_finished_at": None,
        "last_step_prompt_path": None,
        "last_step_result_path": None,
        "last_error": None,
        "report_path": None,
        "enable_debug_messages": enable_debug_messages,
    }


def update_window(window_path: str, updates: dict) -> dict:
    window = read_json(window_path) or {}
    for key, value in updates.items():
        parts = key.split(".")
        target = window
        for part in parts[:-1]:
            if part not in target or not isinstance(target[part], dict):
                target[part] = {}
            target = target[part]
        target[parts[-1]] = value
    atomic_write_json(window_path, window)
    return window


# --- Active window management ---

_ACTIVE_WINDOW_LOCK = "active_window.lock"


def get_active_window() -> Optional[dict]:
    active_path = os.path.join(get_aw_base(), "active_window.json")
    return read_json(active_path)


def try_acquire_active_window(window_id: str, status: str = "running") -> bool:
    """Atomically acquire the active-window slot.
    Returns True if acquired, False if already held.
    """
    # Defensive check: refuse if active_window.json already exists (covers
    # older state or set_active_window artifacts where the lock file may be
    # missing but a window is clearly active).
    if get_active_window() is not None:
        return False
    base = get_aw_base()
    os.makedirs(base, exist_ok=True)
    lock_path = os.path.join(base, _ACTIVE_WINDOW_LOCK)
    try:
        fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        with os.fdopen(fd, "w") as f:
            data = json.dumps({
                "window_id": window_id,
                "status": status,
                "acquired_at": time.time(),
            })
            f.write(data + "\n")
        active_path = os.path.join(base, "active_window.json")
        atomic_write_json(active_path, {
            "window_id": window_id,
            "status": status,
            "updated_at": time.time(),
        })
        return True
    except FileExistsError:
        return False


def set_active_window(window_id: str, status: str = "running") -> None:
    """Set active_window.json for tests/compatibility.

    Runtime start paths should use try_acquire_active_window() for atomic
    overlap refusal. This helper intentionally mirrors the historical behavior
    and also refreshes the lock marker so clear_active_window() has one thing to
    clean up.
    """
    base = get_aw_base()
    os.makedirs(base, exist_ok=True)
    active_path = os.path.join(base, "active_window.json")
    atomic_write_json(active_path, {
        "window_id": window_id,
        "status": status,
        "updated_at": time.time(),
    })
    lock_path = os.path.join(base, _ACTIVE_WINDOW_LOCK)
    try:
        with open(lock_path, "w") as f:
            json.dump({
                "window_id": window_id,
                "status": status,
                "acquired_at": time.time(),
                "source": "set_active_window",
            }, f)
            f.write("\n")
    except OSError:
        pass


def clear_active_window() -> None:
    base = get_aw_base()
    active_path = os.path.join(base, "active_window.json")
    lock_path = os.path.join(base, _ACTIVE_WINDOW_LOCK)
    try:
        os.unlink(active_path)
    except FileNotFoundError:
        pass
    try:
        os.unlink(lock_path)
    except FileNotFoundError:
        pass


# --- Exactly-once marker ---

def marker_once(window_dir: str, marker_name: str) -> bool:
    locks_dir = os.path.join(window_dir, "locks")
    os.makedirs(locks_dir, exist_ok=True)
    marker_path = os.path.join(locks_dir, f"aw.{marker_name}")
    try:
        fd = os.open(marker_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        with os.fdopen(fd, "w") as f:
            f.write(f"{time.time()}\n")
        return True
    except FileExistsError:
        return False


# --- Window directory creation ---

def create_window_dir(window_id: str) -> str:
    window_dir = get_window_dir(window_id)
    os.makedirs(window_dir, exist_ok=True)
    os.makedirs(os.path.join(window_dir, "logs"), exist_ok=True)
    os.makedirs(os.path.join(window_dir, "control"), exist_ok=True)
    os.makedirs(os.path.join(window_dir, "locks"), exist_ok=True)
    return window_dir


# --- Artifact path helpers ---

def get_window_json_path(window_dir: str) -> str:
    return os.path.join(window_dir, "window.json")


def get_spec_json_path(window_dir: str) -> str:
    return os.path.join(window_dir, "spec.json")


def get_events_path(window_dir: str) -> str:
    return os.path.join(window_dir, "events.jsonl")


def get_step_prompt_path(window_dir: str) -> str:
    return os.path.join(window_dir, "step_prompt.md")


def get_last_step_result_path(window_dir: str) -> str:
    return os.path.join(window_dir, "last_step_result.md")


def get_selection_path(window_dir: str) -> str:
    return os.path.join(window_dir, "selection.md")


def get_final_report_path(window_dir: str) -> str:
    return os.path.join(window_dir, "final_report.md")


def get_cancel_path(window_dir: str) -> str:
    return os.path.join(window_dir, "control", "cancel")


def get_runner_lock_path(window_dir: str) -> str:
    return os.path.join(window_dir, "locks", "runner.lock")


def get_step_lock_path(window_dir: str) -> str:
    return os.path.join(window_dir, "locks", "step.lock")


# --- Duration parsing ---

_DURATION_RE = re.compile(
    r"^\s*(\d+)\s*(h|hours?|m|minutes?|s|seconds?)\s*$", re.IGNORECASE
)


def parse_duration(duration_str: str) -> Optional[int]:
    m = _DURATION_RE.match(duration_str)
    if not m:
        return None
    value = int(m.group(1))
    unit = m.group(2).lower()
    if unit.startswith("h"):
        return value * 3600
    elif unit.startswith("m"):
        return value * 60
    else:
        return value


# --- Phase/continuation validation ---

VALID_PHASES = frozenset({
    "snapshot_preflight",
    "candidate_generation",
    "score_and_select",
    "executing_task",
    "record_outcome",
    "finalizing",
    "blocked",
    "completed",
    "cancelled",
    "failed",
})

VALID_CONTINUATIONS = frozenset({
    "continue_now",
    "wait_external",
    "final",
    "blocked",
})

TERMINAL_CONTINUATIONS = frozenset({"final", "blocked"})

TERMINAL_PHASES = frozenset({"completed", "cancelled", "failed"})


def is_terminal(continuation: str) -> bool:
    return continuation in TERMINAL_CONTINUATIONS


def is_terminal_phase(phase: str) -> bool:
    return phase in TERMINAL_PHASES

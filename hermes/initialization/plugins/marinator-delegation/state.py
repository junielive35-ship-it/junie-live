"""Durable state helpers for Marinator run ledger.

Provides atomic JSON read/write, JSONL event append, status updates,
and exactly-once wake markers.
"""

import json
import os
import time
import tempfile
import fcntl
from pathlib import Path
from typing import Any, Optional


def get_hermes_home() -> str:
    """Resolve the Hermes home directory.

    Priority:
      1. HERMES_HOME environment variable (explicit test/profile override)
      2. get_hermes_home() from hermes SDK if importable
      3. ~/.hermes
    """
    env_home = os.environ.get("HERMES_HOME")
    if env_home:
        return env_home
    try:
        from hermes_constants import get_hermes_home as _sdk_home  # type: ignore
        return str(_sdk_home())
    except (ImportError, AttributeError):
        pass
    try:
        from hermes.utils import get_hermes_home as _sdk_home  # type: ignore
        return str(_sdk_home())
    except (ImportError, AttributeError):
        pass
    return os.path.expanduser("~/.hermes")


def get_profile_dir() -> str:
    """Resolve the Hermes profile directory.

    Priority:
      1. HERMES_PROFILE_DIR env var (explicit override)
      2. If get_hermes_home() already points at profiles/<profile>, use it directly.
      3. Otherwise, append profiles/<profile> to get_hermes_home().
    """
    explicit = os.environ.get("HERMES_PROFILE_DIR")
    if explicit:
        return explicit
    home = Path(get_hermes_home()).expanduser()
    profile = os.environ.get("HERMES_PROFILE", "junie-live")
    if home.name == profile and home.parent.name == "profiles":
        return str(home)
    return str(home / "profiles" / profile)


def get_marinator_base() -> str:
    """Return the base directory for Marinator state (profile-local)."""
    return os.path.join(get_profile_dir(), "junie-live", "state", "marinator")


def get_run_dir(job_id: str) -> str:
    """Return the run directory path for a given job."""
    return os.path.join(get_marinator_base(), "runs", job_id)


# --- Atomic JSON helpers ---

def atomic_write_json(path: str, data: Any) -> None:
    """Write JSON atomically using a temp file + rename."""
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
    """Read a JSON file, returning None if missing or corrupt."""
    try:
        with open(path, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None


# --- JSONL event helpers ---

def append_event(events_path: str, event_type: str, data: Optional[dict] = None) -> dict:
    """Append a timestamped event to the JSONL events file.

    Returns the event dict that was written.
    """
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


# --- Status helpers ---

def make_initial_status(
    job_id: str,
    owner_session_id: Optional[str],
    owner_session_key: Optional[str],
    runtime_mode: str,
    runtime_detected_from: dict,
    repo: str,
    run_dir: str,
    opencode_bin: Optional[str] = None,
    opencode_previous_session_id: Optional[str] = None,
    skip_permissions: bool = True,
) -> dict:
    """Create the initial status.json structure."""
    return {
        "job_id": job_id,
        "owner_session_id": owner_session_id,
        "owner_session_key": owner_session_key,
        "runtime": {
            "mode": runtime_mode,
            "detected_from": runtime_detected_from,
        },
        "repo": repo,
        "run_dir": run_dir,
        "opencode": {
            "bin": opencode_bin,
            "pid": None,
            "pgid": None,
            "exit_code": None,
            "previous_session_id": opencode_previous_session_id,
            "session_id": None,
            "skip_permissions": skip_permissions,
        },
        "worker_state": "queued",
        "attention": {
            "state": "none",
            "reason": None,
            "detected_at": None,
        },
        "wake": {
            "done_sent_at": None,
            "attention_sent_at": None,
            "last_resume_session_id": None,
            "last_error": None,
        },
    }


def update_status(status_path: str, updates: dict) -> dict:
    """Read status.json, apply shallow-merge updates, and write back atomically.

    Supports dotted keys like 'opencode.pid' for nested updates.
    Returns the updated status dict.
    """
    status = read_json(status_path) or {}

    for key, value in updates.items():
        parts = key.split(".")
        target = status
        for part in parts[:-1]:
            if part not in target or not isinstance(target[part], dict):
                target[part] = {}
            target = target[part]
        target[parts[-1]] = value

    atomic_write_json(status_path, status)
    return status


# --- Marker / exactly-once helpers ---

def marker_once(run_dir: str, marker_name: str) -> bool:
    """Create a marker file atomically. Returns True if this call created it
    (first time), False if it already existed (duplicate).

    Used for exactly-once wake event delivery.
    """
    locks_dir = os.path.join(run_dir, "locks")
    os.makedirs(locks_dir, exist_ok=True)
    marker_path = os.path.join(locks_dir, f"wake.{marker_name}")

    try:
        fd = os.open(marker_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        with os.fdopen(fd, "w") as f:
            f.write(f"{time.time()}\n")
        return True
    except FileExistsError:
        return False


# --- Run directory creation ---

def create_run_dir(job_id: str) -> str:
    """Create the full run directory structure for a job.

    Returns the run_dir path.
    """
    run_dir = get_run_dir(job_id)

    os.makedirs(run_dir, exist_ok=True)
    os.makedirs(os.path.join(run_dir, "control"), exist_ok=True)
    os.makedirs(os.path.join(run_dir, "locks"), exist_ok=True)

    return run_dir


def write_prompt(run_dir: str, prompt_file: str) -> str:
    """Copy or write the prompt file into the run directory.

    Returns the path to the prompt.md in the run_dir.
    """
    dest = os.path.join(run_dir, "prompt.md")
    if os.path.isfile(prompt_file):
        import shutil
        shutil.copy2(prompt_file, dest)
    else:
        with open(dest, "w") as f:
            f.write(f"# Prompt\n\n{prompt_file}\n")
    return dest

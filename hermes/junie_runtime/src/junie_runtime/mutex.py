import json
import os
import shutil
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any


@dataclass
class MutexStatus:
    state: str
    holder_data: dict[str, Any] | None = None


@dataclass
class MutexLease:
    holder_id: str
    mutex_dir: str


@dataclass
class ReleaseResult:
    state: str
    was_held: bool
    mismatch: bool = False
    current_holder: str | None = None


@dataclass
class StaleResult:
    state: str
    is_stale: bool | None = None
    age_minutes: int | None = None
    reason: str | None = None
    recovered: bool = False
    is_broken: bool = False


def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _holder_file(mutex_dir: str) -> str:
    return os.path.join(mutex_dir, "holder.json")


def status(mutex_dir: str) -> MutexStatus:
    if not os.path.isdir(mutex_dir):
        return MutexStatus(state="FREE")
    hf = _holder_file(mutex_dir)
    if os.path.isfile(hf):
        try:
            with open(hf) as f:
                data = json.load(f)
            return MutexStatus(state="HELD", holder_data=data)
        except (json.JSONDecodeError, OSError):
            return MutexStatus(state="HELD")
    return MutexStatus(state="BROKEN")


class MutexHeldError(Exception):
    def __init__(self, mutex_status: MutexStatus) -> None:
        self.mutex_status = mutex_status
        super().__init__(f"Mutex is {mutex_status.state}")


def acquire(
    mutex_dir: str,
    holder_id: str,
    reason: str,
    repo: str | None = None,
    branch: str | None = None,
) -> MutexLease:
    try:
        os.makedirs(mutex_dir, exist_ok=False)
    except FileExistsError:
        raise MutexHeldError(status(mutex_dir))
    hf = _holder_file(mutex_dir)
    data = {
        "holder_id": holder_id,
        "reason": reason,
        "repo": repo or "",
        "branch": branch or "",
        "started_at": now_utc(),
        "updated_at": now_utc(),
        "pid": os.getpid(),
    }
    with open(hf, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    return MutexLease(holder_id=holder_id, mutex_dir=mutex_dir)


def release(
    mutex_dir: str,
    holder_id: str | None = None,
    force: bool = False,
) -> ReleaseResult:
    if not os.path.isdir(mutex_dir):
        return ReleaseResult(state="FREE", was_held=False)
    hf = _holder_file(mutex_dir)
    if holder_id and not force and os.path.isfile(hf):
        try:
            with open(hf) as f:
                data = json.load(f)
            current_holder = data.get("holder_id", "")
            if current_holder and current_holder != holder_id:
                return ReleaseResult(
                    state="HELD",
                    was_held=True,
                    mismatch=True,
                    current_holder=current_holder,
                )
        except (json.JSONDecodeError, OSError):
            pass
    shutil.rmtree(mutex_dir)
    return ReleaseResult(state="RELEASED", was_held=True)


def check_stale(
    mutex_dir: str,
    stale_minutes: int = 30,
    auto_recover: bool = False,
) -> StaleResult:
    if not os.path.isdir(mutex_dir):
        return StaleResult(state="FREE")
    hf = _holder_file(mutex_dir)
    if not os.path.isfile(hf):
        if auto_recover:
            shutil.rmtree(mutex_dir, ignore_errors=True)
            return StaleResult(
                state="HELD",
                is_broken=True,
                reason="mutex directory exists but no holder metadata",
                recovered=True,
            )
        return StaleResult(
            state="HELD",
            is_broken=True,
            reason="mutex directory exists but no holder metadata",
        )
    mtime = os.path.getmtime(hf)
    now_epoch = time.time()
    age_minutes = int((now_epoch - mtime) / 60)
    if age_minutes > stale_minutes:
        reason = f"mutex held for {age_minutes} minutes (threshold: {stale_minutes})"
        return StaleResult(
            state="HELD",
            is_stale=True,
            age_minutes=age_minutes,
            reason=reason,
        )
    return StaleResult(state="HELD", is_stale=False, age_minutes=age_minutes)

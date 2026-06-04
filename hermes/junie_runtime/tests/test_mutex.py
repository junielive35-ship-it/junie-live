import json
import os
import subprocess
import sys
import tempfile
import time

import pytest

from junie_runtime import mutex

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def holder_json(mutex_dir: str) -> dict:
    with open(os.path.join(mutex_dir, "holder.json")) as f:
        return json.load(f)


def test_acquire_success() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        lease = mutex.acquire(md, "test-holder", "testing")
        assert lease.holder_id == "test-holder"
        assert os.path.isdir(md)
        assert os.path.isfile(os.path.join(md, "holder.json"))
        data = holder_json(md)
        assert data["holder_id"] == "test-holder"
        assert data["reason"] == "testing"


def test_acquire_fails_when_held() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        mutex.acquire(md, "holder-a", "first")
        with pytest.raises(mutex.MutexHeldError) as exc:
            mutex.acquire(md, "holder-b", "second")
        assert exc.value.mutex_status.state == "HELD"
        data = exc.value.mutex_status.holder_data
        assert data is not None
        assert data["holder_id"] == "holder-a"


def test_acquire_metadata() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        mutex.acquire(md, "test", "my reason", repo="/repo/path", branch="feat/x")
        data = holder_json(md)
        assert data["repo"] == "/repo/path"
        assert data["branch"] == "feat/x"
        assert "started_at" in data
        assert "updated_at" in data
        assert "pid" in data


def test_status_free() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        s = mutex.status(md)
        assert s.state == "FREE"
        assert s.holder_data is None


def test_status_held() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        mutex.acquire(md, "holder-x", "test")
        s = mutex.status(md)
        assert s.state == "HELD"
        assert s.holder_data is not None
        assert s.holder_data["holder_id"] == "holder-x"


def test_status_broken() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        os.makedirs(md)
        s = mutex.status(md)
        assert s.state == "BROKEN"
        assert s.holder_data is None


def test_release_matching_holder() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        mutex.acquire(md, "holder-y", "test")
        result = mutex.release(md, holder_id="holder-y")
        assert result.state == "RELEASED"
        assert result.was_held
        assert not result.mismatch
        assert not os.path.isdir(md)


def test_release_mismatched_holder() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        mutex.acquire(md, "holder-z", "test")
        result = mutex.release(md, holder_id="wrong-holder")
        assert result.mismatch
        assert result.current_holder == "holder-z"
        assert os.path.isdir(md)


def test_release_mismatched_holder_with_force() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        mutex.acquire(md, "holder-z", "test")
        result = mutex.release(md, holder_id="wrong-holder", force=True)
        assert result.state == "RELEASED"
        assert not result.mismatch
        assert not os.path.isdir(md)


def test_release_not_held() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        result = mutex.release(md)
        assert result.state == "FREE"
        assert not result.was_held


def test_release_without_holder_id() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        mutex.acquire(md, "any", "test")
        result = mutex.release(md)
        assert result.state == "RELEASED"
        assert not os.path.isdir(md)


def test_stale_mutex_detection() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        mutex.acquire(md, "stale-holder", "test")
        hf = os.path.join(md, "holder.json")
        old_time = time.time() - 3600
        os.utime(hf, (old_time, old_time))
        result = mutex.check_stale(md, stale_minutes=30)
        assert result.is_stale is True
        assert result.is_broken is False
        assert result.age_minutes is not None and result.age_minutes >= 60


def test_non_stale_mutex() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        mutex.acquire(md, "fresh-holder", "test")
        result = mutex.check_stale(md, stale_minutes=30)
        assert result.is_stale is False
        assert not result.is_broken


def test_broken_mutex_no_auto_recover() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        os.makedirs(md)
        result = mutex.check_stale(md, stale_minutes=30, auto_recover=False)
        assert result.is_broken
        assert not result.recovered
        assert result.reason is not None
        assert os.path.isdir(md)


def test_auto_recover_broken_mutex() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        os.makedirs(md)
        result = mutex.check_stale(md, stale_minutes=30, auto_recover=True)
        assert result.is_broken
        assert result.recovered
        assert not os.path.isdir(md)


def test_auto_recover_does_not_remove_stale_holder() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        mutex.acquire(md, "holder", "test")
        hf = os.path.join(md, "holder.json")
        old_time = time.time() - 3600
        os.utime(hf, (old_time, old_time))
        result = mutex.check_stale(md, stale_minutes=30, auto_recover=True)
        assert result.is_stale is True
        assert not result.recovered
        assert os.path.isdir(md)
        assert os.path.isfile(hf)


def test_check_stale_free() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        result = mutex.check_stale(md)
        assert result.state == "FREE"
        assert result.is_stale is None


def test_release_allows_any_holder_when_holder_id_none(tmp_path):
    md = os.path.join(tmp_path, "code_mutex")
    mutex.acquire(md, "some-holder", "reason")
    result = mutex.release(md, holder_id=None)
    assert result.state == "RELEASED"
    assert not os.path.isdir(md)


def test_mutex_held_error_holder_data(tmp_path):
    md = os.path.join(tmp_path, "code_mutex")
    mutex.acquire(md, "first", "reason")
    try:
        mutex.acquire(md, "second", "reason")
    except mutex.MutexHeldError as e:
        assert e.mutex_status.state in ("HELD", "BROKEN")
        assert e.mutex_status.holder_data is not None


def test_broken_without_holder_json(tmp_path):
    md = os.path.join(tmp_path, "code_mutex")
    os.makedirs(md)
    s = mutex.status(md)
    assert s.state == "BROKEN"


# ── CLI wrapper compatibility tests ──

CLI_MODULE = "junie_runtime.cli.mutex"


def _cli(*args: str, mutex_dir: str | None = None) -> subprocess.CompletedProcess:
    cmd = [sys.executable, "-m", CLI_MODULE] + list(args)
    if mutex_dir is not None:
        cmd.extend(["--mutex-dir", mutex_dir])
    return subprocess.run(cmd, capture_output=True, text=True, timeout=10)


def _shell_wrapper(*args: str, mutex_dir: str | None = None) -> subprocess.CompletedProcess:
    script = os.path.join(ROOT, "distribution", "scripts", "code-mutex.sh")
    cmd = [script] + list(args)
    if mutex_dir is not None:
        cmd.extend(["--mutex-dir", mutex_dir])
    env = {**os.environ}
    if mutex_dir is not None:
        env["JUNIE_STATE_DIR"] = os.path.dirname(mutex_dir)
    return subprocess.run(cmd, capture_output=True, text=True, timeout=10, env=env)


def test_cli_status_free() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        r = _cli("status", mutex_dir=md)
        assert r.returncode == 0
        assert "mutex=FREE" in r.stdout


def test_cli_status_held() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        mutex.acquire(md, "cli-holder", "testing")
        r = _cli("status", mutex_dir=md)
        assert r.returncode == 0
        assert "mutex=HELD" in r.stdout
        assert "cli-holder" in r.stdout


def test_cli_status_broken() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        os.makedirs(md)
        r = _cli("status", mutex_dir=md)
        assert r.returncode != 0
        assert "mutex=BROKEN" in r.stdout


def test_cli_acquire_success() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        r = _cli("acquire", "--holder", "test", "--reason", "testing", mutex_dir=md)
        assert r.returncode == 0
        assert "mutex=ACQUIRED" in r.stdout
        assert "holder_id=test" in r.stdout
        assert os.path.isfile(os.path.join(md, "holder.json"))


def test_cli_acquire_already_held() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        mutex.acquire(md, "existing", "first")
        r = _cli("acquire", "--holder", "second", "--reason", "second", mutex_dir=md)
        assert r.returncode != 0
        assert "already_held" in r.stdout or "HELD" in r.stdout


def test_cli_acquire_missing_holder() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        r = _cli("acquire", "--reason", "testing", mutex_dir=md)
        assert r.returncode != 0
        assert "ERROR" in r.stderr or "ERROR" in r.stdout


def test_cli_release_matching() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        mutex.acquire(md, "owner", "test")
        r = _cli("release", "--holder", "owner", mutex_dir=md)
        assert r.returncode == 0
        assert "mutex=RELEASED" in r.stdout
        assert not os.path.isdir(md)


def test_cli_release_mismatch() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        mutex.acquire(md, "owner", "test")
        r = _cli("release", "--holder", "wrong", mutex_dir=md)
        assert r.returncode != 0
        assert "holder_mismatch" in r.stdout


def test_cli_release_mismatch_force() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        mutex.acquire(md, "owner", "test")
        r = _cli("release", "--holder", "wrong", "--force", mutex_dir=md)
        assert r.returncode == 0
        assert "mutex=RELEASED" in r.stdout


def test_cli_release_not_held() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        r = _cli("release", mutex_dir=md)
        assert r.returncode == 0
        assert "was_not_held" in r.stdout


def test_cli_check_stale_free() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        r = _cli("check-stale", mutex_dir=md)
        assert r.returncode == 0
        assert "mutex=FREE" in r.stdout


def test_cli_check_stale_held_not_stale() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        mutex.acquire(md, "fresh", "test")
        r = _cli("check-stale", "--stale-minutes", "30", mutex_dir=md)
        assert r.returncode == 0
        assert "stale=NO" in r.stdout


def test_cli_check_stale_stale() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        mutex.acquire(md, "old", "test")
        hf = os.path.join(md, "holder.json")
        old_time = time.time() - 3600
        os.utime(hf, (old_time, old_time))
        r = _cli("check-stale", "--stale-minutes", "30", mutex_dir=md)
        assert r.returncode != 0
        assert "stale=YES" in r.stdout


def test_cli_check_stale_broken_no_recover() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        os.makedirs(md)
        r = _cli("check-stale", "--stale-minutes", "30", mutex_dir=md)
        assert r.returncode != 0
        assert "stale=BROKEN" in r.stdout
        assert os.path.isdir(md)


def test_cli_check_stale_broken_auto_recover() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        os.makedirs(md)
        r = _cli("check-stale", "--stale-minutes", "30", "--auto-recover", mutex_dir=md)
        assert r.returncode == 0
        assert "recovered=BROKEN" in r.stdout
        assert not os.path.isdir(md)


def test_shell_wrapper_status_free() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        r = _shell_wrapper("status", mutex_dir=md)
        assert r.returncode == 0
        assert "mutex=FREE" in r.stdout


def test_shell_wrapper_status_held() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        mutex.acquire(md, "shell-holder", "testing")
        r = _shell_wrapper("status", mutex_dir=md)
        assert r.returncode == 0
        assert "mutex=HELD" in r.stdout
        assert "shell-holder" in r.stdout


def test_shell_wrapper_acquire() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        r = _shell_wrapper("acquire", "--holder", "sh-test", "--reason", "testing", mutex_dir=md)
        assert r.returncode == 0
        assert "mutex=ACQUIRED" in r.stdout
        assert os.path.isfile(os.path.join(md, "holder.json"))
        data = json.load(open(os.path.join(md, "holder.json")))
        assert data["holder_id"] == "sh-test"


def test_shell_wrapper_acquire_already_held() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        mutex.acquire(md, "existing", "first")
        r = _shell_wrapper("acquire", "--holder", "second", "--reason", "second", mutex_dir=md)
        assert r.returncode != 0
        assert "already_held" in r.stdout


def test_shell_wrapper_release_matching() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        mutex.acquire(md, "owner", "test")
        r = _shell_wrapper("release", "--holder", "owner", mutex_dir=md)
        assert r.returncode == 0
        assert "mutex=RELEASED" in r.stdout
        assert not os.path.isdir(md)


def test_shell_wrapper_release_mismatch() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        mutex.acquire(md, "owner", "test")
        r = _shell_wrapper("release", "--holder", "wrong", mutex_dir=md)
        assert r.returncode != 0
        assert "holder_mismatch" in r.stdout


def test_shell_wrapper_check_stale_not_stale() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        md = os.path.join(tmp, "code_mutex")
        mutex.acquire(md, "fresh", "test")
        r = _shell_wrapper("check-stale", "--stale-minutes", "30", mutex_dir=md)
        assert r.returncode == 0
        assert "stale=NO" in r.stdout

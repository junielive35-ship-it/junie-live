import importlib.util
import json
import os
import stat
import sys
import types
from pathlib import Path

import pytest


PLUGIN_DIR = Path(__file__).resolve().parents[1]


def load_worker_package():
    pkg = types.ModuleType("sr_plugin_tests")
    pkg.__path__ = [str(PLUGIN_DIR)]
    sys.modules["sr_plugin_tests"] = pkg
    for name in ("state", "worker"):
        spec = importlib.util.spec_from_file_location(
            f"sr_plugin_tests.{name}", PLUGIN_DIR / f"{name}.py"
        )
        module = importlib.util.module_from_spec(spec)
        sys.modules[f"sr_plugin_tests.{name}"] = module
        spec.loader.exec_module(module)
    return sys.modules["sr_plugin_tests.state"], sys.modules["sr_plugin_tests.worker"]


state, worker = load_worker_package()


def write_jsonl(path, rows):
    with open(path, "w", encoding="utf-8") as fh:
        for row in rows:
            if isinstance(row, str):
                fh.write(row + "\n")
            else:
                fh.write(json.dumps(row) + "\n")


def test_read_spec_requires_core_fields(tmp_path):
    spec_path = tmp_path / "spec.json"
    spec_path.write_text(json.dumps({"repo": "/tmp"}), encoding="utf-8")

    with pytest.raises(ValueError, match="prompt_file, opencode_bin"):
        worker.read_spec(str(spec_path))

    complete = {"repo": "/tmp", "prompt_file": "/tmp/prompt.md", "opencode_bin": "/bin/true"}
    spec_path.write_text(json.dumps(complete), encoding="utf-8")
    assert worker.read_spec(str(spec_path)) == complete


def test_status_nested_update_and_event_append(tmp_path):
    status_path = tmp_path / "status.json"
    events_path = tmp_path / "events.jsonl"
    state.atomic_write_json(str(status_path), {"opencode": {"pid": None}})

    updated = state.update_status(str(status_path), {"opencode.session_id": "ses_ABC", "worker_state": "running"})
    event = state.append_event(str(events_path), "opencode_starting", {"job_id": "j1", "exit_code": 0})

    assert updated["opencode"]["session_id"] == "ses_ABC"
    assert updated["worker_state"] == "running"
    written = json.loads(events_path.read_text(encoding="utf-8").strip())
    assert written["type"] == "opencode_starting"
    assert written["data"] == {"job_id": "j1", "exit_code": 0}
    assert event["type"] == "opencode_starting"


def test_extract_session_id_from_ndjson(tmp_path):
    stdout_log = tmp_path / "stdout.log"
    write_jsonl(stdout_log, [
        "not-json",
        {"sessionID": "bad"},
        {"sessionID": "ses_FIRST", "type": "start"},
        {"sessionID": "ses_LAST123", "type": "text"},
    ])

    assert worker.extract_session_id(str(stdout_log)) == "ses_LAST123"


def test_extract_assistant_text_from_ndjson(tmp_path):
    stdout_log = tmp_path / "stdout.log"
    write_jsonl(stdout_log, [
        {"type": "text", "part": {"type": "text", "text": "first"}},
        {"type": "text", "part": {"type": "tool", "text": "ignored"}},
        {"type": "text", "part": {"type": "text", "text": "second"}},
    ])

    assert worker.extract_assistant_text(str(stdout_log)) == "first\nsecond"


def test_verdict_preservation_and_synthesis():
    preserved = worker.normalize_verdict(
        "body\nVERDICT: pr-ready\nSUMMARY: Done\nUSER_MESSAGE: Ship it\nPR_URL: https://example/pr/1",
        0,
    )
    assert preserved == {
        "VERDICT": "pr-ready",
        "SUMMARY": "Done",
        "USER_MESSAGE": "Ship it",
        "PR_URL": "https://example/pr/1",
    }

    assert worker.normalize_verdict("no block", 3)["VERDICT"] == "failed"
    assert worker.normalize_verdict("PR_URL: https://example/pr/2", 0)["VERDICT"] == "pr-ready"
    assert worker.normalize_verdict("no pr", 0)["VERDICT"] == "needs-input"


def test_run_writes_artifacts_with_fake_opencode(tmp_path, monkeypatch):
    run_dir = tmp_path / "run"
    repo = tmp_path / "repo"
    repo.mkdir()
    prompt = run_dir / "prompt.md"
    run_dir.mkdir()
    prompt.write_text("do work", encoding="utf-8")
    state.atomic_write_json(str(run_dir / "status.json"), state.make_initial_status("job1", "task1", str(repo), str(run_dir), None))

    fake = tmp_path / "opencode"
    fake.write_text(
        "#!/usr/bin/env bash\n"
        "printf '%s\n' '{\"sessionID\":\"ses_FAKE123\",\"type\":\"start\"}'\n"
        "printf '%s\n' '{\"type\":\"text\",\"part\":{\"type\":\"text\",\"text\":\"Did work.\\nVERDICT: pr-ready\\nSUMMARY: Implemented X\\nUSER_MESSAGE: All done.\\nPR_URL: https://example/pr/9\"}}'\n"
        "exit 0\n",
        encoding="utf-8",
    )
    fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
    monkeypatch.setenv("OPENCODE_MODEL", "test-model")

    exit_code = worker.run_coding_task_from_spec(
        str(run_dir),
        "job1",
        {"repo": str(repo), "prompt_file": str(prompt), "opencode_bin": str(fake)},
    )

    assert exit_code == 0
    result = (run_dir / "result.md").read_text(encoding="utf-8")
    status = json.loads((run_dir / "status.json").read_text(encoding="utf-8"))
    events = [json.loads(line) for line in (run_dir / "events.jsonl").read_text(encoding="utf-8").splitlines()]

    assert "VERDICT: pr-ready" in result
    assert "https://example/pr/9" in result
    assert status["worker_state"] == "completed"
    assert status["opencode"]["session_id"] == "ses_FAKE123"
    assert status["opencode"]["exit_code"] == 0
    assert [event["type"] for event in events] == ["opencode_starting", "opencode_exited"]
    assert (run_dir / "opencode.stdout.log").is_file()
    assert (run_dir / "opencode.stderr.log").is_file()
    assert (run_dir / "runner.log").is_file()

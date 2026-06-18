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

    with pytest.raises(ValueError, match="prompt_file, junie_bin"):
        worker.read_spec(str(spec_path))

    complete = {"repo": "/tmp", "prompt_file": "/tmp/prompt.md", "junie_bin": "/bin/true"}
    spec_path.write_text(json.dumps(complete), encoding="utf-8")
    assert worker.read_spec(str(spec_path)) == complete


def test_status_nested_update_and_event_append(tmp_path):
    status_path = tmp_path / "status.json"
    events_path = tmp_path / "events.jsonl"
    state.atomic_write_json(str(status_path), {"junie": {"pid": None}})

    updated = state.update_status(str(status_path), {"junie.exit_code": 0, "worker_state": "running"})
    event = state.append_event(str(events_path), "junie_starting", {"job_id": "j1", "exit_code": 0})

    assert updated["junie"]["exit_code"] == 0
    assert updated["worker_state"] == "running"
    written = json.loads(events_path.read_text(encoding="utf-8").strip())
    assert written["type"] == "junie_starting"
    assert written["data"] == {"job_id": "j1", "exit_code": 0}
    assert event["type"] == "junie_starting"


def test_extract_assistant_text_from_ndjson(tmp_path):
    stdout_log = tmp_path / "stdout.log"
    write_jsonl(stdout_log, [
        {"type": "text", "part": {"type": "text", "text": "first"}},
        {"type": "text", "part": {"type": "tool", "text": "ignored"}},
        {"type": "text", "part": {"type": "text", "text": "second"}},
    ])

    assert worker.extract_assistant_text(str(stdout_log)) == "first\nsecond"


def test_extract_assistant_text_prefers_result_event(tmp_path):
    stdout_log = tmp_path / "stdout.log"
    write_jsonl(stdout_log, [
        {"type": "session"},
        {"type": "step", "name": "TASK RESULT:", "details": "step summary"},
        {"type": "text", "part": {"type": "text", "text": "legacy text"}},
        {"type": "result", "result": "result summary", "changes": []},
    ])

    assert worker.extract_assistant_text(str(stdout_log)) == "result summary"


def test_extract_assistant_text_task_result_step_fallback(tmp_path):
    stdout_log = tmp_path / "stdout.log"
    write_jsonl(stdout_log, [
        {"type": "session"},
        {"type": "step", "name": "TASK RESULT:", "details": "step summary"},
    ])

    assert worker.extract_assistant_text(str(stdout_log)) == "step summary"


def test_extract_assistant_text_strips_ansi_plain_text(tmp_path):
    stdout_log = tmp_path / "stdout.log"
    stdout_log.write_text(
        "\x1b[38;5;247mImplemented X\x1b[0m\nAll tests pass\n",
        encoding="utf-8",
    )

    text = worker.extract_assistant_text(str(stdout_log))
    assert text == "Implemented X\nAll tests pass"


def test_run_writes_artifacts_with_fake_junie(tmp_path):
    run_dir = tmp_path / "run"
    repo = tmp_path / "repo"
    repo.mkdir()
    prompt = run_dir / "prompt.md"
    run_dir.mkdir()
    prompt.write_text("do work", encoding="utf-8")
    state.atomic_write_json(str(run_dir / "status.json"), state.make_initial_status("job1", "task1", str(repo), str(run_dir), None))

    auth_file = tmp_path / "junie.key"
    auth_file.write_text("fake-key", encoding="utf-8")

    fake = tmp_path / "junie"
    fake.write_text(
        "#!/usr/bin/env bash\n"
        "printf '%s\n' \"$@\" > args.txt\n"
        "printf '%s\\n' '{\"type\":\"result\",\"result\":\"Implemented X. PR: https://example/pr/9\"}'\n"
        "exit 0\n",
        encoding="utf-8",
    )
    fake.chmod(fake.stat().st_mode | stat.S_IXUSR)

    exit_code = worker.run_coding_task_from_spec(
        str(run_dir),
        "job1",
        {"repo": str(repo), "prompt_file": str(prompt), "junie_bin": str(fake), "auth_file": str(auth_file), "model": "opus"},
    )

    assert exit_code == 0
    result = (run_dir / "result.md").read_text(encoding="utf-8")
    status = json.loads((run_dir / "status.json").read_text(encoding="utf-8"))
    events = [json.loads(line) for line in (run_dir / "events.jsonl").read_text(encoding="utf-8").splitlines()]

    # The runner writes the raw executor response and runner state; it does not
    # emit a structured verdict block.
    assert "Implemented X" in result
    assert "https://example/pr/9" in result
    assert "runner_state: completed" in result
    assert status["worker_state"] == "completed"
    assert status["junie"]["model"] == "opus"
    assert status["junie"]["exit_code"] == 0
    assert [event["type"] for event in events] == ["junie_starting", "junie_exited"]
    args_text = (repo / "args.txt").read_text(encoding="utf-8")
    assert "--auth=fake-key" in args_text
    assert "--model\nopus" in args_text
    assert "--output-format=json-stream" in args_text
    assert "--skip-update-check" in args_text
    assert (run_dir / "junie.stdout.log").is_file()
    assert (run_dir / "junie.stderr.log").is_file()
    assert (run_dir / "runner.log").is_file()


def test_run_preserves_raw_response(tmp_path):
    run_dir = tmp_path / "run"
    repo = tmp_path / "repo"
    repo.mkdir()
    prompt = run_dir / "prompt.md"
    run_dir.mkdir()
    prompt.write_text("do work", encoding="utf-8")
    state.atomic_write_json(str(run_dir / "status.json"), state.make_initial_status("job2", "task2", str(repo), str(run_dir), None))

    auth_file = tmp_path / "junie.key"
    auth_file.write_text("fake-key", encoding="utf-8")

    raw = "I investigated the bug and added a guard, but the integration test is still flaky."
    fake = tmp_path / "junie"
    fake.write_text(
        "#!/usr/bin/env bash\n"
        f"printf '%s\\n' '{{\"type\":\"result\",\"result\":\"{raw}\"}}'\n"
        "exit 0\n",
        encoding="utf-8",
    )
    fake.chmod(fake.stat().st_mode | stat.S_IXUSR)

    exit_code = worker.run_coding_task_from_spec(
        str(run_dir),
        "job2",
        {"repo": str(repo), "prompt_file": str(prompt), "junie_bin": str(fake), "auth_file": str(auth_file), "model": "opus"},
    )

    assert exit_code == 0
    result = (run_dir / "result.md").read_text(encoding="utf-8")
    status = json.loads((run_dir / "status.json").read_text(encoding="utf-8"))

    # Raw Junie final response is preserved verbatim in result.md; the runner
    # makes no semantic decision and emits no verdict.
    assert raw in result
    assert status["worker_state"] == "completed"


def test_run_nonzero_exit_sets_failed_state(tmp_path):
    run_dir = tmp_path / "run"
    repo = tmp_path / "repo"
    repo.mkdir()
    prompt = run_dir / "prompt.md"
    run_dir.mkdir()
    prompt.write_text("do work", encoding="utf-8")
    state.atomic_write_json(str(run_dir / "status.json"), state.make_initial_status("job3", "task3", str(repo), str(run_dir), None))

    auth_file = tmp_path / "junie.key"
    auth_file.write_text("fake-key", encoding="utf-8")

    fake = tmp_path / "junie"
    fake.write_text(
        "#!/usr/bin/env bash\n"
        "printf '%s\\n' '{\"type\":\"result\",\"result\":\"boom\"}'\n"
        "exit 3\n",
        encoding="utf-8",
    )
    fake.chmod(fake.stat().st_mode | stat.S_IXUSR)

    exit_code = worker.run_coding_task_from_spec(
        str(run_dir),
        "job3",
        {"repo": str(repo), "prompt_file": str(prompt), "junie_bin": str(fake), "auth_file": str(auth_file), "model": "opus"},
    )

    assert exit_code == 3
    result = (run_dir / "result.md").read_text(encoding="utf-8")
    status = json.loads((run_dir / "status.json").read_text(encoding="utf-8"))

    assert "runner_state: failed" in result
    assert status["worker_state"] == "failed"
    assert status["junie"]["exit_code"] == 3

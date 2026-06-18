"""Junie CLI execution and artifact writing for the Senior runner."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

try:
    from . import state
except ImportError:  # pragma: no cover - used by the compatibility shell wrapper.
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import state  # type: ignore


_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
_DEFAULT_JUNIE_MODEL = "claude-opus-4.8"
_DEFAULT_JUNIE_AUTH_FILE = "~/junie.key"


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def read_spec(spec_path: str) -> dict[str, Any]:
    try:
        with open(spec_path, "r", encoding="utf-8") as fh:
            spec = json.load(fh)
    except FileNotFoundError as exc:
        raise ValueError(f"spec.json not found: {spec_path}") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f"spec.json is not valid JSON: {spec_path}") from exc

    missing = [key for key in ("repo", "prompt_file", "junie_bin") if not spec.get(key)]
    if missing:
        raise ValueError(f"spec.json missing required field(s): {', '.join(missing)}")
    return spec


def extract_assistant_text(stdout_log: str) -> str:
    result_text = ""
    task_result_text = ""
    parts = []
    for ev in _iter_ndjson(stdout_log):
        ev_type = ev.get("type")
        if ev_type == "result":
            result = ev.get("result")
            if isinstance(result, str) and result.strip():
                result_text = result
        elif ev_type == "step":
            if ev.get("name") == "TASK RESULT:":
                details = ev.get("details")
                if isinstance(details, str) and details.strip():
                    task_result_text = details
        elif ev_type == "text":
            part = ev.get("part", {})
            if isinstance(part, dict) and part.get("type") == "text" and part.get("text"):
                parts.append(str(part["text"]))
    if result_text:
        return result_text
    if task_result_text:
        return task_result_text
    if parts:
        return "\n".join(parts)
    return _strip_ansi(_tail(stdout_log, 500)).strip()


def run_from_spec(run_dir: str, job_id: str, spec_path: str) -> int:
    spec = read_spec(spec_path)
    return run_coding_task_from_spec(run_dir, job_id, spec)


def run_coding_task_from_spec(run_dir: str, job_id: str, spec: dict[str, Any]) -> int:
    repo = str(spec["repo"])
    prompt_file = str(spec["prompt_file"])
    junie_bin = str(spec["junie_bin"])
    model = str(spec.get("model") or os.environ.get("JUNIE_SENIOR_MODEL") or _DEFAULT_JUNIE_MODEL)
    auth_file = str(spec.get("auth_file") or os.environ.get("JUNIE_SENIOR_AUTH_FILE") or _DEFAULT_JUNIE_AUTH_FILE)
    paths = _artifact_paths(run_dir)
    os.makedirs(run_dir, exist_ok=True)
    for path in (paths["stdout"], paths["stderr"], paths["runner"], paths["events"]):
        Path(path).touch()

    if not os.path.isdir(repo):
        return _fail_preflight(paths, job_id, 66, "repo_not_found", {"repo": repo})
    if not os.path.isfile(prompt_file):
        return _fail_preflight(paths, job_id, 66, "prompt_file_not_found", {"prompt_file": prompt_file})
    if not _is_executable(junie_bin):
        return _fail_preflight(paths, job_id, 69, "junie_not_found", {"junie_bin": junie_bin})

    with open(prompt_file, "r", encoding="utf-8") as fh:
        prompt = fh.read()
    try:
        auth_value = _read_auth_value(auth_file)
    except OSError as exc:
        return _fail_preflight(paths, job_id, 70, "junie_auth_file_unreadable", {"auth_file": auth_file, "error": str(exc)})
    if not auth_value:
        return _fail_preflight(paths, job_id, 70, "junie_auth_file_empty", {"auth_file": auth_file})
    args = [junie_bin, f"--auth={auth_value}", "--model", model, "--output-format=json-stream", "--skip-update-check", prompt]

    _log_runner(paths["runner"], f"Starting junie (sync): model={model} auth_file={auth_file} {junie_bin}")
    state.update_status(paths["status"], {"worker_state": "running", "junie.bin": junie_bin, "junie.model": model, "junie.auth_file": auth_file})
    state.append_event(paths["events"], "junie_starting", {"job_id": job_id, "junie_bin": junie_bin, "model": model, "auth_file": auth_file, "repo": repo})
    with open(paths["stdout"], "w", encoding="utf-8") as out_f, open(paths["stderr"], "w", encoding="utf-8") as err_f:
        exit_code = int(subprocess.run(args, cwd=repo, stdout=out_f, stderr=err_f).returncode)

    state.append_event(paths["events"], "junie_exited", {"job_id": job_id, "exit_code": exit_code})
    _log_runner(paths["runner"], f"Junie CLI exited: exit_code={exit_code}")
    assistant_text = extract_assistant_text(paths["stdout"])
    worker_state = "completed" if exit_code == 0 else "failed"
    state.update_status(paths["status"], {"worker_state": worker_state, "junie.exit_code": exit_code})
    _write_result(paths["result"], job_id, exit_code, assistant_text, paths["stdout"], paths["stderr"])
    print(f"SENIOR_DONE job_id={job_id} state={worker_state} exit_code={exit_code} run_dir={run_dir} result_path={paths['result']}")
    _log_runner(paths["runner"], f"Senior worker finished worker_state={worker_state} exit_code={exit_code}")
    return exit_code


def _iter_ndjson(path: str):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for raw in fh:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    value = json.loads(raw)
                except (json.JSONDecodeError, ValueError):
                    continue
                if isinstance(value, dict):
                    yield value
    except FileNotFoundError:
        return


def _artifact_paths(run_dir: str) -> dict[str, str]:
    return {name: os.path.join(run_dir, filename) for name, filename in {
        "stdout": "junie.stdout.log",
        "stderr": "junie.stderr.log",
        "runner": "runner.log",
        "status": "status.json",
        "events": "events.jsonl",
        "result": "result.md",
    }.items()}


def _is_executable(path: str) -> bool:
    return bool(path) and os.path.isfile(path) and os.access(path, os.X_OK)


def _read_auth_value(auth_file: str) -> str:
    path = Path(auth_file).expanduser()
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read().strip()


def _fail_preflight(paths: dict[str, str], job_id: str, exit_code: int, reason: str, details: dict[str, str]) -> int:
    state.update_status(paths["status"], {"worker_state": "failed"})
    state.append_event(paths["events"], "failed", {"job_id": job_id, "reason": reason, **details})
    print(f"SENIOR_DONE job_id={job_id} state=failed exit_code={exit_code} run_dir={os.path.dirname(paths['result'])} result_path={paths['result']}")
    return exit_code


def _log_runner(runner_log: str, message: str) -> None:
    with open(runner_log, "a", encoding="utf-8") as fh:
        fh.write(f"{now_iso()} {message}\n")


def _strip_ansi(text: str) -> str:
    return _ANSI_RE.sub("", text)


def _tail(path: str, lines: int) -> str:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return "".join(fh.readlines()[-lines:])
    except FileNotFoundError:
        return ""


def _write_result(result_path: str, job_id: str, exit_code: int, assistant_text: str, stdout_log: str, stderr_log: str) -> None:
    runner_state = "completed" if exit_code == 0 else "failed"
    lines = ["# Senior Dev worker result", "", f"- job_id: {job_id}", f"- finished_at: {now_iso()}", f"- exit_code: {exit_code}", f"- runner_state: {runner_state}"]
    lines.append("")
    if assistant_text:
        lines.extend(["## Assistant response", "", assistant_text, ""])
    lines.extend(["## stdout tail", "```", _tail(stdout_log, 80).rstrip("\n"), "```", "", "## stderr tail", "```", _tail(stderr_log, 120).rstrip("\n"), "```"])
    with open(result_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def main() -> int:
    run_dir = os.environ.get("SENIOR_RUN_DIR", "")
    job_id = os.environ.get("SENIOR_JOB_ID", "")
    if not run_dir:
        print("ERROR: SENIOR_RUN_DIR not set", file=sys.stderr)
        return 64
    if not job_id:
        print("ERROR: SENIOR_JOB_ID not set", file=sys.stderr)
        return 64
    spec_path = os.environ.get("SENIOR_SPEC_PATH") or os.path.join(run_dir, "spec.json")
    try:
        return run_from_spec(run_dir, job_id, spec_path)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 66


if __name__ == "__main__":
    raise SystemExit(main())

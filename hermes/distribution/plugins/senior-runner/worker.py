"""OpenCode execution and artifact writing for the Senior runner."""

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


_SESSION_RE = re.compile(r"^ses_[A-Za-z0-9]+$")
_VERDICT_RE = re.compile(r"^\s*(VERDICT|SUMMARY|USER_MESSAGE|PR_URL)\s*:\s*(.*)$")
_VALID_VERDICTS = {"pr-ready", "needs-input", "failed"}


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

    missing = [key for key in ("repo", "prompt_file", "opencode_bin") if not spec.get(key)]
    if missing:
        raise ValueError(f"spec.json missing required field(s): {', '.join(missing)}")
    return spec


def extract_session_id(stdout_log: str) -> str:
    last_id = ""
    for ev in _iter_ndjson(stdout_log):
        sid = ev.get("sessionID", "")
        if _SESSION_RE.match(str(sid)):
            last_id = str(sid)
    return last_id


def extract_assistant_text(stdout_log: str) -> str:
    parts = []
    for ev in _iter_ndjson(stdout_log):
        if ev.get("type") != "text":
            continue
        part = ev.get("part", {})
        if isinstance(part, dict) and part.get("type") == "text" and part.get("text"):
            parts.append(str(part["text"]))
    return "\n".join(parts)


def normalize_verdict(text: str, exit_code: int) -> dict[str, str]:
    fields = {"VERDICT": "", "SUMMARY": "", "USER_MESSAGE": "", "PR_URL": ""}
    found = False
    for line in text.splitlines():
        match = _VERDICT_RE.match(line)
        if match:
            found = True
            fields[match.group(1)] = match.group(2).strip()

    verdict = fields["VERDICT"].lower()
    if verdict not in _VALID_VERDICTS:
        verdict = "failed" if exit_code else ("pr-ready" if fields["PR_URL"] else "needs-input")
        found = False

    summary = fields["SUMMARY"] or (
        "(no summary provided)" if found else
        ("OpenCode run completed" if exit_code == 0 else f"OpenCode run failed with exit code {exit_code}")
    )
    user_message = fields["USER_MESSAGE"] or summary
    return {"VERDICT": verdict, "SUMMARY": summary, "USER_MESSAGE": user_message, "PR_URL": fields["PR_URL"]}


def format_verdict_block(verdict: dict[str, str]) -> str:
    return "\n".join([
        f"VERDICT: {verdict['VERDICT']}",
        f"SUMMARY: {verdict['SUMMARY']}",
        f"USER_MESSAGE: {verdict['USER_MESSAGE']}",
        f"PR_URL: {verdict['PR_URL']}",
    ])


def run_from_spec(run_dir: str, job_id: str, spec_path: str) -> int:
    spec = read_spec(spec_path)
    return run_coding_task_from_spec(run_dir, job_id, spec)


def run_coding_task_from_spec(run_dir: str, job_id: str, spec: dict[str, Any]) -> int:
    repo = str(spec["repo"])
    prompt_file = str(spec["prompt_file"])
    opencode_bin = str(spec["opencode_bin"])
    paths = _artifact_paths(run_dir)
    os.makedirs(run_dir, exist_ok=True)
    for path in (paths["stdout"], paths["stderr"], paths["runner"], paths["events"]):
        Path(path).touch()

    if not os.path.isdir(repo):
        return _fail_preflight(paths, job_id, 66, "repo_not_found", {"repo": repo})
    if not os.path.isfile(prompt_file):
        return _fail_preflight(paths, job_id, 66, "prompt_file_not_found", {"prompt_file": prompt_file})
    if not _is_executable(opencode_bin):
        return _fail_preflight(paths, job_id, 69, "opencode_not_found", {})

    with open(prompt_file, "r", encoding="utf-8") as fh:
        prompt = fh.read()
    model = os.environ.get("OPENCODE_MODEL", "openrouter/openai/gpt-5.5")
    args = [opencode_bin, "run", "--format", "json", "--dangerously-skip-permissions", "--model", model, "--", prompt]

    _log_runner(paths["runner"], f"Starting opencode (sync): model={model} {opencode_bin}")
    state.update_status(paths["status"], {"worker_state": "running", "opencode.bin": opencode_bin, "opencode.model": model})
    state.append_event(paths["events"], "opencode_starting", {"job_id": job_id, "opencode_bin": opencode_bin, "model": model, "repo": repo})
    with open(paths["stdout"], "w", encoding="utf-8") as out_f, open(paths["stderr"], "w", encoding="utf-8") as err_f:
        exit_code = int(subprocess.run(args, cwd=repo, stdout=out_f, stderr=err_f).returncode)

    state.append_event(paths["events"], "opencode_exited", {"job_id": job_id, "exit_code": exit_code})
    _log_runner(paths["runner"], f"OpenCode exited: exit_code={exit_code}")
    session_id = extract_session_id(paths["stdout"])
    if session_id:
        state.update_status(paths["status"], {"opencode.session_id": session_id})
        _log_runner(paths["runner"], f"OpenCode session id: {session_id}")
    assistant_text = extract_assistant_text(paths["stdout"])
    verdict = normalize_verdict(assistant_text, exit_code)
    state.update_status(paths["status"], {"worker_state": "completed", "opencode.exit_code": exit_code, "verdict": verdict["VERDICT"]})
    _write_result(paths["result"], job_id, exit_code, session_id, assistant_text, paths["stdout"], paths["stderr"], verdict)
    print(f"SENIOR_DONE job_id={job_id} state=completed exit_code={exit_code} run_dir={run_dir} result_path={paths['result']}")
    _log_runner(paths["runner"], f"Senior worker finished verdict={verdict['VERDICT']}")
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
        "stdout": "opencode.stdout.log",
        "stderr": "opencode.stderr.log",
        "runner": "runner.log",
        "status": "status.json",
        "events": "events.jsonl",
        "result": "result.md",
    }.items()}


def _is_executable(path: str) -> bool:
    return bool(path) and os.path.isfile(path) and os.access(path, os.X_OK)


def _fail_preflight(paths: dict[str, str], job_id: str, exit_code: int, reason: str, details: dict[str, str]) -> int:
    state.update_status(paths["status"], {"worker_state": "failed"})
    state.append_event(paths["events"], "failed", {"job_id": job_id, "reason": reason, **details})
    print(f"SENIOR_DONE job_id={job_id} state=failed exit_code={exit_code} run_dir={os.path.dirname(paths['result'])} result_path={paths['result']}")
    return exit_code


def _log_runner(runner_log: str, message: str) -> None:
    with open(runner_log, "a", encoding="utf-8") as fh:
        fh.write(f"{now_iso()} {message}\n")


def _tail(path: str, lines: int) -> str:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return "".join(fh.readlines()[-lines:])
    except FileNotFoundError:
        return ""


def _write_result(result_path: str, job_id: str, exit_code: int, session_id: str, assistant_text: str, stdout_log: str, stderr_log: str, verdict: dict[str, str]) -> None:
    lines = ["# Senior Dev worker result", "", f"- job_id: {job_id}", f"- finished_at: {now_iso()}", f"- exit_code: {exit_code}"]
    if session_id:
        lines.append(f"- opencode_session_id: {session_id}")
    lines.append("")
    if assistant_text:
        lines.extend(["## Assistant response", "", assistant_text, ""])
    lines.extend(["## stdout tail", "```", _tail(stdout_log, 80).rstrip("\n"), "```", "", "## stderr tail", "```", _tail(stderr_log, 120).rstrip("\n"), "```", "", "## VERDICT", "```", format_verdict_block(verdict), "```"])
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

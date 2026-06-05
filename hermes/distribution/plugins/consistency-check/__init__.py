"""Consistency check slash command plugin for Hermes.

Registers /check_consistency as a plugin slash command via
ctx.register_command.  The handler resolves the target repository,
invokes the shared consistency-check runner (consistency_check.py)
from the profile scripts directory, and returns a compact summary.
"""

import os
import subprocess
import sys


def _resolve_repo(raw_args: str) -> str | None:
    parts = raw_args.split()
    for i, part in enumerate(parts):
        if part == "--repo" and i + 1 < len(parts):
            return parts[i + 1]

    repo = os.environ.get("JUNIE_REPO")
    if repo:
        return repo

    try:
        from junie_runtime.paths import profile_dir
        tools_path = os.path.join(profile_dir(), "docs", "tools.md")
        if os.path.isfile(tools_path):
            with open(tools_path) as f:
                for line in f:
                    line_stripped = line.strip()
                    if line_stripped.startswith("- Repository:"):
                        val = line_stripped.split(":", 1)[1].strip()
                        if val and val.lower() != "todo":
                            return val
    except Exception:
        pass

    try:
        r = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=10,
        )
        if r.returncode == 0:
            return r.stdout.strip()
    except Exception:
        pass

    return None


def _resolve_runner() -> str | None:
    try:
        from junie_runtime.paths import profile_dir
        candidate = os.path.join(profile_dir(), "scripts", "consistency_check.py")
        if os.path.isfile(candidate):
            return candidate
    except Exception:
        pass

    hermes_home = os.environ.get("HERMES_HOME")
    if hermes_home:
        candidate = os.path.join(hermes_home, "scripts", "consistency_check.py")
        if os.path.isfile(candidate):
            return candidate

    return None


def _format_summary(runner: str, repo: str, dry_run: bool) -> str:
    cmd = [sys.executable, runner, "run", "--repo", repo]
    if dry_run:
        cmd.append("--dry-run")

    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        return (
            "Consistency check timed out after 300 seconds.\n"
            "Run manually with a longer timeout:\n"
            f"  python3 \"{runner}\" run --repo \"{repo}\" --timeout 600"
        )

    lines = []
    if r.returncode == 0:
        lines.append("Consistency check completed successfully.")
    elif r.returncode == 2:
        lines.append("Consistency check blocked or failed.")
    else:
        lines.append(f"Consistency check exited with code {r.returncode}.")

    output = (r.stdout or "") + (r.stderr or "")
    output_lines = [l for l in output.strip().split("\n") if l.strip()]
    relevant = output_lines[-15:]
    if relevant:
        lines.append("```")
        lines.extend(relevant)
        lines.append("```")

    try:
        from junie_runtime.paths import state_root
        runs_dir = os.path.join(state_root(), "consistency", "runs")
        if os.path.isdir(runs_dir):
            run_ids = sorted(os.listdir(runs_dir))
            if run_ids:
                latest = run_ids[-1]
                report_path = os.path.join(runs_dir, latest, "report.md")
                if os.path.isfile(report_path):
                    size = os.path.getsize(report_path)
                    if size < 2000:
                        with open(report_path) as f:
                            content = f.read().strip()
                        lines.append(f"\nLatest report ({latest}):")
                        lines.append("```")
                        lines.append(content[:1500])
                        lines.append("```")
                    else:
                        lines.append(f"\nFull report: {report_path}")
    except Exception:
        pass

    return "\n".join(lines)


def handle_check_consistency(raw_args: str) -> str | None:
    dry_run = "--dry-run" in raw_args

    repo = _resolve_repo(raw_args)
    if not repo:
        return (
            "Could not resolve target repository.\n"
            "Provide --repo <path> or set JUNIE_REPO env var."
        )

    runner = _resolve_runner()
    if not runner:
        return (
            "Consistency check runner not found.\n"
            "Expected at <profile_dir>/scripts/consistency_check.py.\n"
            "Run hire-junie.sh to install the profile."
        )

    try:
        from junie_runtime.state import read_json
        from junie_runtime.paths import state_root
        state_path = os.path.join(state_root(), "consistency", "consistency-state.json")
    except Exception:
        state_path = None

    if state_path and not os.path.isfile(state_path):
        return (
            "Consistency state has not been initialized.\n"
            "Run init first:\n"
            f"  python3 \"{runner}\" init --repo \"{repo}\"\n"
            "After init, /check_consistency will work."
        )

    return _format_summary(runner, repo, dry_run)


def register(ctx) -> None:
    ctx.register_command(
        name="check-consistency",
        handler=handle_check_consistency,
        description="Run consistency check on the target repository to detect contradictions between strategy, docs, memory, and code.",
        args_hint="[--repo <path>] [--dry-run]",
    )

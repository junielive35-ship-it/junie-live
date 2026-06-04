#!/usr/bin/env python3
"""Consistency check runner/CLI for Junie Live.

Subcommands:
  init            Initialize consistency state for a repo.
  run             Run a consistency check.
  render-prompt   Render the prompt template (dry-run) without launching.

State path: $HERMES_HOME/junie-live/state/consistency/
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional


# ── Path resolution ──

def get_hermes_home() -> str:
    env = os.environ.get("HERMES_HOME")
    if env:
        return env
    try:
        from hermes_constants import get_hermes_home as sdk_home
        return str(sdk_home())
    except (ImportError, AttributeError):
        pass
    try:
        from hermes.utils import get_hermes_home as sdk_home
        return str(sdk_home())
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


def get_consistency_base() -> str:
    return os.path.join(get_profile_dir(), "junie-live", "state", "consistency")


def get_state_path() -> str:
    return os.path.join(get_consistency_base(), "consistency-state.json")


def get_pending_path() -> str:
    return os.path.join(get_consistency_base(), "PENDING_CONTRADICTIONS.md")


def get_runs_base() -> str:
    return os.path.join(get_consistency_base(), "runs")


def get_run_dir(run_id: str) -> str:
    return os.path.join(get_runs_base(), run_id)


def get_mutex_dir() -> str:
    return os.path.join(get_profile_dir(), "junie-live", "state", "code_mutex")


# ── State helpers ──

def atomic_write_json(path: str, data: Any) -> None:
    parent = os.path.dirname(path)
    os.makedirs(parent, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=parent, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2, default=str)
            f.write("\n")
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_json(path: str) -> Optional[Any]:
    try:
        with open(path, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None


def atomic_write_text(path: str, text: str) -> None:
    parent = os.path.dirname(path)
    os.makedirs(parent, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=parent, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_text(path: str) -> Optional[str]:
    try:
        with open(path, "r") as f:
            return f.read()
    except (FileNotFoundError, OSError):
        return None


# ── Git helpers ──

def run_git(cmd: list[str], repo: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git"] + cmd,
        cwd=repo,
        capture_output=True,
        text=True,
        timeout=60,
    )


def detect_main_branch(repo: str) -> tuple[Optional[str], Optional[str]]:
    r = run_git(["rev-parse", "--verify", "refs/heads/main"], repo)
    if r.returncode == 0:
        return "main", None

    r = run_git(["rev-parse", "--verify", "refs/heads/master"], repo)
    if r.returncode == 0:
        return "master", None

    r = run_git(["branch", "--format=%(refname:short)"], repo)
    candidates = [b.strip() for b in r.stdout.strip().split("\n") if b.strip()]
    if candidates:
        return None, f"Could not detect main branch. Candidates: {', '.join(candidates)}. Please specify --main-branch."
    return None, "No branches found. Please initialize a git repository with a main branch."


def get_repo_root(path: str) -> Optional[str]:
    r = run_git(["rev-parse", "--show-toplevel"], path)
    if r.returncode == 0:
        return r.stdout.strip()
    return None


def git_is_clean(repo: str) -> bool:
    r = run_git(["status", "--porcelain", "--untracked-files=all"], repo)
    return len(r.stdout.strip()) == 0


def get_current_branch(repo: str) -> Optional[str]:
    r = run_git(["rev-parse", "--abbrev-ref", "HEAD"], repo)
    if r.returncode == 0 and r.stdout.strip() != "HEAD":
        return r.stdout.strip()
    return None


def get_head_sha(repo: str) -> Optional[str]:
    r = run_git(["rev-parse", "HEAD"], repo)
    if r.returncode == 0:
        return r.stdout.strip()
    return None


def get_merge_base(repo: str, main_branch: str) -> Optional[str]:
    r = run_git(["merge-base", "HEAD", main_branch], repo)
    if r.returncode == 0:
        return r.stdout.strip()
    return None


def has_upstream(repo: str, branch: str) -> bool:
    r = run_git(["rev-parse", "--abbrev-ref", f"{branch}@{{upstream}}"], repo)
    return r.returncode == 0 and r.stdout.strip() != ""


def fetch_origin(repo: str) -> tuple[bool, str]:
    r = run_git(["fetch", "--prune"], repo)
    if r.returncode == 0:
        return True, ""
    return False, r.stderr.strip() or "fetch failed"


def is_diverged(repo: str, main_branch: str) -> tuple[bool, str]:
    if not has_upstream(repo, main_branch):
        return False, "no upstream"
    r = run_git(["rev-list", "--left-right", f"{main_branch}...{main_branch}@{{upstream}}"], repo)
    if r.returncode != 0:
        return False, "could not check divergence"
    lines = [l.strip() for l in r.stdout.strip().split("\n") if l.strip()]
    behind = sum(1 for l in lines if l.startswith("<"))
    ahead = sum(1 for l in lines if l.startswith(">"))
    if behind > 0:
        return True, f"main is {behind} commit(s) behind upstream"
    if ahead > 0:
        return True, f"main is {ahead} commit(s) ahead of upstream (unpushed changes)"
    return False, ""


def mutex_is_held() -> tuple[bool, str]:
    mutex_dir = get_mutex_dir()
    if not os.path.isdir(mutex_dir):
        return False, ""
    holder_file = os.path.join(mutex_dir, "holder.json")
    if os.path.isfile(holder_file):
        holder = read_json(holder_file) or {}
        holder_id = holder.get("holder_id", "unknown")
        return True, f"mutex held by {holder_id}"
    return True, "mutex directory exists but holder.json is missing"


# ── Stable ID generation ──

def make_stable_id(bucket: str, claim: str, paths: list[str]) -> str:
    raw = f"{bucket}|{claim}|{','.join(sorted(paths))}"
    h = hashlib.sha256(raw.encode()).hexdigest()[:12]
    return h


# ── State schema ──

def make_initial_state(main_branch: str, checkpoint_commit: str) -> dict:
    return {
        "schema_version": 1,
        "main_branch": main_branch,
        "last_checkpoint_commit": checkpoint_commit,
        "last_scan_at": datetime.now(timezone.utc).isoformat(),
        "last_successful_run_id": None,
        "relevant_artifacts": [],
    }


# ── Prompt rendering ──

PROMPT_TEMPLATE_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..",
    "docs",
    "consistency-check-prompt.md",
)


def render_prompt(
    repo_path: str,
    hermes_md_path: str,
    profile_docs_dir: str,
    pending_path: str,
    state_path: str,
    run_dir: str,
    commit_range: str,
    changed_files: list[str],
    pending_content: str,
    relevant_artifacts: list[dict],
) -> str:
    template = read_text(PROMPT_TEMPLATE_PATH)
    if not template:
        template = _default_prompt_template()

    artifacts_text = ""
    if relevant_artifacts:
        parts = []
        for a in relevant_artifacts:
            parts.append(f"- `{a.get('path', '?')}` — {a.get('kind', '?')} (topics: {', '.join(a.get('topics', []))})")
        artifacts_text = "\n".join(parts)

    changed_text = "\n".join(f"- {f}" for f in changed_files) if changed_files else "(no files changed in range)"

    context = {
        "commit_range": commit_range,
        "repo_path": repo_path,
        "hermes_md_path": hermes_md_path,
        "profile_docs_dir": profile_docs_dir,
        "pending_path": pending_path,
        "state_path": state_path,
        "run_dir": run_dir,
        "pending_content": pending_content,
        "artifacts_text": artifacts_text,
        "changed_text": changed_text,
    }

    prompt = template
    for key, value in context.items():
        prompt = prompt.replace(f"{{{key}}}", value if value else "(none)")

    return prompt


def _default_prompt_template() -> str:
    return """# Consistency Check — Audit Agent Prompt

You are a consistency audit agent. Detect contradictions between repo artifacts and agent state.

Commit range: {commit_range}
Repo: {repo_path}

Changed files:
{changed_text}

Pending contradictions for revalidation:
{pending_content}

Relevant artifacts:
{artifacts_text}

Output sections: new, still_open, resolved, silent_agent_doc_fixes, blocked_or_questions, state_update.
"""


# ── Subcommand: init ──

def cmd_init(args: argparse.Namespace) -> int:
    repo = args.repo
    if not repo:
        cwd = os.getcwd()
        repo = get_repo_root(cwd)
    if not repo:
        print("ERROR: could not resolve repository path. Provide --repo or run from a git repo.", file=sys.stderr)
        return 1
    repo = os.path.abspath(repo)

    state_path = get_state_path()
    if os.path.isfile(state_path) and not args.force:
        state = read_json(state_path)
        if state:
            print(f"Consistency state already exists at {state_path}")
            print(f"  main_branch: {state.get('main_branch', '?')}")
            print(f"  last_checkpoint: {state.get('last_checkpoint_commit', '?')}")
            print("Use --force to re-initialize.")
            return 0

    main_branch = args.main_branch
    if not main_branch:
        detected, err = detect_main_branch(repo)
        if detected:
            main_branch = detected
            print(f"Detected main branch: {main_branch}")
        else:
            print(f"ERROR: {err}", file=sys.stderr)
            return 1

    r = run_git(["rev-parse", main_branch], repo)
    if r.returncode != 0:
        print(f"ERROR: branch '{main_branch}' not found in repo", file=sys.stderr)
        return 1
    checkpoint = r.stdout.strip()

    state = make_initial_state(main_branch, checkpoint)
    atomic_write_json(state_path, state)

    pending_path = get_pending_path()
    if not os.path.isfile(pending_path):
        pending_text = """# Pending Contradictions

Current unresolved contradictions known to Junie. The consistency runner revalidates this file on every successful check and removes items that are no longer present on main.

"""
        atomic_write_text(pending_path, pending_text)
        print(f"Created: {pending_path}")

    print(f"Consistency state initialized at {state_path}")
    print(f"  main_branch: {main_branch}")
    print(f"  last_checkpoint_commit: {checkpoint}")
    return 0


# ── Subcommand: render-prompt ──

def cmd_render_prompt(args: argparse.Namespace) -> int:
    repo = args.repo
    if not repo:
        cwd = os.getcwd()
        repo = get_repo_root(cwd)
    if not repo:
        print("ERROR: could not resolve repository path", file=sys.stderr)
        return 1
    repo = os.path.abspath(repo)

    state_path = get_state_path()
    state = read_json(state_path)
    if not state:
        print("ERROR: consistency state not found. Run 'init' first.", file=sys.stderr)
        return 1

    main_branch = state["main_branch"]
    last_checkpoint = state.get("last_checkpoint_commit", "")
    head_sha = get_head_sha(repo)
    if not head_sha:
        print("ERROR: could not get HEAD sha", file=sys.stderr)
        return 1

    commit_range = f"{last_checkpoint}..{head_sha}" if last_checkpoint else head_sha

    r = run_git(["diff", "--name-only", f"{last_checkpoint}..{head_sha}"], repo) if last_checkpoint else run_git(["diff", "--name-only", "HEAD"], repo)
    changed = [l.strip() for l in r.stdout.strip().split("\n") if l.strip()] if r.returncode == 0 else []

    hermes_md = os.path.join(repo, "HERMES.md")
    if not os.path.isfile(hermes_md):
        hermes_md = os.path.join(repo, ".hermes.md")

    profile_docs = os.path.join(get_profile_dir(), "docs")

    pending_content = read_text(get_pending_path()) or "(no pending contradictions)"

    relevant = state.get("relevant_artifacts", [])

    run_dir = get_run_dir(args.run_id or f"dry-run-{uuid.uuid4().hex[:8]}")

    prompt = render_prompt(
        repo_path=repo,
        hermes_md_path=hermes_md,
        profile_docs_dir=profile_docs,
        pending_path=get_pending_path(),
        state_path=state_path,
        run_dir=run_dir,
        commit_range=commit_range,
        changed_files=changed,
        pending_content=pending_content,
        relevant_artifacts=relevant,
    )

    print(prompt)
    return 0


# ── Subcommand: run ──

def _parse_audit_output(output: str) -> dict:
    sections = {
        "new": [],
        "still_open": [],
        "resolved": [],
        "silent_agent_doc_fixes": [],
        "blocked_or_questions": [],
        "state_update": [],
    }
    current_section = None
    current_items = []
    for line in output.split("\n"):
        if line.startswith("### ") and current_section:
            current_items.append(line)
        elif line.startswith("## "):
            section_name = line.strip("# ").strip().lower().replace(" ", "_")
            if section_name in sections:
                if current_section and current_items:
                    sections[current_section].append("\n".join(current_items))
                current_section = section_name
                current_items = []
            else:
                if current_section and current_items:
                    sections[current_section].append("\n".join(current_items))
                current_section = None
                current_items = []
        elif current_section:
            current_items.append(line)
    if current_section and current_items:
        sections[current_section].append("\n".join(current_items))
    return sections


def _update_pending_file(pending_path: str, parsed: dict, state: dict) -> list[str]:
    resolved_ids = []
    for block in parsed.get("resolved", []):
        m = re.search(r"CC-[a-f0-9]+", block)
        if m:
            resolved_ids.append(m.group(0))

    existing = read_text(pending_path) or ""
    if resolved_ids:
        lines = existing.split("\n")
        keep = []
        skip = False
        skip_section = False
        for line in lines:
            if re.match(r"^### CC-", line):
                sid = line.split(":")[0].strip("# ")
                if sid in resolved_ids:
                    skip = True
                else:
                    skip = False
            if line.startswith("## "):
                skip_section = False
            if not skip:
                keep.append(line)
        new_pending = "\n".join(keep)
    else:
        new_pending = existing

    new_entries = []
    for block in parsed.get("new", []):
        if block.strip():
            new_entries.append(block.strip())
            new_pending += "\n" + block.strip() + "\n"

    if new_pending.strip():
        atomic_write_text(pending_path, new_pending)

    return resolved_ids


def cmd_run(args: argparse.Namespace) -> int:
    repo = args.repo
    if not repo:
        cwd = os.getcwd()
        repo = get_repo_root(cwd)
    if not repo:
        print("ERROR: could not resolve repository path. Provide --repo or run from a git repo.", file=sys.stderr)
        return 1
    repo = os.path.abspath(repo)

    # Check mutex
    held, msg = mutex_is_held()
    if held:
        print(f"BLOCKED: {msg}", file=sys.stderr)
        return 2

    # Check worktree cleanliness
    if not git_is_clean(repo):
        print("BLOCKED: working tree is dirty. Commit, stash, or remove changes first.", file=sys.stderr)
        return 2

    # Fetch
    ok, err = fetch_origin(repo)
    if not ok:
        print(f"BLOCKED: fetch failed: {err}", file=sys.stderr)
        return 2

    # Load state
    state_path = get_state_path()
    state = read_json(state_path)
    if not state:
        print("ERROR: consistency state not found. Run 'consistency_check.py init' first.", file=sys.stderr)
        return 1

    main_branch = state["main_branch"]

    # Check branch
    current_branch = get_current_branch(repo)
    if current_branch != main_branch:
        print(f"BLOCKED: on branch '{current_branch}', expected '{main_branch}'", file=sys.stderr)
        return 2

    # Check diverged
    diverged, div_msg = is_diverged(repo, main_branch)
    if diverged:
        print(f"BLOCKED: {div_msg}", file=sys.stderr)
        return 2

    last_checkpoint = state.get("last_checkpoint_commit", "")
    head_sha = get_head_sha(repo)
    if not head_sha:
        print("ERROR: could not determine HEAD sha", file=sys.stderr)
        return 1

    if last_checkpoint == head_sha:
        print("No new commits since last checkpoint. Nothing to check.")

    commit_range = f"{last_checkpoint}..{head_sha}" if last_checkpoint else head_sha

    # Get changed files
    if last_checkpoint:
        r = run_git(["diff", "--name-only", f"{last_checkpoint}..{head_sha}"], repo)
    else:
        r = run_git(["diff", "--name-only", "HEAD"], repo)
    changed = [l.strip() for l in r.stdout.strip().split("\n") if l.strip()] if r.returncode == 0 else []

    # Create run
    run_id = f"cc-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S')}-{uuid.uuid4().hex[:6]}"
    run_dir = get_run_dir(run_id)
    os.makedirs(run_dir, exist_ok=True)
    os.makedirs(os.path.join(run_dir, "control"), exist_ok=True)
    os.makedirs(os.path.join(run_dir, "locks"), exist_ok=True)

    # Write input.json
    input_data = {
        "run_id": run_id,
        "repo": repo,
        "main_branch": main_branch,
        "last_checkpoint_commit": last_checkpoint,
        "head_sha": head_sha,
        "commit_range": commit_range,
        "changed_files": changed,
        "state": state,
    }
    atomic_write_json(os.path.join(run_dir, "input.json"), input_data)

    # Render prompt
    hermes_md = os.path.join(repo, "HERMES.md")
    if not os.path.isfile(hermes_md):
        hermes_md = os.path.join(repo, ".hermes.md")

    profile_docs = os.path.join(get_profile_dir(), "docs")
    pending_content = read_text(get_pending_path()) or "(no pending contradictions)"
    relevant = state.get("relevant_artifacts", [])

    prompt = render_prompt(
        repo_path=repo,
        hermes_md_path=hermes_md,
        profile_docs_dir=profile_docs,
        pending_path=get_pending_path(),
        state_path=state_path,
        run_dir=run_dir,
        commit_range=commit_range,
        changed_files=changed,
        pending_content=pending_content,
        relevant_artifacts=relevant,
    )

    # Write prompt
    prompt_path = os.path.join(run_dir, "prompt.md")
    atomic_write_text(prompt_path, prompt)

    # Dry-run mode
    if args.dry_run:
        print(f"DRY RUN: run_id={run_id}")
        print(f"Prompt written to: {prompt_path}")
        print("Skipping headless Hermes invocation.")
        return 0

    # Launch headless Hermes
    profile = os.environ.get("HERMES_PROFILE", "junie-live")
    hermes_bin = shutil.which("hermes")
    if not hermes_bin:
        print("ERROR: 'hermes' not found in PATH", file=sys.stderr)
        return 1

    print(f"Launching headless Hermes audit (profile={profile})...")
    try:
        r = subprocess.run(
            [hermes_bin, "-p", profile, "chat", "-q", prompt],
            cwd=repo,
            capture_output=True,
            text=True,
            timeout=args.timeout,
        )
        agent_output = r.stdout
        agent_stderr = r.stderr
        exit_code = r.returncode
    except subprocess.TimeoutExpired:
        print(f"ERROR: Hermes audit timed out after {args.timeout}s", file=sys.stderr)
        _write_failed_run(run_dir, "timeout", f"Audit timed out after {args.timeout}s")
        return 2
    except FileNotFoundError:
        print(f"ERROR: hermes binary not found at {hermes_bin}", file=sys.stderr)
        return 1

    # Write agent output
    atomic_write_text(os.path.join(run_dir, "agent-output.md"), agent_output)
    if agent_stderr:
        atomic_write_text(os.path.join(run_dir, "agent-stderr.log"), agent_stderr)

    if exit_code != 0:
        print(f"ERROR: Hermes audit exited with code {exit_code}", file=sys.stderr)
        _write_failed_run(run_dir, "hermes_failed", f"hermes exited with code {exit_code}")
        return 2

    # Parse output
    parsed = _parse_audit_output(agent_output)

    # Update pending file
    resolved_ids = _update_pending_file(get_pending_path(), parsed, state)

    # Write report
    report_lines = [
        f"# Consistency Check Report — {run_id}",
        f"",
        f"- Checked: {commit_range}",
        f"- Changed files: {len(changed)}",
        f"",
    ]
    for section_name in ("new", "still_open", "resolved", "silent_agent_doc_fixes", "blocked_or_questions", "state_update"):
        items = parsed.get(section_name, [])
        if items:
            report_lines.append(f"## {section_name.replace('_', ' ').title()}")
            report_lines.append("")
            for item in items:
                report_lines.append(item if item.startswith("### ") else f"- {item}")
            report_lines.append("")

    if resolved_ids:
        report_lines.append(f"Resolved IDs: {', '.join(resolved_ids)}")

    report = "\n".join(report_lines)
    atomic_write_text(os.path.join(run_dir, "report.md"), report)

    # Write events
    events_path = os.path.join(run_dir, "events.jsonl")
    now = time.time()
    iso = datetime.now(timezone.utc).isoformat()
    event = json.dumps({"ts": now, "iso": iso, "type": "check_completed", "data": {"run_id": run_id, "commit_range": commit_range, "new_count": len(parsed.get("new", [])), "resolved_count": len(resolved_ids)}}, default=str) + "\n"
    with open(events_path, "a") as f:
        f.write(event)

    # Write status
    status = {
        "run_id": run_id,
        "status": "completed",
        "checked_range": commit_range,
        "new_count": len(parsed.get("new", [])),
        "resolved_count": len(resolved_ids),
        "completed_at": iso,
    }
    atomic_write_json(os.path.join(run_dir, "status.json"), status)

    # Update checkpoint
    state["last_checkpoint_commit"] = head_sha
    state["last_scan_at"] = datetime.now(timezone.utc).isoformat()
    state["last_successful_run_id"] = run_id
    atomic_write_json(state_path, state)

    print(report)
    print(f"\nCheckpoint updated to {head_sha}")
    return 0


def _write_failed_run(run_dir: str, reason: str, detail: str) -> None:
    iso = datetime.now(timezone.utc).isoformat()
    status = {
        "run_id": os.path.basename(run_dir),
        "status": "failed",
        "reason": reason,
        "detail": detail,
        "failed_at": iso,
    }
    atomic_write_json(os.path.join(run_dir, "status.json"), status)
    atomic_write_text(os.path.join(run_dir, "report.md"), f"# Consistency Check — Failed\n\nReason: {reason}\n\nDetail: {detail}\n")


# ── CLI ──

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Junie Live consistency check runner",
    )
    parser.add_argument("--repo", help="Target repository path (default: auto-detect from cwd)")
    parser.add_argument("--timeout", type=int, default=300, help="Timeout in seconds for headless Hermes (default: 300)")

    sub = parser.add_subparsers(dest="command", required=True)

    init_p = sub.add_parser("init", help="Initialize consistency state")
    init_p.add_argument("--repo", help="Target repository path")
    init_p.add_argument("--main-branch", help="Override main branch detection")
    init_p.add_argument("--force", action="store_true", help="Re-initialize existing state")
    init_p.set_defaults(func=cmd_init)

    run_p = sub.add_parser("run", help="Run a consistency check")
    run_p.add_argument("--repo", help="Target repository path")
    run_p.add_argument("--dry-run", action="store_true", help="Render prompt but do not launch headless Hermes")
    run_p.add_argument("--timeout", type=int, default=300, help="Timeout in seconds for headless Hermes")
    run_p.set_defaults(func=cmd_run)

    render_p = sub.add_parser("render-prompt", help="Render the prompt template (dry-run)")
    render_p.add_argument("--repo", help="Target repository path")
    render_p.add_argument("--run-id", help="Run ID for prompt (default: auto-generated)")
    render_p.set_defaults(func=cmd_render_prompt)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())

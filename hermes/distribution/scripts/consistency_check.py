#!/usr/bin/env python3
"""Consistency check runner/CLI for Junie Live.

Subcommands:
  init            Initialize consistency state for a repo.
  run             Run a consistency check.
  render-prompt   Render the prompt template (dry-run) without launching.

State path is resolved via junie_runtime.paths.state_root() and lives under
<state_root>/consistency/.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from junie_runtime.events import append_event
from junie_runtime.mutex import MutexHeldError, acquire as mutex_acquire, release as mutex_release
from junie_runtime.paths import mutex_dir, state_root
from junie_runtime.state import atomic_write_json, atomic_write_text, read_json, read_text

HERMES_PROFILE_ENV = "HERMES_PROFILE"


def get_consistency_base() -> str:
    return os.path.join(state_root(), "consistency")


def get_state_path() -> str:
    return os.path.join(get_consistency_base(), "consistency-state.json")


def get_pending_path() -> str:
    return os.path.join(get_consistency_base(), "PENDING_CONTRADICTIONS.md")


def get_runs_base() -> str:
    return os.path.join(get_consistency_base(), "runs")


def get_run_dir(run_id: str) -> str:
    return os.path.join(get_runs_base(), run_id)


# ── Git helpers ──

def run_git(cmd: list[str], repo: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git"] + cmd,
        cwd=repo,
        capture_output=True,
        text=True,
        timeout=60,
    )


def detect_main_branch(repo: str) -> tuple[str | None, str | None]:
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


def get_repo_root(path: str) -> str | None:
    r = run_git(["rev-parse", "--show-toplevel"], path)
    if r.returncode == 0:
        return r.stdout.strip()
    return None


def git_is_clean(repo: str) -> bool:
    r = run_git(["status", "--porcelain", "--untracked-files=all"], repo)
    return len(r.stdout.strip()) == 0


def get_current_branch(repo: str) -> str | None:
    r = run_git(["rev-parse", "--abbrev-ref", "HEAD"], repo)
    if r.returncode == 0 and r.stdout.strip() != "HEAD":
        return r.stdout.strip()
    return None


def get_head_sha(repo: str) -> str | None:
    r = run_git(["rev-parse", "HEAD"], repo)
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

Output sections (use ## headings): new, still_open, resolved, silent_agent_doc_fixes, blocked_or_questions, state_update.
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

    if last_checkpoint:
        r = run_git(["diff", "--name-only", f"{last_checkpoint}..{head_sha}"], repo)
    else:
        r = run_git(["diff", "--name-only", "HEAD"], repo)
    changed = [l.strip() for l in r.stdout.strip().split("\n") if l.strip()] if r.returncode == 0 else []

    hermes_md = os.path.join(repo, "HERMES.md")
    if not os.path.isfile(hermes_md):
        hermes_md = os.path.join(repo, ".hermes.md")

    profile_docs = os.path.join(state_root(), "..", "docs")
    if not os.path.isdir(profile_docs):
        profile_docs = os.path.join(os.path.dirname(state_root()), "docs")

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
        if line.startswith("## "):
            section_name = line.strip("# ").strip().lower().replace(" ", "_")
            if current_section and current_items:
                sections[current_section].append("\n".join(current_items))
            current_items = []
            if section_name in sections:
                current_section = section_name
            else:
                current_section = None
        elif current_section and line.startswith("### ") and current_section in sections:
            if current_items:
                joined = "\n".join(current_items).strip()
                if joined:
                    sections[current_section].append(joined)
            current_items = [line]
        elif current_section:
            current_items.append(line)
    if current_section and current_items:
        joined = "\n".join(current_items).strip()
        if joined:
            sections[current_section].append(joined)
    return sections


def _extract_item_id(block: str) -> str | None:
    m = re.search(r"### (CC-[a-f0-9]+):", block)
    return m.group(1) if m else None


def _parse_existing_items(text: str) -> dict[str, str]:
    items: dict[str, str] = {}
    current_id = None
    current_block: list[str] = []
    for line in text.split("\n"):
        m = re.match(r"^### (CC-[a-f0-9]+):", line)
        if m:
            if current_id and current_block:
                items[current_id] = "\n".join(current_block)
            current_id = m.group(1)
            current_block = [line]
        elif current_id is not None:
            current_block.append(line)
    if current_id is not None and current_block:
        items[current_id] = "\n".join(current_block)
    return items


SEVERITY_ORDER = {"Critical": 0, "High": 1, "Medium": 2, "Low": 3, "Unknown": 99}


def _severity_key(item: tuple[str, str]) -> tuple:
    _, block = item
    m = re.search(r"Severity:\s*(\S+)", block)
    sev = m.group(1) if m else "Unknown"
    return (SEVERITY_ORDER.get(sev, 99), item[0])


def _update_pending_file(pending_path: str, parsed: dict, state: dict) -> list[str]:
    resolved_ids: list[str] = []
    for block in parsed.get("resolved", []):
        for m in re.finditer(r"CC-[a-f0-9]+", block):
            resolved_ids.append(m.group(0))

    existing = read_text(pending_path) or ""
    items = _parse_existing_items(existing)

    for rid in resolved_ids:
        items.pop(rid, None)

    for block in parsed.get("new", []):
        bid = _extract_item_id(block)
        if bid:
            items[bid] = block.strip()

    for block in parsed.get("still_open", []):
        bid = _extract_item_id(block)
        if bid:
            items[bid] = block.strip()

    sorted_items = sorted(items.items(), key=_severity_key)

    header = """# Pending Contradictions

Current unresolved contradictions known to Junie. The consistency runner revalidates this file on every successful check and removes items that are no longer present on main.

"""
    body_parts: list[str] = []
    current_sev: str | None = None
    for item_id, block in sorted_items:
        m = re.search(r"Severity:\s*(\S+)", block)
        sev = m.group(1) if m else "Unknown"
        if sev != current_sev:
            if current_sev is not None:
                body_parts.append("")
            body_parts.append(f"## {sev}")
            body_parts.append("")
            current_sev = sev
        body_parts.append(block)

    body = "\n".join(body_parts)
    new_pending = header + body + "\n"

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

    # Create run_id early for blocked artifact recording
    run_id = f"cc-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S')}-{uuid.uuid4().hex[:6]}"
    run_dir = get_run_dir(run_id)
    os.makedirs(run_dir, exist_ok=True)

    # Acquire mutex via junie_runtime.mutex.acquire
    current_branch = get_current_branch(repo) or ""
    mutex_holder_id = f"junie:consistency-check:{run_id}"
    mdir = mutex_dir()
    try:
        mutex_acquire(mdir, mutex_holder_id, "consistency check", repo, current_branch)
    except MutexHeldError as e:
        msg = f"mutex {e}"
        _write_run_artifacts(run_dir, "blocked", "mutex_held", msg)
        print(f"BLOCKED: {msg}", file=sys.stderr)
        return 2

    try:
        # Preflight: worktree cleanliness
        if not git_is_clean(repo):
            _write_run_artifacts(run_dir, "blocked", "dirty_worktree",
                                 "Working tree is dirty. Commit, stash, or remove changes first.")
            print("BLOCKED: working tree is dirty.", file=sys.stderr)
            return 2

        # Preflight: fetch
        ok, err = fetch_origin(repo)
        if not ok:
            _write_run_artifacts(run_dir, "blocked", "fetch_failed", err, {
                "run_id": run_id, "repo": repo, "reason": "fetch_failed"})
            print(f"BLOCKED: fetch failed: {err}", file=sys.stderr)
            return 2

        # Load state
        state_path = get_state_path()
        state = read_json(state_path)
        if not state:
            print("ERROR: consistency state not found. Run 'consistency_check.py init' first.", file=sys.stderr)
            return 1

        main_branch = state["main_branch"]

        # Preflight: correct branch
        current_branch = get_current_branch(repo)
        if current_branch != main_branch:
            _write_run_artifacts(run_dir, "blocked", "wrong_branch",
                                 f"On branch '{current_branch}', expected '{main_branch}'", {
                                     "run_id": run_id, "repo": repo, "main_branch": main_branch,
                                     "current_branch": current_branch})
            print(f"BLOCKED: on branch '{current_branch}', expected '{main_branch}'", file=sys.stderr)
            return 2

        # Preflight: diverged main
        diverged, div_msg = is_diverged(repo, main_branch)
        if diverged:
            _write_run_artifacts(run_dir, "blocked", "diverged", div_msg, {
                "run_id": run_id, "repo": repo, "main_branch": main_branch, "diverged": div_msg})
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

        profile_docs = os.path.join(state_root(), "..", "docs")
        if not os.path.isdir(profile_docs):
            profile_docs = os.path.join(os.path.dirname(state_root()), "docs")
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
        profile = os.environ.get(HERMES_PROFILE_ENV, "junie-live")
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

        # Write event via junie_runtime.events
        iso = datetime.now(timezone.utc).isoformat()
        event = {"ts": time.time(), "iso": iso, "type": "check_completed",
                 "data": {"run_id": run_id, "commit_range": commit_range,
                          "new_count": len(parsed.get("new", [])),
                          "resolved_count": len(resolved_ids)}}
        append_event(os.path.join(run_dir, "events.jsonl"), event)

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

    finally:
        mutex_release(mdir, mutex_holder_id)


def _write_run_artifacts(run_dir: str, status_val: str, reason: str, detail: str,
                         input_data: dict | None = None) -> None:
    iso = datetime.now(timezone.utc).isoformat()
    run_id = os.path.basename(run_dir)
    atomic_write_json(os.path.join(run_dir, "status.json"), {
        "run_id": run_id,
        "status": status_val,
        "reason": reason,
        "detail": detail,
        "failed_at": iso,
    })
    atomic_write_text(os.path.join(run_dir, "report.md"),
        f"# Consistency Check — {status_val.title()}\n\nReason: {reason}\n\nDetail: {detail}\n")
    if input_data:
        atomic_write_json(os.path.join(run_dir, "input.json"), input_data)
    event = {"ts": time.time(), "iso": iso, "type": f"{status_val}_preflight",
             "data": {"reason": reason, "detail": detail}}
    events_path = os.path.join(run_dir, "events.jsonl")
    os.makedirs(os.path.dirname(events_path), exist_ok=True)
    append_event(events_path, event)


def _write_failed_run(run_dir: str, reason: str, detail: str) -> None:
    _write_run_artifacts(run_dir, "failed", reason, detail)


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

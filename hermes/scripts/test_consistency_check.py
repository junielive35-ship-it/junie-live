#!/usr/bin/env python3
"""Test consistency check runner: init, preflight, prompt rendering, state management, mutex.

Run:  python3 hermes/scripts/test_consistency_check.py
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SCRIPT = os.path.join(ROOT, "initialization", "scripts", "consistency_check.py")

# Load the runner module directly (hermes/ is not a Python package)
_spec = importlib.util.spec_from_file_location("consistency_check", SCRIPT)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
_parse_audit_output = _mod._parse_audit_output
_update_pending_file = _mod._update_pending_file
_parse_existing_items = _mod._parse_existing_items
_extract_item_id = _mod._extract_item_id
_write_run_artifacts = _mod._write_run_artifacts
mutex_acquire = _mod.mutex_acquire
mutex_release = _mod.mutex_release

fail_count = 0
pass_count = 0


def pass_():
    global pass_count
    pass_count += 1


def fail(msg: str) -> None:
    global fail_count
    fail_count += 1
    print(f"  FAIL: {msg}", file=sys.stderr)


def run_check(hermes_home: str, *args: str, expect_zero: bool = True) -> subprocess.CompletedProcess:
    env = {**os.environ, "HERMES_HOME": hermes_home, "HERMES_PROFILE": "test-profile"}
    r = subprocess.run(
        [sys.executable, SCRIPT] + list(args),
        capture_output=True, text=True, timeout=30, env=env,
    )
    if expect_zero and r.returncode != 0:
        fail(f"expected exit 0, got {r.returncode}: stdout={r.stdout[:500]!r} stderr={r.stderr[:500]!r}")
    elif not expect_zero and r.returncode == 0:
        fail(f"expected non-zero exit, got 0: stdout={r.stdout[:500]!r}")
    return r


def make_repo(path: str, initial_branch: str = "master") -> None:
    os.makedirs(path, exist_ok=True)
    subprocess.run(["git", "init", "-q", f"--initial-branch={initial_branch}"], cwd=path, capture_output=True, check=True)
    subprocess.run(["git", "config", "user.email", "test@test.com"], cwd=path, capture_output=True, check=True)
    subprocess.run(["git", "config", "user.name", "Test"], cwd=path, capture_output=True, check=True)


def commit(repo: str, msg: str = "initial") -> None:
    subprocess.run(["git", "commit", "--allow-empty", "-m", msg], cwd=repo, capture_output=True, check=True)


def state_path(home: str) -> str:
    return os.path.join(home, "profiles", "test-profile", "junie-live", "state", "consistency", "consistency-state.json")


def pending_path(home: str) -> str:
    return os.path.join(home, "profiles", "test-profile", "junie-live", "state", "consistency", "PENDING_CONTRADICTIONS.md")


def mutex_dir(home: str) -> str:
    return os.path.join(home, "profiles", "test-profile", "junie-live", "state", "code_mutex")


# ════════════════════════════════════════════════════════════════

def test_py_compile() -> None:
    r = subprocess.run([sys.executable, "-m", "py_compile", SCRIPT], capture_output=True, text=True)
    if r.returncode == 0:
        pass_()
        print("  OK: py_compile passed")
    else:
        fail(f"py_compile failed: {r.stderr}")


def test_init_main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo = os.path.join(tmp, "repo")
        make_repo(repo, "main")
        commit(repo)
        r = run_check(tmp, "init", "--repo", repo)
        sp = state_path(tmp)
        if not os.path.isfile(sp):
            fail("state file not created")
            return
        state = json.load(open(sp))
        if state["main_branch"] == "main":
            pass_()
            print(f"  OK: main_branch=main")
        else:
            fail(f"expected main_branch=main, got {state['main_branch']}")

        pp = pending_path(tmp)
        if os.path.isfile(pp):
            pass_()
            print("  OK: PENDING_CONTRADICTIONS.md created")
        else:
            fail("PENDING_CONTRADICTIONS.md not created")


def test_init_master_no_main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo = os.path.join(tmp, "repo")
        make_repo(repo, "master")
        commit(repo)
        r = run_check(tmp, "init", "--repo", repo)
        sp = state_path(tmp)
        state = json.load(open(sp))
        if state["main_branch"] == "master":
            pass_()
            print(f"  OK: master branch detected")
        else:
            fail(f"expected master, got {state['main_branch']}")


def test_init_prefers_main_over_master() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo = os.path.join(tmp, "repo")
        make_repo(repo, "master")
        commit(repo)
        subprocess.run(["git", "branch", "-m", "master", "main"], cwd=repo, capture_output=True, check=True)
        subprocess.run(["git", "checkout", "-b", "master"], cwd=repo, capture_output=True, check=True)
        r = run_check(tmp, "init", "--repo", repo)
        sp = state_path(tmp)
        state = json.load(open(sp))
        if state["main_branch"] == "main":
            pass_()
            print("  OK: main preferred over master")
        else:
            fail(f"expected main, got {state['main_branch']}")


def test_init_no_branches_error() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo = os.path.join(tmp, "repo")
        os.makedirs(repo, exist_ok=True)
        subprocess.run(["git", "init", "-q"], cwd=repo, capture_output=True, check=True)
        r = run_check(tmp, "init", "--repo", repo, expect_zero=False)
        if r.returncode != 0:
            pass_()
            print(f"  OK: empty repo rejected (exit {r.returncode})")
        else:
            fail("init should fail on empty repo")


def test_init_existing_state_preserved() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo = os.path.join(tmp, "repo")
        make_repo(repo, "main")
        commit(repo)
        run_check(tmp, "init", "--repo", repo)
        sp = state_path(tmp)
        state = json.load(open(sp))
        orig_checkpoint = state["last_checkpoint_commit"]
        r = run_check(tmp, "init", "--repo", repo)
        if "already exists" in r.stdout:
            pass_()
            print("  OK: existing state preserved")
        else:
            fail(f"expected 'already exists' message, got: {r.stdout[:200]}")


def test_init_force_overwrites() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo = os.path.join(tmp, "repo")
        make_repo(repo, "main")
        commit(repo)
        run_check(tmp, "init", "--repo", repo)
        run_check(tmp, "init", "--repo", repo, "--force")
        sp = state_path(tmp)
        if os.path.isfile(sp):
            pass_()
            print("  OK: force init works")
        else:
            fail("state file missing after force init")


def test_render_prompt() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo = os.path.join(tmp, "repo")
        make_repo(repo, "main")
        commit(repo)
        commit(repo, "second")
        run_check(tmp, "init", "--repo", repo)
        r = run_check(tmp, "render-prompt", "--repo", repo)
        if "Consistency Check" in r.stdout or "Audit Agent" in r.stdout:
            pass_()
            print("  OK: prompt rendered")
        else:
            fail("prompt does not contain expected heading")


def test_dry_run() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo = os.path.join(tmp, "repo")
        make_repo(repo, "main")
        commit(repo)
        run_check(tmp, "init", "--repo", repo)
        r = run_check(tmp, "run", "--repo", repo, "--dry-run")
        if "DRY RUN" in r.stdout:
            pass_()
            print("  OK: dry-run mode works")
        else:
            fail("dry-run output missing")


def test_mutex_held_blocks() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo = os.path.join(tmp, "repo")
        make_repo(repo, "main")
        commit(repo)
        run_check(tmp, "init", "--repo", repo)

        # Acquire the mutex externally via mkdir
        md = mutex_dir(tmp)
        os.makedirs(md, exist_ok=True)
        holder = {"holder_id": "test:other-process", "reason": "testing"}
        with open(os.path.join(md, "holder.json"), "w") as f:
            json.dump(holder, f)

        r = run_check(tmp, "run", "--repo", repo, expect_zero=False)
        if r.returncode != 0 and ("BLOCKED" in r.stdout or "BLOCKED" in r.stderr or "mutex" in (r.stdout + r.stderr).lower()):
            pass_()
            print("  OK: mutex blocks")

            # Check that blocked artifacts were written
            runs_dir = os.path.join(os.path.dirname(state_path(tmp)), "runs")
            dirs = [d for d in os.listdir(runs_dir) if os.path.isdir(os.path.join(runs_dir, d))]
            if dirs:
                latest_run = sorted(dirs)[-1]
                status_f = os.path.join(runs_dir, latest_run, "status.json")
                report_f = os.path.join(runs_dir, latest_run, "report.md")
                events_f = os.path.join(runs_dir, latest_run, "events.jsonl")
                if os.path.isfile(status_f) and os.path.isfile(report_f):
                    pass_()
                    print("  OK: blocked run artifacts written")
                else:
                    fail("blocked run artifacts missing")
            else:
                fail("no run dir created for blocked run")
        else:
            fail(f"expected BLOCKED, got exit {r.returncode}: stdout={r.stdout[:200]} stderr={r.stderr[:200]}")


def test_dirty_worktree_blocks() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo = os.path.join(tmp, "repo")
        make_repo(repo, "main")
        commit(repo)
        run_check(tmp, "init", "--repo", repo)

        with open(os.path.join(repo, "dirty.txt"), "w") as f:
            f.write("dirty")

        r = run_check(tmp, "run", "--repo", repo, expect_zero=False)
        if r.returncode != 0 and ("BLOCKED" in r.stdout or "BLOCKED" in r.stderr or "dirty" in (r.stdout + r.stderr).lower()):
            pass_()
            print("  OK: dirty worktree blocked")
        else:
            fail(f"expected BLOCKED, got exit {r.returncode}")


def test_mutex_acquire_release() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo = os.path.join(tmp, "repo")
        make_repo(repo, "main")
        commit(repo)
        run_check(tmp, "init", "--repo", repo)

        # Acquire mutex programmatically via the script should succeed
        r1 = run_check(tmp, "run", "--repo", repo, "--dry-run")
        if r1.returncode == 0:
            pass_()
            print("  OK: first acquisition succeeds")

        # After successful dry-run, mutex should be released
        md = mutex_dir(tmp)
        if not os.path.isdir(md):
            pass_()
            print("  OK: mutex released after run")
        else:
            fail("mutex still held after run")

        # Second run should also succeed (mutex was released)
        r2 = run_check(tmp, "run", "--repo", repo, "--dry-run")
        if r2.returncode == 0:
            pass_()
            print("  OK: second acquisition succeeds (mutex released)")
        else:
            fail(f"second run blocked: {r2.stdout[:200]}")


def test_parse_audit_output_sections() -> None:
    sample = """## new

### CC-a1b2c3d4e5f6: Test contradiction

- Severity: High
- Claim: test

## still_open

### CC-f0e1d2c3b4a5: Old contradiction

- Severity: Low
- Last seen: 2024-01-01

## resolved

### CC-9876543210ab: Gone

No longer present.

## silent_agent_doc_fixes

- Fixed typo in README.md

## blocked_or_questions

Nothing.

## state_update

No changes.
"""
    parsed = _parse_audit_output(sample)
    checks = [
        ("new", len(parsed.get("new", [])), 1, "new section"),
        ("still_open", len(parsed["still_open"]), 1, "still_open section"),
        ("resolved", len(parsed["resolved"]), 1, "resolved section"),
        ("silent_agent_doc_fixes", len(parsed["silent_agent_doc_fixes"]), 1, "silent_agent_doc_fixes section"),
        ("blocked_or_questions", len(parsed["blocked_or_questions"]), 1, "blocked_or_questions section"),
        ("state_update", len(parsed["state_update"]), 1, "state_update section"),
    ]
    ok = True
    for section_name, actual, expected, label in checks:
        if actual == expected:
            pass_()
        else:
            fail(f"{label}: expected {expected} items, got {actual}")
            ok = False
    if ok:
        print("  OK: all sections parsed correctly")


def test_parse_audit_output_multi_items() -> None:
    sample = """## new

### CC-a1a1a1a1a1a1: First item

- Severity: High

### CC-b2b2b2b2b2b2: Second item

- Severity: Low

## still_open

### CC-c3c3c3c3c3c3: Still open

- Severity: Medium
"""
    parsed = _parse_audit_output(sample)
    if len(parsed["new"]) == 2:
        pass_()
        print("  OK: multiple new items parsed")
    else:
        fail(f"expected 2 new items, got {len(parsed['new'])}")
    if len(parsed["still_open"]) == 1:
        pass_()
        print("  OK: still_open items parsed")
    else:
        fail(f"expected 1 still_open item, got {len(parsed['still_open'])}")

    # Check CC-IDs present
    new_text = "\n".join(parsed["new"])
    if "CC-a1a1a1a1a1a1" in new_text and "CC-b2b2b2b2b2b2" in new_text:
        pass_()
        print("  OK: CC-IDs present in new items")
    else:
        fail("CC-IDs missing from new items")


def test_pending_merge_new_item() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        pp = os.path.join(tmp, "PENDING_CONTRADICTIONS.md")
        with open(pp, "w") as f:
            f.write("# Pending Contradictions\n\n")

        parsed = {
            "new": [
                "### CC-abcd1234abcd: Test item\n\n- Severity: High\n- Claim: contradiction"
            ],
            "still_open": [],
            "resolved": [],
        }
        resolved = _update_pending_file(pp, parsed, {})
        text = open(pp).read()
        if "CC-abcd1234abcd" in text and "High" in text:
            pass_()
            print("  OK: new item added to pending")
        else:
            fail(f"new item not found in pending: {text[:200]}")
        if len(resolved) == 0:
            pass_()
        else:
            fail(f"expected 0 resolved, got {len(resolved)}")


def test_pending_merge_resolved_removed() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        pp = os.path.join(tmp, "PENDING_CONTRADICTIONS.md")
        with open(pp, "w") as f:
            f.write("# Pending Contradictions\n\n## High\n\n### CC-abcd0000abcd: Will be resolved\n\n- Severity: High\n\n## Low\n\n### CC-ffff0000ffff: Keep this\n\n- Severity: Low\n")

        parsed = {
            "new": [],
            "still_open": [],
            "resolved": ["### CC-abcd0000abcd: Resolved now\n"],
        }
        resolved = _update_pending_file(pp, parsed, {})
        text = open(pp).read()
        if "CC-abcd0000abcd" in text:
            fail("resolved item still in pending")
        else:
            pass_()
            print("  OK: resolved item removed")

        if "CC-ffff0000ffff" in text:
            pass_()
            print("  OK: unresolved item preserved")
        else:
            fail("unresolved item removed incorrectly")

        if "Low" in text:
            pass_()
            print("  OK: Low severity heading preserved")
        else:
            fail("Low heading removed after resolved removal")

        if "CC-abcd0000abcd" in resolved:
            pass_()
            print("  OK: resolved ID returned")
        else:
            fail("resolved ID not in return list")


def test_pending_merge_still_open_upserts() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        pp = os.path.join(tmp, "PENDING_CONTRADICTIONS.md")
        with open(pp, "w") as f:
            f.write("# Pending Contradictions\n\n### CC-abcd0000beef: Old version\n\n- Severity: Low\n- Last seen: 2024-01-01\n")
        parsed = {
            "new": [],
            "still_open": [
                "### CC-abcd0000beef: Updated version\n\n- Severity: Low\n- Last seen: 2024-06-01\n- Last checked commit: abcd1234\n"
            ],
            "resolved": [],
        }
        _update_pending_file(pp, parsed, {})
        text = open(pp).read()
        if "Updated version" in text and "2024-06-01" in text:
            pass_()
            print("  OK: still_open item updated")
        else:
            fail(f"still_open upsert failed: {text[:300]}")
        if "Old version" not in text:
            pass_()
            print("  OK: old version replaced")
        else:
            fail("old version not replaced")


def test_blocked_artifacts_written() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        run_dir = os.path.join(tmp, "runs", "test-run")
        os.makedirs(run_dir, exist_ok=True)
        _write_run_artifacts(run_dir, "blocked", "test_reason", "test detail", {"run_id": "test-run"})
        status = json.load(open(os.path.join(run_dir, "status.json")))
        report = open(os.path.join(run_dir, "report.md")).read()
        events = open(os.path.join(run_dir, "events.jsonl")).read()
        if status["status"] == "blocked":
            pass_()
            print("  OK: blocked status written")
        else:
            fail("status not blocked")
        if "test_reason" in report:
            pass_()
        else:
            fail("reason not in report")
        if "blocked_preflight" in events:
            pass_()
            print("  OK: event written")
        else:
            fail("event not written")


# ════════════════════════════════════════════════════════════════

def main() -> int:
    tests = [
        ("py_compile", test_py_compile),
        ("init with main branch", test_init_main),
        ("init with master branch (no main)", test_init_master_no_main),
        ("init prefers main over master", test_init_prefers_main_over_master),
        ("init no branches returns error", test_init_no_branches_error),
        ("existing state preserved", test_init_existing_state_preserved),
        ("init --force overwrites", test_init_force_overwrites),
        ("render-prompt works", test_render_prompt),
        ("run --dry-run works", test_dry_run),
        ("mutex held blocks", test_mutex_held_blocks),
        ("dirty worktree blocks", test_dirty_worktree_blocks),
        ("mutex acquire/release", test_mutex_acquire_release),
        ("parse audit output sections", test_parse_audit_output_sections),
        ("parse audit output multi items", test_parse_audit_output_multi_items),
        ("pending merge new item", test_pending_merge_new_item),
        ("pending merge resolved removed", test_pending_merge_resolved_removed),
        ("pending merge still_open upserts", test_pending_merge_still_open_upserts),
        ("blocked artifacts written", test_blocked_artifacts_written),
    ]

    print("=== Consistency Check Tests ===\n")
    for name, func in tests:
        print(f"--- {name} ---")
        try:
            func()
        except Exception as e:
            fail(f"test raised exception: {e}")
            import traceback
            traceback.print_exc()
        print()

    print(f"=== Results: Passed {pass_count}, Failed {fail_count} ===")
    return 1 if fail_count > 0 else 0


if __name__ == "__main__":
    sys.exit(main())

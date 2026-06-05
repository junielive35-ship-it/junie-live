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
SCRIPT = os.path.join(ROOT, "distribution", "scripts", "consistency_check.py")

# Load the runner module directly
_spec = importlib.util.spec_from_file_location("consistency_check", SCRIPT)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
_validate_pending_file = _mod._validate_pending_file
_backup_pending = _mod._backup_pending
_restore_pending = _mod._restore_pending
_compute_pending_diff = _mod._compute_pending_diff
_parse_existing_items = _mod._parse_existing_items
_extract_item_id = _mod._extract_item_id
_write_run_artifacts = _mod._write_run_artifacts
_atomic_write_text = _mod.atomic_write_text

fail_count = 0
pass_count = 0


def pass_():
    global pass_count
    pass_count += 1


def fail(msg: str) -> None:
    global fail_count
    fail_count += 1
    print(f"  FAIL: {msg}", file=sys.stderr)


def run_check(hermes_home: str, *args: str, expect_zero: bool = True,
              hermes_home_override: str | None = None,
              env_override: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    env = env_override if env_override is not None else {
        **os.environ,
        "HERMES_HOME": hermes_home_override or hermes_home,
        "HERMES_PROFILE": "test-profile",
    }
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


# ── Validation tests ──

def test_validate_empty_canonical() -> None:
    text = "# Pending Contradictions\n\nNo items.\n"
    errors = _validate_pending_file(text)
    if len(errors) == 0:
        pass_()
        print("  OK: empty canonical file is valid")
    else:
        fail(f"expected 0 errors, got {len(errors)}: {errors}")


def test_validate_valid_block() -> None:
    text = """# Pending Contradictions

### CC-a1b2c3d4e5f6: Test contradiction

- Severity: High
- Bucket: repo-internal
- Claim: Code contradicts docs
- Evidence: src/main.py says X, docs say Y
- Required resolution: commit/PR
"""
    errors = _validate_pending_file(text)
    if len(errors) == 0:
        pass_()
        print("  OK: valid contradiction block passes")
    else:
        fail(f"expected 0 errors, got {len(errors)}: {errors}")


def test_validate_missing_header() -> None:
    text = "Some random text\n"
    errors = _validate_pending_file(text)
    if any("must start with" in e for e in errors):
        pass_()
        print("  OK: missing header rejected")
    else:
        fail(f"expected header error, got: {errors}")


def test_validate_missing_required_field() -> None:
    text = """# Pending Contradictions

### CC-a1b2c3d4e5f6: Missing fields

- Severity: High
"""
    errors = _validate_pending_file(text)
    missing = [e for e in errors if "missing required field" in e]
    if len(missing) >= 3:
        pass_()
        print(f"  OK: missing fields detected ({len(missing)} errors)")
    else:
        fail(f"expected >=3 missing field errors, got {len(errors)}: {errors}")


def test_validate_bad_severity() -> None:
    text = """# Pending Contradictions

### CC-a1b2c3d4e5f6: Bad severity

- Severity: CriticalPlus
- Bucket: repo-internal
- Claim: test
- Evidence: test
- Required resolution: test
"""
    errors = _validate_pending_file(text)
    if any("invalid severity" in e for e in errors):
        pass_()
        print("  OK: bad severity rejected")
    else:
        fail(f"expected severity error, got: {errors}")


def test_validate_bad_bucket() -> None:
    text = """# Pending Contradictions

### CC-a1b2c3d4e5f6: Bad bucket

- Severity: High
- Bucket: invalid-bucket
- Claim: test
- Evidence: test
- Required resolution: test
"""
    errors = _validate_pending_file(text)
    if any("invalid bucket" in e for e in errors):
        pass_()
        print("  OK: bad bucket rejected")
    else:
        fail(f"expected bucket error, got: {errors}")


# ── Backup/restore tests ──

def test_backup_and_restore() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        pp = os.path.join(tmp, "PENDING_CONTRADICTIONS.md")
        original = "# Pending Contradictions\n\nOriginal content.\n"
        with open(pp, "w") as f:
            f.write(original)
        backup = _backup_pending(pp)
        if backup and os.path.isfile(backup):
            pass_()
            print("  OK: backup file created")
        else:
            fail("backup file not created")
            return
        backup_content = open(backup).read()
        if backup_content == original:
            pass_()
            print("  OK: backup content matches original")
        else:
            fail("backup content mismatch")

        # Modify original
        with open(pp, "w") as f:
            f.write("MODIFIED\n")
        _restore_pending(pp, backup)
        restored = open(pp).read()
        if restored == original:
            pass_()
            print("  OK: restore works correctly")
        else:
            fail(f"restore mismatch: expected {original!r}, got {restored!r}")


# ── Diff computation tests ──

def test_compute_diff_added() -> None:
    before = "# Pending Contradictions\n\n"
    after = """# Pending Contradictions

### CC-aaa000aaa000: New item

- Severity: High
- Bucket: repo-internal
- Claim: test
- Evidence: test
- Required resolution: test
"""
    diff = _compute_pending_diff(before, after)
    if diff["added_ids"] == ["CC-aaa000aaa000"]:
        pass_()
        print("  OK: added item detected")
    else:
        fail(f"expected added [CC-aaa000aaa000], got {diff['added_ids']}")
    if diff["removed_ids"] == []:
        pass_()
    else:
        fail(f"expected no removed, got {diff['removed_ids']}")
    if diff["total_after"] == 1:
        pass_()
    else:
        fail(f"expected total_after=1, got {diff['total_after']}")


def test_compute_diff_removed() -> None:
    before = """# Pending Contradictions

### CC-bbb000bbb000: Removed item

- Severity: Low
- Bucket: repo-internal
- Claim: test
- Evidence: test
- Required resolution: test
"""
    after = "# Pending Contradictions\n\n"
    diff = _compute_pending_diff(before, after)
    if diff["removed_ids"] == ["CC-bbb000bbb000"]:
        pass_()
        print("  OK: removed item detected")
    else:
        fail(f"expected removed [CC-bbb000bbb000], got {diff['removed_ids']}")


def test_compute_diff_severity_counts() -> None:
    text = """# Pending Contradictions

### CC-111: Critical one

- Severity: Critical
- Bucket: repo-internal
- Claim: c1
- Evidence: e1
- Required resolution: r1

### CC-222: High one

- Severity: High
- Bucket: repo-vs-agent-state
- Claim: c2
- Evidence: e2
- Required resolution: r2
"""
    diff = _compute_pending_diff("", text)
    if diff["severity_counts"].get("Critical") == 1 and diff["severity_counts"].get("High") == 1:
        pass_()
        print("  OK: severity counts correct")
    else:
        fail(f"unexpected severity counts: {diff['severity_counts']}")
    if diff["total_after"] == 2:
        pass_()
    else:
        fail(f"expected total_after=2, got {diff['total_after']}")


# ── Prompt content tests ──

def test_prompt_says_stdout_informational() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo = os.path.join(tmp, "repo")
        make_repo(repo, "main")
        commit(repo)
        run_check(tmp, "init", "--repo", repo)
        r = run_check(tmp, "render-prompt", "--repo", repo)
        if "Stdout is informational" in r.stdout or "stdout is informational" in r.stdout.lower():
            pass_()
            print("  OK: prompt says stdout is informational")
        else:
            fail("prompt missing 'stdout is informational'")


def test_prompt_says_allowed_writes() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo = os.path.join(tmp, "repo")
        make_repo(repo, "main")
        commit(repo)
        run_check(tmp, "init", "--repo", repo)
        r = run_check(tmp, "render-prompt", "--repo", repo)
        if "Allowed writes" in r.stdout or "allowed writes" in r.stdout.lower():
            pass_()
            print("  OK: prompt mentions allowed writes")
        else:
            fail("prompt missing 'Allowed writes'")


# ── Existing helpers ──

def test_parse_existing_items() -> None:
    text = """# Pending Contradictions

### CC-abc123: First

- Severity: High

### CC-def456: Second

- Severity: Low
"""
    items = _parse_existing_items(text)
    if len(items) == 2 and "CC-abc123" in items and "CC-def456" in items:
        pass_()
        print("  OK: existing items parsed")
    else:
        fail(f"expected 2 items, got {len(items)}: {list(items.keys())}")


def test_extract_item_id() -> None:
    bid = _extract_item_id("### CC-a1b2c3d4e5f6: Title here\n")
    if bid == "CC-a1b2c3d4e5f6":
        pass_()
        print("  OK: item ID extracted")
    else:
        fail(f"expected CC-a1b2c3d4e5f6, got {bid}")
    none_bid = _extract_item_id("Some random text")
    if none_bid is None:
        pass_()
        print("  OK: no ID in non-matching text")
    else:
        fail(f"expected None, got {none_bid}")


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


def test_profile_docs_path() -> None:
    """Prove profile_docs resolves to <profile_dir>/docs not <profile_dir>/junie-live/docs."""
    with tempfile.TemporaryDirectory() as tmp:
        repo = os.path.join(tmp, "repo")
        make_repo(repo, "main")
        commit(repo)

        profile_home = os.path.join(tmp, "profiles", "test-profile")
        profile_docs_dir = os.path.join(profile_home, "docs")
        os.makedirs(profile_docs_dir, exist_ok=True)
        with open(os.path.join(profile_docs_dir, "strategy.md"), "w") as f:
            f.write("# Strategy\n")

        hermes_home = os.path.join(tmp, "hermes")
        os.makedirs(hermes_home, exist_ok=True)
        env = {
            **os.environ,
            "HERMES_HOME": hermes_home,
            "HERMES_PROFILE_DIR": profile_home,
            "HERMES_PROFILE": "test-profile",
        }
        run_check(tmp, "init", "--repo", repo, hermes_home_override=hermes_home, env_override=env)

        # render-prompt should reference the correct docs path
        r = run_check(tmp, "render-prompt", "--repo", repo, hermes_home_override=hermes_home, env_override=env)
        if profile_docs_dir in r.stdout:
            pass_()
            print(f"  OK: profile docs path correct in render-prompt: {profile_docs_dir}")
        else:
            fail(f"profile docs path {profile_docs_dir} not found in render-prompt output")

        # dry-run should write prompt.md with the correct docs path
        r2 = run_check(tmp, "run", "--repo", repo, "--dry-run", hermes_home_override=hermes_home, env_override=env)
        if "DRY RUN" not in r2.stdout:
            fail("dry-run output missing")
            return
        # Find the prompt file path from dry-run output
        prompt_path = None
        for line in r2.stdout.splitlines():
            if "Prompt written to:" in line:
                prompt_path = line.split("Prompt written to:", 1)[1].strip()
                break
        if not prompt_path or not os.path.isfile(prompt_path):
            fail("prompt file not written in dry-run mode")
            return
        prompt_content = open(prompt_path).read()
        if profile_docs_dir in prompt_content:
            pass_()
            print(f"  OK: profile docs path correct in dry-run prompt: {profile_docs_dir}")
        else:
            fail(f"profile docs path {profile_docs_dir} not found in dry-run prompt")
        # Also check that the wrong path (junie-live/docs) is NOT present
        wrong_path = os.path.join(profile_home, "junie-live", "docs")
        if wrong_path not in prompt_content:
            pass_()
            print(f"  OK: wrong path {wrong_path} NOT present in prompt")
        else:
            fail(f"wrong path {wrong_path} IS present in prompt, but should not be")


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
        ("validate empty canonical", test_validate_empty_canonical),
        ("validate valid block", test_validate_valid_block),
        ("validate missing header", test_validate_missing_header),
        ("validate missing required fields", test_validate_missing_required_field),
        ("validate bad severity", test_validate_bad_severity),
        ("validate bad bucket", test_validate_bad_bucket),
        ("backup and restore", test_backup_and_restore),
        ("diff added", test_compute_diff_added),
        ("diff removed", test_compute_diff_removed),
        ("diff severity counts", test_compute_diff_severity_counts),
        ("prompt says stdout informational", test_prompt_says_stdout_informational),
        ("prompt says allowed writes", test_prompt_says_allowed_writes),
        ("parse existing items", test_parse_existing_items),
        ("extract item id", test_extract_item_id),
        ("blocked artifacts written", test_blocked_artifacts_written),
        ("profile docs path correct (not junie-live/docs)", test_profile_docs_path),
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

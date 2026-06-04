#!/usr/bin/env bash
# Test consistency check runner: init, preflight, prompt rendering, and
# state management. Run from the hermes/ subtree root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/initialization/scripts/consistency_check.py"

fail_count=0
pass_count=0

pass() { pass_count=$((pass_count + 1)); }
fail() { printf '  FAIL: %s\n' "$*" >&2; fail_count=$((fail_count + 1)); }

# Helper: run the consistency_check.py with a temp HERMES_HOME
run_check() {
  HERMES_HOME="$1" HERMES_PROFILE="test-profile" python3 "$SCRIPT" "${@:2}" 2>&1
}

# Helper: create a temp git repo
make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@test.com"
  git -C "$dir" config user.name "Test"
}

# ════════════════════════════════════════════════════════════════
printf '=== Test 1: py_compile consistency_check.py ===\n'
if python3 -m py_compile "$SCRIPT"; then
  pass
  printf '  OK: py_compile passed\n'
else
  fail "py_compile failed"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 2: init with main branch ===\n'
tmpdir="$(mktemp -d)"
repo="$tmpdir/repo"
make_repo "$repo"
git -C "$repo" commit --allow-empty -m "initial" >/dev/null 2>&1

result=$(run_check "$tmpdir" init --repo "$repo" 2>&1) && pass || fail "init with main failed: $result"
printf '  %s\n' "$result"

state_file="$tmpdir/profiles/test-profile/junie-live/state/consistency/consistency-state.json"
if [[ -f "$state_file" ]]; then
  pass
  main_branch=$(python3 -c "import json; print(json.load(open('$state_file'))['main_branch'])")
  if [[ "$main_branch" == "main" || "$main_branch" == "master" ]]; then
    pass
    printf '  OK: main_branch=%s\n' "$main_branch"
  else
    fail "unexpected main_branch: $main_branch"
  fi
else
  fail "state file not created"
fi

pending_file="$tmpdir/profiles/test-profile/junie-live/state/consistency/PENDING_CONTRADICTIONS.md"
if [[ -f "$pending_file" ]]; then
  pass
  printf '  OK: PENDING_CONTRADICTIONS.md created\n'
else
  fail "PENDING_CONTRADICTIONS.md not created"
fi

rm -rf "$tmpdir"

# ════════════════════════════════════════════════════════════════
printf '=== Test 3: init with master branch (no main) ===\n'
tmpdir="$(mktemp -d)"
repo="$tmpdir/repo"
make_repo "$repo"
git -C "$repo" checkout -b master >/dev/null 2>&1
git -C "$repo" commit --allow-empty -m "initial" >/dev/null 2>&1

result=$(run_check "$tmpdir" init --repo "$repo" 2>&1) && pass || fail "init with master failed: $result"
state_file="$tmpdir/profiles/test-profile/junie-live/state/consistency/consistency-state.json"
if [[ -f "$state_file" ]]; then
  main_branch=$(python3 -c "import json; print(json.load(open('$state_file'))['main_branch'])")
  if [[ "$main_branch" == "master" ]]; then
    pass
    printf '  OK: master branch detected: %s\n' "$main_branch"
  else
    fail "expected master, got $main_branch"
  fi
fi
rm -rf "$tmpdir"

# ════════════════════════════════════════════════════════════════
printf '=== Test 4: init with no branches returns error ===\n'
tmpdir="$(mktemp -d)"
repo="$tmpdir/repo"
mkdir -p "$repo"
git -C "$repo" init -q >/dev/null 2>&1
# Empty repo with no commits has no branches

result=$(run_check "$tmpdir" init --repo "$repo" 2>&1) && fail "init should fail on empty repo" || pass
printf '  %s\n' "$result"
rm -rf "$tmpdir"

# ════════════════════════════════════════════════════════════════
printf '=== Test 5: existing state preserved without --force ===\n'
tmpdir="$(mktemp -d)"
repo="$tmpdir/repo"
make_repo "$repo"
git -C "$repo" commit --allow-empty -m "initial" >/dev/null 2>&1

run_check "$tmpdir" init --repo "$repo" >/dev/null 2>&1
# Second init without force should say "already exists"
result=$(run_check "$tmpdir" init --repo "$repo" 2>&1) && pass || fail "second init should succeed"
if echo "$result" | grep -q "already exists"; then
  pass
  printf '  OK: existing state preserved\n'
else
  fail "expected 'already exists' message, got: $result"
fi
rm -rf "$tmpdir"

# ════════════════════════════════════════════════════════════════
printf '=== Test 6: init with --force overwrites existing state ===\n'
tmpdir="$(mktemp -d)"
repo="$tmpdir/repo"
make_repo "$repo"
git -C "$repo" commit --allow-empty -m "initial" >/dev/null 2>&1

run_check "$tmpdir" init --repo "$repo" >/dev/null 2>&1
run_check "$tmpdir" init --repo "$repo" --force >/dev/null 2>&1 && pass || fail "force init failed"
state_file="$tmpdir/profiles/test-profile/junie-live/state/consistency/consistency-state.json"
if [[ -f "$state_file" ]]; then
  pass
  printf '  OK: state file exists after force init\n'
else
  fail "state file missing after force init"
fi
rm -rf "$tmpdir"

# ════════════════════════════════════════════════════════════════
printf '=== Test 7: render-prompt works after init ===\n'
tmpdir="$(mktemp -d)"
repo="$tmpdir/repo"
make_repo "$repo"
git -C "$repo" commit --allow-empty -m "initial" >/dev/null 2>&1
git -C "$repo" commit --allow-empty -m "second" >/dev/null 2>&1

run_check "$tmpdir" init --repo "$repo" >/dev/null 2>&1
result=$(run_check "$tmpdir" render-prompt --repo "$repo" 2>&1) && pass || fail "render-prompt failed"
if echo "$result" | grep -q "Consistency Check"; then
  pass
  printf '  OK: prompt rendered\n'
else
  fail "prompt does not contain expected heading"
fi
rm -rf "$tmpdir"

# ════════════════════════════════════════════════════════════════
printf '=== Test 8: run --dry-run works ===\n'
tmpdir="$(mktemp -d)"
repo="$tmpdir/repo"
make_repo "$repo"
git -C "$repo" commit --allow-empty -m "initial" >/dev/null 2>&1

run_check "$tmpdir" init --repo "$repo" >/dev/null 2>&1
result=$(run_check "$tmpdir" run --repo "$repo" --dry-run 2>&1) && pass || fail "dry-run failed"
if echo "$result" | grep -q "DRY RUN"; then
  pass
  printf '  OK: dry-run mode works\n'
else
  fail "dry-run output missing"
fi
rm -rf "$tmpdir"

# ════════════════════════════════════════════════════════════════
printf '=== Test 9: run blocks on dirty worktree ===\n'
tmpdir="$(mktemp -d)"
repo="$tmpdir/repo"
make_repo "$repo"
git -C "$repo" commit --allow-empty -m "initial" >/dev/null 2>&1
echo "dirty" > "$repo/dirty.txt"

run_check "$tmpdir" init --repo "$repo" --force >/dev/null 2>&1
result=$(run_check "$tmpdir" run --repo "$repo" 2>&1) && fail "dirty run should fail" || pass
if echo "$result" | grep -qi "dirty\|BLOCKED"; then
  pass
  printf '  OK: dirty worktree blocked\n'
else
  fail "expected BLOCKED message, got: $result"
fi
rm -rf "$tmpdir"

# ════════════════════════════════════════════════════════════════
printf '=== Test 10: Atomic state write survives partial corruption ===\n'
tmpdir="$(mktemp -d)"
repo="$tmpdir/repo"
make_repo "$repo"
git -C "$repo" commit --allow-empty -m "initial" >/dev/null 2>&1

run_check "$tmpdir" init --repo "$repo" >/dev/null 2>&1
state_file="$tmpdir/profiles/test-profile/junie-live/state/consistency/consistency-state.json"
# Corrupt the file
echo "not json" > "$state_file"
# Read should return None without crashing
result=$(run_check "$tmpdir" render-prompt --repo "$repo" 2>&1) && fail "should fail with corrupt state" || pass
if echo "$result" | grep -qi "not found\|ERROR"; then
  pass
  printf '  OK: corrupt state detected\n'
fi
rm -rf "$tmpdir"

# ════════════════════════════════════════════════════════════════
printf '\n=== Results ===\n'
printf 'Passed: %d, Failed: %d\n' "$pass_count" "$fail_count"

if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi

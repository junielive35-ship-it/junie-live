#!/usr/bin/env bash
set -euo pipefail

# verify.sh — Repository verification for Junie Live (hermes implementation)
#
# Checks bash syntax, markdown links, table syntax, and repo hygiene.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log() { printf '==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

log "preflight clean working tree"
if git status --porcelain --untracked-files=all | grep -q .; then
  git status --short --branch --untracked-files=all >&2
  fail "working tree is not clean before verify; commit, stash, or remove changes first"
fi

log "bash syntax"
script_count=0
for script in scripts/*.sh; do
  [[ -f "$script" ]] || continue
  bash -n "$script" || fail "bash syntax error in $script"
  script_count=$((script_count + 1))
done
[[ "$script_count" -ge 2 ]] || fail "expected at least 2 bash scripts in scripts/, found $script_count"

log "local markdown links"
while IFS= read -r file; do
  while IFS= read -r target; do
    [[ -z "$target" ]] && continue
    [[ "$target" =~ ^https?://|^mailto:|^# ]] && continue
    target="${target%%#*}"
    [[ -z "$target" ]] && continue
    [[ "$target" = /* ]] && continue
    path="$(dirname "$file")/$target"
    [[ -e "$path" ]] || fail "broken link in ${file#./}: $target"
  done < <(grep -oE '\[[^]]+\]\([^)]+\)' "$file" | sed -E 's/^.*\(([^)]+)\)$/\1/' || true)
done < <(find . -path './.git' -prune -o -name '*.md' -type f -print)

log "git whitespace"
if ! git diff --check HEAD -- 2>/dev/null; then
  fail "git diff --check found whitespace errors"
fi

log "hire-junie.sh /start initialization quick command alias"
# Verify the direct config.yaml writer maps /start to a normal initialization
# agent turn via /steer, not to session reset (/new).
forbidden_reset_target="quick_commands.start.target /""new|st\\['target'\\] = '/""new'"
forbidden_reset_label="/start → /""new|/start -> /""new"
if grep -qF "quick_commands" "$ROOT/scripts/hire-junie.sh" && \
   grep -qE "'type'.*'alias'" "$ROOT/scripts/hire-junie.sh" && \
   grep -qE "START_ALIAS_TARGET.*/steer.*initialization" "$ROOT/scripts/hire-junie.sh" && \
   grep -qE "st\['target'\] = target" "$ROOT/scripts/hire-junie.sh" && \
   ! grep -qE "$forbidden_reset_target|$forbidden_reset_label" "$ROOT/scripts/hire-junie.sh"; then
  :
else
  fail "hire-junie.sh must map /start to /steer initialization, not session reset"
fi

log "dump-junie.sh distribution regression guard"
# dump-junie.sh lives in distribution/scripts/ so the Hermes profile
# distribution installs it into the profile at $PROFILE_DIR/scripts/dump-junie.sh,
# making it runnable on a live VM without the repo checkout.
if [[ -f "$ROOT/distribution/scripts/dump-junie.sh" ]]; then
  [[ -x "$ROOT/distribution/scripts/dump-junie.sh" ]] || \
    fail "distribution/scripts/dump-junie.sh exists but is not executable"
else
  fail "distribution/scripts/dump-junie.sh is missing"
fi
# hire-junie.sh now uses hermes profile delete + install for cleanup.

log "variant-minimal regression guard"
offenders=$(grep -rn --exclude-dir=.git -- '--variant minimal' . 2>/dev/null | \
  grep -v '^\./docs/implementation-status.md:' | \
  grep -v '^\./scripts/verify.sh:' || true)
if [[ -n "$offenders" ]]; then
  printf '%s\n' "$offenders" >&2
  fail "variant-minimal regression detected: see offending lines above"
fi

log "directory structure"
for required_dir in \
    distribution \
    distribution/docs \
    distribution/skills \
    scripts \
    docs \
    distribution/plugins/senior-task \
    distribution/plugins/senior-runner \
    distribution/plugins/senior-runner/scripts \
    distribution/profiles/senior-dev \
    distribution/scripts; do
  [[ -d "$required_dir" ]] || fail "missing required directory: $required_dir"
done

# Also verify that distribution has its manifest
[[ -f "distribution/distribution.yaml" ]] || fail "missing distribution.yaml"

for required_file in \
    README.md \
    distribution/distribution.yaml \
    distribution/SOUL.md \
    distribution/INITIALIZATION.md \
    distribution/memory-seed.md \
    distribution/HERMES.seed.md \
    distribution/docs/tools.md \
    distribution/scripts/dump-junie.sh \
    distribution/scripts/initialization-check.sh \
    distribution/junie/AGENTS.md \
    distribution/plugins/senior-task/plugin.yaml \
    distribution/plugins/senior-task/__init__.py \
    distribution/plugins/senior-task/tools.py \
    distribution/plugins/senior-runner/plugin.yaml \
    distribution/plugins/senior-runner/__init__.py \
    distribution/plugins/senior-runner/tools.py \
    distribution/plugins/senior-runner/runner.py \
    distribution/plugins/senior-runner/state.py \
    distribution/plugins/senior-runner/scripts/run-coding-task.sh \
    distribution/profiles/senior-dev/distribution.yaml \
    distribution/profiles/senior-dev/config.yaml \
    distribution/profiles/senior-dev/SOUL.md \
    scripts/install-senior-dev-profile.sh \
    scripts/test-install-senior-dev.sh; do
  [[ -f "$required_file" ]] || fail "missing required file: $required_file"
done

log "skill frontmatter"
for skill_dir in distribution/skills/*/; do
  skill_file="$skill_dir/SKILL.md"
  [[ -f "$skill_file" ]] || continue
  grep -q '^---$' "$skill_file" || fail "skill missing frontmatter: $skill_file"
  grep -q '^name: ' "$skill_file" || fail "skill missing name in frontmatter: $skill_file"
  grep -q '^description: ' "$skill_file" || fail "skill missing description in frontmatter: $skill_file"
done

log "plugin bash syntax"
for plugin_script in distribution/plugins/*/scripts/*.sh; do
  [[ -f "$plugin_script" ]] || continue
  bash -n "$plugin_script" || fail "bash syntax error in $plugin_script"
done

log "plugin python syntax"
for plugin_py in distribution/plugins/*/*.py; do
  [[ -f "$plugin_py" ]] || continue
  python3 -m py_compile "$plugin_py" || fail "python syntax error in $plugin_py"
done

log "dump/rehire disaster recovery tests"
"$ROOT/scripts/test-dump-rehire.sh" || fail "dump/rehire disaster recovery tests failed"

log "initialization gate regression tests"
"$ROOT/scripts/test-initialization-gate.sh" || fail "initialization gate tests failed"

log "senior-task plugin tests"
"$ROOT/scripts/test-senior-task.sh" || fail "senior-task plugin tests failed"

log "senior-dev install script tests"
"$ROOT/scripts/test-install-senior-dev.sh" || fail "senior-dev install script tests failed"

log "senior-dev Kanban toolset split tests"
"$ROOT/scripts/test-senior-dev-kanban-toolsets.sh" || fail "senior-dev Kanban toolset split tests failed"

log "senior-runner synchronous runner tests"
"$ROOT/scripts/test-senior-runner.sh" || fail "senior-runner synchronous runner tests failed"

log "junie_runtime package import and tests"
if python3 -c "import junie_runtime; print(junie_runtime.__version__)" 2>/dev/null; then
  log "  junie_runtime import OK"
else
  fail "junie_runtime package is not importable; run 'python3 -m pip install -e hermes/junie_runtime'"
fi
python3 -m pytest "$ROOT/junie_runtime/tests" -q 2>/dev/null || python3 -m pytest "$ROOT/junie_runtime/tests" -q || fail "junie_runtime tests failed"

log "all checks passed"

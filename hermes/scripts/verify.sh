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

log "hire-junie.sh /start quick command alias"
# Verify the direct config.yaml writer sets quick_commands.start
if grep -qF "quick_commands" "$ROOT/scripts/hire-junie.sh" && \
   grep -qE "'type'.*'alias'" "$ROOT/scripts/hire-junie.sh" && \
   grep -qE "'target'.*'/new'" "$ROOT/scripts/hire-junie.sh"; then
  :
else
  fail "hire-junie.sh missing /start → /new quick command alias config"
fi

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
    initialization \
    initialization/docs \
    initialization/skills \
    scripts \
    docs \
    initialization/plugins/marinator-delegation \
    initialization/plugins/marinator-delegation/scripts \
    initialization/plugins/autonomous-work \
    initialization/plugins/autonomous-work/scripts; do
  [[ -d "$required_dir" ]] || fail "missing required directory: $required_dir"
done

for required_file in \
    README.md \
    initialization/SOUL.md \
    initialization/INITIALIZATION.md \
    initialization/memory-seed.md \
    initialization/docs/seed-HERMES.md \
    initialization/docs/tools.md \
    initialization/plugins/marinator-delegation/plugin.yaml \
    initialization/plugins/marinator-delegation/__init__.py \
    initialization/plugins/marinator-delegation/tools.py \
    initialization/plugins/marinator-delegation/runner.py \
    initialization/plugins/marinator-delegation/state.py \
    initialization/plugins/marinator-delegation/scripts/marinator-worker.sh \
    initialization/plugins/autonomous-work/plugin.yaml \
    initialization/plugins/autonomous-work/__init__.py \
    initialization/plugins/autonomous-work/tools.py \
    initialization/plugins/autonomous-work/state.py \
    initialization/plugins/autonomous-work/prompts.py \
    initialization/plugins/autonomous-work/backlog.py \
    initialization/plugins/autonomous-work/scripts/aw-runner.sh \
    initialization/docs/backlog-protocol.md; do
  [[ -f "$required_file" ]] || fail "missing required file: $required_file"
done

log "skill frontmatter"
for skill_dir in initialization/skills/*/; do
  skill_file="$skill_dir/SKILL.md"
  [[ -f "$skill_file" ]] || continue
  grep -q '^---$' "$skill_file" || fail "skill missing frontmatter: $skill_file"
  grep -q '^name: ' "$skill_file" || fail "skill missing name in frontmatter: $skill_file"
  grep -q '^description: ' "$skill_file" || fail "skill missing description in frontmatter: $skill_file"
done

log "marinator worker progress-summary regression guard"
WORKER_SH="initialization/plugins/marinator-delegation/scripts/marinator-worker.sh"
if [[ -f "$WORKER_SH" ]]; then
  # Positive checks: required prompt directives
  grep -qF 'Use only the stdout/stderr excerpts below' "$WORKER_SH" || \
    fail "$WORKER_SH: missing 'Use only the stdout/stderr excerpts below' in prompt"
  grep -qF 'Answer in no more than 150 words' "$WORKER_SH" || \
    fail "$WORKER_SH: missing 'Answer in no more than 150 words' in prompt"
  grep -qF 'Do not mention files/logs being missing' "$WORKER_SH" || \
    fail "$WORKER_SH: missing 'Do not mention files/logs being missing' in prompt"

  # Negative checks: no wrapper artifacts in progress context
  if grep -qF '## artifact paths' "$WORKER_SH"; then
    fail "$WORKER_SH: artifact paths section still present in progress context"
  fi
  if grep -qF '## status.json' "$WORKER_SH"; then
    fail "$WORKER_SH: status.json section still present in progress context"
  fi
  if grep -qF '## recent events.jsonl' "$WORKER_SH"; then
    fail "$WORKER_SH: events.jsonl section still present in progress context"
  fi
  if grep -qF '## runner.log tail' "$WORKER_SH"; then
    fail "$WORKER_SH: runner.log tail section still present in progress context"
  fi

  # Sections must exist (regression guard: interval status/delta preserved)
  grep -qF '## stdout/stderr interval status' "$WORKER_SH" || \
    fail "$WORKER_SH: missing '## stdout/stderr interval status' section"
  grep -qF '## stdout/stderr delta' "$WORKER_SH" || \
    fail "$WORKER_SH: missing '## stdout/stderr delta' section"

  # Must NOT pipe context_file through tail -c (would trim sections)
  if grep -qE '\|\s*tail\s+-c\s+[0-9]+\s*>\s*"\$context_file"' "$WORKER_SH"; then
    fail "$WORKER_SH: context_file is piped through tail -c; interval status/delta would be trimmed"
  fi

  # Must write context_file directly (confirming sections land in final output)
  grep -qE '>\s*"\$context_file"' "$WORKER_SH" || \
    fail "$WORKER_SH: no direct write to context_file; sections would be dropped"

  # [:700] truncation must not appear in non-comment lines
  if grep -qF '[:700]' "$WORKER_SH"; then
    if grep -nE '\[:700\]' "$WORKER_SH" | grep -vE '^\s*#' | grep -q .; then
      fail "$WORKER_SH: [:700] truncation still present in non-comment line"
    fi
  fi
else
  fail "missing $WORKER_SH"
fi

log "marinator plugin bash syntax"
for plugin_script in initialization/plugins/*/scripts/*.sh; do
  [[ -f "$plugin_script" ]] || continue
  bash -n "$plugin_script" || fail "bash syntax error in $plugin_script"
done

log "marinator plugin python syntax"
for plugin_py in initialization/plugins/*/*.py; do
  [[ -f "$plugin_py" ]] || continue
  python3 -m py_compile "$plugin_py" || fail "python syntax error in $plugin_py"
done

log "autonomous-work plugin tests"
"$ROOT/scripts/test-autonomous-work.sh" || fail "autonomous-work plugin tests failed"

log "initialization gate regression tests"
"$ROOT/scripts/test-initialization-gate.sh" || fail "initialization gate tests failed"

log "all checks passed"

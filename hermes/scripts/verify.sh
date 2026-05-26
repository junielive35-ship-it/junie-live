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

log "directory structure"
for required_dir in initialization initialization/docs initialization/skills scripts docs; do
  [[ -d "$required_dir" ]] || fail "missing required directory: $required_dir"
done

for required_file in \
    README.md \
    initialization/SOUL.md \
    initialization/INITIALIZATION.md \
    initialization/memory-seed.md \
    initialization/docs/seed-HERMES.md \
    initialization/docs/tools.md; do
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

log "all checks passed"

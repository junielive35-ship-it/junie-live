#!/usr/bin/env bash
set -euo pipefail

# MD consistency scan — minimal first implementation.
#
# Checks backtick-quoted file references in repo markdown docs to detect
# stale or broken paths.  Part of day_to_day_routines.md routine #7.
# Semantic contradiction detection is not yet implemented.
#
# Scans *.md at repo root and docs/ (not initialization/ seed templates).
#
# Output: machine-readable kv lines.
# Exit codes: 0 = clean, 1 = broken refs found.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$ROOT"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    *) printf 'Unknown: %s\n' "$1" >&2; exit 2 ;;
  esac
done

checked=0
broken=0
broken_list=()

should_skip() {
  local ref="$1"
  [[ "$ref" =~ ^https?:// ]] && return 0
  [[ "$ref" == --* ]] && return 0
  [[ "$ref" == "#"* ]] && return 0
  [[ "$ref" == "/"* ]] && return 0
  [[ "$ref" == "~"* ]] && return 0
  [[ "$ref" == *" "* ]] && return 0
  [[ "$ref" == *"="* ]] && return 0
  [[ "$ref" == *'$'* ]] && return 0
  [[ "$ref" == *"*"* ]] && return 0
  [[ "$ref" == .openclaw/* ]] && return 0
  # Workspace artifact directories referenced in repo hygiene rules
  [[ "$ref" == "state/" ]] && return 0
  # Template/placeholder patterns (e.g., memory/YYYY-MM-DD.md)
  [[ "$ref" =~ YYYY ]] && return 0
  return 1
}

is_likely_path() {
  local ref="$1"
  # Script, markdown, and python files are always likely repo paths.
  [[ "$ref" =~ \.(sh|md|py)$ ]] && return 0
  # json/txt/crontab require a directory component to avoid bare workspace filenames
  # like holder.json that are prose references, not repo file paths.
  [[ "$ref" == */* && "$ref" =~ \.(json|txt|crontab)$ ]] && return 0
  # Directory references ending with /
  [[ "$ref" =~ /$ ]] && return 0
  return 1
}

is_workspace_file() {
  # All-uppercase .md files (MEMORY.md, USER.md, TOOLS.md, etc.) are OpenClaw
  # workspace files that may not exist in the repo but are valid references.
  [[ "$1" =~ ^[A-Z][A-Z_]*\.md$ ]]
}

resolve_ref() {
  local ref="$1" md_dir="$2"
  # Repo root
  [[ -e "$repo/$ref" ]] && return 0
  # Relative to markdown file directory
  [[ -e "$md_dir/$ref" ]] && return 0
  # Bare .sh files -> try scripts/ prefix
  if [[ "$ref" =~ \.sh$ && ! "$ref" == */* ]]; then
    [[ -e "$repo/scripts/$ref" ]] && return 0
  fi
  # Single-component paths (no intermediate /) -> try initialization/ prefix
  local base="${ref%/}"
  if [[ "$base" != */* ]]; then
    [[ -e "$repo/initialization/$ref" ]] && return 0
  fi
  # docs/ paths -> try initialization/docs/
  if [[ "$ref" == docs/* ]]; then
    [[ -e "$repo/initialization/$ref" ]] && return 0
  fi
  # Repo-name-prefixed paths (e.g., junie-live/initialization/). In temp
  # verification clones, the directory name may differ from the product repo name,
  # so also recognize the stable Junie Live repo prefix.
  local repo_basename
  repo_basename="$(basename "$repo")"
  if [[ "$ref" == "$repo_basename/"* ]]; then
    local stripped="${ref#"$repo_basename"/}"
    [[ -e "$repo/$stripped" ]] && return 0
  fi
  if [[ "$ref" == "junie-live/"* ]]; then
    local stripped="${ref#junie-live/}"
    [[ -e "$repo/$stripped" ]] && return 0
  fi
  return 1
}

while IFS= read -r md_file; do
  [[ -f "$md_file" ]] || continue
  md_dir="$(dirname "$md_file")"

  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    should_skip "$ref" && continue
    is_likely_path "$ref" || continue

    checked=$((checked + 1))

    if ! resolve_ref "$ref" "$md_dir"; then
      # Workspace files (all-uppercase .md) are valid even without repo presence
      is_workspace_file "$ref" && continue
      broken=$((broken + 1))
      rel_md="${md_file#"$repo"/}"
      broken_list+=("${rel_md}:${ref}")
    fi
  done < <(grep -oE '`[^`]+`' "$md_file" | sed 's/^`//;s/`$//')
done < <({
  # In a git repo, respect .gitignore by using git ls-files for tracked files
  # and untracked-but-not-ignored for new files. Fall back to find for non-git dirs.
  if git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$repo" ls-files --cached --others --exclude-standard '*.md' | while IFS= read -r f; do
      rp="$repo/$f"
      case "$f" in
        docs/*|*.md)
          [[ "$f" == */* && "$f" != docs/* ]] && continue
          printf '%s\n' "$rp"
          ;;
      esac
    done
  else
    find "$repo" -maxdepth 1 -name '*.md' -type f -print
    find "$repo/docs" -name '*.md' -type f -print 2>/dev/null
  fi
} | sort)

printf 'checked=%s\n' "$checked"
printf 'broken=%s\n' "$broken"

if [[ "$broken" -gt 0 ]]; then
  for b in "${broken_list[@]}"; do
    printf 'broken_ref=%s\n' "$b"
  done
  exit 1
fi
exit 0

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Default repo root: the enclosing git repo if there is one (source repo or a
# git-tracked workspace), otherwise the parent of this script's directory.
repo_root_default() {
  git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/.." && pwd)
}
repo="${REPO:-$(repo_root_default)}"
stale_hours=24
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --stale-hours) stale_hours="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    *) printf 'Unknown: %s\n' "$1" >&2; exit 2 ;;
  esac
done

ps_out=$(mktemp)
trap 'rm -f "$ps_out"' EXIT
# pr-status.sh is a sibling in both the source repo and a hired workspace.
"$SCRIPT_DIR/pr-status.sh" --repo "$repo" --stale-hours "$stale_hours" >"$ps_out" 2>/dev/null || true

read_val() { grep "^${1}=" "$ps_out" 2>/dev/null | sed 's/^[^=]*=//' || true; }

pr_check=$(read_val pr_check_available)
open_prs=$(read_val open_prs)

updated=0
commented=0
details_parts=()

if [[ "$pr_check" != "true" || "${open_prs:-0}" -eq 0 ]]; then
  printf 'updated=0\n'
  printf 'commented=0\n'
  printf 'actions=0\n'
  printf 'details=No PR follow-up needed\n'
  exit 0
fi

for idx in $(seq 1 "$open_prs"); do
  number=$(read_val "pr_${idx}_number")
  ci=$(read_val "pr_${idx}_ci")
  stale=$(read_val "pr_${idx}_stale")
  title=$(read_val "pr_${idx}_title")
  branch=$(read_val "pr_${idx}_branch")

  [[ -n "$number" ]] || continue

  if [[ "$stale" != "true" ]]; then
    continue
  fi

  if [[ "$ci" == "success" ]]; then
    if [[ "$dry_run" == "true" ]]; then
      details_parts+=("WOULD rebase PR #${number} (${branch})")
    else
      if gh pr update-branch "$number" --repo "$repo" 2>/dev/null; then
        updated=$((updated + 1))
        details_parts+=("Rebased PR #${number} (${branch})")
      else
        details_parts+=("Failed to rebase PR #${number} (${branch})")
      fi
    fi
  elif [[ "$ci" == "failure" || "$ci" == "pending" ]]; then
    body="Automated check: this PR has ${ci} CI status and has been stale. Please review and resolve."
    if [[ "$dry_run" == "true" ]]; then
      details_parts+=("WOULD comment on PR #${number} (${branch})")
    else
      if gh pr comment "$number" --repo "$repo" --body "$body" 2>/dev/null; then
        commented=$((commented + 1))
        details_parts+=("Commented on PR #${number} (${branch})")
      else
        details_parts+=("Failed to comment on PR #${number} (${branch})")
      fi
    fi
  fi
done

printf 'updated=%s\n' "$updated"
printf 'commented=%s\n' "$commented"
actions=$((updated + commented))
printf 'actions=%s\n' "$actions"

if [[ "${#details_parts[@]}" -gt 0 ]]; then
  printf 'details=%s\n' "$(IFS='; '; printf '%s' "${details_parts[*]}")"
else
  printf 'details=No PR follow-up needed\n'
fi

exit 0

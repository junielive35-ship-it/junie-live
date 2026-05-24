#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo=""
stale_hours=24

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --stale-hours) stale_hours="$2"; shift 2 ;;
    *) printf 'Unknown: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ -n "$repo" ]] || repo="$ROOT"
cd "$repo"

# ---- gh availability ----
if ! command -v gh &>/dev/null; then
  printf 'pr_check_available=false\n'
  printf 'open_prs=0\n'
  printf 'stale_prs=0\n'
  printf 'failing_ci=0\n'
  printf 'pending_ci=0\n'
  printf 'details=gh CLI not available\n'
  exit 0
fi

now_epoch=$(date +%s)
open_prs=0
stale_prs=0
failing_ci=0
pending_ci=0
details_parts=()
warnings=0
critical=0

while IFS=$'\t' read -r number title headRefName createdAt updatedAt mergeable author login; do
  [[ -n "$number" ]] || continue
  open_prs=$((open_prs + 1))
  idx="$open_prs"

  printf 'pr_%d_number=%s\n' "$idx" "$number"
  printf 'pr_%d_title=%s\n' "$idx" "$title"
  printf 'pr_%d_branch=%s\n' "$idx" "$headRefName"
  printf 'pr_%d_author=%s\n' "$idx" "$author"
  printf 'pr_%d_mergeable=%s\n' "$idx" "$mergeable"

  # Age / staleness
  age_hours=0
  stale=false
  if [[ -n "$updatedAt" ]]; then
    updated_epoch=$(date -d "$updatedAt" +%s 2>/dev/null || echo 0)
    if [[ "$updated_epoch" -gt 0 ]]; then
      age_hours=$(( (now_epoch - updated_epoch) / 3600 ))
      if [[ "$age_hours" -ge "$stale_hours" ]]; then
        stale=true
        stale_prs=$((stale_prs + 1))
      fi
    fi
  fi
  printf 'pr_%d_age_hours=%s\n' "$idx" "$age_hours"
  printf 'pr_%d_stale=%s\n' "$idx" "$stale"

  # CI status via check runs
  ci_status="unknown"
  ci_data=$(gh pr view "$number" --json statusCheckRollup 2>/dev/null) || ci_data=""
  if [[ -n "$ci_data" ]]; then
    # Check for any failing checks
    has_failure=$(printf '%s' "$ci_data" | grep -c '"conclusion"[[:space:]]*:[[:space:]]*"FAILURE"' 2>/dev/null || true)
    has_pending=$(printf '%s' "$ci_data" | grep -c '"status"[[:space:]]*:[[:space:]]*"IN_PROGRESS"' 2>/dev/null || true)
    if [[ "$has_failure" -gt 0 ]]; then
      ci_status="failure"
      failing_ci=$((failing_ci + 1))
    elif [[ "$has_pending" -gt 0 ]]; then
      ci_status="pending"
      pending_ci=$((pending_ci + 1))
    else
      has_success=$(printf '%s' "$ci_data" | grep -c '"conclusion"[[:space:]]*:[[:space:]]*"SUCCESS"' 2>/dev/null || true)
      if [[ "$has_success" -gt 0 ]]; then
        ci_status="success"
      fi
    fi
  fi
  printf 'pr_%d_ci=%s\n' "$idx" "$ci_status"

  if [[ "$ci_status" == "failure" ]]; then
    critical=1
    details_parts+=("PR #${number} CI failing")
  elif [[ "$ci_status" == "pending" ]]; then
    warnings=1
    details_parts+=("PR #${number} CI pending")
  fi
  if [[ "$stale" == "true" ]]; then
    warnings=1
    details_parts+=("PR #${number} stale (${age_hours}h)")
  fi
done < <(gh pr list --state open --json number,title,headRefName,createdAt,updatedAt,mergeable,author --jq '.[] | [.number, .title, .headRefName, .createdAt, .updatedAt, .mergeable, .author.login] | @tsv' 2>/dev/null || true)

# ---- Summary output ----
printf 'pr_check_available=true\n'
printf 'open_prs=%s\n' "$open_prs"
printf 'stale_prs=%s\n' "$stale_prs"
printf 'failing_ci=%s\n' "$failing_ci"
printf 'pending_ci=%s\n' "$pending_ci"

if [[ "$open_prs" -eq 0 ]]; then
  printf 'details=No open PRs\n'
  exit 0
fi

if [[ "${#details_parts[@]}" -gt 0 ]]; then
  printf 'details=%s\n' "$(IFS='; '; printf '%s' "${details_parts[*]}")"
else
  printf 'details=%d open PR(s), all healthy\n' "$open_prs"
fi

if [[ "$critical" -gt 0 ]]; then
  exit 2
elif [[ "$warnings" -gt 0 ]]; then
  exit 1
fi
exit 0

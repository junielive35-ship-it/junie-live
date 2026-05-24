#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/runtime-paths.sh
source "$ROOT/scripts/runtime-paths.sh"
state_dir="${OVERNIGHT_STATE_DIR:-$(junie_overnight_state_dir_default)}"
repo="$ROOT"
format=human
while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-dir) state_dir="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --format) format="$2"; shift 2 ;;
    *) printf 'Unknown: %s\n' "$1" >&2; exit 2 ;;
  esac
done
mkdir -p "$state_dir"
out="$state_dir/morning-report.txt"
state_file="$state_dir/state.json"
field() { local f="$1" k="$2"; grep -o '"'"$k"'"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*"'"$k"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true; }
numfield() { local f="$1" k="$2"; grep -o '"'"$k"'"[[:space:]]*:[[:space:]]*[0-9]*' "$f" 2>/dev/null | head -1 | sed 's/.*"'"$k"'"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/' || true; }

run_id="none"; status="missing"; phase="unknown"; iter=0; verify="unknown"; started=""; updated=""
if [[ -f "$state_file" ]]; then
  run_id=$(field "$state_file" run_id); status=$(field "$state_file" status); phase=$(field "$state_file" phase)
  iter=$(numfield "$state_file" iteration); verify=$(field "$state_file" last_verify_status)
  started=$(field "$state_file" started_at); updated=$(field "$state_file" updated_at)
fi
branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || printf unknown)
last_commit=$(git -C "$repo" log -1 --format='%h %s' 2>/dev/null || printf unknown)
dirty=$(git -C "$repo" status --short 2>/dev/null | wc -l | tr -d ' ')
diff_check="not_run"
if git -C "$repo" diff --check >/tmp/overnight-report-diff-check.$$ 2>&1; then diff_check=passed; else diff_check=failed; fi
rm -f /tmp/overnight-report-diff-check.$$
routine_summary="unavailable"
backlog_queued=0; backlog_in_progress=0; backlog_completed=0; backlog_total=0
if [[ -x "$ROOT/scripts/report.sh" ]]; then
  rpt_out=$("$ROOT/scripts/report.sh" --repo "$repo" 2>/dev/null || true)
  routine_summary=$(printf '%s\n' "$rpt_out" | grep '^summary=' | sed 's/^summary=//' || true)
  backlog_queued=$(printf '%s\n' "$rpt_out" | grep '^backlog_queued=' | sed 's/^backlog_queued=//' || true)
  backlog_in_progress=$(printf '%s\n' "$rpt_out" | grep '^backlog_in_progress=' | sed 's/^backlog_in_progress=//' || true)
  backlog_completed=$(printf '%s\n' "$rpt_out" | grep '^backlog_completed=' | sed 's/^backlog_completed=//' || true)
  backlog_total=$(printf '%s\n' "$rpt_out" | grep '^backlog_total=' | sed 's/^backlog_total=//' || true)
fi
watchdog="not_run"
[[ -f "$state_dir/watchdog-findings.txt" ]] && watchdog=$(tail -n 1 "$state_dir/watchdog-findings.txt" 2>/dev/null || true)

# Commits made during the controller run window
commits_in_window=0; commits_list=""
if [[ -n "$started" && "$started" != "unknown" ]]; then
  commits_list=$(git -C "$repo" log --after="$started" --oneline 2>/dev/null || true)
  if [[ -n "$commits_list" ]]; then
    commits_in_window=$(printf '%s\n' "$commits_list" | wc -l | tr -d ' ')
  fi
fi

# Local failure count from controller state
local_failures=0
if [[ -f "$state_file" ]]; then
  local_failures=$(numfield "$state_file" local_failures)
fi

{
if [[ "$format" == "kv" ]]; then
  printf 'run_id=%s\nstatus=%s\nphase=%s\niterations=%s\nbranch=%s\ndirty_files=%s\nlast_verify_status=%s\ndiff_check=%s\nlast_commit=%s\n' "$run_id" "$status" "$phase" "${iter:-0}" "$branch" "$dirty" "$verify" "$diff_check" "$last_commit"
  printf 'backlog_total=%s\nbacklog_queued=%s\nbacklog_in_progress=%s\nbacklog_completed=%s\n' "${backlog_total:-0}" "${backlog_queued:-0}" "${backlog_in_progress:-0}" "${backlog_completed:-0}"
  printf 'commits_in_window=%s\n' "${commits_in_window:-0}"
  printf 'local_failures=%s\n' "${local_failures:-0}"
  printf 'routine_summary=%s\n' "${routine_summary:-unavailable}"
  printf 'watchdog=%s\n' "${watchdog:-not_run}"
else
  printf 'Overnight report\n'
  printf -- '----------------\n'
  printf 'Run: %s (%s, phase=%s, iterations=%s)\n' "$run_id" "$status" "$phase" "${iter:-0}"
  printf 'Window: %s -> %s\n' "${started:-unknown}" "${updated:-unknown}"
  printf 'Repo: %s on %s, dirty files=%s\n' "$repo" "$branch" "$dirty"
  printf 'Last commit: %s\n' "$last_commit"
  printf 'Verification: %s; git diff --check: %s\n' "$verify" "$diff_check"
  printf 'Backlog: %s total (%s queued, %s in progress, %s completed)\n' "${backlog_total:-0}" "${backlog_queued:-0}" "${backlog_in_progress:-0}" "${backlog_completed:-0}"
  printf 'Commits in window: %s\n' "${commits_in_window:-0}"
  if [[ -n "$commits_list" ]]; then
    printf '%s\n' "$commits_list" | while IFS= read -r cline; do
      printf '  %s\n' "$cline"
    done
  fi
  [[ "${local_failures:-0}" -gt 0 ]] && printf 'Local failures: %s\n' "$local_failures"
  printf 'Routine summary: %s\n' "${routine_summary:-unavailable}"
  printf 'Watchdog: %s\n' "${watchdog:-not_run}"
  printf 'Next: inspect worker/controller logs in %s/logs if status is not complete.\n' "$state_dir"
fi
} | tee "$out"

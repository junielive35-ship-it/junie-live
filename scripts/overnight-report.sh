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
if [[ -x "$ROOT/scripts/report.sh" ]]; then
  routine_summary=$("$ROOT/scripts/report.sh" --repo "$repo" 2>/dev/null | grep '^summary=' | sed 's/^summary=//' || true)
fi
watchdog="not_run"
[[ -f "$state_dir/watchdog-findings.txt" ]] && watchdog=$(tail -n 1 "$state_dir/watchdog-findings.txt" 2>/dev/null || true)

{
if [[ "$format" == "kv" ]]; then
  printf 'run_id=%s\nstatus=%s\nphase=%s\niterations=%s\nbranch=%s\ndirty_files=%s\nlast_verify_status=%s\ndiff_check=%s\nlast_commit=%s\n' "$run_id" "$status" "$phase" "${iter:-0}" "$branch" "$dirty" "$verify" "$diff_check" "$last_commit"
else
  printf 'Overnight report\n'
  printf -- '----------------\n'
  printf 'Run: %s (%s, phase=%s, iterations=%s)\n' "$run_id" "$status" "$phase" "${iter:-0}"
  printf 'Window: %s -> %s\n' "${started:-unknown}" "${updated:-unknown}"
  printf 'Repo: %s on %s, dirty files=%s\n' "$repo" "$branch" "$dirty"
  printf 'Last commit: %s\n' "$last_commit"
  printf 'Verification: %s; git diff --check: %s\n' "$verify" "$diff_check"
  printf 'Routine summary: %s\n' "${routine_summary:-unavailable}"
  printf 'Watchdog: %s\n' "${watchdog:-not_run}"
  printf 'Next: inspect worker/controller logs in %s/logs if status is not complete.\n' "$state_dir"
fi
} | tee "$out"

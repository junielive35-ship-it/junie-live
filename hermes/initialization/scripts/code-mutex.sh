#!/usr/bin/env bash
set -euo pipefail

# code-mutex.sh — File-based code mutex for Junie Live
#
# Uses atomic mkdir as the lock primitive (same as the OpenClaw implementation).
# The directory's existence IS the lock; holder.json inside is metadata only.
#
# Usage:
#   code-mutex.sh status [--mutex-dir DIR]
#   code-mutex.sh acquire --holder ID --reason TEXT [--repo DIR] [--mutex-dir DIR]
#   code-mutex.sh release [--mutex-dir DIR]
#   code-mutex.sh check-stale [--stale-minutes N] [--auto-recover] [--mutex-dir DIR]
#
# --auto-recover (check-stale only):
#   When the mutex is in BROKEN state (directory exists, holder.json missing),
#   automatically remove the empty mutex directory and exit 0.
#   Stale-by-age locks (holder.json present but old) are NOT auto-recovered;
#   they still require manual release.

STATE_DIR="${JUNIE_STATE_DIR:-${HOME}/.hermes/junie-live/state}"
MUTEX_DIR=""
STALE_MINUTES=30

usage() {
  cat <<'EOF'
Usage:
  code-mutex.sh status          Show current mutex state
  code-mutex.sh acquire         Acquire the mutex
  code-mutex.sh release         Release the mutex
  code-mutex.sh check-stale     Check for stale mutex

Options:
  --mutex-dir DIR         Mutex directory (default: ~/.hermes/junie-live/state/code_mutex)
  --holder ID             Holder identifier (required for acquire)
  --reason TEXT           Reason for acquiring (required for acquire)
  --repo DIR              Repository path (for acquire metadata)
  --branch BRANCH         Branch name (for acquire metadata)
  --stale-minutes N       Minutes before mutex is considered stale (default: 30)
  --auto-recover          (check-stale) Auto-remove BROKEN mutex (dir exists, no holder.json)
EOF
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

ACTION="${1:-}"
shift 2>/dev/null || true

HOLDER=""
REASON=""
REPO=""
BRANCH=""
AUTO_RECOVER=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mutex-dir) MUTEX_DIR="$2"; shift 2 ;;
    --holder) HOLDER="$2"; shift 2 ;;
    --reason) REASON="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --stale-minutes) STALE_MINUTES="$2"; shift 2 ;;
    --auto-recover) AUTO_RECOVER=true; shift ;;
    *) printf 'Unknown: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$MUTEX_DIR" ]]; then
  MUTEX_DIR="$STATE_DIR/code_mutex"
fi

HOLDER_FILE="$MUTEX_DIR/holder.json"

case "$ACTION" in
  status)
    if [[ -d "$MUTEX_DIR" ]]; then
      printf 'mutex=HELD\n'
      if [[ -f "$HOLDER_FILE" ]]; then
        cat "$HOLDER_FILE"
      fi
    else
      printf 'mutex=FREE\n'
    fi
    ;;

  acquire)
    [[ -n "$HOLDER" ]] || { printf 'ERROR: --holder required\n' >&2; exit 2; }
    [[ -n "$REASON" ]] || { printf 'ERROR: --reason required\n' >&2; exit 2; }

    # mkdir is the lock operation. It succeeds for exactly one caller
    # when the directory does not already exist.
    if mkdir "$MUTEX_DIR" 2>/dev/null; then
      cat > "$HOLDER_FILE" <<JSON
{
  "holder_id": "$(json_escape "$HOLDER")",
  "reason": "$(json_escape "$REASON")",
  "repo": "$(json_escape "$REPO")",
  "branch": "$(json_escape "$BRANCH")",
  "started_at": "$(now_utc)",
  "updated_at": "$(now_utc)",
  "pid": $$
}
JSON
      printf 'mutex=ACQUIRED\n'
      printf 'holder_id=%s\n' "$HOLDER"
    else
      printf 'mutex=HELD\n'
      printf 'result=already_held\n'
      [[ -f "$HOLDER_FILE" ]] && cat "$HOLDER_FILE"
      exit 1
    fi
    ;;

  release)
    if [[ -d "$MUTEX_DIR" ]]; then
      rm -rf "$MUTEX_DIR"
      printf 'mutex=RELEASED\n'
    else
      printf 'mutex=FREE\n'
      printf 'result=was_not_held\n'
    fi
    ;;

  check-stale)
    if [[ ! -d "$MUTEX_DIR" ]]; then
      printf 'mutex=FREE\n'
      exit 0
    fi
    if [[ ! -f "$HOLDER_FILE" ]]; then
      printf 'mutex=HELD\n'
      printf 'stale=BROKEN\n'
      printf 'reason=mutex directory exists but no holder metadata\n'
      if [[ "$AUTO_RECOVER" == true ]]; then
        rmdir "$MUTEX_DIR" 2>/dev/null || rm -rf "$MUTEX_DIR"
        printf 'recovered=BROKEN\n'
        printf 'result=removed_empty_mutex_dir\n'
        exit 0
      fi
      exit 1
    fi

    # Use holder.json modification time as the staleness signal
    if [[ "$(uname)" == "Darwin" ]]; then
      updated_epoch=$(stat -f %m "$HOLDER_FILE" 2>/dev/null || echo 0)
    else
      updated_epoch=$(stat -c %Y "$HOLDER_FILE" 2>/dev/null || echo 0)
    fi
    now_epoch=$(date +%s)
    age_minutes=$(( (now_epoch - updated_epoch) / 60 ))

    printf 'mutex=HELD\n'
    printf 'age_minutes=%s\n' "$age_minutes"
    if [[ "$age_minutes" -gt "$STALE_MINUTES" ]]; then
      printf 'stale=YES\n'
      printf 'reason=mutex held for %s minutes (threshold: %s)\n' "$age_minutes" "$STALE_MINUTES"
      if [[ "$AUTO_RECOVER" == true ]]; then
        printf 'recovered=NO\n'
        printf 'result=stale_age_recovery_requires_manual_release\n'
      fi
      exit 1
    else
      printf 'stale=NO\n'
    fi
    ;;

  ""|-h|--help)
    usage
    exit 0
    ;;

  *)
    printf 'ERROR: unknown action: %s\n' "$ACTION" >&2
    usage
    exit 2
    ;;
esac

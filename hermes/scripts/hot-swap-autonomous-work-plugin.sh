#!/usr/bin/env bash
set -euo pipefail

PROFILE="junie-live"
PROFILE_DIR=""
REPO_DIR=""
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: hot-swap-autonomous-work-plugin.sh [options]

Safely copy the repo seed autonomous-work plugin into an installed Hermes
profile without resetting runtime state.

Options:
  --profile NAME       Hermes profile name (default: junie-live)
  --profile-dir DIR    Explicit installed profile directory
  --repo DIR           Repository root (default: inferred from this script)
  --dry-run            Resolve paths and show planned actions only
  -h, --help           Show this help

The script updates only:
  <profile-dir>/plugins/autonomous-work/

It does not touch runtime state, memory, sessions, backlog, windows, or gateway
processes. Already-running Hermes/gateway sessions may need a restart before
Python module changes are loaded:
  hermes -p <profile> gateway restart
EOF
}

log() { printf '==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      [[ $# -ge 2 ]] || fail "--profile requires a value"
      PROFILE="$2"
      shift 2
      ;;
    --profile-dir)
      [[ $# -ge 2 ]] || fail "--profile-dir requires a value"
      PROFILE_DIR="$2"
      shift 2
      ;;
    --repo)
      [[ $# -ge 2 ]] || fail "--repo requires a value"
      REPO_DIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

canonical_dir() {
  local path="$1"
  [[ -d "$path" ]] || return 1
  (cd "$path" && pwd -P)
}

looks_like_profile_dir() {
  local path="$1"
  [[ -d "$path" ]] || return 1
  [[ -d "$path/plugins" || -f "$path/config.yaml" || -f "$path/SOUL.md" ]]
}

if [[ -z "$REPO_DIR" ]]; then
  REPO_DIR="$(canonical_dir "$(dirname "${BASH_SOURCE[0]}")/../..")" || fail "could not infer repo root"
else
  REPO_DIR="$(canonical_dir "$REPO_DIR")" || fail "repo directory not found: $REPO_DIR"
fi

SOURCE_DIR="$REPO_DIR/hermes/distribution/plugins/autonomous-work"
[[ -d "$SOURCE_DIR" ]] || fail "source plugin seed not found: $SOURCE_DIR"

if [[ -n "$PROFILE_DIR" ]]; then
  PROFILE_DIR="$(canonical_dir "$PROFILE_DIR")" || fail "profile directory not found: $PROFILE_DIR"
elif [[ -n "${HERMES_HOME:-}" ]] && looks_like_profile_dir "$HERMES_HOME"; then
  PROFILE_DIR="$(canonical_dir "$HERMES_HOME")"
elif [[ -n "${HERMES_HOME:-}" && -d "$HERMES_HOME/profiles/$PROFILE" ]]; then
  PROFILE_DIR="$(canonical_dir "$HERMES_HOME/profiles/$PROFILE")"
elif [[ -n "${HERMES_PROFILE_DIR:-}" ]] && looks_like_profile_dir "$HERMES_PROFILE_DIR"; then
  PROFILE_DIR="$(canonical_dir "$HERMES_PROFILE_DIR")"
elif [[ -n "${HERMES_PROFILE_DIR:-}" && -d "$(dirname "$HERMES_PROFILE_DIR")/$PROFILE" ]]; then
  PROFILE_DIR="$(canonical_dir "$(dirname "$HERMES_PROFILE_DIR")/$PROFILE")"
elif [[ -d "$REPO_DIR/.hermes/profiles/$PROFILE" ]]; then
  PROFILE_DIR="$(canonical_dir "$REPO_DIR/.hermes/profiles/$PROFILE")"
else
  fail "could not resolve profile dir; pass --profile-dir or set HERMES_HOME/HERMES_PROFILE_DIR"
fi

DEST_DIR="$PROFILE_DIR/plugins/autonomous-work"
TMP_ROOT="$PROFILE_DIR/tmp/autonomous-work-hot-swap"
BACKUP_ROOT="$PROFILE_DIR/backups/autonomous-work-hot-swap"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
STAGE_DIR="$TMP_ROOT/stage-$STAMP"
BACKUP_DIR="$BACKUP_ROOT/autonomous-work-$STAMP"

log "profile: $PROFILE"
log "repo: $REPO_DIR"
log "source: $SOURCE_DIR"
log "destination: $DEST_DIR"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry run: would stage copy at $STAGE_DIR"
  if [[ -e "$DEST_DIR" || -L "$DEST_DIR" ]]; then
    log "dry run: would backup existing plugin to $BACKUP_DIR"
  else
    log "dry run: destination does not exist; no backup needed"
  fi
  log "dry run: would replace only plugins/autonomous-work"
  log "restart caveat: disk files only; run 'hermes -p $PROFILE gateway restart' if a gateway has already imported the plugin"
  exit 0
fi

mkdir -p "$TMP_ROOT" "$BACKUP_ROOT" "$(dirname "$DEST_DIR")"
rm -rf -- "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

log "staging plugin copy"
tar \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  --exclude='.pytest_cache' \
  --exclude='.mypy_cache' \
  --exclude='.ruff_cache' \
  --exclude='*.tmp' \
  --exclude='*.temp' \
  --exclude='*~' \
  --exclude='.DS_Store' \
  -C "$SOURCE_DIR" -cf - . | tar -C "$STAGE_DIR" -xf -

[[ -f "$STAGE_DIR/plugin.yaml" ]] || fail "staged plugin is missing plugin.yaml"
[[ -f "$STAGE_DIR/tools.py" ]] || fail "staged plugin is missing tools.py"

if [[ -e "$DEST_DIR" || -L "$DEST_DIR" ]]; then
  log "backing up existing plugin to $BACKUP_DIR"
  mv -- "$DEST_DIR" "$BACKUP_DIR"
fi

log "installing staged plugin"
if ! mv -- "$STAGE_DIR" "$DEST_DIR"; then
  if [[ -d "$BACKUP_DIR" && ! -e "$DEST_DIR" ]]; then
    mv -- "$BACKUP_DIR" "$DEST_DIR" || true
  fi
  fail "failed to install staged plugin; restored backup when possible"
fi

rm -rf -- "$TMP_ROOT"

log "hot-swap complete"
log "backup: $BACKUP_DIR"
if [[ -f "$PROFILE_DIR/config.yaml" ]] && grep -q 'autonomous-work' "$PROFILE_DIR/config.yaml"; then
  log "plugin enablement: autonomous-work appears in $PROFILE_DIR/config.yaml"
else
  log "plugin enablement: verify with 'hermes -p $PROFILE plugins enable autonomous-work' if needed"
fi
log "restart caveat: disk files only; run 'hermes -p $PROFILE gateway restart' if a gateway has already imported the plugin"

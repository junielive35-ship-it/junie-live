#!/usr/bin/env bash
set -euo pipefail

# dump-junie.sh — Create a disaster recovery archive for a Hermes profile
#
# Archives the entire profile directory with safe SQLite database snapshots,
# excluding transient junk. Output is a .tgz under $HERMES_ROOT/backups/.

usage() {
  cat <<'EOF'
Usage:
  dump-junie.sh [options]

Creates a disaster recovery archive of a Hermes profile.

Options:
  --profile NAME      Hermes profile name. Default: junie-live
  --output PATH       Output archive path (default: auto-generated under backups/)
  --help              Show this help
EOF
}

log() { printf '==> %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

PROFILE="junie-live"
OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) [[ $# -ge 2 ]] || { err "--profile requires a value"; exit 2; }; PROFILE="$2"; shift 2 ;;
    --output)  [[ $# -ge 2 ]] || { err "--output requires a value"; exit 2; }; OUTPUT="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage; exit 2 ;;
  esac
done

# ── Resolve Hermes root (robust against profile-scoped HERMES_HOME) ──
resolve_hermes_root() {
  local profile="$1"

  # Priority 1: explicit override
  if [[ -n "${JUNIE_HERMES_ROOT:-}" ]]; then
    HERMES_ROOT="$JUNIE_HERMES_ROOT"
    return 0
  fi

  local hh="${HERMES_HOME:-$HOME/.hermes}"

  # Priority 2: $HERMES_HOME/profiles/$profile exists — hh is already root
  if [[ -d "$hh/profiles/$profile" ]]; then
    HERMES_ROOT="$hh"
    return 0
  fi

  # Priority 3: $HERMES_HOME looks like the profile dir itself
  # (e.g. /home/.../.hermes/profiles/junie-live)
  local base; base="$(basename "$hh")"
  local parent; parent="$(basename "$(dirname "$hh")")"
  if [[ "$base" == "$profile" && "$parent" == "profiles" ]]; then
    HERMES_ROOT="$(dirname "$(dirname "$hh")")"
    return 0
  fi

  # Priority 4: $HOME/.hermes/profiles/$profile exists
  if [[ -d "$HOME/.hermes/profiles/$profile" ]]; then
    HERMES_ROOT="$HOME/.hermes"
    return 0
  fi

  # Fallback
  HERMES_ROOT="$hh"
}

resolve_hermes_root "$PROFILE"
PROFILE_DIR="$HERMES_ROOT/profiles/$PROFILE"
[[ -d "$PROFILE_DIR" ]] || { err "profile not found: $PROFILE_DIR"; exit 1; }

# ── Resolve output path ──
if [[ -z "$OUTPUT" ]]; then
  BACKUP_DIR="$HERMES_ROOT/backups"
  mkdir -p "$BACKUP_DIR"
  ts="$(date +%Y%m%d-%H%M%S)"
  OUTPUT="$BACKUP_DIR/$PROFILE-dump-$ts.tgz"
fi

log "profile:       $PROFILE"
log "hermes root:   $HERMES_ROOT"
log "profile dir:   $PROFILE_DIR"
log "output:        $OUTPUT"

# ── Stage ──
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR" ${RUNTIME_BUILD_COPY:-}' EXIT

# Create full path structure so archive can be extracted into any HERMES_HOME
ARCHIVE_PROFILE_DIR="$STAGING_DIR/profiles/$PROFILE"
mkdir -p "$(dirname "$ARCHIVE_PROFILE_DIR")"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log "staging profile copy (safe SQLite snapshot via junie-runtime-artifact)..."

python3 "$SCRIPT_DIR/junie-runtime-artifact.py" snapshot-profile "$PROFILE_DIR" "$ARCHIVE_PROFILE_DIR"

# ── Build runtime wheel artifact ──

RUNTIME_MANIFEST_SRC="$PROFILE_DIR/junie-live/runtime/junie_runtime.json"
ARCHIVE_RUNTIME_DIR="$STAGING_DIR/runtime"

if [[ -f "$RUNTIME_MANIFEST_SRC" ]]; then
  log "runtime manifest found: $RUNTIME_MANIFEST_SRC"

  RUNTIME_SOURCE="$(python3 "$SCRIPT_DIR/junie-runtime-artifact.py" read-manifest-field "$RUNTIME_MANIFEST_SRC" source_path)"
  if [[ -z "$RUNTIME_SOURCE" || ! -d "$RUNTIME_SOURCE" ]]; then
    err "runtime source path not found: ${RUNTIME_SOURCE:-'(empty)'}"
    err "  (recorded in $RUNTIME_MANIFEST_SRC)"
    exit 1
  fi

  log "building wheel from $RUNTIME_SOURCE..."

  # Build from a temp copy to avoid leaving build artifacts in the source tree
  RUNTIME_BUILD_COPY="$(mktemp -d)"
  cp -a "$RUNTIME_SOURCE/." "$RUNTIME_BUILD_COPY/"

  mkdir -p "$ARCHIVE_RUNTIME_DIR"

  python3 -m pip wheel --no-deps "$RUNTIME_BUILD_COPY" -w "$ARCHIVE_RUNTIME_DIR" -q || {
    err "pip wheel failed for $RUNTIME_SOURCE"
    exit 1
  }

  rm -rf "$RUNTIME_BUILD_COPY"
  unset RUNTIME_BUILD_COPY

  WHEEL_COUNT="$(ls "$ARCHIVE_RUNTIME_DIR"/*.whl 2>/dev/null | wc -l)"
  if [[ "$WHEEL_COUNT" -eq 0 ]]; then
    err "wheel build produced no output"
    exit 1
  fi

  WHEEL_FILE="$(ls "$ARCHIVE_RUNTIME_DIR"/*.whl | head -1)"
  WHEEL_HASH="$(sha256sum "$WHEEL_FILE" | cut -d' ' -f1)"
  WHEEL_BASENAME="$(basename "$WHEEL_FILE")"

  # Copy manifest to archive with wheel info
  python3 "$SCRIPT_DIR/junie-runtime-artifact.py" enrich-archive-manifest \
    --input "$RUNTIME_MANIFEST_SRC" \
    --output "$ARCHIVE_RUNTIME_DIR/junie_runtime.json" \
    --wheel-filename "$WHEEL_BASENAME" \
    --wheel-sha256 "$WHEEL_HASH"
  log "  wheel: $WHEEL_BASENAME ($WHEEL_HASH)"
else
  err "runtime manifest not found: $RUNTIME_MANIFEST_SRC"
  err "  This dump branch requires a runtime manifest for exact DR artifact."
  err "  Re-hire with the current branch first."
  exit 1
fi

log "creating archive..."
tar -czf "$OUTPUT" -C "$STAGING_DIR" . || { err "failed to create archive"; exit 1; }

log "archive created: $OUTPUT"
log "  size: $(du -h "$OUTPUT" | cut -f1)"

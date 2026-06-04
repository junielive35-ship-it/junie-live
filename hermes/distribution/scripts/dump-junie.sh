#!/usr/bin/env bash
set -euo pipefail

# dump-junie.sh — Create a disaster recovery archive for a Hermes profile
#
# Archives the entire profile directory using Hermes-native export, then
# embeds a Junie Runtime wheel artifact inside the profile tree under
# junie-live/runtime_artifact/.

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

# ── Resolve Hermes root via junie_runtime path helper ──
HERMES_ROOT="$(python3 -m junie_runtime.paths hermes-root --profile "$PROFILE")"
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

# ── Prerequisites ──
command -v hermes >/dev/null || { err "hermes CLI not found in PATH"; exit 1; }

# ── Stage via Hermes-native export ──
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR" ${RUNTIME_BUILD_COPY:-}' EXIT

NATIVE_EXPORT="$STAGING_DIR/native-export.tgz"
export HERMES_HOME="$HERMES_ROOT"

log "exporting profile via Hermes-native export..."
hermes profile export "$PROFILE" -o "$NATIVE_EXPORT" || {
  err "hermes profile export failed for $PROFILE"
  exit 1
}

log "extracting native export..."
NATIVE_EXTRACT="$STAGING_DIR/native"
mkdir -p "$NATIVE_EXTRACT"
tar -xzf "$NATIVE_EXPORT" -C "$NATIVE_EXTRACT" || {
  err "failed to extract native export"
  exit 1
}

ARCHIVE_PROFILE_DIR="$NATIVE_EXTRACT/$PROFILE"
[[ -d "$ARCHIVE_PROFILE_DIR" ]] || { err "native export missing profile dir"; exit 1; }

# ── Post-export cleanup (exclude transient junk, safe SQLite backup) ──
log "post-export cleanup..."
rm -rf "$ARCHIVE_PROFILE_DIR"/{__pycache__,logs,cache,backups}
find "$ARCHIVE_PROFILE_DIR" \( -name '*.pyc' -o -name '*.pyo' -o -name '*.pid' -o -name '*.lock' \) -delete
find "$ARCHIVE_PROFILE_DIR" \( -name '*.db-wal' -o -name '*.db-shm' -o -name '*.db-journal' \) -delete

# Safe SQLite backup
while IFS= read -r -d '' db; do
  tmp="${db}.tmpbak"
  if sqlite3 "file:${db}?mode=ro" ".backup ${tmp}" 2>/dev/null && [[ -f "$tmp" ]]; then
    mv -f "$tmp" "$db"
  fi
  rm -f "$tmp"
done < <(find "$ARCHIVE_PROFILE_DIR" -name '*.db' -type f -print0)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Read runtime manifest from source profile ──
RUNTIME_MANIFEST_SRC="$PROFILE_DIR/junie-live/runtime/junie_runtime.json"

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

  RUNTIME_ARTIFACT_DIR="$ARCHIVE_PROFILE_DIR/junie-live/runtime_artifact"
  mkdir -p "$RUNTIME_ARTIFACT_DIR"

  python3 -m pip wheel --no-deps "$RUNTIME_BUILD_COPY" -w "$RUNTIME_ARTIFACT_DIR" -q || {
    err "pip wheel failed for $RUNTIME_SOURCE"
    exit 1
  }

  rm -rf "$RUNTIME_BUILD_COPY"
  unset RUNTIME_BUILD_COPY

  WHEEL_COUNT="$(ls "$RUNTIME_ARTIFACT_DIR"/*.whl 2>/dev/null | wc -l)"
  if [[ "$WHEEL_COUNT" -eq 0 ]]; then
    err "wheel build produced no output"
    exit 1
  fi

  WHEEL_FILE="$(ls "$RUNTIME_ARTIFACT_DIR"/*.whl | head -1)"
  WHEEL_HASH="$(sha256sum "$WHEEL_FILE" | cut -d' ' -f1)"
  WHEEL_BASENAME="$(basename "$WHEEL_FILE")"

  # Write enriched manifest to runtime_artifact/
  python3 "$SCRIPT_DIR/junie-runtime-artifact.py" enrich-archive-manifest \
    --input "$RUNTIME_MANIFEST_SRC" \
    --output "$RUNTIME_ARTIFACT_DIR/junie_runtime.json" \
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
tar -czf "$OUTPUT" -C "$NATIVE_EXTRACT" "$PROFILE" || { err "failed to create archive"; exit 1; }

log "archive created: $OUTPUT"
log "  size: $(du -h "$OUTPUT" | cut -f1)"

#!/usr/bin/env bash
set -euo pipefail

# rehire-junie.sh — Restore a Junie Live Hermes profile from a disaster recovery archive
#
# Uses Hermes-native profile import, then restores the embedded runtime wheel
# artifact from within the profile tree under junie-live/runtime_artifact/.

usage() {
  cat <<'EOF'
Usage:
  rehire-junie.sh <archive> [options]

Restores a Junie Live Hermes profile from a disaster recovery archive created
by dump-junie.sh.

Arguments:
  archive                 Path to dump archive (.tgz created by dump-junie.sh)

Options:
  --profile NAME          Hermes profile name. Default: junie-live
  --no-gateway-start      Do not start/restart the gateway after restore
  --force                 Overwrite existing profile if one exists
  --help                  Show this help
EOF
}

log() { printf '==> %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

ARCHIVE=""
PROFILE="junie-live"
NO_GATEWAY_START=0
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) [[ $# -ge 2 ]] || { err "--profile requires a value"; exit 2; }; PROFILE="$2"; shift 2 ;;
    --no-gateway-start) NO_GATEWAY_START=1; shift ;;
    --force) FORCE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    -*)
      if [[ -z "$ARCHIVE" && -f "$1" ]]; then
        ARCHIVE="$1"; shift
      else
        err "unknown option: $1"; usage; exit 2
      fi
      ;;
    *)
      if [[ -z "$ARCHIVE" ]]; then
        ARCHIVE="$1"; shift
      else
        err "unexpected argument: $1"; usage; exit 2
      fi
      ;;
  esac
done

# ── Validate ──
[[ -n "$ARCHIVE" ]] || { err "missing required archive path"; usage; exit 2; }
[[ -f "$ARCHIVE" ]] || { err "archive not found: $ARCHIVE"; exit 1; }
command -v hermes >/dev/null || { err "hermes CLI not found in PATH"; exit 1; }

# ── Resolve Hermes root via junie_runtime path helper ──
HERMES_ROOT="$(python3 -m junie_runtime.paths hermes-root --profile "$PROFILE")"
PROFILE_DIR="$HERMES_ROOT/profiles/$PROFILE"

log "archive:       $ARCHIVE"
log "hermes root:   $HERMES_ROOT"
log "profile:       $PROFILE"
log "profile dir:   $PROFILE_DIR"

# ── Check for existing profile ──
if [[ -e "$PROFILE_DIR" ]]; then
  if [[ "$FORCE" -eq 1 ]]; then
    ts="$(date +%Y%m%d-%H%M%S)"
    mv "$PROFILE_DIR" "${PROFILE_DIR}.rehire-before-$ts"
    log "existing profile moved aside: ${PROFILE_DIR}.rehire-before-$ts"
  else
    err "profile already exists: $PROFILE_DIR"
    err "use --force to overwrite (existing profile will be moved aside)"
    exit 1
  fi
fi

# ── Restore via Hermes-native import ──
log "restoring archive via Hermes-native import..."
export HERMES_HOME="$HERMES_ROOT"
hermes profile import "$ARCHIVE" --name "$PROFILE" || {
  err "hermes profile import failed"
  exit 1
}

# ── Verify key files ──
if [[ -f "$PROFILE_DIR/config.yaml" ]]; then
  log "  config.yaml present"
else
  err "restored profile missing config.yaml: $PROFILE_DIR/config.yaml"
  exit 1
fi

# ── Restore junie_runtime from embedded runtime_artifact ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUNTIME_ARTIFACT_DIR="$PROFILE_DIR/junie-live/runtime_artifact"
ARCHIVE_MANIFEST="$RUNTIME_ARTIFACT_DIR/junie_runtime.json"

if [[ -f "$ARCHIVE_MANIFEST" ]]; then
  log "runtime manifest found in archive: $ARCHIVE_MANIFEST"

  HELPER="$SCRIPT_DIR/../distribution/scripts/junie-runtime-artifact.py"
  WHEEL_FILENAME="$(python3 "$HELPER" read-manifest-field "$ARCHIVE_MANIFEST" wheel_filename)"
  EXPECTED_HASH="$(python3 "$HELPER" read-manifest-field "$ARCHIVE_MANIFEST" wheel_sha256)"
  EXPECTED_VERSION="$(python3 "$HELPER" read-manifest-field "$ARCHIVE_MANIFEST" version)"

  WHEEL_PATH="$RUNTIME_ARTIFACT_DIR/$WHEEL_FILENAME"
  if [[ -z "$WHEEL_FILENAME" || ! -f "$WHEEL_PATH" ]]; then
    err "wheel file not found: $WHEEL_PATH"
    err "  Archive may be corrupt. Re-dump with the current branch."
    exit 1
  fi

  # Verify sha256
  ACTUAL_HASH="$(sha256sum "$WHEEL_PATH" | cut -d' ' -f1)"
  if [[ "$ACTUAL_HASH" != "$EXPECTED_HASH" ]]; then
    err "wheel hash mismatch for $WHEEL_FILENAME"
    err "  expected: $EXPECTED_HASH"
    err "  actual:   $ACTUAL_HASH"
    err "  Archive may be corrupt or tampered. Re-dump with the current branch."
    exit 1
  fi

  log "wheel hash verified: $WHEEL_FILENAME"

  log "installing junie_runtime from archive wheel..."
  python3 -m pip install --force-reinstall "$WHEEL_PATH" -q || {
    err "Failed to install junie_runtime from $WHEEL_PATH"
    exit 1
  }
  log "  junie_runtime installed from archive wheel"

  # Verify installed version matches manifest
  INSTALLED_VERSION="$(python3 -m pip show junie-runtime 2>/dev/null | sed -n 's/^Version: //p')"
  if [[ -n "$EXPECTED_VERSION" && "$INSTALLED_VERSION" != "$EXPECTED_VERSION" ]]; then
    err "installed junie_runtime version mismatch: expected $EXPECTED_VERSION, got $INSTALLED_VERSION"
    exit 1
  fi
  log "  version verified: $INSTALLED_VERSION"

  # Write restored manifest to profile runtime state
  RESTORE_MANIFEST_DIR="$PROFILE_DIR/junie-live/runtime"
  mkdir -p "$RESTORE_MANIFEST_DIR"
  python3 "$HELPER" write-restore-manifest \
    --archive-manifest "$ARCHIVE_MANIFEST" \
    --output-dir "$RESTORE_MANIFEST_DIR" \
    --archive "$ARCHIVE" \
    --installed-python "python3" || {
    err "failed to write restored manifest"
    exit 1
  }
  log "  restore manifest written to $RESTORE_MANIFEST_DIR/junie_runtime.json"

  # Clean up extracted runtime_artifact dir
  rm -rf "$RUNTIME_ARTIFACT_DIR"
elif [[ -d "$RUNTIME_ARTIFACT_DIR" ]]; then
  err "runtime_artifact directory found in profile but no manifest: $RUNTIME_ARTIFACT_DIR"
  err "  Archive may be from an incompatible version."
  exit 1
else
  err "no runtime artifact found in archive at $RUNTIME_ARTIFACT_DIR"
  err "  This dump does not contain a junie_runtime wheel artifact."
  err "  Run a newer dump-junie.sh to create one."
  err "  Then re-run rehire-junie.sh with the fresh archive."
  exit 1
fi

# ── Start/restart gateway ──
if [[ "$NO_GATEWAY_START" -eq 0 ]]; then
  log "starting gateway..."
  gateway_cmd=""
  if HERMES_HOME="$PROFILE_DIR" hermes gateway restart >/dev/null 2>&1; then
    gateway_cmd="HERMES_HOME=$PROFILE_DIR hermes gateway restart"
    log "  gateway restarted: $gateway_cmd"
  elif HERMES_HOME="$PROFILE_DIR" hermes gateway start >/dev/null 2>&1; then
    gateway_cmd="HERMES_HOME=$PROFILE_DIR hermes gateway start"
    log "  gateway started: $gateway_cmd"
  else
    err "could not start/restart gateway"
    err "try manually: HERMES_HOME=$PROFILE_DIR hermes gateway start"
    exit 1
  fi
fi

log ""
log "rehire complete for profile: $PROFILE"
log "profile dir: $PROFILE_DIR"
[[ "$NO_GATEWAY_START" -eq 0 ]] && log "gateway:      $gateway_cmd"
log "you can now continue chatting with Junie in Telegram"

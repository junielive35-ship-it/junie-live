#!/usr/bin/env bash
set -euo pipefail

# rehire-junie.sh — Restore a Junie Live Hermes profile from a disaster recovery archive

usage() {
  cat <<'EOF'
Usage:
  rehire-junie.sh <archive> [options]

Restores a Junie Live Hermes profile from a disaster recovery archive created
by dump-junie.sh. After restore, optionally starts/restarts the Telegram gateway.

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
      # If first positional looks like an option and isn't consumed above, check if it's the archive
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

# ── Resolve Hermes root (robust against profile-scoped HERMES_HOME) ──
# Must be declared before first use; bash resolves at call time.
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

# ── Restore archive ──
log "restoring archive..."
mkdir -p "$HERMES_ROOT"
tar -xzf "$ARCHIVE" -C "$HERMES_ROOT" || { err "failed to extract archive"; exit 1; }

# ── Verify key files ──
if [[ -f "$PROFILE_DIR/config.yaml" ]]; then
  log "  config.yaml present"
else
  err "restored profile missing config.yaml: $PROFILE_DIR/config.yaml"
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

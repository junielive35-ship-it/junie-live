#!/usr/bin/env bash
set -euo pipefail

# install-senior-dev-profile.sh — Install the senior-dev profile into Hermes
#
# Installs the senior-dev profile, copies required plugins
# (marinator-delegation, senior-task), enables them, and enables
# required toolsets. Safe to re-run (idempotent with --alias).
# Does not overwrite an existing live senior-dev profile unless --force.

PROFILE="senior-dev"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEED_DIR="$ROOT/distribution/profiles/senior-dev"
PLUGIN_SRC="$ROOT/distribution/plugins"

usage() {
  cat <<EOF
Usage: install-senior-dev-profile.sh [--force]

Installs the '$PROFILE' profile into Hermes with required plugins
(marinator-delegation, senior-task) and toolsets (marinator, senior,
terminal, file).

Safe to re-run — uses hermes profile install with --alias.

Options:
  --force    Overwrite existing profile even if already installed.
  --help     Show this help.
EOF
}

FORCE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    --help) usage; exit 0 ;;
    *) echo "ERROR: Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

if [[ ! -d "$SEED_DIR" ]]; then
  err "Seed directory not found: $SEED_DIR"
  exit 1
fi

if [[ ! -f "$SEED_DIR/config.yaml" ]]; then
  err "Seed directory missing config.yaml: $SEED_DIR"
  exit 1
fi

if ! command -v hermes &>/dev/null; then
  err "hermes CLI not found on PATH. Is Hermes Agent installed?"
  exit 1
fi

# ── Resolve profile directory path ──
# This resolver must work when called from within a gateway/profile session
# where HERMES_HOME == <hermes-root>/profiles/<current-profile> (the current
# profile dir, not the global Hermes root). It extracts the real Hermes root
# and appends profiles/$PROFILE.
resolve_profile_dir() {
  python3 -c "
import os

profile = '$PROFILE'

# If HERMES_HOME has a /profiles/ component, extract the root from it.
# E.g. HERMES_HOME=/home/x/.hermes/profiles/junie-live
#   -> root = /home/x/.hermes
#   -> result = /home/x/.hermes/profiles/senior-dev
hh = os.environ.get('HERMES_HOME', '')
if '/profiles/' in hh:
    idx = hh.index('/profiles/')
    root = hh[:idx]
    candidate = os.path.join(root, 'profiles', profile)
    print(candidate)
    exit(0)

# If JUNIE_HERMES_ROOT is set, use it directly.
jhr = os.environ.get('JUNIE_HERMES_ROOT', '')
if jhr:
    print(os.path.join(jhr, 'profiles', profile))
    exit(0)

# Fallback: HERMES_HOME as the root (or ~/.hermes if unset).
root = hh if hh else os.path.join(os.path.expanduser('~'), '.hermes')
print(os.path.join(root, 'profiles', profile))
"
}

# ── Plugin enable helper (preserves existing plugins.enabled) ──
ensure_plugin() {
  local profile_dir="$1"
  local profile="$2"
  local plugin_name="$3"

  if hermes -p "$profile" plugins enable "$plugin_name" >/dev/null 2>&1; then
    log "  Plugin '$plugin_name' enabled via 'plugins enable'"
    return 0
  fi

  local merged
  merged=$(PD="$profile_dir" PN="$plugin_name" python3 2>/dev/null <<'PYENSURE'
import json, os, sys
config_file = os.path.join(os.environ['PD'], 'config.yaml')
plugin = os.environ['PN']
existing = []
if os.path.isfile(config_file):
    try:
        import yaml
        with open(config_file) as f:
            cfg = yaml.safe_load(f) or {}
        enabled = (cfg.get('plugins') or {}).get('enabled') or []
        existing = enabled if isinstance(enabled, list) else []
    except ImportError:
        pass
if plugin not in existing:
    existing.append(plugin)
print(json.dumps(existing))
PYENSURE
  ) || merged='["marinator-delegation","senior-task"]'

  if hermes -p "$profile" config set plugins.enabled "$merged" >/dev/null 2>&1; then
    log "  Plugin '$plugin_name' enabled via config set fallback (preserving existing plugins)"
  else
    log "  WARNING: could not enable plugin '$plugin_name'; enable manually after install"
  fi
}

# ── Check if profile already exists ──
if hermes profile show "$PROFILE" >/dev/null 2>&1; then
  if [[ "$FORCE" != "true" ]]; then
    PD=$(resolve_profile_dir)
    log "Profile '$PROFILE' already exists. Use --force to overwrite."
    [[ -n "$PD" ]] && log "Current profile at: $PD"
    exit 0
  fi
  log "Profile '$PROFILE' exists. Deleting before reinstall (--force)..."
  hermes profile delete "$PROFILE" -y || {
    err "Failed to delete profile $PROFILE"
    exit 1
  }
fi

# ── Step 1: Install profile seed ──
log "Installing $PROFILE profile from $SEED_DIR..."
if ! hermes profile install "$SEED_DIR" --name "$PROFILE" --alias -y; then
  if [[ "$FORCE" == "true" ]]; then
    log "Profile install reported existing target after delete; retrying with Hermes --force..."
    hermes profile install "$SEED_DIR" --name "$PROFILE" --alias -y --force || {
      err "Failed to install profile $PROFILE"
      exit 1
    }
  else
    err "Failed to install profile $PROFILE"
    exit 1
  fi
fi

log "Profile seed installed."

# ── Step 2: Resolve installed profile directory ──
PROFILE_DIR=$(resolve_profile_dir)
log "Profile directory: $PROFILE_DIR"

# ── Step 3: Copy required plugins from distribution ──
PLUGIN_TARGET="$PROFILE_DIR/plugins"
mkdir -p "$PLUGIN_TARGET"

for plugin in marinator-delegation senior-task; do
  if [[ -d "$PLUGIN_SRC/$plugin" ]]; then
    if [[ -d "$PLUGIN_TARGET/$plugin" ]]; then
      log "  Plugin '$plugin' already installed in profile, skipping copy."
    else
      cp -a "$PLUGIN_SRC/$plugin" "$PLUGIN_TARGET/$plugin"
      log "  Plugin '$plugin' copied to profile."
    fi
  else
    log "  WARNING: plugin source '$PLUGIN_SRC/$plugin' not found; skipping"
  fi
done

# ── Step 4: Enable plugins ──
log "Enabling plugins..."
ensure_plugin "$PROFILE_DIR" "$PROFILE" "marinator-delegation"
ensure_plugin "$PROFILE_DIR" "$PROFILE" "senior-task"

# ── Step 5: Enable required toolsets ──
log "Enabling toolsets..."
for platform in cli; do
  for toolset in marinator senior terminal file; do
    hermes -p "$PROFILE" tools enable --platform "$platform" "$toolset" >/dev/null 2>&1 || true
  done
done
log "  Toolsets enabled: marinator, senior, terminal, file (cli)"

log "Profile '$PROFILE' installed successfully."

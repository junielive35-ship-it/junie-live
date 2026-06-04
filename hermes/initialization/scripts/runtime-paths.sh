#!/usr/bin/env bash
# Shared runtime-state defaults for Hermes Junie Live scripts.
# Operational state is profile-local for isolation between Hermes profiles.

hermes_profile_dir_default() {
  local hermes_home="${HERMES_HOME:-${HOME:-/tmp}/.hermes}"
  local profile="${HERMES_PROFILE:-junie-live}"
  # Detect when HERMES_HOME already points to a profile directory
  # (e.g. /home/user/.hermes/profiles/junie-live) to avoid double-nesting
  # into /home/user/.hermes/profiles/junie-live/profiles/junie-live.
  local dirname parent
  dirname="$(basename "$hermes_home")"
  parent="$(basename "$(dirname "$hermes_home")")"
  if [[ "$dirname" == "$profile" && "$parent" == "profiles" ]]; then
    printf '%s\n' "$hermes_home"
  else
    printf '%s\n' "$hermes_home/profiles/$profile"
  fi
}

hermes_state_root_default() {
  printf '%s\n' "$(hermes_profile_dir_default)/junie-live/state"
}

hermes_mutex_dir_default() {
  printf '%s\n' "$(hermes_state_root_default)/code_mutex"
}

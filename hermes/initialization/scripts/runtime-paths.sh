#!/usr/bin/env bash
# Shared runtime-state defaults for Hermes Junie Live scripts.
# Operational state is profile-local for isolation between Hermes profiles.

hermes_profile_dir_default() {
  local hermes_home="${HERMES_HOME:-${HOME:-/tmp}/.hermes}"
  local profile="${HERMES_PROFILE:-junie-live}"
  printf '%s\n' "$hermes_home/profiles/$profile"
}

hermes_state_root_default() {
  printf '%s\n' "$(hermes_profile_dir_default)/junie-live/state"
}

hermes_mutex_dir_default() {
  printf '%s\n' "$(hermes_state_root_default)/code_mutex"
}

#!/usr/bin/env bash
# Shared runtime-state defaults for Junie Live scripts.
# Operational state must stay out of the git repo root unless tests explicitly override paths.

junie_workspace_default() {
  printf '%s\n' "${JUNIE_WORKSPACE:-${HOME:-/tmp}/.openclaw/workspace-junie-live}"
}

junie_state_root_default() {
  printf '%s\n' "$(junie_workspace_default)/.openclaw/state"
}

junie_mutex_dir_default() {
  printf '%s\n' "$(junie_state_root_default)/code_mutex"
}

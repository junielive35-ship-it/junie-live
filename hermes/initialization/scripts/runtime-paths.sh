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

# Resolve Hermes Python interpreter.
# Priority: JUNIE_HERMES_PYTHON env var > hermes CLI shebang > python3.
# Prints the interpreter path and returns 0, or returns 1 on failure.
resolve_hermes_python() {
  # Priority 1: explicit override
  if [[ -n "${JUNIE_HERMES_PYTHON:-}" ]]; then
    if "$JUNIE_HERMES_PYTHON" -c 'import sys; print(sys.executable)' >/dev/null 2>&1; then
      printf '%s\n' "$JUNIE_HERMES_PYTHON"
      return 0
    fi
    printf 'ERROR: JUNIE_HERMES_PYTHON=%s is not a working Python interpreter\n' "$JUNIE_HERMES_PYTHON" >&2
    return 1
  fi

  # Priority 2: inspect hermes CLI shebang
  local hp; hp="$(command -v hermes 2>/dev/null || true)"
  if [[ -n "$hp" && -f "$hp" && -x "$hp" ]]; then
    local shebang; shebang="$(head -1 "$hp" 2>/dev/null || true)"
    if [[ "$shebang" =~ ^#! ]]; then
      local interp; interp="${shebang#\#!}"
      if [[ "$interp" == "/usr/bin/env" ]]; then
        local rest; rest="$(head -1 "$hp" | awk '{print $2}')"
        if [[ -n "$rest" ]] && command -v "$rest" >/dev/null 2>&1; then
          if "$rest" -c 'import sys; print(sys.executable)' >/dev/null 2>&1; then
            printf '%s\n' "$rest"
            return 0
          fi
        fi
      else
        if "$interp" -c 'import sys; print(sys.executable)' >/dev/null 2>&1; then
          printf '%s\n' "$interp"
          return 0
        fi
      fi
    fi
  fi

  # Priority 3: fallback to python3
  if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "python3"
    return 0
  fi

  printf 'ERROR: no working Python interpreter found (tried JUNIE_HERMES_PYTHON, hermes CLI, python3)\n' >&2
  return 1
}

# Ensure pip is available for the given Python interpreter.
# Tries ensurepip --upgrade if pip is missing.
ensure_hermes_pip() {
  local python="$1"
  if "$python" -m pip --version >/dev/null 2>&1; then
    return 0
  fi
  if "$python" -m ensurepip --upgrade >/dev/null 2>&1; then
    return 0
  fi
  printf 'ERROR: pip not available for %s\n' "$python" >&2
  printf '  Run: %s -m ensurepip --upgrade\n' "$python" >&2
  return 1
}

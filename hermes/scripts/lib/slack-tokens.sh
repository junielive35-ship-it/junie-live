#!/usr/bin/env bash
# slack-tokens.sh — shared Slack credential forwarding for Junie hire scripts.
#
# Sourced by hire-junie.sh. Kept as a standalone, sourceable helper so the
# Slack credential / home-channel-notice behavior can be unit-tested without
# running the full hire pipeline.

# forward_slack_tokens PROFILE_ENV SOURCE_FILE
#
# Appends Slack credentials found in SOURCE_FILE to the profile .env at
# PROFILE_ENV. When Slack credentials (a bot or app token) are present but no
# real SLACK_HOME_CHANNEL is configured, also writes
# SLACK_SUPPRESS_HOME_CHANNEL_NOTICE=true so the Hermes gateway does not
# repeatedly nag about a missing Slack home channel on every new thread.
#
# It never writes a fake SLACK_HOME_CHANNEL: doing so would silence the notice
# but silently break real cron / cross-platform delivery semantics. Operators
# can still run `/hermes sethome` later to set a real Slack home channel; the
# suppression flag only silences the missing-home notice.
#
# Emits human-readable progress lines on stdout. Returns 0 (a missing source
# file is a no-op, mirroring the historical inline behavior).
forward_slack_tokens() {
  local profile_env="$1"
  local source_file="$2"

  [[ -f "$source_file" ]] || return 0

  local forwardable_keys=(
    SLACK_BOT_TOKEN
    SLACK_APP_TOKEN
    SLACK_ALLOWED_USERS
    SLACK_ALLOW_ALL_USERS
    SLACK_HOME_CHANNEL
    SLACK_HOME_CHANNEL_NAME
    SLACK_ALLOWED_CHANNELS
  )

  local count=0
  local names=()
  local creds_present=0
  local home_set=0
  local key line

  printf '\n# Slack tokens from %s\n' "$source_file" >> "$profile_env"
  for key in "${forwardable_keys[@]}"; do
    line="$(grep -E "^${key}=." "$source_file" | head -n1 || true)"
    if [[ -n "$line" ]]; then
      printf '%s\n' "$line" >> "$profile_env"
      count=$((count + 1))
      names+=("$key")
      case "$key" in
        SLACK_BOT_TOKEN|SLACK_APP_TOKEN) creds_present=1 ;;
        SLACK_HOME_CHANNEL) home_set=1 ;;
      esac
    fi
  done

  if [[ "$count" -gt 0 ]]; then
    printf '  Forwarded %s Slack credential(s) from %s: %s\n' "$count" "$source_file" "${names[*]}"
  fi

  # Suppress the recurring "No home channel is set for Slack" notice when Slack
  # credentials are forwarded but no real SLACK_HOME_CHANNEL is configured.
  if [[ "$creds_present" -eq 1 && "$home_set" -eq 0 ]]; then
    printf 'SLACK_SUPPRESS_HOME_CHANNEL_NOTICE=true\n' >> "$profile_env"
    printf '  Slack home channel not provided; suppressing missing-home-channel notice (SLACK_SUPPRESS_HOME_CHANNEL_NOTICE=true)\n'
  fi

  return 0
}

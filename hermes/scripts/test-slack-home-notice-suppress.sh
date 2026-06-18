#!/usr/bin/env bash
# Focused test for lib/slack-tokens.sh forward_slack_tokens().
#
# Verifies the missing-home-channel-notice suppression behavior used by
# hire-junie.sh:
#   - Slack creds forwarded + no SLACK_HOME_CHANNEL  -> suppression flag written
#   - Slack creds forwarded + real SLACK_HOME_CHANNEL -> flag NOT written
#   - never writes a fake SLACK_HOME_CHANNEL
#   - no creds (only allow-list keys) -> flag NOT written
#   - missing source file -> no-op
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/slack-tokens.sh
source "$ROOT/lib/slack-tokens.sh"

fail_count=0
pass_count=0
pass() { pass_count=$((pass_count + 1)); printf '  PASS: %s\n' "$*"; }
fail() { fail_count=$((fail_count + 1)); printf '  FAIL: %s\n' "$*" >&2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

assert_contains() {
  local file="$1" needle="$2" msg="$3"
  if grep -qF "$needle" "$file"; then pass "$msg"; else fail "$msg (missing: $needle)"; fi
}
assert_not_contains() {
  local file="$1" needle="$2" msg="$3"
  if grep -qF "$needle" "$file"; then fail "$msg (unexpected: $needle)"; else pass "$msg"; fi
}

# ── Case 1: creds present, no home channel -> suppress ──
SRC1="$TMP/tokens1"
ENV1="$TMP/env1"
cat > "$SRC1" <<'EOF'
SLACK_BOT_TOKEN=xoxb-test
SLACK_APP_TOKEN=xapp-test
SLACK_ALLOWED_USERS=U123
EOF
: > "$ENV1"
forward_slack_tokens "$ENV1" "$SRC1" >/dev/null
assert_contains "$ENV1" "SLACK_BOT_TOKEN=xoxb-test" "case1: bot token forwarded"
assert_contains "$ENV1" "SLACK_SUPPRESS_HOME_CHANNEL_NOTICE=true" "case1: suppression flag written"
assert_not_contains "$ENV1" "SLACK_HOME_CHANNEL=" "case1: no fake home channel written"

# ── Case 2: creds + real home channel -> no suppression ──
SRC2="$TMP/tokens2"
ENV2="$TMP/env2"
cat > "$SRC2" <<'EOF'
SLACK_BOT_TOKEN=xoxb-test
SLACK_HOME_CHANNEL=C0REALHOME
EOF
: > "$ENV2"
forward_slack_tokens "$ENV2" "$SRC2" >/dev/null
assert_contains "$ENV2" "SLACK_HOME_CHANNEL=C0REALHOME" "case2: real home channel preserved"
assert_not_contains "$ENV2" "SLACK_SUPPRESS_HOME_CHANNEL_NOTICE" "case2: no suppression when home set"

# ── Case 3: no Slack credentials (only allow-list) -> no suppression ──
SRC3="$TMP/tokens3"
ENV3="$TMP/env3"
cat > "$SRC3" <<'EOF'
SLACK_ALLOWED_USERS=U123
SLACK_ALLOW_ALL_USERS=false
EOF
: > "$ENV3"
forward_slack_tokens "$ENV3" "$SRC3" >/dev/null
assert_not_contains "$ENV3" "SLACK_SUPPRESS_HOME_CHANNEL_NOTICE" "case3: no suppression without bot/app token"

# ── Case 4: missing source file -> no-op, returns 0 ──
ENV4="$TMP/env4"
: > "$ENV4"
if forward_slack_tokens "$ENV4" "$TMP/does-not-exist" >/dev/null; then pass "case4: missing source is a no-op (rc=0)"; else fail "case4: missing source should return 0"; fi
if [[ -s "$ENV4" ]]; then fail "case4: env should remain empty"; else pass "case4: env untouched"; fi

printf '\n%s passed, %s failed\n' "$pass_count" "$fail_count"
[[ "$fail_count" -eq 0 ]]

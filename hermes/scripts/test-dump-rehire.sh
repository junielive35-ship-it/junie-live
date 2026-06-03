#!/usr/bin/env bash
# Test dump-junie.sh and rehire-junie.sh disaster recovery scripts.
# Run from the hermes/ subtree root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DUMP_SCRIPT="$ROOT/initialization/scripts/dump-junie.sh"
REHIRE_SCRIPT="$ROOT/scripts/rehire-junie.sh"

fail_count=0
pass_count=0

pass() { pass_count=$((pass_count + 1)); }
fail() { printf '  FAIL: %s\n' "$*" >&2; fail_count=$((fail_count + 1)); }

# ── Setup: temp workspace ──
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_HERMES_HOME="$TMP/hermes-home"
FAKE_REHIRE_HOME="$TMP/rehire-home"
FAKE_HERMES_LOG="$TMP/fake-hermes.log"
FAKE_REHIRE_HERMES_LOG="$TMP/fake-hermes-rehire.log"

PROFILE="junie-live"
PROFILE_DIR="$FAKE_HERMES_HOME/profiles/$PROFILE"

# ── Create fake hermes CLI (named "hermes" so PATH resolution works) ──
mkdir -p "$TMP/bin"
FAKE_HERMES_BIN="$TMP/bin/hermes"
FAKE_REHIRE_HERMES_BIN="$TMP/bin/hermes-rehire"
cat > "$FAKE_HERMES_BIN" <<'FAKEHERMES'
#!/usr/bin/env bash
set -euo pipefail
log="${FAKE_HERMES_LOG:?}"
{
  printf 'HERMES_HOME=%q\n' "${HERMES_HOME:-}"
  printf 'hermes'
  for a in "$@"; do printf ' %q' "$a"; done
  printf '\n'
} >> "$log"
# Simulate profile show success only for our test profile
if [[ "${1:-}" == "profile" && "${2:-}" == "show" ]]; then
  echo "junie-live"
  exit 0
fi
if [[ "${1:-}" == "gateway" && "${2:-}" == "restart" ]]; then
  echo "gateway restarted"
  exit 0
fi
if [[ "${1:-}" == "gateway" && "${2:-}" == "start" ]]; then
  echo "gateway started"
  exit 0
fi
if [[ "${1:-}" == "gateway" && "${2:-}" == "install" ]]; then
  echo "ERROR: gateway install should not be called during rehire" >&2
  exit 1
fi
exit 0
FAKEHERMES
chmod +x "$FAKE_HERMES_BIN"

# Same for rehire home test
cp "$FAKE_HERMES_BIN" "$FAKE_REHIRE_HERMES_BIN"
# Different log
sed -i 's/FAKE_HERMES_LOG/FAKE_REHIRE_HERMES_LOG/' "$FAKE_REHIRE_HERMES_BIN"

# ── Create sample profile ──
mkdir -p "$PROFILE_DIR"/{sessions,skills,plugins,junie-live/state,__pycache__,cache,logs,backups}
mkdir -p "$PROFILE_DIR"/docs
mkdir -p "$PROFILE_DIR"/junie-live/state/backlog/items

cat > "$PROFILE_DIR/config.yaml" <<'CFG'
profile: junie-live
model:
  default: openai/gpt-5.5
  provider: openrouter
CFG

echo "TELEGRAM_BOT_TOKEN=test_token" > "$PROFILE_DIR/.env"

# Create a real SQLite state.db for safe-backup testing
export PROFILE_DIR
python3 <<'PYDB'
import sqlite3, os
db_path = os.path.join(os.environ['PROFILE_DIR'], 'state.db')
con = sqlite3.connect(db_path)
con.execute('CREATE TABLE sessions (id TEXT, data TEXT)')
con.execute("INSERT INTO sessions VALUES ('ses_001', 'test session data')")
con.commit()
con.close()
PYDB

# Create sessions files
echo "session content" > "$PROFILE_DIR/sessions/ses_001.json"

# Create plugins content
echo "plugin data" > "$PROFILE_DIR/plugins/test-plugin.yaml"

# Create junie-live/state content
echo "backlog item" > "$PROFILE_DIR/junie-live/state/backlog/items/backlog-001.md"

# Create transient junk that should be excluded
touch "$PROFILE_DIR/__pycache__/cache.pyc"
touch "$PROFILE_DIR/logs/gateway.log"
touch "$PROFILE_DIR/cache/tmp.dat"
touch "$PROFILE_DIR/backups/old-backup.tgz"
touch "$PROFILE_DIR/state.db-wal"
touch "$PROFILE_DIR/state.db-shm"

# Add a pid file
echo "1234" > "$PROFILE_DIR/gateway.pid"

# ── Helper ──
archive_contents() {
  tar -tzf "$1" 2>/dev/null
}

# ════════════════════════════════════════════════════════════════
printf '=== Test 1: dump creates archive with required files ===\n'

DUMP_OUTPUT="$TMP/test-dump.tgz"
HERMES_HOME="$FAKE_HERMES_HOME" \
FAKE_HERMES_LOG="$FAKE_HERMES_LOG" \
PATH="$TMP/bin:$PATH" \
  "$DUMP_SCRIPT" --profile "$PROFILE" --output "$DUMP_OUTPUT" >/dev/null 2>&1

if [[ -f "$DUMP_OUTPUT" ]]; then
  pass
  printf '  OK: archive created at %s\n' "$DUMP_OUTPUT"
else
  fail "dump did not create archive"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 2: archive contains config.yaml ===\n'

if archive_contents "$DUMP_OUTPUT" | grep -q 'config.yaml'; then
  pass
else
  fail "archive missing config.yaml"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 3: archive contains .env ===\n'

if archive_contents "$DUMP_OUTPUT" | grep -q '\.env'; then
  pass
else
  fail "archive missing .env"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 4: archive contains state.db (safe copy) ===\n'

if archive_contents "$DUMP_OUTPUT" | grep -q 'state\.db'; then
  pass
else
  fail "archive missing state.db"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 5: archive contains sessions/ ===\n'

if archive_contents "$DUMP_OUTPUT" | grep -q 'sessions/ses_001\.json'; then
  pass
else
  fail "archive missing sessions/ses_001.json"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 6: archive contains plugins/ ===\n'

if archive_contents "$DUMP_OUTPUT" | grep -q 'plugins/test-plugin\.yaml'; then
  pass
else
  fail "archive missing plugins/test-plugin.yaml"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 7: archive contains junie-live/state/ ===\n'

if archive_contents "$DUMP_OUTPUT" | grep -q 'junie-live/state/backlog/items/backlog-001\.md'; then
  pass
else
  fail "archive missing junie-live/state/backlog content"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 8: archive excludes __pycache__ ===\n'

if archive_contents "$DUMP_OUTPUT" | grep -q '__pycache__'; then
  fail "archive should exclude __pycache__"
else
  pass
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 9: archive excludes .pyc files ===\n'

if archive_contents "$DUMP_OUTPUT" | grep -q '\.pyc$'; then
  fail "archive should exclude .pyc files"
else
  pass
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 10: archive excludes SQLite WAL/SHM sidecars ===\n'

if archive_contents "$DUMP_OUTPUT" | grep -qE '\.db-wal$|\.db-shm$'; then
  fail "archive should exclude .db-wal/.db-shm"
else
  pass
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 11: archive excludes top-level logs/ ===\n'

if archive_contents "$DUMP_OUTPUT" | grep -q "profiles/$PROFILE/logs/"; then
  fail "archive should exclude profile-level logs/"
else
  pass
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 12: archive excludes top-level cache/ ===\n'

if archive_contents "$DUMP_OUTPUT" | grep -q "profiles/$PROFILE/cache/"; then
  fail "archive should exclude profile-level cache/"
else
  pass
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 12b: archive excludes top-level backups/ ===\n'

if archive_contents "$DUMP_OUTPUT" | grep -q "profiles/$PROFILE/backups/"; then
  fail "archive should exclude profile-level backups/"
else
  pass
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 13: archive excludes pid files ===\n'

if archive_contents "$DUMP_OUTPUT" | grep -q '\.pid$'; then
  fail "archive should exclude .pid files"
else
  pass
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 14: rehire restores profile ===\n'

mkdir -p "$FAKE_REHIRE_HOME"
PATH="$TMP/bin:$PATH" \
HERMES_HOME="$FAKE_REHIRE_HOME" \
FAKE_HERMES_LOG="$FAKE_HERMES_LOG" \
  "$REHIRE_SCRIPT" "$DUMP_OUTPUT" --profile "$PROFILE" >/dev/null 2>&1 && rc=0 || rc=$?

if [[ "$rc" -eq 0 && -f "$FAKE_REHIRE_HOME/profiles/$PROFILE/config.yaml" ]]; then
  pass
  printf '  OK: profile restored with config.yaml\n'
else
  fail "rehire failed (rc=$rc) or missing config.yaml"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 15: rehire restored sessions ===\n'

if [[ -f "$FAKE_REHIRE_HOME/profiles/$PROFILE/sessions/ses_001.json" ]]; then
  pass
else
  fail "rehire did not restore sessions/"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 16: rehire restored state ===\n'

if [[ -f "$FAKE_REHIRE_HOME/profiles/$PROFILE/junie-live/state/backlog/items/backlog-001.md" ]]; then
  pass
else
  fail "rehire did not restore junie-live/state/"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 17: rehire calls gateway restart/start ===\n'

# Create fresh log and fresh rehire target for clean test
FRESH_LOG="$TMP/fresh-hermes.log"
FRESH_HOME="$TMP/fresh-rehire-home"
mkdir -p "$FRESH_HOME"
FRESH_BIN="$TMP/fresh-hermes"
cp "$FAKE_HERMES_BIN" "$FRESH_BIN"
sed 's/FAKE_HERMES_LOG/FRESH_LOG/' -i "$FRESH_BIN"
touch "$FRESH_LOG"

PATH="$TMP/bin:$PATH" \
HERMES_HOME="$FRESH_HOME" \
FAKE_HERMES_LOG="$FRESH_LOG" \
FRESH_LOG="$FRESH_LOG" \
  "$REHIRE_SCRIPT" "$DUMP_OUTPUT" --profile "$PROFILE" >/dev/null 2>&1 || true

FRESH_PROFILE_DIR="$FRESH_HOME/profiles/$PROFILE"
if grep -q 'hermes.*gateway.*restart\|hermes.*gateway.*start' "$FRESH_LOG" 2>/dev/null; then
  pass
  printf '  OK: gateway restart/start called\n'
else
  fail "gateway restart/start not called"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 17b: gateway restart uses restored profile dir as HERMES_HOME ===\n'

# The fake hermes now logs HERMES_HOME=<value>. Check it matches the restored
# profile directory.
if grep -qF "HERMES_HOME=$FRESH_PROFILE_DIR" "$FRESH_LOG" 2>/dev/null; then
  pass
  printf '  OK: gateway HERMES_HOME matches restored profile dir\n'
else
  fail "gateway HERMES_HOME should be $FRESH_PROFILE_DIR, got: $(grep 'HERMES_HOME=' "$FRESH_LOG" 2>/dev/null || echo '(no HERMES_HOME logged)')"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 18: rehire does NOT call gateway install ===\n'

if grep -q 'hermes.*gateway.*install' "$FRESH_LOG" 2>/dev/null; then
  fail "rehire should not call gateway install"
else
  pass
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 19: rehire without --no-gateway-start does not skip gateway ===\n'

# FRESH_LOG already has gateway commands from Test 17
if grep -q 'hermes.*gateway' "$FRESH_LOG" 2>/dev/null; then
  pass
else
  fail "rehire should start gateway by default"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 20: rehire with --no-gateway-start skips gateway ===\n'

SKIP_LOG="$TMP/skip-hermes.log"
SKIP_HOME="$TMP/skip-rehire-home"
mkdir -p "$SKIP_HOME"
SKIP_BIN="$TMP/skip-hermes"
cp "$FAKE_HERMES_BIN" "$SKIP_BIN"
sed 's/FAKE_HERMES_LOG/SKIP_LOG/' -i "$SKIP_BIN"
touch "$SKIP_LOG"

PATH="$TMP/bin:$PATH" \
HERMES_HOME="$SKIP_HOME" \
FAKE_HERMES_LOG="$SKIP_LOG" \
SKIP_LOG="$SKIP_LOG" \
  "$REHIRE_SCRIPT" "$DUMP_OUTPUT" --profile "$PROFILE" --no-gateway-start >/dev/null 2>&1 || true

if grep -q 'hermes.*gateway' "$SKIP_LOG" 2>/dev/null; then
  fail "rehire with --no-gateway-start should not start gateway"
else
  pass
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 21: rehire refuses to overwrite existing profile without --force ===\n'

# Setup: create a profile that already exists
EXISTING_HOME="$TMP/existing-home"
mkdir -p "$EXISTING_HOME/profiles/$PROFILE"
touch "$EXISTING_HOME/profiles/$PROFILE/config.yaml"

EXISTING_LOG="$TMP/existing-hermes.log"
touch "$EXISTING_LOG"

rc=0
PATH="$TMP/bin:$PATH" \
HERMES_HOME="$EXISTING_HOME" \
FAKE_HERMES_LOG="$EXISTING_LOG" \
  "$REHIRE_SCRIPT" "$DUMP_OUTPUT" --profile "$PROFILE" >/dev/null 2>&1 || rc=$?

if [[ "$rc" -ne 0 ]]; then
  pass
  printf '  OK: rehire refused to overwrite (rc=%d)\n' "$rc"
else
  fail "rehire should refuse to overwrite existing profile"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 22: rehire with --force overwrites existing profile ===\n'

rc=0
PATH="$TMP/bin:$PATH" \
HERMES_HOME="$EXISTING_HOME" \
FAKE_HERMES_LOG="$EXISTING_LOG" \
  "$REHIRE_SCRIPT" "$DUMP_OUTPUT" --profile "$PROFILE" --force >/dev/null 2>&1 || rc=$?

if [[ "$rc" -eq 0 && -f "$EXISTING_HOME/profiles/$PROFILE/.env" ]]; then
  pass
  printf '  OK: rehire with --force overwrote profile\n'
else
  fail "rehire with --force failed (rc=$rc)"
fi

# ── Verify the moved-aside backup exists ──
if ls "$EXISTING_HOME/profiles/" | grep -q '\.rehire-before-'; then
  pass
  printf '  OK: old profile moved aside\n'
else
  fail "old profile not moved aside after --force"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 23: rehire with --no-gateway-start and --force ===\n'

FORCE_SKIP_HOME="$TMP/force-skip-home"
mkdir -p "$FORCE_SKIP_HOME/profiles/$PROFILE"
touch "$FORCE_SKIP_HOME/profiles/$PROFILE/config.yaml"
FORCE_SKIP_LOG="$TMP/force-skip-hermes.log"
FORCE_SKIP_BIN="$TMP/force-skip-hermes"
cp "$FAKE_HERMES_BIN" "$FORCE_SKIP_BIN"
sed 's/FAKE_HERMES_LOG/FORCE_SKIP_LOG/' -i "$FORCE_SKIP_BIN"
touch "$FORCE_SKIP_LOG"

rc=0
PATH="$TMP/bin:$PATH" \
HERMES_HOME="$FORCE_SKIP_HOME" \
FAKE_HERMES_LOG="$FORCE_SKIP_LOG" \
FORCE_SKIP_LOG="$FORCE_SKIP_LOG" \
  "$REHIRE_SCRIPT" "$DUMP_OUTPUT" --profile "$PROFILE" --force --no-gateway-start >/dev/null 2>&1 || rc=$?

if [[ "$rc" -eq 0 ]]; then
  pass
else
  fail "rehire with --force --no-gateway-start failed (rc=$rc)"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 24: state.db content preserved (SQLite backup valid) ===\n'

RESTORED_DB="$FAKE_REHIRE_HOME/profiles/$PROFILE/state.db"
if [[ -f "$RESTORED_DB" ]]; then
  result=$(python3 -c "
import sqlite3, os
con = sqlite3.connect('$RESTORED_DB')
cur = con.execute('SELECT data FROM sessions WHERE id = ?', ('ses_001',))
row = cur.fetchone()
con.close()
print(row[0] if row else 'MISSING')
" 2>&1)
  if [[ "$result" == "test session data" ]]; then
    pass
    printf '  OK: state.db contains expected data\n'
  else
    fail "state.db data mismatch: $result"
  fi
else
  fail "state.db not found at $RESTORED_DB"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 25: dump works when HERMES_HOME points at profile dir ===\n'

# Simulate a profile-scoped HERMES_HOME (e.g. inside a Hermes session)
SCOPED_HOME="$TMP/scoped-home"
mkdir -p "$SCOPED_HOME"
# Use the existing FAKE_HERMES_HOME as the root, and point HERMES_HOME at the profile dir
PROFILE_SCOPED_PATH="$FAKE_HERMES_HOME/profiles/$PROFILE"
[[ -d "$PROFILE_SCOPED_PATH" ]] || { fail "test setup: profile dir not found at $PROFILE_SCOPED_PATH"; true; }

SCOPED_DUMP_OUTPUT="$TMP/scoped-dump.tgz"
rc=0
HERMES_HOME="$PROFILE_SCOPED_PATH" \
FAKE_HERMES_LOG="$FAKE_HERMES_LOG" \
PATH="$TMP/bin:$PATH" \
  "$DUMP_SCRIPT" --profile "$PROFILE" --output "$SCOPED_DUMP_OUTPUT" >/dev/null 2>&1 || rc=$?

if [[ "$rc" -eq 0 && -f "$SCOPED_DUMP_OUTPUT" ]]; then
  pass
  printf '  OK: dump succeeded with profile-scoped HERMES_HOME\n'
else
  fail "dump failed (rc=$rc) when HERMES_HOME=$PROFILE_SCOPED_PATH"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 26: dump from scoped HERMES_HOME includes expected files ===\n'

if archive_contents "$SCOPED_DUMP_OUTPUT" | grep -q "profiles/$PROFILE/config.yaml"; then
  pass
  printf '  OK: archive from scoped HERMES_HOME has correct paths\n'
else
  fail "archive from scoped HERMES_HOME missing expected paths"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 27: rehire resolves root when HERMES_HOME is profile-scoped ===\n'

# Simulate rehire inside a profile-scoped session: HERMES_HOME points at the
# profile dir, but rehire should resolve the root and restore there.
SCOPED_REHIRE_LOG="$TMP/scoped-rehire-hermes.log"
touch "$SCOPED_REHIRE_LOG"
SCOPED_REHIRE_BIN="$TMP/scoped-rehire-hermes"
cp "$FAKE_HERMES_BIN" "$SCOPED_REHIRE_BIN"
sed 's/FAKE_HERMES_LOG/SCOPED_REHIRE_LOG/' -i "$SCOPED_REHIRE_BIN"

SCOPED_REHIRE_HOME="$TMP/scoped-rehire-home"
mkdir -p "$SCOPED_REHIRE_HOME"

# Set HERMES_HOME to a profile-like path that doesn't exist yet (rehire
# should resolve it to the root, not double-nest)
PROFILE_LIKE_PATH="$SCOPED_REHIRE_HOME/profiles/$PROFILE"
rc=0
PATH="$TMP/bin:$PATH" \
HERMES_HOME="$PROFILE_LIKE_PATH" \
FAKE_HERMES_LOG="$SCOPED_REHIRE_LOG" \
SCOPED_REHIRE_LOG="$SCOPED_REHIRE_LOG" \
  "$REHIRE_SCRIPT" "$DUMP_OUTPUT" --profile "$PROFILE" --no-gateway-start >/dev/null 2>&1 || rc=$?

if [[ "$rc" -eq 0 && -f "$SCOPED_REHIRE_HOME/profiles/$PROFILE/config.yaml" ]]; then
  pass
  printf '  OK: rehire resolved root correctly\n'
else
  fail "rehire with profile-scoped HERMES_HOME failed (rc=$rc)"
  # Debug: check what's where
  ls -R "$SCOPED_REHIRE_HOME" 2>/dev/null | head -20 || true
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 28: no double-nesting (profiles/junie-live/profiles/junie-live) ===\n'

if [[ -d "$SCOPED_REHIRE_HOME/profiles/$PROFILE/profiles" ]]; then
  fail "double-nesting detected: profiles/$PROFILE/profiles/ exists"
elif [[ -f "$SCOPED_REHIRE_HOME/profiles/$PROFILE/profiles" ]]; then
  fail "double-nesting detected: profiles/$PROFILE/profiles exists as file"
else
  pass
  printf '  OK: no double-nesting\n'
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 29: JUNIE_HERMES_ROOT override works ===\n'

OVERRIDE_HOME="$TMP/override-home"
OVERRIDE_DUMP="$TMP/override-dump.tgz"
mkdir -p "$OVERRIDE_HOME/profiles/$PROFILE"
echo "config: override" > "$OVERRIDE_HOME/profiles/$PROFILE/config.yaml"

rc=0
JUNIE_HERMES_ROOT="$OVERRIDE_HOME" \
HERMES_HOME="/nonexistent/bogus" \
FAKE_HERMES_LOG="$FAKE_HERMES_LOG" \
PATH="$TMP/bin:$PATH" \
  "$DUMP_SCRIPT" --profile "$PROFILE" --output "$OVERRIDE_DUMP" >/dev/null 2>&1 || rc=$?

if [[ "$rc" -eq 0 && -f "$OVERRIDE_DUMP" ]]; then
  pass
  printf '  OK: JUNIE_HERMES_ROOT override works\n'
else
  fail "JUNIE_HERMES_ROOT override failed (rc=$rc)"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 30: rehire with JUNIE_HERMES_ROOT uses correct gateway HERMES_HOME ===\n'

# Rehire into a non-standard root via JUNIE_HERMES_ROOT and verify gateway
# is started with HERMES_HOME pointing into that root.
OVERRIDE_REHIRE_ROOT="$TMP/override-rehire-root"
OVERRIDE_REHIRE_LOG="$TMP/override-rehire-hermes.log"
OVERRIDE_REHIRE_BIN="$TMP/override-rehire-hermes"
cp "$FAKE_HERMES_BIN" "$OVERRIDE_REHIRE_BIN"
sed 's/FAKE_HERMES_LOG/OVERRIDE_REHIRE_LOG/' -i "$OVERRIDE_REHIRE_BIN"
touch "$OVERRIDE_REHIRE_LOG"

rc=0
JUNIE_HERMES_ROOT="$OVERRIDE_REHIRE_ROOT" \
HERMES_HOME="/nonexistent" \
PATH="$TMP/bin:$PATH" \
FAKE_HERMES_LOG="$OVERRIDE_REHIRE_LOG" \
OVERRIDE_REHIRE_LOG="$OVERRIDE_REHIRE_LOG" \
  "$REHIRE_SCRIPT" "$DUMP_OUTPUT" --profile "$PROFILE" >/dev/null 2>&1 || rc=$?

if [[ "$rc" -eq 0 ]]; then
  pass
  printf '  OK: rehire with JUNIE_HERMES_ROOT succeeded\n'
else
  fail "rehire with JUNIE_HERMES_ROOT failed (rc=$rc)"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 30b: JUNIE_HERMES_ROOT rehire gateway runs against correct profile dir ===\n'

EXPECTED_HH="$OVERRIDE_REHIRE_ROOT/profiles/$PROFILE"
if grep -qF "HERMES_HOME=$EXPECTED_HH" "$OVERRIDE_REHIRE_LOG" 2>/dev/null; then
  pass
  printf '  OK: HERMES_HOME matches override root profile dir\n'
else
  fail "expected HERMES_HOME=$EXPECTED_HH, got: $(grep 'HERMES_HOME=' "$OVERRIDE_REHIRE_LOG" 2>/dev/null || echo '(none)')"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 31: profile-local script dump works (simulates VM without repo) ===\n'

# Simulate the profile having scripts/ installed by hire-junie.sh.
# Only dump-junie.sh is seeded; rehire-junie.sh stays a repo script.
PROFILE_LOCAL_SCRIPTS_DIR="$FAKE_HERMES_HOME/profiles/$PROFILE/scripts"
mkdir -p "$PROFILE_LOCAL_SCRIPTS_DIR"
cp "$DUMP_SCRIPT" "$PROFILE_LOCAL_SCRIPTS_DIR/dump-junie.sh"
chmod +x "$PROFILE_LOCAL_SCRIPTS_DIR/dump-junie.sh"

LOCAL_DUMP_OUTPUT="$TMP/local-dump.tgz"
rc=0
HERMES_HOME="$FAKE_HERMES_HOME" \
FAKE_HERMES_LOG="$FAKE_HERMES_LOG" \
PATH="$TMP/bin:$PATH" \
  "$PROFILE_LOCAL_SCRIPTS_DIR/dump-junie.sh" --profile "$PROFILE" --output "$LOCAL_DUMP_OUTPUT" >/dev/null 2>&1 || rc=$?

if [[ "$rc" -eq 0 && -f "$LOCAL_DUMP_OUTPUT" ]]; then
  pass
  printf '  OK: profile-local dump created archive\n'
else
  fail "profile-local dump failed (rc=$rc)"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 32: profile-local dump archive contains expected files ===\n'

if archive_contents "$LOCAL_DUMP_OUTPUT" | grep -q 'config.yaml' && \
   archive_contents "$LOCAL_DUMP_OUTPUT" | grep -q 'state\.db'; then
  pass
  printf '  OK: archive from profile-local dump has expected content\n'
else
  fail "archive from profile-local dump missing expected files"
fi

# ════════════════════════════════════════════════════════════════
printf '\n=== Results ===\n'
printf 'Passed: %d, Failed: %d\n' "$pass_count" "$fail_count"

if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi

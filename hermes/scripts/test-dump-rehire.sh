#!/usr/bin/env bash
# Test dump-junie.sh and rehire-junie.sh disaster recovery scripts.
# Run from the hermes/ subtree root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DUMP_SCRIPT="$ROOT/distribution/scripts/dump-junie.sh"
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
# Simulate profile export
if [[ "${1:-}" == "profile" && "${2:-}" == "export" ]]; then
  profile_name="${3:-}"
  output_file=""
  if [[ "${4:-}" == "-o" ]]; then
    output_file="${5:-}"
  fi
  if [[ -z "$profile_name" || -z "$output_file" ]]; then
    echo "ERROR: usage: hermes profile export PROFILE -o OUTPUT" >&2
    exit 1
  fi
  profile_src="${HERMES_HOME}/profiles/${profile_name}"
  if [[ ! -d "$profile_src" ]]; then
    echo "ERROR: profile not found: $profile_src" >&2
    exit 1
  fi
  tmpdir="$(mktemp -d)"
  cp -a "$profile_src" "$tmpdir/${profile_name}"
  (cd "$tmpdir" && tar -czf "$output_file" "$profile_name")
  rm -rf "$tmpdir"
  exit 0
fi
# Simulate profile import
if [[ "${1:-}" == "profile" && "${2:-}" == "import" ]]; then
  archive=""
  profile_name=""
  found_name=0
  for arg in "$@"; do
    if [[ "$found_name" -eq 1 ]]; then
      profile_name="$arg"
      found_name=0
    elif [[ "$arg" == "--name" ]]; then
      found_name=1
    elif [[ -z "$archive" && "$arg" != "profile" && "$arg" != "import" ]]; then
      archive="$arg"
    fi
  done
  if [[ -z "$profile_name" ]]; then
    echo "ERROR: --name required for profile import" >&2
    exit 1
  fi
  if [[ ! -f "$archive" ]]; then
    echo "ERROR: archive not found: $archive" >&2
    exit 1
  fi
  hermes_root="${HERMES_HOME:-$HOME/.hermes}"
  import_tmp="$(mktemp -d)"
  tar -xzf "$archive" -C "$import_tmp"
  topdirs=("$import_tmp"/*)
  if [[ ${#topdirs[@]} -ne 1 || ! -d "${topdirs[0]}" ]]; then
    echo "ERROR: expected single top-level directory in archive" >&2
    exit 1
  fi
  mkdir -p "$hermes_root/profiles"
  mv "${topdirs[0]}" "$hermes_root/profiles/$profile_name"
  rm -rf "$import_tmp"
  exit 0
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

# ── Runtime manifest setup for wheel artifact tests ──
RUNTIME_MANIFEST_DIR="$PROFILE_DIR/junie-live/runtime"
mkdir -p "$RUNTIME_MANIFEST_DIR"
HELPER="$ROOT/distribution/scripts/junie-runtime-artifact.py"
python3 "$HELPER" write-install-manifest \
  --runtime-dir "$ROOT/junie_runtime" \
  --repo-root "$ROOT" \
  --manifest-dir "$RUNTIME_MANIFEST_DIR" \
  --installed-python "python3" >/dev/null

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
printf '=== Test 1a: archive has single top-level profile dir (not profiles/) ===\n'

TOP_LEVEL="$(archive_contents "$DUMP_OUTPUT" | cut -d/ -f1 | sort -u)"
if [[ "$TOP_LEVEL" == "$PROFILE" ]]; then
  pass
  printf '  OK: top-level dir is %s\n' "$TOP_LEVEL"
else
  fail "top-level should be '$PROFILE', got: $TOP_LEVEL"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 1b: no build artifacts left in runtime source tree ===\n'

if [[ -d "$ROOT/junie_runtime/build" ]]; then
  fail "build artifacts remain under runtime source: $ROOT/junie_runtime/build"
elif ls "$ROOT/junie_runtime/"*.egg-info 2>/dev/null | grep -q .; then
  fail "build artifacts remain under runtime source: egg-info found"
else
  pass
  printf '  OK: no build artifacts under %s\n' "$ROOT/junie_runtime"
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

if archive_contents "$DUMP_OUTPUT" | grep -q "$PROFILE/logs/"; then
  fail "archive should exclude profile-level logs/"
else
  pass
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 12: archive excludes top-level cache/ ===\n'

if archive_contents "$DUMP_OUTPUT" | grep -q "$PROFILE/cache/"; then
  fail "archive should exclude profile-level cache/"
else
  pass
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 12b: archive excludes top-level backups/ ===\n'

if archive_contents "$DUMP_OUTPUT" | grep -q "$PROFILE/backups/"; then
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

if archive_contents "$SCOPED_DUMP_OUTPUT" | grep -q "$PROFILE/config.yaml"; then
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
# Create runtime manifest for override profile
OVERRIDE_MANIFEST_DIR="$OVERRIDE_HOME/profiles/$PROFILE/junie-live/runtime"
mkdir -p "$OVERRIDE_MANIFEST_DIR"
python3 "$ROOT/distribution/scripts/junie-runtime-artifact.py" write-install-manifest \
  --runtime-dir "$ROOT/junie_runtime" \
  --repo-root "$ROOT" \
  --manifest-dir "$OVERRIDE_MANIFEST_DIR" \
  --installed-python "python3" >/dev/null

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
# Also copy junie-runtime-artifact.py (called by dump-junie.sh)
cp "$ROOT/distribution/scripts/junie-runtime-artifact.py" "$PROFILE_LOCAL_SCRIPTS_DIR/junie-runtime-artifact.py"

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
printf '=== Test 33: dump archive includes runtime/junie_runtime.json ===\n'

if archive_contents "$DUMP_OUTPUT" | grep -q 'junie-live/runtime_artifact/junie_runtime.json'; then
  pass
  printf '  OK: archive contains junie-live/runtime_artifact/junie_runtime.json\n'
else
  fail "archive missing junie-live/runtime_artifact/junie_runtime.json"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 34: dump archive includes a wheel in junie-live/runtime_artifact/ ===\n'

WHEEL_IN_ARCHIVE="$(archive_contents "$DUMP_OUTPUT" | grep 'junie-live/runtime_artifact/.*\.whl' | head -1 || true)"
if [[ -n "$WHEEL_IN_ARCHIVE" ]]; then
  pass
  printf '  OK: archive contains wheel: %s\n' "$WHEEL_IN_ARCHIVE"
else
  fail "archive missing wheel file in junie-live/runtime_artifact/"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 35: runtime manifest includes sha256 and installed_python ===\n'

if python3 "$HELPER" archive-manifest-summary "$DUMP_OUTPUT" wheel_sha256 installed_python wheel_filename >/dev/null 2>&1; then
  pass
  printf '  OK: manifest has sha256, installed_python, wheel_filename\n'
else
  MANIFEST_CHECK="$(python3 "$HELPER" archive-manifest-summary "$DUMP_OUTPUT" wheel_sha256 installed_python 2>&1)"
  fail "manifest missing required fields: $MANIFEST_CHECK"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 36: rehire restores from artifact (verifies restored manifest metadata) ===\n'

HASH_REHIRE_HOME="$TMP/hash-rehire-home"
HASH_REHIRE_LOG="$TMP/hash-rehire-hermes.log"
HASH_REHIRE_BIN="$TMP/hash-rehire-hermes"
cp "$FAKE_HERMES_BIN" "$HASH_REHIRE_BIN"
sed 's/FAKE_HERMES_LOG/HASH_REHIRE_LOG/' -i "$HASH_REHIRE_BIN"
touch "$HASH_REHIRE_LOG"

rc=0
PATH="$TMP/bin:$PATH" \
HERMES_HOME="$HASH_REHIRE_HOME" \
FAKE_HERMES_LOG="$HASH_REHIRE_LOG" \
HASH_REHIRE_LOG="$HASH_REHIRE_LOG" \
  "$REHIRE_SCRIPT" "$DUMP_OUTPUT" --profile "$PROFILE" --no-gateway-start >/dev/null 2>&1 || rc=$?

if [[ "$rc" -eq 0 ]]; then
  # Verify restore manifest was written
  RESTORE_MANIFEST="$HASH_REHIRE_HOME/profiles/$PROFILE/junie-live/runtime/junie_runtime.json"
  if [[ -f "$RESTORE_MANIFEST" ]]; then
    if python3 "$HELPER" manifest-has-fields "$RESTORE_MANIFEST" restored_at restored_from_archive installed_python >/dev/null 2>&1; then
      pass
      printf '  OK: rehire succeeded and restore manifest has metadata\n'
    else
      HAS_RESTORE="$(python3 "$HELPER" manifest-has-fields "$RESTORE_MANIFEST" restored_at restored_from_archive installed_python 2>&1)"
      fail "restore manifest missing restore metadata: $HAS_RESTORE"
    fi
  else
    fail "restore manifest not found at $RESTORE_MANIFEST"
  fi
else
  fail "rehire with archive wheel failed (rc=$rc)"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 37: rehire fails on wheel hash mismatch ===\n'

CORRUPT_DIR="$TMP/corrupt"
CORRUPT_ARCHIVE="$TMP/corrupt-dump.tgz"
mkdir -p "$CORRUPT_DIR"
tar -xzf "$DUMP_OUTPUT" -C "$CORRUPT_DIR" 2>/dev/null

# Corrupt the manifest hash
python3 "$HELPER" corrupt-manifest-hash "$CORRUPT_DIR/$PROFILE/junie-live/runtime_artifact/junie_runtime.json" 2>/dev/null || true

tar -czf "$CORRUPT_ARCHIVE" -C "$CORRUPT_DIR" . 2>/dev/null

CORRUPT_REHIRE_HOME="$TMP/corrupt-rehire-home"
CORRUPT_REHIRE_LOG="$TMP/corrupt-rehire-hermes.log"
CORRUPT_REHIRE_BIN="$TMP/corrupt-rehire-hermes"
cp "$FAKE_HERMES_BIN" "$CORRUPT_REHIRE_BIN"
sed 's/FAKE_HERMES_LOG/CORRUPT_REHIRE_LOG/' -i "$CORRUPT_REHIRE_BIN"
touch "$CORRUPT_REHIRE_LOG"

rc=0
PATH="$TMP/bin:$PATH" \
HERMES_HOME="$CORRUPT_REHIRE_HOME" \
FAKE_HERMES_LOG="$CORRUPT_REHIRE_LOG" \
CORRUPT_REHIRE_LOG="$CORRUPT_REHIRE_LOG" \
  "$REHIRE_SCRIPT" "$CORRUPT_ARCHIVE" --profile "$PROFILE" --no-gateway-start >/dev/null 2>&1 || rc=$?

if [[ "$rc" -ne 0 ]]; then
  pass
  printf '  OK: rehire correctly rejected hash mismatch (rc=%d)\n' "$rc"
else
  fail "rehire should have failed on hash mismatch (rc=0)"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 38: rehire fails gracefully when no runtime artifact ===\n'

NO_RT_DIR="$TMP/no-rt"
NO_RT_ARCHIVE="$TMP/no-rt-dump.tgz"
mkdir -p "$NO_RT_DIR"
tar -xzf "$DUMP_OUTPUT" -C "$NO_RT_DIR" 2>/dev/null
rm -rf "$NO_RT_DIR/$PROFILE/junie-live/runtime_artifact"
tar -czf "$NO_RT_ARCHIVE" -C "$NO_RT_DIR" . 2>/dev/null

NO_RT_REHIRE_HOME="$TMP/no-rt-rehire-home"
NO_RT_REHIRE_LOG="$TMP/no-rt-rehire-hermes.log"
NO_RT_REHIRE_BIN="$TMP/no-rt-rehire-hermes"
cp "$FAKE_HERMES_BIN" "$NO_RT_REHIRE_BIN"
sed 's/FAKE_HERMES_LOG/NO_RT_REHIRE_LOG/' -i "$NO_RT_REHIRE_BIN"
touch "$NO_RT_REHIRE_LOG"

rc=0
PATH="$TMP/bin:$PATH" \
HERMES_HOME="$NO_RT_REHIRE_HOME" \
FAKE_HERMES_LOG="$NO_RT_REHIRE_LOG" \
NO_RT_REHIRE_LOG="$NO_RT_REHIRE_LOG" \
  "$REHIRE_SCRIPT" "$NO_RT_ARCHIVE" --profile "$PROFILE" --no-gateway-start >/dev/null 2>&1 || rc=$?

if [[ "$rc" -ne 0 ]]; then
  pass
  printf '  OK: rehire correctly rejected archive without runtime artifact (rc=%d)\n' "$rc"
else
  fail "rehire should have failed when no runtime artifact (rc=0)"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 39: rehire does not silently install from sibling source ===\n'

# Use a separate home dir to avoid test 38 collision
MSG_REHIRE_HOME="$TMP/msg-rehire-home"
MSG_REHIRE_LOG="$TMP/msg-rehire-hermes.log"
MSG_REHIRE_BIN="$TMP/msg-rehire-hermes"
cp "$FAKE_HERMES_BIN" "$MSG_REHIRE_BIN"
sed 's/FAKE_HERMES_LOG/MSG_REHIRE_LOG/' -i "$MSG_REHIRE_BIN"
touch "$MSG_REHIRE_LOG"

# Verify that the no-artifact failure message mentions the branch/source
NO_RT_OUTPUT="$TMP/no-rt-output.txt"
rc=0
PATH="$TMP/bin:$PATH" \
HERMES_HOME="$MSG_REHIRE_HOME" \
FAKE_HERMES_LOG="$MSG_REHIRE_LOG" \
MSG_REHIRE_LOG="$MSG_REHIRE_LOG" \
  "$REHIRE_SCRIPT" "$NO_RT_ARCHIVE" --profile "$PROFILE" --no-gateway-start >"$NO_RT_OUTPUT" 2>&1 || rc=$?

if grep -qiE 'runtime artifact|junie_runtime.*wheel|newer dump' "$NO_RT_OUTPUT" 2>/dev/null; then
  pass
  printf '  OK: error message references runtime artifact requirement\n'
else
  fail "error message should mention runtime artifact requirement"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 40: rehire invokes install-senior-dev-profile.sh ===\n'

T40_HOME="$TMP/t40-rehire-home"
T40_LOG="$TMP/t40-rehire-hermes.log"
T40_BIN="$TMP/t40-rehire-hermes"
cp "$FAKE_HERMES_BIN" "$T40_BIN"
sed 's/FAKE_HERMES_LOG/T40_LOG/' -i "$T40_BIN"
touch "$T40_LOG"

rc=0
PATH="$TMP/bin:$PATH" \
HERMES_HOME="$T40_HOME" \
FAKE_HERMES_LOG="$T40_LOG" \
T40_LOG="$T40_LOG" \
  "$REHIRE_SCRIPT" "$DUMP_OUTPUT" --profile "$PROFILE" >/dev/null 2>&1 || rc=$?

if [[ "$rc" -eq 0 ]]; then
  if grep -q 'senior-dev' "$T40_LOG" 2>/dev/null; then
    pass
    printf '  OK: senior-dev profile install invoked by rehire\n'
  else
    fail "senior-dev profile install NOT invoked by rehire"
  fi
else
  fail "rehire for senior-dev test failed (rc=$rc)"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 41: rehire with --no-gateway-start still installs senior-dev ===\n'

T41_HOME="$TMP/t41-rehire-home"
T41_LOG="$TMP/t41-rehire-hermes.log"
T41_BIN="$TMP/t41-rehire-hermes"
cp "$FAKE_HERMES_BIN" "$T41_BIN"
sed 's/FAKE_HERMES_LOG/T41_LOG/' -i "$T41_BIN"
touch "$T41_LOG"

rc=0
PATH="$TMP/bin:$PATH" \
HERMES_HOME="$T41_HOME" \
FAKE_HERMES_LOG="$T41_LOG" \
T41_LOG="$T41_LOG" \
  "$REHIRE_SCRIPT" "$DUMP_OUTPUT" --profile "$PROFILE" --no-gateway-start >/dev/null 2>&1 || rc=$?

if [[ "$rc" -eq 0 ]]; then
  if grep -q 'senior-dev' "$T41_LOG" 2>/dev/null; then
    pass
    printf '  OK: senior-dev install invoked with --no-gateway-start\n'
  else
    fail "senior-dev NOT installed when --no-gateway-start"
  fi
else
  fail "rehire with --no-gateway-start failed (rc=$rc)"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 42: existing gateway start test remains valid ===\n'

# Gateway was started in T40 (no --no-gateway-start)
if grep -q 'hermes.*gateway' "$T40_LOG" 2>/dev/null; then
  pass
  printf '  OK: gateway started in default rehire\n'
else
  fail "gateway not started - existing gateway test broken"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 43: --no-gateway-start does not start gateway (senior-dev still installed) ===\n'

if grep -q 'hermes.*gateway' "$T41_LOG" 2>/dev/null; then
  fail "gateway was started despite --no-gateway-start"
else
  pass
  printf '  OK: gateway NOT started with --no-gateway-start\n'
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 44: rehire with --force --no-gateway-start installs senior-dev ===\n'

T44_HOME="$TMP/t44-rehire-home"
T44_LOG="$TMP/t44-rehire-hermes.log"
T44_BIN="$TMP/t44-rehire-hermes"
cp "$FAKE_HERMES_BIN" "$T44_BIN"
sed 's/FAKE_HERMES_LOG/T44_LOG/' -i "$T44_BIN"
touch "$T44_LOG"
mkdir -p "$T44_HOME/profiles/$PROFILE"
touch "$T44_HOME/profiles/$PROFILE/config.yaml"

rc=0
PATH="$TMP/bin:$PATH" \
HERMES_HOME="$T44_HOME" \
FAKE_HERMES_LOG="$T44_LOG" \
T44_LOG="$T44_LOG" \
  "$REHIRE_SCRIPT" "$DUMP_OUTPUT" --profile "$PROFILE" --force --no-gateway-start >/dev/null 2>&1 || rc=$?

if [[ "$rc" -eq 0 ]]; then
  if grep -q 'senior-dev' "$T44_LOG" 2>/dev/null; then
    pass
    printf '  OK: senior-dev install invoked with --force --no-gateway-start\n'
  else
    fail "senior-dev NOT installed with --force --no-gateway-start"
  fi
else
  fail "rehire with --force --no-gateway-start failed (rc=$rc)"
fi

# ════════════════════════════════════════════════════════════════
printf '\n=== Hire-junie.sh: native profile delete tests ===\n'

HIRE_SCRIPT="$ROOT/scripts/hire-junie.sh"

# Create a minimal seed directory for hire-junie.sh
HIRE_SEED_DIR="$TMP/hire-seed"
mkdir -p "$HIRE_SEED_DIR"/docs
cat > "$HIRE_SEED_DIR/distribution.yaml" <<'EOF'
distribution: junie-live
version: "1.0"
EOF
echo "# SOUL.md" > "$HIRE_SEED_DIR/SOUL.md"
echo "# INITIALIZATION.md" > "$HIRE_SEED_DIR/INITIALIZATION.md"
echo "# tools.md" > "$HIRE_SEED_DIR/docs/tools.md"

# Fake hermes factory for hire-junie tests.
# Usage: make_hire_fake_hermes <bin_path> <log_path> <profile_exists (0|1)>
# Creates a fake hermes that logs invocations and handles profile show/delete/install
# plus all other commands hire-junie.sh calls.
make_hire_fake_hermes() {
  local bin="$1" log="$2" exists="$3"
  cat > "$bin" <<FAKEHIRES
#!/usr/bin/env bash
set -euo pipefail
LOG="$log"
EXISTS=$exists
{
  printf 'hermes'
  for a in "\$@"; do printf ' %q' "\$a"; done
  printf '\n'
} >> "\$LOG"

case "\${1:-}" in
  profile)
    case "\${2:-}" in
      show) [ "\$EXISTS" = "1" ] && exit 0 || exit 1 ;;
      delete) rm -rf "\${HERMES_HOME:?}/profiles/\${3:?}" 2>/dev/null || true; exit 0 ;;
      install)
        sd="\${3:-}"
        nm=""
        args=("\$@")
        for ((i=0; i<\${#args[@]}; i++)); do
          if [ "\${args[\$i]}" = "--name" ] && [ \$((i+1)) -lt \${#args[@]} ]; then
            nm="\${args[\$((i+1))]}"
          fi
        done
        if [ -n "\$nm" ] && [ -n "\$sd" ] && [ -d "\$sd" ]; then
          mkdir -p "\${HERMES_HOME:?}/profiles/\$nm"
          cp -a "\$sd/." "\${HERMES_HOME:?}/profiles/\$nm/"
        fi
        exit 0
        ;;
      *) exit 0 ;;
    esac
    ;;
  -p)
    # All hermes -p <profile> <subcommand> calls: plugins, tools, config, gateway
    exit 0
    ;;
  gateway) exit 0 ;;
  *) exit 0 ;;
esac
FAKEHIRES
  chmod +x "$bin"
}

# ════════════════════════════════════════════════════════════════
printf '=== Hire test A: profile exists → delete + install ===\n'

A_BIN_DIR="$TMP/hire-a-bin"
A_HOME="$TMP/hire-a-home"
A_LOG="$TMP/hire-a-hermes.log"
mkdir -p "$A_BIN_DIR" "$A_HOME/profiles/junie-live"  # Pre-existing profile
make_hire_fake_hermes "$A_BIN_DIR/hermes" "$A_LOG" 1

A_EXIT=0
PATH="$A_BIN_DIR:$PATH" \
HERMES_HOME="$A_HOME" \
"$HIRE_SCRIPT" \
  --telegram-token "tok_test" \
  --admin-telegram-id "12345" \
  --seed-dir "$HIRE_SEED_DIR" \
  --no-restart \
  --no-backup \
  --no-forward-keys \
  >/dev/null 2>&1 || A_EXIT=$?

if [[ "$A_EXIT" -eq 0 ]]; then
  pass
  printf '  OK: hire with existing profile succeeded\n'
else
  fail "hire with existing profile failed (rc=$A_EXIT)"
fi

# Check that profile delete was called
if grep -q 'hermes profile delete' "$A_LOG" 2>/dev/null; then
  pass
  printf '  OK: hermes profile delete was called\n'
else
  fail "hermes profile delete was NOT called"
fi

# Check that profile install was called with --alias
if grep -q 'hermes profile install.*--alias' "$A_LOG" 2>/dev/null; then
  pass
  printf '  OK: hermes profile install uses --alias\n'
else
  fail "hermes profile install does not use --alias"
fi

# Check that --force is NOT present in the install call
if grep -q 'hermes profile install.*--force' "$A_LOG" 2>/dev/null; then
  fail "hermes profile install uses --force (should not with native delete)"
else
  pass
  printf '  OK: hermes profile install does not use --force\n'
fi

# Check that profile create was NOT called
if grep -q 'hermes profile create' "$A_LOG" 2>/dev/null; then
  fail "hermes profile create was called (should not be)"
else
  pass
  printf '  OK: hermes profile create was NOT called\n'
fi

# Verify INITIALIZATION.md landed in profile dir after install
if [[ -f "$A_HOME/profiles/junie-live/INITIALIZATION.md" ]]; then
  pass
  printf '  OK: INITIALIZATION.md installed into profile\n'
else
  fail "INITIALIZATION.md missing from installed profile"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Hire test B: profile does NOT exist → no delete, fresh install ===\n'

B_BIN_DIR="$TMP/hire-b-bin"
B_HOME="$TMP/hire-b-home"
B_LOG="$TMP/hire-b-hermes.log"
mkdir -p "$B_BIN_DIR" "$B_HOME"  # No profile dir
make_hire_fake_hermes "$B_BIN_DIR/hermes" "$B_LOG" 0

B_EXIT=0
PATH="$B_BIN_DIR:$PATH" \
HERMES_HOME="$B_HOME" \
"$HIRE_SCRIPT" \
  --telegram-token "tok_test" \
  --admin-telegram-id "12345" \
  --seed-dir "$HIRE_SEED_DIR" \
  --no-restart \
  --no-backup \
  --no-forward-keys \
  >/dev/null 2>&1 || B_EXIT=$?

if [[ "$B_EXIT" -eq 0 ]]; then
  pass
  printf '  OK: hire without existing profile succeeded\n'
else
  fail "hire without existing profile failed (rc=$B_EXIT)"
fi

# Check that profile delete was NOT called
if grep -q 'hermes profile delete' "$B_LOG" 2>/dev/null; then
  fail "hermes profile delete was called but profile did not exist"
else
  pass
  printf '  OK: hermes profile delete was NOT called (profile did not exist)\n'
fi

# Check that profile install was called
if grep -q 'hermes profile install' "$B_LOG" 2>/dev/null; then
  pass
  printf '  OK: hermes profile install was called\n'
else
  fail "hermes profile install was NOT called"
fi

# Check that INSTALL uses --alias
if grep -q 'hermes profile install.*--alias' "$B_LOG" 2>/dev/null; then
  pass
  printf '  OK: install uses --alias\n'
else
  fail "install does not use --alias"
fi

# Check that INSTALL does NOT use --force
if grep -q 'hermes profile install.*--force' "$B_LOG" 2>/dev/null; then
  fail "install uses --force (should not)"
else
  pass
  printf '  OK: install does not use --force\n'
fi

# ════════════════════════════════════════════════════════════════
printf '=== Hire test C: no manual rm -rf profile cleanup in hire-junie.sh ===\n'

# Check for any rm -rf -- "$PROFILE_DIR" patterns (the old manual cleanup)
if grep -qnE 'rm\s+-rf\s+--\s+"\$PROFILE_DIR' "$HIRE_SCRIPT" 2>/dev/null; then
  fail "hire-junie.sh still contains rm -rf on PROFILE_DIR paths"
else
  pass
  printf '  OK: no rm -rf PROFILE_DIR cleanup in hire-junie.sh\n'
fi

# Also confirm SEED_OWNED_PATHS is gone
if grep -q 'SEED_OWNED_PATHS' "$HIRE_SCRIPT" 2>/dev/null; then
  fail "hire-junie.sh still defines SEED_OWNED_PATHS"
else
  pass
  printf '  OK: SEED_OWNED_PATHS removed\n'
fi

# Confirm runtime_cleared logic is gone
if grep -q 'runtime_cleared' "$HIRE_SCRIPT" 2>/dev/null; then
  fail "hire-junie.sh still has runtime_cleared logic"
else
  pass
  printf '  OK: runtime state cleanup removed\n'
fi

# ════════════════════════════════════════════════════════════════
printf '=== Hire test Cb: hire-junie.sh invokes install-senior-dev-profile.sh ===\n'
if grep -qE 'install-senior-dev-profile\.sh' "$HIRE_SCRIPT" 2>/dev/null; then
  pass
  printf '  OK: hire-junie.sh references install-senior-dev-profile.sh\n'
else
  fail "hire-junie.sh does not reference install-senior-dev-profile.sh"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Hire test Cc: install-senior-dev-profile.sh exists and is executable ===\n'
if [[ -f "$ROOT/scripts/install-senior-dev-profile.sh" && -x "$ROOT/scripts/install-senior-dev-profile.sh" ]]; then
  pass
  printf '  OK: install-senior-dev-profile.sh exists and is executable\n'
else
  fail "install-senior-dev-profile.sh missing or not executable"
fi

# ════════════════════════════════════════════════════════════════
printf '\n=== Hire-junie.sh: backup behavior tests ===\n'

# Create a minimal temp hire tree so the hire script resolves its siblings
# (dump-junie.sh, junie-runtime-artifact.py, junie_runtime/) via relative
# paths without ever touching tracked repo files.
HIRE_TREE="$TMP/hire-backup-test-root"
mkdir -p "$HIRE_TREE"/{scripts,distribution/scripts}
# Copy the real hire script into the tree (always chmod +x).
cp "$HIRE_SCRIPT" "$HIRE_TREE/scripts/hire-junie.sh"
chmod +x "$HIRE_TREE/scripts/hire-junie.sh"
# Provide a real junie-runtime-artifact.py so post-install manifest writes work.
cp "$ROOT/distribution/scripts/junie-runtime-artifact.py" "$HIRE_TREE/distribution/scripts/junie-runtime-artifact.py"
# Symlink the runtime source so pip install -e works inside the test.
ln -s "$ROOT/junie_runtime" "$HIRE_TREE/junie_runtime"

# Overwrite the dump binary with a controlled stub (only in the temp tree).
HIRE_TREE_DUMP="$HIRE_TREE/distribution/scripts/dump-junie.sh"
DUMP_STUB_LOG="$TMP/dump-stub.log"

install_dump_stub() {
  local exit_code="$1"
  cat > "$HIRE_TREE_DUMP" <<DUMPSTUB
#!/usr/bin/env bash
set -euo pipefail
echo "called: \$*" >> "$DUMP_STUB_LOG"
output=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in --output) output="\$2"; shift 2 ;; --profile) shift 2 ;; *) shift ;; esac
done
[[ -n "\$output" ]] && mkdir -p "\$(dirname "\$output")" && touch "\$output"
exit $exit_code
DUMPSTUB
  chmod +x "$HIRE_TREE_DUMP"
}

TEST_HIRE="$HIRE_TREE/scripts/hire-junie.sh"

# ════════════════════════════════════════════════════════════════
printf '=== Hire test D: profile exists + backup enabled → dump, then delete, then install ===\n'

D_BIN_DIR="$TMP/hire-d-bin"
D_HOME="$TMP/hire-d-home"
D_LOG="$TMP/hire-d-hermes.log"
mkdir -p "$D_BIN_DIR" "$D_HOME/profiles/junie-live"
make_hire_fake_hermes "$D_BIN_DIR/hermes" "$D_LOG" 1
rm -f "$DUMP_STUB_LOG"
install_dump_stub 0

D_OUT="$TMP/hire-d-out.txt"
D_EXIT=0
PATH="$D_BIN_DIR:$PATH" \
HERMES_HOME="$D_HOME" \
"$TEST_HIRE" \
  --telegram-token "tok_test" \
  --admin-telegram-id "12345" \
  --seed-dir "$HIRE_SEED_DIR" \
  --no-restart \
  --no-forward-keys \
  >"$D_OUT" 2>&1 || D_EXIT=$?

if [[ "$D_EXIT" -eq 0 ]]; then
  pass
  printf '  OK: hire with backup succeeded (rc=0)\n'
else
  fail "hire with backup failed (rc=$D_EXIT); output: $(head -5 "$D_OUT" | tr '\n' ';')"
fi

# dump-junie.sh was invoked
if [[ -s "$DUMP_STUB_LOG" ]]; then
  pass
  printf '  OK: dump-junie.sh was called\n'
else
  fail "dump-junie.sh was NOT called"
fi

# profile delete was called (in the hermes log)
if grep -q 'hermes profile delete.*-y' "$D_LOG" 2>/dev/null; then
  pass
  printf '  OK: hermes profile delete was called\n'
else
  fail "hermes profile delete was NOT called"
fi

# profile delete happened AFTER dump (dump log has content AND delete in hermes log)
# Since dump runs synchronously before Step 2, if both markers exist the order is correct.
# Additional proof: check the backup output mentions success
if grep -q 'Backup:' "$D_OUT" 2>/dev/null; then
  pass
  printf '  OK: backup output reported\n'
else
  fail "backup output not reported"
fi

# profile install was called
if grep -q 'hermes profile install' "$D_LOG" 2>/dev/null; then
  pass
  printf '  OK: profile install was called\n'
else
  fail "profile install was NOT called"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Hire test E: dump failure → abort, no delete ===\n'

E_BIN_DIR="$TMP/hire-e-bin"
E_HOME="$TMP/hire-e-home"
E_LOG="$TMP/hire-e-hermes.log"
mkdir -p "$E_BIN_DIR" "$E_HOME/profiles/junie-live"
make_hire_fake_hermes "$E_BIN_DIR/hermes" "$E_LOG" 1
rm -f "$DUMP_STUB_LOG"
install_dump_stub 1  # stub exits 1

E_OUT="$TMP/hire-e-out.txt"
E_EXIT=0
PATH="$E_BIN_DIR:$PATH" \
HERMES_HOME="$E_HOME" \
"$TEST_HIRE" \
  --telegram-token "tok_test" \
  --admin-telegram-id "12345" \
  --seed-dir "$HIRE_SEED_DIR" \
  --no-restart \
  --no-forward-keys \
  >"$E_OUT" 2>&1 || E_EXIT=$?

if [[ "$E_EXIT" -ne 0 ]]; then
  pass
  printf '  OK: hire aborted on dump failure (rc=%d)\n' "$E_EXIT"
else
  fail "hire should have failed when dump fails (rc=0)"
fi

# dump-junie.sh was invoked (stub was called)
if [[ -s "$DUMP_STUB_LOG" ]]; then
  pass
  printf '  OK: dump-junie.sh was called (before failure)\n'
else
  fail "dump-junie.sh was NOT called"
fi

# profile delete was NOT called
if grep -q 'hermes profile delete' "$E_LOG" 2>/dev/null; then
  fail "hermes profile delete was called despite dump failure"
else
  pass
  printf '  OK: hermes profile delete was NOT called after dump failure\n'
fi

# Error message mentions backup failure
if grep -qi 'Backup.*fail\|dump.*fail\|backup via dump' "$E_OUT" 2>/dev/null; then
  pass
  printf '  OK: error message reports backup failure\n'
else
  fail "no backup failure error message"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Hire test F: profile does not exist + backup enabled → no dump, no delete, install ===\n'

F_BIN_DIR="$TMP/hire-f-bin"
F_HOME="$TMP/hire-f-home"
F_LOG="$TMP/hire-f-hermes.log"
mkdir -p "$F_BIN_DIR" "$F_HOME"  # No profile dir
make_hire_fake_hermes "$F_BIN_DIR/hermes" "$F_LOG" 0
rm -f "$DUMP_STUB_LOG"
install_dump_stub 0  # stub would succeed, but shouldn't be called

F_OUT="$TMP/hire-f-out.txt"
F_EXIT=0
PATH="$F_BIN_DIR:$PATH" \
HERMES_HOME="$F_HOME" \
"$TEST_HIRE" \
  --telegram-token "tok_test" \
  --admin-telegram-id "12345" \
  --seed-dir "$HIRE_SEED_DIR" \
  --no-restart \
  --no-forward-keys \
  >"$F_OUT" 2>&1 || F_EXIT=$?

if [[ "$F_EXIT" -eq 0 ]]; then
  pass
  printf '  OK: hire without profile succeeded (rc=0)\n'
else
  fail "hire without profile failed (rc=$F_EXIT); output: $(head -5 "$F_OUT" | tr '\n' ';')"
fi

# dump-junie.sh was NOT invoked
if [[ -s "$DUMP_STUB_LOG" ]]; then
  fail "dump-junie.sh was called but profile did not exist"
else
  pass
  printf '  OK: dump-junie.sh was NOT called (no profile)\n'
fi

# profile delete was NOT called
if grep -q 'hermes profile delete' "$F_LOG" 2>/dev/null; then
  fail "hermes profile delete was called but profile did not exist"
else
  pass
  printf '  OK: hermes profile delete was NOT called\n'
fi

# profile install WAS called
if grep -q 'hermes profile install' "$F_LOG" 2>/dev/null; then
  pass
  printf '  OK: profile install was called\n'
else
  fail "profile install was NOT called"
fi

# "skipping backup" message logged
if grep -qi 'skipping backup' "$F_OUT" 2>/dev/null; then
  pass
  printf '  OK: "skipping backup" message logged\n'
else
  fail '"skipping backup" message not found'
fi

# ════════════════════════════════════════════════════════════════
printf '\n=== Results ===\n'
printf 'Passed: %d, Failed: %d\n' "$pass_count" "$fail_count"

if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi

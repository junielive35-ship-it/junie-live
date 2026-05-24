#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log() { printf '==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

log "bash syntax"
bash -n hire-junie.sh
bash -n scripts/code-mutex-status.sh
log "local markdown links"
while IFS= read -r file; do
  while IFS= read -r target; do
    [[ -z "$target" ]] && continue
    [[ "$target" =~ ^https?://|^mailto:|^# ]] && continue
    target="${target%%#*}"
    [[ -z "$target" ]] && continue
    [[ "$target" = /* ]] && continue
    path="$(dirname "$file")/$target"
    [[ -e "$path" ]] || fail "broken link in ${file#./}: $target"
  done < <(grep -oE '\[[^]]+\]\([^)]+\)' "$file" | sed -E 's/^.*\(([^)]+)\)$/\1/' || true)
done < <(find . -path './.git' -prune -o -name '*.md' -type f -print)

log "hire-junie smoke tests"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/bin" "$tmp/seed"
printf '# Init\n' > "$tmp/seed/INITIALIZATION.md"
cat > "$tmp/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${OPENCLAW_STUB_LOG:?}"
case "$*" in
  "agents list") exit 0 ;;
  "devices approve --latest") exit 0 ;;
esac
exit 0
STUB
chmod +x "$tmp/bin/openclaw"

log_file="$tmp/openclaw.log"
PATH="$tmp/bin:$PATH" HOME="$tmp/home" OPENCLAW_STUB_LOG="$log_file" \
  ./hire-junie.sh --telegram-token test-token --admin-telegram-id 12345 \
    --seed-dir "$tmp/seed" --no-restart >"$tmp/success.out"

grep -q 'Junie hiring configured.' "$tmp/success.out" || fail "success smoke did not complete"
grep -q '^agents add junie-live ' "$log_file" || fail "agents add not called"
grep -q '^channels add --channel telegram --account junie-live --token test-token$' "$log_file" || fail "channels add not called with expected account/token"
grep -q '^config patch --file ' "$log_file" || fail "config patch not called"
grep -q '^agents bind --agent junie-live --bind telegram:junie-live$' "$log_file" || fail "agents bind not called"
[[ -f "$tmp/home/.openclaw/workspace-junie-live/INITIALIZATION.md" ]] || fail "workspace was not seeded"

set +e
PATH="$tmp/bin:$PATH" HOME="$tmp/home2" OPENCLAW_STUB_LOG="$tmp/fail.log" \
  ./hire-junie.sh --telegram-token test-token --seed-dir "$tmp/seed" --no-restart >"$tmp/fail.out" 2>"$tmp/fail.err"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "missing admin id exit status was $status, expected 2"
grep -q 'missing required --admin-telegram-id' "$tmp/fail.err" || fail "missing admin id error not found"
[[ ! -e "$tmp/home2/.openclaw" ]] || fail "missing admin id path mutated HOME"
[[ ! -s "$tmp/fail.log" ]] || fail "missing admin id path called openclaw"

log "code mutex status smoke tests"
mutex="$tmp/code_mutex"
set +e
./scripts/code-mutex-status.sh --mutex-dir "$mutex" --repo "$tmp/repo" >"$tmp/mutex-free.out" 2>"$tmp/mutex-free.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "free mutex exit status was $status, expected 0"
grep -q '^FREE code mutex$' "$tmp/mutex-free.out" || fail "free mutex status not reported"

mkdir -p "$mutex"
cat > "$mutex/holder.json" <<'JSON'
{
  "holder_id": "test-holder",
  "reason": "verify fresh mutex",
  "started_at": "2999-01-01T00:00:00Z",
  "updated_at": "2999-01-01T00:05:00Z",
  "expected_next_action": "finish smoke test"
}
JSON
set +e
./scripts/code-mutex-status.sh --mutex-dir "$mutex" --repo "$tmp/repo" --stale-minutes 120 >"$tmp/mutex-held.out" 2>"$tmp/mutex-held.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "held mutex exit status was $status, expected 0"
grep -q '^HELD code mutex$' "$tmp/mutex-held.out" || fail "held mutex status not reported"
grep -q '^holder_id=test-holder$' "$tmp/mutex-held.out" || fail "holder id not reported"
grep -q '^expected_next_action=finish smoke test$' "$tmp/mutex-held.out" || fail "expected next action not reported"

cat > "$mutex/holder.json" <<'JSON'
{
  "holder_id": "old-holder",
  "reason": "verify stale mutex",
  "started_at": "2000-01-01T00:00:00Z",
  "updated_at": "2000-01-01T00:05:00Z"
}
JSON
set +e
./scripts/code-mutex-status.sh --mutex-dir "$mutex" --repo "$tmp/repo" --stale-minutes 1 >"$tmp/mutex-stale.out" 2>"$tmp/mutex-stale.err"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "stale mutex exit status was $status, expected 1"
grep -q '^STALE code mutex$' "$tmp/mutex-stale.out" || fail "stale mutex status not reported"

printf '{not json\n' > "$mutex/holder.json"
set +e
./scripts/code-mutex-status.sh --mutex-dir "$mutex" --repo "$tmp/repo" >"$tmp/mutex-broken.out" 2>"$tmp/mutex-broken.err"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "broken mutex exit status was $status, expected 2"
grep -q '^BROKEN code mutex$' "$tmp/mutex-broken.out" || fail "broken mutex status not reported"

log "all checks passed"

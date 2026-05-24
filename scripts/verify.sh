#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log() { printf '==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

log "bash syntax"
bash -n hire-junie.sh
bash -n scripts/code-mutex-status.sh
bash -n scripts/backlog.sh
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

log "backlog smoke tests"
backlog="$tmp/backlog"
BACKLOG_DIR="$backlog" ./scripts/backlog.sh add --type task --title "Test task" >"$tmp/bl-add1.out"
add1_id=$(cat "$tmp/bl-add1.out")
[[ -n "$add1_id" ]] || fail "backlog add did not output an id"
[[ -f "$backlog/items/$add1_id.json" ]] || fail "backlog item file not created"

BACKLOG_DIR="$backlog" ./scripts/backlog.sh add --type hypothesis --title "High priority" --priority 90 >"$tmp/bl-add2.out"
add2_id=$(cat "$tmp/bl-add2.out")
[[ -n "$add2_id" ]] || fail "backlog second add did not output an id"

BACKLOG_DIR="$backlog" ./scripts/backlog.sh list >"$tmp/bl-list.out"
grep -q 'task.*Test task' "$tmp/bl-list.out" || fail "backlog list missing task"
grep -q 'hypothesis.*High priority' "$tmp/bl-list.out" || fail "backlog list missing hypothesis"

BACKLOG_DIR="$backlog" ./scripts/backlog.sh next >"$tmp/bl-next.out"
grep -q "id=$add2_id" "$tmp/bl-next.out" || fail "backlog next did not pick highest priority"
grep -q "priority=90" "$tmp/bl-next.out" || fail "backlog next did not report priority"

BACKLOG_DIR="$backlog" ./scripts/backlog.sh update "$add2_id" --status done >/dev/null
s=$(grep '"status"' "$backlog/items/$add2_id.json" | sed 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
[[ "$s" == "done" ]] || fail "backlog update did not change status to done"

BACKLOG_DIR="$backlog" ./scripts/backlog.sh next >"$tmp/bl-next2.out"
grep -q "id=$add1_id" "$tmp/bl-next2.out" || fail "backlog next should pick remaining queued item"

BACKLOG_DIR="$backlog" ./scripts/backlog.sh archive >"$tmp/bl-archive.out"
grep -q "Archived 1 items" "$tmp/bl-archive.out" || fail "backlog archive should move done item"
[[ -f "$backlog/archive/$add2_id.json" ]] || fail "backlog archive did not move item file"

log "backlog acquire smoke tests"
acq_backlog="$tmp/backlog_acquire"
BACKLOG_DIR="$acq_backlog" ./scripts/backlog.sh add --type task --title "Low prio" --priority 20 >"$tmp/bl-acq-add1.out"
acq_id1=$(cat "$tmp/bl-acq-add1.out")
[[ -n "$acq_id1" ]] || fail "acquire add1 did not output an id"
BACKLOG_DIR="$acq_backlog" ./scripts/backlog.sh add --type hypothesis --title "High prio" --priority 95 >"$tmp/bl-acq-add2.out"
acq_id2=$(cat "$tmp/bl-acq-add2.out")
[[ -n "$acq_id2" ]] || fail "acquire add2 did not output an id"

BACKLOG_DIR="$acq_backlog" ./scripts/backlog.sh acquire >"$tmp/bl-acq.out"
[[ -f "$acq_backlog/items/$acq_id2.json" ]] || fail "acquire target item missing"
s=$(grep '"status"' "$acq_backlog/items/$acq_id2.json" | sed 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
[[ "$s" == "in_progress" ]] || fail "acquire did not set status to in_progress, got $s"
grep -q "id=$acq_id2" "$tmp/bl-acq.out" || fail "acquire output missing target id"
grep -q "status=in_progress" "$tmp/bl-acq.out" || fail "acquire output missing in_progress status"

BACKLOG_DIR="$acq_backlog" ./scripts/backlog.sh acquire >"$tmp/bl-acq2.out"
s=$(grep '"status"' "$acq_backlog/items/$acq_id1.json" | sed 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
[[ "$s" == "in_progress" ]] || fail "second acquire did not set remaining item to in_progress, got $s"
grep -q "id=$acq_id1" "$tmp/bl-acq2.out" || fail "second acquire output missing id"

BACKLOG_DIR="$acq_backlog" ./scripts/backlog.sh acquire >"$tmp/bl-acq3.out"
[[ ! -s "$tmp/bl-acq3.out" ]] || fail "third acquire should produce no output when all items claimed"

log "all checks passed"

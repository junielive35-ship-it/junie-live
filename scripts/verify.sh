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
bash -n scripts/routine-health.sh
bash -n scripts/backlog-hygiene.sh
bash -n scripts/pr-status.sh
bash -n scripts/report.sh
bash -n scripts/next-action.sh
bash -n scripts/task-acquire.sh
bash -n scripts/task-release.sh
bash -n scripts/mutex-release-stale.sh
bash -n scripts/mutex-touch.sh
bash -n scripts/drive.sh
bash -n scripts/hypothesis-generate.sh
bash -n scripts/pr-follow-up.sh
bash -n scripts/reflect.sh
bash -n scripts/memory-size-check.sh
bash -n scripts/backlog-rescore.sh
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
cleanup() {
  rm -rf "$tmp"
  rm -rf "$ROOT/state"
}
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

log "routine health smoke tests"
health_tmp="$tmp/routine_health"
rh_backlog="$health_tmp/backlog"
rh_mutex="$health_tmp/mutex"
rh_mutex_empty="$health_tmp/mutex_empty"
mkdir -p "$rh_backlog/items"

# Empty backlog + free (nonexistent) mutex -> OK
set +e
BACKLOG_DIR="$rh_backlog" MUTEX_DIR="$rh_mutex_empty" ./scripts/routine-health.sh >"$tmp/rh-ok.out" 2>"$tmp/rh-ok.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "empty health exit status was $status, expected 0"
grep -q '^status=OK$' "$tmp/rh-ok.out" || fail "empty health status not OK"
grep -q '^mutex_status=FREE$' "$tmp/rh-ok.out" || fail "empty health mutex not FREE"
grep -q '^details=All nominal$' "$tmp/rh-ok.out" || fail "empty health details not nominal"

# Held mutex + items -> OK
mkdir -p "$rh_mutex"
for i in 1 2; do
  BACKLOG_DIR="$rh_backlog" ./scripts/backlog.sh add --type task --title "Task $i" --priority $((i * 10)) >/dev/null
done
cat > "$rh_mutex/holder.json" <<'JSON'
{
  "holder_id": "active-worker",
  "reason": "routine health worker smoke test",
  "started_at": "2999-01-01T00:00:00Z",
  "updated_at": "2999-01-01T00:02:00Z",
  "expected_next_action": "finish smoke test"
}
JSON
set +e
BACKLOG_DIR="$rh_backlog" MUTEX_DIR="$rh_mutex" ./scripts/routine-health.sh >"$tmp/rh-held.out" 2>"$tmp/rh-held.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "held health exit status was $status, expected 0"
grep -q '^status=OK$' "$tmp/rh-held.out" || fail "held health status not OK"
grep -q '^mutex_status=HELD$' "$tmp/rh-held.out" || fail "held health mutex not HELD"
grep -q 'backlog_queued=2' "$tmp/rh-held.out" || fail "held health backlog queue count wrong"
grep -q 'backlog_next=' "$tmp/rh-held.out" || fail "held health backlog next missing"

# Stale in_progress item -> WARNING
BACKLOG_DIR="$rh_backlog" ./scripts/backlog.sh acquire >"$tmp/rh-acq2.out"
acq_id=$(grep '^id=' "$tmp/rh-acq2.out" | sed 's/^id=//')
ts_old="2000-01-01T00:00:00Z"
sed -i 's/"updated_at"[[:space:]]*:[[:space:]]*"[^"]*"/"updated_at": "'"$ts_old"'"/' "$rh_backlog/items/$acq_id.json"
sed -i 's/"created_at"[[:space:]]*:[[:space:]]*"[^"]*"/"created_at": "'"$ts_old"'"/' "$rh_backlog/items/$acq_id.json"
rm -f "$rh_mutex/holder.json"
rmdir "$rh_mutex"
set +e
BACKLOG_DIR="$rh_backlog" MUTEX_DIR="$rh_mutex" ./scripts/routine-health.sh --stale-minutes 1 >"$tmp/rh-stale-ip.out" 2>"$tmp/rh-stale-ip.err"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "stale in_progress exit status was $status, expected 1"
grep -q '^status=WARNING$' "$tmp/rh-stale-ip.out" || fail "stale in_progress status not WARNING"
grep -q 'backlog_stale_in_progress=1' "$tmp/rh-stale-ip.out" || fail "stale in_progress count wrong"
grep -q 'stale in-progress' "$tmp/rh-stale-ip.out" || fail "stale in_progress not in details"

# Stale mutex -> CRITICAL
mkdir -p "$rh_mutex"
cat > "$rh_mutex/holder.json" <<'JSON'
{
  "holder_id": "dead-worker",
  "reason": "verify stale mutex detection",
  "started_at": "2000-01-01T00:00:00Z",
  "updated_at": "2000-01-01T00:05:00Z"
}
JSON
set +e
BACKLOG_DIR="$rh_backlog" MUTEX_DIR="$rh_mutex" ./scripts/routine-health.sh --stale-minutes 1 >"$tmp/rh-stale-mutex.out" 2>"$tmp/rh-stale-mutex.err"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "stale mutex exit status was $status, expected 2"
grep -q '^status=CRITICAL$' "$tmp/rh-stale-mutex.out" || fail "stale mutex status not CRITICAL"
grep -q '^mutex_status=STALE$' "$tmp/rh-stale-mutex.out" || fail "stale mutex not reported as STALE"
grep -q 'Mutex STALE' "$tmp/rh-stale-mutex.out" || fail "stale mutex not in details"

# Broken mutex -> CRITICAL
printf 'not json\n' > "$rh_mutex/holder.json"
set +e
BACKLOG_DIR="$rh_backlog" MUTEX_DIR="$rh_mutex" ./scripts/routine-health.sh >"$tmp/rh-broken.out" 2>"$tmp/rh-broken.err"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "broken mutex exit status was $status, expected 2"
grep -q '^status=CRITICAL$' "$tmp/rh-broken.out" || fail "broken mutex status not CRITICAL"
grep -q 'Mutex BROKEN' "$tmp/rh-broken.out" || fail "broken mutex not in details"

log "backlog hygiene smoke tests"
hygiene_tmp="$tmp/backlog_hygiene"
hygiene_backlog="$hygiene_tmp/backlog"
mkdir -p "$hygiene_backlog/items" "$hygiene_backlog/archive"
ts_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ts_old="2000-01-01T00:00:00Z"
ts_yesterday="$(date -u -d '30 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '2000-01-01T00:00:00Z')"

# Empty backlog -> OK
set +e
BACKLOG_DIR="$hygiene_backlog" ./scripts/backlog-hygiene.sh >"$tmp/hygiene-empty.out" 2>"$tmp/hygiene-empty.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "empty hygiene exit status was $status, expected 0"
grep -q '^archived=0$' "$tmp/hygiene-empty.out" || fail "empty hygiene archived count wrong"
grep -q '^reset_in_progress=0$' "$tmp/hygiene-empty.out" || fail "empty hygiene reset count wrong"
grep -q '^stale_queued=0$' "$tmp/hygiene-empty.out" || fail "empty hygiene stale count wrong"

# Add fresh items that should NOT be archived
BACKLOG_DIR="$hygiene_backlog" ./scripts/backlog.sh add --type task --title "Fresh done" >/dev/null
fresh_done_id=$(BACKLOG_DIR="$hygiene_backlog" ./scripts/backlog.sh next | grep '^id=' | sed 's/^id=//')
[[ -n "$fresh_done_id" ]] || fail "hygiene fresh done add failed"
BACKLOG_DIR="$hygiene_backlog" ./scripts/backlog.sh update "$fresh_done_id" --status done >/dev/null

BACKLOG_DIR="$hygiene_backlog" ./scripts/backlog.sh add --type task --title "Fresh queued" >/dev/null
# All items are fresh so archive should do nothing
set +e
BACKLOG_DIR="$hygiene_backlog" ./scripts/backlog-hygiene.sh --archive-days 1 >"$tmp/hygiene-fresh.out" 2>"$tmp/hygiene-fresh.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "fresh hygiene exit status was $status, expected 0"
grep -q '^archived=0$' "$tmp/hygiene-fresh.out" || fail "fresh hygiene should not archive"
grep -q '^reset_in_progress=0$' "$tmp/hygiene-fresh.out" || fail "fresh hygiene should not reset"

# Add old done item that should be archived
BACKLOG_DIR="$hygiene_backlog" ./scripts/backlog.sh add --type task --title "Old done" >/dev/null
old_done_id=$(BACKLOG_DIR="$hygiene_backlog" ./scripts/backlog.sh next | grep '^id=' | sed 's/^id=//')
BACKLOG_DIR="$hygiene_backlog" ./scripts/backlog.sh update "$old_done_id" --status done >/dev/null
sed -i 's/"created_at"[[:space:]]*:[[:space:]]*"[^"]*"/"created_at": "'"$ts_old"'"/' "$hygiene_backlog/items/$old_done_id.json"

set +e
BACKLOG_DIR="$hygiene_backlog" ./scripts/backlog-hygiene.sh --archive-days 1 >"$tmp/hygiene-old-done.out" 2>"$tmp/hygiene-old-done.err"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "old done archive exit status was $status, expected 2"
grep -q '^archived=1$' "$tmp/hygiene-old-done.out" || fail "old done should be archived"
[[ ! -f "$hygiene_backlog/items/$old_done_id.json" ]] || fail "old done item should have moved to archive"
[[ -f "$hygiene_backlog/archive/$old_done_id.json" ]] || fail "old done item should be in archive dir"

# Add stale in_progress item that should be reset to queued
BACKLOG_DIR="$hygiene_backlog" ./scripts/backlog.sh add --type task --title "Stale in progress" --priority 80 >/dev/null
stale_ip_id=$(BACKLOG_DIR="$hygiene_backlog" ./scripts/backlog.sh next | grep '^id=' | sed 's/^id=//')
BACKLOG_DIR="$hygiene_backlog" ./scripts/backlog.sh acquire >/dev/null
sed -i 's/"updated_at"[[:space:]]*:[[:space:]]*"[^"]*"/"updated_at": "'"$ts_old"'"/' "$hygiene_backlog/items/$stale_ip_id.json"
sed -i 's/"created_at"[[:space:]]*:[[:space:]]*"[^"]*"/"created_at": "'"$ts_old"'"/' "$hygiene_backlog/items/$stale_ip_id.json"

set +e
BACKLOG_DIR="$hygiene_backlog" ./scripts/backlog-hygiene.sh --stale-minutes 1 >"$tmp/hygiene-stale-ip.out" 2>"$tmp/hygiene-stale-ip.err"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "stale ip reset exit status was $status, expected 2"
grep -q '^reset_in_progress=1$' "$tmp/hygiene-stale-ip.out" || fail "stale ip should be reset"
s=$(grep '"status"' "$hygiene_backlog/items/$stale_ip_id.json" | sed 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
[[ "$s" == "queued" ]] || fail "stale ip should be reset to queued, got $s"

# Check dry-run: add another old done, verify no actual archive
BACKLOG_DIR="$hygiene_backlog" ./scripts/backlog.sh add --type task --title "Dry run done" >/dev/null
dry_id=$(BACKLOG_DIR="$hygiene_backlog" ./scripts/backlog.sh next | grep '^id=' | sed 's/^id=//')
BACKLOG_DIR="$hygiene_backlog" ./scripts/backlog.sh update "$dry_id" --status done >/dev/null
sed -i 's/"created_at"[[:space:]]*:[[:space:]]*"[^"]*"/"created_at": "'"$ts_old"'"/' "$hygiene_backlog/items/$dry_id.json"

# Count items before dry-run
items_before=$(ls "$hygiene_backlog/items/"*.json 2>/dev/null | wc -l)
archives_before=$(ls "$hygiene_backlog/archive/"*.json 2>/dev/null | wc -l)

set +e
BACKLOG_DIR="$hygiene_backlog" ./scripts/backlog-hygiene.sh --archive-days 1 --dry-run >"$tmp/hygiene-dry.out" 2>"$tmp/hygiene-dry.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "dry-run hygiene exit status was $status, expected 0"
grep -q 'WOULD_ARCHIVE' "$tmp/hygiene-dry.out" || fail "dry-run should show would-archive"

items_after=$(ls "$hygiene_backlog/items/"*.json 2>/dev/null | wc -l)
archives_after=$(ls "$hygiene_backlog/archive/"*.json 2>/dev/null | wc -l)
[[ "$items_before" -eq "$items_after" ]] || fail "dry-run should not move items ($items_before vs $items_after)"
[[ "$archives_before" -eq "$archives_after" ]] || fail "dry-run should not add archives ($archives_before vs $archives_after)"

# Stale queued items should trigger warning exit
BACKLOG_DIR="$hygiene_backlog" ./scripts/backlog.sh add --type hypothesis --title "Stale queued hypothesis" --priority 10 >/dev/null
stale_q_id=$(BACKLOG_DIR="$hygiene_backlog" ./scripts/backlog.sh list --status queued 2>/dev/null | tail -1 | cut -f1)
[[ -f "$hygiene_backlog/items/$stale_q_id.json" ]] || fail "stale queued item missing"
sed -i 's/"created_at"[[:space:]]*:[[:space:]]*"[^"]*"/"created_at": "'"$ts_yesterday"'"/' "$hygiene_backlog/items/$stale_q_id.json"

set +e
BACKLOG_DIR="$hygiene_backlog" ./scripts/backlog-hygiene.sh --stale-queued-days 1 >"$tmp/hygiene-stale-q.out" 2>"$tmp/hygiene-stale-q.err"
status=$?
set -e
grep -q '^stale_queued=1$' "$tmp/hygiene-stale-q.out" || fail "stale queued count should be 1"

log "backlog-rescore smoke tests"
rescore_tmp="$tmp/rescore"
rescore_bl="$rescore_tmp/backlog"
mkdir -p "$rescore_bl/items"

BACKLOG_DIR="$rescore_bl" ./scripts/backlog.sh add --type task --title "Recent" --priority 50 >/dev/null
recent_id=$(BACKLOG_DIR="$rescore_bl" ./scripts/backlog.sh next | grep '^id=' | sed 's/^id=//')

BACKLOG_DIR="$rescore_bl" ./scripts/backlog.sh add --type hypothesis --title "Old" --priority 40 >/dev/null
old_id=$(BACKLOG_DIR="$rescore_bl" ./scripts/backlog.sh list 2>/dev/null | tail -1 | cut -f1)
sed -i 's/"created_at"[[:space:]]*:[[:space:]]*"[^"]*"/"created_at": "2000-01-01T00:00:00Z"/' "$rescore_bl/items/$old_id.json"

# Dry-run: should show would-rescore for old item, not recent
set +e
BACKLOG_DIR="$rescore_bl" ./scripts/backlog-rescore.sh --dry-run --max-boost 10 >"$tmp/rescore-dry.out" 2>"$tmp/rescore-dry.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "rescore dry-run exit status was $status, expected 0"
grep -q "WOULD_RESCORE.*$old_id" "$tmp/rescore-dry.out" || fail "rescore dry-run should propose boosting old item"
grep -q "WOULD_RESCORE.*$recent_id" "$tmp/rescore-dry.out" && fail "rescore dry-run should NOT propose boosting recent item"
grep -q '^rescored=1$' "$tmp/rescore-dry.out" || fail "rescore dry-run should report rescored=1"

# Live run: boosts old item, not recent
set +e
BACKLOG_DIR="$rescore_bl" ./scripts/backlog-rescore.sh --max-boost 10 >"$tmp/rescore-live.out" 2>"$tmp/rescore-live.err"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "rescore live exit status was $status, expected 1"
old_prio=$(grep '"priority"' "$rescore_bl/items/$old_id.json" | sed 's/.*"priority"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/')
[[ "$old_prio" -gt 40 ]] || fail "old item priority should have been boosted, got $old_prio"
recent_prio=$(grep '"priority"' "$rescore_bl/items/$recent_id.json" | sed 's/.*"priority"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/')
[[ "$recent_prio" -eq 50 ]] || fail "recent item priority should remain 50, got $recent_prio"

# Second run with no changes: no rescore needed
set +e
BACKLOG_DIR="$rescore_bl" ./scripts/backlog-rescore.sh --max-boost 10 >"$tmp/rescore-idle.out" 2>"$tmp/rescore-idle.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "rescore idle exit status was $status, expected 0"
grep -q '^rescored=0$' "$tmp/rescore-idle.out" || fail "rescore idle should report rescored=0"

log "task acquire/release smoke tests"
ta_tmp="$tmp/task_acquire"
ta_backlog="$ta_tmp/backlog"
ta_mutex="$ta_tmp/mutex"
ta_mutex_held="$ta_tmp/mutex_held"
mkdir -p "$ta_backlog/items"

# Empty backlog + free mutex -> backlog=empty, mutex released
BACKLOG_DIR="$ta_backlog" MUTEX_DIR="$ta_mutex" ./scripts/task-acquire.sh >"$tmp/ta-empty.out" 2>"$tmp/ta-empty.err"
grep -q '^backlog=empty$' "$tmp/ta-empty.out" || fail "task-acquire empty backlog should output backlog=empty"
[[ ! -d "$ta_mutex" ]] || fail "task-acquire empty backlog should release mutex"

# Held mutex -> mutex=HELD, exit 2
mkdir -p "$ta_mutex_held"
cat > "$ta_mutex_held/holder.json" <<'JSON'
{"holder_id":"test","task_id":"test","reason":"holder test"}
JSON
set +e
BACKLOG_DIR="$ta_backlog" MUTEX_DIR="$ta_mutex_held" ./scripts/task-acquire.sh >"$tmp/ta-held.out" 2>"$tmp/ta-held.err"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "task-acquire held mutex exit status was $status, expected 2"
grep -q '^mutex=HELD$' "$tmp/ta-held.out" || fail "task-acquire held mutex output wrong"

# Free mutex + queued item -> acquires, creates mutex dir and holder.json
BACKLOG_DIR="$ta_backlog" ./scripts/backlog.sh add --type task --title "Task acquire test" --priority 70 >/dev/null
BACKLOG_DIR="$ta_backlog" MUTEX_DIR="$ta_mutex" ./scripts/task-acquire.sh >"$tmp/ta-acquired.out" 2>"$tmp/ta-acquired.err"
grep -q '^status=in_progress$' "$tmp/ta-acquired.out" || fail "task-acquire should set status in_progress"
grep -q '^mutex=ACQUIRED$' "$tmp/ta-acquired.out" || fail "task-acquire should report mutex ACQUIRED"
task_id=$(grep '^id=' "$tmp/ta-acquired.out" | sed 's/^id=//')
[[ -n "$task_id" ]] || fail "task-acquire should output item id"
[[ -d "$ta_mutex" ]] || fail "task-acquire should create mutex dir"
[[ -f "$ta_mutex/holder.json" ]] || fail "task-acquire should write holder.json"
s=$(grep '"status"' "$ta_backlog/items/$task_id.json" | sed 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
[[ "$s" == "in_progress" ]] || fail "task-acquire status should be in_progress, got $s"

# task-release with default status (done)
BACKLOG_DIR="$ta_backlog" MUTEX_DIR="$ta_mutex" REFLECTIONS_DIR="$ta_tmp/reflections" ./scripts/task-release.sh >"$tmp/ta-release.out" 2>"$tmp/ta-release.err"
grep -q '^released=true$' "$tmp/ta-release.out" || fail "task-release should report released=true"
grep -q "^task_id=$task_id$" "$tmp/ta-release.out" || fail "task-release should report correct task_id"
grep -q '^new_status=done$' "$tmp/ta-release.out" || fail "task-release should report new_status=done"
[[ ! -d "$ta_mutex" ]] || fail "task-release should remove mutex dir"
s=$(grep '"status"' "$ta_backlog/items/$task_id.json" | sed 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
[[ "$s" == "done" ]] || fail "task-release status should be done, got $s"

# task-release with already free mutex -> released=false
BACKLOG_DIR="$ta_backlog" MUTEX_DIR="$ta_mutex" ./scripts/task-release.sh >"$tmp/ta-free-release.out" 2>"$tmp/ta-free-release.err"
grep -q '^released=false$' "$tmp/ta-free-release.out" || fail "task-release free mutex should report released=false"
grep -q 'mutex already free' "$tmp/ta-free-release.out" || fail "task-release free mutex should explain"

log "reflection smoke tests"
refl_tmp="$tmp/reflection"
refl_backlog="$refl_tmp/backlog"
refl_dir="$refl_tmp/state/reflections"
mkdir -p "$refl_backlog/items"

# reflect.sh with no args does nothing (no error)
set +e
BACKLOG_DIR="$refl_backlog" ./scripts/reflect.sh >"$tmp/refl-noop.out" 2>"$tmp/refl-noop.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "reflect noop exit status was $status, expected 0"

# reflect.sh with valid task -> creates reflection
BACKLOG_DIR="$refl_backlog" ./scripts/backlog.sh add --type task --title "Reflect task" --priority 50 >/dev/null
refl_id=$(BACKLOG_DIR="$refl_backlog" ./scripts/backlog.sh next | grep '^id=' | sed 's/^id=//')
[[ -n "$refl_id" ]] || fail "reflect add failed"
BACKLOG_DIR="$refl_backlog" REFLECTIONS_DIR="$refl_dir" ./scripts/reflect.sh "$refl_id" done >"$tmp/refl-created.out" 2>"$tmp/refl-created.err"
[[ -f "$refl_dir/${refl_id}.json" ]] || fail "reflect should create reflection file"
t=$(grep -o '"task_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$refl_dir/${refl_id}.json" | sed 's/.*"task_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
[[ "$t" == "$refl_id" ]] || fail "reflection file wrong task_id, got $t"
t=$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$refl_dir/${refl_id}.json" | sed 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
[[ "$t" == "done" ]] || fail "reflection status should be done, got $t"

# reflect.sh with nonexistent task -> silent no-op
set +e
BACKLOG_DIR="$refl_backlog" ./scripts/reflect.sh "nonexistent-task" >"$tmp/refl-nonexist.out" 2>"$tmp/refl-nonexist.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "reflect nonexistent exit status was $status, expected 0"

# reflect.sh with --notes -> stores in reflection JSON
BACKLOG_DIR="$refl_backlog" ./scripts/backlog.sh add --type hypothesis --title "Reflect notes" --priority 40 >/dev/null
refl_notes_id=$(BACKLOG_DIR="$refl_backlog" ./scripts/backlog.sh next | grep '^id=' | sed 's/^id=//')
[[ -n "$refl_notes_id" ]] || fail "reflect notes add failed"
BACKLOG_DIR="$refl_backlog" REFLECTIONS_DIR="$refl_dir" ./scripts/reflect.sh "$refl_notes_id" done \
  --notes "Outcome: verified fix works. What worked: clear reproduction steps." >/dev/null
[[ -f "$refl_dir/${refl_notes_id}.json" ]] || fail "reflect notes should create reflection file"
grep -q '"notes"' "$refl_dir/${refl_notes_id}.json" || fail "reflect notes should store notes field"
grep -q 'Outcome: verified fix works' "$refl_dir/${refl_notes_id}.json" || fail "reflect notes should store notes content"

# reflect.sh without --notes should not have notes field
BACKLOG_DIR="$refl_backlog" ./scripts/backlog.sh add --type task --title "Reflect no notes" --priority 30 >/dev/null
refl_no_notes_id=$(BACKLOG_DIR="$refl_backlog" ./scripts/backlog.sh next | grep '^id=' | sed 's/^id=//')
[[ -n "$refl_no_notes_id" ]] || fail "reflect no-notes add failed"
BACKLOG_DIR="$refl_backlog" REFLECTIONS_DIR="$refl_dir" ./scripts/reflect.sh "$refl_no_notes_id" done >/dev/null
grep -q '"notes"' "$refl_dir/${refl_no_notes_id}.json" && fail "reflect no-notes should not have notes field" || true

# reflect.sh with notes containing JSON-special characters
BACKLOG_DIR="$refl_backlog" ./scripts/backlog.sh add --type task --title "Reflect special chars" --priority 20 >/dev/null
refl_special_id=$(BACKLOG_DIR="$refl_backlog" ./scripts/backlog.sh next | grep '^id=' | sed 's/^id=//')
[[ -n "$refl_special_id" ]] || fail "reflect special add failed"
BACKLOG_DIR="$refl_backlog" REFLECTIONS_DIR="$refl_dir" ./scripts/reflect.sh "$refl_special_id" blocked \
  --notes 'Contains "quotes" and \backslashes\ and newlines' >/dev/null
grep -q 'Contains.*quotes.*backslashes' "$refl_dir/${refl_special_id}.json" || fail "reflect notes should escape special chars"
s=$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$refl_dir/${refl_special_id}.json" | sed 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
[[ "$s" == "blocked" ]] || fail "reflect special status should be blocked, got $s"

# task-release integration with reflection
refl_ta_tmp="$tmp/refl_task_acquire"
refl_ta_backlog="$refl_ta_tmp/backlog"
refl_ta_mutex="$refl_ta_tmp/mutex"
mkdir -p "$refl_ta_backlog/items"

BACKLOG_DIR="$refl_ta_backlog" ./scripts/backlog.sh add --type task --title "Release reflect" --priority 60 >/dev/null
BACKLOG_DIR="$refl_ta_backlog" MUTEX_DIR="$refl_ta_mutex" ./scripts/task-acquire.sh >"$tmp/refl-ta-out" 2>/dev/null
refl_ta_id=$(grep '^id=' "$tmp/refl-ta-out" | sed 's/^id=//')
[[ -n "$refl_ta_id" ]] || fail "release-reflect acquire failed"
[[ -d "$refl_ta_mutex" ]] || fail "release-reflect mutex not created"
[[ -f "$refl_ta_mutex/holder.json" ]] || fail "release-reflect holder.json missing"

refl_dir2="$refl_ta_tmp/state/reflections"
BACKLOG_DIR="$refl_ta_backlog" MUTEX_DIR="$refl_ta_mutex" REFLECTIONS_DIR="$refl_dir2" ./scripts/task-release.sh >"$tmp/refl-tr-out" 2>"$tmp/refl-tr.err"
grep -q '^released=true$' "$tmp/refl-tr-out" || fail "release-reflect should report released=true"
[[ ! -d "$refl_ta_mutex" ]] || fail "release-reflect should remove mutex dir"
[[ -f "$refl_dir2/${refl_ta_id}.json" ]] || fail "release-reflect should create reflection file"
t=$(grep -o '"task_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$refl_dir2/${refl_ta_id}.json" | sed 's/.*"task_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
[[ "$t" == "$refl_ta_id" ]] || fail "release-reflect reflection wrong task_id"

# next-action release_completed_task detection
relcomp_tmp="$tmp/release_completed"
relcomp_backlog="$relcomp_tmp/backlog"
relcomp_mutex="$relcomp_tmp/mutex"
relcomp_repo="$relcomp_tmp/repo"
mkdir -p "$relcomp_backlog/items" "$relcomp_repo"

BACKLOG_DIR="$relcomp_backlog" ./scripts/backlog.sh add --type task --title "Completed but held" --priority 70 >/dev/null
relcomp_id=$(BACKLOG_DIR="$relcomp_backlog" ./scripts/backlog.sh next | grep '^id=' | sed 's/^id=//')
[[ -n "$relcomp_id" ]] || fail "relcomp add failed"

ts_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$relcomp_mutex"
cat > "$relcomp_mutex/holder.json" <<JSON
{
  "holder_id": "task-acquire:${relcomp_id}",
  "task_id": "${relcomp_id}",
  "reason": "release_completed_task smoke test",
  "started_at": "${ts_now}",
  "updated_at": "${ts_now}"
}
JSON
# Manually set task to done (simulating external completion)
sed -i 's/"status"[[:space:]]*:[[:space:]]*"[^"]*"/"status": "done"/' "$relcomp_backlog/items/$relcomp_id.json"

set +e
BACKLOG_DIR="$relcomp_backlog" MUTEX_DIR="$relcomp_mutex" REPO="$relcomp_repo" \
  ./scripts/next-action.sh >"$tmp/relcomp-na.out" 2>"$tmp/relcomp-na.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "relcomp next-action exit status was $status, expected 0"
grep -q '^action=release_completed_task$' "$tmp/relcomp-na.out" || fail "relcomp should detect completed task"
grep -q 'is done' "$tmp/relcomp-na.out" || fail "relcomp reason should mention done"

# release_completed_task via drive.sh, then loop continues to generate_hypotheses
# and then acquires the generated hypothesis
relcomp_drive_tmp="$tmp/relcomp_drive"
relcomp_drive_bl="$relcomp_drive_tmp/backlog"
relcomp_drive_mutex="$relcomp_drive_tmp/mutex"
relcomp_drive_hyp="$relcomp_drive_tmp/hyp_state"
mkdir -p "$relcomp_drive_bl/items" "$relcomp_drive_mutex"

BACKLOG_DIR="$relcomp_drive_bl" ./scripts/backlog.sh add --type task --title "Drive relcomp" --priority 80 >/dev/null
relcomp_drive_id=$(BACKLOG_DIR="$relcomp_drive_bl" ./scripts/backlog.sh next | grep '^id=' | sed 's/^id=//')
[[ -n "$relcomp_drive_id" ]] || fail "drive relcomp add failed"

ts_now2="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$relcomp_drive_mutex/holder.json" <<JSON
{
  "holder_id": "task-acquire:${relcomp_drive_id}",
  "task_id": "${relcomp_drive_id}",
  "reason": "drive release_completed_task test",
  "started_at": "${ts_now2}",
  "updated_at": "${ts_now2}"
}
JSON
sed -i 's/"status"[[:space:]]*:[[:space:]]*"[^"]*"/"status": "cancelled"/' "$relcomp_drive_bl/items/$relcomp_drive_id.json"

set +e
BACKLOG_DIR="$relcomp_drive_bl" MUTEX_DIR="$relcomp_drive_mutex" HYPOTHESIS_STATE_DIR="$relcomp_drive_hyp" \
  ./scripts/drive.sh >"$tmp/relcomp-drive.out" 2>"$tmp/relcomp-drive.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "drive relcomp exit status was $status, expected 0"
grep -q '^action=start_backlog_item$' "$tmp/relcomp-drive.out" || fail "drive should loop to start_backlog_item after release + hypotheses"
grep -q '^summary=.*released completed task' "$tmp/relcomp-drive.out" || fail "drive relcomp summary missing release"
grep -q 'generated hypothesis' "$tmp/relcomp-drive.out" || fail "drive relcomp summary missing hypothesis generation"
# Mutex was re-acquired for the generated hypothesis
[[ -d "$relcomp_drive_mutex" ]] || fail "drive should acquire mutex for the new hypothesis"
[[ -f "$relcomp_drive_mutex/holder.json" ]] || fail "drive hyp holder.json missing"
s=$(grep '"status"' "$relcomp_drive_bl/items/$relcomp_drive_id.json" | sed 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
[[ "$s" == "cancelled" ]] || fail "drive should preserve terminal status ($s)"

log "mutex release stale smoke tests"
mrs_tmp="$tmp/mutex_release_stale"
mrs_mutex="$mrs_tmp/mutex"
mrs_backlog="$mrs_tmp/backlog"
mkdir -p "$mrs_backlog/items" "$mrs_backlog/archive"

# Free mutex -> FREE, exit 0
set +e
MUTEX_DIR="$mrs_mutex/nonexistent" BACKLOG_DIR="$mrs_backlog" ./scripts/mutex-release-stale.sh >"$tmp/mrs-free.out" 2>"$tmp/mrs-free.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "free mutex exit status was $status, expected 0"
grep -q '^status=FREE$' "$tmp/mrs-free.out" || fail "free mutex status not FREE"
grep -q '^action=none$' "$tmp/mrs-free.out" || fail "free mutex action not none"

# Broken mutex (no holder.json) -> BROKEN, exit 0
mkdir -p "$mrs_mutex/noholder"
set +e
MUTEX_DIR="$mrs_mutex/noholder" BACKLOG_DIR="$mrs_backlog" ./scripts/mutex-release-stale.sh >"$tmp/mrs-broken.out" 2>"$tmp/mrs-broken.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "broken mutex exit status was $status, expected 0"
grep -q '^status=BROKEN$' "$tmp/mrs-broken.out" || fail "broken mutex status not BROKEN"
grep -q '^action=removed$' "$tmp/mrs-broken.out" || fail "broken mutex action not removed"
[[ ! -d "$mrs_mutex/noholder" ]] || fail "broken mutex dir should be removed"

# Broken mutex dry run -> WOULD_REMOVE
mkdir -p "$mrs_mutex/drybroken"
set +e
MUTEX_DIR="$mrs_mutex/drybroken" BACKLOG_DIR="$mrs_backlog" ./scripts/mutex-release-stale.sh --dry-run >"$tmp/mrs-drybroken.out" 2>"$tmp/mrs-drybroken.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "broken mutex dry-run exit status was $status, expected 0"
grep -q '^action=WOULD_REMOVE$' "$tmp/mrs-drybroken.out" || fail "broken mutex dry-run action not WOULD_REMOVE"
[[ -d "$mrs_mutex/drybroken" ]] || fail "broken mutex dry-run should not remove dir"

# Broken mutex (no holder_id in json) -> BROKEN, exit 0
mkdir -p "$mrs_mutex/noid"
printf '{"invalid": true}\n' > "$mrs_mutex/noid/holder.json"
set +e
MUTEX_DIR="$mrs_mutex/noid" BACKLOG_DIR="$mrs_backlog" ./scripts/mutex-release-stale.sh >"$tmp/mrs-noid.out" 2>"$tmp/mrs-noid.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "no-id mutex exit status was $status, expected 0"
grep -q '^status=BROKEN$' "$tmp/mrs-noid.out" || fail "no-id mutex status not BROKEN"
grep -q '^action=removed$' "$tmp/mrs-noid.out" || fail "no-id mutex action not removed"
[[ ! -d "$mrs_mutex/noid" ]] || fail "no-id mutex dir should be removed"

# Held mutex (not stale) -> HELD, exit 1
mkdir -p "$mrs_mutex/held"
cat > "$mrs_mutex/held/holder.json" <<'JSON'
{
  "holder_id": "active-worker",
  "reason": "held mutex test",
  "started_at": "2999-01-01T00:00:00Z",
  "updated_at": "2999-01-01T00:02:00Z"
}
JSON
set +e
MUTEX_DIR="$mrs_mutex/held" BACKLOG_DIR="$mrs_backlog" ./scripts/mutex-release-stale.sh --stale-minutes 120 >"$tmp/mrs-held.out" 2>"$tmp/mrs-held.err"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "held mutex exit status was $status, expected 1"
grep -q '^status=HELD$' "$tmp/mrs-held.out" || fail "held mutex status not HELD"
grep -q '^action=none$' "$tmp/mrs-held.out" || fail "held mutex action not none"
grep -q '^holder_id=active-worker$' "$tmp/mrs-held.out" || fail "held mutex holder_id not reported"
[[ -d "$mrs_mutex/held" ]] || fail "held mutex dir should not be removed"

# Stale mutex (no associated backlog item) -> STALE, action=released
mkdir -p "$mrs_mutex/stale"
cat > "$mrs_mutex/stale/holder.json" <<'JSON'
{
  "holder_id": "dead-worker",
  "reason": "stale mutex test",
  "started_at": "2000-01-01T00:00:00Z",
  "updated_at": "2000-01-01T00:05:00Z"
}
JSON
set +e
MUTEX_DIR="$mrs_mutex/stale" BACKLOG_DIR="$mrs_backlog" ./scripts/mutex-release-stale.sh --stale-minutes 1 >"$tmp/mrs-stale.out" 2>"$tmp/mrs-stale.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "stale mutex exit status was $status, expected 0"
grep -q '^status=STALE$' "$tmp/mrs-stale.out" || fail "stale mutex status not STALE"
grep -q '^action=released$' "$tmp/mrs-stale.out" || fail "stale mutex action not released"
grep -q '^holder_id=dead-worker$' "$tmp/mrs-stale.out" || fail "stale mutex holder_id not reported"
[[ ! -d "$mrs_mutex/stale" ]] || fail "stale mutex dir should be removed"

# Stale mutex with associated backlog in_progress item -> resets to queued
mkdir -p "$mrs_mutex/withitem"
cat > "$mrs_mutex/withitem/holder.json" <<'JSON'
{
  "holder_id": "dead-worker-2",
  "task_id": "task-stale-test",
  "reason": "stale mutex with backlog item",
  "started_at": "2000-01-01T00:00:00Z",
  "updated_at": "2000-01-01T00:05:00Z"
}
JSON
ts_old="2000-01-01T00:00:00Z"
cat > "$mrs_backlog/items/task-stale-test.json" <<JSON
{
  "id": "task-stale-test",
  "title": "Stale task",
  "status": "in_progress",
  "priority": 50,
  "created_at": "${ts_old}",
  "updated_at": "${ts_old}"
}
JSON
set +e
MUTEX_DIR="$mrs_mutex/withitem" BACKLOG_DIR="$mrs_backlog" ./scripts/mutex-release-stale.sh --stale-minutes 1 >"$tmp/mrs-withitem.out" 2>"$tmp/mrs-withitem.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "stale with item exit status was $status, expected 0"
grep -q '^status=STALE$' "$tmp/mrs-withitem.out" || fail "stale with item status not STALE"
grep -q '^action=released$' "$tmp/mrs-withitem.out" || fail "stale with item action not released"
grep -q '^task_id=task-stale-test$' "$tmp/mrs-withitem.out" || fail "stale with item task_id not output"
grep -q '^task_reset_to=queued$' "$tmp/mrs-withitem.out" || fail "stale with item should reset to queued"
s=$(grep '"status"' "$mrs_backlog/items/task-stale-test.json" | sed 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
[[ "$s" == "queued" ]] || fail "stale with item status should be queued, got $s"
[[ ! -d "$mrs_mutex/withitem" ]] || fail "stale with item mutex dir should be removed"

# Stale mutex dry run -> WOULD_RELEASE, mutex NOT removed
mkdir -p "$mrs_mutex/drystale"
cat > "$mrs_mutex/drystale/holder.json" <<'JSON'
{
  "holder_id": "dry-worker",
  "task_id": "task-dry-test",
  "reason": "dry run test",
  "started_at": "2000-01-01T00:00:00Z",
  "updated_at": "2000-01-01T00:05:00Z"
}
JSON
set +e
MUTEX_DIR="$mrs_mutex/drystale" BACKLOG_DIR="$mrs_backlog" ./scripts/mutex-release-stale.sh --stale-minutes 1 --dry-run >"$tmp/mrs-drystale.out" 2>"$tmp/mrs-drystale.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "stale dry-run exit status was $status, expected 0"
grep -q '^action=WOULD_RELEASE$' "$tmp/mrs-drystale.out" || fail "stale dry-run action not WOULD_RELEASE"
grep -q '^task_id=task-dry-test$' "$tmp/mrs-drystale.out" || fail "stale dry-run task_id not output"
[[ -d "$mrs_mutex/drystale" ]] || fail "stale dry-run should not remove mutex"
s=$(grep '"status"' "$mrs_backlog/items/task-stale-test.json" | sed 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
[[ "$s" == "queued" ]] || fail "stale dry-run should not change status"

log "mutex touch smoke tests"
mt_tmp="$tmp/mutex_touch"
mt_mutex="$mt_tmp/mutex"

# Free mutex -> touched=false
set +e
MUTEX_DIR="$mt_tmp/nonexistent" ./scripts/mutex-touch.sh >"$tmp/mt-free.out" 2>"$tmp/mt-free.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "free mutex touch exit status was $status, expected 0"
grep -q '^touched=false$' "$tmp/mt-free.out" || fail "free mutex touch not touched=false"
grep -q 'mutex not held' "$tmp/mt-free.out" || fail "free mutex touch reason missing"

# Held mutex -> touched=true, updated_at refreshed
mkdir -p "$mt_mutex"
cat > "$mt_mutex/holder.json" <<'JSON'
{
  "holder_id": "touch-test",
  "reason": "mutex touch smoke test",
  "started_at": "2000-01-01T00:00:00Z",
  "updated_at": "2000-01-01T00:00:00Z"
}
JSON
set +e
MUTEX_DIR="$mt_mutex" ./scripts/mutex-touch.sh >"$tmp/mt-held.out" 2>"$tmp/mt-held.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "held mutex touch exit status was $status, expected 0"
grep -q '^touched=true$' "$tmp/mt-held.out" || fail "held mutex touch not touched=true"
touch_ts=$(grep '^updated_at=' "$tmp/mt-held.out" | sed 's/^updated_at=//')
[[ -n "$touch_ts" ]] || fail "held mutex touch should output updated_at"
# Verify updated_at was refreshed (not the original 2000 date)
updated_in_file=$(grep -o '"updated_at"[[:space:]]*:[[:space:]]*"[^"]*"' "$mt_mutex/holder.json" | sed 's/.*"updated_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
[[ "$updated_in_file" != "2000-01-01T00:00:00Z" ]] || fail "mutex touch should update timestamp"

# Broken mutex (dir exists, no holder.json) -> touched=false
mkdir -p "$mt_tmp/broken"
set +e
MUTEX_DIR="$mt_tmp/broken" ./scripts/mutex-touch.sh >"$tmp/mt-broken.out" 2>"$tmp/mt-broken.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "broken mutex touch exit status was $status, expected 0"
grep -q '^touched=false$' "$tmp/mt-broken.out" || fail "broken mutex touch not touched=false"

log "pr status smoke tests"
pr_tmp="$tmp/pr_status"
mkdir -p "$pr_tmp"

# gh not available (default PATH has no gh) -> pr_check_available=false
set +e
./scripts/pr-status.sh --repo "$pr_tmp" >"$tmp/pr-nogh.out" 2>"$tmp/pr-nogh.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "no gh exit status was $status, expected 0"
grep -q '^pr_check_available=false$' "$tmp/pr-nogh.out" || fail "no gh should report unavailable"

# gh available, no open PRs
cat > "$tmp/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_STUB_LOG:?}"
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  exit 0
fi
exit 0
GH_STUB
chmod +x "$tmp/bin/gh"

gh_log="$tmp/gh.log"
PATH="$tmp/bin:$PATH" GH_STUB_LOG="$gh_log" ./scripts/pr-status.sh --repo "$pr_tmp" >"$tmp/pr-empty.out" 2>"$tmp/pr-empty.err"
grep -q '^open_prs=0$' "$tmp/pr-empty.out" || fail "empty prs should report 0"
grep -q '^details=No open PRs$' "$tmp/pr-empty.out" || fail "empty prs details wrong"

# gh stub with healthy PR
cat > "$tmp/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_STUB_LOG:?}"
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  printf '42\tHealthy PR\tmain\t2026-05-24T10:00:00Z\t2026-05-24T10:00:00Z\tMERGEABLE\tauthor\n'
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  printf '{"statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}\n'
  exit 0
fi
exit 0
GH_STUB
chmod +x "$tmp/bin/gh"

PATH="$tmp/bin:$PATH" GH_STUB_LOG="$gh_log" ./scripts/pr-status.sh --repo "$pr_tmp" >"$tmp/pr-healthy.out" 2>"$tmp/pr-healthy.err"
grep -q '^pr_check_available=true$' "$tmp/pr-healthy.out" || fail "healthy pr should be available"
grep -q '^open_prs=1$' "$tmp/pr-healthy.out" || fail "healthy pr should report 1"
grep -q '^pr_1_number=42$' "$tmp/pr-healthy.out" || fail "healthy pr number missing"
grep -q '^pr_1_ci=success$' "$tmp/pr-healthy.out" || fail "healthy pr ci should be success"
grep -q '^pr_1_stale=false$' "$tmp/pr-healthy.out" || fail "healthy pr should not be stale"

# gh stub with failing CI -> exit 2
cat > "$tmp/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_STUB_LOG:?}"
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  printf '99\tFailing PR\tmain\t2026-05-24T10:00:00Z\t2026-05-24T10:00:00Z\tMERGEABLE\tauthor\n'
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  printf '{"statusCheckRollup":[{"conclusion":"FAILURE","status":"COMPLETED"}]}\n'
  exit 0
fi
exit 0
GH_STUB
chmod +x "$tmp/bin/gh"

set +e
PATH="$tmp/bin:$PATH" GH_STUB_LOG="$gh_log" ./scripts/pr-status.sh --repo "$pr_tmp" >"$tmp/pr-failing.out" 2>"$tmp/pr-failing.err"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "failing ci exit status was $status, expected 2"
grep -q '^failing_ci=1$' "$tmp/pr-failing.out" || fail "failing ci count wrong"
grep -q 'PR #99 CI failing' "$tmp/pr-failing.out" || fail "failing ci not in details"

# gh stub with stale PR -> exit 1
cat > "$tmp/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_STUB_LOG:?}"
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  printf '77\tStale PR\tmain\t2000-01-01T00:00:00Z\t2000-01-01T00:00:00Z\tMERGEABLE\tauthor\n'
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  printf '{"statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}\n'
  exit 0
fi
exit 0
GH_STUB
chmod +x "$tmp/bin/gh"

set +e
PATH="$tmp/bin:$PATH" GH_STUB_LOG="$gh_log" ./scripts/pr-status.sh --repo "$pr_tmp" --stale-hours 1 >"$tmp/pr-stale.out" 2>"$tmp/pr-stale.err"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "stale pr exit status was $status, expected 1"
grep -q '^stale_prs=1$' "$tmp/pr-stale.out" || fail "stale pr count wrong"
grep -q 'PR #77 stale' "$tmp/pr-stale.out" || fail "stale pr not in details"

log "pr follow-up smoke tests"
fup_tmp="$tmp/pr_followup"
mkdir -p "$fup_tmp"

# gh not available (default PATH has no gh) -> no-op
set +e
PATH="$tmp/bin:$PATH" ./scripts/pr-follow-up.sh --repo "$fup_tmp" >"$tmp/fup-nogh.out" 2>"$tmp/fup-nogh.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "fup no gh exit status was $status, expected 0"
grep -q '^updated=0$' "$tmp/fup-nogh.out" || fail "fup no gh updated should be 0"
grep -q '^commented=0$' "$tmp/fup-nogh.out" || fail "fup no gh commented should be 0"

# gh stub with stale PR and passing CI -> update-branch called
cat > "$tmp/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_STUB_LOG:?}"
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  printf '77\tStale PR\tstale-branch\t2000-01-01T00:00:00Z\t2000-01-01T00:00:00Z\tMERGEABLE\tauthor\n'
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  printf '{"statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}\n'
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "update-branch" ]]; then
  exit 0
fi
exit 0
GH_STUB
chmod +x "$tmp/bin/gh"
gh_log="$tmp/gh_fup.log"
: > "$gh_log"

PATH="$tmp/bin:$PATH" GH_STUB_LOG="$gh_log" ./scripts/pr-follow-up.sh --repo "$fup_tmp" --stale-hours 1 >"$tmp/fup-stale-success.out" 2>"$tmp/fup-stale-success.err"
grep -q '^updated=1$' "$tmp/fup-stale-success.out" || fail "fup stale+success should update 1"
grep -q '^commented=0$' "$tmp/fup-stale-success.out" || fail "fup stale+success should not comment"
grep -q 'update-branch.*77' "$gh_log" || fail "fup stale+success should call gh pr update-branch"

# gh stub with stale PR and failing CI -> comment
cat > "$tmp/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_STUB_LOG:?}"
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  printf '99\tFailing PR\tfailing-branch\t2000-01-01T00:00:00Z\t2000-01-01T00:00:00Z\tMERGEABLE\tauthor\n'
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  printf '{"statusCheckRollup":[{"conclusion":"FAILURE","status":"COMPLETED"}]}\n'
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "comment" ]]; then
  exit 0
fi
exit 0
GH_STUB
chmod +x "$tmp/bin/gh"
: > "$gh_log"

PATH="$tmp/bin:$PATH" GH_STUB_LOG="$gh_log" ./scripts/pr-follow-up.sh --repo "$fup_tmp" --stale-hours 1 >"$tmp/fup-stale-failing.out" 2>"$tmp/fup-stale-failing.err"
grep -q '^updated=0$' "$tmp/fup-stale-failing.out" || fail "fup stale+failing should not update"
grep -q '^commented=1$' "$tmp/fup-stale-failing.out" || fail "fup stale+failing should comment 1"
grep -q 'comment.*99' "$gh_log" || fail "fup stale+failing should call gh pr comment"

# gh stub with healthy PR (not stale) -> no action
cat > "$tmp/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_STUB_LOG:?}"
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  printf '42\tHealthy PR\tmain\t2026-05-24T10:00:00Z\t2026-05-24T10:00:00Z\tMERGEABLE\tauthor\n'
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  printf '{"statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}\n'
  exit 0
fi
exit 0
GH_STUB
chmod +x "$tmp/bin/gh"
: > "$gh_log"

PATH="$tmp/bin:$PATH" GH_STUB_LOG="$gh_log" ./scripts/pr-follow-up.sh --repo "$fup_tmp" --stale-hours 24 >"$tmp/fup-healthy.out" 2>"$tmp/fup-healthy.err"
grep -q '^updated=0$' "$tmp/fup-healthy.out" || fail "fup healthy should not update"
grep -q '^commented=0$' "$tmp/fup-healthy.out" || fail "fup healthy should not comment"
grep -q 'No PR follow-up needed' "$tmp/fup-healthy.out" || fail "fup healthy should say no action needed"

# dry-run on stale PR -> WOULD but no actual gh calls
cat > "$tmp/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_STUB_LOG:?}"
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  printf '55\tStale PR\tdry-branch\t2000-01-01T00:00:00Z\t2000-01-01T00:00:00Z\tMERGEABLE\tauthor\n'
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  printf '{"statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}\n'
  exit 0
fi
exit 0
GH_STUB
chmod +x "$tmp/bin/gh"
: > "$gh_log"

PATH="$tmp/bin:$PATH" GH_STUB_LOG="$gh_log" ./scripts/pr-follow-up.sh --repo "$fup_tmp" --stale-hours 1 --dry-run >"$tmp/fup-dry.out" 2>"$tmp/fup-dry.err"
grep -q '^updated=0$' "$tmp/fup-dry.out" || fail "fup dry-run updated should be 0"
grep -q '^actions=0$' "$tmp/fup-dry.out" || fail "fup dry-run actions should be 0"
grep -q 'WOULD rebase' "$tmp/fup-dry.out" || fail "fup dry-run should show WOULD"
grep -q 'update-branch' "$gh_log" && fail "fup dry-run should not call gh pr update-branch" || true

log "report smoke tests"
report_tmp="$tmp/report"
mkdir -p "$report_tmp/items"

# Empty backlog + free mutex + no gh -> OK
set +e
BACKLOG_DIR="$report_tmp" ./scripts/report.sh >"$tmp/report-empty.out" 2>"$tmp/report-empty.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "empty report exit status was $status, expected 0"
grep -q '^status=OK$' "$tmp/report-empty.out" || fail "empty report status not OK"
grep -q '^mutex=FREE$' "$tmp/report-empty.out" || fail "empty report mutex not FREE"
grep -q '^backlog_total=0$' "$tmp/report-empty.out" || fail "empty report backlog_total not 0"
grep -q '^backlog_completed=0$' "$tmp/report-empty.out" || fail "empty report backlog_completed not 0"
grep -q '^mutex_holder_id=$' "$tmp/report-empty.out" || fail "empty report mutex_holder_id should be empty"
grep -q '^mutex_task_id=$' "$tmp/report-empty.out" || fail "empty report mutex_task_id should be empty"
grep -q '^pr_check_available=false$' "$tmp/report-empty.out" || fail "empty report pr check not false"
grep -q '^summary=' "$tmp/report-empty.out" || fail "empty report missing summary"

# Held mutex + backlog items -> OK with relevant fields
report_mutex="$report_tmp/mutex"
mkdir -p "$report_mutex"
BACKLOG_DIR="$report_tmp" ./scripts/backlog.sh add --type task --title "Report task" --priority 50 >/dev/null
cat > "$report_mutex/holder.json" <<'JSON'
{
  "holder_id": "report-worker",
  "reason": "report smoke test",
  "started_at": "2999-01-01T00:00:00Z",
  "updated_at": "2999-01-01T00:02:00Z",
  "expected_next_action": "finish smoke test"
}
JSON
set +e
BACKLOG_DIR="$report_tmp" MUTEX_DIR="$report_mutex" ./scripts/report.sh >"$tmp/report-held.out" 2>"$tmp/report-held.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "held report exit status was $status, expected 0"
grep -q '^status=OK$' "$tmp/report-held.out" || fail "held report status not OK"
grep -q '^mutex=HELD$' "$tmp/report-held.out" || fail "held report mutex not HELD"
grep -q '^backlog_total=1$' "$tmp/report-held.out" || fail "held report backlog_total not 1"
grep -q '^backlog_queued=1$' "$tmp/report-held.out" || fail "held report backlog_queued not 1"
grep -q '^backlog_completed=0$' "$tmp/report-held.out" || fail "held report backlog_completed not 0"
grep -q '^mutex_holder_id=report-worker$' "$tmp/report-held.out" || fail "held report mutex_holder_id not report-worker"
grep -q '^mutex_task_id=$' "$tmp/report-held.out" || fail "held report mutex_task_id should be empty"

# Held mutex with task_id -> mutex_task_id reported
cat > "$report_mutex/holder.json" <<'JSON'
{
  "holder_id": "task-holder",
  "task_id": "task-42",
  "reason": "report task_id test",
  "started_at": "2999-01-01T00:00:00Z",
  "updated_at": "2999-01-01T00:02:00Z"
}
JSON
set +e
BACKLOG_DIR="$report_tmp" MUTEX_DIR="$report_mutex" ./scripts/report.sh >"$tmp/report-taskid.out" 2>"$tmp/report-taskid.err"
status=$?
set -e
grep -q '^mutex_holder_id=task-holder$' "$tmp/report-taskid.out" || fail "taskid report mutex_holder_id not task-holder"
grep -q '^mutex_task_id=task-42$' "$tmp/report-taskid.out" || fail "taskid report mutex_task_id not task-42"

# All checks pass with correct combined exit
Rval=$(grep '^mutex=' "$tmp/report-empty.out" | sed 's/^mutex=//')
Bval=$(grep '^backlog_total=' "$tmp/report-empty.out" | sed 's/^backlog_total=//')
[[ "$Rval" == "FREE" ]] || fail "report.sh mutex value incorrect: $Rval"
[[ "$Bval" == "0" ]] || fail "report.sh backlog_total value incorrect: $Bval"

# Stale mutex -> CRITICAL
cat > "$report_mutex/holder.json" <<'JSON'
{
  "holder_id": "dead-worker",
  "reason": "stale report test",
  "started_at": "2000-01-01T00:00:00Z",
  "updated_at": "2000-01-01T00:05:00Z"
}
JSON
set +e
BACKLOG_DIR="$report_tmp" MUTEX_DIR="$report_mutex" ./scripts/report.sh --stale-minutes 1 >"$tmp/report-stale.out" 2>"$tmp/report-stale.err"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "stale report exit status was $status, expected 2"
grep -q '^status=CRITICAL$' "$tmp/report-stale.out" || fail "stale report status not CRITICAL"
grep -q '^mutex=STALE$' "$tmp/report-stale.out" || fail "stale report mutex not STALE"

log "next-action smoke tests"
na_tmp="$tmp/next_action"

# Empty backlog + free mutex + no gh + no last_generated -> generate_hypotheses
mkdir -p "$na_tmp/items"
set +e
BACKLOG_DIR="$na_tmp" ./scripts/next-action.sh >"$tmp/na-hyp-gen.out" 2>"$tmp/na-hyp-gen.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "hyp-gen next-action exit status was $status, expected 0"
grep -q '^action=generate_hypotheses$' "$tmp/na-hyp-gen.out" || fail "empty next-action action not generate_hypotheses"
grep -q '^mutex=FREE' "$tmp/na-hyp-gen.out" || fail "empty next-action mutex not FREE"

# Empty backlog + free mutex + recent last_generated -> idle
na_hyp_state="$na_tmp/hypothesis"
mkdir -p "$na_hyp_state"
date -u +%s > "$na_hyp_state/last_generated"
set +e
HYPOTHESIS_STATE_DIR="$na_hyp_state" BACKLOG_DIR="$na_tmp" ./scripts/next-action.sh >"$tmp/na-idle.out" 2>"$tmp/na-idle.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "idle next-action exit status was $status, expected 0"
grep -q '^action=idle$' "$tmp/na-idle.out" || fail "idle next-action action not idle"
grep -q '^mutex=FREE' "$tmp/na-idle.out" || fail "idle next-action mutex not FREE"

# Free mutex + queued item -> start_backlog_item
na_backlog="$na_tmp/with_item"
BACKLOG_DIR="$na_backlog" ./scripts/backlog.sh add --type task --title "Next action task" --priority 80 >/dev/null
set +e
BACKLOG_DIR="$na_backlog" ./scripts/next-action.sh >"$tmp/na-work.out" 2>"$tmp/na-work.err"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "work next-action exit status was $status, expected 1"
grep -q '^action=start_backlog_item$' "$tmp/na-work.out" || fail "work next-action action not start_backlog_item"
grep -q '^backlog_queued=1$' "$tmp/na-work.out" || fail "work next-action backlog_queued not 1"

# Held mutex -> wait_for_mutex
na_mutex="$na_tmp/mutex_held"
mkdir -p "$na_mutex"
cat > "$na_mutex/holder.json" <<'JSON'
{
  "holder_id": "active-worker",
  "reason": "next-action held test",
  "started_at": "2999-01-01T00:00:00Z",
  "updated_at": "2999-01-01T00:02:00Z"
}
JSON
set +e
BACKLOG_DIR="$na_backlog" MUTEX_DIR="$na_mutex" ./scripts/next-action.sh >"$tmp/na-held.out" 2>"$tmp/na-held.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "held next-action exit status was $status, expected 0"
grep -q '^action=wait_for_mutex$' "$tmp/na-held.out" || fail "held next-action action not wait_for_mutex"
grep -q '^mutex=HELD$' "$tmp/na-held.out" || fail "held next-action mutex not HELD"

# Stale mutex -> release_stale_mutex
na_stale_mutex="$na_tmp/mutex_stale"
mkdir -p "$na_stale_mutex"
cat > "$na_stale_mutex/holder.json" <<'JSON'
{
  "holder_id": "dead-worker",
  "reason": "next-action stale test",
  "started_at": "2000-01-01T00:00:00Z",
  "updated_at": "2000-01-01T00:05:00Z"
}
JSON
set +e
BACKLOG_DIR="$na_backlog" MUTEX_DIR="$na_stale_mutex" ./scripts/next-action.sh --stale-minutes 1 >"$tmp/na-stale.out" 2>"$tmp/na-stale.err"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "stale next-action exit status was $status, expected 2"
grep -q '^action=release_stale_mutex$' "$tmp/na-stale.out" || fail "stale next-action action not release_stale_mutex"
grep -q '^mutex=STALE$' "$tmp/na-stale.out" || fail "stale next-action mutex not STALE"

# Broken mutex -> fix_mutex
na_broken_mutex="$na_tmp/mutex_broken"
mkdir -p "$na_broken_mutex"
printf 'not json\n' > "$na_broken_mutex/holder.json"
set +e
BACKLOG_DIR="$na_backlog" MUTEX_DIR="$na_broken_mutex" ./scripts/next-action.sh >"$tmp/na-broken.out" 2>"$tmp/na-broken.err"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "broken next-action exit status was $status, expected 2"
grep -q '^action=fix_mutex$' "$tmp/na-broken.out" || fail "broken next-action action not fix_mutex"

# Free mutex + in_progress item + no queued -> check_stale_in_progress
na_stale_ip="$na_tmp/stale_ip"
mkdir -p "$na_stale_ip/items"
BACKLOG_DIR="$na_stale_ip" ./scripts/backlog.sh add --type task --title "Orphaned in_progress" --priority 30 >/dev/null
stale_ip_id=$(BACKLOG_DIR="$na_stale_ip" ./scripts/backlog.sh next | grep '^id=' | sed 's/^id=//')
[[ -n "$stale_ip_id" ]] || fail "stale_ip add failed"
sed -i 's/"status"[[:space:]]*:[[:space:]]*"[^"]*"/"status": "in_progress"/' "$na_stale_ip/items/$stale_ip_id.json"
set +e
BACKLOG_DIR="$na_stale_ip" ./scripts/next-action.sh >"$tmp/na-stale-ip.out" 2>"$tmp/na-stale-ip.err"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "stale_ip next-action exit status was $status, expected 1"
grep -q '^action=check_stale_in_progress$' "$tmp/na-stale-ip.out" || fail "stale_ip next-action action not check_stale_in_progress"
grep -q 'backlog_in_progress=1' "$tmp/na-stale-ip.out" || fail "stale_ip should report 1 in_progress"
grep -q 'backlog_next=none' "$tmp/na-stale-ip.out" || fail "stale_ip should report no queued items"

log "hypothesis generate smoke tests"
hg_tmp="$tmp/hypothesis_gen"
hg_backlog="$hg_tmp/backlog"
hg_hyp_state="$hg_tmp/hypothesis"

# Missing --title -> exit 2
set +e
BACKLOG_DIR="$hg_backlog" HYPOTHESIS_STATE_DIR="$hg_hyp_state" \
  ./scripts/hypothesis-generate.sh >"$tmp/hg-no-title.out" 2>"$tmp/hg-no-title.err"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "missing title exit status was $status, expected 2"
grep -q 'Missing --title' "$tmp/hg-no-title.err" || fail "missing title error not reported"

# Valid generation with --title -> creates backlog item and state dir
set +e
BACKLOG_DIR="$hg_backlog" HYPOTHESIS_STATE_DIR="$hg_hyp_state" \
  ./scripts/hypothesis-generate.sh --title "Test hypothesis" --desc "Based on smoke test" --source analytics --priority 75 >"$tmp/hg-valid.out" 2>"$tmp/hg-valid.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "valid hypothesis exit status was $status, expected 0"
hg_id=$(cat "$tmp/hg-valid.out")
[[ -n "$hg_id" ]] || fail "hypothesis generate did not output an id"
[[ -f "$hg_backlog/items/$hg_id.json" ]] || fail "hypothesis item file not created"
[[ -f "$hg_hyp_state/last_generated" ]] || fail "hypothesis state not written"
t=$(grep '"type"' "$hg_backlog/items/$hg_id.json" | sed 's/.*"type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
[[ "$t" == "hypothesis" ]] || fail "hypothesis type should be hypothesis, got $t"
s=$(grep '"source"' "$hg_backlog/items/$hg_id.json" | sed 's/.*"source"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
[[ "$s" == "analytics" ]] || fail "hypothesis source should be analytics, got $s"

# Mark hypothesis as done so backlog is empty, then verify next-action picks up recent last_generated -> idle
BACKLOG_DIR="$hg_backlog" ./scripts/backlog.sh update "$hg_id" --status done >/dev/null
BACKLOG_DIR="$hg_backlog" ./scripts/backlog.sh archive >/dev/null
set +e
BACKLOG_DIR="$hg_backlog" HYPOTHESIS_STATE_DIR="$hg_hyp_state" \
  ./scripts/next-action.sh --hypothesis-interval-hours 1 >"$tmp/hg-next-idle.out" 2>"$tmp/hg-next-idle.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "post-hypothesis next-action exit status was $status, expected 0"
grep -q '^action=idle$' "$tmp/hg-next-idle.out" || fail "post-hypothesis next-action should idle"

log "drive smoke tests"
drive_tmp="$tmp/drive"
drive_backlog="$drive_tmp/backlog"
drive_hyp_state="$drive_tmp/hyp_state"

# Empty backlog + free mutex + recent hypotheses -> idle
mkdir -p "$drive_backlog/items" "$drive_hyp_state"
date -u +%s > "$drive_hyp_state/last_generated"
set +e
HYPOTHESIS_STATE_DIR="$drive_hyp_state" BACKLOG_DIR="$drive_backlog" MUTEX_DIR="$drive_tmp/mutex_free" \
  ./scripts/drive.sh >"$tmp/drive-idle.out" 2>"$tmp/drive-idle.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "idle drive exit status was $status, expected 0"
grep -q '^action=idle$' "$tmp/drive-idle.out" || fail "idle action not found"
grep -q '^summary=' "$tmp/drive-idle.out" || fail "idle drive missing summary"

# Empty backlog + free mutex + no recent hypotheses -> generate_hypotheses,
# then loop continues to acquire the hypothesis as a backlog item
rm -f "$drive_hyp_state/last_generated"
set +e
HYPOTHESIS_STATE_DIR="$drive_hyp_state" BACKLOG_DIR="$drive_backlog" MUTEX_DIR="$drive_tmp/mutex_free" \
  ./scripts/drive.sh >"$tmp/drive-hyp.out" 2>"$tmp/drive-hyp.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "drive hyp->acquire exit status was $status, expected 0"
grep -q '^action=start_backlog_item$' "$tmp/drive-hyp.out" || fail "drive hyp should loop to start_backlog_item"
grep -q '^summary=' "$tmp/drive-hyp.out" || fail "drive hyp missing summary"
grep -q 'generated' "$tmp/drive-hyp.out" || fail "drive hyp summary missing generation"
grep -q 'acquired' "$tmp/drive-hyp.out" || fail "drive hyp summary missing acquisition"
[[ -f "$drive_hyp_state/last_generated" ]] || fail "drive hyp should write last_generated"
# Verify the hypothesis was created and acquired
hyp_items=$(find "$drive_backlog/items/" -name '*.json' 2>/dev/null)
hyp_count=$(printf '%s\n' "$hyp_items" | wc -l)
[[ "$hyp_count" -eq 1 ]] || fail "drive hyp should create exactly 1 backlog item, got $hyp_count"
hyp_item=$(printf '%s\n' "$hyp_items" | head -1)
hyp_type=$(grep -o '"type"[[:space:]]*:[[:space:]]*"[^"]*"' "$hyp_item" | sed 's/.*"type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
[[ "$hyp_type" == "hypothesis" ]] || fail "drive hyp item type should be hypothesis, got $hyp_type"
hyp_status=$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$hyp_item" | sed 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
[[ "$hyp_status" == "in_progress" ]] || fail "drive hyp item should be acquired (in_progress), got $hyp_status"
# Mutex should be acquired
[[ -d "$drive_tmp/mutex_free" ]] || fail "drive hyp should acquire mutex"
[[ -f "$drive_tmp/mutex_free/holder.json" ]] || fail "drive hyp mutex holder.json missing"
grep -q '^acquired_type=hypothesis$' "$tmp/drive-hyp.out" || fail "drive hyp acquired_type not hypothesis"
grep -q '^acquired_description=' "$tmp/drive-hyp.out" || fail "drive hyp acquired_description missing"

# Held mutex -> wait_for_mutex
mkdir -p "$drive_tmp/mutex_held"
cat > "$drive_tmp/mutex_held/holder.json" <<'JSON'
{"holder_id":"test-holder","reason":"drive held test","started_at":"2999-01-01T00:00:00Z","updated_at":"2999-01-01T00:02:00Z"}
JSON
set +e
HYPOTHESIS_STATE_DIR="$drive_hyp_state" BACKLOG_DIR="$drive_backlog" MUTEX_DIR="$drive_tmp/mutex_held" \
  ./scripts/drive.sh >"$tmp/drive-held.out" 2>"$tmp/drive-held.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "held mutex drive exit status was $status, expected 0"
grep -q '^action=wait_for_mutex$' "$tmp/drive-held.out" || fail "wait_for_mutex action not found"
grep -q '^summary=' "$tmp/drive-held.out" || fail "held mutex drive missing summary"

# Queued item + free mutex -> start_backlog_item (acquires task + mutex)
drive_start_bl="$drive_tmp/bl_start"
BACKLOG_DIR="$drive_start_bl" ./scripts/backlog.sh add --type task --title "Drive start test" --priority 90 >/dev/null
set +e
BACKLOG_DIR="$drive_start_bl" MUTEX_DIR="$drive_tmp/mutex_start" \
  ./scripts/drive.sh >"$tmp/drive-start.out" 2>"$tmp/drive-start.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "start backlog item drive exit status was $status, expected 0"
grep -q '^action=start_backlog_item$' "$tmp/drive-start.out" || fail "start_backlog_item action not found"
grep -q '^summary=.*acquired backlog item' "$tmp/drive-start.out" || fail "start_backlog_item summary missing acquisition"
[[ -d "$drive_tmp/mutex_start" ]] || fail "mutex was not acquired"
[[ -f "$drive_tmp/mutex_start/holder.json" ]] || fail "holder.json not written"
grep -q '^acquired_type=task$' "$tmp/drive-start.out" || fail "start_backlog_item acquired_type not task"
grep -q '^acquired_description=' "$tmp/drive-start.out" || fail "start_backlog_item acquired_description missing"

# Stale mutex -> mutex-release-stale.sh, then loop continues to acquire task
drive_stale_bl="$drive_tmp/bl_stale"
drive_stale_mutex="$drive_tmp/mutex_stale"
mkdir -p "$drive_stale_bl/items" "$drive_stale_mutex"
BACKLOG_DIR="$drive_stale_bl" ./scripts/backlog.sh add --type task --title "Stale recovery task" --priority 70 >/dev/null
cat > "$drive_stale_mutex/holder.json" <<'JSON'
{"holder_id":"dead-worker","reason":"drive stale test","started_at":"2000-01-01T00:00:00Z","updated_at":"2000-01-01T00:05:00Z"}
JSON
set +e
BACKLOG_DIR="$drive_stale_bl" MUTEX_DIR="$drive_stale_mutex" \
  ./scripts/drive.sh --stale-minutes 1 >"$tmp/drive-stale.out" 2>"$tmp/drive-stale.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "stale mutex drive exit status was $status, expected 0"
grep -q '^action=start_backlog_item$' "$tmp/drive-stale.out" || fail "stale mutex drive should loop to start_backlog_item"
grep -q 'released stale mutex' "$tmp/drive-stale.out" || fail "stale mutex summary missing release"
[[ -d "$drive_stale_mutex" ]] || fail "stale mutex drive should acquire mutex after cleanup"

# Broken mutex -> mutex-release-stale.sh, then loop continues to acquire task
drive_broken_bl="$drive_tmp/bl_broken"
drive_broken_mutex="$drive_tmp/mutex_broken"
mkdir -p "$drive_broken_bl/items" "$drive_broken_mutex"
BACKLOG_DIR="$drive_broken_bl" ./scripts/backlog.sh add --type task --title "Broken mutex recover" --priority 80 >/dev/null
printf 'not json\n' > "$drive_broken_mutex/holder.json"
set +e
BACKLOG_DIR="$drive_broken_bl" MUTEX_DIR="$drive_broken_mutex" \
  ./scripts/drive.sh >"$tmp/drive-broken.out" 2>"$tmp/drive-broken.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "broken mutex drive exit status was $status, expected 0"
grep -q '^action=start_backlog_item$' "$tmp/drive-broken.out" || fail "broken mutex drive should loop to start_backlog_item"
grep -q 'removed broken mutex' "$tmp/drive-broken.out" || fail "broken mutex summary missing removal"
[[ -d "$drive_broken_mutex" ]] || fail "broken mutex drive should acquire mutex after cleanup"

# Stale in_progress item + free mutex -> backlog hygiene auto-resets to queued,
# then start_backlog_item re-acquires with mutex
drive_stale_ip="$tmp/drive_stale_ip"
drive_stale_ip_bl="$drive_stale_ip/backlog"
mkdir -p "$drive_stale_ip_bl/items"
BACKLOG_DIR="$drive_stale_ip_bl" ./scripts/backlog.sh add --type task --title "Orphaned task" --priority 60 >/dev/null
stale_ip_id=$(BACKLOG_DIR="$drive_stale_ip_bl" ./scripts/backlog.sh next | grep '^id=' | sed 's/^id=//')
[[ -n "$stale_ip_id" ]] || fail "drive stale ip add failed"
sed -i 's/"status"[[:space:]]*:[[:space:]]*"[^"]*"/"status": "in_progress"/' "$drive_stale_ip_bl/items/$stale_ip_id.json"
sed -i 's/"updated_at"[[:space:]]*:[[:space:]]*"[^"]*"/"updated_at": "2000-01-01T00:00:00Z"/' "$drive_stale_ip_bl/items/$stale_ip_id.json"
sed -i 's/"created_at"[[:space:]]*:[[:space:]]*"[^"]*"/"created_at": "2000-01-01T00:00:00Z"/' "$drive_stale_ip_bl/items/$stale_ip_id.json"
set +e
BACKLOG_DIR="$drive_stale_ip_bl" MUTEX_DIR="$drive_stale_ip/mutex" \
  ./scripts/drive.sh --stale-minutes 1 >"$tmp/drive-stale-ip.out" 2>"$tmp/drive-stale-ip.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "drive stale ip exit status was $status, expected 0"
grep -q '^action=start_backlog_item$' "$tmp/drive-stale-ip.out" || fail "drive stale ip action not start_backlog_item"
grep -q '^summary=.*reset' "$tmp/drive-stale-ip.out" || fail "drive stale ip summary missing reset"
[[ -d "$drive_stale_ip/mutex" ]] || fail "drive stale ip mutex should be acquired"
[[ -f "$drive_stale_ip/mutex/holder.json" ]] || fail "drive stale ip holder.json should exist"
s=$(grep '"status"' "$drive_stale_ip_bl/items/$stale_ip_id.json" | sed 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
[[ "$s" == "in_progress" ]] || fail "drive stale ip should re-acquire to in_progress, got $s"

log "memory size check smoke tests"
msc_tmp="$tmp/memory_size_check"
mkdir -p "$msc_tmp"

# No MEMORY.md file -> exists=false, status=OK, exit 0
set +e
./scripts/memory-size-check.sh --file "$msc_tmp/nonexistent.md" >"$tmp/msc-no-file.out" 2>"$tmp/msc-no-file.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "no-file exit status was $status, expected 0"
grep -q '^exists=false$' "$tmp/msc-no-file.out" || fail "no-file should report exists=false"
grep -q '^status=OK$' "$tmp/msc-no-file.out" || fail "no-file should report status=OK"

# Small MEMORY.md file -> within budget, exit 0
printf '# MEMORY.md\n\nSmall file\n' > "$msc_tmp/small.md"
set +e
./scripts/memory-size-check.sh --file "$msc_tmp/small.md" --max-lines 100 --max-bytes 10000 >"$tmp/msc-small.out" 2>"$tmp/msc-small.err"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "small file exit status was $status, expected 0"
grep -q '^exists=true$' "$tmp/msc-small.out" || fail "small file should report exists=true"
grep -q '^status=OK$' "$tmp/msc-small.out" || fail "small file should report status=OK"

# Large MEMORY.md file -> OVER_LIMIT, exit 2
msc_bl="$msc_tmp/backlog"
python3 -c "for _ in range(600): print('line')" > "$msc_tmp/large.md"
set +e
BACKLOG_DIR="$msc_bl" ./scripts/memory-size-check.sh --file "$msc_tmp/large.md" --max-lines 500 --max-bytes 1000000 >"$tmp/msc-large.out" 2>"$tmp/msc-large.err"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "large file exit status was $status, expected 2"
grep -q '^status=OVER_LIMIT$' "$tmp/msc-large.out" || fail "large file should report OVER_LIMIT"
grep -q '^over_lines=true$' "$tmp/msc-large.out" || fail "large file should report over_lines=true"
grep -q '^candidate_created=true$' "$tmp/msc-large.out" || fail "large file should create fix candidate"
[[ -n "$(find "$msc_bl/items/" -name '*.json' 2>/dev/null | head -1)" ]] || fail "large file should create backlog item"

# Dry-run on large file -> candidate_created=false, no backlog item
msc_bl2="$msc_tmp/backlog2"
set +e
BACKLOG_DIR="$msc_bl2" ./scripts/memory-size-check.sh --file "$msc_tmp/large.md" --max-lines 500 --max-bytes 1000000 --dry-run >"$tmp/msc-dry.out" 2>"$tmp/msc-dry.err"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "dry-run exit status was $status, expected 2"
grep -q '^candidate_created=false$' "$tmp/msc-dry.out" || fail "dry-run should not create candidate"
[[ -z "$(find "$msc_bl2/items/" -name '*.json' 2>/dev/null)" ]] || fail "dry-run should not create backlog files"

# Over bytes only
python3 -c "print('x' * 50000)" > "$msc_tmp/big.md"
set +e
./scripts/memory-size-check.sh --file "$msc_tmp/big.md" --max-lines 1000 --max-bytes 1000 --backlog-dir "$msc_bl" >"$tmp/msc-bytes.out" 2>"$tmp/msc-bytes.err"
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "over bytes exit status was $status, expected 2"
grep -q '^over_lines=false$' "$tmp/msc-bytes.out" || fail "over bytes should not be over lines"
grep -q '^over_bytes=true$' "$tmp/msc-bytes.out" || fail "over bytes should be over bytes"

# Duplicate candidate check: second call should not create another backlog item
msc_bl3="$msc_tmp/backlog3"
mkdir -p "$msc_bl3/items"
items_before=$(find "$msc_bl3/items/" -name '*.json' 2>/dev/null | wc -l)
set +e
BACKLOG_DIR="$msc_bl3" ./scripts/memory-size-check.sh --file "$msc_tmp/large.md" --max-lines 500 --max-bytes 1000000 >"$tmp/msc-dup1.out" 2>"$tmp/msc-dup1.err"
status=$?
set -e
items_after1=$(find "$msc_bl3/items/" -name '*.json' 2>/dev/null | wc -l)
[[ "$items_after1" -gt "$items_before" ]] || fail "first call should create candidate"
set +e
BACKLOG_DIR="$msc_bl3" ./scripts/memory-size-check.sh --file "$msc_tmp/large.md" --max-lines 500 --max-bytes 1000000 >"$tmp/msc-dup2.out" 2>"$tmp/msc-dup2.err"
status=$?
set -e
items_after2=$(find "$msc_bl3/items/" -name '*.json' 2>/dev/null | wc -l)
[[ "$items_after2" -eq "$items_after1" ]] || fail "second call should not create duplicate candidate"

log "all checks passed"

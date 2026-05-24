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
BACKLOG_DIR="$ta_backlog" MUTEX_DIR="$ta_mutex" ./scripts/task-release.sh >"$tmp/ta-release.out" 2>"$tmp/ta-release.err"
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

# Empty backlog + free mutex + no gh -> idle
mkdir -p "$na_tmp/items"
set +e
BACKLOG_DIR="$na_tmp" ./scripts/next-action.sh >"$tmp/na-idle.out" 2>"$tmp/na-idle.err"
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

log "all checks passed"

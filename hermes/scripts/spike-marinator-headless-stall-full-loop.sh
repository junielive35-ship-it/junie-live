#!/usr/bin/env bash
set -euo pipefail

# Spike: headless Marinator no-log-progress attention must not block supervision.
# Validates: silent OpenCode -> attention_required -> async resume starts ->
# supervisor still sees control/kill -> first job killed -> second job completes.

SPIKE_ID="full-loop-$(date -u +%Y%m%d%H%M%S)"
BASE="/tmp/marinator-full-loop-$SPIKE_ID"
HERMES_HOME_SPIKE="${HERMES_HOME:-/tmp/marinator-test-home-$SPIKE_ID}"
REPO="$BASE/repo"
BIN="$BASE/bin"
PROMPT1="$BASE/prompt1.md"
PROMPT2="$BASE/prompt2.md"
FAKE_OPENCODE="$BIN/fake-opencode"
FAKE_DATE="$BIN/date"
FAKE_HERMES="$BIN/hermes"
PLUGIN_DIR="${MARINATOR_PLUGIN_DIR:-/home/Danila.Savenkov/code/junie-live/hermes/initialization/plugins/marinator-delegation}"
PROFILE_STATE="$HERMES_HOME_SPIKE/profiles/junie-live/junie-live/state/marinator"
OWNER_SESSION_ID="spike-session-$SPIKE_ID"
JOB1="$SPIKE_ID-a"
JOB2="$SPIKE_ID-b"
RUN1="$PROFILE_STATE/runs/$JOB1"
RUN2="$PROFILE_STATE/runs/$JOB2"
SUMMARY="$BASE/summary.txt"

cleanup() {
  pkill -TERM -f "$SPIKE_ID" 2>/dev/null || true
  sleep 0.5
  pkill -KILL -f "$SPIKE_ID" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$REPO" "$BIN" "$HERMES_HOME_SPIKE"
printf '# fake repo for Marinator full-loop spike\n' > "$REPO/README.md"
printf '# Prompt 1\nSilent fake opencode should stall.\n' > "$PROMPT1"
printf '# Prompt 2\nFake opencode should complete quickly after restart.\n' > "$PROMPT2"

cat > "$FAKE_OPENCODE" <<'FAKEOPENCODE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "run" && "${2:-}" == "--help" ]]; then
  echo "Usage: fake-opencode run [--session ID] [--dangerously-skip-permissions] <prompt>"
  exit 0
fi
state_file="${FAKE_OPENCODE_STATE:?}"
count=0
[[ -f "$state_file" ]] && count=$(cat "$state_file")
count=$((count + 1))
echo "$count" > "$state_file"
if [[ "$count" -eq 1 ]]; then
  sleep 1200
else
  echo "Session: fake-session-$count"
  echo "fake opencode completed on restart count=$count"
  exit 0
fi
FAKEOPENCODE
chmod +x "$FAKE_OPENCODE"

cat > "$FAKE_DATE" <<'FAKEDATE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$#" -eq 1 && "$1" == "+%s" ]]; then
  state="${FAKE_DATE_STATE:-/tmp/fake-date-state}"
  if [[ -f "$state" ]]; then n=$(cat "$state"); else n=$(/usr/bin/date +%s); fi
  n=$((n + 1000))
  echo "$n" > "$state"
  echo "$n"
  exit 0
fi
exec /usr/bin/date "$@"
FAKEDATE
chmod +x "$FAKE_DATE"

cat > "$FAKE_HERMES" <<'FAKEHERMES'
#!/usr/bin/env bash
set -euo pipefail
log="${FAKE_HERMES_LOG:?}"
printf 'fake hermes invoked:' >>"$log"
printf ' %q' "$0" "$@" >>"$log"
printf '\n' >>"$log"
sleep 120
FAKEHERMES
chmod +x "$FAKE_HERMES"

start_job() {
  local job_id=$1 prompt=$2 out=$3
  HERMES_HOME="$HERMES_HOME_SPIKE" \
  HERMES_PROFILE=junie-live \
  HERMES_SESSION_ID="$OWNER_SESSION_ID" \
  OPENCODE_BIN="$FAKE_OPENCODE" \
  FAKE_OPENCODE_STATE="$BASE/fake-opencode-count" \
  FAKE_HERMES_LOG="$BASE/fake-hermes.log" \
  MARINATOR_FORCE_MODE=headless \
  PATH="$BIN:$PATH" \
  FAKE_DATE_STATE="$BASE/fake-date-state" \
  python3 - "$PLUGIN_DIR" "$job_id" "$REPO" "$prompt" > "$out" <<'PY'
import json, os, sys, importlib.util, types
plugin_dir, job_id, repo, prompt = sys.argv[1:]
pkg = types.ModuleType("marinator_delegation_spike")
pkg.__path__ = [plugin_dir]
pkg.__file__ = os.path.join(plugin_dir, "__init__.py")
sys.modules[pkg.__name__] = pkg
spec = importlib.util.spec_from_file_location(
    "marinator_delegation_spike.runner",
    os.path.join(plugin_dir, "runner.py"),
    submodule_search_locations=[plugin_dir],
)
runner = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = runner
spec.loader.exec_module(runner)
res = runner.start_job(job_id=job_id, repo=repo, prompt_file=prompt, attachments=[], opencode_previous_session_id=None, enable_per_minute_reports=False, ctx=None)
print(json.dumps(res, indent=2))
PY
}

wait_for_attention_resume() {
  local run_dir=$1 deadline=$(( $(/usr/bin/date +%s) + 60 ))
  while (( $(/usr/bin/date +%s) < deadline )); do
    if [[ -s "$run_dir/resume_attention_required.pid" ]] && python3 - "$run_dir/status.json" <<'PY' >/dev/null 2>&1
import json, sys
with open(sys.argv[1]) as f: s=json.load(f)
assert s.get('attention',{}).get('state') == 'suspected_stall'
assert s.get('attention',{}).get('reason') == 'no_log_progress'
PY
    then return 0; fi
    sleep 1
  done
  return 1
}

wait_for_terminal() {
  local run_dir=$1 want=$2 deadline=$(( $(/usr/bin/date +%s) + 60 ))
  while (( $(/usr/bin/date +%s) < deadline )); do
    if python3 - "$run_dir/status.json" "$want" <<'PY' >/dev/null 2>&1
import json, sys
with open(sys.argv[1]) as f: s=json.load(f)
assert s.get('worker_state') == sys.argv[2]
PY
    then return 0; fi
    sleep 1
  done
  return 1
}

start_job "$JOB1" "$PROMPT1" "$BASE/start1.json"
wait_for_attention_resume "$RUN1" && attention_resume=1 || attention_resume=0
mkdir -p "$RUN1/control"
touch "$RUN1/control/kill"
wait_for_terminal "$RUN1" killed && killed_seen=1 || killed_seen=0

start_job "$JOB2" "$PROMPT2" "$BASE/start2.json"
wait_for_terminal "$RUN2" completed && restart_completed=1 || restart_completed=0

{
  echo "SPIKE_ID=$SPIKE_ID"
  echo "BASE=$BASE"
  echo "HERMES_HOME_SPIKE=$HERMES_HOME_SPIKE"
  echo "RUN1=$RUN1"
  echo "RUN2=$RUN2"
  echo "ATTENTION_AND_RESUME=$attention_resume"
  echo "KILLED_SEEN=$killed_seen"
  echo "RESTART_COMPLETED=$restart_completed"
  echo "--- job1 status ---"
  python3 - "$RUN1/status.json" <<'PY' || true
import json, sys
with open(sys.argv[1]) as f: s=json.load(f)
print(json.dumps({'worker_state':s.get('worker_state'),'attention':s.get('attention'),'opencode':s.get('opencode')}, indent=2))
PY
  echo "--- job1 events ---"
  grep -E 'opencode_started|attention_required|headless_resume|terminate_requested|killed|failed|completed' "$RUN1/events.jsonl" || true
  echo "--- fake hermes log ---"
  cat "$BASE/fake-hermes.log" 2>/dev/null || true
  echo "--- job2 status ---"
  python3 - "$RUN2/status.json" <<'PY' || true
import json, sys
with open(sys.argv[1]) as f: s=json.load(f)
print(json.dumps({'worker_state':s.get('worker_state'),'attention':s.get('attention'),'opencode':s.get('opencode')}, indent=2))
PY
  echo "--- job2 result ---"
  tail -40 "$RUN2/result.md" 2>/dev/null || true
} | tee "$SUMMARY"

if [[ "$attention_resume" == 1 && "$killed_seen" == 1 && "$restart_completed" == 1 ]]; then
  echo "VERDICT=VALIDATED"
else
  echo "VERDICT=PARTIAL_OR_INVALIDATED"
  exit 1
fi

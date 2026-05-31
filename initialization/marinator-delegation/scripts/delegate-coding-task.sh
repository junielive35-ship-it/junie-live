#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: delegate-coding-task.sh --job <resolved-spec.json>

Runs a single Marinator delegated coding task with a bounded headless opencode
process and per-run supervision. The spec must already contain current delivery
and orchestrator session metadata; this script does not guess routing context.
USAGE
}

if [[ $# -ne 2 || "${1:-}" != "--job" ]]; then
  usage >&2
  exit 64
fi

spec_path=$2
if [[ ! -f "$spec_path" ]]; then
  echo "spec not found: $spec_path" >&2
  exit 66
fi

json_get() {
  local expr=$1
  python3 - "$spec_path" "$expr" <<'PY'
import json, sys
path, expr = sys.argv[1], sys.argv[2]
with open(path, 'r', encoding='utf-8') as fh:
    data = json.load(fh)
cur = data
for part in expr.split('.'):
    if not part:
        continue
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        cur = None
        break
if cur is None:
    sys.exit(1)
if isinstance(cur, (dict, list)):
    print(json.dumps(cur, ensure_ascii=False))
else:
    print(cur)
PY
}

json_get_default() {
  local expr=$1
  local default=$2
  json_get "$expr" 2>/dev/null || printf '%s\n' "$default"
}

job_id=$(json_get 'job_id')
repo=$(json_get 'repo')
prompt_file=$(json_get 'prompt_file')
run_dir=$(json_get 'run_dir')
summary_model=$(json_get_default 'summary_model' 'openrouter/openai/gpt-4.1-mini')
update_interval_seconds=$(json_get_default 'update_interval_seconds' '300')
no_progress_seconds=$(json_get_default 'no_progress_seconds' '900')
timeout_seconds=$(json_get_default 'timeout_seconds' '7200')
orchestrator_session_key=$(json_get 'orchestrator_session_key')
delivery_channel=$(json_get 'delivery.channel')
delivery_target=$(json_get 'delivery.target')
delivery_thread_id=$(json_get_default 'delivery.thread_id' '')
delivery_account_id=$(json_get_default 'delivery.account_id' '')
opencode_previous_session_id=$(json_get_default 'opencode_previous_session_id' '')
OPENCODE_BIN=${OPENCODE_BIN:-}
if [[ -z "$OPENCODE_BIN" ]]; then
  if command -v opencode >/dev/null 2>&1; then
    OPENCODE_BIN=$(command -v opencode)
  elif [[ -x "$HOME/.opencode/bin/opencode" ]]; then
    OPENCODE_BIN="$HOME/.opencode/bin/opencode"
  else
    OPENCODE_BIN=opencode
  fi
fi

stdout_log="$run_dir/opencode.stdout.log"
stderr_log="$run_dir/opencode.stderr.log"
runner_log="$run_dir/runner.log"
status_path="$run_dir/status.json"
events_path="$run_dir/events.jsonl"
result_path="$run_dir/result.md"
control_dir="$run_dir/control"
pid_path="$run_dir/opencode.pid"
pgid_path="$run_dir/opencode.pgid"
exit_path="$run_dir/opencode.exit"
waiter_pid_path="$run_dir/opencode-waiter.pid"

mkdir -p "$run_dir" "$control_dir"
touch "$stdout_log" "$stderr_log" "$runner_log" "$events_path"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

append_event() {
  local event=$1
  shift
  python3 - "$events_path" "$event" "$job_id" "$@" <<'PYEVENT'
import json, sys, datetime
path, event, job_id, *items = sys.argv[1:]
detail = {}
for i in range(0, len(items), 2):
    value = items[i + 1]
    if value.lstrip('-').isdigit():
        value = int(value)
    detail[items[i]] = value
record = {"ts": datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), "event": event, "job_id": job_id}
record.update(detail)
with open(path, 'a', encoding='utf-8') as fh:
    fh.write(json.dumps(record, ensure_ascii=False) + '\n')
PYEVENT
}

write_status() {
  local state=$1
  shift
  python3 - "$status_path" "$state" "$job_id" "$@" <<'PYSTATUS'
import json, sys, datetime
path, state, job_id, *items = sys.argv[1:]
detail = {}
for i in range(0, len(items), 2):
    value = items[i + 1]
    if value.lstrip('-').isdigit():
        value = int(value)
    detail[items[i]] = value
record = {
  "job_id": job_id,
  "state": state,
  "updated_at": datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
}
record.update(detail)
with open(path, 'w', encoding='utf-8') as fh:
    json.dump(record, fh, ensure_ascii=False, indent=2)
    fh.write('\n')
PYSTATUS
}

update_status_json() {
  local updates_json=$1
  python3 - "$status_path" "$updates_json" <<'PYSTATUSUPDATE'
import json, sys, datetime
path, updates_raw = sys.argv[1:]
now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
try:
    with open(path, 'r', encoding='utf-8') as fh:
        record = json.load(fh)
except FileNotFoundError:
    record = {}
updates = json.loads(updates_raw)
record.update(updates)
record['updated_at'] = now
with open(path, 'w', encoding='utf-8') as fh:
    json.dump(record, fh, ensure_ascii=False, indent=2)
    fh.write('\n')
PYSTATUSUPDATE
}

set_handoff_pending() {
  update_status_json "$(python3 - "$orchestrator_session_key" <<'PY'
import json, sys
print(json.dumps({"handoff": {
  "state": "pending",
  "session_key": sys.argv[1],
  "schedule_job_id": None,
  "scheduled_at": None,
  "consumed_by_run_id": None,
  "consumed_at": None,
  "last_error": None,
}}))
PY
)"
  append_event "handoff_pending" session_key "$orchestrator_session_key"
}

extract_cron_job_id() {
  python3 - <<'PY'
import json, os
raw = os.environ.get("CRON_OUTPUT", "")
# The CLI can print warnings before the JSON object. Decode the last valid JSON
# object/array found in the output instead of assuming stdout is pure JSON.
for start in [idx for idx, ch in enumerate(raw) if ch in "{"] [::-1]:
    try:
        data = json.loads(raw[start:])
        break
    except Exception:
        data = None
else:
    data = None
if not isinstance(data, dict):
    print("")
    raise SystemExit
for key in ("id", "job_id", "jobId"):
    value = data.get(key)
    if value:
        print(value)
        raise SystemExit
job = data.get("job")
if isinstance(job, dict):
    print(job.get("id") or job.get("job_id") or job.get("jobId") or "")
else:
    print("")
PY
}

schedule_continuation() {
  local continuation_at continuation_timeout_seconds message cron_output cron_status schedule_job_id scheduled_at
  continuation_at="5s"
  continuation_timeout_seconds=300
  scheduled_at=$(now_iso)
  message="Marinator job $job_id finished. Read $status_path and $result_path, inspect the repo diff, and continue the review/fix/acceptance loop. Do not report success unless the requested user outcome is verified or explicitly blocked."
  set +e
  cron_output=$(openclaw cron add \
    --name "marinator-continuation-$job_id" \
    --at "$continuation_at" \
    --session main \
    --session-key "$orchestrator_session_key" \
    --system-event "$message" \
    --timeout-seconds "$continuation_timeout_seconds" \
    --no-deliver \
    --delete-after-run \
    --json 2>&1)
  cron_status=$?
  set -e
  if [[ "$cron_status" -eq 0 ]]; then
    schedule_job_id=$(CRON_OUTPUT="$cron_output" extract_cron_job_id)
    if [[ -z "$schedule_job_id" ]]; then
      update_status_json "$(python3 - "$orchestrator_session_key" "$cron_output" <<'PY'
import json, sys
session_key, error = sys.argv[1:]
print(json.dumps({"handoff": {
  "state": "failed",
  "session_key": session_key,
  "schedule_job_id": None,
  "scheduled_at": None,
  "consumed_by_run_id": None,
  "consumed_at": None,
  "last_error": ("cron add succeeded but job id could not be parsed: " + error)[-2000:],
}}))
PY
)"
      append_event "handoff_schedule_id_missing" session_key "$orchestrator_session_key" error "$cron_output"
      return
    fi
    update_status_json "$(python3 - "$orchestrator_session_key" "$schedule_job_id" "$scheduled_at" <<'PY'
import json, sys
session_key, schedule_job_id, scheduled_at = sys.argv[1:]
print(json.dumps({"handoff": {
  "state": "scheduled",
  "session_key": session_key,
  "schedule_job_id": schedule_job_id,
  "scheduled_at": scheduled_at,
  "consumed_by_run_id": None,
  "consumed_at": None,
  "last_error": None,
}}))
PY
)"
    append_event "handoff_scheduled" session_key "$orchestrator_session_key" schedule_job_id "$schedule_job_id"
  else
    update_status_json "$(python3 - "$orchestrator_session_key" "$cron_output" <<'PY'
import json, sys
session_key, error = sys.argv[1:]
print(json.dumps({"handoff": {
  "state": "failed",
  "session_key": session_key,
  "schedule_job_id": None,
  "scheduled_at": None,
  "consumed_by_run_id": None,
  "consumed_at": None,
  "last_error": error[-2000:],
}}))
PY
)"
    append_event "handoff_schedule_failed" session_key "$orchestrator_session_key" error "$cron_output"
  fi
}

# DEBUG-ONLY (TEMPORARY): The runner must talk ONLY to the orchestrator, never
# directly to the end user. These direct send_telegram calls are a temporary
# debug aid and violate that invariant. The durable design routes all worker
# progress/terminal events to the orchestrator via wake_marinator (system
# event); the orchestrator is the sole party that messages the user. Remove
# every send_telegram call once the orchestrator-driven delivery path is final.
send_telegram() {
  local message=$1
  local args=(message send --channel "$delivery_channel" --target "$delivery_target" --message "$message")
  if [[ -n "$delivery_thread_id" ]]; then
    args+=(--thread-id "$delivery_thread_id")
  fi
  if [[ -n "$delivery_account_id" ]]; then
    args+=(--account "$delivery_account_id")
  fi
  if ! openclaw "${args[@]}" >>"$runner_log" 2>&1; then
    append_event "telegram_send_failed" message "$message"
  fi
}

wake_marinator() {
  local event=$1
  local message=$2
  local text="Marinator worker event: $event
job_id: $job_id
status: $event
result_path: ${result_path:-$run_dir/result.md}
run_dir: $run_dir
$message

Orchestrator: review result_path and the repo diff, then either re-delegate a fix or report the outcome to the user."
  if ! openclaw system event --session-key "$orchestrator_session_key" --mode now --text "$text" >>"$runner_log" 2>&1; then
    append_event "marinator_wake_failed" event "$event" message "$message"
  fi
}

terminal_handoff_done=0
terminal_handoff() {
  local event=$1
  local message=$2
  if [[ "$terminal_handoff_done" -eq 0 ]]; then
    terminal_handoff_done=1
    set_handoff_pending
    schedule_continuation
  fi
  wake_marinator "$event" "$message"
}

# Terminal states never need a stale-running rescue from the exit trap.
TERMINAL_STATES_RE='^(completed|failed|timeout|killed|stalled)$'

current_state() {
  python3 - "$status_path" 2>/dev/null <<'PYSTATE' || true
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as fh:
        print(json.load(fh).get('state', ''))
except Exception:
    pass
PYSTATE
}

# Guarantee status.json is never left as a non-terminal state after the runner
# exits for any reason we can trap (normal exit, error, or a catchable signal).
# Without this, a runner/waiter that dies unexpectedly leaves status "running"
# forever and Marinator is never woken.
on_runner_exit() {
  local rc=$?
  trap - EXIT INT TERM HUP
  local state
  state=$(current_state)
  if [[ ! "$state" =~ $TERMINAL_STATES_RE ]]; then
    # Best-effort: avoid orphaning the opencode process group.
    if [[ -n "${opencode_pgid:-}" ]]; then
      kill -TERM -- "-$opencode_pgid" 2>/dev/null || true
    fi
    write_status "failed" reason runner_exited_unexpectedly exit_code "$rc" || true
    append_event "failed" reason runner_exited_unexpectedly exit_code "$rc" || true
    terminal_handoff "failed" "runner exited unexpectedly (rc=$rc) without a terminal status; treating worker as failed" || true
  fi
  exit "$rc"
}

summarize_delta() {
  local stdout_offset_file="$run_dir/.summary.stdout.offset"
  local stderr_offset_file="$run_dir/.summary.stderr.offset"
  local stdout_size stderr_size previous_stdout_size previous_stderr_size delta_file context_file summary_prompt summary_json summary change_note
  stdout_size=$(wc -c < "$stdout_log" | tr -d ' ')
  stderr_size=$(wc -c < "$stderr_log" | tr -d ' ')
  previous_stdout_size=0
  previous_stderr_size=0
  [[ -f "$stdout_offset_file" ]] && previous_stdout_size=$(cat "$stdout_offset_file" 2>/dev/null || echo 0)
  [[ -f "$stderr_offset_file" ]] && previous_stderr_size=$(cat "$stderr_offset_file" 2>/dev/null || echo 0)
  delta_file="$run_dir/.summary.delta"
  context_file="$run_dir/.summary.context"
  if (( stdout_size <= previous_stdout_size && stderr_size <= previous_stderr_size )); then
    change_note="No new stdout or stderr bytes since the previous summary interval. Say that nothing changed if the supporting context also shows no movement."
    : > "$delta_file"
  else
    change_note="New stdout/stderr output appeared since the previous summary interval."
    {
      if (( stdout_size > previous_stdout_size )); then
        printf '## stdout delta\n'
        tail -c +$((previous_stdout_size + 1)) "$stdout_log"
        printf '\n'
      fi
      if (( stderr_size > previous_stderr_size )); then
        printf '## stderr delta\n'
        tail -c +$((previous_stderr_size + 1)) "$stderr_log"
        printf '\n'
      fi
    } | tail -c 12000 > "$delta_file"
  fi
  printf '%s\n' "$stdout_size" > "$stdout_offset_file"
  printf '%s\n' "$stderr_size" > "$stderr_offset_file"
  {
    printf '## change note\n%s\n\n' "$change_note"
    printf '## status.json\n'
    tail -c 4000 "$status_path" 2>/dev/null || true
    printf '\n\n## recent events.jsonl\n'
    tail -n 40 "$events_path" 2>/dev/null || true
    printf '\n\n## runner.log tail\n'
    tail -n 80 "$runner_log" 2>/dev/null || true
    printf '\n\n## stdout/stderr delta\n'
    cat "$delta_file" 2>/dev/null || true
    printf '\n\n## stdout tail\n'
    tail -n 80 "$stdout_log" 2>/dev/null || true
    printf '\n\n## stderr tail\n'
    tail -n 120 "$stderr_log" 2>/dev/null || true
  } | tail -c 24000 > "$context_file"
  summary_prompt=$(cat <<PROMPT
Summarize this Marinator/opencode worker state for a Telegram debug progress update.
Use the provided status, events, runner log, stdout, and stderr. Focus on worker actions and critical errors/blockers.
Be concise, factual, under 700 characters. If the change note says there was no new stdout/stderr and the context shows no other movement, explicitly say nothing changed and that the worker still appears to be running.
Job: $job_id

Worker context:
$(cat "$context_file")
PROMPT
)
  if summary_json=$(openclaw infer model run --gateway --model "$summary_model" --json --prompt "$summary_prompt" 2>>"$runner_log"); then
    summary=$(python3 -c 'import json,sys
raw=sys.stdin.read()
try:
    data=json.loads(raw)
    text=data.get("text") or data.get("content") or data.get("message")
    if not text and isinstance(data.get("outputs"), list) and data["outputs"]:
        first=data["outputs"][0]
        if isinstance(first, dict):
            text=first.get("text") or first.get("content") or first.get("message")
    print((text or raw)[:700])
except Exception:
    print(raw[:700])' <<<"$summary_json")
  else
    if [[ -s "$delta_file" ]]; then
      summary="Marinator worker $job_id: opencode is still running; new log output was produced, but summary generation failed."
    else
      summary="Marinator worker $job_id: opencode is still running; nothing changed since the previous debug update, and summary generation failed."
    fi
  fi
  send_telegram "$summary" # DEBUG-ONLY (TEMPORARY): runner->user; should be a wake to the orchestrator instead
  append_event "progress_summary_sent" summary "$summary" stdout_bytes "$stdout_size" stderr_bytes "$stderr_size"
}

terminate_group() {
  local pgid=$1
  append_event "terminate_requested" pgid "$pgid"
  kill -TERM -- "-$pgid" 2>/dev/null || true
  sleep 10
  kill -KILL -- "-$pgid" 2>/dev/null || true
}

build_opencode_args() {
  local prompt help_text
  prompt=$(cat "$prompt_file")
  OPENCODE_ARGS=(run)
  help_text=$("$OPENCODE_BIN" run --help 2>&1 || true)
  OPENCODE_ARGS+=(--dangerously-skip-permissions)
  if [[ -n "$opencode_previous_session_id" && "$opencode_previous_session_id" != "null" ]]; then
    if grep -q -- '--session' <<<"$help_text"; then
      OPENCODE_ARGS+=(--session "$opencode_previous_session_id")
    elif grep -q -- '--resume' <<<"$help_text"; then
      OPENCODE_ARGS+=(--resume "$opencode_previous_session_id")
    else
      write_status "failed" reason opencode_resume_not_supported
      append_event "failed" reason opencode_resume_not_supported
      terminal_handoff "failed" "opencode_previous_session_id was provided, but this opencode CLI exposes no --session/--resume option"
      exit 70
    fi
  fi
  OPENCODE_ARGS+=("$prompt")
}

if [[ ! -d "$repo" ]]; then
  write_status "failed" reason repo_not_found repo "$repo"
  append_event "failed" reason repo_not_found repo "$repo"
  terminal_handoff "failed" "repo not found"
  exit 66
fi
if [[ ! -f "$prompt_file" ]]; then
  write_status "failed" reason prompt_file_not_found prompt_file "$prompt_file"
  append_event "failed" reason prompt_file_not_found prompt_file "$prompt_file"
  terminal_handoff "failed" "prompt file not found"
  exit 66
fi
if ! command -v "$OPENCODE_BIN" >/dev/null 2>&1 && [[ ! -x "$OPENCODE_BIN" ]]; then
  write_status "failed" reason opencode_not_found
  append_event "failed" reason opencode_not_found
  terminal_handoff "failed" "opencode binary not found in PATH"
  exit 69
fi

build_opencode_args
write_status "running" started_at "$(now_iso)"
append_event "started" repo "$repo" prompt_file "$prompt_file"

# From here on, a non-terminal status must never survive runner exit.
opencode_pgid=""
trap on_runner_exit EXIT INT TERM HUP

(
  # Record opencode.exit even if opencode exits non-zero, the wait is
  # interrupted, or this subshell dies for another reason. errexit (inherited
  # from the parent) would otherwise abort the subshell on a non-zero wait
  # before the exit code is written, leaving the supervisor with stale state.
  trap 'rc=$?; [[ -f "$exit_path" ]] || echo "$rc" > "$exit_path"' EXIT
  cd "$repo"
  setsid "$OPENCODE_BIN" "${OPENCODE_ARGS[@]}" >"$stdout_log" 2>"$stderr_log" &
  opencode_pid=$!
  echo "$opencode_pid" > "$pid_path"
  set +e
  wait "$opencode_pid"
  opencode_status=$?
  set -e
  echo "$opencode_status" > "$exit_path"
) &
waiter_pid=$!
echo "$waiter_pid" > "$waiter_pid_path"
opencode_pid=""
for _ in $(seq 1 50); do
  if [[ -s "$pid_path" ]]; then
    opencode_pid=$(cat "$pid_path")
    break
  fi
  sleep 0.1
done
if [[ -z "$opencode_pid" ]]; then
  write_status "failed" reason opencode_pid_not_recorded
  append_event "failed" reason opencode_pid_not_recorded
  terminal_handoff "failed" "opencode process did not record a pid"
  exit 70
fi
opencode_pgid=$opencode_pid
echo "$opencode_pgid" > "$pgid_path"
append_event "opencode_started" pid "$opencode_pid" pgid "$opencode_pgid"

start_epoch=$(date +%s)
last_summary_epoch=$start_epoch
last_progress_epoch=$start_epoch
last_stdout_size=0
last_stderr_size=0
exit_code=""

while [[ ! -f "$exit_path" ]] && kill -0 "$waiter_pid" 2>/dev/null; do
  now_epoch=$(date +%s)
  current_stdout_size=$(wc -c < "$stdout_log" | tr -d ' ')
  current_stderr_size=$(wc -c < "$stderr_log" | tr -d ' ')
  if (( current_stdout_size > last_stdout_size || current_stderr_size > last_stderr_size )); then
    last_stdout_size=$current_stdout_size
    last_stderr_size=$current_stderr_size
    last_progress_epoch=$now_epoch
  fi
  if [[ -f "$control_dir/kill" ]]; then
    write_status "killing" reason control_kill
    terminate_group "$opencode_pgid"
    wait "$waiter_pid" 2>/dev/null || true
    write_status "killed" reason control_kill
    append_event "killed" reason control_kill
    terminal_handoff "killed" "worker killed by Marinator control file"
    exit 130
  fi
  if (( now_epoch - start_epoch >= timeout_seconds )); then
    write_status "timeout" reason timeout
    terminate_group "$opencode_pgid"
    wait "$waiter_pid" 2>/dev/null || true
    append_event "timeout" reason timeout
    send_telegram "Marinator worker $job_id timed out and was stopped." # DEBUG-ONLY (TEMPORARY): runner->user; wake the orchestrator instead
    terminal_handoff "timeout" "worker timed out and was stopped"
    exit 124
  fi
  if (( now_epoch - last_progress_epoch >= no_progress_seconds )); then
    write_status "stalled" reason no_progress
    terminate_group "$opencode_pgid"
    wait "$waiter_pid" 2>/dev/null || true
    append_event "stalled" reason no_progress
    send_telegram "Marinator worker $job_id appears stalled with no log progress and was stopped." # DEBUG-ONLY (TEMPORARY): runner->user; wake the orchestrator instead
    terminal_handoff "stalled" "no log progress before no_progress timeout"
    exit 125
  fi
  if (( now_epoch - last_summary_epoch >= update_interval_seconds )); then
    summarize_delta || true
    last_summary_epoch=$now_epoch
  fi
  sleep 5
done

if [[ -f "$exit_path" ]]; then
  exit_code=$(cat "$exit_path")
else
  set +e
  wait "$waiter_pid"
  waiter_status=$?
  set -e
  if [[ -f "$exit_path" ]]; then
    exit_code=$(cat "$exit_path")
  else
    # The waiter disappeared without recording opencode.exit (e.g. it was
    # SIGKILLed). Do not pretend the worker succeeded: fall back to the waiter
    # status and force a non-zero failure code if it looked clean.
    exit_code=$waiter_status
    if [[ "$exit_code" -eq 0 ]]; then
      exit_code=70
    fi
    append_event "waiter_exited_without_opencode_exit" waiter_status "$waiter_status" exit_code "$exit_code"
  fi
fi
# Guard against a corrupt/empty opencode.exit so the numeric comparison below
# (and the exit trap) cannot misfire under errexit.
if ! [[ "$exit_code" =~ ^-?[0-9]+$ ]]; then
  append_event "opencode_exit_unreadable" raw_exit "$exit_code"
  exit_code=70
fi
summarize_delta || true

if [[ "$exit_code" -eq 0 ]]; then
  {
    echo "# Marinator worker result"
    echo
    echo "- job_id: $job_id"
    echo "- completed_at: $(now_iso)"
    echo "- exit_code: 0"
    echo
    echo "## stdout tail"
    echo '```'
    tail -n 80 "$stdout_log"
    echo '```'
    echo
    echo "## stderr tail"
    echo '```'
    tail -n 120 "$stderr_log"
    echo '```'
  } > "$result_path"
  write_status "completed" exit_code "$exit_code" result_path "$result_path"
  append_event "completed" exit_code "$exit_code" result_path "$result_path"
  terminal_handoff "completed" "worker exited successfully; review result and diff"
  exit 0
fi

write_status "failed" exit_code "$exit_code"
append_event "failed" exit_code "$exit_code"
send_telegram "Marinator worker $job_id failed with exit code $exit_code." # DEBUG-ONLY (TEMPORARY): runner->user; wake the orchestrator instead
terminal_handoff "failed" "worker exited with code $exit_code"
exit "$exit_code"

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
summary_model=$(json_get_default 'summary_model' 'openai/gpt-4.1-mini')
update_interval_seconds=$(json_get_default 'update_interval_seconds' '300')
no_progress_seconds=$(json_get_default 'no_progress_seconds' '900')
timeout_seconds=$(json_get_default 'timeout_seconds' '7200')
orchestrator_session_key=$(json_get 'orchestrator_session_key')
delivery_channel=$(json_get 'delivery.channel')
delivery_target=$(json_get 'delivery.target')
delivery_thread_id=$(json_get_default 'delivery.thread_id' '')
delivery_account_id=$(json_get_default 'delivery.account_id' '')
opencode_previous_session_id=$(json_get_default 'opencode_previous_session_id' '')

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
  local text="Marinator worker event: $event\njob_id: $job_id\nrun_dir: $run_dir\n$message"
  if ! openclaw system event --session-key "$orchestrator_session_key" --mode now --text "$text" >>"$runner_log" 2>&1; then
    append_event "marinator_wake_failed" event "$event" message "$message"
  fi
}

summarize_delta() {
  local offset_file="$run_dir/.summary.offset"
  local current_size previous_size delta_file summary_prompt summary_json summary
  current_size=$(wc -c < "$stdout_log" | tr -d ' ')
  previous_size=0
  [[ -f "$offset_file" ]] && previous_size=$(cat "$offset_file" 2>/dev/null || echo 0)
  if (( current_size <= previous_size )); then
    return 0
  fi
  delta_file="$run_dir/.summary.delta"
  tail -c +$((previous_size + 1)) "$stdout_log" | tail -c 12000 > "$delta_file"
  printf '%s\n' "$current_size" > "$offset_file"
  summary_prompt=$(cat <<PROMPT
Summarize this opencode worker log delta for a Telegram progress update.
Be concise, factual, under 700 characters. Mention current action, files/tests if visible, and blockers if any.
Job: $job_id

Log delta:
$(cat "$delta_file")
PROMPT
)
  if summary_json=$(openclaw infer model run --gateway --model "$summary_model" --json --prompt "$summary_prompt" 2>>"$runner_log"); then
    summary=$(python3 -c 'import json,sys; raw=sys.stdin.read();
try:
 data=json.loads(raw); print(data.get("text") or data.get("content") or data.get("message") or raw[:700])
except Exception: print(raw[:700])' <<<"$summary_json")
  else
    summary="Marinator worker $job_id: opencode is still running; new log output was produced in the last interval."
  fi
  send_telegram "$summary"
  append_event "progress_summary_sent" summary "$summary"
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
  if [[ -n "$opencode_previous_session_id" && "$opencode_previous_session_id" != "null" ]]; then
    help_text=$(opencode run --help 2>/dev/null || true)
    if grep -q -- '--session' <<<"$help_text"; then
      OPENCODE_ARGS+=(--session "$opencode_previous_session_id")
    elif grep -q -- '--resume' <<<"$help_text"; then
      OPENCODE_ARGS+=(--resume "$opencode_previous_session_id")
    else
      write_status "failed" reason opencode_resume_not_supported
      append_event "failed" reason opencode_resume_not_supported
      wake_marinator "failed" "opencode_previous_session_id was provided, but this opencode CLI exposes no --session/--resume option"
      exit 70
    fi
  fi
  OPENCODE_ARGS+=("$prompt")
}

if [[ ! -d "$repo" ]]; then
  write_status "failed" reason repo_not_found repo "$repo"
  append_event "failed" reason repo_not_found repo "$repo"
  wake_marinator "failed" "repo not found"
  exit 66
fi
if [[ ! -f "$prompt_file" ]]; then
  write_status "failed" reason prompt_file_not_found prompt_file "$prompt_file"
  append_event "failed" reason prompt_file_not_found prompt_file "$prompt_file"
  wake_marinator "failed" "prompt file not found"
  exit 66
fi
if ! command -v opencode >/dev/null 2>&1; then
  write_status "failed" reason opencode_not_found
  append_event "failed" reason opencode_not_found
  wake_marinator "failed" "opencode binary not found in PATH"
  exit 69
fi

build_opencode_args
write_status "running" started_at "$(now_iso)"
append_event "started" repo "$repo" prompt_file "$prompt_file"

(
  cd "$repo"
  setsid opencode "${OPENCODE_ARGS[@]}" >"$stdout_log" 2>"$stderr_log" &
  opencode_pid=$!
  echo "$opencode_pid" > "$pid_path"
  wait "$opencode_pid"
  echo $? > "$exit_path"
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
  wake_marinator "failed" "opencode process did not record a pid"
  exit 70
fi
opencode_pgid=$opencode_pid
echo "$opencode_pgid" > "$pgid_path"
append_event "opencode_started" pid "$opencode_pid" pgid "$opencode_pgid"

start_epoch=$(date +%s)
last_summary_epoch=$start_epoch
last_progress_epoch=$start_epoch
last_size=0
exit_code=""

while [[ ! -f "$exit_path" ]] && kill -0 "$waiter_pid" 2>/dev/null; do
  now_epoch=$(date +%s)
  current_size=$(wc -c < "$stdout_log" | tr -d ' ')
  if (( current_size > last_size )); then
    last_size=$current_size
    last_progress_epoch=$now_epoch
  fi
  if [[ -f "$control_dir/kill" ]]; then
    write_status "killing" reason control_kill
    terminate_group "$opencode_pgid"
    wait "$waiter_pid" 2>/dev/null || true
    write_status "killed" reason control_kill
    append_event "killed" reason control_kill
    wake_marinator "killed" "worker killed by Marinator control file"
    exit 130
  fi
  if (( now_epoch - start_epoch >= timeout_seconds )); then
    write_status "timeout" reason timeout
    terminate_group "$opencode_pgid"
    wait "$waiter_pid" 2>/dev/null || true
    append_event "timeout" reason timeout
    send_telegram "Marinator worker $job_id timed out and was stopped."
    wake_marinator "timeout" "worker timed out and was stopped"
    exit 124
  fi
  if (( now_epoch - last_progress_epoch >= no_progress_seconds )); then
    write_status "stalled" reason no_progress
    terminate_group "$opencode_pgid"
    wait "$waiter_pid" 2>/dev/null || true
    append_event "stalled" reason no_progress
    send_telegram "Marinator worker $job_id appears stalled with no log progress and was stopped."
    wake_marinator "stalled" "no log progress before no_progress timeout"
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
    exit_code=$waiter_status
  fi
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
  } > "$result_path"
  write_status "completed" exit_code "$exit_code" result_path "$result_path"
  append_event "completed" exit_code "$exit_code" result_path "$result_path"
  wake_marinator "completed" "worker exited successfully; review result and diff"
  exit 0
fi

write_status "failed" exit_code "$exit_code"
append_event "failed" exit_code "$exit_code"
send_telegram "Marinator worker $job_id failed with exit code $exit_code."
wake_marinator "failed" "worker exited with code $exit_code"
exit "$exit_code"

#!/usr/bin/env bash
set -euo pipefail

# marinator-worker.sh — Hermes Marinator wrapper for OpenCode delegation
#
# Reads spec.json from MARINATOR_RUN_DIR / MARINATOR_SPEC_PATH, runs OpenCode
# with supervision, captures logs, monitors progress, detects stalls (without
# killing), emits marker lines, writes result.md, and wakes the orchestrator
# via notify_on_complete (live) or hermes chat --resume (headless).
#
# Environment:
#   MARINATOR_RUN_DIR   — durable run directory
#   MARINATOR_JOB_ID    — job identifier
#   MARINATOR_SPEC_PATH — path to spec.json

# ── Validate environment ──

if [[ -z "${MARINATOR_RUN_DIR:-}" ]]; then
  echo "ERROR: MARINATOR_RUN_DIR not set" >&2
  exit 64
fi
if [[ -z "${MARINATOR_JOB_ID:-}" ]]; then
  echo "ERROR: MARINATOR_JOB_ID not set" >&2
  exit 64
fi

run_dir="$MARINATOR_RUN_DIR"
job_id="$MARINATOR_JOB_ID"
spec_path="${MARINATOR_SPEC_PATH:-$run_dir/spec.json}"

if [[ ! -f "$spec_path" ]]; then
  echo "ERROR: spec.json not found: $spec_path" >&2
  exit 66
fi

# ── JSON helpers ──

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
  json_get "$expr" 2>/dev/null || printf '%s' "$default"
}

# ── Read spec ──

repo=$(json_get 'repo')
prompt_file=$(json_get 'prompt_file')
opencode_bin=$(json_get 'opencode_bin')
runtime_mode=$(json_get_default 'runtime_mode' 'headless')
owner_session_id=$(json_get_default 'owner_session_id' '')
hermes_profile=$(json_get_default 'hermes_profile' 'junie-live')
enable_per_minute_reports=$(json_get_default 'enable_per_minute_reports' 'false')
opencode_previous_session_id=$(json_get_default 'opencode_previous_session_id' '')
progress_delivery_enabled=$(json_get_default 'progress_delivery.enabled' 'false')
progress_delivery_profile=$(json_get_default 'progress_delivery.profile' "$hermes_profile")
progress_delivery_target=$(json_get_default 'progress_delivery.target' '')

# OpenCode unattended mode: allow every permission class and every external
# directory. `--dangerously-skip-permissions` only auto-approves permissions
# that are not explicitly denied/asked by config; this runtime override makes
# delegated Marinator workers genuinely headless.
export OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow","external_directory":{"/**":"allow"}}}'

# Tuning: intervals in seconds
update_interval_seconds=60
no_progress_seconds=900

# ── Paths ──

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

mkdir -p "$run_dir" "$control_dir" "$run_dir/locks"
touch "$stdout_log" "$stderr_log" "$runner_log" "$events_path"

# ── Utility functions ──

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log_runner() {
  printf '%s %s\n' "$(now_iso)" "$*" >> "$runner_log"
}

append_event() {
  local event=$1
  shift
  python3 - "$events_path" "$event" "$job_id" "$@" <<'PYEVENT'
import json, sys, datetime
path, event, job_id = sys.argv[1], sys.argv[2], sys.argv[3]
items = sys.argv[4:]
detail = {}
for i in range(0, len(items), 2):
    if i + 1 < len(items):
        value = items[i + 1]
        if value.lstrip('-').isdigit():
            value = int(value)
        detail[items[i]] = value
record = {
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    "type": event,
    "job_id": job_id,
}
record.update(detail)
with open(path, 'a', encoding='utf-8') as fh:
    fh.write(json.dumps(record, ensure_ascii=False) + '\n')
PYEVENT
}

update_status_json() {
  local updates_json=$1
  python3 - "$status_path" "$updates_json" <<'PYUPDATE'
import json, sys, datetime
path, updates_raw = sys.argv[1], sys.argv[2]
now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
try:
    with open(path, 'r', encoding='utf-8') as fh:
        record = json.load(fh)
except (FileNotFoundError, json.JSONDecodeError):
    record = {}
updates = json.loads(updates_raw)
for key, value in updates.items():
    parts = key.split('.')
    target = record
    for part in parts[:-1]:
        if part not in target or not isinstance(target[part], dict):
            target[part] = {}
        target = target[part]
    target[parts[-1]] = value
record['updated_at'] = now
with open(path, 'w', encoding='utf-8') as fh:
    json.dump(record, fh, ensure_ascii=False, indent=2)
    fh.write('\n')
PYUPDATE
}

# Exactly-once marker: returns 0 if this call created it, 1 if already exists
marker_once() {
  local marker_name=$1
  local marker_path="$run_dir/locks/wake.$marker_name"
  if (set -C; echo "$(date +%s)" > "$marker_path") 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

# ── Progress delivery (optional per-minute reports) ──

send_progress() {
  local message=$1
  if [[ "$enable_per_minute_reports" != "true" ]]; then
    return 0
  fi
  if [[ "$progress_delivery_enabled" != "true" && "$progress_delivery_enabled" != "True" ]]; then
    append_event "progress_send_skipped" reason "delivery_not_enabled" summary "$message"
    return 0
  fi
  if [[ -z "$progress_delivery_target" ]]; then
    append_event "progress_send_skipped" reason "missing_runtime_delivery_context"
    return 0
  fi

  # Send through profile-aware Hermes child process
  local profile="${progress_delivery_profile:-$hermes_profile}"
  if command -v hermes >/dev/null 2>&1; then
    if ! hermes -p "$profile" chat -Q -t messaging \
      -q "Use send_message to send this exact message to target $progress_delivery_target: $message. Then reply only SEND_DONE." \
      >>"$runner_log" 2>&1; then
      append_event "progress_send_failed" target "$progress_delivery_target" summary "$message"
    fi
  else
    append_event "progress_send_skipped" reason "hermes_not_in_path"
  fi
}

# ── Headless resume helper ──

headless_resume() {
  local event=$1
  local wake_message="${2:-}"

  if [[ "$runtime_mode" != "headless" ]]; then
    return 0
  fi
  if [[ -z "$owner_session_id" ]]; then
    log_runner "headless_resume: no owner_session_id, skipping"
    append_event "headless_resume_skipped" reason "no_owner_session_id" event "$event"
    return 0
  fi

  # Exactly-once guard
  if ! marker_once "resume_$event"; then
    log_runner "headless_resume: marker resume_$event already exists, skipping duplicate"
    return 0
  fi

  # Session lock
  local lock_dir
  lock_dir="$(dirname "$(dirname "$run_dir")")/../owner-session-locks"
  mkdir -p "$lock_dir"
  local lock_file="$lock_dir/${owner_session_id}.lock"

  local resume_prompt="Marinator worker job_id=$job_id reached state=$event. run_dir=$run_dir. Read status.json, result.md, stdout/stderr logs, inspect repo diff, then follow the Marinator delegation protocol: review, decide accept/fix/wait/kill/block, and do not report success unless the requested user-visible outcome is verified."

  log_runner "headless_resume: calling hermes chat --resume for event=$event"
  append_event "headless_resume_started" event "$event" owner_session_id "$owner_session_id"

  local resume_log="$run_dir/resume_${event}.log"
  if command -v hermes >/dev/null 2>&1; then
    (
      flock -n 200 || { log_runner "headless_resume: session lock held, skipping"; exit 0; }
      hermes -p "$hermes_profile" chat \
        --resume "$owner_session_id" \
        --toolsets terminal,file \
        -q "$resume_prompt" \
        >"$resume_log" 2>&1 || true
    ) 200>"$lock_file"
    append_event "headless_resume_completed" event "$event"
  else
    log_runner "headless_resume: hermes not in PATH"
    append_event "headless_resume_failed" event "$event" reason "hermes_not_in_path"
  fi
}

# ── Build OpenCode arguments ──

build_opencode_args() {
  local prompt help_text
  prompt=$(cat "$prompt_file")
  OPENCODE_ARGS=(run --dangerously-skip-permissions)

  if [[ -n "$opencode_previous_session_id" && "$opencode_previous_session_id" != "null" ]]; then
    help_text=$("$opencode_bin" run --help 2>&1 || true)
    if echo "$help_text" | grep -q -- '--session'; then
      OPENCODE_ARGS+=(--session "$opencode_previous_session_id")
    elif echo "$help_text" | grep -q -- '--resume'; then
      OPENCODE_ARGS+=(--resume "$opencode_previous_session_id")
    else
      update_status_json '{"worker_state":"failed","attention.state":"needs_decision","attention.reason":"opencode_resume_not_supported"}'
      append_event "failed" reason opencode_resume_not_supported
      echo "MARINATOR_ATTENTION_REQUIRED job_id=$job_id reason=opencode_resume_not_supported run_dir=$run_dir status_path=$status_path"
      headless_resume "failed"
      exit 70
    fi
  fi

  # Append attachments from spec.json as --file arguments
  local att_line
  while IFS= read -r att_line; do
    if [[ -n "$att_line" && -f "$att_line" ]]; then
      OPENCODE_ARGS+=(--file "$att_line")
    fi
  done < <(python3 - "$spec_path" <<'PYATT'
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as fh:
        attachments = json.load(fh).get('attachments', [])
    for a in attachments:
        if a:
            print(a)
except Exception:
    pass
PYATT
  )

  OPENCODE_ARGS+=("$prompt")
}

# ── Progress summary (simplified for Hermes MVP) ──

summarize_delta() {
  local stdout_offset_file="$run_dir/.summary.stdout.offset"
  local stderr_offset_file="$run_dir/.summary.stderr.offset"
  local stdout_size stderr_size previous_stdout_size previous_stderr_size

  stdout_size=$(wc -c < "$stdout_log" | tr -d ' ')
  stderr_size=$(wc -c < "$stderr_log" | tr -d ' ')
  previous_stdout_size=0
  previous_stderr_size=0
  [[ -f "$stdout_offset_file" ]] && previous_stdout_size=$(cat "$stdout_offset_file" 2>/dev/null || echo 0)
  [[ -f "$stderr_offset_file" ]] && previous_stderr_size=$(cat "$stderr_offset_file" 2>/dev/null || echo 0)

  local change_note summary
  if (( stdout_size <= previous_stdout_size && stderr_size <= previous_stderr_size )); then
    change_note="no new output"
  else
    change_note="new output: stdout=$((stdout_size - previous_stdout_size))B stderr=$((stderr_size - previous_stderr_size))B"
  fi

  printf '%s\n' "$stdout_size" > "$stdout_offset_file"
  printf '%s\n' "$stderr_size" > "$stderr_offset_file"

  local elapsed=$(( $(date +%s) - start_epoch ))
  summary="MARINATOR_PROGRESS job_id=$job_id elapsed=${elapsed}s summary=$change_note total_stdout=${stdout_size}B total_stderr=${stderr_size}B"

  log_runner "$summary"
  append_event "progress_summary" summary "$change_note" stdout_bytes "$stdout_size" stderr_bytes "$stderr_size" elapsed "$elapsed"

  # Send via Telegram only when explicitly enabled
  if [[ "$enable_per_minute_reports" == "true" ]]; then
    send_progress "Marinator [$job_id] ${elapsed}s: $change_note"
  fi
}

# ── Stall detection (no auto-kill) ──

attention_emitted=0
emit_attention() {
  local reason=$1
  if [[ "$attention_emitted" -eq 0 ]]; then
    attention_emitted=1
    update_status_json "{\"attention.state\":\"suspected_stall\",\"attention.reason\":\"$reason\",\"attention.detected_at\":\"$(now_iso)\"}"
    append_event "attention_required" reason "$reason"
    echo "MARINATOR_ATTENTION_REQUIRED job_id=$job_id reason=$reason run_dir=$run_dir status_path=$status_path"
    log_runner "ATTENTION_REQUIRED: $reason"
    headless_resume "attention_required"
  fi
}

# ── Terminate helper (only called on explicit control/kill) ──

terminate_group() {
  local pgid=$1
  append_event "terminate_requested" pgid "$pgid"
  kill -TERM -- "-$pgid" 2>/dev/null || true
  sleep 5
  kill -KILL -- "-$pgid" 2>/dev/null || true
}

# ── Extract OpenCode session id from logs ──

extract_opencode_session_id() {
  # Try to find session id from OpenCode stdout/stderr
  local session_id=""
  # Pattern 1: plain text — "Session: <id>", "session_id: <id>", "Session ID: <id>"
  session_id=$(grep -oP '(?:Session(?:\s+ID)?|session_id)\s*[:=]\s*\K\S+' "$stdout_log" 2>/dev/null | tail -1 || true)
  if [[ -z "$session_id" ]]; then
    session_id=$(grep -oP '(?:Session(?:\s+ID)?|session_id)\s*[:=]\s*\K\S+' "$stderr_log" 2>/dev/null | tail -1 || true)
  fi
  # Pattern 2: JSON output — "sessionID":"ses_..."  or  "session_id":"ses_..."
  if [[ -z "$session_id" ]]; then
    session_id=$(grep -oP '"(?:sessionID|session_id)"\s*:\s*"\K[^"]+' "$stdout_log" 2>/dev/null | tail -1 || true)
  fi
  if [[ -z "$session_id" ]]; then
    session_id=$(grep -oP '"(?:sessionID|session_id)"\s*:\s*"\K[^"]+' "$stderr_log" 2>/dev/null | tail -1 || true)
  fi
  printf '%s' "$session_id"
}

# ── Exit trap: ensure non-terminal status never survives ──

TERMINAL_STATES_RE='^(completed|failed|cancelled|killed)$'
opencode_pgid=""

current_worker_state() {
  python3 - "$status_path" 2>/dev/null <<'PYSTATE' || true
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as fh:
        print(json.load(fh).get('worker_state', ''))
except Exception:
    pass
PYSTATE
}

on_runner_exit() {
  local rc=$?
  trap - EXIT INT TERM HUP
  local ws
  ws=$(current_worker_state)
  if [[ ! "$ws" =~ $TERMINAL_STATES_RE ]]; then
    if [[ -n "$opencode_pgid" ]]; then
      kill -TERM -- "-$opencode_pgid" 2>/dev/null || true
    fi
    update_status_json "{\"worker_state\":\"failed\",\"wake.last_error\":\"runner_exited_unexpectedly rc=$rc\"}" || true
    append_event "failed" reason runner_exited_unexpectedly exit_code "$rc" || true
    echo "MARINATOR_DONE job_id=$job_id state=failed exit_code=$rc run_dir=$run_dir result_path=$result_path" || true
    headless_resume "failed" || true
  fi
  exit "$rc"
}

# ── Pre-flight checks ──

if [[ ! -d "$repo" ]]; then
  update_status_json '{"worker_state":"failed"}'
  append_event "failed" reason repo_not_found repo "$repo"
  echo "MARINATOR_DONE job_id=$job_id state=failed exit_code=66 run_dir=$run_dir result_path=$result_path"
  headless_resume "failed"
  exit 66
fi

if [[ ! -f "$prompt_file" ]]; then
  update_status_json '{"worker_state":"failed"}'
  append_event "failed" reason prompt_file_not_found prompt_file "$prompt_file"
  echo "MARINATOR_DONE job_id=$job_id state=failed exit_code=66 run_dir=$run_dir result_path=$result_path"
  headless_resume "failed"
  exit 66
fi

# Resolve opencode binary (double-check runner.py resolution)
if [[ -z "$opencode_bin" || "$opencode_bin" == "null" ]]; then
  if command -v opencode >/dev/null 2>&1; then
    opencode_bin=$(command -v opencode)
  elif [[ -x "$HOME/.opencode/bin/opencode" ]]; then
    opencode_bin="$HOME/.opencode/bin/opencode"
  elif [[ -x "/home/Danila.Savenkov/.opencode/bin/opencode" ]]; then
    opencode_bin="/home/Danila.Savenkov/.opencode/bin/opencode"
  fi
fi

if ! command -v "$opencode_bin" >/dev/null 2>&1 && [[ ! -x "$opencode_bin" ]]; then
  update_status_json '{"worker_state":"failed"}'
  append_event "failed" reason opencode_not_found
  echo "MARINATOR_DONE job_id=$job_id state=failed exit_code=69 run_dir=$run_dir result_path=$result_path"
  headless_resume "failed"
  exit 69
fi

# ── Build args and start OpenCode ──

build_opencode_args
log_runner "Starting opencode: $opencode_bin ${OPENCODE_ARGS[*]}"
update_status_json "{\"worker_state\":\"running\",\"opencode.bin\":\"$opencode_bin\"}"
append_event "opencode_starting" opencode_bin "$opencode_bin" repo "$repo"

# Install exit trap
trap on_runner_exit EXIT INT TERM HUP

# Launch OpenCode in a separate process group via setsid in a subshell
(
  trap 'rc=$?; [[ -f "$exit_path" ]] || echo "$rc" > "$exit_path"' EXIT
  cd "$repo"
  setsid "$opencode_bin" "${OPENCODE_ARGS[@]}" >"$stdout_log" 2>"$stderr_log" &
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

# Wait for opencode pid to appear
opencode_pid=""
for _ in $(seq 1 50); do
  if [[ -s "$pid_path" ]]; then
    opencode_pid=$(cat "$pid_path")
    break
  fi
  sleep 0.1
done

if [[ -z "$opencode_pid" ]]; then
  update_status_json '{"worker_state":"failed"}'
  append_event "failed" reason opencode_pid_not_recorded
  echo "MARINATOR_DONE job_id=$job_id state=failed exit_code=70 run_dir=$run_dir result_path=$result_path"
  headless_resume "failed"
  exit 70
fi

opencode_pgid=$opencode_pid
echo "$opencode_pgid" > "$pgid_path"
update_status_json "{\"opencode.pid\":$opencode_pid,\"opencode.pgid\":$opencode_pgid}"
append_event "opencode_started" pid "$opencode_pid" pgid "$opencode_pgid"
log_runner "OpenCode started: pid=$opencode_pid pgid=$opencode_pgid"

# ── Supervision loop ──

start_epoch=$(date +%s)
last_summary_epoch=$start_epoch
last_progress_epoch=$start_epoch
last_stdout_size=0
last_stderr_size=0

while [[ ! -f "$exit_path" ]] && kill -0 "$waiter_pid" 2>/dev/null; do
  now_epoch=$(date +%s)

  # Check log byte growth
  current_stdout_size=$(wc -c < "$stdout_log" | tr -d ' ')
  current_stderr_size=$(wc -c < "$stderr_log" | tr -d ' ')
  if (( current_stdout_size > last_stdout_size || current_stderr_size > last_stderr_size )); then
    last_stdout_size=$current_stdout_size
    last_stderr_size=$current_stderr_size
    last_progress_epoch=$now_epoch
  fi

  # Check control/kill (orchestrator decision only)
  if [[ -f "$control_dir/kill" ]]; then
    log_runner "Control kill detected"
    update_status_json '{"worker_state":"killed"}'
    terminate_group "$opencode_pgid"
    wait "$waiter_pid" 2>/dev/null || true
    append_event "killed" reason control_kill
    echo "MARINATOR_DONE job_id=$job_id state=killed exit_code=130 run_dir=$run_dir result_path=$result_path"
    headless_resume "killed"
    exit 130
  fi

  # Detect suspected stall (NO auto-kill — record and continue)
  if (( now_epoch - last_progress_epoch >= no_progress_seconds )); then
    emit_attention "no_log_progress"
  fi

  # Periodic progress summary
  if (( now_epoch - last_summary_epoch >= update_interval_seconds )); then
    summarize_delta || true
    last_summary_epoch=$now_epoch
  fi

  sleep 5
done

# ── OpenCode exited — collect result ──

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
    if [[ "$exit_code" -eq 0 ]]; then
      exit_code=70
    fi
    append_event "waiter_exited_without_opencode_exit" waiter_status "$waiter_status" exit_code "$exit_code"
  fi
fi

# Sanitize exit code
if ! [[ "$exit_code" =~ ^-?[0-9]+$ ]]; then
  append_event "opencode_exit_unreadable" raw_exit "$exit_code"
  exit_code=70
fi

# Final progress summary
summarize_delta || true

# Extract and store session id
opencode_session_id=$(extract_opencode_session_id)
if [[ -n "$opencode_session_id" ]]; then
  update_status_json "{\"opencode.session_id\":\"$opencode_session_id\"}"
  log_runner "OpenCode session id: $opencode_session_id"
fi

# ── Write result and terminal status ──

if [[ "$exit_code" -eq 0 ]]; then
  {
    echo "# Marinator worker result"
    echo
    echo "- job_id: $job_id"
    echo "- completed_at: $(now_iso)"
    echo "- exit_code: 0"
    if [[ -n "$opencode_session_id" ]]; then
      echo "- opencode_session_id: $opencode_session_id"
    fi
    echo
    echo "## stdout tail"
    echo '```'
    tail -n 80 "$stdout_log" 2>/dev/null || true
    echo '```'
    echo
    echo "## stderr tail"
    echo '```'
    tail -n 120 "$stderr_log" 2>/dev/null || true
    echo '```'
  } > "$result_path"

  update_status_json "{\"worker_state\":\"completed\",\"opencode.exit_code\":$exit_code}"
  append_event "completed" exit_code "$exit_code"
  echo "MARINATOR_DONE job_id=$job_id state=completed exit_code=0 run_dir=$run_dir result_path=$result_path"
  log_runner "Worker completed successfully"
  headless_resume "completed"
  exit 0
fi

# Failed
{
  echo "# Marinator worker result"
  echo
  echo "- job_id: $job_id"
  echo "- failed_at: $(now_iso)"
  echo "- exit_code: $exit_code"
  if [[ -n "$opencode_session_id" ]]; then
    echo "- opencode_session_id: $opencode_session_id"
  fi
  echo
  echo "## stdout tail"
  echo '```'
  tail -n 80 "$stdout_log" 2>/dev/null || true
  echo '```'
  echo
  echo "## stderr tail"
  echo '```'
  tail -n 120 "$stderr_log" 2>/dev/null || true
  echo '```'
} > "$result_path"

update_status_json "{\"worker_state\":\"failed\",\"opencode.exit_code\":$exit_code}"
append_event "failed" exit_code "$exit_code"
echo "MARINATOR_DONE job_id=$job_id state=failed exit_code=$exit_code run_dir=$run_dir result_path=$result_path"
log_runner "Worker failed with exit_code=$exit_code"
headless_resume "failed"
exit "$exit_code"

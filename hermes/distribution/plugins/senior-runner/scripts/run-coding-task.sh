#!/usr/bin/env bash
set -euo pipefail

# run-coding-task.sh — synchronous OpenCode executor for the Senior Dev lane.
#
# Reads spec.json from SENIOR_RUN_DIR / SENIOR_SPEC_PATH, runs OpenCode in the
# foreground (no supervision loop, no stall watchdog, no async wake), captures
# stdout/stderr/runner logs, writes result.md (including the trailing VERDICT
# block discipline), and exits with OpenCode's exit code.
#
# This script is fully synchronous: the caller
# (senior-runner runner.py / senior_run_coding_task) blocks until OpenCode
# exits, then reads the artifacts. It never mutates the Kanban board — the
# senior-dev worker agent does that after reading the artifacts.
#
# Environment:
#   SENIOR_RUN_DIR    — durable run directory
#   SENIOR_JOB_ID     — job identifier
#   SENIOR_SPEC_PATH  — path to spec.json (default: $SENIOR_RUN_DIR/spec.json)

# ── Validate environment ──

if [[ -z "${SENIOR_RUN_DIR:-}" ]]; then
  echo "ERROR: SENIOR_RUN_DIR not set" >&2
  exit 64
fi
if [[ -z "${SENIOR_JOB_ID:-}" ]]; then
  echo "ERROR: SENIOR_JOB_ID not set" >&2
  exit 64
fi

run_dir="$SENIOR_RUN_DIR"
job_id="$SENIOR_JOB_ID"
spec_path="${SENIOR_SPEC_PATH:-$run_dir/spec.json}"

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
elif isinstance(cur, bool):
    print(str(cur).lower())
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

# ── Paths ──

stdout_log="$run_dir/opencode.stdout.log"
stderr_log="$run_dir/opencode.stderr.log"
runner_log="$run_dir/runner.log"
status_path="$run_dir/status.json"
events_path="$run_dir/events.jsonl"
result_path="$run_dir/result.md"

mkdir -p "$run_dir"
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

# ── Pre-flight checks ──

if [[ ! -d "$repo" ]]; then
  update_status_json '{"worker_state":"failed"}'
  append_event "failed" reason repo_not_found repo "$repo"
  echo "SENIOR_DONE job_id=$job_id state=failed exit_code=66 run_dir=$run_dir result_path=$result_path"
  exit 66
fi

if [[ ! -f "$prompt_file" ]]; then
  update_status_json '{"worker_state":"failed"}'
  append_event "failed" reason prompt_file_not_found prompt_file "$prompt_file"
  echo "SENIOR_DONE job_id=$job_id state=failed exit_code=66 run_dir=$run_dir result_path=$result_path"
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
  echo "SENIOR_DONE job_id=$job_id state=failed exit_code=69 run_dir=$run_dir result_path=$result_path"
  exit 69
fi

# ── Build args and run OpenCode synchronously ──

prompt=$(cat "$prompt_file")
opencode_model="${OPENCODE_MODEL:-openrouter/openai/gpt-5.5}"
opencode_args=(run --format json --dangerously-skip-permissions --model "$opencode_model" -- "$prompt")

log_runner "Starting opencode (sync): model=$opencode_model $opencode_bin ${opencode_args[*]}"
update_status_json "{\"worker_state\":\"running\",\"opencode.bin\":\"$opencode_bin\",\"opencode.model\":\"$opencode_model\"}"
append_event "opencode_starting" opencode_bin "$opencode_bin" model "$opencode_model" repo "$repo"

set +e
(
  cd "$repo"
  "$opencode_bin" "${opencode_args[@]}"
) >"$stdout_log" 2>"$stderr_log"
exit_code=$?
set -e

# Sanitize exit code
if ! [[ "$exit_code" =~ ^-?[0-9]+$ ]]; then
  append_event "opencode_exit_unreadable" raw_exit "$exit_code"
  exit_code=70
fi

append_event "opencode_exited" exit_code "$exit_code"
log_runner "OpenCode exited: exit_code=$exit_code"

# ── Extract OpenCode session id from JSON NDJSON logs ──

opencode_session_id=$(python3 - "$stdout_log" <<'PYSES' 2>/dev/null || true
import json, sys, re
ses_re = re.compile(r'^ses_[A-Za-z0-9]+$')
last_id = ""
try:
    with open(sys.argv[1], 'r', encoding='utf-8', errors='replace') as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                ev = json.loads(raw)
                sid = ev.get("sessionID", "")
                if ses_re.match(str(sid)):
                    last_id = sid
            except (json.JSONDecodeError, ValueError):
                pass
except FileNotFoundError:
    pass
print(last_id, end="")
PYSES
)
if [[ -n "$opencode_session_id" ]]; then
  update_status_json "{\"opencode.session_id\":\"$opencode_session_id\"}"
  log_runner "OpenCode session id: $opencode_session_id"
fi

# ── Extract human-visible assistant text from NDJSON events ──

opencode_text=$(python3 - "$stdout_log" <<'PYTEXT' 2>/dev/null || true
import json, sys
parts = []
try:
    with open(sys.argv[1], 'r', encoding='utf-8', errors='replace') as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                ev = json.loads(raw)
                if ev.get("type") == "text":
                    part = ev.get("part", {})
                    if isinstance(part, dict) and part.get("type") == "text":
                        text = part.get("text", "")
                        if text:
                            parts.append(text)
            except (json.JSONDecodeError, ValueError):
                pass
except FileNotFoundError:
    pass
print("\n".join(parts), end="")
PYTEXT
)

# ── Derive a VERDICT block ──
# OpenCode is prompted to end its response with a VERDICT block. If it did,
# preserve it verbatim; otherwise synthesize one from the exit code so the
# senior-dev worker always has a machine-readable verdict to map onto Kanban.

verdict_block=$(VERDICT_TEXT="$opencode_text" VERDICT_EXIT="$exit_code" python3 <<'PYVERDICT'
import os, re

text = os.environ.get("VERDICT_TEXT", "")
exit_code = os.environ.get("VERDICT_EXIT", "1")

# Find a VERDICT: line and capture the block that follows it.
fields = {"VERDICT": "", "SUMMARY": "", "USER_MESSAGE": "", "PR_URL": ""}
found = False
for line in text.splitlines():
    m = re.match(r'^\s*(VERDICT|SUMMARY|USER_MESSAGE|PR_URL)\s*:\s*(.*)$', line)
    if m:
        found = True
        fields[m.group(1)] = m.group(2).strip()

verdict = fields["VERDICT"].lower()
if verdict not in ("pr-ready", "needs-input", "failed"):
    # Synthesize from exit code.
    if exit_code == "0":
        verdict = "pr-ready" if fields["PR_URL"] else "needs-input"
    else:
        verdict = "failed"
    found = False

if not found:
    summary = (fields["SUMMARY"]
               or ("OpenCode run completed" if exit_code == "0"
                   else f"OpenCode run failed with exit code {exit_code}"))
    user_message = fields["USER_MESSAGE"] or summary
    pr_url = fields["PR_URL"]
else:
    summary = fields["SUMMARY"] or "(no summary provided)"
    user_message = fields["USER_MESSAGE"] or summary
    pr_url = fields["PR_URL"]

print(f"VERDICT: {verdict}")
print(f"SUMMARY: {summary}")
print(f"USER_MESSAGE: {user_message}")
print(f"PR_URL: {pr_url}")
PYVERDICT
)

verdict_value=$(printf '%s\n' "$verdict_block" | sed -n 's/^VERDICT:[[:space:]]*//p' | head -n1)
update_status_json "{\"worker_state\":\"completed\",\"opencode.exit_code\":$exit_code,\"verdict\":\"$verdict_value\"}"

# ── Write result.md ──

{
  echo "# Senior Dev worker result"
  echo
  echo "- job_id: $job_id"
  echo "- finished_at: $(now_iso)"
  echo "- exit_code: $exit_code"
  if [[ -n "$opencode_session_id" ]]; then
    echo "- opencode_session_id: $opencode_session_id"
  fi
  echo
  if [[ -n "$opencode_text" ]]; then
    echo "## Assistant response"
    echo
    echo "$opencode_text"
    echo
  fi
  echo "## stdout tail"
  echo '```'
  tail -n 80 "$stdout_log" 2>/dev/null || true
  echo '```'
  echo
  echo "## stderr tail"
  echo '```'
  tail -n 120 "$stderr_log" 2>/dev/null || true
  echo '```'
  echo
  echo "## VERDICT"
  echo '```'
  printf '%s\n' "$verdict_block"
  echo '```'
} > "$result_path"

echo "SENIOR_DONE job_id=$job_id state=completed exit_code=$exit_code run_dir=$run_dir result_path=$result_path"
log_runner "Senior worker finished verdict=$verdict_value"
exit "$exit_code"

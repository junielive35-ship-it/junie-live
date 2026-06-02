#!/usr/bin/env bash
set -euo pipefail

# aw-runner.sh — Autonomous Work Window runner for Hermes
#
# Thin deterministic supervisor that drives one headless AW step at a time.
# It must NOT choose product work, edit backlog semantically, review code,
# decide strategy, or bypass Marinator.
#
# Environment:
#   AW_WINDOW_DIR   — window run directory (provided by autonomous_work_start)
#   AW_WINDOW_ID    — window identifier
#   HERMES_PROFILE  — Hermes profile (default: junie-live)

if [[ -z "${AW_WINDOW_DIR:-}" ]]; then
  echo "ERROR: AW_WINDOW_DIR not set" >&2
  exit 64
fi

window_dir="$AW_WINDOW_DIR"
window_id="${AW_WINDOW_ID:-unknown}"
profile="${HERMES_PROFILE:-junie-live}"

window_json="$window_dir/window.json"
events_path="$window_dir/events.jsonl"
runner_lock="$window_dir/locks/runner.lock"
step_lock="$window_dir/locks/step.lock"
control_dir="$window_dir/control"
logs_dir="$window_dir/logs"
runner_log="$logs_dir/aw-runner.log"
step_count=0
max_steps=100

mkdir -p "$logs_dir" "$control_dir" "$window_dir/locks"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log_runner() {
  printf '%s %s\n' "$(now_iso)" "$*" >> "$runner_log"
}

append_event() {
  local event=$1
  shift
  python3 - "$events_path" "$event" "$window_id" "$@" <<'PYEVENT'
import json, sys, datetime
path, event, window_id = sys.argv[1], sys.argv[2], sys.argv[3]
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
    "window_id": window_id,
}
record.update(detail)
with open(path, 'a', encoding='utf-8') as fh:
    fh.write(json.dumps(record, ensure_ascii=False) + '\n')
PYEVENT
}

# Cleanup handler — removes both locks on exit
cleanup() {
  rm -f "$runner_lock" "$step_lock"
}
trap cleanup EXIT

# Acquire runner lock (non-blocking)
if ! (set -C; : > "$runner_lock") 2>/dev/null; then
  log_runner "Runner lock held; exiting"
  exit 0
fi

log_runner "AW runner started: window_id=$window_id"

# ── Main loop ──

while [[ "$step_count" -lt "$max_steps" ]]; do
  step_count=$((step_count + 1))

  # Read window.json
  if [[ ! -f "$window_json" ]]; then
    log_runner "window.json not found; exiting"
    append_event "runner_exit" reason "window_json_not_found"
    exit 1
  fi

  phase=$(python3 - "$window_json" 2>/dev/null <<'PYPHASE'
import json, sys
try:
    with open(sys.argv[1], 'r') as fh:
        w = json.load(fh)
    print(w.get('phase', 'unknown'))
except Exception:
    print('unknown')
PYPHASE
) || phase="unknown"

  continuation=$(python3 - "$window_json" 2>/dev/null <<'PYCONT'
import json, sys
try:
    with open(sys.argv[1], 'r') as fh:
        w = json.load(fh)
    print(w.get('continuation', 'unknown'))
except Exception:
    print('unknown')
PYCONT
) || continuation="unknown"

  log_runner "Step $step_count: phase=$phase continuation=$continuation"

  case "$continuation" in
    continue_now)
      # Read the step prompt built by autonomous_work_step
      prompt_file="$window_dir/step_prompt.md"
      if [[ ! -f "$prompt_file" ]]; then
        log_runner "step_prompt.md not found; using generic prompt"
        prompt="Continue autonomous work window $window_id, phase $phase. Read $window_json, follow the phase instructions, then call autonomous_work_step(rationale=\"runner tick\")."
      else
        prompt=$(cat "$prompt_file")
      fi

      step_log="$logs_dir/step-${step_count}.stdout.log"
      step_err_log="$logs_dir/step-${step_count}.stderr.log"

      log_runner "starting fresh AW step: phase=$phase"

      # Acquire step lock for this step (cleanup handler removes it on error)
      if ! (set -C; : > "$step_lock") 2>/dev/null; then
        log_runner "Step lock held; waiting..."
        sleep 2
        continue
      fi

      set +e
      hermes -p "$profile" chat \
        --toolsets autonomous,marinator,terminal,file \
        -q "$prompt" \
        >"$step_log" 2>"$step_err_log"
      step_rc=$?
      set -e

      rm -f "$step_lock"

      log_runner "Step $step_count completed: rc=$step_rc"
      append_event "step_completed" step "$step_count" rc "$step_rc" phase "$phase"

      # Check cancel file after step
      if [[ -f "$control_dir/cancel" ]]; then
        log_runner "Cancel file detected; exiting"
        append_event "runner_exit" reason "cancel_detected"
        exit 0
      fi

      # Re-read window.json after step
      continuation=$(python3 - "$window_json" 2>/dev/null <<'PYCONT2'
import json, sys
try:
    with open(sys.argv[1], 'r') as fh:
        w = json.load(fh)
    print(w.get('continuation', 'unknown'))
except Exception:
    print('unknown')
PYCONT2
) || continuation="unknown"

      log_runner "After step: continuation=$continuation"
      ;;

    wait_external)
      log_runner "Continuation=wait_external; stopping loop"
      append_event "runner_stop" reason "wait_external" phase "$phase"
      exit 0
      ;;

    final|blocked|cancelled)
      log_runner "Continuation=$continuation; stopping loop"
      append_event "runner_stop" reason "continuation_$continuation" phase "$phase"
      exit 0
      ;;

    *)
      log_runner "Unknown continuation '$continuation'; stopping"
      append_event "runner_stop" reason "unknown_continuation" continuation "$continuation"
      exit 1
      ;;
  esac
done

log_runner "Max steps ($max_steps) reached; exiting"
append_event "runner_exit" reason "max_steps_reached" steps "$max_steps"
exit 0

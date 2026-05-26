---
name: junie-autonomous-work-window
description: "Start a bounded autonomous work window for Junie Live from Telegram/admin commands."
version: 1.0.0
tags: [junie-live, autonomous, overnight, work-window]
---

# Autonomous Work Window

Use this skill when the admin asks to start a bounded autonomous work window for the initialized project.

Trigger phrases include:
- "work autonomously for 9 hours"
- "start autonomous loop for 4h"
- "поработай автономно 9 часов"
- "иди улучшай продукт 9 часов"
- "работай над проектом до утра"

## Inputs

Parse the message for:

1. A bounded duration or end time: `9h`, `4 hours`, `30m`, `до утра`, `until morning`, `until 08:00`, or similar.
2. Optional goal text. Treat it as guidance, not as a replacement for initialized strategy/backlog context.

If the duration/end time is missing or ambiguous, ask one concise question. Do not ask multiple setup questions.

## Required behavior

Before starting:

1. Confirm initialization is complete (check memory for "Initialization status: INITIALIZED").
2. Derive the owned repo, backlog priorities, mutex state, verification gates, commit expectations from memory and docs. Do **not** ask the admin to restate internal details such as repo path, backlog process, mutex location, verification commands, commit policy, or report format.
3. Check the code mutex state. If held, do not start.
4. Never work on `main` branch. Verify branch before starting.

## Implementation

Use Hermes cron to create a bounded autonomous work job:

```
cronjob(
  action="create",
  name="junie-autonomous-window",
  schedule="now",  # Start immediately
  prompt="You are Junie Live running an autonomous work window. Duration: <duration>. Goal: <goal or backlog priorities>. Read memory for full context. Select the highest-priority eligible backlog item, delegate implementation via ~/.opencode/bin/opencode run (--model openrouter/anthropic/claude-opus-4.6 --variant minimal), review the result, commit if good, reflect, then pick the next item. Stop when time expires or you hit a blocker. Report results to the owner via Telegram.",
  skills=["junie-autonomous-work-window", "junie-coding-task-decomposition", "junie-implementation-review", "junie-task-reflection"],
  enabled_toolsets=["terminal", "file", "web", "delegation"],
  deliver="telegram"
)
```

Alternatively, for simpler cases, use a spawned background process:

```
terminal(
  command="hermes -p junie-live chat -q '<autonomous work prompt>'",
  background=true,
  notify_on_complete=true
)
```

## Telegram response format

Keep replies concise.

Started:
```
Started autonomous work window.
Duration/end: <resolved duration/end>
Goal: <goal or initialized backlog priorities>
Next: I'll work in the background and report blockers/results.
```

Blocked:
```
Blocked: <reason>
Needed: <single next action, if any>
```

Status/update:
```
Status: <running|blocked|done>
Window: <duration/end>
Current: <active task or blocker>
```

## Safety constraints

- Initialization must be complete before starting.
- Code mutex must be free.
- Do not run on `main`.
- Do not use ad hoc background loops. Use Hermes cron or spawned processes.
- Keep the skill project-agnostic; do not hard-code repo paths or branch names.

## Verification failure handling

Verification failures get up to 7 fix attempts (delegated back to subagent with the failure context). If all fail, block the task, release the mutex, preserve the diff/status, and move to the next item.

## Local task failure continuation

By default, continue after safe local task failures (max 3). If a worker fails, block that task, clean up, and continue to the next backlog item. Stop on cleanup failure or too many consecutive failures.

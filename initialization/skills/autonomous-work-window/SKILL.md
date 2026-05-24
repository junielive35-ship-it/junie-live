---
name: autonomous-work-window
description: "Start a bounded autonomous work window from Telegram/admin commands."
---

# Autonomous Work Window

Use this skill when the admin invokes `/skill autonomous-work-window ...` or asks from Telegram/admin chat to start a bounded autonomous work window for the initialized project.

This is the command surface for requests such as:

- `/skill autonomous-work-window 9h`
- `/skill autonomous-work-window 4 hours improve onboarding`
- `/skill autonomous-work-window до утра`
- `/skill autonomous-work-window until 08:00 fix top backlog items`

## Inputs

Parse the invocation text for:

1. A bounded duration or end time: `9h`, `4 hours`, `30m`, `до утра`, `until morning`, `until 08:00`, or similar.
2. Optional goal text after removing the duration/end-time phrase. Treat it as guidance, not as a replacement for initialized strategy/backlog context.

If the duration/end time is missing or ambiguous, ask one concise question, for example: `На сколько запустить автономное окно? Например: 4h, 9h, до утра.` Do not ask multiple setup questions.

## Required behavior

Before starting:

1. Confirm initialization is complete; if `INITIALIZATION.md` still exists or the project assignment is unresolved, block and say initialization must finish first.
2. Derive the owned repo/workspace, backlog, mutex, branch, verification gates, commit/report expectations, opencode model, and state/log paths from initialized context (`MEMORY.md`, `AGENTS.md`, `TOOLS.md`, `docs/`, repo state, and workspace `.openclaw/state`).
3. Do **not** ask the admin to restate internal details such as repo path, backlog process, mutex location, opencode/Claude settings, verification commands, commit policy, or report format.
4. Check repo/workspace and code mutex/preflight according to initialized guidance. If the mutex is held or preflight blocks, do not start a competing loop.
5. Never run on `main` and never invent ad hoc loops. Use the standard wrapper/controller/watchdog/report path only.

Start the window with the standard wrapper after initialization, normally:

```bash
scripts/start-autonomous-window.sh --duration <resolved-duration-or-end> --background
```

Add explicit `--workspace`, `--repo`, `--state-dir`, `--expected-branch`, controller limits, or goal/context options only when the initialized project guidance or wrapper requires them. Let the wrapper/controller handle repeated backlog choice, sequential opencode-compatible worker delegation, verification, meaningful commits, task release/blocking, mutex cleanup, watchdog/report state, and blocker handling until the requested end time, max iterations, or a blocker.

## Telegram response format

Keep Telegram replies concise.

Started:

```text
Started autonomous work window.
Duration/end: <resolved duration/end>
Goal: <goal or initialized backlog priorities>
State/logs: <state/log/report location if known>
Next: I’ll work in the background and report blockers/results.
```

Blocked:

```text
Blocked: <reason>
Needed: <single next action, if any>
```

Status/update:

```text
Status: <running|blocked|done>
Window: <duration/end>
Current: <active task or blocker>
Logs/report: <location if known>
```

## Safety constraints

- Initialization must be complete before starting.
- Repo/workspace and code mutex context must be known from initialized context.
- Respect mutex/preflight; do not bypass or start parallel code-changing work.
- Do not run on `main`.
- Do not use ad hoc background loops or manual long-running shell scripts instead of the standard wrapper.
- Keep the command project-agnostic; do not hard-code repo paths, branch names, or project-specific backlog items in this skill.

Autonomous windows: default --fix-retries 7 / AUTONOMOUS_FIX_RETRIES; verification failures get bounded fix attempts. Exhaustion blocks, releases mutex, preserves diff/status, cleans workspace. Hard timeout default 7200s.

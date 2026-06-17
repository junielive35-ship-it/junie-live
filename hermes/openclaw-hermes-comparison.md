# OpenClaw vs Hermes — Junie Live Platform Comparison

This document compares the OpenClaw and Hermes implementations of Junie Live to help make an informed platform decision.

## 1. Key Differences

### Architecture

| Aspect | OpenClaw | Hermes |
| --- | --- | --- |
| **Agent framework** | OpenClaw (open-source) | Hermes Agent (open-source, Nous Research) |
| **Workspace model** | `.openclaw/workspace-*` directory with seed files (`AGENTS.md`, `SOUL.md`, `MEMORY.md`, `TOOLS.md`, `HEARTBEAT.md`) | Hermes profile (`~/.hermes/profiles/junie-live/`) holding `SOUL.md`, memory stores, skills, docs |
| **Persistent context** | `MEMORY.md` file — manually read, manually size-checked, manually compacted | Hermes memory tool — auto-injected into every turn, structured add/replace/remove, searchable |
| **Persona / personality** | `SOUL.md` file in workspace | `SOUL.md` in `$HERMES_HOME` — auto-loaded as agent identity (slot #1 in system prompt) on every turn |
| **Operating protocol** | `AGENTS.md` — large protocol file in workspace, loaded by OpenClaw | `HERMES.md` in target repo root (auto-loaded by Hermes from cwd) + skills + `SOUL.md` + memory; `HERMES.md` is used instead of `AGENTS.md` so coding executors don't pick up orchestrator-only rules |
| **Operational reference** | `TOOLS.md` — auto-loaded workspace file with repo paths, dev commands, deploy process, dashboards, escalation contacts | `docs/tools.md` — same structure (project paths, dev commands, git/PR conventions, mutex configuration, deployment & rollback, analytics, escalation). Not auto-loaded by Hermes; `HERMES.md` instructs the agent to consult `tools.md` before any work that needs build/lint/test/run/deploy/branch/rollback/mutex-escalation info. |
| **Coding delegation** | `opencode run` via shell scripts (`run-backlog-worker.sh`) | `create_senior_task` to the Senior Dev Kanban lane. Current p1 uses synchronous `senior_run_coding_task` (OpenCode) and `blocked(review-required|needs-input|failed)` handoff; `delegate_task` only for non-code subtasks |
| **Scheduled routines** | System crontab + OpenClaw cron definitions + shell scripts | Hermes native cron jobs — created in-session, no system crontab |
| **Orchestration logic** | ~25 shell scripts (drive.sh, overnight-controller.sh, etc.) | LLM-driven orchestration guided by skills and docs |
| **Repo hygiene** | Complex — must prevent workspace artifacts from leaking into target repo | Single tracked file (`HERMES.md`); all other state under `~/.hermes/` |

### Delegation Model

| Aspect | OpenClaw | Hermes |
| --- | --- | --- |
| **Worker** | `opencode` CLI with Claude Opus 4.6 low reasoning | `senior-dev` profile is a thin Kanban worker. In p1 it calls `senior_run_coding_task`, which runs OpenCode synchronously; `delegate_task` is reserved for non-code research/analysis |
| **Worker control** | Shell-level: timeout, pid tracking, log capture, exit code checking | Senior p1 runner records status, logs, events, result artifacts, and returns synchronously to the Kanban worker, which comments and blocks the task for review/input/failure |
| **Worker model** | Hardcoded to `openrouter/anthropic/claude-opus-4.6` low reasoning | Uses OpenCode's configured defaults behind the Senior runner boundary |
| **Context passing** | Prompt file written to disk, passed as CLI argument | Senior task body + comments are assembled by `senior-dev` and passed to `senior_run_coding_task`; the runner writes `prompt.md` and Marinator-style artifacts |
| **Fix retry loop** | Shell loop: re-run worker with verification failure output piped as stdin | Orchestrator reviews `blocked(review-required)` artifacts/comments, then comments and requeues/unblocks the same Senior task when a fix/follow-up is appropriate. This follow-up ergonomics is still a live-runtime verification point. |
| **Parallel work** | Blocked by shell-level sequential execution | `delegate_task` supports up to 3 parallel subagents (for non-code work) |

### Scheduling and Autonomous Work

| Aspect | OpenClaw | Hermes |
| --- | --- | --- |
| **Cron backend** | System crontab + OpenClaw cron API + shell scripts | Hermes cron scheduler (in-process, persistent) |
| **Job creation** | `openclaw/scripts/install-overnight-crons.sh` generates crontab entries and OpenClaw cron definitions | `cronjob(action="create", ...)` from any session |
| **Job definition** | JSON definition + crontab line + shell command with explicit env vars | Prompt + optional skills + schedule + delivery target |
| **Watchdog** | `openclaw/scripts/overnight-watchdog.sh` — shell script checking mutex, process state, git status | Hermes cron job with LLM — checks mutex, uses tools to inspect state |
| **Controller** | `openclaw/scripts/overnight-controller.sh` — loop: select task → delegate worker → verify → commit → next | LLM-driven: same flow but orchestrated by the agent, not a shell loop |
| **Report** | `openclaw/scripts/overnight-report.sh` — generates KV-format report from state files | LLM generates natural-language report from inspection |

## 2. Strengths and Weaknesses

### OpenClaw Strengths

1. **Deterministic orchestration** — Shell scripts always execute the same way. The overnight controller loop, verification retry, mutex handling, and cleanup are predictable state machines. No LLM variability.

2. **Battle-tested scripts** — 25+ scripts with comprehensive verify.sh tests (~500 lines of test assertions). The verification suite catches regressions in script behavior, cron installation, workspace hygiene, and autonomous-loop contracts.

3. **Explicit state management** — Every state transition is a file operation: mutex acquire/release, backlog item status, controller phase, worker PID. State is inspectable with `cat` and `jq`.

4. **No LLM dependency for orchestration** — The overnight controller, watchdog, and report run without calling any LLM. Only the actual coding work requires an LLM. This means orchestration is fast, cheap, and won't fail due to API outages.

5. **Comprehensive workspace model** — `AGENTS.md`, `SOUL.md`, `MEMORY.md`, `TOOLS.md`, `HEARTBEAT.md`, `docs/`, `skills/` form a well-defined layered context that can be inspected and modified by any tool.

6. **Hardened opencode integration** — Model discovery, API key loading (`~/openrouter.key`), shell-level error handling, and blocked states. Note: `opencode auth list` was historically treated as an authoritative readiness check, but a running OpenCode can report `0 credentials` and still execute code changes successfully. The canonical readiness signal is a real smoke execution (`opencode run`), not auth-only diagnostics.

### OpenClaw Weaknesses

1. **Shell-script complexity** — 25+ interconnected bash scripts with environment variable plumbing, temp file management, and grep-based state parsing. Hard to understand, maintain, and debug. The `drive.sh` script alone is 340 lines.

2. **Workspace artifact leakage** — OpenClaw's workspace model creates `AGENTS.md`, `SOUL.md`, `USER.md`, `TOOLS.md`, `.openclaw/`, `state/` files that can accidentally pollute the target repo. Extensive hygiene checks and `.git/info/exclude` guards are needed.

3. **Rigid delegation** — Hardcoded to `opencode` with specific model/variant/agent flags. Changing the coding worker requires updating environment variables and ensuring the new binary supports the same CLI interface.

4. **Manual context management** — `MEMORY.md` must be read manually before each meaningful task, and size-checked after each edit. Forgetting either step degrades the agent's strategic awareness or bloats context.

5. **System crontab dependency** — Cron jobs require system-level crontab installation, which may not work in all environments (containers, restricted systems, WSL).

6. **OpenClaw dependency** — If OpenClaw changes its API, workspace format, or cron interface, all scripts need updating.

7. **Complex initialization** — The `openclaw/hire-junie.sh` script is 258 lines orchestrating: backup, openclaw agents add, workspace seeding, cron installation, telegram channel setup, config patching, agent binding, device approval, gateway restart.

### Hermes Strengths

1. **Native tool integration** — `delegate_task`, `cronjob`, `memory`, `session_search`, `skill_manage` are first-class tools. No shell-script glue needed for orchestration.

2. **Minimal target-repo footprint** — Junie installs exactly one file in the target repo (`HERMES.md`, the orchestrator-only project protocol). All other state lives under `~/.hermes/`. The `HERMES.md` slot is invisible to coding executors (opencode, codex, claude-code) which read `AGENTS.md`/`CLAUDE.md`/`.cursorrules` instead, so executor sessions stay clean and the project's own `AGENTS.md` (if any) is untouched.

3. **Flexible delegation** — `delegate_task` works with any model. Can delegate to subagents, spawn separate Hermes processes, or use Claude Code / Codex / OpenCode. Model choice is per-task.

4. **Auto-loaded memory** — Hermes injects memory into every turn automatically. No need to manually read `MEMORY.md` — the strategic compass is always present.

5. **Auto-loaded skills** — Skills match by description and are loaded when relevant. The orchestrator doesn't need to know which protocol to consult — Hermes finds it.

6. **Open source and provider-agnostic** — Works with 20+ LLM providers. Not tied to one vendor's ecosystem.

7. **Simpler setup** — Profile creation, persona copy, skill installation, and gateway setup are straightforward. No complex workspace bootstrapping.

8. **Session search** — Past sessions are searchable via `session_search`. The orchestrator can recall previous decisions, task outcomes, and owner instructions without maintaining daily memory files.

9. **Multi-platform** — Beyond Telegram, Hermes supports Discord, Slack, WhatsApp, Signal, Matrix, Email, SMS, and more. Future Junie instances could use any platform.

10. **Self-improving skills** — Hermes skills can be patched in-session (`skill_manage(action="patch")`), versioned, and managed by the curator. When a skill has issues, the agent fixes it immediately.

### Hermes Weaknesses

1. **LLM-dependent orchestration** — The overnight controller, watchdog, and autonomous work loop are LLM-driven. This means:
   - Every orchestration step costs tokens
   - API outages break orchestration, not just coding work
   - LLM may make different decisions on each run (non-deterministic)
   - Harder to test deterministically

2. **No verification test suite** — The OpenClaw version has ~2400 lines of bash tests in `verify.sh` that validate the entire system: scripts, cron installation, autonomous loop behavior, worker integration, hygiene. The Hermes version has a basic `verify.sh` but nothing comparable.

3. **Less explicit state management** — Hermes memory is a good strategic compass, but lacks the file-level inspectability of OpenClaw's `holder.json`, `state.json`, `window.json`, etc. Debugging a stuck overnight run means reading session logs, not `cat state.json`.

4. **Newer platform** — Hermes Agent is younger than OpenClaw. While actively developed, edge cases in cron scheduling, delegation, or gateway behavior may surface.

5. **Cron job fragility** — Hermes cron jobs are created in-session with prompts. If the prompt is poorly written, the cron job may not behave correctly. OpenClaw cron definitions are explicit shell commands with predictable behavior.

6. **Senior runner boundary is newer than OpenClaw's scripts** — OpenClaw's `run-backlog-worker.sh` has a longer-tested shell boundary. The Hermes implementation now has a synchronous Senior runner with status files, logs, event capture, result artifacts, and Kanban blocked-state handoff; the older async Marinator runner also remains available, but sustained-load confidence is still developing.

7. **delegate_task is not the coding path** — Native subagents remain useful for non-code research and analysis, but code-changing work must go through `create_senior_task` and the Senior Dev Kanban lane so the orchestrator can enforce active-task lookup, review/fix/requeue, verification, user notification, and acceptance boundaries.

8. **Injection-detection filter on auto-loaded files** — Hermes runs a prompt-injection scanner on `SOUL.md` and `HERMES.md` before loading them into the system prompt. HTML comments (`<!-- ... -->`) trigger the `html_comment_injection` heuristic and cause the entire file to be blocked with no fallback. This is silent from the agent's perspective (the file simply doesn't appear in context) but logged as `[BLOCKED: SOUL.md contained potential prompt injection (html_comment_injection). Content not loaded.]`. In practice this broke Junie's first initialization: `SOUL.md` carried the initialization gate rule, but the file was blocked because it contained developer-documentation HTML comments. The agent had no identity, no operating rules, and no initialization gate — it just greeted the user casually. OpenClaw has no equivalent filter; workspace files are loaded verbatim. **Workaround:** never use HTML comments in `SOUL.md`, `HERMES.md`, or any file auto-loaded into the Hermes system prompt. Move developer notes into companion documentation files or use markdown-native documentation instead.

## 3. Suitability Assessment

### For current project status (MVP)

The MVP priority is the autonomous ownership loop: strategy → backlog → Senior Dev Kanban → delegation → review/requeue → commit/handoff → reflection. The code mutex remains for legacy/manual protected paths, but Kanban is the active p1 code-work boundary.

**Hermes** is the current MVP path:
- The Autonomous Work plugin provides durable bounded windows and deterministic phase artifacts
- Senior Dev Kanban + `senior_run_coding_task` provides the current p1 OpenCode boundary for code-changing work
- `./hermes/scripts/verify.sh` now covers dump/rehire, initialization-gate, Senior Dev install/toolset, Senior task/result, and Senior runner regressions
- Profile memory/docs keep the strategic state native to Hermes instead of relying on OpenClaw workspace files

**OpenClaw** remains useful as historical context and a benchmark:
- Its shell scripts are still a reference for deterministic controller/watchdog/report behavior
- Its broader test suite is a reminder to keep expanding Hermes regression coverage where it protects real MVP risks

**Remaining Hermes MVP risk**:
- Sustained-load confidence is still developing for long autonomous windows
- Cron watchdog/health jobs are optional and operator-configured, not installed by default
- The AW plugin + Senior Dev Kanban runner + memory/docs loop needs continued real-world runs and regression coverage

**Verdict for MVP**: continue stabilizing the Hermes-native AW + Senior Dev Kanban p1 path. Use OpenClaw as a comparison baseline, not as the recommended runtime for new Junie Live MVP work.

### For long-term product vision

The long-term vision is a persistent senior-engineer-style agent with product ownership, proactive improvement, team communication, and self-improvement.

**Hermes** has advantages:
- Memory auto-injection means the agent always has strategic context
- Session search enables learning from past decisions
- Flexible delegation supports evolving the coding workflow
- Multi-platform support enables broader team communication
- Self-improving skills mean the agent gets better over time
- Open-source means full control and customization

**OpenClaw** limitations long-term:
- Shell-script orchestration is hard to extend with new behaviors
- Adding new delegation targets requires shell-level integration
- `MEMORY.md` manual management becomes fragile as context grows
- OpenClaw API/workspace format changes would require updating all scripts

**Verdict for long-term**: Hermes is more extensible and adaptable.

### For specific capabilities

| Capability | Better platform | Why |
| --- | --- | --- |
| Deterministic overnight loops | OpenClaw | Shell scripts are predictable |
| Flexible coding delegation | Hermes | Marinator boundary for code changes; native subagents for non-code work |
| Strategic memory | Hermes | Auto-injected, always present |
| Self-improvement | Hermes | Skills, memory, session_search |
| Team communication | Hermes | Multi-platform gateway |
| Repo hygiene | Hermes | No workspace artifacts |
| Debugging failed runs | OpenClaw | Explicit state files |
| Setup simplicity | Hermes | Profile + persona + skills |
| Test coverage | OpenClaw | 2400-line verify.sh |
| Provider flexibility | Hermes | 20+ providers |
| Autonomous work reliability | Hermes path under active validation | AW plugin state machine plus Marinator artifacts; OpenClaw remains a deterministic benchmark |

## 4. Recommendation

**Short-term**: use the Hermes-native implementation as the active MVP path: owner/admin-triggered Autonomous Work windows, Marinator for code-changing work, profile memory/docs for strategic context, and repo verification before commits. Keep OpenClaw as a benchmark for deterministic behavior and test coverage.

**Medium-term**: keep validating Hermes on low-stakes autonomous windows. Compare against OpenClaw's historical behavior where useful:
- Autonomous work reliability (does the AW plugin + Marinator loop produce equivalent or better outcomes?)
- Token cost (Hermes orchestration costs tokens; OpenClaw orchestration is free)
- Maintainability (how easy is it to fix issues in each?)
- Adaptability (how easy is it to add new behaviors?)

**Long-term**: keep the product centered on Hermes if the AW + Marinator loop continues to prove reliable. The flexibility, extensibility, and self-improvement capabilities are better aligned with the Junie Live vision. Port only the most valuable deterministic lessons from OpenClaw into Hermes-native plugins, skills, tests, or explicitly approved cron jobs.

**Cron stance**: do not use cron as the primary control plane. Owner/admin-triggered AW windows are the default. Hermes cron can be added later for watchdog, health, or scheduled-start routines only after explicit owner/admin decision.

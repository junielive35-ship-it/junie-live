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
| **Operational reference** | `TOOLS.md` — auto-loaded workspace file with repo paths, dev commands, deploy process, dashboards, escalation contacts | No auto-loaded equivalent. Workaround: `HERMES.md` instructs the agent to `read_file("docs/tools.md")` (or equivalent) before meaningful work, or critical bits go into memory |
| **Coding delegation** | `opencode run` via shell scripts (`run-backlog-worker.sh`) | `delegate_task` (native) or spawned `hermes`/`claude-code`/`codex` process |
| **Scheduled routines** | System crontab + OpenClaw cron definitions + shell scripts | Hermes native cron jobs — created in-session, no system crontab |
| **Orchestration logic** | ~25 shell scripts (drive.sh, overnight-controller.sh, etc.) | LLM-driven orchestration guided by skills and docs |
| **Repo hygiene** | Complex — must prevent workspace artifacts from leaking into target repo | Single tracked file (`HERMES.md`); all other state under `~/.hermes/` |

### Delegation Model

| Aspect | OpenClaw | Hermes |
| --- | --- | --- |
| **Worker** | `opencode` CLI with Claude Opus 4.6 low reasoning | `delegate_task` subagent (any model) or spawned process |
| **Worker control** | Shell-level: timeout, pid tracking, log capture, exit code checking | Framework-level: delegate_task returns summary, background processes tracked |
| **Worker model** | Hardcoded to `openrouter/anthropic/claude-opus-4.6` low reasoning | Configurable per-delegation; can use any Hermes-supported model |
| **Context passing** | Prompt file written to disk, passed as CLI argument | In-memory context string passed to delegate_task |
| **Fix retry loop** | Shell loop: re-run worker with verification failure output piped as stdin | Orchestrator reads failure, delegates fix task with failure context |
| **Parallel work** | Blocked by shell-level sequential execution | `delegate_task` supports up to 3 parallel subagents (for non-code work) |

### Scheduling and Autonomous Work

| Aspect | OpenClaw | Hermes |
| --- | --- | --- |
| **Cron backend** | System crontab + OpenClaw cron API + shell scripts | Hermes cron scheduler (in-process, persistent) |
| **Job creation** | `scripts/install-overnight-crons.sh` generates crontab entries and OpenClaw cron definitions | `cronjob(action="create", ...)` from any session |
| **Job definition** | JSON definition + crontab line + shell command with explicit env vars | Prompt + optional skills + schedule + delivery target |
| **Watchdog** | `scripts/overnight-watchdog.sh` — shell script checking mutex, process state, git status | Hermes cron job with LLM — checks mutex, uses tools to inspect state |
| **Controller** | `scripts/overnight-controller.sh` — loop: select task → delegate worker → verify → commit → next | LLM-driven: same flow but orchestrated by the agent, not a shell loop |
| **Report** | `scripts/overnight-report.sh` — generates KV-format report from state files | LLM generates natural-language report from inspection |

## 2. Strengths and Weaknesses

### OpenClaw Strengths

1. **Deterministic orchestration** — Shell scripts always execute the same way. The overnight controller loop, verification retry, mutex handling, and cleanup are predictable state machines. No LLM variability.

2. **Battle-tested scripts** — 25+ scripts with comprehensive verify.sh tests (~500 lines of test assertions). The verification suite catches regressions in script behavior, cron installation, workspace hygiene, and autonomous-loop contracts.

3. **Explicit state management** — Every state transition is a file operation: mutex acquire/release, backlog item status, controller phase, worker PID. State is inspectable with `cat` and `jq`.

4. **No LLM dependency for orchestration** — The overnight controller, watchdog, and report run without calling any LLM. Only the actual coding work requires an LLM. This means orchestration is fast, cheap, and won't fail due to API outages.

5. **Comprehensive workspace model** — `AGENTS.md`, `SOUL.md`, `MEMORY.md`, `TOOLS.md`, `HEARTBEAT.md`, `docs/`, `skills/` form a well-defined layered context that can be inspected and modified by any tool.

6. **Hardened opencode integration** — Model discovery, API key loading (`~/openrouter.key`), auth diagnostics, provider error detection — all handled at the shell level with specific error messages and blocked states.

### OpenClaw Weaknesses

1. **Shell-script complexity** — 25+ interconnected bash scripts with environment variable plumbing, temp file management, and grep-based state parsing. Hard to understand, maintain, and debug. The `drive.sh` script alone is 340 lines.

2. **Workspace artifact leakage** — OpenClaw's workspace model creates `AGENTS.md`, `SOUL.md`, `USER.md`, `TOOLS.md`, `.openclaw/`, `state/` files that can accidentally pollute the target repo. Extensive hygiene checks and `.git/info/exclude` guards are needed.

3. **Rigid delegation** — Hardcoded to `opencode` with specific model/variant/agent flags. Changing the coding worker requires updating environment variables and ensuring the new binary supports the same CLI interface.

4. **Manual context management** — `MEMORY.md` must be read manually before each meaningful task, and size-checked after each edit. Forgetting either step degrades the agent's strategic awareness or bloats context.

5. **System crontab dependency** — Cron jobs require system-level crontab installation, which may not work in all environments (containers, restricted systems, WSL).

6. **OpenClaw dependency** — If OpenClaw changes its API, workspace format, or cron interface, all scripts need updating.

7. **Complex initialization** — The `hire-junie.sh` script is 258 lines orchestrating: backup, openclaw agents add, workspace seeding, cron installation, telegram channel setup, config patching, agent binding, device approval, gateway restart.

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

6. **No shell-level worker boundary** — OpenClaw's `run-backlog-worker.sh` provides a hardened worker boundary: timeout, PID tracking, log capture, model diagnostics, API key loading, exit code detection. Hermes `delegate_task` is simpler but less battle-tested for long autonomous work.

7. **delegate_task limitations** — Subagents cannot use `clarify`, `memory`, `send_message`, or `execute_code`. Subagents are cancelled if the parent session is interrupted. For truly long work, spawned processes are needed.

## 3. Suitability Assessment

### For current project status (MVP)

The MVP priority is the autonomous ownership loop: strategy → backlog → mutex → delegation → review → commit → reflection.

**OpenClaw** has the advantage here:
- The shell scripts implementing the autonomous loop already exist and are tested
- The overnight controller, watchdog, and report are implemented
- `verify.sh` validates the system end-to-end
- Deterministic orchestration means predictable behavior during the critical MVP phase

**Hermes** requires:
- The autonomous work loop to be orchestrated by the LLM (less predictable)
- Real-world testing to validate that cron + delegate_task + memory works reliably for multi-hour autonomous windows
- Building confidence that the LLM won't make bad orchestration decisions

**Verdict for MVP**: OpenClaw has a head start. The deterministic scripts are valuable for the first real autonomous runs.

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
| Flexible coding delegation | Hermes | Any model, any tool, delegate_task |
| Strategic memory | Hermes | Auto-injected, always present |
| Self-improvement | Hermes | Skills, memory, session_search |
| Team communication | Hermes | Multi-platform gateway |
| Repo hygiene | Hermes | No workspace artifacts |
| Debugging failed runs | OpenClaw | Explicit state files |
| Setup simplicity | Hermes | Profile + persona + skills |
| Test coverage | OpenClaw | 2400-line verify.sh |
| Provider flexibility | Hermes | 20+ providers |
| Autonomous work reliability | OpenClaw (currently) | Deterministic controller loop |

## 4. Recommendation

**Short-term**: Use the OpenClaw implementation for the first real autonomous runs. Its deterministic scripts and comprehensive tests reduce risk during MVP validation.

**Medium-term**: Run both implementations in parallel on a low-stakes project. Compare:
- Autonomous work reliability (does Hermes's LLM-driven loop produce equivalent outcomes?)
- Token cost (Hermes orchestration costs tokens; OpenClaw orchestration is free)
- Maintainability (how easy is it to fix issues in each?)
- Adaptability (how easy is it to add new behaviors?)

**Long-term**: Migrate to Hermes if the LLM-driven orchestration proves reliable. The flexibility, extensibility, and self-improvement capabilities are better aligned with the Junie Live vision. Consider porting the most valuable shell-script logic into Hermes skills or `no_agent` cron scripts as a hybrid approach.

**Hybrid approach** (recommended): Use Hermes as the primary platform with targeted shell scripts for critical deterministic paths. Hermes supports `no_agent` cron jobs that run scripts without an LLM, and the `terminal` tool can execute shell scripts. The best of both worlds: Hermes for orchestration + communication + memory, shell scripts for predictable autonomous loops.

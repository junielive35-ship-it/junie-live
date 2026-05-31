# tools.md — Local Operational References

<!--
This file is the Hermes-port equivalent of OpenClaw's workspace TOOLS.md.

It lives at ~/.hermes/profiles/junie-live/docs/tools.md (deployed from the seed
during hire) and serves as Junie's structured cheat-sheet for project paths,
development commands, git/PR conventions, mutex configuration, deployment,
analytics references, and local caveats.

Hermes does not auto-load this file. Use `read_file` to consult it (or load
specific sections into memory pointers) before relevant work. HERMES.md
instructs the agent to consult tools.md whenever build / lint / test / run /
deployment / branch / rollback / dashboard / mutex-escalation information is
needed.

During initialization, fill in placeholders ("TODO") based on inspection of the
target project. If a section genuinely does not apply (e.g. no analytics
dashboard yet), mark it "N/A" with a one-line reason instead of deleting the
section — that records the absence of the capability as a known fact.
-->

This file is guidance only. It documents local commands, paths, dashboards, and conventions for the assigned project; it does not grant permissions or tools.

## Project paths

- Repository: TODO
- Workspace / monorepo subdir (if relevant): TODO
- Related services or repos: TODO

## Communication

- Primary channel(s): TODO
- Owner / contact people: TODO
- Team / group chats: TODO
- Escalation path: TODO

## Development commands

Fill in after inspecting the project. Use the exact commands a developer would run.

- Install dependencies: TODO
- Build: TODO
- Test: TODO
- Lint / typecheck: TODO
- Run locally (dev server, REPL, or whatever the project actually exposes): TODO

If multiple variants exist (e.g. `make test` vs `pytest path/`), record both and note when to use each.

## Git and PR conventions

- Default branch: TODO
- Branch naming convention (e.g. `feature/*`, `fix/*`, ticket prefixes): TODO
- PR target / reviewer conventions: TODO
- CI checks to watch (names of required workflows / status checks): TODO
- Commit-message conventions, if the project enforces any: TODO

## Code mutex

- Protected repository / feature-area scope: TODO
- Mutex directory: `~/.hermes/profiles/junie-live/junie-live/state/code_mutex/` (profile-local)
- Holder metadata file: `~/.hermes/profiles/junie-live/junie-live/state/code_mutex/holder.json`
- Mutex commands: `$HERMES_PROFILE_DIR/scripts/code-mutex.sh status` / `acquire` / `release [--holder ID] [--force]` / `check-stale`
- Administrator / owner contact for held or stale mutex decisions: TODO
- Status-check convention (how often to poll, where to surface stuck holders): TODO

## Marinator delegation

- **Tool:** `marinator_delegate` (Hermes plugin, `marinator` toolset)
- **Plugin location:** `~/.hermes/profiles/junie-live/plugins/marinator-delegation/`
- **Run ledger:** `~/.hermes/profiles/junie-live/junie-live/state/marinator/runs/<job_id>/` (profile-local)
- **Run artifacts:** `spec.json`, `status.json`, `events.jsonl`, `result.md`, `opencode.stdout.log`, `opencode.stderr.log`, `runner.log`, `control/`, `locks/`
- **Worker script:** `plugins/marinator-delegation/scripts/marinator-worker.sh`
- **Runtime modes:** `live_gateway` (Telegram, uses `notify_on_complete`) or `headless` (uses `hermes chat --resume`)
- **Stall policy:** suspected stalls are recorded but never auto-killed; the orchestrator decides via `control/kill`
- **Progress reports:** enabled by default (debug visibility); `enable_per_minute_reports=false` only when user explicitly asks to disable
- **Deferred:** Kanban-backed Marinator, cron-bound session continuation

## Deployment / release

- Release process (manual? CI on tag? merge-to-main?): TODO
- Deployment command / dashboard / pipeline link: TODO
- Rollback procedure (exact command or runbook step): TODO
- Approval requirements (who signs off, when, for what change classes): TODO

## Product and analytics references

- Issue tracker / backlog (URL or tool name): TODO
- Analytics dashboard (URL): TODO
- Error reporting / log aggregation (URL or tool name): TODO
- Support / bug intake channel: TODO

## Local caveats

Record environment-specific gotchas future Junie runs should know about: flaky tests, services that must be started before tests, OS-specific quirks, secrets that are not in `.env`, anything that breaks on a fresh machine.

- TODO

## Maintenance rule

Update `tools.md` whenever a development command, git convention, deployment path, or escalation contact changes. Stale operational references are worse than missing ones — a wrong rollback command can cause real damage.

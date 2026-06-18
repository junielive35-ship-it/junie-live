# tools.md — Local Operational References

<!--
This file is Junie's structured cheat-sheet for the assigned project: project paths, development commands, git/PR conventions, deployment, analytics references, and local caveats.

Hermes does not auto-load this file. Use `read_file` to consult it (or load
specific sections into memory pointers) before relevant work. HERMES.md
instructs the agent to consult tools.md whenever build / lint / test / run /
deployment / branch / rollback / dashboard information is
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

## Senior Dev Kanban lane

- **Chat Agent tools:** `senior_active_tasks` (inspect active Senior tasks before routing) and `create_senior_task` (create/subscribe one Senior Dev Kanban task). Both live in the `senior-task` plugin under the `senior` toolset.
- **Senior worker tool:** `senior_run_coding_task` (Hermes plugin `senior-runner`, toolset `senior_runner`; enabled only for the `senior-dev` profile).
- **Senior worker protocol:** `kanban_show` → build structured handoff (`repo`, `user_outcome`, `acceptance_criteria`, `distilled_context`, `constraints`, `non_goals`, `expected_report_schema`) → `senior_run_coding_task` → read `result.md`/`status.json` + `exit_code` → `kanban_comment` → decide and apply exactly one terminal Kanban action (the runner emits no verdict).
- **Terminal outcomes (worker decides):** `kanban_block("review-required: ...")` is the default for successful code-changing work; `kanban_block("needs-input: ...")` only when external user/owner information is required; `kanban_block("failed: ...")` for execution/verification/requested-outcome failure (including `exit_code != 0`); `kanban_complete("done: ...")` only for genuinely terminal no-review work.
- **Senior executor:** installed `junie` CLI in headless mode, authenticated with `~/junie.key` and configured for Opus 4.8 by default.
- **Senior run ledger:** under the Senior Dev profile's per-project state directory by default; tests may override with `SENIOR_RUNNER_BASE`.
- **Run artifacts:** `prompt.md`, `spec.json`, `status.json`, `events.jsonl`, `result.md`, `junie.stdout.log`, `junie.stderr.log`, `runner.log`.
- **Follow-up routing:** if a related task is `blocked`, add a comment with the user's follow-up and unblock/requeue only when the follow-up answers the `review-required` or `needs-input` ask.
- **Companion profile install:** handled by the Junie installation/rehire scripts when the distribution includes a Senior Dev companion profile.

## Deployment / release

- Release process (manual? CI on tag? merge-to-main?): TODO
- Deployment command / dashboard / pipeline link: TODO
- Rollback procedure (exact command or runbook step): TODO
- Approval requirements (who signs off, when, for what change classes): TODO

## Product and analytics references

- Issue tracker / task board (URL or tool name): TODO
- Analytics dashboard (URL): TODO
- Error reporting / log aggregation (URL or tool name): TODO
- Support / bug intake channel: TODO

## Local caveats

Record environment-specific gotchas future Junie runs should know about: flaky tests, services that must be started before tests, OS-specific quirks, secrets that are not in `.env`, anything that breaks on a fresh machine.

- TODO

## Maintenance rule

Update `tools.md` whenever a development command, git convention, deployment path, or escalation contact changes. Stale operational references are worse than missing ones — a wrong rollback command can cause real damage.

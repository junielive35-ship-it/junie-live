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

## Senior Dev handoff runtime

- **Team Lead role:** collect repository path, user-visible outcome, acceptance criteria, distilled context, constraints, non-goals, and expected report schema before sending code-changing work to Senior Dev.
- **Senior Dev role:** headless Junie CLI owns implementation, review, verification, fix loop, and final verdict end-to-end after handoff.
- **Final verdict schema:** `done`, `needs-input`, or `failed`, with exact verification commands/results or a clear reason verification could not run.
- **Team Lead tools:** use `create_senior_task` to create/subscribe to a Senior Dev handoff and `senior_active_tasks` to inspect active or pending Senior Dev work. Kanban follow-up tools such as `kanban_comment` and `kanban_block` are for task coordination and blocker reporting, not for Team Lead code review.
- **Senior Dev runner:** `senior_run_coding_task` is available to the Senior Dev companion profile for one synchronous headless Junie CLI run per coding task.
- **Senior executor:** installed `junie` CLI in headless mode, authenticated through the configured Junie CLI auth path for this machine/profile.
- **Senior run ledger/artifacts:** record the configured artifact location during initialization if the local runtime exposes one; include prompts/specs/status/logs/result files when available.
- **Follow-up routing:** if Senior Dev returns `needs-input`, answer the exact missing-input question or create a clarified follow-up handoff. Do not treat follow-up routing as Team Lead code review.
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

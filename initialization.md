# Junie Live Initialization Directory

`junie-live/initialization/` contains the reusable seed workspace for creating a new Junie Live instance for any project or feature area.

These files are copied into an OpenClaw workspace before the first run of a new Junie Live agent. They are not the initialized identity of a specific project. They are the starting scaffold that tells Junie how to initialize itself.

Alongside the guidance seed, `initialization/` also bundles the project-agnostic runtime assets every working Junie Live instance needs:

- `initialization/scripts/` — operational scripts such as code-mutex helpers, PR/CI helpers, reflection, and the MD/table consistency checkers.
- `initialization/marinator-delegation/` — the OpenClaw plugin that exposes the `marinator_delegate` tool and drives the bounded opencode runner it bundles at `initialization/marinator-delegation/scripts/delegate-coding-task.sh`.

`hire-junie.sh` copies these into the workspace, installs (copies) the plugin from the workspace copy, and patches OpenClaw config (tools allowlist and runtime models) so a hired instance can delegate coding work without manual setup. The plugin bundles its runner under its own `scripts/` directory and resolves it relative to the plugin package, so the plugin is self-contained and works under any install shape (copy, npm, ClawHub) without depending on this source repo's path. These assets are project-agnostic: they work the same for any target project.

After hire, the expected runtime layout is:

- workspace `marinator-delegation/` — installed (copied) OpenClaw plugin directory;
- runner bundled in the plugin, copied from `initialization/marinator-delegation/scripts/delegate-coding-task.sh` — supervised opencode runner used by `marinator_delegate`;
- workspace Marinator run state directory — per-run durable state with `spec.json`, `status.json`, `events.jsonl`, logs, `opencode.exit`, and a result artifact when available.

The hire flow must also make the `marinator-delegation` plugin visible under coding tool profiles via `tools.alsoAllow`, register `openrouter/openai/gpt-4.1-mini` for progress summaries, and install/link the plugin with the explicit unsafe-install bypass because the runner starts a child process. The runner reports concise progress as observability, but task granularity still follows the Marinator acceptance loop. Every run should reach an explicit terminal status (`completed`, `failed`, `timeout`, `killed`, or `stalled`) and wake the orchestrator so half-finished work is not silently abandoned.

Code-changing work initialized from this seed uses the mutex protocol described in [`code_mutex.md`](code_mutex.md).

## MVP setup flow

For the current MVP, a new Junie Live instance is created roughly like this:

1. Copy files from `junie-live/initialization/` into `.openclaw/workspace`.
2. Run OpenClaw with the new agent workspace.
3. Give Junie:
   - the path to the target project;
   - means of communication (contact persons, group chats, etc.; for MVP, Telegram only);
   - the area of responsibility;
   - expectations, constraints, and team/product context.
4. Junie follows `INITIALIZATION.md` to inspect the target project, ask questions across as many rounds as needed, resolve contradictions, and produce a coherent durable identity.

Concrete autonomous-window, backlog, watchdog, or executor scheduling implementations are project-dependent. They should not be assumed to exist just because the seed workspace was copied.

## What belongs in `initialization/`

Only project-agnostic Junie Live seed files belong here.

They may describe:

- how Junie initializes when assigned to a project;
- Junie's generic senior product-owning SWE persona;
- generic operating protocol: validation, challenge behavior, delegation, review, approvals;
- generic recurring-check guidance;
- templates for project-specific files such as `MEMORY.md`, `TOOLS.md`, and `docs/`;
- reusable skills such as task reflection.
- project-agnostic runtime assets every instance needs: operational scripts in `initialization/scripts/` and the `initialization/marinator-delegation/` delegation plugin.

The files should make sense if copied into a workspace for any target project, for example:

- an online wine shop;
- a mobile onboarding feature;
- an internal admin system;
- a backend service;
- a game feature area.

## What does not belong in `initialization/`

Do not put Junie Live product-development state here.

Avoid references such as:

- “Junie Live MVP currently does/does not implement X”;
- “this will be implemented in v2”;
- repo-local roadmap notes;
- development status of `~/code/junie-live`;
- project-specific facts from any one target project;
- assumptions that only make sense for the Junie Live repository itself.

Those belong in the root Junie Live product docs, not in the reusable seed workspace.

A good test: after copying `initialization/` into a workspace for “Wines Online Shop”, every file should still read naturally and usefully.

## Seed files vs initialized files

Before initialization:

- files from `initialization/` are templates/seeds;
- they define generic Junie Live behavior;
- `MEMORY.md`, `TOOLS.md`, and `docs/` may contain TODOs or placeholders;
- `INITIALIZATION.md` keeps the workspace in durable initialization mode across turns.

After initialization:

- the copied files become the durable identity of one concrete Junie instance;
- `MEMORY.md` contains compact strategy for the assigned project;
- `docs/` contains detailed project knowledge;
- `TOOLS.md` contains local operational references;
- `INITIALIZATION.md` is deleted or archived by Junie after initialization is complete.

## Layering rule

Seed guidance may say “during initialization, discover X and record it.” It should not hard-code the result of that discovery for the Junie Live repository.

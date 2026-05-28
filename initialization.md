# Junie Live Initialization Directory

`junie-live/initialization/` contains the reusable seed workspace for creating a new Junie Live instance for any project or feature area.

These files are copied into an OpenClaw workspace before the first run of a new Junie Live agent. They are not the initialized identity of a specific project. They are the starting scaffold that tells Junie how to initialize itself.

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

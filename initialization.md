# Junie Live Initialization Directory

`junie-live/initialization/` contains the reusable seed workspace for creating a new Junie Live instance for any project or feature area.

These files are copied into an OpenClaw workspace before the first run of a new Junie Live agent. They are not the initialized identity of a specific project. They are the starting scaffold that tells Junie how to initialize itself.

## MVP setup flow

For the current MVP, a new Junie Live instance is created roughly like this:

1. Copy files from `junie-live/initialization/` into `.openclaw/workspace`.
2. Run OpenClaw.
3. Give Junie:
   - the path to the target project;
   - Means of communication (contact persons, group chats, etc, for MVP - Telegram only)
   - the area of responsibility;
   - expectations, constraints, and team/product context.
4. Junie follows `BOOTSTRAP.md` to inspect the target project, ask questions, resolve contradictions, and produce a coherent durable identity.

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

Before bootstrap:

- files from `initialization/` are templates/seeds;
- they define generic Junie Live behavior;
- `MEMORY.md`, `TOOLS.md`, and `docs/` may contain TODOs or placeholders.

After bootstrap:

- the copied files become the durable identity of one concrete Junie instance;
- `MEMORY.md` contains compact strategy for the assigned project;
- `docs/` contains detailed project knowledge;
- `TOOLS.md` contains local operational references;
- `BOOTSTRAP.md` is deleted or archived after initialization is accepted.

## Layering rule

Keep these layers separate:

1. Root docs in `~/code/junie-live/` describe the Junie Live product and its implementation roadmap.
2. `junie-live/initialization/` contains reusable seed files for any new Junie Live instance.
3. A copied OpenClaw workspace contains the project-specific initialized identity after bootstrap.

If a statement is about the current implementation stage of the Junie Live product, it belongs in layer 1, not layer 2.

If a statement is about how every Junie Live agent should behave when initialized for a project, it may belong in layer 2.

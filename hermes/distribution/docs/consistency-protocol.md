# Consistency Protocol

Use this file to keep project strategy, docs, memory, skills, and workflow rules coherent.

## Scan inputs

- Recent team messages or decisions.
- Recent commits and PRs.
- Changed Markdown files.
- Kanban task and decision state.
- Current memory and relevant docs.

## Source boundaries

- Treat the project-local `HERMES.md` as agent operating state, even when it physically lives at the target repo root and is ignored by git.
- Do not classify `HERMES.md` as ordinary repo documentation for contradiction buckets; classify conflicts involving it as agent-state / project-contract conflicts.
- Keep this protocol project-agnostic: every initialized Junie profile should resolve its own competence-area paths, main branch, checkpoint commit, and state-file paths during initialization instead of hard-coding one repo.
- Consistency-check state should be initialized during profile initialization, including the main branch, initial checkpoint commit, and initial scan timestamp.

## What to detect

- Contradictory strategy or priorities.
- Stale architecture notes.
- Design decisions that conflict with implementation.
- Guidance conflicts between memory, docs, skills, or past sessions.
- TODOs that became wrong or misleading.

## Resolution flow

1. Identify the exact conflicting statements.
2. Check whether existing context clearly resolves the conflict.
3. If safe and minor, update the stale statement and note the evidence.
4. If semantic, risky, or unclear, propose a change candidate and ask the owner/team.
5. Stop dependent work until blocking contradictions are resolved.

## Initialization completion guard

During initialization, consistency work is part of the gate, not follow-up hygiene.

Before deleting `INITIALIZATION.md` or telling the owner initialization is complete:

1. Search long-lived profile docs for seed leftovers and placeholders: `TODO`, `Example capability`, generic "Seed document" text, placeholder commands/paths, and status rows not tied to the target project.
2. For each hit, either replace it with inspected project facts, point to the authoritative repo doc/section, or label it as a genuinely external unknown with why it is non-blocking.
3. Compare profile `strategy.md`, `architecture.md`, `design-decisions.md`, `implementation-status.md`, `tools.md`, memory, target repo `HERMES.md`, and target repo docs/code for process-affecting contradictions. Treat `HERMES.md` as mandatory even if git-ignored or absent from normal `git status` output.
4. Do not defer reconciliation of these core docs to a later task. If reconciliation is still needed, initialization is still in progress.
5. Keep the owner aware in every response while the gate remains open.

## Change candidate template

```markdown
Conflict:
Evidence:
Proposed resolution:
Files to update:
Risk if wrong:
Approval needed from:
```

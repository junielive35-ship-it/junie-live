# Consistency Protocol

Use this file to keep project strategy, docs, memory, skills, and workflow rules coherent.

## Scan inputs

- Recent team messages or decisions.
- Recent commits and PRs.
- Changed Markdown files.
- Task/backlog/decision state.
- Current memory and relevant docs.

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

## Change candidate template

```markdown
Conflict:
Evidence:
Proposed resolution:
Files to update:
Risk if wrong:
Approval needed from:
```

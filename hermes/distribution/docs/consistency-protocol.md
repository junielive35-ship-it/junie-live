# Consistency Protocol

Use this file to keep project strategy, docs, memory, skills, and workflow rules coherent.

## Scan inputs

- Recent team messages or decisions.
- Recent commits and PRs.
- Changed Markdown files.
- Task/backlog/decision state.
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
4. Do not create a backlog/autonomous-work item to reconcile these core docs after completion. If reconciliation is still needed, initialization is still in progress.
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

---

## Runner architecture

The consistency check is a **maintenance entrypoint**, not a model-loop tool.

- **Shared Python runner:** installed at `$PROFILE_DIR/scripts/consistency_check.py` (seed source: `hermes/distribution/scripts/consistency_check.py`)
- **Subcommands:** `init` (initialize state), `run` (full check), `render-prompt` (dry-run)
- **No model-loop tool:** The runner is not registered as a callable tool in the orchestrator's schema. Invoke directly:
  ```bash
  python3 "$PROFILE_DIR/scripts/consistency_check.py" run --repo <path>
  ```

### Runtime dependency

The runner uses `junie_runtime` for path resolution, mutex operations, state I/O, and event logging rather than duplicating those primitives:

| Concern | Source |
|---|---|
| Profile state root | `junie_runtime.paths.state_root()` |
| Code mutex directory | `junie_runtime.paths.mutex_dir()` |
| Mutex acquire / release | `junie_runtime.mutex.acquire()` / `.release()` |
| JSON / text read/write | `junie_runtime.state.read_json()` / `.atomic_write_json()` etc. |
| JSONL event append | `junie_runtime.events.append_event()` |

## State

State lives under the profile-local state tree (`<state_root>/consistency/`):

```
<state_root>/consistency/
  consistency-state.json
  PENDING_CONTRADICTIONS.md
  runs/<run_id>/
    input.json
    prompt.md
    agent-output.md
    report.md
    events.jsonl
    status.json
```

### `consistency-state.json` schema

```json
{
  "schema_version": 1,
  "main_branch": "main",
  "last_checkpoint_commit": "<sha>",
  "last_scan_at": "<iso8601>",
  "last_successful_run_id": "<run_id>",
  "relevant_artifacts": [
    {
      "path": "junie-live-architecture.jpg",
      "kind": "architecture_diagram",
      "topics": ["orchestration", "maintenance routines"],
      "source": "initialization|check|manual"
    }
  ]
}
```

## Preflight (fail-fast order)

1. Resolve repo and state paths.
2. Check/acquire the code mutex via `junie_runtime.mutex.acquire()`. If `MutexHeldError` is raised, write blocked run artifacts and exit non-zero.
3. Check target repo worktree cleanliness. If dirty, write blocked run artifact and exit non-zero.
4. Run `git fetch --prune`. If fetch fails, block.
5. Verify current branch equals configured `main_branch`. If not, block.
6. Verify local main is not stale/diverged from upstream when upstream exists. If diverged, block.
7. Read `last_checkpoint_commit` and compute diff range.
8. Create run dir and `input.json`.

Failed/blocked runs do **not** update the checkpoint.

## Checkpoint updates

- Checkpoint is updated after a successful completed consistency check, regardless of remaining pending contradictions.
- Failed/blocked runs do not move the checkpoint.

## Verification

- `python3 -m py_compile hermes/distribution/scripts/consistency_check.py`
- Full consistency check tests via `python3 hermes/scripts/test_consistency_check.py`
- Tests use temp dirs/repos and must not touch the live profile.

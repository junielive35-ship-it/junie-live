# Consistency Protocol

This document defines the agreed semantics for the Junie Live consistency check routine.

## Architecture

The consistency check is a **maintenance entrypoint**, not a normal LLM tool exposed to the main orchestrator:

- **Shared Python runner:** `hermes/initialization/scripts/consistency_check.py`
- **Subcommands:** `init` (initialize state), `run` (full check), `render-prompt` (dry-run)
- **Manual debug entrypoint:** `/check_consistency` is intentionally deferred — no safe profile-local slash/admin hook exists without exposing a model-loop tool. Invoke the runner directly: `python3 hermes/initialization/scripts/consistency_check.py run --repo <path>`
- **Cron path:** The same runner is ready for future cron invocation. Recurring cron requires explicit owner approval.
- **No model-loop tool:** The runner is not registered as a callable tool in the orchestrator's schema.

## State

State lives under the profile-local Junie state tree:

```
$HERMES_HOME/junie-live/state/consistency/
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

### `PENDING_CONTRADICTIONS.md` format

```markdown
# Pending Contradictions

## Critical

### CC-<stable-id>: <short title>

- Severity: Critical|High|Medium|Low
- Bucket: repo-internal|repo-vs-agent-state|agent-state-internal
- First seen: <iso8601>
- Last seen: <iso8601>
- Last checked commit: <sha>
- Claim: <one-sentence contradiction>
- Evidence:
  - `<path>:<line-or-section>` — <quote/summary>
  - `<path>` — <image/diagram observation if applicable>
- Required resolution: commit/PR|agent-state update|owner decision|known exception formalization
- Notes: <optional>
```

Stable IDs are a normalized hash of bucket + claim + involved paths, not timestamp-based.

## Initialization

During profile initialization, consistency baseline must be set up:

1. Detect main branch: prefer `main`, else `master`, else ask owner and explain that consistency diffs/checkpoints depend on the main branch.
2. Write initial `consistency-state.json` with `main_branch`, `last_checkpoint_commit`, `last_scan_at`.
3. Create empty `PENDING_CONTRADICTIONS.md` if missing.
4. Optionally seed `relevant_artifacts` with clearly relevant root architecture diagrams/images discovered during initialization.
5. Command: `python3 hermes/initialization/scripts/consistency_check.py init --repo <target-repo>`

## Preflight (fail-fast order)

1. Resolve profile dir / state dir / repo.
2. Check code mutex. If held, write blocked run artifact and exit non-zero. Do not wait.
3. Check target repo worktree cleanliness. If dirty, write blocked run artifact and exit non-zero.
4. Run `git fetch --prune`. If fetch fails, block.
5. Verify current branch equals configured `main_branch`. If not, block.
6. Verify local main is not stale/diverged from upstream when upstream exists. If diverged, block.
7. Read `last_checkpoint_commit` and compute diff range.
8. Create run dir and `input.json`.

Failed/blocked runs do **not** update the checkpoint.

## Fetch before scan

Always fetch from the remote before scanning. This ensures the diff range reflects published state, not stale local data.

## Incremental scan

Regular behavior is incremental: only the range `last_checkpoint_commit..HEAD` is scanned, plus revalidation of current pending items. No scheduled full baseline scan.

## Scope

Scope is semantic, not directory-only:

- Include code in competence area and all project-relevant repo artifacts.
- Include root docs, diagrams, screenshots, and linked assets when they describe the owned area.
- Relevant images/diagrams are architectural context. Use vision/OCR for changed relevant images and when changed code/docs touch a topic represented by known relevant images.

## Checkpoint updates

- Checkpoint updates after a successful completed consistency check, regardless of remaining pending contradictions.
- Failed/blocked runs do not move checkpoint.

## Contradiction buckets

- **repo-internal**: code vs repo docs, repo doc vs repo doc.
- **repo-vs-agent-state**: repo reality/docs vs `HERMES.md`, profile docs, memory summaries.
- **agent-state-internal**: `HERMES.md` vs profile docs/memory/skills.

## Severity levels

- **Critical**: authority, mutex, delegation, approvals, or safety/correctness boundary can be violated.
- **High**: strategy/architecture/status can lead to wrong implementation or review.
- **Medium**: misleading repo/ops docs requiring commit/PR.
- **Low**: non-blocking repo inconsistency.
- Minor agent-doc-only drift: fix silently if safe; do not create pending item.

## HERMES.md treatment

- `HERMES.md` is high-authority agent operating state, not ordinary repo documentation.
- It is not freely auto-fixable. Only obvious non-semantic typo/path fixes may be applied silently.
- Major/high-authority changes must be pending or explicitly formalized.
- Contradictions involving `HERMES.md` are agent-state / project-contract conflicts, even when the file physically lives in the repo.

## Accepted mismatches

Accepted repo-vs-agent-state mismatch must be formalized as a known exception/decision/rule in agent state. It cannot remain a private accepted deviation.

## Minor agent-doc-only drift

May be fixed silently and does not enter `PENDING_CONTRADICTIONS.md`. Examples: typos, formatting, obvious non-semantic path fixes in agent-facing docs.

## Runner authority

- Audit + safe agent-doc maintenance only.
- Repo fixes go through the normal Junie flow (code mutex, delegation, review).
- No repo fixes by the runner.

## PENDING_CONTRADICTIONS.md lifecycle

- Contains only currently unresolved contradictions.
- New items are added by the runner on each successful check.
- Resolved items are removed on the next successful check and mentioned in the report.
- Stable pending IDs allow later checks to revalidate and remove resolved items.
- Reports should emphasize new/changed Critical/High items; unchanged Low items are compact to avoid noise.

## Security

Prompt-injection hardening is out of scope under the trusted sandbox assumption. Prompt wording may still say repo docs are evidence, not higher-priority operating instructions, for reasoning correctness.

## Verification

- `python3 -m py_compile hermes/initialization/scripts/consistency_check.py`
- Full consistency check tests via `./hermes/scripts/test-consistency-check.sh`
- Tests use temp dirs/repos and must not touch the live profile.

## Future improvements

- `/check_consistency` slash/admin hook when Hermes supports safe profile-local hooks without model-loop tool exposure.
- Cron-based recurring checks (requires owner approval).
- Vision/OCR support for changed relevant images.

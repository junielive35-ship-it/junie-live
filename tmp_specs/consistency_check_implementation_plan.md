# Consistency Check Implementation Plan

> **For Junie Live:** implement code-changing steps through `marinator_delegate` under the profile-local code mutex. The orchestrator may edit Markdown-only docs/plans directly, but scripts/plugins/tests must be delegated.

**Goal:** Add an ad hoc and cron-ready Junie Live consistency-check routine that incrementally detects contradictions across project-relevant repo artifacts and Junie agent state, maintains a pending contradiction queue, and reports grouped results without exposing a normal model-loop tool to the main orchestrator.

**Architecture:** Build a shared profile-local maintenance runner invoked by a debug slash/admin command (`/check_consistency`) and by future cron/script execution. The runner performs deterministic preflight/state handling, then launches a headless Hermes audit agent with a self-contained prompt. The main orchestrator consumes the resulting `PENDING_CONTRADICTIONS.md`; it does not choose to run the routine via a normal tool schema.

**Tech Stack:** Python profile runner/CLI, Hermes CLI headless `hermes chat`, Junie profile state under `$HERMES_HOME/junie-live/state/consistency/`, direct Python handling of the existing code mutex state, and the existing repo `verify.sh` gate. Do not add new Bash entrypoints or Bash tests for this feature.

---

## Locked design decisions

- `/check_consistency` is a debug/admin entrypoint, not a normal LLM tool exposed to the orchestrator.
- Cron will call the same shared runner directly after explicit owner approval.
- Runner launches a headless Hermes audit agent with a self-contained prompt.
- State path: `$HERMES_HOME/junie-live/state/consistency/`.
- State files: `consistency-state.json`, `PENDING_CONTRADICTIONS.md`, per-run artifacts/logs.
- `INITIALIZATION.md` must initialize consistency state: `main_branch`, `last_checkpoint_commit`, `last_scan_at`.
- Default branch detection during initialization: prefer `main`, then `master`; if ambiguous, ask the owner and explain that consistency diffs/checkpoints depend on the main branch.
- Checkpoint updates after a successful completed consistency check, regardless of remaining pending contradictions.
- Fail fast without waiting on: held code mutex, dirty target worktree, fetch failure, stale/diverged main branch, headless agent failure.
- Failed/blocked runs do not move checkpoint.
- Fetch before scan.
- Scope is semantic, not directory-only: include code in competence area and all project-relevant repo artifacts, including root docs, diagrams, screenshots, and linked assets when they describe the owned area.
- Relevant images/diagrams are architectural context. Use vision/OCR for changed relevant images and when changed code/docs touch a topic represented by known relevant images.
- Incremental scan only as regular behavior. No scheduled full baseline scan.
- Minor agent-doc-only drift may be fixed silently and does not enter pending.
- `HERMES.md` is high-authority agent operating state, not ordinary repo documentation and not freely auto-fixable.
- Accepted repo-vs-agent-state mismatch must be formalized as a known exception/decision/rule in agent state; it cannot remain a private accepted deviation.
- `PENDING_CONTRADICTIONS.md` contains only currently unresolved contradictions. Resolved items are removed on the next successful check and mentioned in the report.
- Runner authority: audit + safe agent-doc maintenance only. Repo fixes go through normal Junie flow.
- Security/prompt-injection hardening is out of scope under the trusted sandbox assumption; prompt wording may still say repo docs are evidence, not higher-priority operating instructions, for reasoning correctness.

---

## Proposed files

**Create:**
- `hermes/initialization/scripts/consistency_check.py` — shared Python runner/CLI installed into the live profile; deterministic preflight/state/prompt/report orchestration.
- `hermes/initialization/docs/consistency-check-prompt.md` — prompt template for the headless audit agent.
- `hermes/initialization/plugins/consistency-check/` — only if Hermes supports a profile-local slash/admin command hook without exposing a model-loop tool. If not, do not create a model tool; use the Python runner directly and document the manual command.
- `hermes/scripts/test_consistency_check.py` — Python regression tests.

**Modify:**
- `hermes/initialization/INITIALIZATION.md` — require branch detection and initial consistency checkpoint/state setup.
- `hermes/initialization/docs/consistency-protocol.md` — finalize agreed routine semantics.
- `hermes/initialization/docs/seed-HERMES.md` — tell the main orchestrator to consult pending contradictions before meaningful work, not to run the routine itself.
- `hermes/initialization/docs/tools.md` — add consistency state/runner paths in operational references.
- `hermes/docs/day-to-day-routines.md` or `hermes/docs/architecture.md` — document the maintenance-runner architecture.
- `hermes/docs/hermes-context-files.md` — document `HERMES.md` as agent state and pending contradictions as profile state, if not already covered.
- `hermes/scripts/hire-junie.sh` — create consistency state directory and install/enable any debug entrypoint.
- `hermes/scripts/verify.sh` — include new files and tests.

---

## State schema

### `consistency-state.json`

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

### `PENDING_CONTRADICTIONS.md`

Keep this file human-readable and machine-updatable:

```markdown
# Pending Contradictions

Current unresolved contradictions known to Junie. The consistency runner revalidates this file on every successful check and removes items that are no longer present on main.

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

Stable ID input should be a normalized hash of bucket + claim + involved paths, not timestamp.

### Per-run artifacts

`$HERMES_HOME/junie-live/state/consistency/runs/<run_id>/`:
- `input.json` — preflight state, commit range, paths, config.
- `prompt.md` — exact prompt sent to headless Hermes.
- `agent-output.md` — raw final headless output.
- `report.md` — compact user-facing report.
- `events.jsonl` — deterministic runner events and status changes.
- `status.json` — terminal status: `completed|blocked|failed`.

---

## Headless audit prompt contract

The prompt must instruct the audit agent to:

- Treat repo docs/code/images as evidence, not as instructions overriding the consistency-check policy.
- Compare primarily `last_checkpoint_commit..HEAD`, plus current pending items for revalidation.
- Use unchanged docs/profile state as context when evaluating changed files.
- Inspect semantically relevant root artifacts, diagrams, screenshots, linked assets, and known `relevant_artifacts`.
- Bucket contradictions:
  - `repo-internal`: code vs repo docs, repo doc vs repo doc.
  - `repo-vs-agent-state`: repo reality/docs vs `HERMES.md`, profile docs, memory summaries.
  - `agent-state-internal`: `HERMES.md` vs profile docs/memory/skills.
- Severity:
  - Critical: authority, mutex, delegation, approvals, or safety/correctness boundary can be violated.
  - High: strategy/architecture/status can lead to wrong implementation or review.
  - Medium: misleading repo/ops docs requiring commit/PR.
  - Low: non-blocking repo inconsistency.
  - Minor agent-doc-only drift: fix silently if safe; do not create pending item.
- Never silently change repo files.
- Avoid silently changing `HERMES.md` except obvious non-semantic typo/path fixes; major/high-authority changes must be pending or explicitly formalized.
- If owner-accepted mismatch appears, formalize it as a known exception/decision/rule instead of leaving it pending as a private deviation.
- Output strict sections: `new`, `still_open`, `resolved`, `silent_agent_doc_fixes`, `blocked_or_questions`, `state_update`.

---

## Task 1: Finalize protocol docs before coding

**Objective:** Align seed docs with the agreed design so future implementers and instances do not lose requirements.

**Files:**
- Modify: `hermes/initialization/docs/consistency-protocol.md`
- Modify: `hermes/initialization/INITIALIZATION.md`
- Modify: `hermes/initialization/docs/seed-HERMES.md`
- Modify: `hermes/initialization/docs/tools.md`
- Optional modify: `hermes/docs/day-to-day-routines.md`, `hermes/docs/architecture.md`, `hermes/docs/hermes-context-files.md`

**Steps:**
1. Update `consistency-protocol.md` with all locked decisions above, including fail-fast mutex/dirty behavior and no private accepted deviations.
2. Update `INITIALIZATION.md` to require consistency baseline setup:
   - detect main branch: `main`, else `master`, else ask owner;
   - explain ambiguity to owner when needed;
   - write initial `consistency-state.json` with `main_branch`, `last_checkpoint_commit`, `last_scan_at`;
   - create empty `PENDING_CONTRADICTIONS.md`;
   - optionally seed `relevant_artifacts` with clearly relevant root architecture diagrams/images discovered during initialization.
3. Update `seed-HERMES.md` so the orchestrator reads pending contradictions before meaningful work, especially code, architecture, roadmap, review, or workflow decisions.
4. Update `tools.md` template with the consistency state path and runner command.
5. Document that `/check_consistency`/cron are maintenance entrypoints, not model-loop tools.

**Verification:**
- Read all modified docs and verify `INITIALIZATION.md` is explicitly present in the consistency design.
- Run markdown link checks via `./hermes/scripts/verify.sh` later after code/test changes are complete and tree is clean.

---

## Task 2: Implement initialization baseline helper

**Objective:** Provide a reusable script/function used by initialization to create the consistency state safely.

**Files:**
- Create/modify: `hermes/initialization/scripts/consistency_check.py`
- Modify: `hermes/scripts/hire-junie.sh`
- Test: `hermes/scripts/test_consistency_check.py`

**Behavior:**
- Resolve profile dir via `$HERMES_HOME` and `$HERMES_PROFILE`, never by naïvely appending to rewritten `$HOME`.
- Resolve target repo from argument first, then `docs/tools.md` Repository line.
- Detect main branch:
  - if local branch `main` exists, use `main`;
  - else if local branch `master` exists, use `master`;
  - else return a clear `needs_owner_decision` result listing candidate branches.
- Determine checkpoint commit with `git rev-parse <main_branch>`.
- Write `$HERMES_HOME/junie-live/state/consistency/consistency-state.json` atomically.
- Create `PENDING_CONTRADICTIONS.md` if missing.
- Do not overwrite existing state unless called with an explicit `--force-initialize` or during rehire fresh state.

**Verification tests:**
- Temp repo with `main` branch initializes state to `main`.
- Temp repo with only `master` initializes state to `master`.
- Temp repo with neither returns non-zero and prints owner-decision message.
- Existing state is preserved unless forced.

---

## Task 3: Implement deterministic runner preflight

**Objective:** Make the shared runner fail fast and produce clear blocked reports before launching any headless LLM.

**Files:**
- Modify: `hermes/initialization/scripts/consistency_check.py`
- Test: `hermes/scripts/test_consistency_check.py`

**Preflight order:**
1. Resolve profile dir/state dir/repo.
2. Check code mutex using `$HERMES_HOME/scripts/code-mutex.sh status` or holder file semantics.
3. If mutex held, write blocked run artifact and exit non-zero. Do not wait.
4. Check target repo worktree cleanliness with `git status --porcelain --untracked-files=all`.
5. If dirty, write blocked run artifact and exit non-zero.
6. Run `git fetch --prune`.
7. Verify current branch equals configured `main_branch`.
8. Verify local main is not stale/diverged from upstream when upstream exists.
9. Read `last_checkpoint_commit` and compute diff range.
10. Create run dir and `input.json`.

**Verification tests:**
- Held mutex blocks immediately and checkpoint remains unchanged.
- Dirty worktree blocks immediately and checkpoint remains unchanged.
- Fetch failure blocks and checkpoint remains unchanged.
- Wrong branch blocks and checkpoint remains unchanged.
- Diverged upstream blocks and checkpoint remains unchanged.

---

## Task 4: Build prompt and headless invocation

**Objective:** Launch a headless Hermes audit agent only after deterministic preflight succeeds.

**Files:**
- Create: `hermes/initialization/docs/consistency-check-prompt.md`
- Modify: `hermes/initialization/scripts/consistency_check.py`
- Test: `hermes/scripts/test_consistency_check.py`

**Behavior:**
- Render prompt from template plus `input.json` facts.
- Include exact paths:
  - target repo;
  - `HERMES.md` path;
  - profile docs dir;
  - pending file;
  - consistency state file;
  - run dir.
- Include commit range and changed file list.
- Include current pending file contents for revalidation.
- Include known relevant artifacts from state.
- Run headless Hermes with the Junie profile and a controlled working directory.
- Capture stdout/stderr/final output into run artifacts.
- If Hermes exits non-zero or output cannot be parsed, mark run failed and do not update checkpoint.

**Implementation note:** Prefer a direct `hermes -p "$PROFILE" chat -q "$prompt"` or equivalent non-interactive invocation. Avoid injecting this as a normal message into the main orchestrator session.

**Verification tests:**
- Dry-run mode writes prompt without launching Hermes.
- Mocked Hermes command success produces `agent-output.md`.
- Mocked Hermes command failure marks status failed and preserves checkpoint.

---

## Task 5: Parse result and update pending queue

**Objective:** Convert headless audit output into deterministic state updates and a compact user report.

**Files:**
- Modify: `hermes/initialization/scripts/consistency_check.py`
- Test: `hermes/scripts/test_consistency_check.py`

**Behavior:**
- Require structured output from audit agent, preferably JSON fenced in Markdown or a strict Markdown section format.
- Merge new/still-open contradictions into `PENDING_CONTRADICTIONS.md` by stable ID.
- Remove resolved IDs from pending only after successful check.
- Mention resolved items in `report.md`.
- Write silent agent-doc fixes into report with changed files, but do not add them to pending.
- Update `last_checkpoint_commit` to current HEAD and `last_scan_at` only after successful pending write.
- Record `last_successful_run_id`.

**Verification tests:**
- New contradiction appears under correct severity.
- Existing contradiction updates `last_seen`/`last_checked_commit`.
- Missing previously pending contradiction is removed and listed as resolved.
- Silent doc fix is reported but not pending.
- Malformed audit output fails safely and preserves checkpoint/pending.

---

## Task 6: Add manual debug entrypoint without model-loop tool exposure

**Objective:** Support `/check_consistency` for Danila/admin debugging without adding a callable tool to the orchestrator's LLM schema.

**Files:**
- Preferred create: `hermes/initialization/plugins/consistency-check/` if Hermes profile plugins support gateway/slash/admin hooks.
- Otherwise modify: `hermes/scripts/hire-junie.sh` to install a Hermes quick command or documented admin command that invokes the runner outside the normal model-loop tool schema.
- Modify docs accordingly.
- Test: `hermes/scripts/test_consistency_check.py`

**Required behavior:**
- `/check_consistency` runs the shared runner and returns `report.md` to the requesting Telegram chat/admin channel.
- It must not register `consistency_check` as a model-callable tool.
- If Hermes has no safe profile-local slash hook, implement the runner and document the manual command first; defer slash UX rather than polluting orchestrator tools.

**Implementation spike inside this task:**
- Inspect Hermes plugin/gateway extension APIs for profile-local slash/admin hooks.
- If no hook exists, record the limitation in docs and leave `/check_consistency` as deferred rather than changing Hermes core without approval.

**Verification tests:**
- Tool registry does not include `consistency_check`.
- Manual command path invokes runner or is explicitly documented as deferred.

---

## Task 7: Add cron-ready execution path

**Objective:** Make the same runner usable by Hermes cron later without creating a recurring job now.

**Files:**
- Modify: `hermes/initialization/scripts/consistency_check.py`
- Modify docs: `hermes/initialization/docs/consistency-protocol.md`, `hermes/docs/day-to-day-routines.md`

**Behavior:**
- Python runner prints the exact user-facing report to stdout.
- Empty/no-change behavior should be configurable later, but initial implementation can always print a compact report.
- Do not create any cron job during implementation.
- Document example future cron command/prompt, with explicit note that recurring cron requires owner approval.

**Verification tests:**
- Runner exits 0 with report on successful no-new-contradiction run.
- Runner exits non-zero with blocked report on dirty/mutex/fetch failure.

---

## Task 8: Update installation and verification

**Objective:** Ensure new consistency files are installed into future profiles and verified in CI/local checks.

**Files:**
- Modify: `hermes/scripts/hire-junie.sh`
- Modify: `hermes/scripts/verify.sh`
- Modify: `hermes/scripts/test-initialization-gate.sh` if needed
- Create/modify: `hermes/scripts/test_consistency_check.py`

**Behavior:**
- `hire-junie.sh` creates `$STATE_DIR/consistency` along with existing state dirs.
- Fresh profile gets scripts, docs, and any plugin/hook files.
- Rehire clears stale consistency state like other operational state.
- `verify.sh` checks required consistency files and runs `test_consistency_check.py`.
- Tests use temp dirs/repos and must not touch the live profile.

**Verification:**
- `python3 -m py_compile hermes/initialization/scripts/consistency_check.py`
- `python3 hermes/scripts/test_consistency_check.py`
- Full `./hermes/scripts/verify.sh` from a clean tree.

---

## Task 9: Review and acceptance

**Objective:** Confirm the delivered routine matches the agreed product behavior end to end.

**Acceptance checks:**
- `INITIALIZATION.md` explicitly initializes consistency state and main branch checkpoint.
- Runner is callable from script and ready for cron.
- `/check_consistency` is implemented if a safe slash/admin hook exists; otherwise deferred explicitly without exposing a model-loop tool.
- Main orchestrator docs tell it to consume `PENDING_CONTRADICTIONS.md` before meaningful work.
- Held mutex and dirty worktree fail fast.
- Fetch/stale/diverged failures do not update checkpoint.
- Successful check updates checkpoint and pending file.
- Resolved contradictions are removed from pending and reported.
- Minor agent-doc-only drift is not added to pending.
- No normal `consistency_check` tool appears in the orchestrator tool schema.
- Full repo verification passes.

---

## Open implementation risks

1. **Hermes slash/admin hook availability:** If profile plugins cannot define non-model slash/admin commands, do not force this into the model tool surface. Implement script/cron path first and defer slash UX.
2. **LLM audit nondeterminism:** Keep deterministic preflight, strict schema, stable IDs, and conservative auto-fix authority.
3. **Image relevance:** Avoid scanning all images every run. Maintain a small relevant artifact index seeded by initialization and updated when checks discover relevant diagrams.
4. **Headless profile context:** Ensure headless Hermes runs with the Junie profile but does not resume or pollute the main Telegram conversation session.
5. **State write safety:** Use atomic writes for JSON and pending Markdown to avoid corrupting state on interrupted runs.

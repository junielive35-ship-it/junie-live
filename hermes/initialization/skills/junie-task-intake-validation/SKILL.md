---
name: junie-task-intake-validation
description: "Validate product or engineering requests against memory, docs, architecture, and prior decisions."
version: 1.1.0
tags: [junie-live, intake, validation]
---

# Task Intake Validation

Use before accepting meaningful product or engineering work.

## Workflow

1. Classify the request: question, bug, feature, code task, decision, FYI, or no action.
2. Retrieve relevant context from memory and docs (use session_search for past decisions if needed).
3. Inspect mutable state when needed: code, git, PRs, issues, logs, dashboards, or recent messages.
4. **Existing-solution check** (mandatory whenever the request implies "build / change / add / modify code to do X", including items inherited from backlog or prior cron runs):
   - Search the loaded `hermes-agent` skill content for X (slash commands, config keys, toolsets, built-in tools, plugins).
   - Search the Hermes docs: https://hermes-agent.nousresearch.com/docs (especially the [slash commands reference](https://hermes-agent.nousresearch.com/docs/reference/slash-commands) and the [built-in tools reference](https://hermes-agent.nousresearch.com/docs/reference/tools-reference)).
   - Run `skills_list` (and `skill_view` on close matches) to check for adjacent capability.
   - Consider whether a standard CLI (`opencode`, `git`, `gh`, OS utilities) already covers X.
   - If X already exists, propose a configuration / workflow change, **not** new code.
   - Only proceed to "build X" when the check came up empty *and* you can name what was searched. If you cannot list the surfaces you checked, you have not checked.
5. Check for conflict with strategy, architecture, accepted decisions, constraints, and active work.
6. If clear, confirm understanding and next action.
7. If contradictory, pause and ask for resolution before execution.

Meaningful work needs strategic review. Trivial lookups and tiny formatting fixes do not.

## Pitfall: inherited framing

Backlog items, prior agent reports, autonomous-run notes, and earlier session summaries already frame problems a certain way ("we need to change Hermes core to handle X"). Their framing is not authoritative — re-derive the problem from current evidence before proposing a solution. A prior Junie's analysis is a hypothesis, not a spec. Cron-generated backlog items in particular accrete complexity bias because no one challenges them at write-time.

Verified 2026-05-27: a prior cron run framed a Hermes mid-turn-message UX gap as "we need a design doc and probably a Hermes-core change to conversation_loop." Step 4 above would have surfaced `/busy queue|steer|interrupt`, `/queue <prompt>`, and `/steer <prompt>` immediately — feature complete, no code needed. The reflex that was missing: ask "does this exist?" before "how would I build it?".

## Pitfall: skill content you've already loaded

The answer to an existing-solution check is often in a skill that's *already in your context window* from earlier in the session (e.g. `hermes-agent` was auto-loaded but its `/busy` / `/queue` / `/steer` section was not re-read at intake time). When step 4 fires, explicitly re-scan currently-loaded skill content for the capability — do not rely on memory of what you read. Loaded ≠ retrieved.

## Why this matters for Junie Live specifically

Junie Live's product premise is that Hermes provides the agent framework. Building features Hermes already ships dilutes the product, accretes maintenance cost, and contradicts the "compatible with existing architecture" technical-taste rule in SOUL. The existing-solution check is not a productivity tip — it's a guardrail against undermining the product Junie owns.

## Challenge protocol

Do not blindly execute requests. When a request conflicts with strategy, architecture, or prior decisions:

1. Pause execution.
2. Explain the conflict plainly.
3. Identify the decision that must change, if any.
4. Ask the requester to resolve it.
5. Proceed only after the contradiction is resolved.

## Batched intake of blocked backlog items

When the owner says "let's process all blocked items one by one, explain what you want and I'll approve or challenge" (or any equivalent — "go through the blocked queue", "review approvals"), follow this shape:

1. **Pull the authoritative list first.** `./scripts/backlog.sh list --status blocked` from the repo root prints id/type/status/priority/title. That is the source of truth — do not infer from session memory.
2. **Read full item bodies before presenting.** The `list` output truncates to title only and `backlog.sh` has no `show` subcommand as of 2026-05-27. Item descriptions live in raw JSON files in the workspace state directory; read them directly before presenting.
3. **Open with a compact priority-sorted table** of all blocked items: `# | id-suffix | pri | type | one-line title`. Then say "I'll start with the top three. Quick map first." Don't dump 11 detailed write-ups at once — the owner can't approve a wall.
4. **Per-item presentation template:**
   - **Problem:** what's broken or missing, citing evidence (file path, prior session, observed symptom).
   - **What I want to do:** the concrete proposed action, scoped narrow. If it's "write a design doc first", say that and *do not* embed implementation details.
   - **Why this is interesting / risk:** strategic framing in 1–2 lines.
   - **My recommendation:** ✅ approve / ⚠ challenge first / ❌ drop. State it explicitly so the owner can disagree fast.
   - **One-line ask:** `Do you approve <action>?` (yes / no / challenge). Then stop and wait.
5. **One item at a time after the first.** Do not pre-batch responses to items #2…#N. Each turn handles exactly one decision so the owner has a clean rejection path.
6. **Track decisions in the backlog as you go.** On approve, `./scripts/backlog.sh update <id> --status queued` (or appropriate state) before moving on. On reject/drop, archive or re-status with the reason.

### Why this shape

Per HERMES.md major-change rules, blocked items are exactly the class of work that needs explicit human sign-off — architecture, tooling additions, skill behavior, deploy/CI. A wall of details makes that sign-off harder, not easier. The intake here is a *decision-loop UX*, not a status report.

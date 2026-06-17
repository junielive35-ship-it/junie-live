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
5. **Custom-machinery check** (mandatory for workflow/tooling/architecture/code-process changes): challenge load-bearing glue code, shell scripts as source of truth, custom installers/runners, hand-rolled queues/locks/schedulers, copied runtime files, duplicated helpers, and manual state files. Prefer existing project/framework/platform/library/team mechanisms. Reused behavior across multiple entrypoints belongs in a library/module/package with tests; shell/CLI wrappers may only be thin adapters.
6. Check for conflict with strategy, architecture, accepted decisions, constraints, and active work.
7. If clear, confirm understanding and next action.
8. If contradictory or custom machinery is unjustified, pause and ask for resolution before execution.

Meaningful work needs strategic review. Trivial lookups and tiny formatting fixes do not.

## Pitfall: inherited framing

Backlog items, prior agent reports, autonomous-run notes, and earlier session summaries already frame problems a certain way ("we need to change Hermes core to handle X"). Their framing is not authoritative — re-derive the problem from current evidence before proposing a solution. A prior Junie's analysis is a hypothesis, not a spec. Cron-generated backlog items in particular accrete complexity bias because no one challenges them at write-time.

Verified 2026-05-27: a prior cron run framed a Hermes mid-turn-message UX gap as "we need a design doc and probably a Hermes-core change to conversation_loop." Step 4 above would have surfaced `/busy queue|steer|interrupt`, `/queue <prompt>`, and `/steer <prompt>` immediately — feature complete, no code needed. The reflex that was missing: ask "does this exist?" before "how would I build it?".

## Pitfall: normalizing custom machinery

Do not accept an ad hoc installer, shell runner, copied runtime folder, custom queue/lock/scheduler, or manual state file just because it already exists or the owner suggested it. Treat it as a design hypothesis. Ask what existing project-native, framework-native, language/package-ecosystem, platform-native, or team-standard mechanism should own the behavior. If custom machinery remains the right choice, record the decision, alternatives rejected, tradeoffs, and revisit trigger.

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

## Batched intake of blocked Kanban tasks

When the owner says "let's process all blocked items one by one, explain what you want and I'll approve or challenge" (or any equivalent — "go through the blocked queue", "review approvals"), use the Senior Dev Kanban board as the source of truth:

1. **Pull active Senior Dev tasks first.** Use `senior_active_tasks(repo=..., include_comments=true)` for the target repo. If there are no active blocked tasks, say so instead of falling back to legacy OpenClaw or removed Junie backlog state.
2. **Never read OpenClaw backlog state from Hermes.** Do not use `.openclaw/`, `~/.openclaw/`, `JUNIE_WORKSPACE`, `workspace-junie-live`, `openclaw/scripts/backlog.sh`, raw legacy JSON item files, or removed profile-local backlog directories as a Hermes source of truth.
3. **Read the task comments/artifacts before presenting.** For each blocked task, inspect the title, status, embedded `_junie_metadata`, comments, `review-required` / `needs-input` / `failed` reason, and referenced result artifacts when needed.
4. **Open with a compact priority-sorted list** of blocked tasks: `# | task_id suffix | status/reason | one-line title`. Then say "I'll start with the top three. Quick map first." Don't dump detailed write-ups for every item at once.
5. **Per-task presentation template:**
   - **Problem:** what's blocked or waiting, citing evidence (Kanban comment, artifact path, observed symptom).
   - **What I want to do:** the concrete proposed action, scoped narrow. If it's "review the worker result first", say that and *do not* embed implementation details.
   - **Why this is interesting / risk:** strategic framing in 1–2 lines.
   - **My recommendation:** ✅ approve / ⚠ challenge first / ❌ drop. State it explicitly so the owner can disagree fast.
   - **One-line ask:** `Do you approve <action>?` (yes / no / challenge). Then stop and wait.
6. **One item at a time after the first.** Do not pre-batch responses to items #2…#N. Each turn handles exactly one decision so the owner has a clean rejection path.
7. **Track decisions in Kanban as you go.** On approval or rejection, comment/update/requeue the Kanban task through the available Kanban/Senior task tooling. If a required Kanban update tool is unavailable in the current session, record the decision in the relevant profile docs/status note instead of inventing an OpenClaw or backlog fallback.

### Why this shape

Per HERMES.md major-change rules, blocked tasks are exactly the class of work that needs explicit human sign-off — architecture, tooling additions, skill behavior, deploy/CI. A wall of details makes that sign-off harder, not easier. The intake here is a *decision-loop UX*, not a status report. Hermes must not silently import OpenClaw workspace state or removed Junie backlog state, because that breaks the Hermes-native Kanban ownership boundary and can resurrect stale decisions.

---
name: junie-task-intake-validation
description: "Validate product or engineering requests against memory, docs, architecture, and prior decisions."
version: 1.0.0
tags: [junie-live, intake, validation]
---

# Task Intake Validation

Use before accepting meaningful product or engineering work.

## Workflow

1. Classify the request: question, bug, feature, code task, decision, FYI, or no action.
2. Retrieve relevant context from memory and docs (use session_search for past decisions if needed).
3. Inspect mutable state when needed: code, git, PRs, issues, logs, dashboards, or recent messages.
4. Check for conflict with strategy, architecture, accepted decisions, constraints, and active work.
5. If clear, confirm understanding and next action.
6. If contradictory, pause and ask for resolution before execution.

Meaningful work needs strategic review. Trivial lookups and tiny formatting fixes do not.

## Challenge protocol

Do not blindly execute requests. When a request conflicts with strategy, architecture, or prior decisions:

1. Pause execution.
2. Explain the conflict plainly.
3. Identify the decision that must change, if any.
4. Ask the requester to resolve it.
5. Proceed only after the contradiction is resolved.

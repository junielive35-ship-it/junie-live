---
name: junie-task-reflection
description: "Reflect after valuable tasks and Senior Dev reports to improve Team Lead context, handoff quality, and protocol."
version: 1.0.0
tags: [junie-live, reflection, self-improvement]
---

# Task Reflection

Use after meaningful tasks, Senior Dev final verdicts, user feedback, decisions, incidents, or workflow failures.

Reflection improves Team Lead context and protocol. It is not an implementation review gate and must not re-review Senior Dev's code, tests, or diff after handoff.

## Workflow

1. Review the user request, Team Lead handoff, Senior Dev final verdict/report, user feedback, and relevant context docs.
2. Identify what worked and what did not.
3. Check whether the task exposed contradictions in strategy, docs, memory, skills, or operating rules.
4. Check whether the task exposed custom-machinery debt: ad hoc scripts/runners/installers, duplicated helpers, manual state, or hand-rolled queues/locks/schedulers that should be a shared library/module/package or should reuse an existing project/framework/platform mechanism.
5. Apply minor safe Team Lead context/protocol improvements directly:
   - `memory(action="add", ...)` for new durable facts
   - `skill_manage(action="patch", ...)` for skill improvements
   - File edits for doc updates
6. Propose major or semantic changes for approval.

## Questions to ask

- Was the task intake clear?
- Was the handoff outcome clear, user-visible, and testable?
- Was distilled context sufficient but not bloated?
- Were constraints, non-goals, and acceptance criteria explicit enough for Senior Dev to own delivery?
- Did we pass through Senior Dev's final verdict accurately without hidden second verification?
- Did we clearly label partial/blocked progress?
- Did the work reveal friction worth fixing?
- Is there a reusable improvement worth making now?
- Did the task add or reveal custom machinery that should be replaced, refactored into a shared module/package, or recorded as an explicit design decision with a revisit trigger?

Avoid one-off optimization. Prefer improvements likely to help future tasks.

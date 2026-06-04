---
name: junie-task-reflection
description: "Reflect after valuable tasks and turn reusable lessons into concrete workflow or context improvements."
version: 1.0.0
tags: [junie-live, reflection, self-improvement]
---

# Task Reflection

Use after meaningful tasks, especially code changes, decisions, incidents, reviews, or workflow failures.

## Workflow

1. Review task artifacts, PR/review history, worker output, and direct inspection evidence.
2. Identify what worked and what did not.
3. Check whether the task exposed contradictions in strategy, docs, memory, skills, or operating rules.
4. Check whether the task exposed custom-machinery debt: ad hoc scripts/runners/installers, duplicated helpers, manual state, or hand-rolled queues/locks/schedulers that should be a shared library/module/package or should reuse an existing project/framework/platform mechanism.
5. Apply minor safe improvements directly:
   - `memory(action="add", ...)` for new durable facts
   - `skill_manage(action="patch", ...)` for skill improvements
   - File edits for doc updates
6. Propose major or semantic changes for approval.

## Questions to ask

- Was the task intake clear?
- Was the work decomposed well?
- Was delegated context sufficient but not bloated?
- Did review catch the right issues?
- Did we claim completion only when the requested user outcome worked end to end?
- Did we clearly label partial/blocked progress?
- Did the work reveal friction worth fixing?
- Is there a reusable improvement worth making now?
- Did the task add or reveal custom machinery that should be replaced, refactored into a shared module/package, or recorded as an explicit design decision with a revisit trigger?

Avoid one-off optimization. Prefer improvements likely to help future tasks.

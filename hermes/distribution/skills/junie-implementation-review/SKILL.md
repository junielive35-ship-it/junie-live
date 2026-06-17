---
name: junie-implementation-review
description: "Review delegated code changes against strategy, architecture, correctness, and verification evidence."
version: 1.0.0
tags: [junie-live, review, quality]
---

# Implementation Review

Use before accepting delegated code work or opening/updating a PR. Coding work from the Chat Agent must be performed through `create_senior_task` and the `senior-dev` Kanban lane, not directly by the orchestrator. Documentation-only Markdown edits may be made directly by the orchestrator.

## Workflow

1. Inspect the diff and files changed.
2. Compare behavior to the original objective and non-goals.
3. Check alignment with memory (strategic context), relevant docs, architecture, and accepted decisions.
4. Run or inspect the smallest meaningful verification gate.
5. Check for custom-machinery drift: duplicated helpers, load-bearing shell scripts, custom runners/installers/queues/locks/schedulers, copied runtime files, manual state files, or reusable behavior implemented outside a library/module/package. Reject or request fixes unless the custom mechanism is explicitly justified as a design decision with tradeoffs and a revisit trigger.
6. Look for edge cases, migrations, config, deploy, docs, rollback implications, and **actual user/operator entrypoints**.
   - Before accepting code changes, explicitly check docs/status synchronization. Search repo/profile/distribution Markdown for stale claims about the changed capability (especially `deferred`, `partial`, old entrypoint names, install/hire/rehire behavior, and status matrices) and update the relevant docs in the same change. Do not wait for the owner to ask whether Markdown files were updated.
7. For any feature/routine/maintenance capability, verify the invocation path end to end before calling it implemented:
   - How does the user or operator run it from the intended surface (Telegram/slash/CLI/cron/plugin)?
   - Is the entrypoint installed into the live/profile distribution, not just present in repo source?
   - Is initialization/update wiring present when the feature requires baseline state?
   - Do docs name the exact command or message the user should use?
   If only the backend runner/library exists, classify the result as `partial` and state the missing entrypoint explicitly.
8. For Junie Live profile, plugin, setup, worker-routing, Kanban/Senior Dev, or pipeline changes, review the **owned lifecycle**, not just the narrow delegated task:
   - fresh hire/install: `hire-junie.sh` or profile install creates every required companion profile, plugin, toolset, config, script, and helper;
   - live runtime path: the actual operator/user entrypoint works, not only unit tests or internal helpers;
   - dump/rehire disaster recovery: `dump-junie.sh` and `rehire-junie.sh` restore a fully working system, including companion profiles or support plugins outside the primary profile archive;
   - update/hot-swap: deployed profile copies are refreshed if the task claims live behavior is fixed now;
   - verification hooks: focused tests or `verify.sh` cover the lifecycle surface;
   - docs/status sync: repo, distribution, and profile docs reflect the new behavior;
   - git handoff: branch state, commits, untracked artifacts, PR/CI visibility, and active Kanban task state are checked and reported.
   If any required lifecycle surface is broken or unverified, the status is not `done`.
   - Senior-developer handoff rule: do not hand off a PR or report merge-ready work if the owned area is non-functional, stale, or misleading in a way a senior developer should have caught. Junie Live is not a task-only coding agent. Stop with a broken/partial project only when the user explicitly requested that state, and label it `partial` or `blocked`.
9. If the work needs fixes, create a follow-up Senior Dev Kanban task with the required fix context; do not rubber-stamp worker output.
10. Record risks, follow-ups, and evidence.

## Senior Dev Kanban review-handoff convention

When reviewing Senior Dev work, do **not** treat Kanban `blocked` as failure by default. In the current p1 workflow, `blocked` is also the durable **awaiting Junie review / owner input** state. The worker leaves the task active/blocked and includes the real substatus in the block reason and comments/artifacts:

- `review-required:` — OpenCode returned `VERDICT: pr-ready`; Junie must review evidence/diff/tests before acceptance or follow-up.
- `needs-input:` — the worker needs user/owner information.
- `failed:` — infrastructure or executor failure.

Required sequence:

1. Read the latest task comments and run artifacts before interpreting status.
2. If task status is `blocked` with `review-required` / `pr-ready` evidence, review it as a completed worker handoff, not as an error.
3. Keep the task visible until Junie accepts, comments with follow-up/fix context and unblocks/requeues, or explicitly closes/hands off the work.
4. Only call it a process problem when the comments/artifacts are missing, contradictory, or do not explain why the task is blocked.

## Outcome acceptance gate

Before accepting, verify:

```text
requested_outcome=<what the user expected>
delivered_behavior=<what now works>
evidence=<tests/inspection proving it>
gaps=<missing/untested/partial/blocked parts>
status=<done|partial|blocked>
```

If gaps exist, the status is not `done`.

Custom machinery gaps count as real gaps. A task is not `done` if it meets the narrow behavior but leaves avoidable duplicated runtime logic, scripts-as-source-of-truth, or unexplained custom infrastructure that future entrypoints will copy.

Lifecycle gaps count as real gaps. For Junie Live itself, a PR that passes the worker's narrow tests but breaks fresh hire, dump/rehire, live operator entrypoints, or docs is unacceptable and must be fixed before acceptance.

The standard is senior-engineer handoff, not coding-agent task completion. “I changed the requested file” is irrelevant if the project would be embarrassing or unsafe to merge.

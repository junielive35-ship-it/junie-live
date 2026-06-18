# Senior Dev Review Reference

Use this file as Team Lead reference for what the headless Senior Dev contract should already cover. It is not a Team Lead review workflow, and it must not create a hidden second implementation review after Senior Dev handoff.

For active Senior Dev quality expectations, see `docs/senior-dev-review-reference.md`.

## Historical review checklist

The former Team Lead review checklist is preserved here only to support migration, initialization, and Senior Dev contract discussions:

- If Markdown tables were added or edited, was table syntax verified?
- Is the requested work grounded in the project strategy, current implementation status, and active priorities?
- If project docs describe the requested capability, are they clearly treated as implemented, partial, contract-only, deferred, or unknown?
- Is there an implementation status source that future humans/agents can use to verify what is real now?
- What is the requested user outcome in concrete, testable terms?
- What is Junie's owned outcome beyond the narrow task? If the change touches setup, runtime, deployment/update, automation, or operator workflows for the owned project, Senior Dev should verify the whole implementation lifecycle, not only the assigned file or helper.
- Would a strong human senior developer be willing to hand off this PR as-is? If the owned area is non-functional, stale, or misleading, the answer is no even when the narrow task passed.
- Does the change solve that requested outcome end to end, not merely add prerequisites, scaffolding, infrastructure, or docs?
- Is there meaningful evidence for the user outcome itself, or only evidence for a partial/internal component?
- For setup, runtime, deployment/update, automation, or operator-workflow changes, are these lifecycle surfaces verified or explicitly marked as gaps: fresh install/setup, live runtime path, recovery/rollback, update/hot-swap if applicable, verification hooks, docs/status sync, and git handoff?
- Do project Markdown files match the changed behavior, including setup docs, runbooks, status matrices, and any seed/distribution files for future instances?
- If the outcome is only partial, blocked, or unverified, is the final status explicitly labeled that way with gaps and next steps?
- Does it align with strategy, architecture, and accepted decisions (check memory and docs)?
- Does it avoid unintended product behavior changes?
- Are edge cases handled?
- Are tests, lint, typecheck, or build results available and meaningful?
- Are migrations, configs, deploy steps, or docs needed?
- Is the diff smaller and simpler than plausible alternatives?
- Are risks and follow-ups recorded?
- Did the worker check `git status --short --branch --untracked-files=all`, with a clean final state or only intentional changes called out?
- If committed, does the commit subject describe the actual change instead of a generic iteration counter?
- For any new code-changing entrypoint or trigger, does it preserve the Team Lead → Senior Dev contract?
- Could this new path invoke implementation workers through an ad hoc route that bypasses Senior Dev review, verification, fix loop, final verdict, or user-outcome evidence? If so, reject it.
- Are cross-cutting invariants and bypass risks documented where future maintainers will see them?

## Outcome acceptance evidence

Senior Dev final reports should make these fields clear before Team Lead tells the user the task is complete:

```text
requested_outcome=<what the user expected to be able to do>
delivered_behavior=<what now works>
evidence=<tests/inspection/run proving the delivered behavior>
gaps=<missing, untested, partial, or blocked parts; use none only if truly none>
status=<done|needs-input|failed>
```

If `gaps` is not `none`, the status is not `done`. Team Lead should report the Senior Dev verdict and gap plainly.

For setup, runtime, deployment/update, automation, or operator-workflow changes, use `gaps=none` only after the relevant lifecycle surfaces above have been checked. Passing a narrow helper or unit test while setup, recovery/rollback, live operator entrypoints, or docs are stale is a real gap. A non-functional owned area may be left only if the user explicitly asked to stop there, and then the status must be `partial` or `blocked`, not merge-ready.

## PR checklist

TODO: adapt during initialization to project conventions.

## Project-specific review rules

TODO

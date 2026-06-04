# Review Protocol

Use this file to guide implementation review before accepting worker output or opening/updating a PR.

## Review checklist

- If Markdown tables were added or edited, was table syntax verified?
- Is the requested work grounded in the project strategy, current implementation status, and active priorities?
- If project docs describe the requested capability, are they clearly treated as implemented, partial, contract-only, deferred, or unknown?
- Is there an implementation status source that future humans/agents can use to verify what is real now?
- What is the requested user outcome in concrete, testable terms?
- Does the change solve that requested outcome end to end, not merely add prerequisites, scaffolding, infrastructure, or docs?
- Is there meaningful evidence for the user outcome itself, or only evidence for a partial/internal component?
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
- For any new code-changing entrypoint or trigger, does it reuse or faithfully implement the shared implementation acceptance loop: worker/delegation/review/fix/acceptance?
- Could this new path invoke implementation workers through an ad hoc route that bypasses review, fix requests, acceptance, or user-outcome evidence? If so, reject it.
- Are cross-cutting invariants and bypass risks documented where future maintainers will see them?

## Outcome acceptance gate

Before accepting worker output or telling the user the task is complete, write down:

```text
requested_outcome=<what the user expected to be able to do>
delivered_behavior=<what now works>
evidence=<tests/inspection/run proving the delivered behavior>
gaps=<missing, untested, partial, or blocked parts; use none only if truly none>
status=<done|partial|blocked>
```

If `gaps` is not `none`, the status is not `done`. Report the gap in the first user-facing completion update.

## PR checklist

TODO: adapt during initialization to project conventions.

## Project-specific review rules

TODO

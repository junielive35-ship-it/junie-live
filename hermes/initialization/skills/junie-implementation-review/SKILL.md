---
name: junie-implementation-review
description: "Review delegated code changes against strategy, architecture, correctness, and verification evidence."
version: 1.0.0
tags: [junie-live, review, quality]
---

# Implementation Review

Use before accepting delegated code work or opening/updating a PR. Coding work must be performed via `marinator_delegate`, not directly by the orchestrator. Documentation-only Markdown edits may be made directly by the orchestrator.

## Workflow

1. Inspect the diff and files changed.
2. Compare behavior to the original objective and non-goals.
3. Check alignment with memory (strategic context), relevant docs, architecture, and accepted decisions.
4. Run or inspect the smallest meaningful verification gate.
5. Check for custom-machinery drift: duplicated helpers, load-bearing shell scripts, custom runners/installers/queues/locks/schedulers, copied runtime files, manual state files, or reusable behavior implemented outside a library/module/package. Reject or request fixes unless the custom mechanism is explicitly justified as a design decision with tradeoffs and a revisit trigger.
6. Look for edge cases, migrations, config, deploy, docs, and rollback implications.
7. If the work needs fixes, delegate fixes back via `marinator_delegate`; do not rubber-stamp worker output.
8. Record risks, follow-ups, and evidence.

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

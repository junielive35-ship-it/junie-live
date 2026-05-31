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
5. Look for edge cases, migrations, config, deploy, docs, and rollback implications.
6. If the work needs fixes, delegate fixes back via `marinator_delegate`; do not rubber-stamp worker output.
7. Record risks, follow-ups, and evidence.

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

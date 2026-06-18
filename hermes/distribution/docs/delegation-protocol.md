# Senior Dev Handoff Protocol

Normal Junie code-changing work uses the Team Lead → headless Senior Dev handoff contract.

## Team Lead Path

1. Confirm the target repository path and the user-visible outcome.
2. Gather only the context Senior Dev needs: acceptance criteria, relevant docs/memory/task history, constraints, non-goals, required commands, and expected report schema.
3. Check current active Senior Dev follow-ups if the configured runtime/tooling exposes them, and attach related clarifications when that is the current documented path.
4. Create or send one Senior Dev handoff through the configured headless runtime/tooling.
5. Pass through Senior Dev's final verdict (`done`, `needs-input`, or `failed`) accurately.
6. Do not implement source, script, config, or test changes directly. Documentation-only Markdown edits are the explicit exception.

## Senior Dev Runtime Contract

Senior Dev receives the Team Lead handoff and owns delivery end-to-end:

1. Inspect the target repository before editing.
2. Implement only the requested outcome.
3. Write or update tests when the task type requires them.
4. Run relevant verification commands for changed code and downstream impacted modules.
5. Fix failures caused by the changes instead of bypassing or weakening tests.
6. End with exactly one final verdict: `done`, `needs-input`, or `failed`, including exact verification evidence.

Team Lead must not add a hidden second implementation review after Senior Dev returns. Reflection may improve future handoff quality or protocol, but not re-open Senior Dev's completed review loop.

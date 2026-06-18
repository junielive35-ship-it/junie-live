# Senior Dev Kanban Protocol

Normal Junie code-changing work uses the configured Senior Dev Kanban path.

## Chat Agent Path

1. Inspect active Senior work with `senior_active_tasks`.
2. If related active work exists, add the follow-up as a comment and requeue only when it answers the current block reason.
3. Otherwise create one Senior Dev task with `create_senior_task`.
4. Do not implement source, script, config, or test changes directly. Documentation-only Markdown edits are the explicit exception.

## Senior Dev Worker Path

1. Read the assigned Kanban task with `kanban_show`.
2. Build a structured handoff for `senior_run_coding_task`: repo path, user-visible outcome, acceptance criteria, distilled context, constraints/non-goals, and expected report schema.
3. Run exactly one synchronous coding attempt with `senior_run_coding_task`.
4. Read the returned `result.md` and `status.json` artifacts, plus the `exit_code` and runner state.
5. Add one `kanban_comment` summarizing the result and artifact paths.
6. Decide the outcome yourself from the artifacts, exit code, task context, and the allowed Kanban statuses — the runner does not emit a verdict. End with exactly one terminal Kanban action:
   - `kanban_block` with `review-required:` — default for successful code-changing work that Junie must review.
   - `kanban_block` with `needs-input:` — only when external user/owner information is required.
   - `kanban_block` with `failed:` — for execution, verification, or requested-outcome failure (including `exit_code != 0`).
   - `kanban_complete` with `done:` — only for genuinely terminal work that needs no review.

`kanban_complete` is intentionally rare in p1 and reserved for terminal no-review work; ordinary code-changing work blocks as `review-required`.

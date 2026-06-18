# Senior Dev Kanban Protocol

Normal Junie code-changing work uses the configured Senior Dev Kanban path.

## Chat Agent Path

1. Inspect active Senior work with `senior_active_tasks`.
2. If related active work exists, add the follow-up as a comment and requeue only when it answers the current block reason.
3. Otherwise create one Senior Dev task with `create_senior_task`.
4. Do not implement source, script, config, or test changes directly. Documentation-only Markdown edits are the explicit exception.

## Senior Dev Worker Path

1. Read the assigned Kanban task with `kanban_show`.
2. Run exactly one synchronous coding attempt with `senior_run_coding_task`.
3. Read the returned `result.md` and `status.json` artifacts.
4. Add one `kanban_comment` summarizing the result and artifact paths.
5. End with exactly one terminal `kanban_block`:
   - `review-required:` for `VERDICT: pr-ready`
   - `needs-input:` for `VERDICT: needs-input`
   - `failed:` for `VERDICT: failed`

`kanban_complete` is intentionally unused in p1 until PR merge monitoring exists.

"""Senior Dev synchronous runner plugin for Hermes.

Registers senior_run_coding_task under the 'senior_runner' toolset. This is
the synchronous p.0 execution boundary for the senior-dev Kanban worker: one
blocking headless Junie CLI run per task, returning artifact paths.

Enable this toolset only for the senior-dev profile — never for the Chat
Agent (junie-live), which must route code work through create_senior_task.
"""


def register(ctx) -> None:
    from .tools import (
        SENIOR_RUN_CODING_TASK_SCHEMA,
        handle_senior_run_coding_task,
        check_requirements,
    )

    ctx.register_tool(
        name="senior_run_coding_task",
        toolset="senior_runner",
        schema=SENIOR_RUN_CODING_TASK_SCHEMA,
        handler=lambda args, **kw: handle_senior_run_coding_task(args, plugin_ctx=ctx, **kw),
        check_fn=check_requirements,
        description=(
            "Run a single coding task synchronously via the headless Junie CLI "
            "Senior executor. Blocks until Junie CLI exits, writes "
            "artifacts (spec.json, status.json, events.jsonl, "
            "result.md, logs), records the exit code and runner state, and "
            "returns their paths. Does not mutate the Kanban board or decide a "
            "semantic outcome; the senior-dev worker reads the artifacts and "
            "chooses the single terminal Kanban action itself."
        ),
        emoji="\U0001f6e0",  # hammer and wrench
    )

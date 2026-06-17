"""Senior Dev synchronous runner plugin for Hermes.

Registers senior_run_coding_task under the 'senior_runner' toolset. This is
the synchronous p1 execution boundary for the senior-dev Kanban worker: one
blocking OpenCode run per task, returning Marinator-style artifact paths.

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
            "Run a single coding task synchronously via the dummy Senior "
            "executor (vanilla OpenCode). Blocks until OpenCode exits, writes "
            "Marinator-style artifacts (spec.json, status.json, events.jsonl, "
            "result.md, logs), and returns their paths plus the VERDICT. Does "
            "not mutate the Kanban board; the senior-dev worker applies the "
            "single terminal Kanban action after reading the artifacts."
        ),
        emoji="\U0001f6e0",  # hammer and wrench
    )

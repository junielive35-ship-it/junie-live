"""Senior Dev Kanban task plugin for Hermes.

Registers create_senior_task and senior_dev_task_result under the
'senior' toolset. Entry point for Chat Agent to delegate code work to
Senior Dev via Hermes Kanban, and for the senior-dev profile to report
results back to Kanban.
"""


def register(ctx) -> None:
    from .tools import (
        CREATE_SENIOR_TASK_SCHEMA,
        SENIOR_DEV_TASK_RESULT_SCHEMA,
        SENIOR_ACTIVE_TASKS_SCHEMA,
        handle_create_senior_task,
        handle_senior_dev_task_result,
        handle_senior_active_tasks,
        check_requirements,
    )

    ctx.register_tool(
        name="senior_active_tasks",
        toolset="senior",
        schema=SENIOR_ACTIVE_TASKS_SCHEMA,
        handler=lambda args, **kw: handle_senior_active_tasks(args, plugin_ctx=ctx, **kw),
        check_fn=check_requirements,
        description=(
            "List active Senior Dev Kanban tasks (ready/running/blocked/"
            "scheduled), optionally filtered by repo and/or current origin "
            "chat. Call this BEFORE create_senior_task so a repeat/follow-up "
            "code request attaches to an existing task instead of creating a "
            "duplicate. Returns task_id, status, repo, origin, PR URLs, and "
            "optionally comments for follow-up routing judgment."
        ),
        emoji="\U0001f50d",  # magnifying glass
    )

    ctx.register_tool(
        name="create_senior_task",
        toolset="senior",
        schema=CREATE_SENIOR_TASK_SCHEMA,
        handler=lambda args, **kw: handle_create_senior_task(args, plugin_ctx=ctx, **kw),
        check_fn=check_requirements,
        description=(
            "Create a Senior Dev Kanban task and subscribe the originating "
            "gateway thread for status updates. One user-visible code request "
            "becomes one Kanban task assigned to senior-dev. Returns task_id, "
            "status, subscription target, and duplicate/idempotency outcome. "
            "All Chat Agent code-task delegation to Senior Dev must go through "
            "this tool."
        ),
        emoji="\U0001f9ed",
    )

    ctx.register_tool(
        name="senior_dev_task_result",
        toolset="senior",
        schema=SENIOR_DEV_TASK_RESULT_SCHEMA,
        handler=lambda args, **kw: handle_senior_dev_task_result(args, plugin_ctx=ctx, **kw),
        check_fn=check_requirements,
        description=(
            "Report the outcome of a completed Marinator/OpenCode run back "
            "to the Senior Dev Kanban task. Called by the senior-dev profile "
            "when Marinator wakes it after the worker finishes or needs "
            "attention. Reads run_dir/status.json and run_dir/result.md "
            "if they exist, then calls kanban_db.complete_task or "
            "kanban_db.block_task."
        ),
        emoji="\U0001f9ed",
    )

"""Autonomous Work Window plugin for Hermes.

Registers autonomous_work_start and autonomous_work_step under the 'autonomous' toolset.
This is the planning/control layer for bounded autonomous work windows.
"""


def register(ctx) -> None:
    from .tools import (
        AUTONOMOUS_WORK_START_SCHEMA,
        AUTONOMOUS_WORK_STEP_SCHEMA,
        handle_autonomous_work_start,
        handle_autonomous_work_step,
        check_requirements,
    )

    ctx.register_tool(
        name="autonomous_work_start",
        toolset="autonomous",
        schema=AUTONOMOUS_WORK_START_SCHEMA,
        handler=lambda args, **kw: handle_autonomous_work_start(args, plugin_ctx=ctx, **kw),
        check_fn=check_requirements,
        description=(
            "Start a bounded autonomous work window. Creates a durable window "
            "directory and starts the AW runner in the background. Returns "
            "window_id, run_dir, phase, and status. Does not select work or "
            "execute tasks."
        ),
        emoji="\U0001f30c",
    )

    ctx.register_tool(
        name="autonomous_work_step",
        toolset="autonomous",
        schema=AUTONOMOUS_WORK_STEP_SCHEMA,
        handler=lambda args, **kw: handle_autonomous_work_step(args, plugin_ctx=ctx, **kw),
        check_fn=check_requirements,
        description=(
            "Advance the autonomous work window state machine. Reads current AW "
            "state and artifacts, validates them, applies the deterministic "
            "transition table, writes state/events, and returns the next instruction "
            "and status. The LLM writes substantive artifacts; this tool controls "
            "phase transitions."
        ),
        emoji="\U0001f504",
    )

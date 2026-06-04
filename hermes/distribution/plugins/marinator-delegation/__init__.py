"""Marinator delegation plugin for Hermes.

Registers the marinator_delegate tool under the 'marinator' toolset.
This is the approved code-changing delegation path for Junie Live on Hermes.
"""


def register(ctx) -> None:
    from .tools import (
        MARINATOR_DELEGATE_SCHEMA,
        handle_marinator_delegate,
        check_requirements,
    )

    ctx.register_tool(
        name="marinator_delegate",
        toolset="marinator",
        schema=MARINATOR_DELEGATE_SCHEMA,
        handler=lambda args, **kw: handle_marinator_delegate(args, plugin_ctx=ctx, **kw),
        check_fn=check_requirements,
        description=(
            "Delegate a code-changing task to the Junie Live Marinator/OpenCode worker. "
            "Creates a durable run directory, starts a supervised OpenCode process, "
            "and returns immediately. The orchestrator reviews the result when the "
            "worker completes or needs attention."
        ),
        emoji="\U0001f9ed",  # compass
    )

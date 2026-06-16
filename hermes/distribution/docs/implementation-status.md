# Implementation Status

Use this file to distinguish current reality from plans for the assigned project. Keep it current enough that future humans and agents can tell what is implemented, partial, contract-only, deferred, or unknown.

Status values:

- **implemented** — behavior exists and has evidence.
- **partial** — some behavior exists, but important user-visible gaps remain.
- **contract-only** — docs describe intended behavior, but implementation is missing or not verified.
- **deferred** — intentionally out of scope for the current stage.
- **unknown** — not yet verified.

## Strategic thread

Initialization is not complete until this file has been reconciled with the target repository and the long-lived profile docs. Its job is to prevent Junie from saying "initialization done" while still lacking a clear, evidence-backed model of what exists, what is partial, what is only documented intent, and what remains externally unknown.

Keep this file concise. Do not paste large repo documents here; link to repo docs when they are the better source of truth, and record the implementation status plus Junie's operating consequence.

## Current status matrix

| Area / capability | Source docs | Status | Evidence | Gaps / next action |
| --- | --- | --- | --- | --- |
| Marinator delegation plugin | `docs/delegation-protocol.md`, `plugins/marinator-delegation/` | implemented | Plugin installed by `hire-junie.sh`; provides `marinator_delegate` tool under `marinator` toolset; supports Kanban linkage for Senior Dev mode | Approved OpenCode supervision boundary; normal user code tasks should enter through the Senior Dev Kanban lane |
| Senior Dev Kanban task helper | `plugins/senior-task/`, `profiles/senior-dev/`, `scripts/install-senior-dev-profile.sh` | implemented | `create_senior_task` creates/subscribes Kanban tasks; `senior_dev_task_result` marks completed/blocked; `hire-junie.sh` and `rehire-junie.sh` install/update the companion `senior-dev` profile | Live sustained usage should still be verified in the deployed environment; PR/CI monitoring remains separate |
| Target-project capabilities | Target repo code/docs; profile `strategy.md`, `architecture.md`, `design-decisions.md`, `tools.md` | unknown until inspected | Seed placeholder only | Replace this row during initialization with project-specific capability rows. Do not delete `INITIALIZATION.md` while this file still contains generic placeholders or unreconciled status gaps that can be answered from the repo/profile. |

## How to use this file

Before meaningful product, roadmap, workflow, or code-changing work:

1. Locate the relevant capability here or add a row if missing.
2. Check the source docs and evidence.
3. Treat docs as current implementation only when evidence supports that status.
4. If status is stale, ambiguous, or unknown, update this file or call out the gap before claiming the work is done.

## Maintenance rule

When project docs add or materially change a capability, update this status source in the same change or explicitly state why status is unknown. Tests, scripts, commits, logs, PRs, dashboards, and direct inspection are evidence; aspirational docs alone are not.

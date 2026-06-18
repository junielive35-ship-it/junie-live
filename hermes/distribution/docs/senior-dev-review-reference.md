# Senior Dev Review Reference

This document preserves the former `junie-implementation-review` skill as historical and transition material for the headless Senior Dev contract.

It is **not** a Team Lead workflow. Team Lead does not review Senior Dev implementation artifacts before acceptance. Senior Dev owns implementation, review, verification, fix loop, and final verdict end-to-end after handoff.

## Senior Dev quality expectations

Senior Dev should verify its own work against these checks before returning `done`:

- Compare behavior to the requested user-visible outcome and non-goals.
- Check alignment with relevant docs, architecture, accepted decisions, and constraints supplied in the Team Lead handoff.
- Run meaningful verification for changed code and downstream impacted modules.
- Fix failures caused by the changes instead of bypassing or weakening tests.
- Challenge custom-machinery drift: duplicated helpers, load-bearing shell scripts, custom runners/installers/queues/locks/schedulers, copied runtime files, manual state files, or reusable behavior implemented outside a library/module/package.
- Check edge cases, migrations, config, deploy, docs, rollback implications, and actual user/operator entrypoints.
- For setup, runtime, deployment/update, worker-routing, automation, or operator-workflow changes, verify the owned lifecycle: fresh install/setup, live runtime path, recovery/rollback, update/hot-swap when applicable, verification hooks, docs/status sync, and git handoff.

## Outcome acceptance evidence

Senior Dev final reports should make these fields obvious, either directly or through the required final verdict schema:

```text
requested_outcome=<what the user expected>
delivered_behavior=<what now works>
evidence=<tests/inspection proving it>
gaps=<missing/untested/partial/blocked parts>
status=<done|needs-input|failed>
```

If gaps exist, Senior Dev must not return `done`.

Custom machinery gaps count as real gaps. A task is not `done` if it meets the narrow behavior but leaves avoidable duplicated runtime logic, scripts-as-source-of-truth, or unexplained custom infrastructure that future entrypoints will copy.

Lifecycle gaps count as real gaps. A change that passes narrow tests but breaks setup, recovery/rollback, live operator entrypoints, or docs must be fixed before Senior Dev returns `done`.

The standard is senior-engineer handoff, not coding-agent task completion. “I changed the requested file” is irrelevant if the project would be embarrassing or unsafe to merge.
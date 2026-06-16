Senior Dev Kanban transition result

Root cause: the main `junie-live` profile had previously exposed the `marinator` plugin toolset to normal CLI/Telegram Chat Agent sessions, and one Chat Agent-facing README row still described code-changing work as direct `marinator_delegate` execution instead of `create_senior_task` through the `senior-dev` Kanban lane.

Changes made:
- Updated `hermes/README.md` so the Chat Agent coding path is `create_senior_task` to `senior-dev`; `marinator_delegate` is described only as the internal `senior-dev` executor boundary.
- Strengthened `hermes/scripts/test-senior-dev-kanban-toolsets.sh` to assert distribution `config.yaml` does not default-enable `marinator` under `platform_toolsets` or `known_plugin_toolsets` for `junie-live`.
- Added a stale-instruction guard for the direct `marinator_delegate` README wording.
- Hot-updated the active `junie-live` profile with Hermes tools commands so CLI and Telegram have `marinator` disabled and `senior` enabled.

Verification:
- `hermes -p junie-live tools list`: `marinator` plugin toolset disabled; `senior` enabled.
- `hermes -p junie-live tools list --platform telegram`: `marinator` plugin toolset disabled; `senior` enabled.
- `hermes -p senior-dev tools list`: `marinator` and `senior` plugin toolsets enabled.
- `./scripts/test-senior-dev-kanban-toolsets.sh`: passed 5, failed 0.
- `./scripts/test-autonomous-work.sh`: passed 41, failed 0.
- `./scripts/test-senior-task.sh`: passed 9, failed 0.
- `./scripts/test-senior-dev-result.sh`: passed 8, failed 0.
- `./scripts/test-install-senior-dev.sh`: passed 11, failed 0.

Implementation commit: `ef6731d` (`fix: guard senior dev kanban toolset split`).

Live-session note: already-loaded Telegram/gateway sessions may retain the old tool schema until restarted. Use gateway `/restart` or start a new session for the live Chat Agent to stop showing any cached `marinator_delegate` schema.

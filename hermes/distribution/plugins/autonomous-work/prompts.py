"""Prompt construction for Autonomous Work Window phases.

Builds phase-specific prompts that include window metadata, artifact paths,
Hermes backlog paths, and behavior rules. Prompts are written to the window
directory and returned as structured results. Never references OpenClaw paths.
"""

import os
import time
from typing import Any, Optional


def _resolve_backlog_paths() -> dict:
    """Resolve Hermes backlog paths from profile dir.

    Returns dict with backlog_root, items_dir, archive_dir, events_path.
    Never falls back to OpenClaw paths.
    """
    try:
        from . import state as aw_state
        profile_dir = aw_state.get_profile_dir()
        root = os.path.join(profile_dir, "junie-live", "state", "backlog")
        return {
            "backlog_root": root,
            "items_dir": os.path.join(root, "items"),
            "archive_dir": os.path.join(root, "archive"),
            "events_path": os.path.join(root, "events.jsonl"),
        }
    except Exception:
        return {
            "backlog_root": "",
            "items_dir": "",
            "archive_dir": "",
            "events_path": "",
        }


def build_step_prompt(
    window: dict,
    window_dir: str,
    phase: str,
    selected_item: Optional[str] = None,
) -> dict:
    window_id = window.get("window_id", "?")
    end_at = window.get("end_at", 0)
    prompt = window.get("prompt", "")
    repo = window.get("repo", "")
    deadline_iso = window.get("end_iso", "") or time.strftime("%Y-%m-%dT%H:%M:%S%z", time.gmtime(end_at))
    enable_debug_messages = window.get("enable_debug_messages", True)

    prompt_path = os.path.join(window_dir, "step_prompt.md")
    events_path = os.path.join(window_dir, "events.jsonl")
    window_json = os.path.join(window_dir, "window.json")
    selection_path = os.path.join(window_dir, "selection.md")
    final_report_path = os.path.join(window_dir, "final_report.md")
    last_step_result_path = os.path.join(window_dir, "last_step_result.md")
    control_cancel = os.path.join(window_dir, "control", "cancel")

    backlog = _resolve_backlog_paths()

    common_rules = (
        "RULES:\n"
        "- Do not ask live questions. If something requires human/operator "
        "intervention or cannot be done safely, record it as blocked and call "
        "autonomous_work_step().\n"
        "- Do not edit code directly. All code changes must go through "
        "create_senior_task and the senior-dev Kanban lane per delegation-protocol.md.\n"
        "- Update required artifacts for this phase.\n"
        "- Never read OpenClaw backlog state. The Hermes backlog is the sole "
        "source of truth at the profile-local path shown below.\n"
        "- Call autonomous_work_step(rationale=<brief note>) at the end, unless "
        "you are waiting on Marinator (executing_task phase).\n"
    )

    prompt_body = _build_phase_body(
        phase=phase,
        window_id=window_id,
        repo=repo,
        prompt=prompt,
        deadline_iso=deadline_iso,
        window_json=window_json,
        events_path=events_path,
        selection_path=selection_path,
        final_report_path=final_report_path,
        last_step_result_path=last_step_result_path,
        control_cancel=control_cancel,
        selected_item=selected_item,
        backlog_items_dir=backlog["items_dir"],
        backlog_archive_dir=backlog["archive_dir"],
        backlog_events_path=backlog["events_path"],
        enable_debug_messages=enable_debug_messages,
    )

    full_prompt = (
        f"# Autonomous Work Window — Phase: {phase}\n"
        f"\n"
        f"Window: {window_id}\n"
        f"Deadline: {deadline_iso}\n"
        f"Repo: {repo}\n"
        f"Owner prompt: {prompt if prompt else '(none)'}\n"
        f"\n"
        f"Artifact paths:\n"
        f"  window.json: {window_json}\n"
        f"  events.jsonl: {events_path}\n"
        f"  selection.md: {selection_path}\n"
        f"  final_report.md: {final_report_path}\n"
        f"  last_step_result.md: {last_step_result_path}\n"
        f"  control/cancel: {control_cancel}\n"
        f"\n"
        f"Hermes backlog (profile-local, sole source of truth):\n"
        f"  items: {backlog['items_dir']}\n"
        f"  archive: {backlog['archive_dir']}\n"
        f"  events: {backlog['events_path']}\n"
        f"\n"
        f"{common_rules}\n"
        f"{prompt_body}\n"
    )

    os.makedirs(os.path.dirname(prompt_path), exist_ok=True)
    with open(prompt_path, "w") as f:
        f.write(full_prompt)

    first_line = prompt_body.split("\n")[0] if prompt_body else f"Execute {phase} phase."
    return {
        "prompt_path": prompt_path,
        "instruction": first_line,
        "phase": phase,
    }


def _build_phase_body(
    phase: str,
    window_id: str,
    repo: str,
    prompt: str,
    deadline_iso: str,
    window_json: str,
    events_path: str,
    selection_path: str,
    final_report_path: str,
    last_step_result_path: str,
    control_cancel: str,
    selected_item: Optional[str] = None,
    backlog_items_dir: str = "",
    backlog_archive_dir: str = "",
    backlog_events_path: str = "",
    enable_debug_messages: bool = True,
) -> str:
    builders = {
        "snapshot_preflight": _snapshot_preflight_body,
        "candidate_generation": _candidate_generation_body,
        "score_and_select": _score_and_select_body,
        "executing_task": _executing_task_body,
        "record_outcome": _record_outcome_body,
        "finalizing": _finalizing_body,
    }
    builder = builders.get(phase, _default_body)
    return builder(
        window_id=window_id,
        repo=repo,
        prompt=prompt,
        deadline_iso=deadline_iso,
        window_json=window_json,
        events_path=events_path,
        selection_path=selection_path,
        final_report_path=final_report_path,
        last_step_result_path=last_step_result_path,
        control_cancel=control_cancel,
        selected_item=selected_item,
        backlog_items_dir=backlog_items_dir,
        backlog_archive_dir=backlog_archive_dir,
        backlog_events_path=backlog_events_path,
        enable_debug_messages=enable_debug_messages,
    )


def _snapshot_preflight_body(**kw) -> str:
    backlog_items = kw.get("backlog_items_dir", "")
    return (
        "## Objective\n"
        "Read current project/product/runtime state and compare with initialized "
        "strategy/target-state to understand what is safe and relevant now.\n"
        "\n"
        "## Required actions\n"
        "1. Read current memory / strategic compass — recall the strategy, "
        "target-state, and how to identify useful work from current state.\n"
        "2. Check profile docs and target repo HERMES.md / operational references.\n"
        "3. Check Hermes backlog state at the profile-local path. List items in "
        f"{backlog_items or '<backlog/items/>'} if it exists. "
        "Check statuses: candidate, validated, ready, in_progress, blocked. "
        "Do NOT read .openclaw, ~/.openclaw, JUNIE_WORKSPACE, workspace-junie-live, "
        "openclaw/scripts/backlog.sh, or legacy JSON backlog files.\n"
        "4. Check git status and current branch. Must not be main.\n"
        "5. Compare current repo state against initialized strategy/target-state "
        "to identify gaps that may suggest useful work.\n"
        "6. Write snapshot_preflight event to events.jsonl (you may use terminal "
        "to append, or document via autonomous_work_step rationale).\n"
        "7. Optionally write snapshot.md if useful for this window.\n"
        "\n"
        "## Artifacts\n"
        "- Append snapshot_preflight event (via autonomous_work_step rationale).\n"
        "- Optionally write snapshot.md in the window directory.\n"
        "\n"
        "Do not skip safety checks. If anything is unsafe, call autonomous_work_step "
        "with an appropriate rationale explaining why."
    )


def _candidate_generation_body(**kw) -> str:
    backlog_items = kw.get("backlog_items_dir", "")
    return (
        "## Objective\n"
        "Derive candidate work items by comparing current project state with "
        "initialized strategy/target-state.\n"
        "\n"
        "## Primary source: strategy vs state comparison\n"
        "- Read the initialized strategy/target-state from memory and profile "
        "docs. What does the target-state look like?\n"
        "- Inspect the current repo state: code structure, tests, git history, "
        "CI config, open PRs/issues.\n"
        "- Identify gaps between current state and target-state. Each gap that "
        "is safe, in-scope, and actionable is a candidate.\n"
        "- Consider: missing features, incomplete implementations, tech debt "
        "visible in code, test gaps, doc drift, build/CI improvements with "
        "visible evidence.\n"
        "\n"
        "## Secondary sources (optional inputs, not required)\n"
        "- Owner request / prompt for this window.\n"
        "- Failed or partial Marinator runs.\n"
        "- Conversation/session signals from recent interactions.\n"
        "- Existing Hermes backlog items with status candidate/validated/ready "
        f"in {backlog_items or '<backlog/items/>'}.\n"
        "- Docs/status files in the repo or profile — if they exist, use them; "
        "if not, inspect repo structure/code/tests/history/admin prompt instead.\n"
        "\n"
        "## Backlog is a cache, not the only source\n"
        "- The backlog is a queue of known items, not an exhaustive inventory "
        "of possible work.\n"
        "- An empty backlog does not mean work is exhausted. Derive candidates "
        "from strategy/state comparison first.\n"
        "- If new candidates emerge from the comparison, add them to the backlog "
        "as Markdown files.\n"
        "\n"
        "## Backlog item format\n"
        "Each item is a Markdown file with YAML frontmatter:\n"
        "---\n"
        "id: BL-YYYYMMDD-NNN\n"
        "kind: feature|bug|chore|refactor|decision\n"
        "status: candidate\n"
        "title: One-line title\n"
        "source: autonomous\n"
        "problem: Problem statement\n"
        "desired_outcome: What done looks like\n"
        "acceptance: |\n"
        "  - Criterion 1\n"
        "verification: |\n"
        "  - How to verify\n"
        "scores:\n"
        "  strategy_fit: 8\n"
        "  effort: 3\n"

        "---\n"
        "\n"
        "## Constraints\n"
        "- Do not invent random work. Every candidate must trace to a visible "
        "gap between current repo state and initialized strategy/target-state, "
        "or to a clear signal from secondary sources.\n"
        "- Create or update backlog items as Markdown files with YAML "
        "frontmatter using the format above.\n"
        "- selection.md is a per-window summary only, not a backlog item.\n"
        "\n"
        "## Artifacts\n"
        "- Created/updated Hermes backlog items (Markdown files in items dir).\n"
        "- Write selection.md in the window directory with the list of candidates "
        "and their priority/strategy fit.\n"
        "\n"
        "## Transition\n"
        "After writing candidates and selection.md, call autonomous_work_step(rationale=...). "
        "Only stop and transition to finalizing after attempting to derive safe "
        "useful work from all available sources: repo state vs strategy comparison, "
        "initialized strategy/target-state, owner prompt, conversation/session "
        "signals, available docs, and existing backlog. If despite all sources no "
        "safe repo-visible work can be derived, record that reasoning and call "
        "autonomous_work_step — the system will transition to finalizing. Do not "
        "fall back to invisible housekeeping (dependency bumps, lint-only fixes, "
        "doc-only changes without context) when no real work can be identified."
    )


def _score_and_select_body(**kw) -> str:
    backlog_items = kw.get("backlog_items_dir", "")
    return (
        "## Objective\n"
        "Evaluate eligible items and select one for execution.\n"
        "\n"
        "## Source items\n"
        f"Read candidate/validated/ready items from the Hermes backlog: "
        f"{backlog_items or '<backlog/items/>'}. "
        "Do NOT read OpenClaw state or legacy JSON.\n"
        "\n"
        "## Eligibility gates\n"
        "- Autonomous scope — if an item requires operator intervention or is "
        "outside safe autonomous scope, explain in selection.md and consider "
        "other items.\n"
        "- Code mutex availability — check before selecting.\n"
        "- Branch safety — must not be main.\n"
        "- Deadline/time budget — skip items that cannot complete before deadline.\n"
        "- No deploy/PR/external actions without authority.\n"
        "- No Hermes Agent core edits unless explicitly requested.\n"
        "\n"
        "## Priority order\n"
        "1. Strategy fit\n"
        "2. Architecture fit\n"
        "3. Implementation/status fit\n"
        "4. Outcome and verification clarity\n"
        "5. Autonomous fit\n"
        "6. Effort/risk/uncertainty\n"
        "\n"
        "## Required actions\n"
        "1. Read candidate/validated/ready items from Hermes backlog items dir.\n"
        "2. Evaluate each against eligibility gates and priority order.\n"
        "3. Update the selected item's status to in_progress in its Markdown file "
        "and set updated timestamp.\n"
        "\n"
        "## Artifacts\n"
        "- Write selection.md with selected_item: <id> on the first line, "
        "then skipped/ineligible reasons for each candidate not selected.\n"
        "\n"
        "## Transition\n"
        "After writing selection.md and updating the backlog item, call "
        "autonomous_work_step(rationale=...). "
        "If no eligible item exists, record why and call autonomous_work_step."
    )


def _executing_task_body(**kw) -> str:
    selected = kw.get("selected_item")
    backlog_items = kw.get("backlog_items_dir", "")
    enable_debug_messages = kw.get("enable_debug_messages", True)
    instr = (
        "## Objective\n"
        f"Execute the selected backlog item through the standard Senior Dev "
        f"Kanban delegation protocol.\n"
    )
    if selected:
        instr += f"\nSelected item: {selected}\n"

    debug_flag = "True" if enable_debug_messages else "False"
    instr += (
        "\n## Required actions\n"
        "1. Read selected item acceptance and verification requirements from "
        "its Markdown file in the Hermes backlog.\n"
        "2. Follow delegation-protocol.md.\n"
        "3. Decompose the work into scoped subtasks if needed.\n"
        "4. For code-changing work: call create_senior_task with the selected "
        "item, repo, acceptance criteria, and verification requirements.\n"
        "   - Do NOT run opencode directly.\n"
        "   - Do NOT edit code yourself.\n"
        f"   - Include debug/progress preference enable_per_minute_reports="
        f"{debug_flag} in the task brief if relevant.\n"
        "5. Wait for the Senior Dev Kanban terminal result, then inspect "
        "reported verification evidence and status.\n"
        "6. Update the backlog item's status in its Markdown file when the task "
        "reaches a terminal outcome.\n"
        "\n"
        "## Terminal selected-item outcomes\n"
        "When the selected item reaches a terminal outcome:\n"
        "1. Update the Hermes backlog item: set status to done/blocked/failed "
        f"in its Markdown file at {backlog_items or '<backlog/items/>'} "
        "and append a history entry.\n"
        "2. Write the outcome to last_step_result.md in the window directory "
        "with a line like:\n"
        "  outcome: done | blocked | deferred | failed | skipped\n"
        "\n"
        "## IMPORTANT\n"
        "- Do NOT call autonomous_work_step() until the selected item reaches a "
        "terminal outcome. While Senior Dev is running, wait for the Kanban wake.\n"
        "- Senior Dev review/fix/acceptance are all inside this single phase.\n"
        "- If something goes wrong, you may write control/cancel or record a "
        "blocked outcome.\n"
    )
    return instr


def _record_outcome_body(**kw) -> str:
    backlog_items = kw.get("backlog_items_dir", "")
    return (
        "## Objective\n"
        "Record what happened with the selected item and update the Hermes backlog.\n"
        "\n"
        "## Required actions\n"
        "1. Update the selected backlog item's Markdown file:\n"
        "   - Set status to done/blocked/failed/dropped as appropriate.\n"
        "   - Append a history entry with timestamp and outcome summary.\n"
        "   - Set updated timestamp.\n"
        f"   Item file location: {backlog_items or '<backlog/items/>'}\n"
        "2. If the item is done and verified, move the file to the archive dir "
        "or leave it in items with status: done.\n"
        "\n"
        "## Required information\n"
        "- Item id.\n"
        "- Terminal outcome (done/blocked/deferred/failed/skipped).\n"
        "- Marinator job ids involved (if any).\n"
        "- Verification evidence or blocked reasons.\n"
        "- Follow-up candidates (if any).\n"
        "- Current git status.\n"
        "\n"
        "## Artifacts\n"
        "Write the outcome record to last_step_result.md in the window directory.\n"
        "\n"
        "## Transition\n"
        "After recording and updating the backlog, call autonomous_work_step(rationale=...). "
        "If time remains and failure budget allows, the system will restart the cycle "
        "from snapshot_preflight."
    )


def _finalizing_body(**kw) -> str:
    return (
        "## Objective\n"
        "Write a truthful final report for this autonomous work window.\n"
        "\n"
        "## Required sections\n"
        "- Duration and goal.\n"
        "- Selected items (list each).\n"
        "- Completed items (with verification evidence).\n"
        "- Blocked or deferred items.\n"
        "- Verification performed.\n"
        "- Remaining risks.\n"
        "- Current git status (git status --short --branch --untracked-files=all).\n"
        "- Recommended next owner decisions.\n"
        "\n"
        "## Artifacts\n"
        "Write the report to final_report.md in the window directory.\n"
        "\n"
        "## Communication\n"
        "After writing the report, optionally send a summary via the current "
        "Junie communication protocol.\n"
        "\n"
        "## Transition\n"
        "After writing the report, call autonomous_work_step(rationale=...). "
        "The system will mark the window as completed."
    )


def _default_body(**kw) -> str:
    phase = kw.get("phase", "unknown") or "unknown"
    wid = kw.get("window_id", "?") or "?"
    return (
        f"Execute the {phase} phase of the autonomous work "
        f"window {wid}."
    )

"""Prompt construction for Autonomous Work Window phases.

Builds phase-specific prompts that include window metadata, artifact paths,
and behavior rules. Prompts are written to the window directory and returned
as structured results.
"""

import os
import time
from typing import Any, Optional


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

    prompt_path = os.path.join(window_dir, "step_prompt.md")
    events_path = os.path.join(window_dir, "events.jsonl")
    window_json = os.path.join(window_dir, "window.json")
    selection_path = os.path.join(window_dir, "selection.md")
    final_report_path = os.path.join(window_dir, "final_report.md")
    last_step_result_path = os.path.join(window_dir, "last_step_result.md")
    control_cancel = os.path.join(window_dir, "control", "cancel")

    common_rules = (
        "RULES:\n"
        "- Do not ask live questions. If something needs approval, record it as "
        "blocked/needs-approval and call autonomous_work_step().\n"
        "- Do not edit code directly. All code changes must go through "
        "marinator_delegate per delegation-protocol.md.\n"
        "- Update required artifacts for this phase.\n"
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
    )


def _snapshot_preflight_body(**kw) -> str:
    return (
        "## Objective\n"
        "Read current project/product/runtime state to understand what is safe "
        "and relevant now.\n"
        "\n"
        "## Required actions\n"
        "1. Read current memory / strategic compass.\n"
        "2. Check profile docs and target repo HERMES.md / operational references.\n"
        "3. Check backlog state and current implementation status.\n"
        "4. Check git status and current branch. Must not be main.\n"
        "5. Write snapshot_preflight event to events.jsonl (you may use terminal "
        "to append, or document via autonomous_work_step rationale).\n"
        "6. Optionally write snapshot.md if useful for this window.\n"
        "\n"
        "## Artifacts\n"
        "- Append snapshot_preflight event (via autonomous_work_step rationale).\n"
        "- Optionally write snapshot.md in the window directory.\n"
        "\n"
        "Do not skip safety checks. If anything is unsafe, call autonomous_work_step "
        "with an appropriate rationale explaining why."
    )


def _candidate_generation_body(**kw) -> str:
    return (
        "## Objective\n"
        "Generate or update candidate work items from current signals.\n"
        "\n"
        "## Check these sources\n"
        "- Implementation gaps from recent work.\n"
        "- Docs/status drift.\n"
        "- Failed or partial Marinator runs.\n"
        "- Owner request / prompt for this window.\n"
        "- Verification gaps.\n"
        "- Current backlog hygiene.\n"
        "\n"
        "## Constraints\n"
        "- Do not invent random work just because the backlog is empty. "
        "Strategy/architecture/status fit is the primary gate.\n"
        "- Create or update backlog items using the current Junie backlog protocol.\n"
        "\n"
        "## Artifacts\n"
        "- Created/updated backlog items or candidate notes.\n"
        "- Write selection.md in the window directory with the list of candidates "
        "and their priority/strategy fit.\n"
        "\n"
        "## Transition\n"
        "After writing candidates, call autonomous_work_step(rationale=...). "
        "If no eligible work exists and no useful candidates can be identified, "
        "record that and call autonomous_work_step — the system will transition "
        "to finalizing."
    )


def _score_and_select_body(**kw) -> str:
    return (
        "## Objective\n"
        "Evaluate eligible items and select one for execution.\n"
        "\n"
        "## Eligibility gates\n"
        "- Owner approval requirement — if an item needs owner approval, mark it "
        "needs_approval and skip.\n"
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
        "## Artifacts\n"
        "- Write selection.md with the selected item and skipped/ineligible reasons "
        "for each candidate not selected.\n"
        "\n"
        "## Transition\n"
        "After writing selection.md, call autonomous_work_step(rationale=...). "
        "If no eligible item exists, record why and call autonomous_work_step."
    )


def _executing_task_body(**kw) -> str:
    selected = kw.get("selected_item")
    instr = (
        "## Objective\n"
        f"Execute the selected backlog item through the standard Junie/Marinator "
        f"delegation protocol.\n"
    )
    if selected:
        instr += f"\nSelected item: {selected}\n"

    instr += (
        "\n## Required actions\n"
        "1. Read selected item acceptance and verification requirements.\n"
        "2. Follow delegation-protocol.md.\n"
        "3. Decompose the work into scoped subtasks if needed.\n"
        "4. For code-changing work: write a prompt file and call marinator_delegate "
        "with job_id, repo, prompt_file.\n"
        "   - Do NOT run opencode directly.\n"
        "   - Do NOT edit code yourself.\n"
        "5. Handle Marinator completion/failure/attention wakes in the ordinary "
        "Marinator loop:\n"
        "   - inspect run_dir, status.json, result.md, logs, diff, and "
        "verification evidence.\n"
        "   - decide accept/fix/wait/kill/block.\n"
        "   - if fix is needed, call marinator_delegate again with is_follow_up=true.\n"
        "6. Update backlog/task artifacts with the terminal outcome.\n"
        "\n"
        "## Terminal selected-item outcomes\n"
        "When the selected item reaches a terminal outcome, write it to "
        "last_step_result.md in the window directory with a line like:\n"
        "  outcome: done | blocked | needs_approval | failed | skipped\n"
        "\n"
        "## IMPORTANT\n"
        "- Do NOT call autonomous_work_step() until the selected item reaches a "
        "terminal outcome. While Marinator is running, wait for the wake.\n"
        "- Marinator review/fix/acceptance are all inside this single phase.\n"
        "- If something goes wrong, you may write control/cancel or record a "
        "blocked outcome.\n"
    )
    return instr


def _record_outcome_body(**kw) -> str:
    return (
        "## Objective\n"
        "Record what happened with the selected item.\n"
        "\n"
        "## Required information\n"
        "- Item id.\n"
        "- Terminal outcome (done/blocked/needs_approval/failed/skipped).\n"
        "- Marinator job ids involved (if any).\n"
        "- Verification evidence or blocked reasons.\n"
        "- Follow-up candidates (if any).\n"
        "- Current git status.\n"
        "\n"
        "## Artifacts\n"
        "Write the outcome record to last_step_result.md in the window directory.\n"
        "\n"
        "## Transition\n"
        "After recording, call autonomous_work_step(rationale=...). If time "
        "remains and failure budget allows, the system will restart the cycle "
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
        "- Blocked/needs-approval items.\n"
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
    return (
        f"Execute the {kw.get('phase', 'unknown')} phase of the autonomous work "
        f"window {kw.get('window_id', '?')}."
    )

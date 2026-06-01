"""Hermes-native backlog helper for Autonomous Work Window.

Dependency-light stdlib Python module providing profile-local YAML-frontmatter
Markdown backlog management. Never inspects OpenClaw paths or legacy JSON.
"""

import os
import re
import time
from pathlib import Path
from typing import Any, Optional

from . import state as aw_state


# ── Path resolution ──

def get_backlog_root() -> str:
    return os.path.join(aw_state.get_profile_dir(), "junie-live", "state", "backlog")


def get_items_dir() -> str:
    return os.path.join(get_backlog_root(), "items")


def get_archive_dir() -> str:
    return os.path.join(get_backlog_root(), "archive")


def get_events_path() -> str:
    return os.path.join(get_backlog_root(), "events.jsonl")


def ensure_backlog_dirs() -> None:
    for d in (get_items_dir(), get_archive_dir()):
        os.makedirs(d, exist_ok=True)


# ── Item ID generation ──

def generate_item_id(kind: str = "BL") -> str:
    today = time.strftime("%Y%m%d")
    items_dir = get_items_dir()
    highest = 0
    if os.path.isdir(items_dir):
        prefix = f"{kind}-{today}-"
        for fname in os.listdir(items_dir):
            if fname.startswith(prefix) and fname.endswith(".md"):
                rest = fname[len(prefix):-3]
                if rest.isdigit():
                    num = int(rest)
                    if num > highest:
                        highest = num
    return f"{kind}-{today}-{highest + 1:03d}"


# ── Simple YAML frontmatter parser (no PyYAML dependency) ──

def parse_frontmatter(text: str) -> tuple[dict, str]:
    """Parse YAML frontmatter from a Markdown string.

    Returns (frontmatter_dict, body_string). If no valid frontmatter is found,
    returns ({}, text) with empty dict.
    """
    if not text.startswith("---"):
        return {}, text

    end_idx = text.find("---", 3)
    if end_idx == -1:
        return {}, text

    yaml_block = text[3:end_idx].strip()
    body = text[end_idx + 3:].strip()

    frontmatter = _parse_yaml_block(yaml_block)
    return frontmatter, body


def _parse_yaml_block(yaml_text: str) -> dict:
    """Parse a simple YAML key-value block into a dict.

    Handles:
      - scalar key: value (strings, booleans, numbers, None)
      - quoted strings (single and double)
      - nested dict via indented key: value
      - block scalars (| and >)
      - list items starting with -
    """
    result: dict = {}
    lines = yaml_text.split("\n")
    i = 0
    path_stack: list[tuple[str, int]] = []
    bs_lines: Optional[list[str]] = None
    bs_style: str = "|"
    bs_kp: list[str] = []
    bs_indent: int = 0

    def _set_by_path(d: dict, kp: list[str], value: Any) -> None:
        target = d
        for part in kp[:-1]:
            if part not in target or not isinstance(target[part], dict):
                target[part] = {}
            target = target[part]
        target[kp[-1]] = value

    def _type(v: str) -> Any:
        s = v.strip()
        if not s:
            return v
        if s.lower() in ("true", "yes", "on"):
            return True
        if s.lower() in ("false", "no", "off"):
            return False
        if s.lower() in ("null", "none", "~"):
            return None
        try:
            return int(s) if "." not in s else float(s)
        except (ValueError, TypeError):
            pass
        return v

    while i < len(lines):
        line = lines[i]
        raw = line.rstrip()

        if bs_lines is not None:
            content_indent = len(raw) - len(raw.lstrip()) if raw else bs_indent + 1
            if content_indent > bs_indent:
                bs_lines.append(raw)
                i += 1
                continue
            else:
                val = ("\n".join(bs_lines)).rstrip("\n") if bs_style == "|" \
                    else " ".join(l.strip() for l in bs_lines).strip()
                _set_by_path(result, bs_kp, val)
                bs_lines = None
                if not raw:
                    i += 1
                    continue

        if not raw or raw.lstrip().startswith("#"):
            i += 1
            continue

        indent = len(raw) - len(raw.lstrip())
        text = raw.lstrip()

        while path_stack and path_stack[-1][1] >= indent:
            path_stack.pop()

        if text.startswith("- "):
            item = text[2:].strip()
            if path_stack:
                parent_key = path_stack[-1][0]
                parent_kp = [p[0] for p in path_stack[:-1]]
                target = result
                for p in parent_kp:
                    if p not in target or not isinstance(target[p], dict):
                        target[p] = {}
                    target = target[p]
                if parent_key in target:
                    existing = target[parent_key]
                    if isinstance(existing, list):
                        existing.append(_type(item))
                    else:
                        target[parent_key] = [existing, _type(item)]
                else:
                    target[parent_key] = [_type(item)]
            i += 1
            continue

        colon_idx = text.find(":")
        if colon_idx == -1:
            i += 1
            continue

        key = text[:colon_idx].strip()
        value_part = text[colon_idx + 1:].strip()
        if not key:
            i += 1
            continue

        kp = [p[0] for p in path_stack] + [key]

        if value_part == "|" or value_part == ">":
            bs_lines = []
            bs_style = value_part
            bs_kp = kp
            bs_indent = indent
            i += 1
            continue

        if value_part == "":
            path_stack.append((key, indent))
            i += 1
            continue

        if value_part.startswith('"') and value_part.endswith('"'):
            _set_by_path(result, kp, value_part[1:-1])
        elif value_part.startswith("'") and value_part.endswith("'"):
            _set_by_path(result, kp, value_part[1:-1])
        else:
            _set_by_path(result, kp, _type(value_part))

        i += 1

    if bs_lines is not None:
        val = ("\n".join(bs_lines)).rstrip("\n") if bs_style == "|" \
            else " ".join(l.strip() for l in bs_lines).strip()
        _set_by_path(result, bs_kp, val)

    return result


def format_frontmatter(data: dict) -> str:
    """Format a dict as YAML frontmatter block (without enclosing ---).

    Handles strings, booleans, numbers, None, lists, and nested dicts.
    Multiline strings use | block scalar.
    """
    lines: list[str] = []

    for key, value in data.items():
        _write_value(lines, key, value, 0)

    return "\n".join(lines)


def _write_value(lines: list[str], key: str, value: Any, indent: int) -> None:
    prefix = "  " * indent
    if isinstance(value, bool):
        lines.append(f"{prefix}{key}: {'true' if value else 'false'}")
    elif value is None:
        lines.append(f"{prefix}{key}: null")
    elif isinstance(value, int) or isinstance(value, float):
        lines.append(f"{prefix}{key}: {value}")
    elif isinstance(value, str):
        if "\n" in value:
            lines.append(f"{prefix}{key}: |")
            for line in value.split("\n"):
                lines.append(f"  {prefix}{line}")
        else:
            lines.append(f"{prefix}{key}: {value}")
    elif isinstance(value, list):
        lines.append(f"{prefix}{key}:")
        for item in value:
            if isinstance(item, dict):
                for sub_key, sub_val in item.items():
                    _write_value(lines, f"- {sub_key}", sub_val, indent + 1)
            else:
                lines.append(f"  {prefix}- {item}")
    elif isinstance(value, dict):
        lines.append(f"{prefix}{key}:")
        for sub_key, sub_val in value.items():
            _write_value(lines, sub_key, sub_val, indent + 1)


# ── Item read/write ──

def read_item(path: str) -> tuple[dict, str]:
    """Read a Markdown backlog item file.

    Returns (frontmatter_dict, body_string).
    """
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()
    return parse_frontmatter(text)


def write_item(path: str, frontmatter: dict, body: str = "") -> None:
    """Write a Markdown backlog item file with YAML frontmatter."""
    fm_str = format_frontmatter(frontmatter)
    content = f"---\n{fm_str}\n---\n"
    if body:
        content += f"\n{body}\n"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


def list_items(items_dir: Optional[str] = None) -> list[str]:
    """List all .md file paths in the items directory, sorted by name."""
    d = items_dir or get_items_dir()
    if not os.path.isdir(d):
        return []
    paths = []
    for fname in sorted(os.listdir(d)):
        if fname.endswith(".md"):
            paths.append(os.path.join(d, fname))
    return paths


def filter_by_status(items: list[str], statuses: set[str]) -> list[str]:
    """Filter a list of item file paths by status."""
    result = []
    for path in items:
        fm, _ = read_item(path)
        if fm.get("status") in statuses:
            result.append(path)
    return result


def list_active_items(items_dir: Optional[str] = None) -> list[dict]:
    """List all items with status candidate, validated, ready, or in_progress.

    Returns list of dicts with {'frontmatter': ..., 'body': ..., 'path': ...}.
    """
    active_statuses = {"candidate", "validated", "ready", "in_progress"}
    items = list_items(items_dir)
    result = []
    for path in items:
        try:
            fm, body = read_item(path)
            if fm.get("status") in active_statuses:
                result.append({
                    "frontmatter": fm,
                    "body": body,
                    "path": path,
                })
        except Exception:
            pass
    return result


def update_item_status(
    path: str,
    new_status: str,
    history_note: Optional[str] = None,
) -> None:
    """Update a backlog item's status and optionally append to history."""
    fm, body = read_item(path)
    fm["status"] = new_status
    if "updated" in fm or new_status in ("in_progress", "blocked", "done", "failed"):
        fm["updated"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    if history_note:
        history = fm.get("history", "")
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        entry = f"[{ts}] {history_note}"
        if history:
            fm["history"] = history + "\n" + entry
        else:
            fm["history"] = entry
    write_item(path, fm, body)


# ── Candidate detection for AW ──

def get_candidate_paths(items_dir: Optional[str] = None) -> list[str]:
    """Get item file paths with status candidate, validated, or ready.

    Used by AW candidate_generation phase to detect backlog candidates
    even without a selection.md.
    """
    d = items_dir or get_items_dir()
    items = list_items(d)
    return filter_by_status(items, {"candidate", "validated", "ready"})


def get_blocked_paths(items_dir: Optional[str] = None) -> list[str]:
    """Get item file paths with status blocked."""
    d = items_dir or get_items_dir()
    items = list_items(d)
    return filter_by_status(items, {"blocked"})

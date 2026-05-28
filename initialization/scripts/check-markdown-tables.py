#!/usr/bin/env python3
"""Small GitHub-style Markdown table syntax checker."""
from __future__ import annotations
import re
import sys
from pathlib import Path
SEP_RE = re.compile(r"^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$")
def split_row(line: str) -> list[str]:
    s = line.strip()
    if s.startswith("|"): s = s[1:]
    if s.endswith("|"): s = s[:-1]
    return [c.strip() for c in s.split("|")]
def check_file(path: Path) -> list[str]:
    lines = path.read_text(encoding="utf-8").splitlines(); errors: list[str] = []
    for i, line in enumerate(lines[:-1]):
        if "|" not in line: continue
        sep = lines[i + 1]
        if not SEP_RE.match(sep): continue
        header_cells = split_row(line); sep_cells = split_row(sep)
        if len(header_cells) < 2:
            errors.append(f"{path}:{i + 1}: table header must have at least 2 columns"); continue
        if len(header_cells) != len(sep_cells):
            errors.append(f"{path}:{i + 2}: separator has {len(sep_cells)} cells, header has {len(header_cells)}")
        j = i + 2
        while j < len(lines) and "|" in lines[j].strip() and lines[j].strip():
            row_cells = split_row(lines[j])
            if len(row_cells) != len(header_cells):
                errors.append(f"{path}:{j + 1}: row has {len(row_cells)} cells, header has {len(header_cells)}")
            j += 1
    return errors
def main(argv: list[str]) -> int:
    if not argv:
        print("usage: initialization/scripts/check-markdown-tables.py FILE.md [...]", file=sys.stderr); return 2
    errors: list[str] = []
    for arg in argv:
        path = Path(arg)
        if path.suffix.lower() == ".md": errors.extend(check_file(path))
    if errors:
        print("markdown_table_check=failed", file=sys.stderr)
        for error in errors: print(error, file=sys.stderr)
        return 1
    print("markdown_table_check=OK"); return 0
if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

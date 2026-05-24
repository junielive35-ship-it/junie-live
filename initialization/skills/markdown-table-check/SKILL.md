---
name: markdown-table-check
description: "Use when adding or editing Markdown tables; verify table syntax with the project checker before accepting changes."
---

# Markdown Table Check

Use this skill only when a task adds or edits Markdown tables. Do not run extra table checks for Markdown changes that do not touch tables.

## Goal

Markdown tables are easy to break in plain text and may stop rendering while still looking superficially correct. Before accepting a change that edits tables, verify table syntax with the project's available checker.

## Workflow

1. Identify changed Markdown files that contain added or edited tables.
2. Use the project's local table checker if one exists.
   - Example for Junie Live-style repos: `scripts/check-markdown-tables.py <changed-md-files-with-tables>`.
3. If no project checker exists, use an available Markdown parser/linter that supports GitHub-style tables.
4. Fix rows, separators, and unescaped `|` characters until the table renders as a table.
5. Report the checker command and result in the handoff.

## Notes

- Prefer avoiding literal `|` inside table cells; use semicolons, commas, or escape the pipe if needed.
- A full Markdown lint run is optional and project-dependent. The required gate here is table syntax for files with edited tables.

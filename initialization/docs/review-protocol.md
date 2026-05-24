# Review Protocol

Use this file to guide implementation review before accepting worker output or opening/updating a PR.

## Review checklist

- Does the change solve the requested problem?
- Does it align with `MEMORY.md`, strategy, architecture, and accepted decisions?
- Does it avoid unintended product behavior changes?
- Are edge cases handled?
- Are tests, lint, typecheck, or build results available and meaningful?
- Are migrations, configs, deploy steps, or docs needed?
- Is the diff smaller and simpler than plausible alternatives?
- Are risks and follow-ups recorded?
- Did the worker check `git status --short --branch --untracked-files=all`, with a clean final state or only intentional changes called out?
- Are accidental root workspace artifacts such as `AGENTS.md`, `USER.md`, `.openclaw/`, or runtime state files absent from the repo root unless intentionally tracked?
- Did the change avoid masking workspace trash with `.gitignore`, `.git/info/exclude`, global excludes, or similar mechanisms?
- If committed, does the commit subject describe the actual change instead of a generic iteration counter such as `Autonomous MVP loop iteration N`?

## PR checklist

TODO: adapt during bootstrap to project conventions.

## Project-specific review rules

TODO

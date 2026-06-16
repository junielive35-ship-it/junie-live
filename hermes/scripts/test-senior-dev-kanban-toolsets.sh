#!/usr/bin/env bash
# Regression guard for Senior Dev Kanban toolset split.
# Does not call hermes CLI or modify live profiles.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail_count=0
pass_count=0

pass() { pass_count=$((pass_count + 1)); }
fail() { printf '  FAIL: %s\n' "$*" >&2; fail_count=$((fail_count + 1)); }

printf '=== Test 1: hire-junie does not enable marinator for junie-live ===\n'
python3 - "$ROOT/scripts/hire-junie.sh" <<'PY' && pass || fail "hire-junie still exposes marinator toolset"
import re
import sys

path = sys.argv[1]
text = open(path).read()
enabled = re.findall(r'for toolset in ([^;\n]+); do', text)
main_blocks = [block.strip() for block in enabled if block.strip() != 'marinator senior terminal file']
bad = [block for block in main_blocks if 'marinator' in block.split()]
assert not bad, bad
assert any('senior' in block.split() for block in main_blocks), main_blocks
assert 'tools disable --platform "$platform" marinator' in text
print('OK: main-profile toolset enable loops exclude marinator and include senior')
PY

printf '=== Test 2: senior-dev installer keeps marinator and senior toolsets ===\n'
if grep -Eq 'for toolset in marinator senior terminal file; do' "$ROOT/scripts/install-senior-dev-profile.sh"; then
  printf '  OK: senior-dev installer enables marinator senior terminal file\n'
  pass
else
  fail "senior-dev installer no longer enables required toolsets"
fi

printf '=== Test 3: Chat Agent-facing docs do not instruct direct marinator_delegate ===\n'
python3 - "$ROOT" <<'PY' && pass || fail "Chat Agent-facing docs still instruct direct marinator_delegate"
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
paths = [
    root / 'distribution' / 'SOUL.md',
    root / 'distribution' / 'HERMES.seed.md',
    root / 'distribution' / 'INITIALIZATION.md',
    root / 'distribution' / 'memory-seed.md',
    root / 'distribution' / 'docs' / 'code-mutex-protocol.md',
    root / 'distribution' / 'skills' / 'junie-coding-task-decomposition' / 'SKILL.md',
    root / 'distribution' / 'skills' / 'junie-implementation-review' / 'SKILL.md',
    root / 'distribution' / 'skills' / 'junie-autonomous-work-window' / 'SKILL.md',
    root / 'distribution' / 'plugins' / 'autonomous-work' / 'prompts.py',
    root / 'README.md',
    root / 'docs' / 'setup.md',
    root / 'docs' / 'code-mutex.md',
    root / 'docs' / 'day-to-day-routines.md',
    root / 'docs' / 'overnight-routines.md',
]
bad_phrases = [
    'delegated via `marinator_delegate`',
    'via `marinator_delegate` or `delegate_task`',
    'prepare a `marinator_delegate` invocation',
    'must be performed via `marinator_delegate`',
    'delegate fixes back via `marinator_delegate`',
    'go through marinator_delegate per',
    'use marinator_delegate for all code-changing work',
    'all coding delegated via marinator_delegate',
    'all code-changing work must go through `marinator_delegate`',
    'use `marinator_delegate` vs `delegate_task`',
]
violations = []
for path in paths:
    text = path.read_text()
    lowered = text.lower()
    for phrase in bad_phrases:
        if phrase.lower() in lowered:
            violations.append(f'{path.relative_to(root)}: {phrase}')
assert not violations, '\n'.join(violations)
print('OK: Chat Agent-facing docs point at Senior Dev Kanban instead of direct Marinator')
PY

printf '=== Test 4: rehire cleans stale junie-live marinator toolset ===\n'
python3 - "$ROOT/scripts/rehire-junie.sh" <<'PY' && pass || fail "rehire does not clean stale marinator toolset"
import sys

text = open(sys.argv[1]).read()
assert 'Older dumps may contain marinator in junie-live platform_toolsets' in text
assert 'tools disable --platform "$platform" marinator' in text
assert 'tools enable --platform "$platform" senior' in text
print('OK: rehire disables marinator and enables senior for junie-live')
PY

printf '\n=== Results ===\n'
printf 'Passed: %d, Failed: %d\n' "$pass_count" "$fail_count"

if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi

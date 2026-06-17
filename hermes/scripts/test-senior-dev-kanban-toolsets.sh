#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

printf '=== Test 1: hire-junie enables Senior p1 toolset ===\n'
python3 - "$ROOT/scripts/hire-junie.sh" <<'PY' || fail "hire-junie does not enable senior toolset"
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
assert '"senior-task"' in text
assert 'for toolset in senior terminal file; do' in text
print('OK: main profile enables senior, terminal, file')
PY

printf '=== Test 2: senior-dev installer enables sync runner toolsets ===\n'
python3 - "$ROOT/scripts/install-senior-dev-profile.sh" <<'PY' || fail "senior-dev installer toolsets are not p1-only"
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
assert 'for toolset in senior senior_runner kanban terminal file; do' in text
assert '"senior-task"' in text
assert '"senior-runner"' in text
print('OK: senior-dev installer enables p1 toolsets')
PY

printf '=== Test 3: p1 docs expose expected surface ===\n'
python3 - "$ROOT" <<'PY' || fail "p1 docs missing expected tools"
from pathlib import Path
import sys
root = Path(sys.argv[1])
text = (root / 'distribution' / 'docs' / 'tools.md').read_text()
for needle in ['senior_active_tasks', 'create_senior_task', 'senior_run_coding_task', 'kanban_comment', 'kanban_block']:
    assert needle in text, needle
print('OK: docs expose Senior p1 surface')
PY

printf 'All Senior Dev Kanban toolset tests passed.\n'

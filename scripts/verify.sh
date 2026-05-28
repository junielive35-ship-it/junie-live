#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log() { printf '==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Clear inherited environment variables from older autonomous/opencode experiments
# so tests are deterministic regardless of calling context.
while IFS= read -r _var; do
  unset "$_var"
done < <(env | grep -oE '^AUTONOMOUS_[^=]+' || true)
unset OPENROUTER_API_KEY OPENCODE OPENCODE_PID OPENCODE_PROCESS_ROLE 2>/dev/null || true

log "preflight clean working tree"
if git status --porcelain --untracked-files=all | grep -q .; then
  git status --short --branch --untracked-files=all >&2
  fail "working tree is not clean before verify; commit, stash, or remove changes first"
fi

log "bash syntax"
bash -n hire-junie.sh
script_count=0
while IFS= read -r script; do
  [[ -f "$script" ]] || continue
  bash -n "$script" || fail "bash syntax error in $script"
  script_count=$((script_count + 1))
done < <(find scripts -maxdepth 1 -name '*.sh' -type f | sort)
[[ "$script_count" -ge 8 ]] || fail "expected at least 8 bash scripts in scripts/, found $script_count"

log "python syntax"
python3 -m py_compile scripts/check-markdown-tables.py

log "maintained markdown tables"
scripts/check-markdown-tables.py implementation-status.md

log "local markdown links"
while IFS= read -r file; do
  while IFS= read -r target; do
    [[ -z "$target" ]] && continue
    [[ "$target" =~ ^https?://|^mailto:|^# ]] && continue
    target="${target%%#*}"
    [[ -z "$target" ]] && continue
    [[ "$target" = /* ]] && continue
    path="$(dirname "$file")/$target"
    [[ -e "$path" ]] || fail "broken link in ${file#./}: $target"
  done < <(grep -oE '\[[^]]+\]\([^)]+\)' "$file" | sed -E 's/^.*\(([^)]+)\)$/\1/' || true)
done < <(find . -path './.git' -prune -o -path './hermes' -prune -o -name '*.md' -type f -print)

log "md consistency scan"
mc_base="$(mktemp -d)"
./scripts/md-consistency.sh >"$mc_base/md-consistency.out"
grep -q '^checked=' "$mc_base/md-consistency.out" || fail "md-consistency missing checked count"
mc_count=$(grep '^checked=' "$mc_base/md-consistency.out" | sed 's/^checked=//')
[[ "$mc_count" -ge 8 ]] || fail "md-consistency checked too few refs: $mc_count"
grep -q '^broken=0$' "$mc_base/md-consistency.out" || fail "md-consistency found broken refs in repo docs: $(cat "$mc_base/md-consistency.out")"

mc_tmp="$mc_base/synthetic"
mkdir -p "$mc_tmp/scripts"
printf '#!/bin/true\n' > "$mc_tmp/scripts/exists.sh"
printf '# Test\n\nSee `scripts/exists.sh` and `missing-script.sh`.\n' > "$mc_tmp/test.md"
set +e
./scripts/md-consistency.sh --repo "$mc_tmp" >"$mc_base/mc-broken.out" 2>"$mc_base/mc-broken.err"
mc_status=$?
set -e
[[ "$mc_status" -eq 1 ]] || fail "md-consistency should exit 1 when broken refs found"
grep -q '^broken=1$' "$mc_base/mc-broken.out" || fail "md-consistency should report 1 broken ref"
grep -q 'missing-script.sh' "$mc_base/mc-broken.out" || fail "md-consistency should report missing-script.sh"
rm -rf "$mc_base"

log "initialization seed guidance"
seed_agents="initialization/AGENTS.md"
seed_delegation="initialization/docs/delegation-protocol.md"
seed_review="initialization/docs/review-protocol.md"
for seed_file in "$seed_agents" "$seed_delegation" "$seed_review"; do
  [[ -f "$seed_file" ]] || fail "missing initialization seed file: $seed_file"
done
seed_hygiene_text="$(cat "$seed_agents" "$seed_delegation" "$seed_review")"
grep -q 'git status --short --branch --untracked-files=all' <<<"$seed_hygiene_text" || fail "initialization seed must require full git status checks after worker work"
grep -qi 'final state should be clean' <<<"$seed_hygiene_text" || fail "initialization seed must require clean or called-out final status"
grep -qi 'intentional changes' <<<"$seed_hygiene_text" || fail "initialization seed must call out intentional remaining changes"
grep -q 'AGENTS.md' <<<"$seed_hygiene_text" || fail "initialization seed must name root AGENTS.md artifacts"
grep -q 'USER.md' <<<"$seed_hygiene_text" || fail "initialization seed must name root USER.md artifacts"
grep -q '\.openclaw/' <<<"$seed_hygiene_text" || fail "initialization seed must name root .openclaw artifacts"
grep -q '\.git/info/exclude' <<<"$seed_hygiene_text" || fail "initialization seed must forbid .git/info/exclude masking"
grep -q '\.gitignore' <<<"$seed_hygiene_text" || fail "initialization seed must forbid .gitignore masking"
grep -qi 'Autonomous MVP loop iteration N' <<<"$seed_hygiene_text" || fail "initialization seed must reject generic iteration-counter commit subjects"
grep -qi 'actual change' <<<"$seed_hygiene_text" || fail "initialization seed must require commit subjects based on actual changes"
grep -qi 'cross-cutting invariants' <<<"$seed_hygiene_text" || fail "initialization seed must extract cross-cutting invariants"
grep -qi 'implementation acceptance loop' <<<"$seed_hygiene_text" || fail "initialization seed must name implementation acceptance loop"
grep -qi 'worker/delegation/review/fix/acceptance' <<<"$seed_hygiene_text" || fail "initialization seed must preserve worker/delegation/review/fix/acceptance loop"
grep -qi 'Never silently abandon half-finished work' <<<"$seed_hygiene_text" || fail "initialization seed must forbid silent abandonment of half-finished work"
grep -qi 'Incomplete-task reporting guardrail' initialization/AGENTS.md || fail "AGENTS seed must include incomplete-task reporting guardrail section"

log "removed auxiliary implementations stay removed"
for removed in \
  docs/overnight-routines.md \
  initialization/skills/autonomous-work-window/SKILL.md \
  scripts/backlog.sh \
  scripts/backlog-hygiene.sh \
  scripts/backlog-rescore.sh \
  scripts/drive.sh \
  scripts/hypothesis-generate.sh \
  scripts/install-overnight-crons.sh \
  scripts/next-action.sh \
  scripts/overnight-controller.sh \
  scripts/overnight-watchdog.sh \
  scripts/report.sh \
  scripts/routine-health.sh \
  scripts/run-backlog-worker.sh \
  scripts/start-autonomous-window.sh; do
  [[ ! -e "$removed" ]] || fail "removed auxiliary implementation still exists: $removed"
done

log "remaining docs do not reference removed implementation scripts"
removed_ref_pattern='scripts/(backlog|backlog-hygiene|backlog-rescore|drive|hypothesis-generate|install-overnight-crons|next-action|overnight-controller|overnight-watchdog|report|routine-health|run-backlog-worker|start-autonomous-window)\.sh|docs/overnight-routines\.md|opencode serve|--attach http://127\.0\.0\.1'
if grep -RIn --exclude-dir=.git --exclude-dir=.idea --exclude-dir=hermes --exclude='verify.sh' \
  -E "$removed_ref_pattern" .; then
  fail "remaining docs/scripts reference removed auxiliary implementations"
fi

log "repo hygiene"
scripts/check-repo-hygiene.sh

log "git diff whitespace"
git diff --check

log "ok"

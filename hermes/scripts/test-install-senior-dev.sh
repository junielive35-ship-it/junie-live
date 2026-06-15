#!/usr/bin/env bash
# Test senior-dev profile install logic: seed validity, plugin sources,
# expected file layout after install, plugin enable config writing.
# Does NOT call hermes CLI or modify live profiles.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEED_DIR="$ROOT/distribution/profiles/senior-dev"
PLUGIN_SRC="$ROOT/distribution/plugins"

fail_count=0
pass_count=0

pass() { pass_count=$((pass_count + 1)); }
fail() { printf '  FAIL: %s\n' "$*" >&2; fail_count=$((fail_count + 1)); }

# ════════════════════════════════════════════════════════════════
printf '=== Test 1: Seed directory exists ===\n'
if [[ -d "$SEED_DIR" ]]; then
  echo "OK: $SEED_DIR"
  pass
else
  fail "Seed directory missing: $SEED_DIR"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 2: Seed has required files ===\n'
missing=0
for f in distribution.yaml config.yaml SOUL.md HERMES.seed.md; do
  if [[ -f "$SEED_DIR/$f" ]]; then
    echo "  OK: $f"
  else
    echo "  MISSING: $f"
    missing=$((missing+1))
  fi
done
if [[ "$missing" -eq 0 ]]; then
  pass
else
  fail "$missing seed files missing"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 3: distribution.yaml is valid YAML ===\n'
python3 -c "
import yaml
with open('$SEED_DIR/distribution.yaml') as f:
    d = yaml.safe_load(f)
assert d.get('name') == 'senior-dev', 'name: ' + str(d.get('name'))
assert 'distribution_owned' in d, 'missing distribution_owned'
owned = d['distribution_owned']
for f in ['SOUL.md', 'HERMES.seed.md', 'distribution.yaml']:
    assert f in owned, f + ' not in distribution_owned'
print('OK: name=senior-dev, %d owned files' % len(owned))
" && pass || fail "distribution.yaml validation failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 4: Plugin sources exist ===\n'
missing=0
for p in marinator-delegation senior-task; do
  if [[ -d "$PLUGIN_SRC/$p" ]]; then
    echo "  OK: $p"
  else
    echo "  MISSING: $p"
    missing=$((missing+1))
  fi
done
if [[ "$missing" -eq 0 ]]; then
  pass
else
  fail "$missing plugin sources missing"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 5: Plugin source has required files ===\n'
missing=0
for p in marinator-delegation senior-task; do
  for f in plugin.yaml __init__.py tools.py; do
    if [[ -f "$PLUGIN_SRC/$p/$f" ]]; then
      echo "  OK: $p/$f"
    else
      echo "  MISSING: $p/$f"
      missing=$((missing+1))
    fi
  done
done
if [[ "$missing" -eq 0 ]]; then
  pass
else
  fail "$missing plugin files missing"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 6: Temp install smoke — file layout ===\n'
TEMP_DIR=$(mktemp -d)
cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

# Simulate what install-senior-dev-profile.sh does after hermes profile install:
# 1. Create profile directory structure
PROFILE_DIR="$TEMP_DIR/profiles/senior-dev"
mkdir -p "$PROFILE_DIR"

# 2. Copy seed files
cp "$SEED_DIR/config.yaml" "$PROFILE_DIR/config.yaml"
cp "$SEED_DIR/SOUL.md" "$PROFILE_DIR/SOUL.md"
cp "$SEED_DIR/HERMES.seed.md" "$PROFILE_DIR/HERMES.seed.md"

# 3. Copy plugins (simulating Step 3 of install script)
PLUGIN_TARGET="$PROFILE_DIR/plugins"
mkdir -p "$PLUGIN_TARGET"
for plugin in marinator-delegation senior-task; do
  cp -a "$PLUGIN_SRC/$plugin" "$PLUGIN_TARGET/$plugin"
done

# 4. Verify expected file layout
missing=0
# Profile root files
for f in config.yaml SOUL.md HERMES.seed.md; do
  if [[ -f "$PROFILE_DIR/$f" ]]; then
    echo "  OK: $f"
  else
    echo "  MISSING: $f"
    missing=$((missing+1))
  fi
done
# Plugin dirs
for p in marinator-delegation senior-task; do
  for f in plugin.yaml __init__.py tools.py; do
    if [[ -f "$PLUGIN_TARGET/$p/$f" ]]; then
      echo "  OK: plugins/$p/$f"
    else
      echo "  MISSING: plugins/$p/$f"
      missing=$((missing+1))
    fi
  done
done

if [[ "$missing" -eq 0 ]]; then
  pass
else
  fail "$missing files missing in simulated install"
fi

# ════════════════════════════════════════════════════════════════
printf '=== Test 7: Config merge logic (plugin enable) ===\n'
python3 -c "
import json, os, tempfile

# Simulate ensure_plugin logic: read config, append plugin, write back
config_file = os.path.join('$TEMP_DIR', 'config_merge_test.yaml')

# Write initial config with existing plugins
with open(config_file, 'w') as f:
    f.write('plugins:\\n  enabled:\\n    - marinator-delegation\\n')

# Simulate loading and appending a new plugin
import yaml
with open(config_file) as f:
    cfg = yaml.safe_load(f) or {}
enabled = (cfg.get('plugins') or {}).get('enabled') or []
existing = enabled if isinstance(enabled, list) else []
for plugin in ['senior-task']:
    if plugin not in existing:
        existing.append(plugin)

assert 'marinator-delegation' in existing, 'existing plugin preserved'
assert 'senior-task' in existing, 'new plugin added'

# Verify it can be round-tripped
with open(config_file, 'w') as f:
    f.write(yaml.dump({'plugins': {'enabled': existing}}, default_flow_style=False))

with open(config_file) as f:
    cfg2 = yaml.safe_load(f) or {}
enabled2 = cfg2['plugins']['enabled']
assert enabled2 == ['marinator-delegation', 'senior-task'], str(enabled2)

print('OK: config merge round-trips correctly: %s' % enabled2)
" && pass || fail "Config merge test failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 8: Profile-dir resolver — HERMES_HOME has /profiles/ ===\n'
python3 -c "
import os, tempfile

# Simulate profile-session environment:
# HERMES_HOME = /tmp/xxx/hermes-home/profiles/junie-live
# Expected: senior-dev at /tmp/xxx/hermes-home/profiles/senior-dev
fake_root = tempfile.mkdtemp(prefix='sd-resolver-')
hermes_home = os.path.join(fake_root, 'hermes-home', 'profiles', 'junie-live')

# The resolver logic (copied from install script):
profile = 'senior-dev'
hh = hermes_home
assert '/profiles/' in hh
idx = hh.index('/profiles/')
root = hh[:idx]
candidate = os.path.join(root, 'profiles', profile)

expected = os.path.join(fake_root, 'hermes-home', 'profiles', 'senior-dev')
assert candidate == expected, 'got %s, expected %s' % (candidate, expected)
print('OK: HERMES_HOME=%s' % hermes_home)
print('    resolves to: %s' % candidate)
import shutil
shutil.rmtree(fake_root)
" && pass || fail "Profile-dir resolver test (hermes_home with /profiles/) failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 9: Profile-dir resolver — plain HERMES_HOME ===\n'
python3 -c "
import os, tempfile

# HERMES_HOME = /tmp/xxx/hermes-root (no /profiles/ in path)
# Expected: senior-dev at $HERMES_HOME/profiles/senior-dev
fake_root = tempfile.mkdtemp(prefix='sd-resolver-')
hermes_home = os.path.join(fake_root, 'hermes-root')

profile = 'senior-dev'
hh = hermes_home
if '/profiles/' not in hh:
    candidate = os.path.join(hh, 'profiles', profile)

expected = os.path.join(fake_root, 'hermes-root', 'profiles', 'senior-dev')
assert candidate == expected, 'got %s, expected %s' % (candidate, expected)
print('OK: HERMES_HOME=%s' % hermes_home)
print('    resolves to: %s' % candidate)
import shutil
shutil.rmtree(fake_root)
" && pass || fail "Profile-dir resolver test (plain hermes_home) failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 10: Profile-dir resolver — JUNIE_HERMES_ROOT ===\n'
python3 -c "
import os, tempfile

# JUNIE_HERMES_ROOT = /tmp/xxx/hermes-root (no HERMES_HOME set)
# Expected: senior-dev at JUNIE_HERMES_ROOT/profiles/senior-dev
fake_root = tempfile.mkdtemp(prefix='sd-resolver-')
jhr = os.path.join(fake_root, 'hermes-root')

profile = 'senior-dev'
jhr_val = jhr
# HERMES_HOME is empty in this scenario
candidate = os.path.join(jhr_val, 'profiles', profile)

expected = os.path.join(fake_root, 'hermes-root', 'profiles', 'senior-dev')
assert candidate == expected, 'got %s, expected %s' % (candidate, expected)
print('OK: JUNIE_HERMES_ROOT=%s' % jhr)
print('    resolves to: %s' % candidate)
import shutil
shutil.rmtree(fake_root)
" && pass || fail "Profile-dir resolver test (JUNIE_HERMES_ROOT) failed"

# ════════════════════════════════════════════════════════════════
printf '=== Test 11: Python plugin imports from simulated profile ===\n'
python3 -c "
import importlib.util, sys, os

# Test importing senior-task tools from the simulated install
plugin_dir = os.path.join('$TEMP_DIR', 'profiles', 'senior-dev', 'plugins', 'senior-task')
spec = importlib.util.spec_from_file_location('st_plugin', os.path.join(plugin_dir, 'tools.py'))
module = importlib.util.module_from_spec(spec)
sys.modules['st_plugin'] = module
spec.loader.exec_module(module)

# Verify expected symbols exist
assert hasattr(module, 'handle_create_senior_task'), 'missing handle_create_senior_task'
assert hasattr(module, 'handle_senior_dev_task_result'), 'missing handle_senior_dev_task_result'
assert hasattr(module, 'CREATE_SENIOR_TASK_SCHEMA'), 'missing CREATE_SENIOR_TASK_SCHEMA'
assert hasattr(module, 'SENIOR_DEV_TASK_RESULT_SCHEMA'), 'missing SENIOR_DEV_TASK_RESULT_SCHEMA'
print('OK: senior-task tools.py imports correctly from simulated install')
" && pass || fail "Plugin import test failed"

# ════════════════════════════════════════════════════════════════
printf '\n'
printf '=== Results ===\n'
printf 'Passed: %d, Failed: %d\n' "$pass_count" "$fail_count"

if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi

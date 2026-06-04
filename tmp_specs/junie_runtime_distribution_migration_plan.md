# Junie Runtime + Profile Distribution Migration Plan

> Scope requested: (1) align the repo-level `hermes/` folder with the target Junie runtime + profile distribution architecture; (2) first PR: shared global `junie_runtime` package + Python mutex source of truth.

## 1. Locked decisions

- `junie_runtime` is a normal Python package shared by the whole Hermes install / Python environment, not profile-local code.
- Profiles own state/config/docs/skills/plugins; they do not own separate runtime versions or profile-local venvs.
- Profile distribution is the canonical long-term delivery mechanism for Junie profile assets.
- `hermes/initialization/` has been removed; all profile assets now live under `hermes/distribution/`.
- Bash may remain only as a thin compatibility wrapper around Python/runtime entrypoints.
- No new runtime logic should be copied between scripts, plugins, workers, or initialization files.

## 2. Target `hermes/` folder shape

```text
hermes/
  docs/                         # repo-level product/ops/design docs
  distribution/                 # Hermes profile distribution payload
    distribution.yaml
    SOUL.md
    HERMES.seed.md              # seed for profile-local high-authority HERMES.md
    config.yaml
    .env.EXAMPLE
    docs/                       # profile-internal Junie docs
    skills/
    plugins/
    cron/                       # optional profile jobs
    mcp.json                    # optional profile MCP config
  junie_runtime/                # shared Python package, installed into Hermes env
    pyproject.toml
    src/junie_runtime/
      __init__.py
      paths.py
      state.py
      events.py
      mutex.py
      cli/
        __init__.py
        mutex.py
    tests/
      test_mutex.py
      test_paths.py
      test_state.py
  scripts/                      # repo verification/migration/thin compatibility only
    verify.sh
    hire-junie.sh               # temporary compatibility wrapper, not canonical install
    rehire-junie.sh             # temporary compatibility wrapper, not canonical restore
  tests/                        # repo-level integration tests if needed
  tmp_specs/                    # temporary planning artifacts, not product architecture
```

Canonical install/update direction:

```bash
# Runtime package, shared by all Junie profiles in this Hermes install.
python -m pip install -e hermes/junie_runtime

# Profile assets, delivered by Hermes-native profile distribution.
hermes profile install hermes/distribution --alias
hermes profile update junie-live
```

## 3. Responsibility boundaries

### `junie_runtime`

Owns reusable operational primitives used by multiple Junie entrypoints:

- profile/path resolution that is robust to rewritten `$HOME` and `$HERMES_HOME` profile mode;
- atomic state file helpers;
- JSONL event/status/report helpers;
- code mutex implementation and CLI.

Later additions require a second real consumer. Examples:

- `git.py` only when consistency runner and another routine both need git preflight helpers;
- `process.py` only when Marinator worker migration needs shared process supervision;
- `hermes.py` only when multiple routines need Hermes CLI invocation helpers.

### Profile distribution

Owns profile assets only:

- `SOUL.md`, config, skills, docs, plugins, cron, MCP config, env example;
- seed/template material for profile-local high-authority `HERMES.md`;
- no runtime package source copied into the profile;
- no secrets beyond `.env.EXAMPLE` / documented env requirements.

### Compatibility scripts

Existing shell entrypoints may stay temporarily if users/operators already call them, but they must delegate to Python or Hermes-native commands and fail clearly if prerequisites are missing.

## 4. First PR: shared runtime package + Python mutex

### Goal

Introduce globally installed `junie_runtime` and make Python mutex the single source of truth while preserving current mutex CLI behavior.

### Create

- `hermes/junie_runtime/pyproject.toml`
- `hermes/junie_runtime/src/junie_runtime/__init__.py`
- `hermes/junie_runtime/src/junie_runtime/paths.py`
- `hermes/junie_runtime/src/junie_runtime/state.py`
- `hermes/junie_runtime/src/junie_runtime/events.py`
- `hermes/junie_runtime/src/junie_runtime/mutex.py`
- `hermes/junie_runtime/src/junie_runtime/cli/__init__.py`
- `hermes/junie_runtime/src/junie_runtime/cli/mutex.py`
- `hermes/junie_runtime/tests/test_paths.py`
- `hermes/junie_runtime/tests/test_state.py`
- `hermes/junie_runtime/tests/test_mutex.py`

### Modify

- `hermes/distribution/scripts/code-mutex.sh`:
  - convert to thin wrapper around `python -m junie_runtime.cli.mutex ...`;
  - keep current command contract and output shape.
- `hermes/scripts/verify.sh`:
  - verify `junie_runtime` import/package metadata;
  - run `hermes/junie_runtime/tests`.
- `hermes/scripts/hire-junie.sh` / `rehire-junie.sh`:
  - stop treating runtime as copied profile payload;
  - if retained, run/check `python -m pip install -e hermes/junie_runtime` as an explicit compatibility step.
- Docs:
  - document `junie_runtime` install/update command;
  - document that profile distribution owns profile assets, not runtime package source;
  - document `HERMES.md` as profile-local high-authority agent/project operating state, not ordinary repo docs.

## 5. Mutex behavior to preserve

Existing commands must keep working:

```bash
$HERMES_HOME/scripts/code-mutex.sh status
$HERMES_HOME/scripts/code-mutex.sh acquire --holder ID --reason TEXT --repo DIR
$HERMES_HOME/scripts/code-mutex.sh release --holder ID
$HERMES_HOME/scripts/code-mutex.sh check-stale --stale-minutes N --auto-recover
```

Semantics:

- atomic `mkdir` remains the lock primitive;
- directory exists + `holder.json` exists = held;
- directory exists + no `holder.json` = broken and blocks acquisition;
- `--auto-recover` may remove only broken empty mutex state;
- stale holder metadata is reported but not auto-recovered;
- release verifies holder identity unless `--force`;
- works with root or profile-scoped `$HERMES_HOME`;
- never relies on rewritten `$HOME`.

Suggested Python API:

```python
with mutex.acquire(mutex_dir, holder_id, reason, repo=repo, branch=branch):
    ...
```

Core functions:

```python
status(mutex_dir) -> MutexStatus
acquire(mutex_dir, holder_id, reason, repo=None, branch=None) -> MutexLease
release(mutex_dir, holder_id, force=False) -> ReleaseResult
check_stale(mutex_dir, stale_minutes) -> StaleResult
```

## 6. Tests and verification

`junie_runtime` tests should cover:

- path resolution with root and profile-scoped `$HERMES_HOME`;
- state root resolution;
- atomic JSON/text write + read;
- mutex acquire success creates directory + `holder.json`;
- second acquire fails with holder info;
- release matching holder succeeds;
- release mismatched holder fails unless force;
- broken mutex detection;
- stale mutex reporting;
- `--auto-recover` only removes broken empty mutex;
- shell wrapper compatibility for status/acquire/release/check-stale;
- import works through normal package install, not `sys.path` mutation.

Verification commands:

```bash
python -m pip install -e hermes/junie_runtime
python -m compileall hermes/junie_runtime/src
python -m pytest hermes/junie_runtime/tests -q
./hermes/scripts/verify.sh
```

## 7. Acceptance gate

- `junie_runtime.mutex` is the only mutex source of truth.
- `code-mutex.sh` is a thin compatibility wrapper only.
- No duplicated mutex logic remains in consistency-check or Marinator follow-up work.
- Runtime package is installed into the shared Hermes Python environment, not copied into profiles.
- Profile distribution contains profile assets only.
- Existing mutex command behavior remains compatible.
- Docs clearly separate repo docs, profile-internal Junie docs, and high-authority profile-local `HERMES.md`.

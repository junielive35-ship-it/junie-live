import os
import sys
from pathlib import Path

from junie_runtime import paths


def test_hermes_home_default() -> None:
    saved_hh = os.environ.pop("HERMES_HOME", None)
    saved_home = os.environ.get("HOME")
    os.environ["HOME"] = "/home/regular/user"
    try:
        result = paths.hermes_home()
        assert result == os.path.expanduser("~/.hermes")
    finally:
        if saved_hh is not None:
            os.environ["HERMES_HOME"] = saved_hh
        if saved_home is not None:
            os.environ["HOME"] = saved_home
        else:
            os.environ.pop("HOME", None)


def test_hermes_home_env() -> None:
    saved = os.environ.get("HERMES_HOME")
    os.environ["HERMES_HOME"] = "/custom/hermes"
    try:
        assert paths.hermes_home() == "/custom/hermes"
    finally:
        if saved is not None:
            os.environ["HERMES_HOME"] = saved
        else:
            os.environ.pop("HERMES_HOME", None)


def test_hermes_profile_default() -> None:
    saved = os.environ.pop("HERMES_PROFILE", None)
    try:
        assert paths.hermes_profile() == "junie-live"
    finally:
        if saved is not None:
            os.environ["HERMES_PROFILE"] = saved


def test_hermes_profile_env() -> None:
    saved = os.environ.get("HERMES_PROFILE")
    os.environ["HERMES_PROFILE"] = "custom-profile"
    try:
        assert paths.hermes_profile() == "custom-profile"
    finally:
        if saved is not None:
            os.environ["HERMES_PROFILE"] = saved
        else:
            os.environ.pop("HERMES_PROFILE", None)


def test_profile_dir_normal() -> None:
    result = paths.profile_dir(home="/root/.hermes", profile="test-p")
    assert result == "/root/.hermes/profiles/test-p"


def test_profile_dir_already_profile() -> None:
    result = paths.profile_dir(
        home="/home/user/.hermes/profiles/junie-live", profile="junie-live"
    )
    assert result == "/home/user/.hermes/profiles/junie-live"


def test_profile_dir_already_profile_name_mismatch() -> None:
    result = paths.profile_dir(
        home="/home/user/.hermes/profiles/other-profile", profile="junie-live"
    )
    assert result == "/home/user/.hermes/profiles/other-profile/profiles/junie-live"


def test_state_root() -> None:
    result = paths.state_root(home="/root/.hermes", profile="test-p")
    assert result == "/root/.hermes/profiles/test-p/junie-live/state"


def test_state_root_with_profile_dir() -> None:
    result = paths.state_root(
        home="/home/user/.hermes/profiles/junie-live", profile="junie-live"
    )
    assert result == "/home/user/.hermes/profiles/junie-live/junie-live/state"


def test_profile_dir_with_hermes_profile_dir() -> None:
    saved_hh = os.environ.pop("HERMES_HOME", None)
    saved_pd = os.environ.get("HERMES_PROFILE_DIR")
    os.environ["HERMES_PROFILE_DIR"] = "/custom/profiles/my-profile"
    try:
        assert paths.profile_dir() == "/custom/profiles/my-profile"
        sr = paths.state_root()
        assert sr == "/custom/profiles/my-profile/junie-live/state"
    finally:
        if saved_hh is not None:
            os.environ["HERMES_HOME"] = saved_hh
        if saved_pd is not None:
            os.environ["HERMES_PROFILE_DIR"] = saved_pd
        else:
            os.environ.pop("HERMES_PROFILE_DIR", None)


def test_profile_dir_with_profile_scoped_hermes_home_regardless_of_name() -> None:
    saved_hh = os.environ.get("HERMES_HOME")
    saved_profile = os.environ.get("HERMES_PROFILE")
    os.environ["HERMES_HOME"] = "/custom/.hermes/profiles/other-profile"
    os.environ["HERMES_PROFILE"] = "junie-live"
    try:
        pd = paths.profile_dir()
        assert pd == "/custom/.hermes/profiles/other-profile"
    finally:
        if saved_hh is not None:
            os.environ["HERMES_HOME"] = saved_hh
        else:
            os.environ.pop("HERMES_HOME", None)
        if saved_profile is not None:
            os.environ["HERMES_PROFILE"] = saved_profile
        else:
            os.environ.pop("HERMES_PROFILE", None)


def test_hermes_home_profile_scoped_home() -> None:
    saved_home = os.environ.get("HOME")
    saved_hh = os.environ.pop("HERMES_HOME", None)
    try:
        os.environ["HOME"] = "/home/user/.hermes/profiles/junie-live/home"
        result = paths.hermes_home()
        assert result == "/home/user/.hermes/profiles/junie-live"
    finally:
        if saved_home is not None:
            os.environ["HOME"] = saved_home
        else:
            os.environ.pop("HOME", None)
        if saved_hh is not None:
            os.environ["HERMES_HOME"] = saved_hh


def test_hermes_root_default() -> None:
    saved_hh = os.environ.pop("HERMES_HOME", None)
    saved_home = os.environ.get("HOME")
    os.environ["HOME"] = "/home/regular/user"
    try:
        result = paths.hermes_root()
        assert result == os.path.expanduser("~/.hermes")
    finally:
        if saved_hh is not None:
            os.environ["HERMES_HOME"] = saved_hh
        if saved_home is not None:
            os.environ["HOME"] = saved_home
        else:
            os.environ.pop("HOME", None)


def test_hermes_root_junie_hermes_root() -> None:
    saved_jhr = os.environ.get("JUNIE_HERMES_ROOT")
    os.environ["JUNIE_HERMES_ROOT"] = "/custom/root"
    try:
        assert paths.hermes_root() == "/custom/root"
    finally:
        if saved_jhr is not None:
            os.environ["JUNIE_HERMES_ROOT"] = saved_jhr
        else:
            os.environ.pop("JUNIE_HERMES_ROOT", None)


def test_hermes_root_hermes_home_with_profile(tmp_path) -> None:
    root = tmp_path / "hermes"
    profiles = root / "profiles" / "test-p"
    profiles.mkdir(parents=True)
    saved_hh = os.environ.get("HERMES_HOME")
    os.environ["HERMES_HOME"] = str(root)
    try:
        result = paths.hermes_root(profile="test-p")
        assert result == str(root)
    finally:
        if saved_hh is not None:
            os.environ["HERMES_HOME"] = saved_hh
        else:
            os.environ.pop("HERMES_HOME", None)


def test_hermes_root_profile_scoped() -> None:
    saved_hh = os.environ.get("HERMES_HOME")
    os.environ["HERMES_HOME"] = "/home/user/.hermes/profiles/junie-live"
    try:
        result = paths.hermes_root(profile="junie-live")
        assert result == "/home/user/.hermes"
    finally:
        if saved_hh is not None:
            os.environ["HERMES_HOME"] = saved_hh
        else:
            os.environ.pop("HERMES_HOME", None)


def test_hermes_root_no_fallback_when_hermes_home_explicit(tmp_path) -> None:
    """Regression: explicit HERMES_HOME must not be overridden by ~/.hermes/profiles/<p>.

    When HERMES_HOME is set to a non-profile directory (e.g. a temp rehire
    target), hermes_root() must return that directory even if the operator's
    real ~/.hermes/profiles/<profile> exists.
    """
    # Simulate ~/.hermes/profiles/junie-live existing in the "real" home
    fake_home = tmp_path / "real-home"
    (fake_home / ".hermes" / "profiles" / "junie-live").mkdir(parents=True)

    explicit_hermes_home = str(tmp_path / "rehire-target")

    saved_hh = os.environ.get("HERMES_HOME")
    saved_home = os.environ.get("HOME")
    os.environ["HOME"] = str(fake_home)
    os.environ["HERMES_HOME"] = explicit_hermes_home
    try:
        result = paths.hermes_root(profile="junie-live")
        assert result == explicit_hermes_home, (
            f"hermes_root returned {result!r}, expected {explicit_hermes_home!r}"
        )
    finally:
        if saved_hh is not None:
            os.environ["HERMES_HOME"] = saved_hh
        else:
            os.environ.pop("HERMES_HOME", None)
        if saved_home is not None:
            os.environ["HOME"] = saved_home
        else:
            os.environ.pop("HOME", None)


def test_hermes_root_fallback_to_home_hermes(tmp_path) -> None:
    root = tmp_path / ".hermes"
    (root / "profiles" / "test-p").mkdir(parents=True)
    saved_hh = os.environ.pop("HERMES_HOME", None)
    saved_home = os.environ.get("HOME")
    os.environ["HOME"] = str(tmp_path)
    try:
        result = paths.hermes_root(profile="test-p")
        assert result == str(root)
    finally:
        if saved_hh is not None:
            os.environ["HERMES_HOME"] = saved_hh
        if saved_home is not None:
            os.environ["HOME"] = saved_home
        else:
            os.environ.pop("HOME", None)
        # Remove the created dir to avoid side effects
        import shutil
        shutil.rmtree(str(root), ignore_errors=True)


def test_backup_dir() -> None:
    result = paths.backup_dir(home="/root/.hermes")
    assert result == "/root/.hermes/backups"


def test_runtime_manifest_dir() -> None:
    result = paths.runtime_manifest_dir(home="/root/.hermes", profile="test-p")
    assert result == "/root/.hermes/profiles/test-p/junie-live/runtime"


def test_cli_hermes_root() -> None:
    import subprocess
    saved_hh = os.environ.get("HERMES_HOME")
    os.environ["HERMES_HOME"] = "/custom/hermes"
    try:
        result = subprocess.run(
            [sys.executable, "-m", "junie_runtime.paths", "hermes-root"],
            capture_output=True, text=True, check=True,
        )
        assert result.stdout.strip() == "/custom/hermes"
    finally:
        if saved_hh is not None:
            os.environ["HERMES_HOME"] = saved_hh
        else:
            os.environ.pop("HERMES_HOME", None)


def test_cli_profile_dir() -> None:
    import subprocess
    saved_hh = os.environ.get("HERMES_HOME")
    os.environ["HERMES_HOME"] = "/custom/hermes"
    try:
        result = subprocess.run(
            [sys.executable, "-m", "junie_runtime.paths", "profile-dir", "--profile", "test-p"],
            capture_output=True, text=True, check=True,
        )
        assert result.stdout.strip() == "/custom/hermes/profiles/test-p"
    finally:
        if saved_hh is not None:
            os.environ["HERMES_HOME"] = saved_hh
        else:
            os.environ.pop("HERMES_HOME", None)


def test_cli_backup_path() -> None:
    import subprocess
    saved_hh = os.environ.get("HERMES_HOME")
    os.environ["HERMES_HOME"] = "/custom/hermes"
    try:
        result = subprocess.run(
            [sys.executable, "-m", "junie_runtime.paths", "backup-path", "--profile", "test-p", "--kind", "before-hire"],
            capture_output=True, text=True, check=True,
        )
        out = result.stdout.strip()
        assert out.startswith("/custom/hermes/backups/test-p-before-hire-")
        assert out.endswith(".tgz")
    finally:
        if saved_hh is not None:
            os.environ["HERMES_HOME"] = saved_hh
        else:
            os.environ.pop("HERMES_HOME", None)


def test_cli_runtime_manifest_dir() -> None:
    import subprocess
    saved_hh = os.environ.get("HERMES_HOME")
    os.environ["HERMES_HOME"] = "/custom/hermes"
    try:
        result = subprocess.run(
            [sys.executable, "-m", "junie_runtime.paths", "runtime-manifest-dir", "--profile", "test-p"],
            capture_output=True, text=True, check=True,
        )
        assert result.stdout.strip() == "/custom/hermes/profiles/test-p/junie-live/runtime"
    finally:
        if saved_hh is not None:
            os.environ["HERMES_HOME"] = saved_hh
        else:
            os.environ.pop("HERMES_HOME", None)


def test_profile_dir_via_hermes_home_profile_scoped() -> None:
    saved_home = os.environ.get("HOME")
    saved_profile = os.environ.get("HERMES_PROFILE")
    saved_hh = os.environ.pop("HERMES_HOME", None)
    try:
        os.environ["HOME"] = "/home/user/.hermes/profiles/junie-live/home"
        os.environ["HERMES_PROFILE"] = "junie-live"
        assert paths.hermes_home() == "/home/user/.hermes/profiles/junie-live"
        pd = paths.profile_dir()
        assert pd == "/home/user/.hermes/profiles/junie-live"
        sr = paths.state_root()
        assert sr == "/home/user/.hermes/profiles/junie-live/junie-live/state"
    finally:
        if saved_home is not None:
            os.environ["HOME"] = saved_home
        else:
            os.environ.pop("HOME", None)
        if saved_profile is not None:
            os.environ["HERMES_PROFILE"] = saved_profile
        else:
            os.environ.pop("HERMES_PROFILE", None)
        if saved_hh is not None:
            os.environ["HERMES_HOME"] = saved_hh

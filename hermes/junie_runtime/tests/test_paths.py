import os
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


def test_mutex_dir() -> None:
    result = paths.mutex_dir(home="/root/.hermes", profile="test-p")
    assert result == "/root/.hermes/profiles/test-p/junie-live/state/code_mutex"


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

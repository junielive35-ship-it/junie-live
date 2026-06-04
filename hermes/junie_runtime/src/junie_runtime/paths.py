import os
from pathlib import Path


def hermes_home() -> str:
    explicit = os.environ.get("HERMES_HOME")
    if explicit:
        return explicit

    raw_home = os.environ.get("HOME", "")
    if raw_home:
        p = Path(raw_home)
        if p.name == "home" and p.parent.parent.name == "profiles":
            return str(p.parent)

    return os.path.expanduser("~/.hermes")


def hermes_profile() -> str:
    return os.environ.get("HERMES_PROFILE", "junie-live")


def profile_dir(home: str | None = None, profile: str | None = None) -> str:
    if home is not None:
        h = home
        p = profile if profile is not None else hermes_profile()
        base = Path(h)
        if base.name == p and base.parent.name == "profiles":
            return str(base)
        return str(base / "profiles" / p)

    # Env-driven defaults
    profile_dir_env = os.environ.get("HERMES_PROFILE_DIR")
    if profile_dir_env:
        return profile_dir_env

    h = hermes_home()
    p = profile if profile is not None else hermes_profile()
    base = Path(h)
    if base.parent.name == "profiles":
        return str(base)
    return str(base / "profiles" / p)


def state_root(home: str | None = None, profile: str | None = None) -> str:
    return os.path.join(profile_dir(home, profile), "junie-live", "state")


def mutex_dir(home: str | None = None, profile: str | None = None) -> str:
    return os.path.join(state_root(home, profile), "code_mutex")

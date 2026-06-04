import argparse
import os
import sys
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

    profile_dir_env = os.environ.get("HERMES_PROFILE_DIR")
    if profile_dir_env:
        return profile_dir_env

    h = hermes_home()
    p = profile if profile is not None else hermes_profile()
    base = Path(h)
    if base.parent.name == "profiles":
        return str(base)
    return str(base / "profiles" / p)


def hermes_root(profile: str | None = None) -> str:
    """Resolve Hermes root directory (parent of profiles/).

    Mirrors the shell resolve_hermes_root() logic from dump/rehire scripts.
    """
    explicit = os.environ.get("JUNIE_HERMES_ROOT")
    if explicit:
        return explicit

    hh = hermes_home()
    p = profile if profile is not None else hermes_profile()

    if os.path.isdir(os.path.join(hh, "profiles", p)):
        return hh

    base = os.path.basename(hh)
    parent = os.path.basename(os.path.dirname(hh))
    if base == p and parent == "profiles":
        return os.path.dirname(os.path.dirname(hh))

    home_hermes = os.path.expanduser("~/.hermes")
    if hh != home_hermes and os.path.isdir(os.path.join(home_hermes, "profiles", p)):
        return home_hermes

    return hh


def backup_dir(home: str | None = None, profile: str | None = None) -> str:
    """Default backup directory under Hermes root."""
    h = home if home is not None else hermes_root(profile)
    return os.path.join(h, "backups")


def runtime_manifest_dir(home: str | None = None, profile: str | None = None) -> str:
    return os.path.join(profile_dir(home, profile), "junie-live", "runtime")


def state_root(home: str | None = None, profile: str | None = None) -> str:
    return os.path.join(profile_dir(home, profile), "junie-live", "state")


def mutex_dir(home: str | None = None, profile: str | None = None) -> str:
    return os.path.join(state_root(home, profile), "code_mutex")


# ---------------------------------------------------------------------------
# CLI entrypoint kept in this module so there is exactly one paths surface.
# Import argparse / datetime locally to keep library imports lightweight.
# ---------------------------------------------------------------------------

def cmd_hermes_root(args: argparse.Namespace) -> None:
    root = hermes_root(profile=args.profile)
    print(root)


def cmd_profile_dir(args: argparse.Namespace) -> None:
    pd = profile_dir(profile=args.profile)
    print(pd)


def cmd_state_root(args: argparse.Namespace) -> None:
    sr = state_root(profile=args.profile)
    print(sr)


def cmd_backup_path(args: argparse.Namespace) -> None:
    import datetime
    p = args.profile or hermes_profile()
    bd = backup_dir(profile=p)
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    kind = args.kind or "backup"
    print(f"{bd}/{p}-{kind}-{ts}.tgz")


def cmd_backup_dir(args: argparse.Namespace) -> None:
    bd = backup_dir(profile=args.profile)
    print(bd)


def cmd_runtime_manifest_dir(args: argparse.Namespace) -> None:
    rmd = runtime_manifest_dir(profile=args.profile)
    print(rmd)


def main() -> None:
    import argparse
    parser = argparse.ArgumentParser(
        prog="python -m junie_runtime.paths",
        description="Junie Runtime path resolution CLI for shell integration",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    h = sub.add_parser("hermes-root")
    h.add_argument("--profile", default=None)
    h.set_defaults(func=cmd_hermes_root)

    p = sub.add_parser("profile-dir")
    p.add_argument("--profile", default=None)
    p.set_defaults(func=cmd_profile_dir)

    s = sub.add_parser("state-root")
    s.add_argument("--profile", default=None)
    s.set_defaults(func=cmd_state_root)

    b = sub.add_parser("backup-path")
    b.add_argument("--profile", default=None)
    b.add_argument("--kind", default=None)
    b.set_defaults(func=cmd_backup_path)

    bd = sub.add_parser("backup-dir")
    bd.add_argument("--profile", default=None)
    bd.set_defaults(func=cmd_backup_dir)

    r = sub.add_parser("runtime-manifest-dir")
    r.add_argument("--profile", default=None)
    r.set_defaults(func=cmd_runtime_manifest_dir)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()

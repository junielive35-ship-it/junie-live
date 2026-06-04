import argparse
import json
import sys

from junie_runtime import mutex
from junie_runtime.paths import mutex_dir as default_mutex_dir


def cmd_status(args: argparse.Namespace) -> None:
    md = args.mutex_dir or default_mutex_dir()
    s = mutex.status(md)
    print(f"mutex={s.state}")
    if s.holder_data:
        print(json.dumps(s.holder_data, indent=2))
    if s.state == "BROKEN":
        sys.exit(1)


def cmd_acquire(args: argparse.Namespace) -> None:
    if not args.holder:
        print("ERROR: --holder required", file=sys.stderr)
        sys.exit(2)
    if not args.reason:
        print("ERROR: --reason required", file=sys.stderr)
        sys.exit(2)
    md = args.mutex_dir or default_mutex_dir()
    try:
        mutex.acquire(md, args.holder, args.reason, repo=args.repo, branch=args.branch)
        print("mutex=ACQUIRED")
        print(f"holder_id={args.holder}")
    except mutex.MutexHeldError as e:
        s = e.mutex_status
        print(f"mutex={s.state}")
        print("result=already_held")
        if s.holder_data:
            print(json.dumps(s.holder_data, indent=2))
        sys.exit(1)


def cmd_release(args: argparse.Namespace) -> None:
    md = args.mutex_dir or default_mutex_dir()
    result = mutex.release(md, holder_id=args.holder, force=args.force)
    if result.mismatch:
        print(f"mutex={result.state}")
        print("result=holder_mismatch")
        print(f"expected_holder={args.holder}")
        print(f"current_holder={result.current_holder}")
        print("hint=use --force to release anyway")
        sys.exit(1)
    print(f"mutex={result.state}")
    if not result.was_held:
        print("result=was_not_held")


def cmd_check_stale(args: argparse.Namespace) -> None:
    md = args.mutex_dir or default_mutex_dir()
    result = mutex.check_stale(
        md, stale_minutes=args.stale_minutes, auto_recover=args.auto_recover
    )
    print(f"mutex={result.state}")
    if result.is_broken:
        print("stale=BROKEN")
        if result.reason:
            print(f"reason={result.reason}")
        if result.recovered:
            print("recovered=BROKEN")
            print("result=removed_empty_mutex_dir")
            return
        sys.exit(1)
    if result.age_minutes is not None:
        print(f"age_minutes={result.age_minutes}")
    if result.is_stale is True:
        print("stale=YES")
        if result.reason:
            print(f"reason={result.reason}")
        sys.exit(1)
    elif result.is_stale is False:
        print("stale=NO")


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="python -m junie_runtime.cli.mutex",
        description="Junie Runtime Code Mutex CLI",
    )
    parser.add_argument(
        "action",
        nargs="?",
        choices=["status", "acquire", "release", "check-stale", "check_stale"],
    )
    parser.add_argument("--mutex-dir", default=None)
    parser.add_argument("--holder", default=None)
    parser.add_argument("--reason", default=None)
    parser.add_argument("--repo", default=None)
    parser.add_argument("--branch", default=None)
    parser.add_argument("--stale-minutes", type=int, default=30)
    parser.add_argument("--auto-recover", action="store_true", default=False)
    parser.add_argument("--force", action="store_true", default=False)

    args, _ = parser.parse_known_args()

    if not args.action:
        parser.print_help()
        sys.exit(0)

    action = args.action.replace("-", "_")

    if action == "status":
        cmd_status(args)
    elif action == "acquire":
        cmd_acquire(args)
    elif action == "release":
        cmd_release(args)
    elif action == "check_stale":
        cmd_check_stale(args)
    else:
        print(f"ERROR: unknown action: {args.action}", file=sys.stderr)
        parser.print_help()
        sys.exit(2)


if __name__ == "__main__":
    main()

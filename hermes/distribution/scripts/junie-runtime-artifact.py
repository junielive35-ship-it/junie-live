#!/usr/bin/env python3
"""
Helper CLI for Junie Runtime disaster-recovery artifact operations.

Subcommands:
  snapshot-profile         Copy profile dir to staging area with SQLite safe backup
  read-manifest-field      Print a single field from a JSON manifest
  write-install-manifest   Write install-time runtime manifest
  enrich-archive-manifest  Add wheel metadata to archive manifest
  write-restore-manifest   Write restore-time runtime manifest
  read-installed-python    Print installed_python from manifest (empty on error)
"""

import argparse
import datetime
import json
import os
import shutil
import sqlite3
import subprocess
import sys


def cmd_snapshot_profile(args: argparse.Namespace) -> None:
    src_root = args.profile_dir
    dst_root = args.archive_profile_dir

    ALWAYS_EXCLUDE = {"__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache"}
    TOP_LEVEL_EXCLUDE = {"cache", "logs", "backups"}
    EXCLUDE_FILE_SUFFIXES = {".pyc", ".pyo", ".pid", ".lock"}
    EXCLUDE_SIDECAR_SUFFIXES = {".db-wal", ".db-shm", ".db-journal"}

    for dirpath, dirnames, filenames in os.walk(src_root):
        rel_dir = os.path.relpath(dirpath, src_root)
        dirnames[:] = [
            d
            for d in dirnames
            if d not in ALWAYS_EXCLUDE
            and not (d in TOP_LEVEL_EXCLUDE and rel_dir == ".")
        ]

        for f in filenames:
            src = os.path.join(dirpath, f)
            rel = os.path.relpath(src, src_root)
            dst = os.path.join(dst_root, rel)

            if any(rel.endswith(suf) for suf in EXCLUDE_FILE_SUFFIXES):
                continue
            if any(rel.endswith(suf) for suf in EXCLUDE_SIDECAR_SUFFIXES):
                continue

            os.makedirs(os.path.dirname(dst), exist_ok=True)

            if f.endswith(".db"):
                try:
                    con = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
                    try:
                        backup_con = sqlite3.connect(str(dst))
                        try:
                            con.backup(backup_con)
                        finally:
                            backup_con.close()
                    finally:
                        con.close()
                except (sqlite3.Error, Exception):
                    shutil.copy2(src, dst)
            else:
                shutil.copy2(src, dst)


def cmd_read_manifest_field(args: argparse.Namespace) -> None:
    with open(args.manifest) as f:
        m = json.load(f)
    val = m.get(args.field, "")
    print(val)


def cmd_write_install_manifest(args: argparse.Namespace) -> None:
    manifest: dict = {}
    manifest["package"] = "junie-runtime"
    manifest["module"] = "junie_runtime"
    if args.runtime_dir:
        manifest["source_path"] = os.path.abspath(args.runtime_dir)
    else:
        manifest["source_path"] = ""
    manifest["runtime_path"] = "hermes/junie_runtime"
    if args.repo_root:
        repo_root = os.path.abspath(args.repo_root)
        manifest["repo_root"] = repo_root
        try:
            commit = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                capture_output=True, text=True, cwd=repo_root, timeout=5,
            )
            if commit.returncode == 0:
                manifest["git_commit"] = commit.stdout.strip()
            branch = subprocess.run(
                ["git", "rev-parse", "--abbrev-ref", "HEAD"],
                capture_output=True, text=True, cwd=repo_root, timeout=5,
            )
            if branch.returncode == 0:
                manifest["git_branch"] = branch.stdout.strip()
            subprocess.run(
                ["git", "diff", "--quiet"],
                capture_output=True, cwd=repo_root, timeout=5,
            )
            manifest["source_type"] = "git-working-tree"
        except Exception:
            manifest["source_type"] = "path"
    else:
        manifest["source_type"] = "path"
    try:
        import junie_runtime  # type: ignore[import-untyped]

        manifest["version"] = junie_runtime.__version__
    except ImportError:
        manifest["version"] = "unknown"
    manifest["installed_python"] = args.installed_python or sys.executable
    manifest["installed_at"] = datetime.datetime.utcnow().strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    out_path = os.path.join(args.manifest_dir, "junie_runtime.json")
    with open(out_path, "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"  Runtime manifest written: {out_path}")


def cmd_enrich_archive_manifest(args: argparse.Namespace) -> None:
    with open(args.input_manifest) as f:
        m = json.load(f)
    m["wheel_filename"] = args.wheel_filename
    m["wheel_sha256"] = args.wheel_sha256
    m["wheel_built_at"] = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(args.output_manifest, "w") as f:
        json.dump(m, f, indent=2)


def cmd_write_restore_manifest(args: argparse.Namespace) -> None:
    with open(args.archive_manifest) as f:
        m = json.load(f)
    m["restored_at"] = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    m["restored_from_archive"] = os.path.basename(args.archive)
    m["installed_python"] = args.installed_python
    out_path = os.path.join(args.output_dir, "junie_runtime.json")
    with open(out_path, "w") as f:
        json.dump(m, f, indent=2)


def cmd_read_installed_python(args: argparse.Namespace) -> None:
    try:
        with open(args.manifest) as f:
            m = json.load(f)
        val = m.get("installed_python", "")
        print(val, end="")
    except Exception:
        pass


_ZERO_HASH = "0000000000000000000000000000000000000000000000000000000000000000"


def _manifest_field_present(m: dict, field: str) -> bool:
    val = m.get(field)
    return bool(val) and val != _ZERO_HASH


def cmd_archive_manifest_summary(args: argparse.Namespace) -> None:
    import tarfile

    try:
        tf = tarfile.open(args.archive, "r:gz")
    except Exception as e:
        print(f"ERROR: cannot open archive: {e}")
        sys.exit(1)

    manifest_member = None
    for m in tf.getmembers():
        if "junie_runtime.json" in m.name and "runtime_artifact" in m.name:
            manifest_member = m
            break
    if manifest_member is None:
        print("ERROR: runtime manifest not found in archive")
        sys.exit(1)

    try:
        f = tf.extractfile(manifest_member)
        m = json.load(f)
    except Exception as e:
        print(f"ERROR: {e}")
        sys.exit(1)
    finally:
        tf.close()

    ok = True
    for field in args.fields:
        present = _manifest_field_present(m, field)
        print(f"{field}={chr(121) if present else chr(110)}")
        if not present:
            ok = False

    if not ok:
        sys.exit(1)


def cmd_manifest_has_fields(args: argparse.Namespace) -> None:
    try:
        with open(args.manifest) as f:
            m = json.load(f)
    except Exception as e:
        print(f"ERROR: {e}")
        sys.exit(1)

    ok = True
    for field in args.fields:
        present = _manifest_field_present(m, field)
        print(f"{field}={chr(121) if present else chr(110)}")
        if not present:
            ok = False

    if not ok:
        sys.exit(1)


def cmd_corrupt_manifest_hash(args: argparse.Namespace) -> None:
    try:
        with open(args.manifest) as f:
            m = json.load(f)
    except Exception as e:
        print(f"ERROR: {e}")
        sys.exit(1)

    m["wheel_sha256"] = _ZERO_HASH
    with open(args.manifest, "w") as f:
        json.dump(m, f, indent=2)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Junie Runtime artifact helper"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # snapshot-profile
    sp = sub.add_parser("snapshot-profile")
    sp.add_argument("profile_dir")
    sp.add_argument("archive_profile_dir")
    sp.set_defaults(func=cmd_snapshot_profile)

    # read-manifest-field
    rmf = sub.add_parser("read-manifest-field")
    rmf.add_argument("manifest")
    rmf.add_argument("field")
    rmf.set_defaults(func=cmd_read_manifest_field)

    # write-install-manifest
    wim = sub.add_parser("write-install-manifest")
    wim.add_argument("--runtime-dir", required=True)
    wim.add_argument("--repo-root", required=True)
    wim.add_argument("--manifest-dir", required=True)
    wim.add_argument("--installed-python", required=True)
    wim.set_defaults(func=cmd_write_install_manifest)

    # enrich-archive-manifest
    eam = sub.add_parser("enrich-archive-manifest")
    eam.add_argument("--input", dest="input_manifest", required=True)
    eam.add_argument("--output", dest="output_manifest", required=True)
    eam.add_argument("--wheel-filename", required=True)
    eam.add_argument("--wheel-sha256", required=True)
    eam.set_defaults(func=cmd_enrich_archive_manifest)

    # write-restore-manifest
    wrm = sub.add_parser("write-restore-manifest")
    wrm.add_argument("--archive-manifest", required=True)
    wrm.add_argument("--output-dir", required=True)
    wrm.add_argument("--archive", required=True)
    wrm.add_argument("--installed-python", required=True)
    wrm.set_defaults(func=cmd_write_restore_manifest)

    # read-installed-python
    rip = sub.add_parser("read-installed-python")
    rip.add_argument("manifest")
    rip.set_defaults(func=cmd_read_installed_python)

    # archive-manifest-summary
    ams = sub.add_parser("archive-manifest-summary")
    ams.add_argument("archive")
    ams.add_argument("fields", nargs="+")
    ams.set_defaults(func=cmd_archive_manifest_summary)

    # manifest-has-fields
    mhf = sub.add_parser("manifest-has-fields")
    mhf.add_argument("manifest")
    mhf.add_argument("fields", nargs="+")
    mhf.set_defaults(func=cmd_manifest_has_fields)

    # corrupt-manifest-hash
    cmh = sub.add_parser("corrupt-manifest-hash")
    cmh.add_argument("manifest")
    cmh.set_defaults(func=cmd_corrupt_manifest_hash)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()

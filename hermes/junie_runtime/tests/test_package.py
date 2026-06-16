import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path, PurePath

import pytest


def test_wheel_metadata_declares_pyyaml():
    pkg_root = Path(__file__).resolve().parent.parent

    with tempfile.TemporaryDirectory() as tmp:
        tmp_pkg = Path(tmp) / "pkg"
        shutil.copytree(pkg_root, tmp_pkg, ignore=_ignore_transient)

        result = subprocess.run(
            [sys.executable, "-m", "pip", "wheel", "--no-deps",
             str(tmp_pkg), "--wheel-dir", tmp],
            capture_output=True, text=True,
        )
        assert result.returncode == 0, (
            f"pip wheel failed (rc={result.returncode})\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )

        wheels = list(Path(tmp).glob("junie_runtime-*.whl"))
        assert len(wheels) >= 1, f"no wheel found in {tmp}"

        with zipfile.ZipFile(wheels[0]) as zf:
            names = zf.namelist()
            meta = next(n for n in names if n.endswith(".dist-info/METADATA"))
            metadata = zf.read(meta).decode()

        assert "Requires-Dist: PyYAML" in metadata, (
            "wheel metadata must declare PyYAML as a dependency"
        )


def _ignore_transient(d: str, contents: list[str]) -> list[str]:
    """Exclude transient build artifacts that would dirty the source tree."""
    ignored: list[str] = []
    for c in contents:
        if c in ("build", "__pycache__", ".pytest_cache"):
            ignored.append(c)
        elif c.endswith(".egg-info") or c.endswith(".pyc"):
            ignored.append(c)
    return ignored

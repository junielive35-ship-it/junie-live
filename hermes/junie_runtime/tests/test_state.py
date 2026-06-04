import os
import tempfile

from junie_runtime import state


def test_atomic_write_read_json() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "test.json")
        data = {"key": "value", "num": 42}
        state.atomic_write_json(path, data)
        result = state.read_json(path)
        assert result == data


def test_read_json_nonexistent() -> None:
    result = state.read_json("/nonexistent/path.json")
    assert result is None


def test_read_json_malformed() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "bad.json")
        with open(path, "w") as f:
            f.write("{invalid json}")
        result = state.read_json(path)
        assert result is None


def test_atomic_write_read_text() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "test.txt")
        text = "hello world"
        state.atomic_write_text(path, text)
        result = state.read_text(path)
        assert result == text


def test_read_text_nonexistent() -> None:
    result = state.read_text("/nonexistent/path.txt")
    assert result is None


def test_json_write_creates_parent_dir() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "nested", "subdir", "test.json")
        data = {"ok": True}
        state.atomic_write_json(path, data)
        assert os.path.isfile(path)
        assert state.read_json(path) == data


def test_text_write_creates_parent_dir() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "nested", "subdir", "test.txt")
        state.atomic_write_text(path, "content")
        assert os.path.isfile(path)
        assert state.read_text(path) == "content"


def test_multiple_writes() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "updates.json")
        state.atomic_write_json(path, {"v": 1})
        state.atomic_write_json(path, {"v": 2})
        result = state.read_json(path)
        assert result == {"v": 2}

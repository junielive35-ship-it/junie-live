import json
import os
from typing import Any


def append_event(path: str, event: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a") as f:
        f.write(json.dumps(event, default=str) + "\n")


def read_events(path: str) -> list[dict[str, Any]]:
    if not os.path.isfile(path):
        return []
    events: list[dict[str, Any]] = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line:
                    events.append(json.loads(line))
    except (json.JSONDecodeError, OSError):
        pass
    return events

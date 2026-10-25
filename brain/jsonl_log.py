"""Append-only JSONL logger for events, prompts, tool calls and results.

Every line is one JSON object with at least ``ts`` (unix seconds) and ``kind``,
so a session can be replayed or grepped later.
"""
from __future__ import annotations

import json
import threading
import time
from pathlib import Path
from typing import Any

from . import paths


class JsonlLogger:
    def __init__(self, path: Path | None = None):
        if path is None:
            path = paths.log_dir() / f"brain-{time.strftime('%Y%m%d')}.jsonl"
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()

    def log(self, kind: str, **fields: Any) -> None:
        record = {"ts": round(time.time(), 3), "kind": kind, **fields}
        line = json.dumps(record, default=str, ensure_ascii=False)
        with self._lock, self.path.open("a", encoding="utf-8") as f:
            f.write(line + "\n")

    def read_all(self) -> list[dict]:
        if not self.path.exists():
            return []
        with self.path.open(encoding="utf-8") as f:
            return [json.loads(line) for line in f if line.strip()]

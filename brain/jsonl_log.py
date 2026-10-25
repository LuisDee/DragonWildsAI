"""Append-only JSONL logger for events, prompts, tool calls and results.

Every line is one JSON object with at least ``ts`` (unix seconds) and ``kind``,
so a session can be replayed or grepped later.
"""
from __future__ import annotations

import itertools
import json
import os
import threading
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

from . import paths


class JsonlLogger:
    def __init__(self, path: Path | None = None):
        if path is None:
            path = paths.log_dir() / f"brain-{time.strftime('%Y%m%d')}.jsonl"
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        # The episode every row belongs to (observability: exact traces instead of timing guesses). Set
        # with ``episode()``; every component that shares this logger (bridge, controller, executor)
        # stamps it on its rows while the episode is open. Thread-local, so a worker thread's episode
        # (the Director's) never stamps the main loop's rows.
        self._episode = threading.local()  # per thread: the Director runs on a worker thread
        self._ids = itertools.count(1)
        self._ids_lock = threading.Lock()

    @property
    def episode_id(self) -> str | None:
        return getattr(self._episode, "id", None)

    @episode_id.setter
    def episode_id(self, value: str | None) -> None:
        self._episode.id = value

    def new_episode_id(self, prefix: str) -> str:
        with self._ids_lock:
            n = next(self._ids)
        return f"{prefix}-{n:04d}-{uuid.uuid4().hex[:4]}"

    @contextmanager
    def episode(self, episode_id: str | None) -> Iterator[str | None]:
        """Stamp ``episode_id`` on every row logged inside the block (nested blocks restore the outer id)."""
        outer, self.episode_id = self.episode_id, episode_id or self.episode_id
        try:
            yield self.episode_id
        finally:
            self.episode_id = outer

    @classmethod
    def session(cls, prefix: str = "brain-live", directory: Path | None = None) -> "JsonlLogger":
        """A fresh file per session: <log_dir>/<prefix>-YYYYMMDD-HHMMSS-<pid>.jsonl."""
        d = Path(directory) if directory else paths.log_dir()
        return cls(d / f"{prefix}-{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}.jsonl")

    def log(self, kind: str, **fields: Any) -> None:
        record = {"ts": round(time.time(), 3), "kind": kind, **fields}
        if self.episode_id and "episode_id" not in record:
            record["episode_id"] = self.episode_id
        line = json.dumps(record, default=str, ensure_ascii=False)
        with self._lock, self.path.open("a", encoding="utf-8") as f:
            f.write(line + "\n")

    def read_all(self) -> list[dict]:
        return read_jsonl(self.path) if self.path.exists() else []


def read_jsonl(path: Path) -> list[dict]:
    """Parse every non-blank line of a JSONL file."""
    with Path(path).open(encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]

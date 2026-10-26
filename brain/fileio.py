"""Shared small file helpers (one place for the Windows-safe write and the tolerant reads).

- ``atomic_write(path, text)``: unique temp file + os.replace, retrying a Windows PermissionError
  (a reader holding the file open: tools/board.py list, antivirus). Moved from board.py (review M2c).
- ``read_json(path, default)``: the parsed file, or ``default`` on a missing/unreadable/invalid file.
- ``append_jsonl(path, rec)``: one JSON line appended (creates the parent folder).
- ``read_new_lines(path, offset)``: complete lines added since ``offset`` -> (rows, new_offset, bad);
  a truncated file restarts at 0, a partial last line is left for the next call.
"""
from __future__ import annotations

import json
import os
import time
import uuid
from pathlib import Path
from typing import Any, Callable


def atomic_write(path: Path, text: str, tries: int = 5, sleep: Callable[[float], None] = time.sleep) -> None:
    path = Path(path)
    tmp = path.with_name(f"{path.name}.{os.getpid()}.{uuid.uuid4().hex[:6]}.tmp")
    tmp.write_text(text, encoding="utf-8")
    delay = 0.05
    for i in range(tries):
        try:
            os.replace(tmp, path)
            return
        except PermissionError:
            if i == tries - 1:
                tmp.unlink(missing_ok=True)
                raise
            sleep(delay)
            delay *= 2


def read_json(path: Path, default: Any = None) -> Any:
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def append_jsonl(path: Path, rec: dict) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False, default=str) + "\n")


def read_new_lines(path: Path, offset: int) -> tuple[list[dict], int, list[str]]:
    path = Path(path)
    try:
        size = path.stat().st_size
    except OSError:
        return [], offset, []
    if size < offset:
        offset = 0
    if size == offset:
        return [], offset, []
    with path.open("rb") as f:
        f.seek(offset)
        chunk = f.read(size - offset)
    end = chunk.rfind(b"\n")
    if end < 0:
        return [], offset, []
    rows, bad = [], []
    for raw in chunk[:end].split(b"\n"):
        text = raw.decode("utf-8", errors="replace").strip()
        if not text:
            continue
        try:
            msg = json.loads(text)
        except ValueError:
            bad.append(text)
            continue
        if isinstance(msg, dict):
            rows.append(msg)
        else:
            bad.append(text)
    return rows, offset + end + 1, bad

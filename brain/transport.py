"""Message transports for the brain <-> body bridge.

``Transport`` is deliberately tiny so a socket transport can replace the file
one later without touching ``BridgeClient``. The file transport implements the
JSONL fallback described in brain/BRIDGE_PROTOCOL.md: each side appends JSON
lines to its own outgoing file and tails the other side's file by byte offset.

Tailing is done in-process (seek/read from a saved offset, keep any partial
trailing line for the next read). The PyPI tail helpers (tailer, ponytail) are
either unmaintained or log-rotation oriented; none handle the partial-line case
we need any better than these ~30 lines.
"""
from __future__ import annotations

import json
import time
from abc import ABC, abstractmethod
from pathlib import Path

from . import paths

BRAIN_TO_BODY = "brain_to_body.jsonl"
BODY_TO_BRAIN = "body_to_brain.jsonl"


class Transport(ABC):
    @abstractmethod
    def send(self, msg: dict) -> None: ...

    @abstractmethod
    def receive(self, timeout: float = 0.0) -> list[dict]:
        """Return messages that arrive within ``timeout`` seconds (possibly none)."""

    def close(self) -> None:
        pass


class JsonlFileTransport(Transport):
    def __init__(self, send_path: Path, recv_path: Path, poll_interval: float = 0.02, from_start: bool = False):
        self.send_path = Path(send_path)
        self.recv_path = Path(recv_path)
        self.send_path.parent.mkdir(parents=True, exist_ok=True)
        self.poll_interval = poll_interval
        # Skip stale lines left over from a previous run unless asked otherwise.
        self._offset = 0 if from_start else self._size()
        self._partial = b""
        self.malformed: list[str] = []  # lines that were not a JSON object; callers may drain this

    def _size(self) -> int:
        try:
            return self.recv_path.stat().st_size
        except FileNotFoundError:
            return 0

    def send(self, msg: dict) -> None:
        line = json.dumps(msg, separators=(",", ":"), ensure_ascii=False) + "\n"
        # One write per line keeps appends from interleaving mid-line.
        with self.send_path.open("a", encoding="utf-8", newline="\n") as f:
            f.write(line)
            f.flush()

    def _read_new(self) -> list[dict]:
        size = self._size()
        if size < self._offset:  # file was truncated or rotated: start over
            self._offset, self._partial = 0, b""
        if size == self._offset:
            return []
        with self.recv_path.open("rb") as f:
            f.seek(self._offset)
            chunk = f.read(size - self._offset)
        self._offset += len(chunk)
        *lines, self._partial = (self._partial + chunk).split(b"\n")
        out = []
        for raw in lines:
            text = raw.decode("utf-8", errors="replace").strip()
            if not text:
                continue
            try:
                msg = json.loads(text)
            except json.JSONDecodeError:
                msg = None
            if isinstance(msg, dict):
                out.append(msg)
            else:
                self.malformed.append(text)
        return out

    def receive(self, timeout: float = 0.0) -> list[dict]:
        deadline = time.monotonic() + timeout
        while True:
            msgs = self._read_new()
            if msgs or time.monotonic() >= deadline:
                return msgs
            time.sleep(self.poll_interval)


def file_transport_pair(directory: Path | None = None) -> tuple[JsonlFileTransport, JsonlFileTransport]:
    """(brain_side, body_side) transports sharing one bridge directory."""
    d = Path(directory) if directory else paths.bridge_dir()
    body = JsonlFileTransport(d / BODY_TO_BRAIN, d / BRAIN_TO_BODY)
    brain = JsonlFileTransport(d / BRAIN_TO_BODY, d / BODY_TO_BRAIN)
    return brain, body


def brain_file_transport(directory: Path | None = None) -> JsonlFileTransport:
    d = Path(directory) if directory else paths.bridge_dir()
    return JsonlFileTransport(d / BRAIN_TO_BODY, d / BODY_TO_BRAIN)

"""Single voice (streamline plan step 3, R3): the one gate every spoken line passes through.

Live bug (2026-10-25 19:22-19:25): "can't find a way to you" right after arriving next to the
player, "really thirsty" three times in a second, the same complaint repeated reply after reply.

The pattern is adapted from game "bark" managers: one central gate; drop a line rather than
backlog it; validate against current state right before speaking. Sources: the bugnet.io and
pulsegeek.com bark write-ups, searched 2026-10-25. The work is split three ways:
- here: no near-duplicate of a line said within ``dup_window_s`` (difflib ratio >= 0.85); the
  history the Agent and broker consult;
- broker.py: whether a body report is still true at speak time (structured facts, no phrase
  matching);
- agent.py: a model reply whose facts changed while the model was thinking is decided again.
``system`` lines (pong) always go out.
"""
from __future__ import annotations

import difflib
import re
import time
from collections import deque
from dataclasses import dataclass
from typing import Callable

SIMILAR = 0.85


def _norm(text: str) -> str:
    return re.sub(r"[^a-z0-9 ]+", "", text.lower()).strip()


@dataclass
class Spoken:
    t: float
    text: str
    kind: str  # reply | notice | system


class Voice:
    def __init__(self, clock: Callable[[], float] = time.monotonic, dup_window_s: float = 30.0):
        self.clock = clock
        self.dup_window_s = dup_window_s
        self.history: deque[Spoken] = deque(maxlen=50)

    def gate(self, text: str, kind: str = "reply") -> str | None:
        """None if the line may be said now, else why not."""
        if kind == "system":
            return None
        now, n = self.clock(), _norm(text)
        for s in reversed(self.history):
            if now - s.t > self.dup_window_s:
                break
            if s.kind != "system" and difflib.SequenceMatcher(None, n, _norm(s.text)).ratio() >= SIMILAR:
                return f"near-duplicate of a line said {now - s.t:.0f}s ago"
        return None

    def record(self, text: str, kind: str = "reply") -> None:
        self.history.append(Spoken(self.clock(), text, kind))

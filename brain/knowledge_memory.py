"""What the Director has looked up or observed, and how fast its work goes (docs/design/director.md 2.10, 2.11).

KnowledgeMemory (per world, knowledge_memory.json): facts {key, value, source, confidence, ts, build, refuted?}.
  * Sources: game_data and perception are confidence "high" and win over the wiki ("medium"); a fact refuted
    in game (DECKARD's idea: wiki edges are hypotheses) stays, marked refuted, so it isn't trusted again.
  * ``recall(query)`` ranks facts by shared words (plurals folded): the cache the Director checks before a lookup.
  * ``matches_unknown(query, facts)`` tells whether a lookup answers a fact the plan listed as unknown (the
    benchmark scores needed vs needless lookups).
Efficiency (per world, efficiency.json + efficiency.jsonl): verified rates (per minute) per key, the best seen,
and the trend log of reflections {ts, task, step, key, rate, best, alternatives_offered, change}.
The agent loop writes; the Director's worker reads ``snapshot()`` copies only.
"""
from __future__ import annotations

import copy
import json
import time
from pathlib import Path
from typing import Any, Callable

from .board import _atomic_write
from .knowledge import _terms  # the index's stemmer (plurals folded consistently)
from .situation import tokens

HIGH = ("game_data", "perception", "memory")


class KnowledgeMemory:
    def __init__(self, directory: Path, build: str | None = None, clock: Callable[[], float] = time.time):
        self.path = Path(directory) / "knowledge_memory.json"
        self.build = build
        self.clock = clock
        self.facts: dict[str, dict] = self._load()

    def _load(self) -> dict[str, dict]:
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
            return {f["key"]: f for f in raw.get("facts", []) if isinstance(f, dict) and f.get("key")}
        except (OSError, ValueError):
            return {}

    def save(self) -> None:
        _atomic_write(self.path, json.dumps({"schema": "dw_knowledge_memory/1", "facts": list(self.facts.values())},
                                            indent=1, ensure_ascii=False))

    def put(self, key: str, value: Any, source: str, confidence: str | None = None, save: bool = True) -> dict:
        key = " ".join(str(key).split())[:200]
        conf = confidence or ("high" if source in HIGH else "medium")
        old = self.facts.get(key)
        if old and not old.get("refuted") and old.get("confidence") == "high" and conf != "high":
            return old  # game data / what he saw is not overwritten by the wiki
        rec = {"key": key, "value": value, "source": source, "confidence": conf, "ts": round(self.clock()),
               "build": self.build}
        self.facts[key] = rec
        if save:
            self.save()
        return rec

    def refute(self, key: str, why: str) -> dict | None:
        rec = self.facts.get(key)
        if rec is None:
            return None
        rec.update(refuted=True, refuted_why=why[:300], refuted_at=round(self.clock()))
        self.save()
        return rec

    def recall(self, query: str, limit: int = 5) -> list[dict]:
        return recall(self.facts, query, limit)

    def snapshot(self) -> dict[str, dict]:
        return copy.deepcopy(self.facts)


def recall(facts: dict[str, dict], query: str, limit: int = 5) -> list[dict]:
    """Facts ranked by shared words with the query (pure: safe on a snapshot)."""
    want = tokens(query)
    if not want:
        return []
    scored = []
    for f in facts.values():
        have = tokens(f["key"]) | tokens(json.dumps(f.get("value"), default=str))
        n = len(want & have)
        if n:
            scored.append((n, f.get("confidence") == "high" and not f.get("refuted"), f.get("ts") or 0, f))
    scored.sort(key=lambda x: (x[0], x[1], x[2]), reverse=True)
    return [s[3] for s in scored[:limit]]


def matches_unknown(query: str, plan_facts: list[dict]) -> bool:
    """Did this lookup ask about a fact the plan had listed as unknown? (2 shared words, or all of a short one)"""
    q = _terms(query)
    for f in plan_facts or []:
        if not isinstance(f, dict) or f.get("status") != "unknown":
            continue
        ft = _terms(f.get("fact"))
        shared = q & ft
        if ft and shared and (len(shared) >= 2 or len(shared) * 2 >= len(ft)):  # at least half its words
            return True
    return False


class Efficiency:
    def __init__(self, directory: Path, clock: Callable[[], float] = time.time):
        self.path = Path(directory) / "efficiency.json"
        self.trend = Path(directory) / "efficiency.jsonl"
        self.clock = clock
        try:
            self.best: dict[str, dict] = json.loads(self.path.read_text(encoding="utf-8")).get("best", {})
        except (OSError, ValueError):
            self.best = {}

    @staticmethod
    def rate(amount: float, seconds: float) -> float | None:
        return round(60.0 * amount / seconds, 3) if seconds > 0 and amount > 0 else (0.0 if seconds > 0 else None)

    def record(self, key: str, rate: float | None, where: Any = None) -> dict:
        """Record a verified rate for a key; returns {rate, best, ratio} (ratio = rate / best before this one)."""
        prev = self.best.get(key)
        best = prev["rate"] if prev else None
        if rate is not None and (best is None or rate > best):
            self.best[key] = {"rate": rate, "at": round(self.clock()), "where": where}
            _atomic_write(self.path, json.dumps({"schema": "dw_efficiency/1", "best": self.best}, indent=1))
        ratio = (rate / best) if rate is not None and best else None
        return {"rate": rate, "best": best, "ratio": ratio}

    def log_reflection(self, task: str, step: str, key: str, rate: float | None, best: float | None,
                       alternatives: list, change: str | None) -> None:
        with self.trend.open("a", encoding="utf-8") as f:
            f.write(json.dumps({"ts": round(self.clock(), 3), "task": task, "step": step, "key": key, "rate": rate,
                                "best": best, "alternatives_offered": alternatives, "change": change},
                               ensure_ascii=False, default=str) + "\n")

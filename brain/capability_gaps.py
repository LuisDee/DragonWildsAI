"""Capability-gap log: primitives (actions) and perception the plans needed but the body lacks.

docs/design/director.md section 2.7. One file for all worlds: logs/state/capability_gaps.json (the backlog that
decides the next primitives to build; ``tools/board.py gaps`` lists it by count).

Sources:
  tool_failure   a tool result not_implemented / unknown_tool (never unknown_skill: an invented skill name is
                 not a body gap, review M4)
  uncheckable    a predicate that evaluates null: the fields it needed (``missing``) are perception gaps
  seed           caps.missing and the manifest's llm=false tools at start-up, and gaps known from design
  director       the Director's own claim that a plan needs something, with the kind the MODEL gives it:
                 action | perception | knowledge. An action claim for a tool that exists is recorded as
                 ``tool_exists: true`` (a claim, not a gap; review M4). A knowledge gap (a fact it couldn't find)
                 is never a capability gap: ``backlog()`` leaves it out and it is never voiced as "I can't ... yet"
Records: {primitive, kind: action|perception, count, first_seen, last_seen, sources, tool_exists?,
          examples: [{task, step, why, workaround}] (newest 5)}
The agent loop is the only writer (atomic writes); readers (the CLI) only read.
"""
from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any, Callable, Iterable

from . import paths
from .board import _atomic_write
from .interface import Reason

AUTO_REASONS = frozenset({Reason.NOT_IMPLEMENTED, Reason.UNKNOWN_TOOL})  # not UNKNOWN_SKILL (review M4)
MAX_EXAMPLES = 5


def default_path() -> Path:
    return paths.state_dir() / "capability_gaps.json"


class GapLog:
    def __init__(self, path: Path | None = None, tools: Iterable[str] = (), log=None,
                 clock: Callable[[], float] = time.time):
        self.path = Path(path) if path else default_path()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.tools = set(tools)  # the body's tools (manifest names): what exists
        self.log = log
        self.clock = clock
        self.gaps: dict[str, dict] = self._load()
        self._told: set[tuple[str, str]] = set()  # (task id, primitive) already voiced

    def _load(self) -> dict[str, dict]:
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
            return {g["primitive"]: g for g in raw.get("gaps", []) if isinstance(g, dict) and g.get("primitive")}
        except (OSError, ValueError):
            return {}

    def save(self) -> None:
        rows = sorted(self.gaps.values(), key=lambda g: (-int(g.get("count") or 0), g["primitive"]))
        try:
            _atomic_write(self.path, json.dumps({"schema": "dw_capability_gaps/1", "gaps": rows}, indent=1,
                                                ensure_ascii=False))
        except OSError as exc:
            if self.log is not None:
                self.log.log("gaps_save_failed", error=repr(exc))

    def record(self, primitive: str, kind: str = "action", source: str = "director", task: str | None = None,
               step: str | None = None, why: str | None = None, workaround: str | None = None,
               save: bool = True) -> dict:
        """Count one occurrence. Returns the record; ``record["new_for_task"]`` says whether this task has not
        heard about it yet (voice it once)."""
        primitive = str(primitive).strip()
        now = self.clock()
        g = self.gaps.get(primitive)
        if g is None:
            g = self.gaps[primitive] = {"primitive": primitive, "kind": kind, "count": 0, "first_seen": now,
                                        "sources": [], "examples": []}
        g["kind"] = kind
        exists = source == "director" and kind == "action" and primitive in self.tools
        if exists:
            g["tool_exists"] = True  # a claim about a tool the body has (review M4): not counted
        else:
            g["count"] = int(g.get("count") or 0) + 1
        g["last_seen"] = now
        if source not in g["sources"]:
            g["sources"].append(source)
        if task or why or workaround:
            g["examples"] = (g["examples"] + [{"task": task, "step": step, "why": why, "workaround": workaround,
                                               "at": now}])[-MAX_EXAMPLES:]
        key = (task or "", primitive)
        out = {**g, "new_for_task": (not exists) and kind != "knowledge" and key not in self._told,
               "tool_exists": exists}
        if out["new_for_task"]:
            self._told.add(key)
        if save:
            self.save()
        return out

    def from_tool_result(self, tool: str, result: dict, task: str | None = None, step: str | None = None) -> dict | None:
        if result.get("ok") or result.get("reason") not in AUTO_REASONS:
            return None
        detail = (result.get("data") or {}).get("detail") if isinstance(result.get("data"), dict) else None
        return self.record(tool, "action", "tool_failure", task, step, why=detail or result.get("reason"))

    def from_uncheckable(self, missing: Iterable[str], task: str | None = None, step: str | None = None) -> list[dict]:
        # "baseline"/"clock"/"tallies" are board bookkeeping, not the body's perception
        return [self.record(f"perceive:{m}", "perception", "uncheckable", task, step, why=f"a success test needed {m}")
                for m in missing if m not in ("baseline", "clock", "tallies")]

    def seed(self, missing: dict[str, str] | None = None, debug_tools: Iterable[str] = (),
             known: Iterable[tuple[str, str, str]] = ()) -> None:
        """Start-up: tools the body lacks (caps.missing), tools it has only for debugging (llm=false), and gaps
        known from design (primitive, kind, why). Seeds never raise counts on restart."""
        for name, why in (missing or {}).items():
            self._seed(name, "action", why)
        for name in debug_tools:
            self._seed(name, "action", "the body has it only as a debug tool (llm=false: not verified from game state)")
        for name, kind, why in known:
            self._seed(name, kind, why)
        self.save()

    def _seed(self, primitive: str, kind: str, why: str) -> None:
        g = self.gaps.setdefault(primitive, {"primitive": primitive, "kind": kind, "count": 0,
                                             "first_seen": self.clock(), "sources": [], "examples": []})
        g.setdefault("last_seen", self.clock())
        if "seed" not in g["sources"]:
            g["sources"].append("seed")
            g["examples"] = (g["examples"] + [{"why": why, "at": self.clock()}])[-MAX_EXAMPLES:]

    def rows(self, kinds: Iterable[str] | None = None) -> list[dict[str, Any]]:
        """By count; ``kinds`` filters (the build backlog is action + perception; knowledge gaps are open facts,
        not missing primitives)."""
        rows = [g for g in self.gaps.values() if kinds is None or g.get("kind", "action") in set(kinds)]
        return sorted(rows, key=lambda g: (-int(g.get("count") or 0), g["primitive"]))

    def backlog(self) -> list[dict[str, Any]]:
        """What the body lacks: actions and perception, never knowledge, never claims about tools it has."""
        return [g for g in self.rows(("action", "perception")) if int(g.get("count") or 0) > 0
                or "seed" in (g.get("sources") or [])]

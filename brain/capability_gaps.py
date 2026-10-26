"""Capability-gap log: what plans needed and the BODY lacks, an action it can't do or something it can't perceive.

docs/design/director.md section 2.7. One file for all worlds: logs/state/capability_gaps.json (the backlog that
decides the next primitives to build; ``tools/board.py gaps`` lists it by count). Knowledge gaps (a fact the Director
couldn't find) are not body gaps: they live in brain/knowledge_memory.py, never here (simplify item 7).

Sources:
  tool_failure   a tool result not_implemented / unknown_tool (never unknown_skill: an invented skill name is
                 not a body gap, review M4)
  uncheckable    a predicate that evaluates null: the fields it needed (``missing``) are perception gaps
  seed           caps.missing and the manifest's llm=false tools at start-up
  director       the Director's claim that a plan needs a primitive, with the kind the MODEL gives it (action |
                 perception). An action claim for a tool the body has is recorded as ``tool_exists`` (a claim, not
                 a gap; review M4) and never counted.
Records: {primitive, kind: action|perception, count, first_seen, last_seen, sources, tool_exists?,
          examples: [{task, step, why, workaround}] (newest 5)}
``record`` only updates memory; callers ``save()`` once per batch. The agent loop is the only writer.
"""
from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any, Callable, Iterable

from . import paths
from . import predicates as P
from .fileio import atomic_write, read_json
from .interface import Reason

KINDS = ("action", "perception")
AUTO_REASONS = frozenset({Reason.NOT_IMPLEMENTED, Reason.UNKNOWN_TOOL})  # not UNKNOWN_SKILL (review M4)
MAX_EXAMPLES = 5
# board bookkeeping a predicate may miss (baseline, clock, tallies): not the body's perception
BOOKKEEPING = P.BOOKKEEPING_FIELDS


def default_path(state_dir: Path | None = None) -> Path:
    """logs/state/capability_gaps.json; for a world folder (<state>/worlds/<w>) the state root beside it."""
    if state_dir is not None:
        d = Path(state_dir)
        return (d.parent.parent if d.parent.name == "worlds" else d) / "capability_gaps.json"
    return paths.state_dir() / "capability_gaps.json"


class GapLog:
    def __init__(self, path: Path | None = None, tools: Iterable[str] = (), log=None,
                 clock: Callable[[], float] = time.time):
        self.path = Path(path) if path else default_path()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.tools = set(tools)  # the body's tools (manifest names): what exists
        self.log = log
        self.clock = clock
        raw = read_json(self.path, default={}) or {}
        self.gaps: dict[str, dict] = {g["primitive"]: g for g in raw.get("gaps", [])
                                      if isinstance(g, dict) and g.get("primitive") and g.get("kind", "action") in KINDS}
        self._told: set[tuple[str, str]] = set()  # (task, primitive) already voiced

    def save(self) -> None:
        try:
            atomic_write(self.path, json.dumps({"schema": "dw_capability_gaps/1", "gaps": self.rows()}, indent=1,
                                               ensure_ascii=False))
        except OSError as exc:
            if self.log is not None:
                self.log.log("gaps_save_failed", error=repr(exc))

    def _get_or_new(self, primitive: str, kind: str) -> dict:
        g = self.gaps.get(primitive)
        if g is None:
            g = self.gaps[primitive] = {"primitive": primitive, "kind": kind, "count": 0, "first_seen": self.clock(),
                                        "last_seen": self.clock(), "sources": [], "examples": []}
        g["kind"] = kind
        return g

    def record(self, primitive: str, kind: str = "action", source: str = "director", task: str | None = None,
               step: str | None = None, why: str | None = None, workaround: str | None = None) -> dict:
        """Count one occurrence (in memory; call save()). ``new_for_task`` says whether this task has not heard
        about it yet (voice it once)."""
        if kind not in KINDS:
            raise ValueError(f"a body gap is one of {KINDS}; knowledge gaps go to the knowledge memory")
        primitive = str(primitive).strip()
        g = self._get_or_new(primitive, kind)
        exists = source == "director" and kind == "action" and primitive in self.tools
        if exists:
            g["tool_exists"] = True  # a claim about a tool the body has (review M4): not counted
        else:
            g["count"] = int(g.get("count") or 0) + 1
        g["last_seen"] = self.clock()
        if source not in g["sources"]:
            g["sources"].append(source)
        if task or why or workaround:
            g["examples"] = (g["examples"] + [{"task": task, "step": step, "why": why, "workaround": workaround,
                                               "at": self.clock()}])[-MAX_EXAMPLES:]
        key = (task or "", primitive)
        new = (not exists) and key not in self._told
        if new:
            self._told.add(key)
        return {**g, "new_for_task": new, "tool_exists": exists}

    def from_tool_result(self, tool: str, result: dict, task: str | None = None, step: str | None = None) -> dict | None:
        if result.get("ok") or result.get("reason") not in AUTO_REASONS:
            return None
        detail = (result.get("data") or {}).get("detail") if isinstance(result.get("data"), dict) else None
        rec = self.record(tool, "action", "tool_failure", task, step, why=detail or result.get("reason"))
        self.save()
        return rec

    def from_uncheckable(self, missing: Iterable[str], task: str | None = None, step: str | None = None) -> list[dict]:
        out = [self.record(f"perceive:{m}", "perception", "uncheckable", task, step, why=f"a success test needed {m}")
               for m in missing if m not in BOOKKEEPING]
        if out:
            self.save()
        return out

    def seed(self, missing: dict[str, str] | None = None, debug_tools: Iterable[str] = ()) -> None:
        """Start-up: tools the body lacks (caps.missing) and tools it has only for debugging (llm=false). Seeds
        never raise counts on restart."""
        for name, why in (missing or {}).items():
            self._seed(name, why)
        for name in debug_tools:
            self._seed(name, "the body has it only as a debug tool (llm=false: not verified from game state)")
        self.save()

    def _seed(self, primitive: str, why: str) -> None:
        g = self._get_or_new(primitive, self.gaps.get(primitive, {}).get("kind", "action"))
        if "seed" not in g["sources"]:
            g["sources"].append("seed")
            g["examples"] = (g["examples"] + [{"why": why, "at": self.clock()}])[-MAX_EXAMPLES:]

    def rows(self) -> list[dict[str, Any]]:
        return sorted(self.gaps.values(), key=lambda g: (-int(g.get("count") or 0), g["primitive"]))

    def backlog(self) -> list[dict[str, Any]]:
        """What to build next: counted gaps and seeds, never mere claims about tools the body has."""
        return [g for g in self.rows() if int(g.get("count") or 0) > 0 or "seed" in (g.get("sources") or [])]

"""The harness-owned observer (design §4.1, review finding 1).

`ObservedGame` wraps any GameInterface (BenchWorld on the mock, the bridge client on dev/live) and records, around
every world-changing tool call, a probe snapshot before and after, with timestamps, plus the tool's reply. Leaves
judge on these probes (the ground truth the harness reads itself) and only cross-check the skill's reply; a
disagreement is a `sensor_mismatch`, never a pass.

Probes: on the mock `BenchWorld.probe()`; on dev/live `client_mod/commands/bench_probe.lua` through the DWClient
command runner (read-only). Referee events: on the mock `BenchWorld.referee`; on dev the server referee log
(mod/bench/referee.lua, read-only, dev server only).
"""
from __future__ import annotations

import time
from dataclasses import asdict, dataclass, field
from typing import Any, Callable

from brain.interface import Activity, GameInterface

READ_ONLY = frozenset({"get_state", "look", "inspect", "inventory", "lookup", "say", "remember", "spells", "list_rules",
                       "world_info", "run_skill"})
# World-changing tools that never count as "acting" for latency (review finding 17).
NOT_ACTIONS = frozenset({"stop", "say", "remember", "forget_skill"})


class Abort(RuntimeError):
    """A guard said stop (wrong server, a broken safety rule): the run ends at once."""


@dataclass
class Observation:
    seq: int
    tool: str
    args: dict
    t0: float
    t1: float
    wall0: float
    wall1: float
    before: dict
    after: dict
    reply: dict

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class Record:
    observations: list[Observation] = field(default_factory=list)
    referee: list[dict] = field(default_factory=list)
    episodes: list[dict] = field(default_factory=list)
    said: list[dict] = field(default_factory=list)  # {t, wall, text}
    reads: list[dict] = field(default_factory=list)  # read-only calls {t, wall, tool, args}
    probe0: dict | None = None
    probe1: dict | None = None


class ObservedGame(GameInterface):
    def __init__(self, inner: GameInterface, probe: Callable[[], dict], referee: Callable[[], list[dict]] | None = None,
                 clock: Callable[[], float] | None = None, guard: Callable[[str, dict], None] | None = None):
        self.inner = inner
        self._probe, self._referee = probe, referee or (lambda: [])
        self.clock = clock or time.time
        self.guard = guard
        self.rec = Record()
        self._seq = 0

    # ---------------------------------------------------------------- recording
    def start(self) -> dict:
        self.rec.probe0 = self._probe()
        self._drain_referee()
        return self.rec.probe0

    def finish(self) -> dict:
        self._drain_referee()
        self.rec.probe1 = self._probe()
        return self.rec.probe1

    def _drain_referee(self) -> None:
        self.rec.referee.extend(self._referee())

    def _observe(self, tool: str, args: dict, run: Callable[[], dict]) -> dict:
        if self.guard:
            self.guard(tool, args)  # may raise Abort
        before, t0, w0 = self._probe(), self.clock(), time.time()
        reply = run()
        after, t1, w1 = self._probe(), self.clock(), time.time()
        self._drain_referee()
        self._seq += 1
        self.rec.observations.append(Observation(self._seq, tool, dict(args), t0, t1, w0, w1, before, after,
                                                 dict(reply) if isinstance(reply, dict) else {"ok": False}))
        return reply

    # ---------------------------------------------------------------- GameInterface
    def call(self, tool: str, args: dict):
        if tool in READ_ONLY:
            self.rec.reads.append({"t": self.clock(), "wall": time.time(), "tool": tool, "args": dict(args)})
            return self.inner.call(tool, args)
        return self._observe(tool, args, lambda: self.inner.call(tool, args))

    def get_state(self):
        return self.inner.get_state()

    def say(self, text: str):
        self.rec.said.append({"t": self.clock(), "wall": time.time(), "text": text})
        return self.inner.say(text)

    def poll_events(self):
        events = self.inner.poll_events()
        for e in events:
            if isinstance(e, Activity):
                self.rec.episodes.append({"t": self.clock(), **e.model_dump()})
        return events

    def spells(self):
        return self.inner.spells()

    def list_rules(self, enemy=None):
        return self.inner.list_rules(enemy)

    def world_info(self):
        return self.inner.world_info()

    def set_progress_listener(self, listener) -> None:
        self.inner.set_progress_listener(listener)

    # typed tools all go through call() so they are observed
    def follow(self, player, distance=3.0):
        return self.call("follow", {"player": player, "distance": distance})

    def stop(self):
        return self.call("stop", {})

    def go_to(self, target):
        return self.call("go_to", {"target": target})

    def attack(self, target):
        return self.call("attack", {"target": target})

    def gather(self, resource, count, radius=None):
        return self.call("gather", {"resource": resource, "count": count, **({"radius": radius} if radius else {})})

    def craft(self, item, count=1):
        return self.call("craft", {"item": item, "count": count})

    def place(self, blueprint, location):
        return self.call("place", {"blueprint": blueprint, "location": location})

    def give(self, player, item, count):
        return self.call("give", {"player": player, "item": item, "count": count})

    def pickup(self, target, item=None, limit=1):
        return self.call("pickup", {"target": target, **({"item": item} if item else {}), "limit": limit})

    def drop(self, item, count, at="feet", player=None):
        return self.call("drop", {"item": item, "count": count, "at": at, **({"player": player} if player else {})})

    def cast(self, spell, target=None):
        return self.call("cast", {"spell": spell, **({"target": target} if target is not None else {})})

    def __getattr__(self, name: str) -> Any:  # anything else (manifest_tools, interrupt_check, ...) -> the body
        if name in ("inner", "rec", "_probe", "_referee", "clock", "guard", "_seq"):
            raise AttributeError(name)
        return getattr(self.inner, name)

    @property
    def manifest_tools(self):  # type: ignore[override]
        return getattr(self.inner, "manifest_tools", frozenset())


def evidence_ctx(rec: Record, baseline_state: dict, spells: dict, now: float, places: dict | None = None,
                 referee_supports: set[str] | None = None) -> dict:
    """The ctx dict leaves evaluate on (brain/predicates.evaluate passes it through)."""
    from brain.predicates import snapshot
    sup = referee_supports if referee_supports is not None else set()
    episodes = list(rec.episodes)
    if "death" in sup:  # kills come from the referee (harness-owned), never from the body's own combat_end claims
        deaths = [e for e in rec.referee if e.get("kind") == "death" and e.get("who") != "self"]
        episodes = [e for e in episodes if e.get("kind") != "combat_end"]
        if deaths and not any("by" in e for e in deaths):
            episodes = None  # the referee can't attribute kills yet: 'killed' is a perception gap, never a pass (C3)
        else:
            episodes += [{"kind": "combat_end", "outcome": "killed", "target": e.get("kind_id"), "target_id": e.get("who"),
                          "target_class": e.get("kind_id"), "by": "referee", "t": e.get("t")}
                         for e in deaths if e.get("by") == "self"]
    return {"baseline": snapshot(baseline_state, t=(rec.probe0 or {}).get("t", 0.0)) if baseline_state else None,
            "now": now, "places": places or {},
            "episodes": episodes, "results": [{"t": o.t1, "tool": o.tool, "args": o.args,
                                                          "ok": o.reply.get("ok"), "reason": o.reply.get("reason"),
                                                          "data": o.reply.get("data")} for o in rec.observations],
            "observations": rec.observations, "referee": list(rec.referee), "probe0": rec.probe0,
            "probe1": rec.probe1, "spells": spells, "mismatches": [],
            "referee_supports": sup}

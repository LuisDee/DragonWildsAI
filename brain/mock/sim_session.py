"""Long self-directed sessions on GearWorld in simulated time, measured like live (tools/obs_tasks.py: gaps between
subtasks split into thinking / waiting / dead, idle share, longest idle stretch; GOAL §2: Luis asked for these to
be logged and optimised).

One clock drives everything: game time (walking, gathering, crafting, crops growing) IS the rig clock, every model
request costs its measured live latency (``HAIKU_S`` per Controller call, ``SONNET_S`` per Director request: the
2026-10-26 dev smoke), the agent loop polls every ``POLL_S`` like run_live, and log rows carry that clock. So a
gap on the mock is the same arithmetic as a gap live, minus the body's real slowness.

Harness only (no brain logic): ``brynmoor_curriculum`` stands in for the model's open-job curriculum, reading
nothing but the prompt (structures, skills, quests) and choosing the next job from the GOAL long tasks.
"""
from __future__ import annotations

import json
import time as _time
from pathlib import Path

from .. import jsonl_log
from ..llm import FakeLLM, LLMResponse
from .gear_jobs import (ASH_LOGS, BREAD, COPPER, FLOUR, PLAYER, SPADE, STONE, WHEAT, WHEAT_SEED, BONE_PICK, JobRig,
                        call, st)
from .gear_world import GearWorld

HAIKU_S = 2.0  # one Controller model call (live smoke 2026-10-26: 1.6-2.8 s)
SONNET_S = 4.0  # one Director request (live: 9-14 s per decision of ~3 requests)
POLL_S = 0.25  # run_live's bridge poll
WAIT_GROW_S = 130.0
WAIT_STEPS = True  # the stand-in marks pure waits (the Director's "wait" step field)  # the stand-in's wait for a crop (GearWorld.grow_s = 120)


class SimWorld(GearWorld):
    """GearWorld whose game time is the rig clock (set ``clock`` right after construction)."""
    clock = None
    _t0 = 0.0

    @property
    def time(self):
        return (self.clock.t - self._t0) if self.clock is not None else self.__dict__.get("_time", 0.0)

    @time.setter
    def time(self, v):
        if self.clock is None:
            self.__dict__["_time"] = v
        else:
            self.clock.t += max(0.0, v - self.time)


class Latency:
    """An LLM client that costs ``seconds`` of rig time per request."""

    def __init__(self, inner, clock, seconds: float):
        self.inner, self.clock, self.seconds = inner, clock, seconds
        self.model = getattr(inner, "model", "fake")
        self.n = 0

    @property
    def calls(self):
        return self.inner.calls

    def complete(self, messages, tools=None):
        self.n += 1
        self.clock.t += self.seconds
        return self.inner.complete(messages, tools)


class RigTime:
    """Stands in for ``time`` inside brain/jsonl_log.py: rows carry the rig clock (strictly increasing)."""

    def __init__(self, clock):
        self.clock, self.last = clock, 0.0

    def time(self):
        self.last = max(self.last + 0.001, self.clock.t)
        return self.last

    def __getattr__(self, name):
        return getattr(_time, name)


def brynmoor_world(rig) -> None:
    """A fresh dev start in Brynmoor: tools, ash and stone around, copper further out, a chest and farm pieces he
    can build (harness data), wheat seeds and a spade."""
    g = rig.game
    g.carry(BONE_PICK)
    g.equip(BONE_PICK)
    g.carry(SPADE)
    g.carry(WHEAT_SEED, 2)
    for s in ("Mining", "Woodcutting", "Construction", "Farming", "Artisan", "Cooking"):
        g.set_skill(s, 1)
    g.add_resource(ASH_LOGS, [-6, 0, 0], 80, tool=None, skill="Woodcutting")
    g.add_resource(STONE, [-8, 4, 0], 80, tool=None, skill="Mining")
    g.add_resource(COPPER, [60, 0, 0], 200, tool="pickaxe", skill="Mining", xp=22)
    rig.store.remember_place("copper rocks", [58.0, 0.0, 0.0])
    g.add_buildable("Wooden Chest", {ASH_LOGS: 10}, kind="container")
    g.add_buildable("Farm Plot", {ASH_LOGS: 4}, kind="plot", crops={WHEAT_SEED: (WHEAT, 3)}, spade_tier=2)
    g.add_buildable("Grinder", {STONE: 4}, kind="station", station="Grinder")
    g.add_buildable("Kiln", {STONE: 6}, kind="station", station="Kiln")


def brynmoor_curriculum(seen: list):
    """The model stand-in for the open job: from the prompt only, the next GOAL long task he hasn't done yet."""
    def respond(messages, tools):
        user = json.loads(messages[1]["content"])
        seen.append(user.get("decision"))
        done = [h for h in user.get("steps_so_far") or [] if h.get("status") == "done"]
        titles = {h.get("title") for h in done}
        built = {r.get("name") for r in (user.get("me") or {}).get("structures") or []}
        if "store copper in the chest" not in titles:
            steps = [] if "Wooden Chest" in built else [
                st("chop ash for a chest", {"gained": {"item": ASH_LOGS, "at_least": 10}},
                   [call("gather", resource=ASH_LOGS, count=10)]),
                st("build a chest at home", {"structure": {"name": "Wooden Chest", "new": True}},
                   [call("build", piece="Wooden Chest")])]
            steps += [st("walk to the copper rocks", {"near": {"place": "copper rocks", "within_m": 8}},
                         [call("go_to", target="copper rocks")], group="trip"),
                     st("mine copper", {"gained": {"item": COPPER, "at_least": 20}},
                        [call("gather", resource=COPPER, count=20)], group="trip"),
                     st("store copper in the chest", {"stored": {"item": COPPER, "at_least": 20}},
                        [call("store", item=COPPER, container="Wooden Chest")], group="trip")]
            return LLMResponse(content=json.dumps({
                "description": "home first: a chest, then fill it with copper over trips", "steps": steps,
                "loops": {"trip": {"until": {"stored": {"item": COPPER, "at_least": 60}}}}}))
        if "bake bread" not in titles:
            steps = [st("chop ash for a plot", {"gained": {"item": ASH_LOGS, "at_least": 4}},
                        [call("gather", resource=ASH_LOGS, count=4)]),
                     st("build a farm plot", {"structure": {"name": "Farm Plot", "new": True}},
                        [call("build", piece="Farm Plot")]),
                     st("dig the weeds and plant wheat", {"lost": {"item": WHEAT_SEED, "at_least": 1}},
                        [call("farm_plots"), call("tend", item=SPADE, times=3), call("tend", item=WHEAT_SEED)]),
                     st("get stone for a grinder and a kiln", {"gained": {"item": STONE, "at_least": 10}},
                        [call("gather", resource=STONE, count=10)]),
                     st("build a grinder and a kiln", {"all": [{"structure": {"name": "Grinder", "new": True}},
                                                               {"structure": {"name": "Kiln", "new": True}}]},
                        [call("build", piece="Grinder"), call("build", piece="Kiln")]),
                     st("let the wheat grow", {"elapsed": {"seconds": WAIT_GROW_S}}, [], wait=WAIT_STEPS),
                     st("harvest the wheat", {"gained": {"item": WHEAT, "at_least": 3}}, [call("tend")]),
                     st("grind the wheat", {"have": {"item": FLOUR, "at_least": 3}},
                        [call("craft", item=FLOUR, count=3)]),
                     st("bake bread", {"have": {"item": BREAD, "at_least": 1}}, [call("craft", item=BREAD, count=1)])]
            steps = [x for x in steps if x["title"] not in titles]  # replans keep what is already done
            return LLMResponse(content=json.dumps({"description": "a farm at home, wheat to bread", "steps": steps}))
        return LLMResponse(content=json.dumps({"description": "base, mining run and bread done", "steps": [],
                                               "done": True}))
    return respond


def run_session(tmp: Path, max_s: float = 3 * 3600.0, director=None, world_cls=SimWorld, setup=brynmoor_world,
                line: str = "set yourself up here in Brynmoor and keep improving, I'll be back in a few hours"):
    """Run an open self-directed session until the job ends or ``max_s`` of rig time; returns (rig, rows)."""
    seen: list = []
    rig = JobRig(Path(tmp), [director or brynmoor_curriculum(seen)] * 60, open_tasks=True, world_cls=world_cls)
    rig.game.clock, rig.game._t0 = rig.clock, rig.clock.t
    rig.director.llm = Latency(rig.director.llm, rig.clock, SONNET_S)
    rig.controller.llm = Latency(rig.controller.llm, rig.clock, HAIKU_S)
    real = jsonl_log.time
    jsonl_log.time = RigTime(rig.clock)
    try:
        setup(rig)
        rig.say(line)
        start = rig.clock.t
        while rig.clock.t - start < max_s:
            rig.steps(1, dt=POLL_S)
            t = rig.director.ops.b.tasks[0] if rig.director.ops.b.tasks else None
            if t is not None and t.status in ("done", "stuck", "cancelled", "waiting_help", "parked"):
                break
    finally:
        jsonl_log.time = real
    rig.seen = seen
    return rig, rig.log_rows()

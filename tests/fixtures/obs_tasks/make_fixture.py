"""Rebuild the long-task fixtures (tests/test_obs.py, "long tasks") from the Director's GearWorld job scenarios.

    .venv\\Scripts\\python.exe tests\\fixtures\\obs_tasks\\make_fixture.py

Each scenario runs the REAL Agent/Controller/executor/Director on the mock (scripted models, no API calls), exactly as
tests/test_director_jobs.py does. Log timestamps follow the rig's clock: the JsonlLogger's time source is replaced by
"max(previous row + 0.2 s, rig clock)" (offset to 2026-10-26 10:00 UTC), so each agent tick is 30 s like the live loop
cadence and rows inside a tick are 0.2 s apart. Writes <scenario>__brain.jsonl and <scenario>__goals.json here.
"""
from __future__ import annotations

import sys
import tempfile
import time as _time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "tests"))

import brain.jsonl_log as jl  # noqa: E402
from brain.mock import gear_jobs as GJ  # noqa: E402
from brain.mock.gear_jobs import IRON_PICK, COAL, JobRig, call, pickaxe_world, plan, st  # noqa: E402
from test_director_jobs import PICKAXE_PLAN  # noqa: E402

BASE = datetime(2026, 10, 26, 10, 0, tzinfo=timezone.utc).timestamp()


class RigTime:
    """Stands in for the ``time`` module inside brain/jsonl_log.py."""

    def __init__(self, clock):
        self.clock, self.last = clock, 0.0

    def time(self):
        self.last = max(self.last + 0.2, BASE + (self.clock.t - 50_000.0))
        return self.last

    def __getattr__(self, name):
        return getattr(_time, name)


def run(name: str, script, setup, say: str, ticks: int, interrupt: tuple[int, str] | None = None) -> None:
    tmp = Path(tempfile.mkdtemp())
    rig = JobRig(tmp, script)
    real = jl.time
    jl.time = RigTime(rig.clock)
    try:
        setup(rig)
        rig.say(say)
        if interrupt:
            rig.steps(interrupt[0])
            rig.say(interrupt[1])
            rig.steps(ticks - interrupt[0])
        else:
            rig.steps(ticks)
    finally:
        jl.time = real
    (HERE / f"{name}__brain.jsonl").write_text(rig.log.path.read_text(encoding="utf-8"), encoding="utf-8")
    (HERE / f"{name}__goals.json").write_text((Path(rig.store.dir) / "goals.json").read_text(encoding="utf-8"), encoding="utf-8")
    t = rig.task()
    print(f"{name}: task {t.status}, {len(t.steps)} steps, {len(rig.log_rows())} rows")


def coal_setup(rig):
    rig.store.remember_place("coal spot", [80.0, 0.0, 0.0])
    rig.store.remember_place("base", [0.0, 0.0, 0.0])
    rig.game.carry(IRON_PICK)
    rig.game.add_resource(COAL, [82, 2, 0], 200, tool="pickaxe", skill="Mining", xp=10)


COAL_UNTIL = {"tally": {"item": "Coal", "at_least": 30}}
COAL_PLAN = [plan(
    task_success=COAL_UNTIL,
    steps=[st("walk to the coal spot", {"near": {"place": "coal spot", "within_m": 8}}, [call("go_to", target="coal spot")], group="trip"),
           st("mine coal", {"any": [{"gained": {"item": "Coal", "at_least": 12}}, {"bag": {"used_pct_at_least": 95}}]},
              [call("gather", resource="coal", count=12)], group="trip"),
           st("walk home", {"near": {"place": "base", "within_m": 8}}, [call("go_to", target="base")], group="trip"),
           st("leave it at the base", {"lost": {"item": "Coal", "at_least": 12}}, [call("drop", item="Coal", count=12)], group="trip")],
    loops={"trip": {"until": COAL_UNTIL}})]


if __name__ == "__main__":
    assert GJ  # the scenarios' helpers come from brain/mock/gear_jobs.py
    run("pickaxe", PICKAXE_PLAN, pickaxe_world, "can you make yourself a better pickaxe", 10)
    run("pickaxe_chat", PICKAXE_PLAN, pickaxe_world, "can you make yourself a better pickaxe", 12,
        interrupt=(3, "claude, what are you up to?"))
    run("coal_trips", COAL_PLAN, coal_setup, "get me a load of coal", 25)

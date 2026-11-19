"""DW_ASYNC_PLAN=1 with DW_JOB_TREE=1: both at once. The job tree is built on the agent loop's thread only (the Keeper
has no lock) and goes to the background Planner as text inside a deep copy of its notes; the Controller's turn while
the plan is made is shown the tree, as a run on the ask is. Live 2026-11-19: every job-tree trial opened with a
19-21 s stand while Sonnet planned (the plan-pending turn is that time).
"""
from __future__ import annotations

import json
import threading

import pytest
from conftest import Rig

from brain import job_tree as jt
from brain import plan_async
from brain.llm import FakeLLM, LLMResponse
from test_job_tree import LINE, data

PLAN = [{"skill": "go_to", "args": {"target": "Luis"}}]
FAILS = [{"skill": "give", "args": {"player": "Luis", "item": "Copper Ore", "count": 30}}]


class SlowPlanner:
    """A Planner reply that waits for ``gate`` and records the thread it ran on."""

    def __init__(self, tasks: list[dict]):
        self.tasks, self.thread = tasks, None
        self.started, self.gate = threading.Event(), threading.Event()

    def __call__(self, messages, tools):
        self.thread = threading.get_ident()
        self.started.set()
        assert self.gate.wait(10), "the test never opened the planner's gate"
        return FakeLLM.plan(self.tasks)


@pytest.fixture
def both_on(monkeypatch):
    monkeypatch.setenv(plan_async.ENV, "1")
    monkeypatch.setenv("DW_JOB_TREE", "1")
    monkeypatch.setattr(jt.GameData, "default", classmethod(lambda cls, knowledge=None, places=None: data()))
    calls: list[tuple[str, int]] = []  # (Keeper method, thread) for every tree build and failure record
    for name in ("tree", "record"):
        orig = getattr(jt.Keeper, name)

        def spy(self, *a, _orig=orig, _name=name, **kw):
            calls.append((_name, threading.get_ident()))
            return _orig(self, *a, **kw)
        monkeypatch.setattr(jt.Keeper, name, spy)
    return calls


def _rows(rig, kind):
    return [r for r in rig.log.read_all() if r["kind"] == kind]


def _ask(rig, goal="mine thirty copper ore and put it in the chest"):
    rig.game.player_say(LINE)
    rig.controller_llm.push(FakeLLM.say("On it.", FakeLLM.call("start_goal", goal=goal)))


def _planner_notes_text(call: dict) -> str:
    return "\n".join(m["content"] for m in call["messages"] if isinstance(m.get("content"), str))


def test_the_pending_turn_is_shown_the_tree_and_the_worker_never_touches_the_keeper(tmp_path, both_on):
    rig = Rig(tmp_path)
    assert rig.agent.async_plan and rig.agent.jobs is not None
    loop = threading.get_ident()
    slow = SlowPlanner(PLAN)
    rig.planner_llm.push(slow)
    _ask(rig)
    seen = {}

    def while_planning(messages, tools):
        assert slow.started.wait(5)
        seen["pending"] = not slow.gate.is_set()
        seen["ctx"] = json.loads(messages[1]["content"])
        return FakeLLM.say("", FakeLLM.call("go_to", target="Luis"))

    def then_stop(messages, tools):
        slow.gate.set()
        return LLMResponse(content="")

    rig.controller_llm.push(while_planning, then_stop, *[LLMResponse(content="")] * 4)
    rig.agent.step()
    assert seen["pending"] is True
    ctx = seen["ctx"]
    assert ctx["body_event"]["type"] == "plan_pending"
    o = ctx["open_request"]  # the tree, on the turn while the plan is made
    assert o["words"] == LINE and o["job_tree"]["target"][0].startswith("Copper Ore: you carry 0 of 30")
    # the plan's notes carry the tree as text, built on the loop before submit
    assert slow.thread is not None and slow.thread != loop  # the Planner really ran on the worker
    prompt = _planner_notes_text(rig.planner_llm.calls[0])
    assert "job_tree" in prompt and "Copper Ore" in prompt
    shown = {r["where"] for r in _rows(rig, "job_tree_shown")}
    assert {"turn", "plan"} <= shown
    assert both_on and all(t == loop for _, t in both_on)  # every Keeper build and record on the loop's thread
    assert not [r for r in _rows(rig, "job_tree_error") if r.get("where") == "off_thread"]
    (acted,) = _rows(rig, "acted_while_planning")  # the unseen signature: he acted while the plan was pending
    assert acted["n"] == 1 and acted["tools"] == ["go_to"]


def test_a_replan_in_the_background_gets_the_tree_from_the_loop(tmp_path, both_on):
    rig = Rig(tmp_path, max_attempts=1)
    loop = threading.get_ident()
    first, second = SlowPlanner(FAILS), SlowPlanner(PLAN)
    first.gate.set()
    rig.planner_llm.push(first, second)
    _ask(rig)

    def pending(messages, tools):
        return LLMResponse(content="")

    def replanning(messages, tools):
        ctx = json.loads(messages[1]["content"])
        if ctx.get("body_event", {}).get("type") == "plan_pending" and ctx["body_event"].get("failed_step"):
            assert second.started.wait(5)
            assert ctx["open_request"]["job_tree"]["target"][0].startswith("Copper Ore")
            seen["replan_turn"] = True
        second.gate.set()
        return LLMResponse(content="")

    seen = {}
    rig.controller_llm.push(pending, replanning, *[LLMResponse(content="")] * 4)
    rig.agent.step()
    assert seen.get("replan_turn") is True
    assert second.thread is not None and second.thread != loop
    assert "job_tree" in _planner_notes_text(rig.planner_llm.calls[1])
    assert "replan" in {r["where"] for r in _rows(rig, "job_tree_shown")}
    assert all(t == loop for _, t in both_on)
    kinds = [r["plan_kind"] for r in _rows(rig, "plan_started")]
    assert kinds == ["plan", "replan"]


def test_a_keeper_call_from_another_thread_is_refused_and_says_so():
    rows = []

    class Log:
        def log(self, kind, **kw):
            rows.append({"kind": kind, **kw})

    k = jt.Keeper(data, log=Log(), wall=lambda: 1000.0)
    k.open(("Luis", LINE))
    assert k.full_view({}) and k.targets  # on its own thread: built
    before = (dict(k.failures), k.last)
    out = {}

    def worker():
        out["full"] = k.full_view({})
        out["compact"] = k.compact_view({})
        out["record"] = k.record("craft", {"item": "Copper Ore"}, False, "missing_materials", None)
        out["open"] = k.open(("Luis", "something else"))
        out["attach"] = k.attach(".", ("Luis", LINE))

    t = threading.Thread(target=worker, name="plan-worker")
    t.start()
    t.join(5)
    assert out == {"full": None, "compact": None, "record": [], "open": [], "attach": False}
    assert (dict(k.failures), k.last) == before and k.ask == ("Luis", LINE) and k.dir is None  # untouched
    refused = [r for r in rows if r["kind"] == "job_tree_error" and r["where"] == "off_thread"]
    assert [r["method"] for r in refused] == ["full_view", "compact_view", "record", "open", "attach"]
    assert "plan-worker" in refused[0]["error"]
    k.owner = None  # a tool run outside the agent: any thread
    t = threading.Thread(target=lambda: out.update(full=k.full_view({})))
    t.start()
    t.join(5)
    assert out["full"]

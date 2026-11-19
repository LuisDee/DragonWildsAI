"""DW_ASYNC_PLAN=1 (brain/plan_async.py, agent._plan_in_background): the Planner call runs in the background and the
Controller keeps his turns. A fake slow Planner (a FakeLLM item that blocks on a gate) shows: his turns run while
the plan is pending and are told so; the plan is shown when it lands; a stale plan is marked and not started; a job
replaced meanwhile drops its plan; with the flag off nothing of this happens (the plan is made in line, as before).
"""
from __future__ import annotations

import json
import threading

from conftest import Rig

from brain import plan_async
from brain.llm import FakeLLM, LLMResponse
from brain.state_store import Task

PLAN = [{"skill": "gather", "args": {"resource": "log", "count": 2}},
        {"skill": "go_to", "args": {"target": "Luis"}},
        {"skill": "give", "args": {"player": "Luis", "item": "log", "count": 2}}]


class SlowPlanner:
    """A Planner reply that waits for ``gate`` (the test opens it) and records that it was in flight."""

    def __init__(self, tasks: list[dict]):
        self.tasks = tasks
        self.started = threading.Event()
        self.gate = threading.Event()

    def __call__(self, messages, tools):
        self.started.set()
        assert self.gate.wait(10), "the test never opened the planner's gate"
        return FakeLLM.plan(self.tasks)


def _context(call: dict) -> dict:
    return json.loads(call["messages"][1]["content"])


def _rows(rig, kind: str) -> list[dict]:
    return [r for r in rig.log.read_all() if r["kind"] == kind]


def _rig(tmp_path, monkeypatch, on: bool = True) -> Rig:
    monkeypatch.setenv(plan_async.ENV, "1" if on else "0")
    rig = Rig(tmp_path)
    assert rig.agent.async_plan is on  # read from the env at start
    return rig


def _ask(rig):
    rig.game.player_say("get me 2 logs")
    rig.controller_llm.push(FakeLLM.say("On it.", FakeLLM.call("start_goal", goal="gather 2 logs and give them to Luis")))


def test_controller_acts_while_a_slow_plan_is_pending_then_the_plan_runs(tmp_path, monkeypatch):
    rig = _rig(tmp_path, monkeypatch)
    slow = SlowPlanner(PLAN)
    rig.planner_llm.push(slow)
    _ask(rig)
    seen = {}

    def while_planning(messages, tools):
        assert slow.started.wait(5)
        seen["pending"] = not slow.gate.is_set()  # this turn runs while the Planner call is still in flight
        return FakeLLM.say("", FakeLLM.call("go_to", target="Luis"))

    def then_stop(messages, tools):
        slow.gate.set()  # the plan may land now
        return LLMResponse(content="")

    rig.controller_llm.push(while_planning, then_stop)
    assert rig.agent.step() == "done"
    assert seen["pending"] is True
    ctx = _context(rig.controller_llm.calls[1])
    assert ctx["body_event"]["type"] == "plan_pending" and ctx["body_event"]["request"] == "get me 2 logs"
    assert ctx["planner"]["state"] == "making the plan"  # the fact, in his context
    assert rig.game.players["Luis"].inventory["log"] == 2  # the plan ran after it landed
    (started,) = _rows(rig, "plan_started")
    (acted,) = _rows(rig, "acted_while_planning")
    (arrived,) = _rows(rig, "plan_arrived")
    assert started["plan_kind"] == "plan" and started["basis"]["position"] is not None
    assert acted["n"] == 1 and acted["tools"] == ["go_to"]
    assert arrived["stale"] is False and arrived["applied"] is True and arrived["steps"] == 3
    assert arrived["age_s"] >= 0 and arrived["drift"].get("moved_m", 0) > 0
    # the go_to was sent before the plan landed, and the planner's rows carry the ask's episode id
    go = next(r for r in rig.log.read_all() if r["kind"] == "tool_call" and r.get("tool") == "go_to")
    assert go["ts"] <= arrived["ts"]
    planner_prompt = next(r for r in rig.log.read_all() if r["kind"] == "prompt" and r.get("component") == "planner")
    assert planner_prompt.get("episode_id") == started.get("episode_id") is not None


def test_a_pending_turn_with_no_call_and_an_idle_body_gets_another_turn_that_acts(tmp_path, monkeypatch):
    """Live 2026-11-19 (run 20261119-013245-L2-V1): every plan_pending turn ended with no call ("I'm letting the
    planner finish the copper job") and nothing else gave him a turn while the plan was made: the body stood 18-26 s
    each time, acted_while_planning n=0. With the plan still pending and the body idle, he gets another turn."""
    from brain import agent as agent_mod
    monkeypatch.setattr(agent_mod, "PLAN_IDLE_TURN_S", 0.2, raising=False)
    rig = _rig(tmp_path, monkeypatch)
    slow = SlowPlanner(PLAN)
    rig.planner_llm.push(slow)
    _ask(rig)
    seen = {}

    def waits(messages, tools):
        assert slow.started.wait(5)
        return LLMResponse(content="I'm letting the planner finish the job.")  # the live shape: no call

    def idle_turn(messages, tools):
        seen["pending"] = not slow.gate.is_set()
        seen["event"] = json.loads(messages[1]["content"]).get("body_event") or {}
        return FakeLLM.say("", FakeLLM.call("go_to", target="Luis"))

    def then_stop(messages, tools):
        slow.gate.set()
        return LLMResponse(content="")

    rig.controller_llm.push(waits, idle_turn, then_stop)
    guard = threading.Timer(3.0, slow.gate.set)  # without the idle turn the plan lands on its own, and the test fails
    guard.start()
    try:
        assert rig.agent.step() == "done"
    finally:
        guard.cancel()
        slow.gate.set()
    assert seen["pending"] is True  # the second turn ran while the Planner call was still in flight
    assert seen["event"]["type"] == "plan_pending" and seen["event"]["idle_s"] >= 0.2
    (idle,) = _rows(rig, "plan_idle_turn")
    assert idle["quiet"] == 1 and idle["plan_kind"] == "plan"
    (acted,) = _rows(rig, "acted_while_planning")
    assert acted["n"] == 1 and acted["tools"] == ["go_to"] and acted["idle_turns"] == 1
    assert rig.game.players["Luis"].inventory["log"] == 2  # the plan still ran after it landed


def test_idle_turns_while_planning_stop_after_three_quiet_replies(tmp_path, monkeypatch):
    """Mindcraft's self-prompter rule: three replies in a row with no command and he is not asked again."""
    from brain import agent as agent_mod
    monkeypatch.setattr(agent_mod, "PLAN_IDLE_TURN_S", 0.05, raising=False)
    rig = _rig(tmp_path, monkeypatch)
    slow = SlowPlanner(PLAN)
    rig.planner_llm.push(slow)
    _ask(rig)
    quiet = lambda messages, tools: LLMResponse(content="waiting")  # noqa: E731
    rig.controller_llm.push(quiet, quiet, quiet)
    guard = threading.Timer(1.0, slow.gate.set)
    guard.start()
    try:
        assert rig.agent.step() == "done"
    finally:
        guard.cancel()
        slow.gate.set()
    assert len(_rows(rig, "plan_idle_turn")) == 2  # the pending turn and two more, then none
    (acted,) = _rows(rig, "acted_while_planning")
    assert acted["n"] == 0 and acted["idle_turns"] == 2


def test_a_plan_that_lands_mid_chain_is_shown_on_his_next_turn(tmp_path, monkeypatch):
    rig = _rig(tmp_path, monkeypatch)
    slow = SlowPlanner(PLAN)
    rig.planner_llm.push(slow)
    _ask(rig)

    def act_and_let_it_land(messages, tools):
        assert slow.started.wait(5)
        slow.gate.set()
        rig.agent._planning.future.result(timeout=5)  # landed before his next turn is built
        return FakeLLM.say("", FakeLLM.call("go_to", target="Luis"))

    rig.controller_llm.push(act_and_let_it_land, LLMResponse(content=""))
    assert rig.agent.step() == "done"
    told = rig.controller_llm.calls[2]["messages"]
    obs = next(m["content"] for m in reversed(told) if m["role"] == "user" and "Current observation" in m["content"])
    assert "plan for 'gather 2 logs and give them to Luis' has arrived (3 steps: gather(" in obs
    (arrived,) = _rows(rig, "plan_arrived")
    assert arrived["shown"] == "fresh" and arrived["applied"] is True


def test_a_stale_plan_is_marked_and_not_started(tmp_path, monkeypatch):
    rig = _rig(tmp_path, monkeypatch)
    slow = SlowPlanner(PLAN)
    rig.planner_llm.push(slow)
    _ask(rig)

    def gather_himself(messages, tools):
        assert slow.started.wait(5)
        return FakeLLM.say("", FakeLLM.call("gather", resource="log", count=2))

    def stop(messages, tools):
        slow.gate.set()
        return LLMResponse(content="")

    shown = {}

    def hears_it(messages, tools):
        shown["event"] = json.loads(messages[1]["content"])["body_event"]
        return LLMResponse(content="")

    rig.controller_llm.push(gather_himself, stop, hears_it)
    assert rig.agent.step() == "interrupted"
    assert len(rig.calls("gather")) == 1  # his own; the plan's first step was not run again
    (arrived,) = _rows(rig, "plan_arrived")
    assert arrived["stale"] is True and arrived["applied"] is False
    assert "first step (gather 2 log) is done" in arrived["why"][0]
    ev = shown["event"]
    assert ev["type"] == "plan_arrived" and ev["stale"] is True and ev["steps"][0].startswith("gather(")
    assert ev["since_it_was_asked_for"]["bag"] == {"log": 2.0}


def test_a_job_replaced_while_it_is_planned_drops_the_plan(tmp_path, monkeypatch):
    rig = _rig(tmp_path, monkeypatch)
    slow = SlowPlanner(PLAN)
    rig.planner_llm.push(slow)
    _ask(rig)

    def new_job(messages, tools):
        assert slow.started.wait(5)
        return FakeLLM.say("", FakeLLM.call("start_goal", goal="go to the lake"))

    rig.controller_llm.push(new_job, LLMResponse(content=""))
    try:
        assert rig.agent.step() == "interrupted"
        assert rig.agent.pending_goal == "go to the lake"  # his choice starts on the next step
        (ab,) = _rows(rig, "plan_abandoned")
        assert ab["why"] == "the job was replaced"
        assert not _rows(rig, "plan_arrived")
    finally:
        slow.gate.set()


def test_flag_off_plans_in_line_exactly_as_before(tmp_path, monkeypatch):
    rig = _rig(tmp_path, monkeypatch, on=False)
    rig.planner_llm.push(FakeLLM.plan(PLAN))
    _ask(rig)
    assert rig.agent.step() == "done"
    assert rig.game.players["Luis"].inventory["log"] == 2
    kinds = {r["kind"] for r in rig.log.read_all()}
    assert not kinds & {"plan_started", "plan_arrived", "plan_abandoned", "acted_while_planning"}
    # no turn while planning: the first Controller call after the ask is the goal's end, with no planner fact
    for call in rig.controller_llm.calls:
        ctx = json.loads(call["messages"][1]["content"])
        assert "planner" not in ctx and (ctx.get("body_event") or {}).get("type") != "plan_pending"


def test_stale_reasons_count_only_death_and_a_first_step_already_done():
    basis = {"position": [0, 0, 0], "inventory": {"log": 1}, "dead": False}
    moved = {"position": [50, 0, 0], "inventory": {"log": 1, "stone": 3}, "fight": True}
    tasks = [Task(skill="go_to", args={"target": [100, 0, 0]})]
    assert plan_async.stale_reasons(basis, moved, tasks) == []  # moving, a bag change and a fight are drift
    assert plan_async.drift(basis, moved) == {"moved_m": 50.0, "bag": {"stone": 3.0}, "fight": True}
    assert plan_async.stale_reasons(basis, moved, tasks, died=True) == ["you died after it was asked for"]
    there = {"position": [99, 1, 0], "inventory": {"log": 1}}
    assert "go_to" in plan_async.stale_reasons(basis, there, tasks)[0]
    # already there when the plan was asked for: the plan was made on that, so it is not behind the game
    assert plan_async.stale_reasons(there, there, tasks) == []
    gathered = {"position": [0, 0, 0], "inventory": {"Logs": 4}}
    assert plan_async.stale_reasons(basis, gathered, [Task(skill="gather", args={"resource": "log", "count": 3})])
    assert not plan_async.stale_reasons(basis, gathered, [Task(skill="gather", args={"resource": "log", "count": 5})])

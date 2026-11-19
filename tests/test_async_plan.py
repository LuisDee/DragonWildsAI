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


# ---------------------------------------------------------------- start_goal first_steps (DW_ASYNC_PLAN=1)
# Live 2026-11-19: 2 of 24 compositions had an act of his while the plan was made; the job was the Planner's and its
# step queue stood empty until the plan landed. His own first steps fill it; the plan lands as a revision of the steps
# not yet started, at a step boundary.

GATHER_2 = {"skill": "gather", "args": {"resource": "log", "count": 2}}


def _ask_with_steps(rig, steps):
    rig.game.player_say("get me 2 logs")
    rig.controller_llm.push(FakeLLM.say("On it.", FakeLLM.call(
        "start_goal", goal="gather 2 logs and give them to Luis", first_steps=steps)))


def _on_call(rig, tool, fn):
    """Run fn(args) when the body gets ``tool`` (before the mock does it)."""
    begin = rig.game._begin

    def hooked(name, **args):
        if name == tool:
            fn(args)
        return begin(name, **args)
    rig.game._begin = hooked


def _start_goal_schema(rig) -> dict:
    tools = rig.controller_llm.calls[0]["tools"]
    return next(t for t in tools if t["function"]["name"] == "start_goal")["function"]


def test_start_goal_first_steps_run_while_the_plan_is_composed(tmp_path, monkeypatch):
    rig = _rig(tmp_path, monkeypatch)
    slow = SlowPlanner(PLAN)
    rig.planner_llm.push(slow)
    _ask_with_steps(rig, [GATHER_2])
    seen = {}
    _on_call(rig, "gather", lambda args: seen.setdefault("gate_shut", not slow.gate.is_set()))

    def steps_done_plan_pending(messages, tools):  # his steps ran out with the plan still pending: his turn
        seen["event"] = json.loads(messages[1]["content"]).get("body_event") or {}
        slow.gate.set()
        return LLMResponse(content="")

    rig.controller_llm.push(steps_done_plan_pending)
    try:
        assert rig.agent.step() == "done"
    finally:
        slow.gate.set()
    assert seen["gate_shut"] is True  # his first step reached the body before the plan landed
    assert seen["event"]["type"] == "plan_pending"
    assert "first_steps" in _start_goal_schema(rig)["parameters"]["properties"]
    (first,) = _rows(rig, "first_steps_started")
    assert first["steps"][0].startswith("gather(")
    (acted,) = _rows(rig, "acted_while_planning")
    assert acted["n"] >= 1 and acted["tools"][0] == "gather" and acted["first_steps"] is True
    assert rig.game.players["Luis"].inventory["log"] == 2  # the plan ran on after it landed


def test_a_step_already_done_in_the_game_is_not_repeated(tmp_path, monkeypatch):
    rig = _rig(tmp_path, monkeypatch)
    slow = SlowPlanner(PLAN)  # its first step is the gather he already did
    rig.planner_llm.push(slow)
    _ask_with_steps(rig, [GATHER_2])

    def open_gate(messages, tools):
        slow.gate.set()
        return LLMResponse(content="")
    rig.controller_llm.push(open_gate)
    try:
        assert rig.agent.step() == "done"
    finally:
        slow.gate.set()
    assert len(rig.calls("gather")) == 1  # his; the plan's gather was marked done from the bag, not run again
    (spliced,) = _rows(rig, "plan_spliced")
    assert len(spliced["marked_done"]) == 1 and spliced["marked_done"][0].startswith("gather(")
    (arrived,) = _rows(rig, "plan_arrived")
    assert arrived["stale"] is False and arrived["applied"] is True  # his own effect is no staleness
    assert any("already true in the game" in (t.detail or "") for t in rig.store.tree.tasks if t.done)
    assert rig.game.players["Luis"].inventory["log"] == 2


def test_a_landed_plan_replaces_only_unstarted_steps(tmp_path, monkeypatch):
    rig = _rig(tmp_path, monkeypatch)
    slow = SlowPlanner([{"skill": "gather", "args": {"resource": "log", "count": 1}},
                        {"skill": "go_to", "args": {"target": "Luis"}},
                        {"skill": "give", "args": {"player": "Luis", "item": "log", "count": 1}}])
    rig.planner_llm.push(slow)
    _ask_with_steps(rig, [{"skill": "gather", "args": {"resource": "log", "count": 1}},
                          {"skill": "gather", "args": {"resource": "stone", "count": 1}}])

    def land_now(args):  # the plan lands while his first step runs
        slow.gate.set()
        rig.agent._steps_plan.future.result(timeout=5)
    _on_call(rig, "gather", land_now)
    try:
        assert rig.agent.step() == "done"
    finally:
        slow.gate.set()
    gathered = rig.calls("gather")
    assert len(gathered) == 1 and gathered[0]["resource"] == "log"  # step 1 finished; step 2 never started
    (spliced,) = _rows(rig, "plan_spliced")
    assert len(spliced["kept"]) == 1 and "log" in spliced["kept"][0]
    assert len(spliced["replaced"]) == 1 and "stone" in spliced["replaced"][0]
    assert len(spliced["marked_done"]) == 1 and spliced["running"] == []
    assert rig.game.players["Luis"].inventory["log"] == 1
    assert not _rows(rig, "plan_abandoned")
    (acted,) = _rows(rig, "acted_while_planning")
    assert acted["n"] == 1 and acted["tools"] == ["gather"]  # sent before the plan landed


def test_an_invalid_first_step_is_his_calls_failed_result(tmp_path, monkeypatch):
    rig = _rig(tmp_path, monkeypatch)
    _ask_with_steps(rig, [{"skill": "fly", "args": {}}])
    seen = {}

    def hears_it(messages, tools):
        seen["result"] = json.dumps(messages)
        return LLMResponse(content="")
    rig.controller_llm.push(hears_it)
    assert rig.agent.step() is None  # no job queued: the call was refused with why, his to decide again
    assert "unknown skill 'fly'" in seen["result"]
    assert rig.agent.pending_goal is None and not rig.planner_llm.calls


def test_flag_off_first_steps_are_not_offered_and_change_nothing(tmp_path, monkeypatch):
    rig = _rig(tmp_path, monkeypatch, on=False)
    rig.planner_llm.push(FakeLLM.plan(PLAN))
    _ask_with_steps(rig, [GATHER_2])
    assert rig.agent.step() == "done"
    assert "first_steps" not in _start_goal_schema(rig)["parameters"]["properties"]
    assert len(rig.calls("gather")) == 1  # the plan's; his first_steps were not run
    assert rig.game.players["Luis"].inventory["log"] == 2
    kinds = {r["kind"] for r in rig.log.read_all()}
    assert not kinds & {"first_steps_started", "plan_spliced", "plan_started", "acted_while_planning"}

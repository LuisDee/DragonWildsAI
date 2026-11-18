"""A plan that comes with steps AND a question for the player: the steps run and the question is said once beside them
(agent._plan_question). Park study 2026-11-18 (window l2_facts_1118i; logs/brain-live-20261118-051943-25588,
-053839-17676, -054931-27144): every ask_help ended the job, even one with steps; the stuck event handed the Controller
the question, he asked and parked, and the copper job was dead 3 of 3. A plan with no steps and only a question still
stops with its reason (also test_controller_loop.test_stuck_asks_for_help_in_one_line)."""
import json

from conftest import Rig

from brain.llm import FakeLLM
from brain.mock import MockGame
from brain.mock.game import Player

Q = "want me to hunt deer for bones and hide first, or can you send a bone pick?"


def _world() -> MockGame:
    g = MockGame()
    g.players["Luis"] = Player("Luis", [1.0, 0.0, 0.0])
    for x in range(4):
        g.add_node("log", [3.0 + x, 0, 0], 5)
    return g


def _rows(rig, kind):
    return [r for r in rig.log.read_all() if r["kind"] == kind]


def _events(rig):
    out = []
    for c in rig.controller_llm.calls:
        ctx = json.loads(c["messages"][1]["content"])
        if ctx.get("body_event"):
            out.append(ctx["body_event"])
    return out


def test_a_plan_with_steps_and_a_question_runs_and_says_it_once(tmp_path):
    rig = Rig(tmp_path, game=_world())
    rig.planner_llm.push(FakeLLM.plan([{"skill": "gather", "args": {"resource": "log", "count": 2}}], ask_help=Q))
    rig.controller_llm.push(FakeLLM.say("hunting deer for bones and hide, or got a bone pick?"))
    assert rig.agent.run_goal("mine 30 copper ore") == "done"
    assert rig.game.inventory["log"] == 2
    ev = _events(rig)
    asked = [e for e in ev if e.get("type") == "plan_question"]
    assert len(asked) == 1 and asked[0]["question"] == Q and asked[0]["steps"] == ["gather log 2"]
    assert not any(e.get("type") == "stuck" for e in ev)
    assert rig.companion_said()[0] == "hunting deer for bones and hide, or got a bone pick?"
    assert [r["question"] for r in _rows(rig, "plan_question")] == [Q]


def test_a_replan_with_steps_and_a_question_goes_on(tmp_path):
    """Runs 051943 and 054931: the replan after the failed explore named the path and asked; the job ended there."""
    rig = Rig(tmp_path, game=_world())
    rig.planner_llm.push(FakeLLM.plan([{"skill": "gather", "args": {"resource": "gold", "count": 1}}], ask_help=Q),
                         FakeLLM.plan([{"skill": "gather", "args": {"resource": "log", "count": 1}}], ask_help=Q))
    assert rig.agent.run_goal("mine 30 copper ore") == "done"
    assert rig.game.inventory["log"] == 1
    assert len(_rows(rig, "plan_question")) == 1  # the same question again: said once
    assert not any(e.get("type") == "stuck" for e in _events(rig))


def test_the_question_has_a_template_line_when_the_model_call_fails(tmp_path):
    rig = Rig(tmp_path, game=_world())
    rig.planner_llm.push(FakeLLM.plan([{"skill": "gather", "args": {"resource": "log", "count": 1}}], ask_help=Q))
    assert rig.agent.run_goal("mine 30 copper ore") == "done"  # no controller script: its calls fail
    assert Q in rig.companion_said()


def test_a_question_with_no_steps_still_stops_with_it(tmp_path):
    rig = Rig(tmp_path, game=_world())
    rig.planner_llm.push(FakeLLM.plan([], ask_help=Q))
    assert rig.agent.run_goal("mine 30 copper ore") == "stuck"
    stuck = [e for e in _events(rig) if e.get("type") == "stuck"]
    assert stuck and stuck[0]["question"] == Q
    assert not _rows(rig, "plan_question")


def test_a_board_run_has_no_plan_question_situation(tmp_path):
    rig = Rig(tmp_path, game=_world())
    rig.planner_llm.push(FakeLLM.plan([{"skill": "gather", "args": {"resource": "log", "count": 1}}], ask_help=Q))
    assert rig.agent.run_goal("chop a log", quiet=True) == "done"
    assert not _rows(rig, "plan_question") and rig.controller_llm.calls == []

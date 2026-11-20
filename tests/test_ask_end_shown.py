"""DW_PLAN_AT_ASK=1: wherever the open ask is shown to the Controller, the end condition his Planner wrote at the ask is
shown with it, with its truth now (and the job's step now while one runs): the say result's his_request, the turn
lines (CONTINUE_FOR, STOP_FOR_NOTE), a goal's done / stuck event, the first turn's open_request block. Each is logged
as done_when_checked with its own ``where``. Live L3 20261120-171336 ("gear up for the vault"): the end condition
"Reinforced Body equipped and Reinforced Platelegs equipped" was written at 0.5 min, but with no job running the turns
showed only the ask's words and he asked the silent player "what vault gear do you want?". Offline: scripted LLMs and
the mock game.
"""
from __future__ import annotations

import json
from types import SimpleNamespace

from conftest import Rig

from brain import agent as A
from brain.llm import FakeLLM
from test_plan_at_ask import LOGS, PL2, T1_BODY, VAULT, _hear, _land, _rows, _wearing, on  # noqa: F401

CLAUSE = "(its end condition, written by your planner at the request: a body with power_level >= 2 (equipped); now: "


def _landed(rig):
    _wearing(rig, T1_BODY)
    rig.planner_llm.push(FakeLLM.plan(LOGS, done_when=PL2))
    _hear(rig, VAULT, FakeLLM.say("sure"))
    _land(rig)


def _wheres(rig):
    return {r["where"] for r in _rows(rig, "done_when_checked")}


def _texts(call) -> list[str]:
    return [m["content"] if isinstance(m.get("content"), str) else json.dumps(m.get("content"))
            for m in call["messages"]]


def test_the_say_result_shows_the_end_condition_with_its_truth_and_the_step_now(tmp_path, on):
    rig = Rig(tmp_path)
    _landed(rig)
    rig.agent._plan_at_ask_tick()  # the ask is still open: its plan lands as the job (queued)
    rig.agent._open_request = VAULT
    told = rig.agent._told_back(VAULT, rig.agent._fresh_state(), {"ran": ["collect_water"]},
                                SimpleNamespace(goal=None, skill=None), False)
    end = told["his_request"]["end_condition"]
    assert end["end_condition"] == "a body with power_level >= 2 (equipped)" and end["now"].startswith("not yet: ")
    assert "step_now" not in end  # no job running: none
    assert "said_result" in _wheres(rig)
    rig.agent.store.set_goal(VAULT[1], [A.Task(skill="gather", args={"resource": "log", "count": 2})])
    rig.agent.active_goal = VAULT[1]
    end = rig.agent._told_back(VAULT, rig.agent._fresh_state(), {"ran": []},
                               SimpleNamespace(goal=None, skill=None), False)["his_request"]["end_condition"]
    assert end["step_now"] == "gather log 2"
    rig.agent.store.tree.status = "stuck"  # a stuck job's next step is no step now
    end = rig.agent._told_back(VAULT, rig.agent._fresh_state(), {"ran": []},
                               SimpleNamespace(goal=None, skill=None), False)["his_request"]["end_condition"]
    assert "step_now" not in end


def test_the_goal_done_event_and_the_turn_lines_carry_it(tmp_path, on):
    rig = Rig(tmp_path)
    _landed(rig)
    rig.controller_llm.script.clear()
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("go_to", target="Luis")))  # then nothing, as long as asked
    assert rig.agent.step() == "done"
    texts = [t for c in rig.controller_llm.calls for t in _texts(c)]
    done = [t for t in texts if '"goal_done"' in t]
    assert done and '"done_when"' in done[0] and "not yet: " in done[0]
    assert any(t.startswith("Your tools ran") and CLAUSE + "not yet: " in t for t in texts)  # CONTINUE_FOR
    assert any(t.startswith("You stopped") and CLAUSE + "not yet: " in t for t in texts)  # STOP_FOR_NOTE
    assert {"goal_done", "continue_line", "stop_for"} <= _wheres(rig)


def test_no_end_condition_no_clause_and_flag_off_nothing(tmp_path, on, monkeypatch):
    rig = Rig(tmp_path)
    assert rig.agent._ask_end(VAULT, "said_result") is None  # nothing written for the ask
    assert rig.controller._end_clause(VAULT, None) == ""
    _landed(rig)
    rig.agent._plan_at_ask_tick()  # landed: the end condition is kept for the ask
    assert rig.controller._end_clause(VAULT, None).startswith(" " + CLAUSE)
    assert rig.controller._end_clause(("Luis", "something else"), None) == ""  # another ask: none
    monkeypatch.delenv(A.PLAN_AT_ASK_ENV)
    rig.agent.plan_at_ask = False
    n = len(_rows(rig, "done_when_checked"))
    assert rig.agent._ask_end(VAULT, "said_result") is None and rig.controller._end_clause(VAULT, None) == ""
    assert len(_rows(rig, "done_when_checked")) == n  # nothing read, nothing logged

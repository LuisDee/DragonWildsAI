"""DW_PLAN_AT_ASK=1: his own claim is never state. When the end condition his Planner wrote for the ask does not hold on
fresh state, his request_done leaves the ask open and its result says so with the reads, and a plan landing after his
close opens the ask again (shown as facts, nothing started for him). Met (or no end condition): the close stands as
before. Live L3 20261120-174206: closed as "ready when you are" 22 s before the plan landed with "Apprentice Robe
equipped and Apprentice Leggings equipped", not met; shown "your close stands", he made no call, the job ended quiet.
Offline: scripted LLMs and the mock game.
"""
from __future__ import annotations

from conftest import Rig

from brain import agent as A
from brain.interface import CommandReceived
from brain.llm import FakeLLM, ToolCall
from test_plan_at_ask import (JOB, LOGS, PL2, T1_BODY, T2_BODY, VAULT, SlowPlanner, _closes_while_planned, _hear,
                              _land, _rows, _wearing, on)  # noqa: F401


def test_a_plan_landing_after_his_close_with_its_end_condition_unmet_opens_the_ask_again(tmp_path, on):
    rig = Rig(tmp_path)
    _wearing(rig, T1_BODY)
    slow = SlowPlanner(FakeLLM.plan(LOGS, done_when=PL2))
    rig.planner_llm.push(slow)
    seen = _closes_while_planned(rig, slow, FakeLLM.say(""))
    assert rig.agent.step() is None  # nothing started for him
    shown = seen["shown"]
    assert A.AT_ASK_REOPENED_NOTE in shown and "close stands" not in shown
    assert "request_open_again" in shown and "not yet: " in shown and "gather" in shown
    assert rig.agent._open_request == JOB  # open again: the open-ask and left-open turns go on
    row, = _rows(rig, "request_reopened")
    assert row["where"] == "plan_arrived" and row["request"] == JOB[1] and row["reads"].startswith("not yet: ")
    at_ask, = _rows(rig, "plan_at_ask")
    assert at_ask["landed"].endswith("open again: its end condition is not met")
    assert rig.calls("gather") == [] and rig.agent.pending_goal is None and not _rows(rig, "request_parked")


def test_his_start_goal_in_that_turn_still_takes_the_landed_plan(tmp_path, on):
    rig = Rig(tmp_path)
    _wearing(rig, T1_BODY)
    slow = SlowPlanner(FakeLLM.plan(LOGS, done_when=PL2))
    rig.planner_llm.push(slow)
    _closes_while_planned(rig, slow, FakeLLM.say("on it after all", FakeLLM.call("start_goal", goal=JOB[1])))
    assert rig.agent.step() == "done"
    assert len(rig.planner_llm.calls) == 1 and rig.game.players["Luis"].inventory["log"] == 2


def test_met_at_landing_the_close_stands(tmp_path, on):
    rig = Rig(tmp_path)
    _wearing(rig, T2_BODY)  # PL 2 body worn: met
    slow = SlowPlanner(FakeLLM.plan(LOGS, done_when=PL2))
    rig.planner_llm.push(slow)
    seen = _closes_while_planned(rig, slow, FakeLLM.say(""))
    assert rig.agent.step() is None
    assert A.AT_ASK_CLOSED_NOTE in seen["shown"] and rig.agent._open_request is None
    assert not _rows(rig, "request_reopened")


def _vault_landed(rig):
    rig.planner_llm.push(FakeLLM.plan([], ask_help="which vault?", done_when=PL2))
    _hear(rig, VAULT, FakeLLM.say("sure"))
    _land(rig)
    rig.agent._plan_at_ask_tick()  # only a question: parked, the end condition kept for the ask
    rig.agent._parked = None
    rig.agent._open_request = VAULT


def test_request_done_with_its_end_condition_unmet_leaves_the_ask_open_and_says_so(tmp_path, on):
    rig = Rig(tmp_path)
    _wearing(rig, T1_BODY)
    _vault_landed(rig)
    res = rig.agent._close_ask(ToolCall("request_done", {"evidence": "ready when you are"}), [])
    assert res["ok"] is False and res["reason"] == "end_condition_not_met" and res["note"] == A.REQUEST_NOT_MET_NOTE
    assert res["game_reads"]["done_when"]["now"].startswith("not yet: ")
    assert rig.agent._open_request == VAULT  # not closed
    claimed = _rows(rig, "request_done_claimed")[-1]
    assert claimed["stays_open"] is True and claimed["evidence"] == "ready when you are"
    row, = _rows(rig, "request_reopened")
    assert row["where"] == "request_done" and row["reads"].startswith("not yet: ")


def test_request_done_with_its_end_condition_met_closes_as_before(tmp_path, on):
    rig = Rig(tmp_path)
    _wearing(rig, T2_BODY)
    _vault_landed(rig)
    res = rig.agent._close_ask(ToolCall("request_done", {"evidence": "wearing it"}), [])
    assert res["ok"] is True and res["note"] == "request closed as finished"
    assert res["game_reads"]["done_when"]["now"].startswith("yes: ")
    assert rig.agent._open_request is None and not _rows(rig, "request_reopened")


def test_in_a_chain_he_sees_the_result_and_the_ask_is_left_open(tmp_path, on):
    rig = Rig(tmp_path)
    _wearing(rig, T1_BODY)
    _vault_landed(rig)
    rig.agent._open_request = None
    rig.planner_llm.push(FakeLLM.plan([], explanation="asked again", done_when=PL2))  # the new line's own call
    rig.controller_llm.script.clear()
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1)), FakeLLM.say(""),
                            FakeLLM.say("", FakeLLM.call("request_done", evidence="all set")), FakeLLM.say("not yet"))
    rig.agent._command(CommandReceived(player=VAULT[0], text=VAULT[1]))
    turn, = _rows(rig, "done_reads_turn")  # the result went back to him
    assert turn["game_reads"]["done_when"]["now"].startswith("not yet: ")
    assert rig.agent._open_request == VAULT and _rows(rig, "request_done_claimed")[-1]["stays_open"] is True

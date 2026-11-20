"""DW_PLAN_AT_ASK=1: his Planner gets the player's ask verbatim the moment the open ask is created, in the background,
with may_decline, while his Controller turn runs as before (research 2026-11-17-long-jobs-planner-actor.md, decisions
3 and 6; L3 2026-11-20: 12 of 12 trials never reached the Planner because Haiku alone decided whether an ask was a
job). A slow fake Planner (a FakeLLM item blocked on a gate) shows: a job ask gets steps while he acts, and they run
as the job for the ask; a knowledge question's decline changes nothing; his request_done during a pending plan is
recorded and told that the job is not dropped; his stop lets it go; a goal he queues takes the call as its plan (one
call per ask); no budget, no call; flag off, nothing of this. Offline: scripted LLMs and the mock game.
"""
from __future__ import annotations

import json
import threading
from types import SimpleNamespace

import pytest

from conftest import Rig

from brain import agent as A
from brain.interface import CommandReceived
from brain.llm import FakeLLM, LLMResponse
from brain.planner import DECLINE_LINE

JOB = ("Luis", "claude, get me 2 logs")
QUESTION = ("Luis", "claude, what's the best pickaxe you can make?")
LOGS = [{"skill": "gather", "args": {"resource": "log", "count": 2}},
        {"skill": "go_to", "args": {"target": "Luis"}},
        {"skill": "give", "args": {"player": "Luis", "item": "log", "count": 2}}]


class SlowPlanner:
    """A Planner reply that waits for ``gate`` (the test opens it) and records that it was in flight."""

    def __init__(self, reply: LLMResponse):
        self.reply = reply
        self.started = threading.Event()
        self.gate = threading.Event()

    def __call__(self, messages, tools):
        self.started.set()
        assert self.gate.wait(10), "the test never opened the planner's gate"
        return self.reply


@pytest.fixture
def on(monkeypatch):
    monkeypatch.setenv(A.PLAN_AT_ASK_ENV, "1")


def _rows(rig, kind):
    return [r for r in rig.log.read_all() if r.get("kind") == kind]


def _endless(rig):
    """The Controller replies as scripted, then with nothing (no text, no call) for as long as it is asked."""
    llm = rig.controller_llm
    orig = llm.complete

    def complete(messages, tools=None, effort=None, **kw):
        if not llm.script:
            llm.script.append(FakeLLM.say(""))
        return orig(messages, tools, effort, **kw)
    llm.complete = complete


def _context(call: dict) -> dict:
    return json.loads(call["messages"][1]["content"])


def _planner_user(call) -> dict:
    return json.loads(call["messages"][1]["content"].split("\n\n")[0])


def _land(rig):
    p = rig.agent._at_ask
    assert p is not None and p.future is not None
    p.future.result(timeout=10)


def _hear(rig, ask, *replies):
    _endless(rig)
    rig.controller_llm.push(*replies)
    rig.agent._command(CommandReceived(player=ask[0], text=ask[1]))


# ----------------------------------------------------------------------------------------------- a job ask


def test_a_job_ask_gets_steps_while_he_acts_and_they_run_as_its_job(tmp_path, on):
    rig = Rig(tmp_path)
    slow = SlowPlanner(FakeLLM.plan(LOGS))
    rig.planner_llm.push(slow)
    seen = {}

    def acts_meanwhile(messages, tools):
        assert slow.started.wait(5)
        seen["pending"] = not slow.gate.is_set()  # his turn runs while the Planner call is in flight
        seen["planner"] = json.loads(messages[1]["content"]).get("planner")
        return FakeLLM.say("on it", FakeLLM.call("go_to", target="Luis"))

    _hear(rig, JOB, acts_meanwhile)
    assert seen["pending"] is True
    assert seen["planner"]["state"] == "making a plan for the player's request"  # he is told, as a fact
    assert seen["planner"]["request"] == JOB[1] and seen["planner"]["about"] == A.AT_ASK_PENDING_NOTE
    started, = _rows(rig, "plan_started")
    assert started["at_ask"] is True and started["from_ask"] is True and started["request"] == JOB[1]
    slow.gate.set()
    _land(rig)
    assert rig.agent.step() == "done"
    call, = rig.planner_llm.calls  # one Planner call for the ask
    assert _planner_user(call)["goal"] == JOB[1]  # verbatim: never rewritten
    assert DECLINE_LINE in call["messages"][0]["content"]  # may decline
    row, = _rows(rig, "plan_at_ask")
    assert row["request"] == JOB[1] and row["outcome"] == "steps" and row["landed"] == "job"
    assert row["acted"] == ["go_to"] and row["age_s"] >= 0
    assert rig.calls("gather") == [{"resource": "log", "count": 2}]  # the steps are his Planner's
    assert rig.game.players["Luis"].inventory["log"] == 2
    ended, = _rows(rig, "ask_handover_ended")
    assert ended["request"] == JOB[1] and ended["result"] == "done"
    assert rig.agent._at_ask is None and rig.agent._at_ask_outcomes[JOB] == "steps"


def test_a_knowledge_questions_decline_changes_nothing(tmp_path, on):
    rig = Rig(tmp_path)
    rig.planner_llm.push(FakeLLM.plan([], explanation="a question to answer, nothing to do in the game"))
    _hear(rig, QUESTION, FakeLLM.say("a bronze pickaxe, I've got the bars"))
    _land(rig)
    before = list(rig.game.calls)
    assert rig.agent.step() is None
    row, = _rows(rig, "plan_at_ask")
    assert row["outcome"] == "decline" and row["landed"] == "nothing: his own handling stands"
    assert row["explanation"].startswith("a question to answer")
    assert rig.agent.pending_goal is None and rig.agent.active_goal is None
    assert rig.agent._open_request == QUESTION  # his handling stands: the ask is as he left it
    assert rig.game.calls == before and not _rows(rig, "request_parked") and not _rows(rig, "ask_handover_ended")


def test_only_a_question_parks_the_ask_waiting_on_the_player(tmp_path, on):
    rig = Rig(tmp_path)
    rig.planner_llm.push(FakeLLM.plan([], ask_help="which chest is yours?"))
    _hear(rig, JOB, FakeLLM.say("sure"))
    _land(rig)
    rig.agent.step()
    row, = _rows(rig, "plan_at_ask")
    assert row["outcome"] == "question" and row["landed"] == "parked: waits on the player"
    parked, = _rows(rig, "request_parked")
    assert parked["by"] == "planner" and parked["reason"] == "planner waits on the player: which chest is yours?"
    assert rig.agent._open_request is None and rig.agent._parked["ask"] == JOB


# ----------------------------------------------------------------------------------------------- his calls meanwhile


def test_request_done_during_a_pending_plan_is_recorded_and_the_job_runs_on(tmp_path, on):
    rig = Rig(tmp_path)
    slow = SlowPlanner(FakeLLM.plan(LOGS))
    rig.planner_llm.push(slow)
    results = {}

    def turn(messages, tools):
        """Nothing until request_done is offered (the open-ask turn), then the claim; then he reads its result."""
        assert slow.started.wait(5)
        names = {t["function"]["name"] for t in tools or []}
        if "claimed" in results:
            results.setdefault("done", [m for m in messages if m.get("role") == "tool"])
            return FakeLLM.say("")
        if "request_done" in names:
            results["claimed"] = True
            return FakeLLM.say("all set", FakeLLM.call("request_done", evidence="nothing needed"))
        return FakeLLM.say("")

    _hear(rig, JOB, *([turn] * 8))
    claimed, = _rows(rig, "request_done_claimed")
    assert claimed["planners_job"]["state"].startswith("being planned")  # the close is recorded with it
    assert rig.agent._open_request is None
    told = json.dumps(results["done"])
    assert "your_planners_job" in told and "being planned" in told  # his request_done result says so
    slow.gate.set()
    _land(rig)
    assert rig.agent.step() == "done"  # not silently dropped: the planner's job runs on
    row, = _rows(rig, "plan_at_ask")
    assert row["landed"] == "job" and row["ask_open"] is False
    assert rig.game.players["Luis"].inventory["log"] == 2


def test_his_stop_lets_the_pending_plan_go(tmp_path, on):
    rig = Rig(tmp_path)
    slow = SlowPlanner(FakeLLM.plan(LOGS))
    rig.planner_llm.push(slow)

    def stops(messages, tools):
        assert slow.started.wait(5)
        return FakeLLM.say("", FakeLLM.call("stop"))

    _hear(rig, JOB, stops)
    assert rig.agent._at_ask is None and len(rig.agent._at_ask_gone) == 1
    slow.gate.set()
    rig.agent._at_ask_gone[0].future.result(timeout=10)
    assert rig.agent.step() is None
    row, = _rows(rig, "plan_at_ask")
    assert row["landed"] == "let go: stopped by him" and row["outcome"] == "steps"
    assert rig.calls("gather") == [] and rig.agent.pending_goal is None


def test_a_newer_line_lets_the_older_call_go_and_plans_the_new_ask(tmp_path, on):
    rig = Rig(tmp_path)
    slow = SlowPlanner(FakeLLM.plan(LOGS))
    rig.planner_llm.push(slow, FakeLLM.plan([], explanation="just chat"))
    _hear(rig, JOB, FakeLLM.say("ok"))
    first = rig.agent._at_ask
    _hear(rig, QUESTION, FakeLLM.say("bronze"))
    assert first.dropped == "a newer player line" and rig.agent._at_ask is not first
    _land(rig)
    slow.gate.set()
    first.future.result(timeout=10)
    assert rig.agent.step() is None
    rows = {r["request"]: r for r in _rows(rig, "plan_at_ask")}
    assert rows[JOB[1]]["landed"] == "let go: a newer player line"
    assert rows[QUESTION[1]]["outcome"] == "decline"
    assert rig.calls("gather") == []  # the let-go job's steps never run


def test_a_goal_he_queues_on_the_ask_takes_the_call_as_its_plan(tmp_path, on):
    rig = Rig(tmp_path)
    slow = SlowPlanner(FakeLLM.plan(LOGS))
    rig.planner_llm.push(slow)

    def starts_goal(messages, tools):
        assert slow.started.wait(5)
        slow.gate.set()
        return FakeLLM.say("On it.", FakeLLM.call("start_goal", goal="gather 2 logs and give them to Luis"))

    _hear(rig, JOB, starts_goal)
    _land(rig)
    assert rig.agent.step() == "done"
    assert len(rig.planner_llm.calls) == 1  # one Planner call per ask: no second plan for his goal
    adopted, = _rows(rig, "plan_at_ask_adopted")
    assert adopted["goal"] == "gather 2 logs and give them to Luis"
    row, = _rows(rig, "plan_at_ask")
    assert row["landed"] == "his goal's plan" and row["outcome"] == "steps"
    assert rig.game.players["Luis"].inventory["log"] == 2


# ----------------------------------------------------------------------------------------------- bounds


def test_out_of_budget_no_call(tmp_path, on):
    rig = Rig(tmp_path)
    rig.agent.budget = SimpleNamespace(allows=lambda kind="model": kind != "planner", out_line_due=lambda: False)
    _hear(rig, JOB, FakeLLM.say("ok"))
    assert rig.planner_llm.calls == [] and rig.agent._at_ask is None
    row, = _rows(rig, "plan_at_ask")
    assert row["landed"] == "not asked" and row["why"] == "out of model budget"
    assert rig.agent.step() is None


def test_flag_off_unchanged(tmp_path):
    rig = Rig(tmp_path)
    assert rig.agent.plan_at_ask is False
    _hear(rig, JOB, FakeLLM.say("ok"))
    assert rig.agent._at_ask is None and rig.planner_llm.calls == []
    assert rig.agent.step() is None
    assert not _rows(rig, "plan_at_ask") and not _rows(rig, "plan_started")
    assert all("planner" not in _context(c) for c in rig.controller_llm.calls)


def test_off_while_the_director_is_attached(tmp_path, on):
    rig = Rig(tmp_path)
    rig.agent.director = SimpleNamespace(running=False, owns_transition=False, tool_names=set(),
                                         tick=lambda: None, on_player_command=lambda *a: None)
    _hear(rig, JOB, FakeLLM.say("ok"))
    assert rig.agent._at_ask is None and rig.planner_llm.calls == []


def test_an_unaddressed_line_asks_nothing(tmp_path, on):
    rig = Rig(tmp_path)
    _endless(rig)
    rig.agent._command(CommandReceived(player="Luis", text="lol nice one"), addressed=False)
    assert rig.agent._at_ask is None and rig.planner_llm.calls == []


def test_with_the_ask_owner_on_a_decline_at_the_ask_is_not_handed_over_again(tmp_path, on, monkeypatch):
    """Both flags: the ask left open after a decline at the ask is not handed to the Planner a second time."""
    monkeypatch.setenv(A.ASK_OWNER_ENV, "1")
    rig = Rig(tmp_path)
    rig.planner_llm.push(FakeLLM.plan([], explanation="a question, nothing to do"))
    _hear(rig, QUESTION, FakeLLM.say("which one do you mean?"))
    assert rig.agent._unowned is not None  # he left it open
    _land(rig)
    rig.agent.step()
    skipped, = _rows(rig, "ask_handover_skipped")
    assert skipped["why"] == "declined by his planner at the ask"
    assert len(rig.planner_llm.calls) == 1 and not _rows(rig, "ask_handover")

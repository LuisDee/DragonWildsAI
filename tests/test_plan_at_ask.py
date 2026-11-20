"""DW_PLAN_AT_ASK=1: his Planner gets the player's ask verbatim the moment the open ask is created, in the background,
with may_decline, while his Controller turn runs as before (research 2026-11-17-long-jobs-planner-actor.md, decisions
3 and 6; L3 2026-11-20: 12 of 12 trials never reached the Planner because Haiku alone decided whether an ask was a
job). A slow fake Planner (a FakeLLM item blocked on a gate) shows: a job ask gets steps while he acts, and they run
as the job for the ask; a knowledge question's decline changes nothing; a plan landing after his request_done starts
and parks nothing and is shown to him once (his start_goal on it takes it); his stop lets it go; a goal he queues takes the call as its plan (one
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
    assert seen["planner"]["request"] == JOB[1]
    about = seen["planner"]["about"]  # facts only (audit 2026-11-20): composing since N s, what its steps do
    assert about.startswith("Your planner is composing a plan for this request, started 0 s ago.")
    assert "plainly" not in about and "look things up" not in about
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


def _closes_while_planned(rig, slow, then):
    """He closes the ask with request_done while its plan is made; ``then`` is his reply in the turn that shows the
    landed plan (a situation run). Returns that turn's context."""
    seen = {}

    def turn(messages, tools):
        names = {t["function"]["name"] for t in tools or []}
        if "for_closed_request" in messages[1]["content"]:
            seen.setdefault("shown", messages[1]["content"])
            return then
        if "claimed" in seen:
            return FakeLLM.say("")
        if "request_done" in names:
            seen["claimed"] = True
            return FakeLLM.say("all set", FakeLLM.call("request_done", evidence="nothing needed"))
        return FakeLLM.say("")

    _hear(rig, JOB, *([turn] * 12))
    claimed, = _rows(rig, "request_done_claimed")
    assert claimed["planners_job"]["state"].startswith("being planned")  # the close is recorded with it
    assert claimed["planners_job"]["note"] == A.AT_ASK_DONE_PENDING_NOTE
    assert claimed["game_reads"] == {}  # flag on: no done_when yet, no tree, so no done-reads turn
    assert not _rows(rig, "done_reads_turn") and rig.agent._open_request is None
    rig.controller_llm.push(*([turn] * 4))
    slow.gate.set()
    _land(rig)
    return seen


def test_a_plan_landing_after_his_request_done_starts_nothing_and_is_shown_once(tmp_path, on):
    """Audit 2026-11-20: code sided with the Planner over his close. Now the close stands (its end condition met: an
    unmet one opens the ask again, tests/test_ask_end_not_met.py): one turn shows the plan."""
    rig = Rig(tmp_path)
    _wearing(rig, T2_BODY)
    slow = SlowPlanner(FakeLLM.plan(LOGS, done_when=PL2))
    rig.planner_llm.push(slow)
    seen = _closes_while_planned(rig, slow, FakeLLM.say("I'll leave it then"))
    assert rig.agent.step() is None  # nothing started
    assert "for_closed_request" in seen["shown"] and A.AT_ASK_CLOSED_NOTE in seen["shown"]
    assert "gather" in seen["shown"] and "done_when" in seen["shown"] and "power_level >= 2" in seen["shown"]
    row, = _rows(rig, "plan_at_ask")
    assert row["landed"] == "shown, not started: he closed the request"
    let_go, = _rows(rig, "plan_at_ask_let_go")
    assert let_go["request"] == JOB[1] and rig.agent._at_ask_held is None
    assert rig.calls("gather") == [] and rig.agent.pending_goal is None and not _rows(rig, "request_parked")
    assert rig.agent._open_request is None and rig.agent._parked is None  # his close stands
    assert rig.agent.step() is None and rig.calls("gather") == []  # and nothing later either


def test_in_the_turn_that_shows_it_his_start_goal_takes_the_landed_plan(tmp_path, on):
    rig = Rig(tmp_path)
    slow = SlowPlanner(FakeLLM.plan(LOGS))
    rig.planner_llm.push(slow)
    _closes_while_planned(rig, slow, FakeLLM.say("on it after all", FakeLLM.call("start_goal", goal=JOB[1])))
    assert rig.agent.step() == "done"
    assert len(rig.planner_llm.calls) == 1  # the landed plan, no second Planner call
    adopted, = _rows(rig, "plan_at_ask_adopted")
    assert adopted["after_close"] is True and adopted["goal"] == JOB[1]
    assert rig.game.players["Luis"].inventory["log"] == 2


def test_a_question_landing_after_his_request_done_is_shown_not_parked(tmp_path, on):
    rig = Rig(tmp_path)
    slow = SlowPlanner(FakeLLM.plan([], ask_help="which chest is yours?"))
    rig.planner_llm.push(slow)
    seen = _closes_while_planned(rig, slow, FakeLLM.say(""))
    assert rig.agent.step() is None
    assert "which chest is yours?" in seen["shown"] and A.AT_ASK_CLOSED_Q_NOTE in seen["shown"]
    row, = _rows(rig, "plan_at_ask")
    assert row["landed"] == "shown, not parked: he closed the request"
    assert not _rows(rig, "request_parked") and rig.agent._parked is None and rig.agent._at_ask_held is None


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


# ----------------------------------------------------------------------------------------------- done_when
# The job's end condition, written once at the ask by the Planner in predicates.py's vocabulary and checked by code on
# fresh state (research 2026-11-17-long-jobs-planner-actor.md, decision 6). L3 2026-11-20 ("gear up for the vault"):
# nothing held what "geared up" meant, so nothing read it as met or not.

PL2 = {"gear_better": {"slot": "body", "stat": "power_level", "than": 2, "op": ">="}}
T1_BODY, T2_BODY = "ITEM_Armour_T1_Body_Adventurers", "ITEM_Armour_T2_Body_Leather"
VAULT = ("Luis", "claude, gear up for the vault")


def _wearing(rig, body):
    orig = rig.game.get_state

    def get_state():
        r = orig()
        r["data"]["gear"] = {"Body": body} if body else {}
        return r
    rig.game.get_state = get_state


def test_done_when_is_written_at_the_ask_and_checked_true_or_false_on_fresh_state(tmp_path, on):
    from brain import predicates as P
    from brain.planner import DONE_WHEN_LINE
    rig = Rig(tmp_path)
    _wearing(rig, T1_BODY)
    rig.planner_llm.push(FakeLLM.plan(LOGS, done_when=PL2))
    _hear(rig, VAULT, FakeLLM.say("sure"))
    _land(rig)
    system = rig.planner_llm.calls[0]["messages"][0]["content"]
    assert DONE_WHEN_LINE in system and P.SCHEMA_DOC in system  # one schema line, the format from predicates.py
    row, = _rows(rig, "plan_done_when")
    assert row["request"] == VAULT[1] and row["valid"] is True and row["done_when"] == PL2
    assert rig.agent.step() == "done"
    ends = [r for r in _rows(rig, "done_when_checked") if r["where"] == "step_end"]
    assert len(ends) == len(LOGS) and all(r["holds"] is False for r in ends)  # an Adventurer's Tunic is PL 1
    assert "Adventurer's Tunic 1 vs 2" in ends[0]["reads"]
    rig.agent._open_request = VAULT  # the ask open again: its block shows the end condition with its truth now
    blk = rig.agent._open_ask_block(VAULT, rig.agent._fresh_state())
    dw = blk["open_request"]["done_when"]
    assert dw["end_condition"] == "a body with power_level >= 2 (equipped)" and dw["now"].startswith("not yet: ")
    _wearing(rig, T2_BODY)
    assert rig.agent._done_when_now(VAULT, "test", rig.agent._fresh_state())["now"].startswith("yes: ")
    assert rig.agent._done_when_now(("Luis", "something else"), "test") is None  # another ask: none


def test_request_done_game_reads_carry_done_when_and_get_their_turn(tmp_path, on):
    rig = Rig(tmp_path)
    _wearing(rig, T1_BODY)
    rig.planner_llm.push(FakeLLM.plan([], ask_help="which vault?", done_when=PL2))
    _hear(rig, VAULT, FakeLLM.say("sure"))
    _land(rig)
    rig.agent._plan_at_ask_tick()  # a question with the ask open: parked as before, done_when kept for the ask
    assert rig.agent._done_when["ask"] == VAULT
    rig.agent._parked = None
    rig.planner_llm.push(FakeLLM.plan([], explanation="asked again", done_when=PL2))  # the new ask's own call
    rig.controller_llm.script.clear()
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1)), FakeLLM.say(""),
                            FakeLLM.say("", FakeLLM.call("request_done", evidence="all set")), FakeLLM.say("not yet"))
    rig.agent._command(CommandReceived(player=VAULT[0], text=VAULT[1]))
    reads = _rows(rig, "request_done_claimed")[-1]["game_reads"]
    assert set(reads) == {"done_when"} and reads["done_when"]["now"].startswith("not yet: ")  # no power level, places
    turn, = _rows(rig, "done_reads_turn")
    assert turn["game_reads"] == reads
    assert any(r["where"] == "request_done" and r["holds"] is False for r in _rows(rig, "done_when_checked"))


def test_an_invalid_done_when_is_refused_with_its_reason_and_the_plan_still_lands(tmp_path, on):
    rig = Rig(tmp_path)
    rig.planner_llm.push(FakeLLM.plan(LOGS, done_when={"have": {"item": "banana", "at_least": 2}}))
    _hear(rig, JOB, FakeLLM.say("sure"))
    _land(rig)
    row, = _rows(rig, "plan_done_when")
    assert row["valid"] is False and "unknown item 'banana'" in row["error"]
    assert len(rig.planner_llm.calls) == 1  # no repair round for it: the plan is good
    assert rig.agent.step() == "done" and rig.game.players["Luis"].inventory["log"] == 2  # the steps ran
    assert rig.agent._done_when is None and not _rows(rig, "done_when_checked")


def test_null_done_when_for_an_ask_that_is_no_job(tmp_path, on):
    rig = Rig(tmp_path)
    rig.planner_llm.push(FakeLLM.plan([], explanation="just a question", done_when=None))
    _hear(rig, QUESTION, FakeLLM.say("bronze"))
    _land(rig)
    row, = _rows(rig, "plan_done_when")
    assert row["valid"] is True and row["done_when"] is None
    rig.agent.step()
    assert rig.agent._done_when is None


def test_flag_off_no_done_when_line_and_request_done_reads_as_before(tmp_path):
    from brain.planner import DONE_WHEN_LINE
    rig = Rig(tmp_path)
    rig.planner_llm.push(FakeLLM.plan(LOGS, done_when=PL2))  # an ordinary plan call: no done_when line, no row
    res = rig.agent.planner.plan("get 2 logs", rig.agent._fresh_state(), {})
    assert DONE_WHEN_LINE not in rig.planner_llm.calls[0]["messages"][0]["content"]
    assert res.done_when is None and not _rows(rig, "plan_done_when")
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1)), FakeLLM.say(""),
                            FakeLLM.say("", FakeLLM.call("request_done", evidence="ok")), FakeLLM.say(""))
    rig.agent._command(CommandReceived(player=JOB[0], text=JOB[1]))
    assert "your_power_level" in _rows(rig, "request_done_claimed")[0]["game_reads"]  # unchanged with the flag off

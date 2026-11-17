"""The open ask survives one silent turn (brain/open_ask.py; variant C of docs/research/2026-11-17-open-ask-replay.md).

A turn with no call while a player's ask is open runs ONE more Controller turn that shows the ask as data (his words,
who, how long ago, what changed in the game since) and offers request_done(evidence) and park_request(reason). Either
closes the ask and is logged; a second silent turn closes it as before (`request_closed`, after_open_ask_turn). Offline:
scripted LLMs and the mock game.
"""
import json

from conftest import Rig

from brain import open_ask as oa
from brain.interface import CommandReceived
from brain.llm import FakeLLM

ASK = ("Luis", "claude, chop me 2 logs")


def _rows(rig, kind):
    return [r for r in rig.log.read_all() if r.get("kind") == kind]


def _tools(call) -> set[str]:
    return {t["function"]["name"] for t in call["tools"] or []}


def _open_turns(rig) -> list[dict]:
    """The Controller calls whose last message is the open ask."""
    return [c for c in rig.controller_llm.calls
            if str(c["messages"][-1].get("content") or "").startswith(oa.NOTE_PREFIX)]


def _shown(call) -> dict:
    return json.loads(call["messages"][-1]["content"][len(oa.NOTE_PREFIX):])["open_request"]


def _ask(rig, *replies):
    rig.controller_llm.push(*replies)
    rig.agent._command(CommandReceived(player=ASK[0], text=ASK[1]))


def _review(rig):
    rig.agent._command(CommandReceived(player="Luis", text=""), addressed=True,
                       body_events=[{"type": "situation_review", "changes": ["hydration: low"]}])


def test_a_silent_stop_runs_one_more_turn_that_shows_the_ask_and_what_changed(tmp_path):
    rig = Rig(tmp_path)
    _ask(rig, FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1)), FakeLLM.say(""), FakeLLM.say(""))
    calls = rig.controller_llm.calls
    assert len(calls) == 3  # the ask, the report turn (silent), the open-ask turn (silent again)
    opened = _open_turns(rig)
    assert opened == [calls[2]]  # once
    shown = _shown(calls[2])
    assert shown["player"] == "Luis" and shown["words"] == ASK[1]
    assert isinstance(shown["asked_s_ago"], int) and shown["asked_s_ago"] >= 0
    assert shown["changed_since_asked"]["bag"] == {"log": "+1"}  # read from fresh state against the state at the ask
    assert shown["changed_since_asked"]["worn"] == "no change"
    assert shown["open_until"] == "request_done or park_request is called"
    # the block states facts: no advice in code's words (his own words are quoted as they were)
    note = calls[2]["messages"][-1]["content"].replace(ASK[1], "")
    assert not any(w in note.lower() for w in ("continue", "should", "next step", "you ")), note
    assert calls[2]["messages"][-2]["content"].startswith("Current observation: ")  # as the replay built it
    # the two tools are offered on that turn only
    assert {"request_done", "park_request"} <= _tools(calls[2])
    assert not ({"request_done", "park_request"} & (_tools(calls[0]) | _tools(calls[1])))
    row, = _rows(rig, "open_ask_turn")
    assert row["request"] == ASK[1] and row["player"] == "Luis" and row["outcome"] == "silent"
    assert row["shown"]["open_request"]["changed_since_asked"]["bag"] == {"log": "+1"}
    # a second silent turn closes it as before, countably
    closed, = _rows(rig, "request_closed")
    assert closed["after_open_ask_turn"] is True and "no_open_ask_turn" not in closed
    assert rig.agent._open_request is None


def test_request_done_closes_the_ask_and_records_his_evidence(tmp_path):
    rig = Rig(tmp_path)
    _ask(rig, FakeLLM.say("", FakeLLM.call("gather", resource="log", count=2)), FakeLLM.say(""),
         FakeLLM.say("", FakeLLM.call("request_done", evidence="2 logs in my bag")))
    assert rig.agent._open_request is None
    claimed, = _rows(rig, "request_done_claimed")
    assert claimed["request"] == ASK[1] and claimed["player"] == "Luis" and claimed["evidence"] == "2 logs in my bag"
    assert _rows(rig, "open_ask_turn")[0]["outcome"] == "done_claim"
    assert not _rows(rig, "request_closed") and not _rows(rig, "request_parked")
    assert len(rig.controller_llm.calls) == 3  # his close is his stop: no further turn
    assert rig.companion_said() == []  # code says nothing for him; the claim is recorded, not judged


def test_park_request_closes_the_ask_and_the_player_hears_the_reason(tmp_path):
    rig = Rig(tmp_path)
    why = "no trees left near here, they're all chopped"
    _ask(rig, FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1)), FakeLLM.say(""),
         FakeLLM.say("", FakeLLM.call("park_request", reason=why)))
    assert rig.agent._open_request is None
    parked, = _rows(rig, "request_parked")
    assert parked["request"] == ASK[1] and parked["player"] == "Luis" and parked["reason"] == why
    assert _rows(rig, "open_ask_turn")[0]["outcome"] == "park"
    assert rig.companion_said() == [why]  # the tool says the player hears it: his own words
    assert not _rows(rig, "request_closed") and len(rig.controller_llm.calls) == 3


def test_work_on_the_extra_turn_keeps_the_ask_open_and_there_is_never_a_second_extra_turn(tmp_path):
    rig = Rig(tmp_path)
    _ask(rig, FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1)), FakeLLM.say(""),
         FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1)), FakeLLM.say(""))
    assert len(rig.calls("gather")) == 2  # he went on after the open-ask turn
    row, = _rows(rig, "open_ask_turn")
    assert row["outcome"] == "world" and row["actions"] == ["gather"]
    assert len(_open_turns(rig)) == 1  # one extra turn per run: no loop
    closed, = _rows(rig, "request_closed")  # his next silent stop closes it as before
    assert closed["after_open_ask_turn"] is False and closed["no_open_ask_turn"] == "had one this run"
    assert len(rig.controller_llm.calls) == 4


def test_a_new_player_line_still_replaces_the_open_ask(tmp_path):
    rig = Rig(tmp_path)
    _ask(rig, FakeLLM.say("", FakeLLM.call("start_goal", goal="chop 2 logs for Luis")))  # a goal: the ask stays open
    assert rig.agent._open_request == ASK and not _rows(rig, "open_ask_turn")
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("go_to", target="Luis")), FakeLLM.say(""), FakeLLM.say(""))
    rig.agent._command(CommandReceived(player="Luis", text="claude, come here"))
    row, = _rows(rig, "open_ask_turn")
    assert row["request"] == "claude, come here"  # the new line is the open one
    assert _shown(_open_turns(rig)[0])["words"] == "claude, come here"
    assert [r["request"] for r in _rows(rig, "request_closed")] == ["claude, come here"]  # the first never closed


def test_a_body_only_run_with_no_ask_open_is_unaffected(tmp_path):
    rig = Rig(tmp_path)
    assert rig.agent._open_request is None
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1)), FakeLLM.say(""))
    _review(rig)
    assert len(rig.controller_llm.calls) == 2  # the run and its report turn, as before
    assert not _open_turns(rig) and not _rows(rig, "open_ask_turn") and not _rows(rig, "request_closed")
    assert not any({"request_done", "park_request"} & _tools(c) for c in rig.controller_llm.calls)


def test_the_ask_tools_are_not_offered_and_are_refused_when_no_ask_is_open(tmp_path):
    rig = Rig(tmp_path)
    assert not ({"request_done", "park_request"} & rig.controller.offered())
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("request_done", evidence="all done")), FakeLLM.say(""))
    _review(rig)
    assert [r["tool"] for r in _rows(rig, "controller_unknown_tool")] == ["request_done"]
    assert not _rows(rig, "request_done_claimed")
    assert not ({"request_done", "park_request"} & rig.controller.offered())  # nothing left behind


def test_no_extra_turn_when_the_run_handed_the_ask_to_a_job(tmp_path):
    # a goal (or a learned skill) queued in the run carries the ask; its end reopens it (goal_done's request)
    rig = Rig(tmp_path)
    _ask(rig, FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1),
                          FakeLLM.call("start_goal", goal="chop 2 logs for Luis")), FakeLLM.say(""))
    assert len(rig.controller_llm.calls) == 2 and not _open_turns(rig)
    closed, = _rows(rig, "request_closed")
    assert closed["no_open_ask_turn"] == "handed to a job"


def test_no_extra_turn_when_the_turn_budget_is_spent(tmp_path, monkeypatch):
    from brain import agent as A
    monkeypatch.setattr(A, "MAX_TURNS", 1)
    rig = Rig(tmp_path)
    _ask(rig, FakeLLM.say("", FakeLLM.call("gather", resource="log", count=1)), FakeLLM.say(""))
    assert len(rig.controller_llm.calls) == 2 and not _open_turns(rig)
    closed, = _rows(rig, "request_closed")
    assert closed["after_open_ask_turn"] is False and closed["no_open_ask_turn"] == "turn budget"

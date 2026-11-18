"""The turn after a line said while a player's ask is open (study ask_vs_act, window l2_v1_1118l, 2026-11-18).

Live 4 of 4 runs of the copper job ended on a question ("where's a copper vein?"): the turn after it was told only
{"ok": true, "note": "said"} and PROMISE_NOTE, whose "(you only answered or asked something) reply with no text at
all" made the question terminal (replayed 0/18 act). Two parts, one point in brain/agent.py:
1. the say result of that line carries what is true about it, as data: who could hear it (players in sight, or
   nobody), the asking player's last line and how long ago, and what is working on his request now;
2. that turn's note is PROMISE_FOR_NOTE (names his request), not PROMISE_NOTE, while his request is still open.
No request open: both stay as they were. Offline: scripted LLMs and the mock game.
"""
import json

import pytest
from conftest import Rig

from brain.agent import PROMISE_FOR_NOTE, PROMISE_NOTE
from brain.interface import CommandReceived
from brain.llm import FakeLLM

ASK = ("Luis", "claude, get me 30 copper ore in the chest")
QUESTION = "stone pick can't do copper. where's a copper vein?"


@pytest.fixture(autouse=True)
def _say_channel(monkeypatch):
    monkeypatch.setenv("DW_SPEECH_CHANNEL", "say")  # live: only say calls are heard, and the say result is shown


def _rows(rig, kind):
    return [r for r in rig.log.read_all() if r.get("kind") == kind]


def _say_results(rig) -> list[dict]:
    """Every say tool result the Controller was shown, in order."""
    last = rig.controller_llm.calls[-1]["messages"]  # the messages carry every earlier turn's results
    return [json.loads(m["content"]) for m in last if m.get("role") == "tool" and m.get("name") == "say"]


def _notes(rig) -> list[str]:
    return [str(c["messages"][-1].get("content") or "") for c in rig.controller_llm.calls]


def _ask(rig, *replies, addressed=True):
    rig.controller_llm.push(*replies)
    rig.agent._command(CommandReceived(player=ASK[0], text=ASK[1]), addressed=addressed)


def test_a_question_said_on_his_open_ask_is_told_back_who_heard_it_and_that_nothing_works_on_it(tmp_path):
    rig = Rig(tmp_path)
    rig.game.players.pop("Luis")  # he is not in sight
    _ask(rig, FakeLLM.say("", FakeLLM.call("say", text=QUESTION)), FakeLLM.say(""), FakeLLM.say(""))
    res = _say_results(rig)[0]
    assert res["ok"] is True and res["note"] == "said"
    assert res["heard_by"] == "nobody in sight"
    assert res["Luis"]["in_sight"] is False
    assert res["Luis"]["last_line"] == ASK[1] and isinstance(res["Luis"]["last_line_s_ago"], int)
    assert res["his_request"] == {"words": ASK[1], "open": True,
                                  "working_on_it": "nothing: no job and no step under way"}
    row = _rows(rig, "say_told_back")[0]
    assert row["heard_by"] == "nobody in sight" and row["working_on_it"].startswith("nothing")
    assert row["note"] == "promise_for" and row["request"] == ASK[1]


def test_that_turn_names_his_request_instead_of_offering_silence(tmp_path):
    rig = Rig(tmp_path)
    _ask(rig, FakeLLM.say("", FakeLLM.call("say", text=QUESTION)), FakeLLM.say(""), FakeLLM.say(""))
    notes = _notes(rig)
    want = PROMISE_FOR_NOTE.format(player="Luis", request=ASK[1])
    assert notes[1] == want and PROMISE_NOTE not in notes


def test_a_player_in_sight_is_named_as_hearing_it(tmp_path):
    rig = Rig(tmp_path)  # the mock world has Luis 2 m away
    _ask(rig, FakeLLM.say("", FakeLLM.call("say", text=QUESTION)), FakeLLM.say(""), FakeLLM.say(""))
    res = _say_results(rig)[0]
    assert res["heard_by"] == "in sight: Luis" and res["Luis"]["in_sight"] is True


def test_a_line_said_beside_a_call_tells_what_works_on_it(tmp_path):
    rig = Rig(tmp_path)
    _ask(rig, FakeLLM.say("", FakeLLM.call("say", text="on it"), FakeLLM.call("gather", resource="log", count=1)),
         FakeLLM.say(""), FakeLLM.say(""))
    res = _say_results(rig)[0]
    assert res["his_request"]["working_on_it"] == "this turn's calls: gather"


def test_with_no_request_open_the_say_result_and_the_note_stay_as_they_were(tmp_path):
    """A line nobody addressed to him (addressed=False) that he answered opens no ask."""
    rig = Rig(tmp_path)
    _ask(rig, FakeLLM.say("", FakeLLM.call("say", text="copper's up north I think")), FakeLLM.say(""),
         addressed=False)
    assert _say_results(rig)[0] == {"ok": True, "note": "said"}
    assert PROMISE_NOTE in _notes(rig)
    assert not _rows(rig, "say_told_back")

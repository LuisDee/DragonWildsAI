"""GOAL M1 talk_without_action: a talk-only FOLLOW-UP turn (after tool results) gets one more model call
before its line is said (controller.TALK_ONLY_NOTE), so a line like "it's raw, I'll look for a fire"
(live 21:17:50, after a pickup) comes with its tool call. Decided on the reply's shape only (text and no
tool call), never its words; the model's answer is used as it is. The agent's first-turn check
(agent.PROMISE_NOTE) is not doubled."""
from __future__ import annotations

from brain.controller import TALK_ONLY_NOTE
from brain.interface import fail, ok
from brain.llm import FakeLLM, LLMResponse

from test_event_hygiene import STATES, Replay

MEAT = "BP_RuntimeSpawnedWorldItem_C_2147464905"
TOOLS = {"get_state", "say", "follow", "go_to", "stop", "interact", "cast"}


def _rig(tmp_path, worked: bool = False):
    """The pickup fails (out of reach): the follow-up talk-only turn gets the check. ``worked``: it succeeds, and a
    talk-only follow-up is then the report itself, with no check call (chat ladder 2026-10-31)."""
    r = Replay(tmp_path, STATES[5], tools=TOOLS)
    r.body.act("interact", ok(target=MEAT) if worked else fail("not_interactable", detail="out of reach"))
    r.model.replies["grab that meat"] = FakeLLM.say("", FakeLLM.call("interact", target=MEAT))
    return r


def _run(r):
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude grab that meat"})
    r.at(0).step()


def _notes(r):
    return [c["messages"][-1]["content"] for c in r.model.calls if c["messages"][-1]["role"] == "user"]


def test_a_talk_only_follow_up_promise_gets_its_tool_call_before_it_is_said(tmp_path):
    r = _rig(tmp_path)
    r.body.act("go_to", ok(target="Zezima"))
    r.model.turns = [FakeLLM.say("can't reach it, I'll walk closer"),  # after the failed pickup: talk only
                     FakeLLM.say("", FakeLLM.call("go_to", target="Zezima")),  # the check turn: the call
                     FakeLLM.say("")]  # after the walk: nothing to add
    _run(r)
    assert [c[0] for c in r.body.calls] == ["interact", "go_to"]
    assert r.body.said == ["can't reach it, I'll walk closer"]  # one line, kept as the model wrote it
    tl = r.body.timeline
    assert tl.index(("say", "can't reach it, I'll walk closer")) < tl.index(("call", "go_to"))
    assert TALK_ONLY_NOTE in _notes(r)
    row = r.records("talk_only_check")[0]
    assert row["actions"] == ["go_to"]


def test_the_check_reply_may_reword_the_line(tmp_path):
    r = _rig(tmp_path)
    r.body.act("go_to", ok(target="Zezima"))
    r.model.turns = [FakeLLM.say("gonna go find a fire"),
                     FakeLLM.say("off to find a fire", FakeLLM.call("go_to", target="Zezima")), FakeLLM.say("")]
    _run(r)
    assert r.body.said == ["off to find a fire"] and [c[0] for c in r.body.calls] == ["interact", "go_to"]


def test_a_plain_follow_up_report_stands_when_the_check_replies_empty(tmp_path):
    r = _rig(tmp_path)
    r.model.turns = [FakeLLM.say("got it, raw though"), FakeLLM.say("")]
    _run(r)
    assert r.body.said == ["got it, raw though"] and [c[0] for c in r.body.calls] == ["interact"]
    assert r.records("talk_only_check")[0]["actions"] == []


def test_a_failed_check_call_keeps_the_line(tmp_path):
    r = _rig(tmp_path)
    r.model.turns = [FakeLLM.say("got it, raw though")]
    orig = r.model.complete

    def complete(messages, tools=None):
        if messages[-1].get("content") == TALK_ONLY_NOTE:
            raise RuntimeError("provider down")
        return orig(messages, tools)
    r.model.complete = complete
    _run(r)
    assert r.body.said == ["got it, raw though"]
    assert "provider down" in r.records("talk_only_check")[0]["error"]


def test_after_a_turn_that_worked_a_talk_only_reply_is_the_report_with_no_check(tmp_path):
    """Live chat ladder 2026-10-31: "I'm at Vannaka, what's up?" after a verified go_to cost a 3rd call that only
    repeated it. After a turn whose actions worked the follow-up note asks for any promised call in the same
    reply, and a talk-only reply is said as it is."""
    r = _rig(tmp_path, worked=True)
    r.model.turns = [FakeLLM.say("got it, raw though")]
    _run(r)
    assert r.body.said == ["got it, raw though"] and len(r.model.calls) == 2
    assert r.records("talk_only_check") == [] and TALK_ONLY_NOTE not in _notes(r)
    assert "comes with its tool call in this same reply" in _notes(r)[-1]


def test_a_silent_follow_up_costs_no_check(tmp_path):
    r = _rig(tmp_path)
    r.model.turns = [FakeLLM.say("")]
    _run(r)
    assert r.records("talk_only_check") == [] and TALK_ONLY_NOTE not in _notes(r)


def test_the_first_turn_check_is_not_doubled(tmp_path):
    """Turn 0 talk-only: the agent's PROMISE_NOTE turn (a next_turn with a note) gets no second check."""
    r = Replay(tmp_path, STATES[5], tools=TOOLS)
    r.model.replies["how are you"] = FakeLLM.say("not bad, you?")
    r.model.turns = [LLMResponse(content="")]
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude how are you"})
    r.at(0).step()
    assert r.body.said == ["not bad, you?"] and len(r.model.calls) == 2
    assert r.records("talk_only_check") == []


def test_a_correction_without_a_call_replaces_a_line_it_cannot_back_up(tmp_path):
    """Voice eval v2: a line the model can't back up (no tool or target for it) gets the model's own
    correction, saying what's stopping it, instead of standing unbacked."""
    r = _rig(tmp_path)
    r.model.turns = [FakeLLM.say("walking to a fire now"), FakeLLM.say("can't see a fire anywhere, got any cooked food?")]
    _run(r)
    assert r.body.said == ["can't see a fire anywhere, got any cooked food?"]
    assert [c[0] for c in r.body.calls] == ["interact"]
    assert "what's stopping you" in TALK_ONLY_NOTE


def test_turn_zero_promise_note_offers_the_honest_out_and_its_line_is_said(tmp_path):
    from brain.agent import PROMISE_NOTE
    r = Replay(tmp_path, STATES[5], tools=TOOLS)
    r.model.replies["get some sleep"] = FakeLLM.say("heading to a flat spot for the shelter")
    r.model.turns = [FakeLLM.say("actually can't pick a flat spot from here, no ground info")]
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude get some sleep"})
    r.at(0).step()
    assert PROMISE_NOTE in _notes(r) and "what's stopping you" in PROMISE_NOTE
    assert r.body.said == ["heading to a flat spot for the shelter",
                           "actually can't pick a flat spot from here, no ground info"]


def _stop_rig(tmp_path, monkeypatch, after_note):
    """Build run 2026-11-01 20:29:57Z (logs/brain-live-20261101-212535-10756.jsonl, its last two turns): "... second
    piece won't seat. I'll keep at it" came with a call, the next turn returned nothing, and the request ended.
    The live say channel: only say calls are heard."""
    monkeypatch.setenv("DW_SPEECH_CHANNEL", "say")
    r = Replay(tmp_path, STATES[5], tools=TOOLS)
    for _ in range(3):
        r.body.act("go_to", ok(target="Zezima"))
    r.model.replies["build me a house"] = FakeLLM.say("", FakeLLM.call("go_to", target="Zezima"))
    r.model.turns = [FakeLLM.say("", FakeLLM.call("go_to", target="Zezima"),
                                 FakeLLM.call("say", text="roof only covers part, second piece won't seat. I'll keep at it")),
                     FakeLLM.say(""),  # stops: no call, nothing said
                     after_note, FakeLLM.say(""), FakeLLM.say("")]
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude build me a house"})
    r.at(0).step()
    return r


def test_a_chain_turn_that_stops_right_after_his_line_is_told_once_and_may_go_on(tmp_path, monkeypatch):
    from brain.agent import STOP_NOTE
    r = _stop_rig(tmp_path, monkeypatch, FakeLLM.say("", FakeLLM.call("go_to", target="Zezima")))
    stops = [n for n in _notes(r) if n.startswith(STOP_NOTE.split("{")[0])]
    assert len(stops) == 1 and "I'll keep at it" in stops[0]
    assert [c[0] for c in r.body.calls] == ["go_to", "go_to", "go_to"]  # the model chose to keep at it
    assert r.body.said == ["roof only covers part, second piece won't seat. I'll keep at it"]  # code said nothing


def test_the_stop_check_is_one_call_and_the_model_may_end_there(tmp_path, monkeypatch):
    from brain.agent import STOP_NOTE
    r = _stop_rig(tmp_path, monkeypatch, FakeLLM.say(""))
    assert sum(n.startswith(STOP_NOTE.split("{")[0]) for n in _notes(r)) == 1
    assert [c[0] for c in r.body.calls] == ["go_to", "go_to"] and len(r.body.said) == 1

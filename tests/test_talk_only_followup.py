"""GOAL M1 talk_without_action: a talk-only FOLLOW-UP turn (after tool results) gets one more model call
before its line is said (controller.TALK_ONLY_NOTE), so a line like "it's raw, I'll look for a fire"
(live 21:17:50, after a pickup) comes with its tool call. Decided on the reply's shape only (text and no
tool call), never its words; the model's answer is used as it is. The agent's first-turn check
(agent.PROMISE_NOTE) is not doubled."""
from __future__ import annotations

from brain.controller import TALK_ONLY_NOTE
from brain.interface import ok
from brain.llm import FakeLLM, LLMResponse

from test_event_hygiene import STATES, Replay

MEAT = "BP_RuntimeSpawnedWorldItem_C_2147464905"
TOOLS = {"get_state", "say", "follow", "go_to", "stop", "interact", "cast"}


def _rig(tmp_path):
    r = Replay(tmp_path, STATES[5], tools=TOOLS)
    r.body.act("interact", ok(target=MEAT))
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
    r.model.turns = [FakeLLM.say("it's raw, I'll find a fire for it"),  # after the pickup: talk only
                     FakeLLM.say("", FakeLLM.call("go_to", target="Zezima")),  # the check turn: the call
                     FakeLLM.say("")]  # after the walk: nothing to add
    _run(r)
    assert [c[0] for c in r.body.calls] == ["interact", "go_to"]
    assert r.body.said == ["it's raw, I'll find a fire for it"]  # one line, kept as the model wrote it
    tl = r.body.timeline
    assert tl.index(("say", "it's raw, I'll find a fire for it")) < tl.index(("call", "go_to"))
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

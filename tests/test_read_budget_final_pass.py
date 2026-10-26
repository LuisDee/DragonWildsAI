"""Read budget final pass (live 22:20:15, review-0006: look, look, inventory, then the read budget ran out,
nothing was done and a template spoke a raw failure with an engine id). Now the over-budget reads are
answered "not run" and ONE final call is made with only the acting tools offered (LangChain early_stopping_method="generate",
adapted): the model acts on what it found or replies. A budget, not a veto."""
from __future__ import annotations

from brain.controller import FINAL_PASS_NOTE
from brain.interface import ok
from brain.llm import FakeLLM

from test_event_hygiene import STATES, Replay

WATER = "BP_WaterVolume_C_UAID_00BE4395530E72EB01_2108496385"
TOOLS = {"get_state", "say", "follow", "go_to", "stop", "interact", "look"}


def _rig(tmp_path, final):
    r = Replay(tmp_path, STATES[5], tools=TOOLS)
    r.body.look_things = [{"name": "Water Volume", "id": WATER, "distance": 3.2, "actions": ["interact"]}]
    r.model.replies["get a drink"] = FakeLLM.say("", FakeLLM.call("look", about="water"))
    r.model.turns = [FakeLLM.say("", FakeLLM.call("look", about="pond")),
                     FakeLLM.say("", FakeLLM.call("look", about="river")), final]
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude get a drink"})
    return r


def _final_call(r):
    return next(c for c in r.model.calls if c["messages"][-1].get("content") == FINAL_PASS_NOTE)


def test_a_turn_that_only_looked_gets_one_acting_call(tmp_path):
    r = _rig(tmp_path, FakeLLM.say("", FakeLLM.call("interact", target=WATER)))
    r.body.act("interact", ok(target=WATER))
    r.at(0).step()
    assert [c[0] for c in r.body.calls] == ["interact"]
    final = _final_call(r)
    offered = {t["function"]["name"] for t in final["tools"]}
    assert "look" not in offered and "interact" in offered
    assert final["messages"][-2]["role"] == "tool" and "not run" in final["messages"][-2]["content"]
    row = r.records("controller_final_pass")[0]
    assert row["ok"] and row["actions"] == ["interact"]


def test_the_final_call_may_reply_instead_and_its_line_is_said(tmp_path):
    r = _rig(tmp_path, FakeLLM.say("can't find any water close by, got a drink?"))
    r.at(0).step()
    assert r.body.calls == [] and r.body.said[0] == "can't find any water close by, got a drink?"


def test_a_failed_final_call_ends_the_turn_as_before(tmp_path):
    r = _rig(tmp_path, FakeLLM.say(""))
    orig = r.model.complete

    def complete(messages, tools=None):
        if messages[-1].get("content") == FINAL_PASS_NOTE:
            raise RuntimeError("provider down")
        return orig(messages, tools)
    r.model.complete = complete
    r.at(0).step()
    assert r.body.calls == [] and "provider down" in r.records("controller_final_pass")[0]["error"]


def test_no_final_pass_when_the_model_acts_within_budget(tmp_path):
    r = Replay(tmp_path, STATES[5], tools=TOOLS)
    r.body.look_things = [{"name": "Water Volume", "id": WATER, "distance": 3.2, "actions": ["interact"]}]
    r.body.act("interact", ok(target=WATER))
    r.model.replies["get a drink"] = FakeLLM.say("", FakeLLM.call("look", about="water"))
    r.model.turns = [FakeLLM.say("", FakeLLM.call("interact", target=WATER))]
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude get a drink"})
    r.at(0).step()
    assert [c[0] for c in r.body.calls] == ["interact"] and r.records("controller_final_pass") == []

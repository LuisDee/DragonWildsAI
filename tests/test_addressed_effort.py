"""Addressed chat can run at a higher effort (DW_CONTROLLER_EFFORT_ADDRESSED, e.g. medium;
off by default until it passes the latency budget); everything else stays at the client's own effort (low). Anthropic's effort docs for Haiku 5.5: low for chat and short tool tasks,
but in long agent prompts low is more likely to skip a search, stop early or skip a check. The level is
held for the whole request (follow-up turns, the promise check) and restored afterwards."""
from __future__ import annotations

import pytest

from brain import controller as ctl_mod
from brain.interface import ok
from brain.llm import FakeLLM, LLMResponse

from test_event_hygiene import STATES, Replay, _proactive_rig, _vitals_state


@pytest.fixture(autouse=True)
def _medium(monkeypatch):
    monkeypatch.setenv(ctl_mod.ADDRESSED_EFFORT_ENV, "medium")


def test_off_by_default(tmp_path, monkeypatch):
    monkeypatch.delenv(ctl_mod.ADDRESSED_EFFORT_ENV)
    assert Replay(tmp_path, STATES[5]).controller.addressed_effort is None


def _record(model):
    model.kwargs = {"max_tokens": 1024, "output_config": {"effort": "low"}}
    seen = []
    orig = model.complete

    def complete(messages, tools=None):
        seen.append(model.kwargs["output_config"]["effort"])
        return orig(messages, tools)
    model.complete = complete
    return seen


def test_a_players_line_runs_at_medium_for_the_whole_request_then_low_again(tmp_path):
    r = Replay(tmp_path, STATES[5])
    seen = _record(r.model)
    r.body.act("go_to", ok(target="Zezima"))
    r.model.replies["come here"] = FakeLLM.say("", FakeLLM.call("go_to", target="Zezima"))
    r.model.turns = [LLMResponse(content="")]
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude come here"})
    r.at(0).step()
    assert seen == ["medium", "medium"]  # the decision and its follow-up turn
    assert r.model.kwargs["output_config"]["effort"] == "low"
    prompts = [x for x in r.records("prompt") if x.get("component") == "controller"]
    assert {p["effort"] for p in prompts} == {"medium"}


def test_a_body_situation_stays_at_low(tmp_path):
    r = _proactive_rig(tmp_path, said="")
    seen = _record(r.model)
    r.body.state = _vitals_state(25, phase="night", sleep_allowed=True)
    r.at(40).step()
    assert seen and set(seen) == {"low"}


def test_the_env_var_turns_it_off(tmp_path, monkeypatch):
    monkeypatch.setenv(ctl_mod.ADDRESSED_EFFORT_ENV, "")
    r = Replay(tmp_path, STATES[5])
    seen = _record(r.model)
    r.model.replies["how are you"] = FakeLLM.say("good, you?")
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude how are you"})
    r.at(0).step()
    assert seen and set(seen) == {"low"}


def test_a_client_without_effort_is_left_alone(tmp_path):
    r = Replay(tmp_path, STATES[5])  # FakeModel: no kwargs at all
    r.model.replies["how are you"] = FakeLLM.say("good, you?")
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude how are you"})
    r.at(0).step()
    assert r.body.said[0] == "good, you?"


def test_warm_up_warms_both_cache_entries(tmp_path):
    r = Replay(tmp_path, STATES[5])
    r.model.kwargs = {"max_tokens": 1024, "output_config": {"effort": "low"}}
    efforts = []
    r.model.warm = lambda messages, tools: (efforts.append(r.model.kwargs["output_config"]["effort"]), {"s": 0.1})[1]
    r.controller.warm_up()
    assert efforts == ["low", "medium"] and r.model.kwargs["output_config"]["effort"] == "low"
    rows = r.records("llm_warmup")
    assert [x.get("effort") for x in rows][-1] == "medium"

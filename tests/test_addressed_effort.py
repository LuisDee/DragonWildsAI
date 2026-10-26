"""Addressed chat can run at a higher effort (DW_CONTROLLER_EFFORT_ADDRESSED, e.g. medium;
off by default until it passes the latency budget); everything else stays at the client's own effort (low).
Anthropic's effort docs for Haiku 5.5: low for chat and short tool tasks, but in long agent prompts low is
more likely to skip a search, stop early or skip a check. The level is held for the whole request (follow-up
turns, the promise check) and passed per call (LLMClient.complete(effort=)); the client's default is untouched."""
from __future__ import annotations

import pytest

from brain import controller as ctl_mod
from brain.interface import ok
from brain.llm import FakeLLM, LiteLLMClient, LLMResponse

from test_event_hygiene import STATES, FakeModel, Replay, _proactive_rig, _vitals_state


class EffortModel(FakeModel):
    """The replay model, with a client default effort and the per-call override recorded."""
    effort = "low"

    def __init__(self):
        super().__init__()
        self.efforts: list[str] = []
        self.warmed: list[str] = []

    def complete(self, messages, tools=None, effort=None):
        self.efforts.append(effort or self.effort)
        return super().complete(messages, tools)

    def warm(self, messages, tools=None, effort=None):
        self.warmed.append(effort or self.effort)
        return {"s": 0.1}


@pytest.fixture(autouse=True)
def _medium(monkeypatch):
    monkeypatch.setenv(ctl_mod.ADDRESSED_EFFORT_ENV, "medium")


def _rig(tmp_path):
    r = Replay(tmp_path, STATES[5])
    r.model = r.controller.llm = EffortModel()
    return r


def test_off_by_default(tmp_path, monkeypatch):
    monkeypatch.delenv(ctl_mod.ADDRESSED_EFFORT_ENV)
    assert Replay(tmp_path, STATES[5]).controller.addressed_effort is None


def test_a_players_line_runs_at_medium_for_the_whole_request(tmp_path):
    r = _rig(tmp_path)
    r.body.act("go_to", ok(target="Zezima"))
    r.model.replies["come here"] = FakeLLM.say("", FakeLLM.call("go_to", target="Zezima"))
    r.model.turns = [LLMResponse(content="")]
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude come here"})
    r.at(0).step()
    assert r.model.efforts == ["medium", "medium"]  # the decision and its follow-up turn
    prompts = [x for x in r.records("prompt") if x.get("component") == "controller"]
    assert {p["effort"] for p in prompts} == {"medium"}  # what was actually sent


def test_a_body_situation_stays_at_the_client_default(tmp_path):
    r = _proactive_rig(tmp_path, said="")
    r.model = r.controller.llm = EffortModel()
    r.body.state = _vitals_state(25, phase="night", sleep_allowed=True)
    r.at(40).step()
    assert r.model.efforts and set(r.model.efforts) == {"low"}
    prompts = [x for x in r.records("prompt") if x.get("component") == "controller"]
    assert {p["effort"] for p in prompts} == {"low"}


def test_the_env_var_turns_it_off(tmp_path, monkeypatch):
    monkeypatch.setenv(ctl_mod.ADDRESSED_EFFORT_ENV, "")
    r = _rig(tmp_path)
    r.model.replies["how are you"] = FakeLLM.say("good, you?")
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude how are you"})
    r.at(0).step()
    assert r.model.efforts and set(r.model.efforts) == {"low"}


def test_warm_up_warms_both_levels(tmp_path):
    r = _rig(tmp_path)
    r.controller.warm_up()
    assert r.model.warmed == ["low", "medium"]
    assert [x.get("effort") for x in r.records("llm_warmup")] == ["low", "medium"]


def test_litellm_client_sends_the_per_call_effort_and_keeps_its_default(monkeypatch):
    import sys
    import types
    seen = []
    fake = types.SimpleNamespace(completion=lambda **kw: seen.append(kw) or types.SimpleNamespace(
        choices=[types.SimpleNamespace(message=types.SimpleNamespace(content="", tool_calls=None))], usage=None))
    monkeypatch.setitem(sys.modules, "litellm", fake)
    c = LiteLLMClient("anthropic/claude-haiku-5-5", max_tokens=1024, output_config={"effort": "low"})
    c.complete([{"role": "user", "content": "x"}], effort="medium")
    c.complete([{"role": "user", "content": "x"}])
    assert [k["output_config"]["effort"] for k in seen] == ["medium", "low"]
    assert c.kwargs["output_config"] == {"effort": "low"} and c.effort == "low"

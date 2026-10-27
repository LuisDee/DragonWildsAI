"""Speech is an explicit channel (single voice): only a say call's text is heard; the model's free text is a
private note, logged and never said (A/B 2026-10-26: with thinking off, Haiku wrote its reasoning there)."""
import json

import pytest
from conftest import Rig

from brain.controller import SAY_TOOL
from brain.llm import FakeLLM, LLMResponse


@pytest.fixture
def srig(tmp_path, monkeypatch):
    monkeypatch.setenv("DW_SPEECH_CHANNEL", "say")
    r = Rig(tmp_path)
    r.tmp = tmp_path
    return r


def reply(line, *calls, note=None):
    say = [FakeLLM.call("say", text=line)] if line else []
    return LLMResponse(content=note, tool_calls=[*say, *calls])


def rows(r, kind):
    path = r.tmp / "logs" / "brain.jsonl"
    return [d for d in map(json.loads, path.read_text(encoding="utf-8").splitlines()) if d.get("kind") == kind]


def tool_msgs(call, name):
    return [json.loads(m["content"]) for m in call["messages"] if m.get("role") == "tool" and m.get("name") == name]


def test_say_is_offered_and_the_persona_says_only_it_is_heard(srig):
    assert srig.controller.tools[0]["function"]["name"] == SAY_TOOL
    assert "Only the say tool is heard" in srig.controller.persona()


def test_only_the_say_text_is_heard_never_the_free_text(srig):
    srig.game.add_ground_item("oak_log", 2, [1, 0, 0])
    srig.game.player_say("grab those logs")
    srig.controller_llm.push(reply("got em", FakeLLM.call("pickup", target="nearest", item="oak"),
                                   note="HP is at 2%, water at 0. Logs are close, pick up first."))
    srig.agent.step()
    assert srig.calls("pickup") and srig.game.inventory["oak_log"] == 2
    assert srig.companion_said() == ["got em"]
    assert any("HP is at 2%" in d["text"] for d in rows(srig, "controller_note"))


def test_free_text_alone_is_never_said(srig):
    srig.game.player_say("just a test line")
    srig.controller_llm.push(LLMResponse(content="Tester says it's just a test line. No reply needed."))
    srig.agent.step()
    assert not any("Tester" in line for line in srig.companion_said())


def test_a_failure_replaces_the_say_line_and_the_model_hears_it_was_not_said(srig):
    srig.game.player_say("pick up the sticks")
    srig.controller_llm.push(reply("got them", FakeLLM.call("pickup", target="nearest", item="stick")),
                             LLMResponse())  # the follow-up turn says nothing: the template reports the failure
    srig.agent.step()
    said = srig.companion_said()
    assert "got them" not in said and said  # the failure line, never the model's claim
    second = srig.controller_llm.calls[1]
    assert tool_msgs(second, SAY_TOOL) and tool_msgs(second, SAY_TOOL)[0]["ok"] is None


def test_a_say_beside_a_read_is_held_and_answered(srig):
    srig.game.add_ground_item("oak_log", 2, [1, 0, 0])
    srig.game.player_say("any sticks about?")
    srig.controller_llm.push(reply("let me look", FakeLLM.call("look", about="sticks")),
                             reply("no sticks, just oak logs"))
    srig.agent.step()
    second = srig.controller_llm.calls[1]
    held = tool_msgs(second, SAY_TOOL)
    assert held and "not said yet" in held[0]["note"]  # every tool_use gets its tool_result
    said = srig.companion_said()
    assert "no sticks, just oak logs" in said and "let me look" not in said


@pytest.mark.parametrize("check_outcome", ["action", "empty", "error"])
def test_say_only_followup_answers_its_tool_before_the_check(srig, check_outcome):
    """A strict provider rejects unmatched say calls even though the body never executes them."""
    from brain.controller import TALK_ONLY_NOTE

    srig.game.add_ground_item("oak_log", 2, [1, 0, 0])
    srig.game.player_say("grab those logs")
    last = reply(None, FakeLLM.call("go_to", target=[2, 0, 0])) if check_outcome == "action" else LLMResponse()
    srig.controller_llm.push(reply(None, FakeLLM.call("pickup", target="nearest", item="oak")),
                             reply("got the logs"), last, LLMResponse())
    complete = srig.controller_llm.complete
    violations, checks = [], []

    def strict_complete(messages, tools=None, **kwargs):
        pending = set()
        for msg in messages:
            if msg["role"] == "tool":
                pending.discard(msg.get("tool_call_id"))
            else:
                if pending:
                    violations.append(sorted(pending))
                    raise RuntimeError("tool calls without results")
                if msg["role"] == "assistant":
                    pending.update(c["id"] for c in msg.get("tool_calls", []))
        if pending:
            violations.append(sorted(pending))
            raise RuntimeError("tool calls without results")
        if messages[-1].get("content") == TALK_ONLY_NOTE:
            checks.append(messages)
            if check_outcome == "error":
                raise RuntimeError("provider unavailable")
        return complete(messages, tools=tools, **kwargs)

    srig.controller_llm.complete = strict_complete
    srig.agent.step()
    assert not violations
    assert len(checks) == 1
    assert any("not said yet" in r["note"] for r in tool_msgs({"messages": checks[0]}, SAY_TOOL))
    assert srig.companion_said() == ["got the logs"]
    assert bool(srig.calls("go_to")) == (check_outcome == "action")

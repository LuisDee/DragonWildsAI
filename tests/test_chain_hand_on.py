"""A request's chain that runs out of turns is handed on, and follow-up turns see fresh perception.

Live 2026-11-01 (quest runs): (1) the 8th follow-up turn cast Summon Shelter "to rest", the chain stopped on its
turn budget, and he stood 194 s, silent, to the end of the run; (2) after a failed go_to to a remembered grave the
follow-up turns carried only tool results, and he said the graves were out of reach with his gravestone 1.4 m away.
These drive the REAL LiveAgent / Controller / Executor with the deterministic FakeModel (what reaches the model and
what is said; never what a real model would choose).
"""
from __future__ import annotations

import json

from brain.agent import CHAIN_BUDGET, MAX_HAND_ONS, MAX_TURNS
from brain.interface import ok
from brain.llm import FakeLLM, LLMResponse

from test_event_hygiene import INFUSION, STATES, Replay

TOOLS = {"get_state", "say", "follow", "go_to", "stop", "interact"}


def _grabbing(tmp_path, body_turns: int):
    r = Replay(tmp_path, STATES[5], tools=TOOLS)
    for _ in range(40):
        r.body.act("interact", ok(target=INFUSION))
    r.model.replies["keep grabbing"] = FakeLLM.say("On it.", FakeLLM.call("interact", target=INFUSION))
    r.model.turns = [FakeLLM.say("", FakeLLM.call("interact", target=INFUSION)) for _ in range(body_turns)]
    return r


def test_a_chain_out_of_turns_is_handed_on_with_its_last_results(tmp_path):
    r = _grabbing(tmp_path, MAX_TURNS)
    seen = []
    r.model.body_reply = lambda ctx: (seen.append(ctx["body_event"]), LLMResponse(content=""))[1]
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude keep grabbing"})
    r.at(0).step()
    assert r.records("chain_stopped")[0]["why"] == "budget"
    assert r.records("chain_handed_on")[0]["hand_on"] == 1
    # the next run is the model's: it hears what was asked and how its last (unseen) calls went
    ev = seen[0]
    assert ev["type"] == CHAIN_BUDGET and ev["request"] == "claude keep grabbing" and ev["from"] == "Zezima"
    lr = ev["last_results"]
    assert len(lr) == 1 and lr[0]["tool"] == "interact" and lr[0]["args"]["target"] == INFUSION and lr[0]["ok"] is True
    assert ev["hand_on"] == 1 and ev["of"] == MAX_HAND_ONS
    # the model chose silence and no action in that run: code doesn't talk over it
    assert r.body.said == ["On it."]


def test_hand_ons_are_capped_and_the_last_one_never_ends_silent(tmp_path):
    turns = MAX_TURNS * (1 + MAX_HAND_ONS) + MAX_HAND_ONS  # every run's follow-ups keep grabbing
    r = _grabbing(tmp_path, turns)
    r.model.body_reply = lambda ctx: FakeLLM.say("", FakeLLM.call("interact", target=INFUSION))
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude keep grabbing"})
    for t in range(0, 4):
        r.at(t).step()
    assert [x["hand_on"] for x in r.records("chain_handed_on")] == list(range(1, MAX_HAND_ONS + 1))
    assert len(r.records("chain_stopped")) == 1 + MAX_HAND_ONS
    # the last run used its turns and said nothing: he says he stopped partway, and what on
    assert r.body.said[0] == "On it."
    assert len(r.body.said) == 2 and "stopped partway through 'claude keep grabbing'" in r.body.said[1]


def test_follow_up_turns_carry_the_situation_summary(tmp_path):
    r = Replay(tmp_path, STATES[5], tools=TOOLS)
    r.body.act("interact", ok(target=INFUSION))
    r.body.act("interact", ok(target=INFUSION))
    r.model.replies["grab that"] = FakeLLM.say("On it.", FakeLLM.call("interact", target=INFUSION))
    r.model.turns = [FakeLLM.say("", FakeLLM.call("interact", target=INFUSION)), LLMResponse(content="")]
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude grab that"})
    r.at(0).step()
    obs = [json.loads(m["content"].split("Current observation: ", 1)[1])
           for c in r.model.calls for m in c["messages"][-2:-1]
           if m["role"] == "user" and str(m["content"]).startswith("Current observation: ")]
    assert len(obs) == 2
    first_lines = r.model.contexts[0]["situation"]
    # the same lines the first turn had (the state did not change), then "unchanged" rather than a repeat
    assert obs[0]["situation"] in (first_lines, "unchanged since you last saw it")
    assert obs[1]["situation"] == "unchanged since you last saw it"


def test_a_changed_situation_is_shown_again(tmp_path):
    import copy
    r = Replay(tmp_path, STATES[5], tools=TOOLS)
    moved = copy.deepcopy(STATES[5])
    moved["position"] = [p + 40.0 for p in moved["position"][:2]] + [moved["position"][2]]
    moved["nearby_items"] = []
    r.body.act("interact", ok(target=INFUSION), state_after=moved)
    r.model.replies["grab that"] = FakeLLM.say("On it.", FakeLLM.call("interact", target=INFUSION))
    r.model.turns = [LLMResponse(content="")]
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude grab that"})
    r.at(0).step()
    follow = r.model.calls[-1]["messages"]
    obs = json.loads(next(m["content"] for m in reversed(follow) if str(m.get("content", "")).startswith("Current observation: "))
                     .split("Current observation: ", 1)[1])
    assert isinstance(obs["situation"], list) and obs["situation"] != r.model.contexts[0]["situation"]


def test_where_he_was_asked_stays_in_the_situation_and_goes_with_a_hand_on(tmp_path):
    """"here" names where he stood when asked (live 21:13Z: he gathered, then built 31 m away): the request's
    context keeps that position, every turn's situation shows it, and a hand-on carries it into the fresh run."""
    r = _grabbing(tmp_path, MAX_TURNS)
    seen = []
    r.model.body_reply = lambda ctx: (seen.append(ctx), LLMResponse(content=""))[1]
    r.body.emit({"type": "chat_heard", "player": "Zezima", "text": "claude keep grabbing here"})
    r.at(0).step()
    asked = next(line for line in r.model.contexts[0]["situation"] if line.startswith("Asked:"))
    assert asked.startswith('Asked: "claude keep grabbing here" when you stood at (59, 1880, -36), 0 m from where you are now; Zezima was at')
    ev = seen[0]["body_event"]
    assert ev["asked_at"]["position"] == [58.9, 1880.0, -35.5] and ev["asked_at"]["request"] == "claude keep grabbing here"
    assert any(line.startswith('Asked: "claude keep grabbing here"') for line in seen[0]["situation"])

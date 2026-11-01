"""tools/replay_first_call.py on a tiny synthetic ladder + brain log (no Lua, no API calls): extract keeps only the first
full Controller prompt of each leg's chat- episode, scoring wants go_to naming the place first (say aside), and the
replay sends today's system prompt with the episode's own user message."""
from __future__ import annotations

import json
from pathlib import Path

from brain.controller import Controller
from brain.jsonl_log import JsonlLogger
from brain.llm import FakeLLM
from brain.mock import MockGame
from brain.state_store import StateStore
from tools import replay_first_call as rfc

TOOLS = [{"type": "function", "function": {"name": "look", "description": "Read-only.", "parameters": {}}},
         {"type": "function", "function": {"name": "go_to", "description": "Walk.", "parameters": {}}}]


def user(text: str, n: int = 0) -> dict:
    return {"role": "user", "content": json.dumps({"command": {"player": "Tester", "text": text, "addressed": True},
                                                   "situation": [f"You: healthy {n}"]})}


def prompt(ep: str, text: str, step=0, **extra) -> dict:
    return {"kind": "prompt", "component": "controller", "model": "anthropic/claude-haiku-5-5", "step": step,
            "effort": "low", "settings": {"max_tokens": 1024}, "episode_id": ep, "tools": TOOLS,
            "messages": [{"role": "system", "content": "OLD PERSONA"}, user(text)], **extra}


def answer(ep: str, *calls, step=0) -> dict:
    return {"kind": "llm_response", "component": "controller", "step": step, "episode_id": ep,
            "tool_calls": [{"name": n, "arguments": a, "id": f"t{i}"} for i, (n, a) in enumerate(calls)]}


def write(path: Path, rows: list[dict]) -> None:
    path.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")


def rig(tmp_path: Path) -> tuple[Path, Path]:
    logs = tmp_path / "logs"
    logs.mkdir()
    write(logs / "brain-live-a.jsonl", [
        {"kind": "session_start", "player": "Tester", "name": "Claude", "director": False, "companion_sha": "abc"},
        prompt("chat-0001-aaaa", "claude meet me at Doric"),
        answer("chat-0001-aaaa", ("go_to", {"target": "Doric"}), ("say", {"text": "on my way"})),
        # a later call of the same episode (only the added messages): never a case
        {**prompt("chat-0001-aaaa", "x", step="turn0"), "messages_from": 2, "tools": None},
        answer("chat-0001-aaaa", ("say", {"text": "here"}), step="turn0"),
        prompt("review-0002-bbbb", ""),  # a situation review: not a chat request
        answer("review-0002-bbbb", ("say", {"text": "thirsty"})),
        prompt("chat-0003-cccc", "claude head over to the Water Anima Vent"),
        answer("chat-0003-cccc", ("look", {"about": "Water Anima Vent"})),
    ])
    ladder = tmp_path / "chat_ladder.jsonl"
    leg1 = {"run_id": "cl-1", "journey": "near_doric", "line": "claude meet me at Doric", "place": "Doric",
            "calls_by_episode": {"chat-0001-aaaa": 2}, "brain_log": "brain-live-a.jsonl"}
    leg2 = {"run_id": "cl-1", "journey": "around_water", "line": "claude head over to the Water Anima Vent",
            "place": "the Water Anima Vent", "calls_by_episode": {"review-0002-bbbb": 1, "chat-0003-cccc": 3},
            "brain_log": "brain-live-a.jsonl"}
    skipped = {"run_id": "cl-1", "journey": "ramp_up", "skipped": True, "brain_log": "brain-live-a.jsonl"}
    gone = {**leg1, "brain_log": "brain-live-missing.jsonl"}
    write(ladder, [leg1, skipped, leg2, leg1, gone])  # leg1 twice: one case
    with ladder.open("a", encoding="utf-8") as f:
        f.write('{"run_id": "cl-2", "torn')  # a live run still appending
    return ladder, logs


def test_extract_first_chat_prompt_per_leg(tmp_path):
    ladder, logs = rig(tmp_path)
    cases, why = rfc.extract(ladder, logs)
    assert [c["id"] for c in cases] == ["cl-1/chat-0001-aaaa", "cl-1/chat-0003-cccc"]
    assert why["duplicate"] == 1 and why["no_chat_episode"] == 1 and why["no_brain_log"] == 1
    doric, vent = cases
    assert doric["expected"] == {"tool": "go_to", "target": "Doric"}
    assert doric["player"] == "Tester" and doric["run_id"] == "cl-1" and doric["journey"] == "near_doric"
    assert [m["role"] for m in doric["messages"]] == ["user"]  # the system prompt is re-rendered, not kept
    assert json.loads(doric["messages"][0]["content"])["command"]["text"] == "claude meet me at Doric"
    assert doric["logged"]["tools"] == ["look", "go_to"] and doric["logged"]["tools_sha"] == rfc.sha(TOOLS)
    assert doric["live"]["passed"] and doric["live"]["calls"] == 2
    assert not vent["live"]["passed"] and vent["live"]["first"] == "look"
    out = tmp_path / "cases.jsonl"
    rfc.write_cases(cases, out)
    assert [json.loads(x)["id"] for x in out.read_text(encoding="utf-8").splitlines()] == [c["id"] for c in cases]


def test_score_go_to_naming_the_place_first():
    go = lambda t: {"name": "go_to", "arguments": {"target": t}}  # noqa: E731
    say = {"name": "say", "arguments": {"text": "on my way"}}
    look = {"name": "look", "arguments": {}}
    assert rfc.score("the Water Anima Vent", [go("Water Anima Vent"), say])["passed"]
    assert rfc.score("the Water Anima Vent", [say, go("the water anima vent")])["passed"]  # say is not a step
    assert rfc.score("Doric", [go("Doric's house")])["passed"]
    assert rfc.score("the temple entrance", [go("Temple Woods entrance")])["passed"]
    assert not rfc.score("Doric", [go("Vannaka")])["passed"]
    assert not rfc.score("the Earth Anima Vent", [go("Anima Vent")])["passed"]  # which vent? not named
    assert not rfc.score("the lodestone by Wise Old Man", [go("Wise Old Man")])["passed"]  # the NPC, not the stone
    # a go_to by id names the place when the request's own rows do (references, "Name (16 m, id X)" entries)
    msgs = [{"role": "user", "content": json.dumps({
        "references": [{"said": "vannaka", "matches": [{"name": "Vannaka", "id": "SkeletalMeshActor_1"}]}],
        "situation": ["Usable: Zanik (1 m, id BP_NPC_Zanik_C_1, Talk); Anima Vent (16 m, id BP_AnimaVent_C_2, ?)"]})}]
    assert rfc.score("Vannaka", [go("SkeletalMeshActor_1")], msgs)["passed"]
    assert rfc.score("Zanik", [go("BP_NPC_Zanik_C_1")], msgs)["passed"]
    assert not rfc.score("the Earth Anima Vent", [go("BP_AnimaVent_C_2")], msgs)["passed"]
    assert not rfc.score("Vannaka", [go("SkeletalMeshActor_1")])["passed"]  # no rows, no name
    r = rfc.score("Zanik", [look, go("Zanik"), say])
    assert not r["passed"] and r["first"] == "look" and r["one_call"]  # read beside the action: still one call
    r = rfc.score("Zanik", [say])
    assert not r["passed"] and r["first"] is None and r["tools"] == ["say"]


def test_replay_sends_todays_persona_with_the_logged_user_message(tmp_path):
    ladder, logs = rig(tmp_path)
    cases, _ = rfc.extract(ladder, logs)
    llms = []

    def make(player, name):
        llm = FakeLLM([FakeLLM.say("", FakeLLM.call("go_to", target="Doric")),
                       FakeLLM.say("", FakeLLM.call("look", about="vent"))])
        llms.append(llm)
        return Controller(llm, MockGame.default_world(), StateStore(tmp_path / "state"),
                          JsonlLogger(tmp_path / "replay.jsonl"), name=name, player=player)

    results = rfc.replay(cases, make)
    assert len(llms) == 1  # one Controller per player
    first = llms[0].calls[0]
    ctl_persona = first["messages"][0]["content"]
    assert ctl_persona != "OLD PERSONA" and "Tester" in ctl_persona
    assert first["messages"][1] == cases[0]["messages"][0]
    assert {t["function"]["name"] for t in first["tools"]} >= {"go_to"}  # today's tool list, not the logged two
    assert [r["passed"] for r in results] == [True, False]
    assert results[1]["first"] == "look" and results[0]["same_prompt_as_live"] is False
    assert rfc.select(cases, None, True, 5) == [cases[1]]  # --live-misses
    assert rfc.select(cases, "water", False, 0) == [cases[1]]

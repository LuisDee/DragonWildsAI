"""The pure parts of tools/replay_open_ask.py: facts, variant messages, the rubric and the tally. No model calls."""
from __future__ import annotations

import json

from tools import replay_open_ask as roa


def _state(inv=None, gear=None, quests=None, graves=None, items=None):
    return {"inventory": inv or {}, "gear": gear or {}, "quests": quests or {"active": [], "complete": []},
            "graves_remembered": graves or [], "inventory_items": items or [], "nearby_entities": [],
            "position": [0.0, 0.0, 0.0], "health": 100.0}


def test_changes_reports_bag_worn_and_quest_step():
    before = _state({"ITEM_A": 2}, {"held_right": None},
                    {"active": [{"quest": "Rune Mysteries", "step": "Speak to Zanik."}], "complete": []},
                    items=[{"item": "ITEM_A", "name": "Ash Logs"}])
    after = _state({"ITEM_A": 52, "ITEM_B": 1}, {"held_right": "ITEM_B"},
                   {"active": [{"quest": "Rune Mysteries", "step": "Mine Rune Essence."}], "complete": []},
                   items=[{"item": "ITEM_A", "name": "Ash Logs"}, {"item": "ITEM_B", "name": "Bronze Sword"}])
    c = roa.changes(before, after)
    assert c["bag"] == {"Ash Logs": "+50", "Bronze Sword": "+1"}
    assert c["worn"] == {"right_hand": "nothing -> Bronze Sword"}
    assert c["quests"] == {"Rune Mysteries": "Speak to Zanik. -> Mine Rune Essence."}


def test_changes_says_no_change_and_a_completed_part_that_goes_on():
    q0 = {"active": [{"quest": "Q", "step": "one"}], "complete": []}
    q1 = {"active": [{"quest": "Q", "step": "two"}], "complete": ["Q"]}
    c = roa.changes(_state(quests=q0), _state(quests=q1))
    assert c["bag"] == "no change" and c["worn"] == "no change"
    assert c["quests"]["Q"].startswith("completed (still active: two)")


def _case(live=None, side="open"):
    return {"id": "x:chat-1", "side": side, "player": "Tester", "words": "do her quest", "age_s": 40,
            "changes": {"bag": "no change"}, "end_state": {"quest_log": {"active": [], "complete": ["Q"]}},
            "state_now": _state(), "messages": [{"role": "system", "content": "s"}, {"role": "user", "content": "u"}],
            "live": live or {"content": None, "tool_calls": []}, "tools": [{"type": "function",
                                                                           "function": {"name": "go_to"}}],
            "settings": {}}


def test_a1_is_the_logged_call_unchanged():
    c = _case()
    msgs, tools = roa.build_request(c, "A1")
    assert msgs == c["messages"] and tools == c["tools"]


def test_b_adds_the_silent_turn_an_observation_and_the_open_ask_with_no_instruction():
    msgs, tools = roa.build_request(_case(), "B")
    assert msgs[2] == {"role": "assistant", "content": ""}
    assert msgs[3]["content"].startswith("Current observation: ")
    last = msgs[-1]["content"]
    assert last.startswith("Open request: ")
    block = json.loads(last[len("Open request: "):])["open_request"]
    assert block == {"player": "Tester", "words": "do her quest", "asked_s_ago": 40,
                     "changed_since_asked": {"bag": "no change"}}
    assert tools == _case()["tools"]


def test_a_silent_say_gets_its_result_before_the_next_messages():
    live = {"content": None, "tool_calls": [{"name": "say", "arguments": {"text": "done"}, "id": "t1"}]}
    msgs, _ = roa.build_request(_case(live), "B")
    assert msgs[2]["tool_calls"][0]["id"] == "t1"
    assert msgs[3] == {"role": "tool", "tool_call_id": "t1", "content": json.dumps({"ok": True, "note": "said"})}


def test_c_offers_the_two_closing_tools_and_d_carries_the_end_state():
    msgs_c, tools_c = roa.build_request(_case(), "C")
    assert [t["function"]["name"] for t in tools_c][-2:] == ["request_done", "park_request"]
    assert json.loads(msgs_c[-1]["content"][14:])["open_request"]["open_until"]
    msgs_d, tools_d = roa.build_request(_case(), "D")
    assert json.loads(msgs_d[-1]["content"][14:])["open_request"]["game_state_now"]["quest_log"]["complete"] == ["Q"]
    assert len(tools_d) == 1


def test_variant_text_never_tells_him_what_to_do():
    for v in ("B", "C", "D"):
        text = roa.build_request(_case(), v)[0][-1]["content"].lower()
        for word in ("call ", "continue", "next step", "you should", "must", "now,"):
            assert word not in text, (v, word)


def test_outcome_classes():
    o = roa.outcome
    assert o([], None) == "empty"
    assert o([], "nothing to add") == "say"
    assert o([{"name": "say", "arguments": {"text": "hi"}}], None) == "say"
    assert o([{"name": "quests", "arguments": {}}], None) == "read"
    assert o([{"name": "say", "arguments": {}}, {"name": "gather", "arguments": {"resource": "rune_essence"}}], None) == "world"
    assert o([{"name": "consume", "arguments": {"item": "Fillet"}}], None) == "need"
    assert o([{"name": "cast", "arguments": {"spell": "Summon Shelter"}}], None) == "need"
    assert o([{"name": "interact", "arguments": {"target": "BP_Magic_SummonShelter_C_1"}}], None) == "need"
    assert o([{"name": "consume", "arguments": {}}, {"name": "go_to", "arguments": {"target": "Zanik"}}], None) == "world"
    assert o([{"name": "request_done", "arguments": {"evidence": "x"}}], None) == "done_claim"
    assert o([{"name": "park_request", "arguments": {"reason": "x"}}, {"name": "say", "arguments": {}}], None) == "park"


def test_pass_rules_per_side():
    assert roa.passed("open", "world") and not roa.passed("open", "read")
    assert roa.passed("open", "read", lenient=True)
    for out in ("empty", "say", "park", "done_claim", "need"):
        assert not roa.passed("open", out)
        assert roa.passed("done", out)
    assert not roa.passed("done", "world")


def test_table_counts_and_compares_against_a_and_b():
    samples = roa.baseline_rows([{"id": "o", "side": "open"}, {"id": "d", "side": "done"}], 2)
    samples += [{"case": "o", "side": "open", "variant": "B", "outcome": "world", "rep": r} for r in range(2)]
    samples += [{"case": "d", "side": "done", "variant": "B", "outcome": "world", "rep": 0},
                {"case": "d", "side": "done", "variant": "B", "outcome": "empty", "rep": 1}]
    rows = {r["variant"]: r for r in roa.table(samples)}
    assert (rows["A"]["open"]["k"], rows["A"]["open"]["n"]) == (0, 2)
    assert (rows["A"]["done"]["k"], rows["A"]["done"]["n"]) == (2, 2)
    assert (rows["B"]["open"]["k"], rows["B"]["done"]["k"]) == (2, 1)
    assert "p_vs_A" in rows["B"]["open"] and "p_vs_B" not in rows["B"]["open"]


def test_pick_keeps_every_open_case_and_spreads_the_done_ones():
    cases = [{"id": f"o{i}", "side": "open", "item": "Q", "episode": "chat-1"} for i in range(3)]
    cases += [{"id": f"d{i}", "side": "done", "item": it, "episode": ep}
              for i, (it, ep) in enumerate([("Q", "chat-1"), ("Q", "chat-2"), ("Q", "situation-1"), ("R", "chat-3")] * 3)]
    out = roa.pick(cases, done_max=4)
    assert [c["id"] for c in out[:3]] == ["o0", "o1", "o2"]
    done = out[3:]
    assert len(done) == 4 and {(c["item"], c["episode"].split("-")[0]) for c in done} == {
        ("Q", "chat"), ("Q", "situation"), ("R", "chat")}


def test_goal_request_reads_the_ask_a_goal_came_from():
    msg = {"role": "user", "content": json.dumps({"body_event": {"type": "goal_done", "request": "do her quest",
                                                                  "from": "Tester"}})}
    assert roa.goal_request([{"role": "system", "content": "s"}, msg]) == ("Tester", "do her quest")
    assert roa.goal_request([{"role": "user", "content": "{\"body_event\": {\"type\": \"goal_done\"}}"}]) is None


def test_episode_calls_rebuilds_messages_and_keeps_the_tools():
    rows = [{"kind": "prompt", "component": "controller", "episode_id": "e", "messages": [{"role": "user", "content": "a"}],
             "tools": [{"t": 1}], "settings": {"x": 1}, "ts": 1},
            {"kind": "llm_response", "ts": 2, "tool_calls": []},
            {"kind": "prompt", "component": "controller", "episode_id": "e", "messages_from": 1,
             "messages": [{"role": "user", "content": "b"}], "ts": 3},
            {"kind": "llm_response", "ts": 4, "tool_calls": []}]
    calls = roa.episode_calls(rows, "e")
    assert len(calls) == 2 and [m["content"] for m in calls[1][1]] == ["a", "b"] and calls[1][3] == [{"t": 1}]

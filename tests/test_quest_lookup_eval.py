"""tools/quest_lookup_eval.py extract: the prompt after a result that gave a quest step, rebuilt from logged deltas."""
from tools import quest_lookup_eval as e


def test_the_prompt_after_a_given_step_is_rebuilt_in_full_from_its_deltas():
    sys_ = {"role": "system", "content": "persona"}
    rows = [
        {"kind": "prompt", "component": "controller", "episode_id": "chat-1", "ts": 1, "tools": ["T"],
         "messages": [sys_, {"role": "user", "content": "do her quest"}]},
        {"kind": "tool_result", "episode_id": "chat-1", "tool": "talk", "result": {"ok": True, "data": {
            "quests_changed": [{"quest": "Rune Mysteries", "from": "given", "to": "complete"},
                               {"quest": "Rune Mysteries", "from": "ungiven", "to": "given", "step": "Mine Rune Essence"}]}}},
        {"kind": "prompt", "component": "controller", "episode_id": "chat-1", "ts": 2, "messages_from": 2,
         "messages": [{"role": "assistant", "content": None}, {"role": "tool", "content": "talk result"}]},
        {"kind": "prompt", "component": "controller", "episode_id": "chat-1", "ts": 3, "messages_from": 4,
         "messages": [{"role": "user", "content": "later"}]},
    ]
    cases = e.extract_log(rows, "log")
    assert len(cases) == 1 and cases[0]["quests"] == ["Rune Mysteries"] and cases[0]["steps"] == ["Mine Rune Essence"]
    assert [m["role"] for m in cases[0]["messages"]] == ["system", "user", "assistant", "tool"] and cases[0]["tools"] == ["T"]


def test_score_counts_a_lookup_that_names_the_quest():
    s = e.score(["Rune Mysteries"], [{"name": "lookup", "arguments": {"query": "rune mysteries walkthrough"}},
                                     {"name": "gather", "arguments": {}}])
    assert s["lookup"] and s["names_quest"] and s["tools"] == ["lookup", "gather"]
    assert not e.score(["Ratcatcher"], [{"name": "lookup", "arguments": {"query": "rat roast"}}])["names_quest"]

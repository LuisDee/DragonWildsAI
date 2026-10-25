"""Claude reads ALL chat and works out what is meant for him (Luis, 2026-10-25), plus the speech that
goes with body events (unreachable / resumed) and the read-only inventory tool.

Runs the real LiveSession (dry-run rule models) against the fake body over the client endpoint.
"""
import json

import pytest

from brain.dry_run_llm import DryRunController, DryRunPlanner
from brain.fake_body import FakeBody
from brain.interface import ChatHeard, Resumed, Unreachable
from brain.mock import MockGame
from brain.run_live import LiveOptions, LiveSession
from brain.situation import summary
from brain.transport import file_transport_pair


class Rig:
    def __init__(self, tmp_path, calls_per_min: int = 20):
        d = tmp_path / "client_bridge"
        _, body_t = file_transport_pair(d, "client")
        self.game = MockGame.default_world()
        self.body = FakeBody(self.game, body_t).start()
        self.session = LiveSession(LiveOptions(body="client", bridge_dir=d, state_dir=tmp_path / "state",
                                               log_dir=tmp_path / "logs", dry_run=True, wait=5.0, probe_timeout=1.0,
                                               chat_calls_per_min=calls_per_min, chat_debounce_s=0.0),
                                   DryRunController(), DryRunPlanner(), out=lambda s: None)
        self.agent = self.session.agent

    def said(self) -> list[str]:
        return [t for who, t in self.game.chat if who == "companion"]

    def hear(self, player: str, text: str, mentions_me: bool | None = None) -> None:
        self.agent.handle_event(ChatHeard(player=player, text=text, mentions_me=mentions_me))
        self.agent.flush_chat()

    def decisions(self) -> list[tuple[str, str, str]]:
        return [(r["text"], r["decision"], r["reason"]) for r in self.session.log.read_all() if r["kind"] == "chat_decision"]

    def close(self):
        self.body.stop()


@pytest.fixture
def rig(tmp_path):
    r = Rig(tmp_path)
    yield r
    r.close()


def test_named_anywhere_is_addressed(rig):
    rig.hear("Luis", "hello claude what are you wearing")
    assert ("hello claude what are you wearing", "addressed", "named or prefixed") in rig.decisions()
    assert rig.said() and rig.said()[-1].startswith("(dry run) I'm wearing")


def test_follow_up_after_talking_to_claude_is_addressed(rig):
    rig.hear("Luis", "hey claude")
    n = len(rig.said())
    rig.hear("Luis", "ok follow me")  # no name: a follow-up in his conversation with Claude
    assert rig.game.following == "Luis"
    assert len(rig.said()) == n + 1
    # he just answered Luis: Luis's next line counts as addressed (speed plan §2.1), no name needed
    assert ("ok follow me", "addressed", "his conversation partner") in rig.decisions()


def test_friends_talking_among_themselves_are_ignored(rig):
    rig.hear("Bob", "did you see the match last night")
    rig.hear("Ann", "yeah that last goal was crazy")
    assert rig.said() == [] and rig.game.calls == []
    ds = rig.decisions()
    assert ("did you see the match last night", "ignored", "model: not meant for me") in ds
    assert ("yeah that last goal was crazy", "ignored", "model: not meant for me") in ds


def test_group_question_only_if_claude_can_help(rig):
    rig.hear("Bob", "anyone got an axe?")
    assert rig.said() == []  # he has none: stays quiet
    rig.game.inventory["axe"] += 1
    rig.hear("Bob", "anyone got an axe?")
    assert rig.said() == ["(dry run) I've got a axe."]


def test_ping_without_model_and_rate_cap(tmp_path):
    rig = Rig(tmp_path, calls_per_min=1)
    try:
        rig.hear("Luis", "!ping")
        assert rig.said() == ["pong"]
        assert not [r for r in rig.session.log.read_all() if r["kind"] == "prompt"], "no model call for !ping"
        rig.hear("Bob", "nice weather today")
        rig.hear("Ann", "it really is")  # over the cap: not even asked
        ds = rig.decisions()
        assert ("!ping", "ping", "!ping (no model)") in ds
        assert ("it really is", "ignored", "rate cap (1 model calls/min)") in ds
    finally:
        rig.close()


def test_burst_is_decided_once(rig):
    agent = rig.agent
    agent.debounce_s = 60.0  # nothing is quiet yet
    for text in ("lol", "that was close", "ok whatever"):
        agent.handle_event(ChatHeard(player="Bob", text=text))
    agent.flush_chat()  # three lines and still noisy: decide now? (cap at 4 lines)
    assert [d for d in rig.decisions() if d[1] != "pending"] == []
    agent.handle_event(ChatHeard(player="Bob", text="brb"))
    agent.flush_chat()  # the fourth line forces a decision on the burst
    ds = rig.decisions()
    # one run with all four lines (streamline step 3): the command text is the whole burst
    assert sum(1 for d in ds if d[1] == "merged") == 3
    assert ("lol / that was close / ok whatever / brb", "ignored", "model: not meant for me") in ds


def test_unreachable_speaks_the_real_reason_and_found_you_after(rig):
    """A body situation: one model-phrased line (the dry run says the template), per episode and reason."""
    rig.hear("Luis", "claude follow me")
    rig.game.players["Luis"].pos = [40.0, 0.0, 9.0]  # he went up where Claude can't follow
    rig.agent.handle_event(Unreachable(reason="leader_windstepped", detail="dz=6.9m", leader_pos=[40, 0, 9],
                                       my_pos=[1, 2, 3], mode="follow"))
    assert "Windstep" in rig.said()[-1]
    rig.agent.handle_event(Unreachable(reason="leader_windstepped"))  # same episode reported twice: once
    assert sum("Windstep" in s for s in rig.said()) == 1
    rig.agent.handle_event(Unreachable(reason="too_high"))
    assert "too high" in rig.said()[-1]
    rig.agent.handle_event(Resumed())
    assert rig.said()[-1] == "Found you."
    rig.agent.handle_event(Unreachable(reason="weird_new_reason", detail="ledge 4.2 m"))
    assert rig.said()[-1] == "I can't reach you: ledge 4.2 m."
    rig.agent.handle_event(Unreachable(reason="needs:DoubleJump"))
    assert rig.said()[-1] == "I'd need Double Jump to get there, and I can't do that yet."


def test_inventory_read_tool_answers_what_is_in_the_bag(rig):
    rig.game.inventory["oak_log"] += 3
    rig.hear("Luis", "claude what's in your bag")
    calls = [r for r in rig.session.log.read_all() if r["kind"] == "tool_call" and r["tool"] == "inventory"]
    assert calls and calls[0]["read_only"] is True
    assert rig.said()[-1] == "(dry run) I've got oak_log x3."


WORN_STATE = {  # what client_bridge.get_state returned live (gear + loadout names), trimmed
    "health": 100, "max_health": 100, "hydration": 49, "hydration_max": 100, "sustenance": 64, "sustenance_max": 100,
    "held": "Mithril Logging Axe", "held_item": "ITEM_Logging_Axe_Mithril", "position": [69.8, 1870.8, -32.5],
    "inventory": {"ITEM_Dagger_Bone": 1, "ITEM_Pickaxe_Mithril": 1, "ITEM_Logging_Axe_Mithril": 1},
    "gear": {"Head": "ITEM_Armour_T3_Head_HardLeather", "Body": "ITEM_Armour_T3_Body_Bronze",
             "Legs": "ITEM_Armour_T1_Legs_Adventurers", "HeldRight": "ITEM_Logging_Axe_Mithril",
             "HeldLeft": "ITEM_Logging_Axe_Mithril", "held_left": "ITEM_Logging_Axe_Mithril"},
    "inventory_items": [
        {"id": "Loadout:0", "item": "ITEM_Armour_T3_Head_HardLeather", "name": "Hard Leather Cowl", "equipped": True},
        {"id": "Loadout:1", "item": "ITEM_Armour_T3_Body_Bronze", "name": "Bronze Platebody", "equipped": True},
        {"id": "Loadout:2", "item": "ITEM_Armour_T1_Legs_Adventurers", "name": "Adventurer's Leggings", "equipped": True},
        {"id": "QuickAction:3", "item": "ITEM_Logging_Axe_Mithril", "name": "Mithril Logging Axe", "count": 1},
        {"id": "QuickAction:0", "item": "ITEM_Dagger_Bone", "name": "Bone Dagger", "count": 1},
        {"id": "InventoryItems:1", "item": "ITEM_Pickaxe_Mithril", "name": "Mithril Pickaxe", "count": 1}],
    "players": [], "nearby_entities": [], "nearby_resources": [], "nearby_items": [], "structures": [], "places": [],
    "not_implemented": ["places", "structures"],
}


def test_what_are_you_wearing_names_the_worn_gear_and_the_axe():
    """Live bug (19:20): 'claude what are you wearing' got only the bag. The digest now says it."""
    lines = summary(WORN_STATE)
    text = "\n".join(lines)
    assert lines[0].startswith("You: HP 100%, water 49%, food 64%, holding Mithril Logging Axe")
    assert "Wearing: Hard Leather Cowl; Bronze Platebody; Adventurer's Leggings" in text
    assert "Carrying:" in text and "Mithril Pickaxe" in text
    ctx = {"command": {"player": "Zezima", "text": "what are you wearing", "addressed": True}, "situation": lines}
    reply = DryRunController().complete([{"role": "system", "content": ""},
                                         {"role": "user", "content": json.dumps(ctx)}]).content
    for word in ("Cowl", "Platebody", "Leggings", "Axe"):
        assert word in reply, (word, reply)


def test_gather_failure_says_the_bodys_own_sentence(rig):
    rig.session.controller.report_failure("gather", "wrong_tool",
                                         {"why": "tool_tier_too_low", "detail": "My axe is too weak for that yew tree."})
    assert rig.said()[-1] == "My axe is too weak for that yew tree."
    rig.session.controller.report_failure("gather", "nothing_in_range", {"resource": "willow"})
    assert rig.said()[-1] == "There's no willow anywhere near me."

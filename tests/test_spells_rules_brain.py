"""Brain side of spells and reflex rules: the cast tool, the new reasons, the Controller's castable
spell list, and standing orders (set_reflex_rule / list_rules / clear_rule) on the mock and over the
JSONL bridge."""
import copy
import json
import time

import pytest
from conftest import Rig

from brain.bridge_client import BridgeClient
from brain.controller import describe_rule, spell_label
from brain.fake_body import FakeBody
from brain.interface import RULE_TOOLS, SENSABLE_TRIGGERS, TOOLS, Reason, ok, validate_args
from brain.jsonl_log import JsonlLogger
from brain.llm import FakeLLM
from brain.mock import MockGame
from brain.spells import DEFAULT_CATALOG, SpellBook, from_body, from_catalog
from brain.state_store import Task
from brain.transport import file_transport_pair

WINDSTEP_AWAY = dict(enemy="kalphite", trigger={"kind": "telegraph"},
                     actions=[{"kind": "evade"}, {"kind": "cast", "spell": "Windstep", "target": "self"}],
                     note="every time the kalphite raises its claws, windstep away")


def context_of(llm_call: dict) -> dict:
    return json.loads(llm_call["messages"][-1]["content"])


# --------------------------------------------------------------------------- reasons


def test_reason_classes():
    assert Reason.ON_COOLDOWN not in Reason.DETERMINISTIC  # retryable (the executor waits short ones)
    assert {Reason.NOT_UNLOCKED, Reason.UNSAFE, Reason.CANT_SENSE} <= Reason.DETERMINISTIC
    assert "cast" in TOOLS and set(RULE_TOOLS) <= set(TOOLS)


def test_rule_args_schema_only_allows_sensable_triggers():
    clean = validate_args("set_reflex_rule", WINDSTEP_AWAY)
    assert clean["enemy"] == "kalphite" and clean["actions"][1]["spell"] == "Windstep"
    with pytest.raises(Exception):
        validate_args("set_reflex_rule", {**WINDSTEP_AWAY, "trigger": {"kind": "boss_roars"}})
    with pytest.raises(Exception):
        validate_args("set_reflex_rule", {**WINDSTEP_AWAY, "actions": [{"kind": "block"}]})
    schema = TOOLS["set_reflex_rule"][0].model_json_schema()
    kinds = schema["$defs"]["ReflexTrigger"]["properties"]["kind"]["enum"]
    assert kinds == list(SENSABLE_TRIGGERS)


# --------------------------------------------------------------------------- cast through the Controller


def test_cast_routes_through_executor_and_controller_sees_castable_spells(rig):
    rig.game.player_say("shield up!")
    rig.controller_llm.push(FakeLLM.say("Shield's up.", FakeLLM.call("cast", spell="Tempest Shield")))
    rig.agent.step()
    assert rig.game.casts[0]["spell"] == "USD_TempestShield"
    assert rig.companion_said() == ["Shield's up."]
    ctx = context_of(rig.controller_llm.calls[0])
    names = [s["name"] for s in ctx["castable_spells"]]
    assert names == ["Tempest Shield", "Windstep"]  # Fire enchant: Luis hasn't unlocked it
    assert set(ctx["castable_spells"][0]) == {"name", "role", "use_when"}
    offered = {t["function"]["name"] for t in rig.controller_llm.calls[0]["tools"]}
    assert {"cast", "set_reflex_rule", "list_rules", "clear_rule"} <= offered


def test_cast_long_cooldown_is_reported_not_retried(rig):
    rig.game.spell_ready_at["USD_TempestShield"] = rig.game.time + 40
    rig.game.player_say("shield")
    rig.controller_llm.push(FakeLLM.say("On it.", FakeLLM.call("cast", spell="shield")))
    rig.agent.step()
    assert rig.companion_said() == ["Tempest Shield is still on cooldown (40s left)."]
    assert len(rig.calls("cast")) == 1


def test_cast_short_cooldown_is_waited_out(rig):
    slept = []

    def sleep(s):
        slept.append(s)
        rig.game.tick(s)

    rig.executor.sleep = sleep
    rig.game.spell_ready_at["USD_Windstep"] = rig.game.time + 2
    rig.game.move_player("Luis", [100, 100, 0])
    outcome = rig.executor.run_task(Task(skill="cast", args={"spell": "windstep", "target": None}))
    assert outcome.ok and slept and slept[0] == pytest.approx(2.1)
    assert len(rig.calls("cast")) == 2


def test_cast_not_unlocked_and_unknown(rig):
    rig.game.player_say("enchant your sword with fire")
    rig.controller_llm.push(FakeLLM.say("Done!", FakeLLM.call("cast", spell="fire enchant")))
    rig.agent.step()
    assert rig.companion_said() == ["You haven't unlocked Enchant Weapon Fire, so I can't use it either."]
    rig.game.player_say("cast meteor")
    rig.controller_llm.push(FakeLLM.say("Boom!", FakeLLM.call("cast", spell="meteor")))
    rig.agent.step()
    assert rig.companion_said()[-1] == "Sorry, I can't cast that spell yet."


def test_cast_unsafe_near_luis_is_deterministic(rig):
    rig.game.player_say("windstep on me")
    rig.controller_llm.push(FakeLLM.say("Here goes.", FakeLLM.call("cast", spell="Windstep", target="Luis")))
    rig.agent.step()
    assert rig.companion_said() == ["Not casting Windstep there, it would hit you."]
    assert len(rig.calls("cast")) == 1  # no retries
    assert rig.game.casts == []


def test_cast_verifier_checks_the_cooldown_started(rig):
    rig.game.script_failure("cast", "lie")
    rig.game.move_player("Luis", [100, 100, 0])
    outcome = rig.executor.run_task(Task(skill="cast", args={"spell": "Windstep", "target": None}))
    # the lying first answer is caught (no cooldown in state); the retry really casts
    assert outcome.ok and len(rig.calls("cast")) == 2 and len(rig.game.casts) == 1


def test_cast_does_not_interrupt_the_current_job(rig):
    d = None
    rig.controller_llm.push(FakeLLM.say("Shield!", FakeLLM.call("cast", spell="shield")))
    d = rig.controller.decide("Luis", "shield", {}, "gather 10 logs")
    assert d.actions and not d.interrupts


# --------------------------------------------------------------------------- standing orders


def test_every_time_x_do_y_becomes_a_reflex_rule(rig):
    rig.game.player_say("every time the kalphite raises its claws, windstep away")
    rig.controller_llm.push(FakeLLM.say("Got it, I'll windstep away when it winds up.",
                                        FakeLLM.call("set_reflex_rule", **WINDSTEP_AWAY)))
    rig.agent.step()
    rules = rig.game.list_rules()["data"]["rules"]
    assert len(rules) == 1 and rules[0]["enemy"] == "kalphite" and rules[0]["trigger"] == {"kind": "telegraph"}
    assert rules[0]["actions"][1] == {"kind": "cast", "spell": "USD_Windstep", "target": "self"}
    assert rig.companion_said() == ["Got it, I'll windstep away when it winds up."]
    # the next decision sees the order in its bounded context
    rig.game.player_say("what are your orders?")
    rig.controller_llm.push(FakeLLM.say("Here you go.", FakeLLM.call("list_rules")))
    rig.agent.step()
    ctx = context_of(rig.controller_llm.calls[1])
    assert ctx["reflex_rules"] == ["r1: kalphite telegraph -> evade, cast Windstep at self"]
    assert rig.companion_said()[-1] == ("Here you go. My standing orders: "
                                        "r1: kalphite telegraph -> evade, cast Windstep at self.")


def test_unsensable_trigger_is_refused_without_reaching_the_body(rig):
    rig.game.player_say("every time the boss roars, shield up")
    rig.controller_llm.push(FakeLLM.say("Will do!", FakeLLM.call(
        "set_reflex_rule", enemy="boss", trigger={"kind": "boss_roars"}, actions=[{"kind": "cast", "spell": "shield"}])))
    rig.agent.step()
    assert rig.calls("set_reflex_rule") == []
    assert rig.companion_said()[0].startswith("I can't sense that")


def test_rule_with_a_spell_luis_lacks_is_stored_with_a_heads_up(rig):
    rig.game.player_say("whenever a goblin is stunned, fire enchant")
    rig.controller_llm.push(FakeLLM.say("Okay.", FakeLLM.call(
        "set_reflex_rule", enemy="goblins", trigger={"kind": "enemy_stunned"},
        actions=[{"kind": "cast", "spell": "fire enchant", "target": "self"}])))
    rig.agent.step()
    assert rig.game.list_rules()["data"]["rules"][0]["enemy"] == "goblin"
    assert rig.companion_said() == ["Okay. Heads up: you haven't unlocked Enchant Weapon Fire, so that part won't happen."]


def test_clear_rule_and_rules_do_not_interrupt(rig):
    rig.game.set_reflex_rule(**WINDSTEP_AWAY)
    rig.controller_llm.push(FakeLLM.say("Okay, I'll stop that.", FakeLLM.call("clear_rule", id="r1")))
    d = rig.controller.decide("Luis", "stop windstepping", {}, "kill the kalphites")
    assert not d.interrupts
    rig.game.player_say("forget that")
    rig.controller_llm.push(FakeLLM.say("Okay, I'll stop that.", FakeLLM.call("clear_rule", id="r1")))
    rig.agent.step()
    assert rig.game.list_rules()["data"]["rules"] == []
    assert rig.companion_said() == ["Okay, I'll stop that. Forgot 1 order."]


def test_rule_not_in_the_body_list_fails_verification(rig):
    rig.game.list_rules = lambda enemy=None: ok(rules=[])  # the body "forgot" it
    rig.game.player_say("every time the kalphite raises its claws, windstep away")
    rig.controller_llm.push(FakeLLM.say("Got it.", FakeLLM.call("set_reflex_rule", **WINDSTEP_AWAY)))
    rig.agent.step()
    assert rig.companion_said() == ["I couldn't set reflex rule: verification_failed."]


def test_describe_rule_and_spell_label():
    assert spell_label("USD_TempestShield") == "Tempest Shield"
    assert spell_label("USD_EnchantWeapon_Fire") == "Enchant Weapon Fire"
    assert describe_rule({"id": "r3", "enemy": "*", "trigger": {"kind": "own_hp_below", "value": 30.0},
                          "actions": [{"kind": "retreat"}]}) == "r3: any enemy own_hp_below <30 -> retreat"


# --------------------------------------------------------------------------- spell book


def test_spellbook_from_body_rows_and_cache():
    game = MockGame.default_world()
    t = [0.0]
    book = SpellBook(game, ttl=60, clock=lambda: t[0])
    assert [r["name"] for r in book.castable()] == ["Tempest Shield", "Windstep"] and book.source == "body"
    game.unlocked.add("USD_EnchantWeapon_Fire")
    assert len(book.castable()) == 2  # cached
    t[0] = 61
    assert len(book.castable()) == 3
    rows = from_body([{"id": "a", "name": "A", "role": "x", "use_when": "u", "castable": False, "reason": "on_cooldown",
                       "remaining_s": 12}, {"id": "b", "name": "B", "castable": False, "reason": "not_implemented"}])
    assert rows == [{"name": "A", "role": "x", "use_when": "u", "note": "on cooldown (12s)"}]


def test_spellbook_catalog_fallback_only_lists_verified_unlocked():
    doc = json.loads(DEFAULT_CATALOG.read_text(encoding="utf-8"))
    assert from_catalog(doc) == []  # build 26161880: no route verified in game yet
    doc2 = copy.deepcopy(doc)
    doc2["routes"]["self_effect"]["verified"] = True
    names = [r["name"] for r in from_catalog(doc2)]
    assert "Tempest Shield" in names and "Windstep" not in names


def test_spellbook_falls_back_to_the_catalog_for_old_bodies():
    class Old(MockGame):
        def spells(self):
            return {"ok": False, "reason": "unknown_tool", "data": {}}

    book = SpellBook(Old.default_world())
    assert book.castable() == [] and book.source == "catalog"


# --------------------------------------------------------------------------- over the bridge


@pytest.fixture
def bridge(tmp_path):
    brain_t, body_t = file_transport_pair(tmp_path / "bridge_io")
    game = MockGame.default_world()
    body = FakeBody(game, body_t).start()
    client = BridgeClient(brain_t, JsonlLogger(tmp_path / "bridge.jsonl"), default_timeout=5.0)
    yield client, game
    body.stop()


def test_bridge_cast_spells_and_rules(bridge):
    client, game = bridge
    game.move_player("Luis", [100, 100, 0])
    assert client.cast("Windstep")["ok"]  # no target: None is dropped, not sent as null
    assert client.cast("Windstep")["reason"] == Reason.ON_COOLDOWN
    assert [s["name"] for s in client.spells()["data"]["spells"]] == ["Tempest Shield", "Windstep"]
    clean = validate_args("set_reflex_rule", WINDSTEP_AWAY)
    res = client.call("set_reflex_rule", clean)
    assert res["ok"] and res["data"]["rule"]["id"] == "r1"
    assert "attack" not in res["data"]["rule"]["trigger"]  # None fields never cross the wire
    assert [r["id"] for r in client.list_rules()["data"]["rules"]] == ["r1"]
    assert client.clear_rule(all=True)["data"]["removed"] == ["r1"]


def test_rig_over_the_bridge_sets_a_rule(tmp_path):
    brain_t, body_t = file_transport_pair(tmp_path / "bridge_io")
    game = MockGame.default_world()
    body = FakeBody(game, body_t).start()
    try:
        client = BridgeClient(brain_t, JsonlLogger(tmp_path / "bridge.jsonl"), default_timeout=5.0)
        rig = Rig(tmp_path, game=client)
        game.player_say("every time the kalphite raises its claws, windstep away")
        rig.controller_llm.push(FakeLLM.say("Got it.", FakeLLM.call("set_reflex_rule", **WINDSTEP_AWAY)))
        deadline = time.monotonic() + 5
        while not rig.controller_llm.calls and time.monotonic() < deadline:
            rig.agent.step()  # the fake body thread delivers the chat event asynchronously
            time.sleep(0.02)
        assert [r["enemy"] for r in game.list_rules()["data"]["rules"]] == ["kalphite"]
        assert game.chat[-1] == ("companion", "Got it.")
    finally:
        body.stop()

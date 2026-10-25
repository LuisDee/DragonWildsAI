"""The capability contract (streamline plan step 2): the body's manifest drives the brain's tool list,
args validation, timeouts and the planner registry; composed primitives reach the body as exactly the
calls the model chose, with valid args.

The manifest is the REAL one: client_mod/tests/test_skills.lua runs the real client_bridge.lua +
skills.lua + manifest.lua over the fake client modules and writes its `capabilities` answer to
<tmp>/capabilities.json. The model is scripted (FakeLLM): these tests check the contract and the
plumbing, not the model's judgement (that is evals/manifest_eval.py, real Haiku).
"""
import json
import subprocess
from pathlib import Path

import pytest

from brain.agent import Agent
from brain.capabilities import Capabilities, discover
from brain.controller import Controller
from brain.executor import Executor
from brain.interface import GameInterface, fail, ok
from brain.jsonl_log import JsonlLogger
from brain.llm import FakeLLM
from brain.planner import Planner
from brain.situation import summary
from brain.state_store import StateStore
from tests.test_lua_bridge import LUA

CLIENT_TESTS = Path(__file__).resolve().parents[1] / "client_mod" / "tests"
needs_lua = pytest.mark.skipif(LUA is None, reason="no Lua interpreter on PATH (set DW_LUA)")


@pytest.fixture(scope="module")
def lua_caps(tmp_path_factory) -> dict:
    if LUA is None:
        pytest.skip("no Lua interpreter")
    d = tmp_path_factory.mktemp("skills")
    proc = subprocess.run([LUA, str(CLIENT_TESTS / "test_skills.lua"), str(d)], capture_output=True, text=True, timeout=120)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    return json.loads((d / "capabilities.json").read_text(encoding="utf-8"))


@needs_lua
def test_lua_skills_suite(lua_caps):
    assert lua_caps["body"] == "client" and lua_caps["manifest"]


# --------------------------------------------------------------------------- a fake client body


class CapsClient:
    """Just enough of BridgeClient for discover(): answers capabilities with the Lua body's answer."""

    def __init__(self, data: dict):
        self.data, self.timeouts, self.manifest_tools = data, {}, frozenset()

    def capabilities(self, timeout: float = 5.0):
        return ok(**self.data)


def grave_world() -> dict:
    """Live 19:50 situation: Claude next to his own grave, Luis 3 m away, food and drink dropped."""
    return {
        "position": [441.0, 1831.0, -16.5], "health": 100, "max_health": 100, "name": "Claude", "body": "client",
        "hydration": 9.0, "hydration_max": 75.0, "sustenance": 30.0, "sustenance_max": 75.0,
        "inventory": {"ITEM_Resources_Wood_Ash": 4, "ITEM_Consumable_Tea_Pumpkin": 1},
        "inventory_items": [
            {"id": "QuickAction:1", "where": "hotbar", "name": "Pumpkin Spice Infusion", "item": "ITEM_Consumable_Tea_Pumpkin",
             "count": 1, "consumable": "drink"},
            {"id": "InventoryItems:0", "where": "bag", "name": "Ash Logs", "item": "ITEM_Resources_Wood_Ash", "count": 4}],
        "players": [{"id": "BP_PlayerCharacter_C_2147466104", "name": "Zezima", "position": [445.7, 1837.0, -15.35],
                     "distance": 3.2}],
        "nearby_entities": [],
        "nearby_items": [
            {"id": "BP_RuntimeSpawnedWorldItem_C_2147465124", "name": "Pumpkin Spice Infusion",
             "item": "ITEM_Consumable_Tea_Pumpkin", "count": 2, "position": [445.0, 1838.0, -15.4], "distance": 3.5,
             "consumable": "drink"},
            {"id": "BP_RuntimeSpawnedWorldItem_C_2147465130", "name": "Forager's Sandwich",
             "item": "ITEM_Consumable_Sandwich_Veggie", "count": 3, "position": [445.3, 1838.2, -15.4], "distance": 3.7,
             "consumable": "food"}],
        "nearby_resources": [],
        "interactables": [{"id": "BP_PlayerGravestone_C_2147463090", "class": "BP_PlayerGravestone_C", "name": "",
                           "prompt": "Take All", "kind": "interactable", "position": [441.6, 1829.1, -16.68],
                           "distance": 2.0}],
        "my_grave": {"id": "BP_PlayerGravestone_C_2147463090", "distance": 2.0, "items": 12, "owner": "unverified",
                     "contents": ["Mithril Pickaxe x1", "Mithril Logging Axe x1", "Torch x1", "Bronze Shield x1"]},
        "last_death": {"ago_s": 300, "respawned": True},
        "structures": [], "places": [], "following": None,
    }


class FakeClientBody(GameInterface):
    """Records every body call; applies its effect so the executor's verifiers see fresh state."""

    def __init__(self, state: dict):
        self.state, self.calls, self.chat = state, [], []

    def get_state(self):
        return ok(**json.loads(json.dumps(self.state)))

    def call_raw(self, tool, args):
        self.calls.append((tool, dict(args)))
        s = self.state
        if tool == "interact":
            hit = next((i for i in s["nearby_items"] if i["id"] == args["target"]), None)
            if hit:
                s["nearby_items"].remove(hit)
                s["inventory"][hit["item"]] = s["inventory"].get(hit["item"], 0) + hit["count"]
                return ok(target=hit["id"], item=hit["item"], count=hit["count"])
            if args["target"] == (s.get("my_grave") or {}).get("id"):
                s["inventory"]["ITEM_Pickaxe_Mithril"] = 1
                s.pop("my_grave")
                return ok(target=args["target"], item="ITEM_Pickaxe_Mithril", count=1, target_gone=True)
            return fail("unknown_target")
        if tool == "consume":
            key = next((r["item"] for r in s["inventory_items"] if r["name"] == args["item"] or r["item"] == args["item"]), None)
            if not key:
                return fail("not_in_inventory")
            s["inventory"][key] -= 1
            return ok(item=key, stat="hydration", stat_rose=True)
        if tool == "move_item":
            return ok(item=args["item"], to=args["to"])
        return fail("not_implemented", tool=tool)

    def interact(self, target, secondary=False):
        return self.call_raw("interact", {"target": target, **({"secondary": True} if secondary else {})})

    def follow(self, player, distance=3.0): return self.call_raw("follow", {"player": player})
    def stop(self): self.calls.append(("stop", {})); return ok()

    def go_to(self, target):
        self.calls.append(("go_to", {"target": target}))
        p = next((p for p in self.state["players"] if p["name"] == target), None)
        if p:
            self.state["position"] = [p["position"][0] - 1.0, p["position"][1], p["position"][2]]
        return ok(target=target, target_position=None, dist_m=1.0)

    def drop(self, item, count, at="feet"):
        self.calls.append(("drop", {"item": item, "count": count, "at": at}))
        key = next((k for k in self.state["inventory"] if k == item or item.lower().split()[0] in k.lower()), None)
        if not key:
            return fail("not_in_inventory")
        self.state["inventory"][key] -= count
        return ok(item=key, count=count, at="feet")

    def say(self, text):
        self.chat.append(text)
        return ok(text=text)

    def attack(self, target): return fail("not_implemented")
    def gather(self, resource, count, radius=None): return fail("not_implemented")
    def craft(self, item, count=1): return fail("not_implemented")
    def place(self, blueprint, location): return fail("not_implemented")
    def give(self, player, item, count): return fail("not_implemented")
    def pickup(self, target, item=None, limit=1): return fail("not_implemented")
    def poll_events(self): return []

    def body_calls(self):
        return [(t, a) for t, a in self.calls if t != "stop"]


class Rig:
    def __init__(self, tmp_path: Path, caps_data: dict, state: dict | None = None):
        self.caps = discover(CapsClient(caps_data))
        self.game = FakeClientBody(state or grave_world())
        self.game.manifest_tools = frozenset(n for n in self.caps.manifest if n not in __import__("brain.interface").interface.BODY_TOOLS)
        self.log = JsonlLogger(tmp_path / "brain.jsonl")
        self.store = StateStore(tmp_path / "state", self.caps.registry())
        self.llm = FakeLLM(model="fake/controller")
        self.controller = Controller(self.llm, self.game, self.store, self.log, name="Claude", player="Zezima",
                                     available_tools=self.caps.tools, caps=self.caps)
        self.executor = Executor(self.game, self.store, self.log)
        self.agent = Agent(self.game, self.controller, Planner(FakeLLM(model="fake/planner"), self.store.skills, self.log),
                           self.executor, self.store, self.log)

    def offered(self) -> set[str]:
        return self.controller.offered()

    def command(self, text: str, *responses):
        from brain.interface import CommandReceived
        self.llm.push(*responses)
        self.agent._command(CommandReceived(player="Zezima", text=text))


# --------------------------------------------------------------------------- the manifest drives the tools


@needs_lua
def test_manifest_drives_the_offered_tools(lua_caps, tmp_path):
    rig = Rig(tmp_path, lua_caps)
    caps = rig.caps
    assert caps.has_manifest and caps.source == "capabilities"
    body_offered = rig.offered() - {"remember", "run_skill", "start_goal"}
    assert body_offered == set(caps.llm_tools())
    for t in ("interact", "consume", "move_item", "equip", "go_to", "follow", "stop", "drop", "look", "inspect", "inventory"):
        assert t in body_offered, t
    # never a tool the body lacks or a demoted compound
    for t in ("pickup", "fetch", "come_to", "recover_grave", "give", "attack", "gather", "craft", "cast", "sleep",
              "set_reflex_rule", "list_rules"):
        assert t not in body_offered, t
    # the body's own words and schemas reach the model
    fn = {t["function"]["name"]: t["function"] for t in rig.controller.tools}
    assert "faces it" in fn["interact"]["description"] and fn["drop"]["parameters"]["properties"]["at"]["enum"] == ["feet"]
    assert fn["move_item"]["parameters"]["required"] == ["item", "to"]
    assert all("anyOf" not in f["parameters"] for f in fn.values()), "no top-level anyOf (model APIs reject it)"
    # timeouts and the registry come from it too
    assert rig.store.skills.names() == caps.skills() and "move_item" in caps.skills() and "look" not in caps.skills()
    assert caps.timeouts()["interact"] >= 110
    assert caps.aliases == {"pickup": "interact"}


@needs_lua
def test_args_are_validated_against_the_body_schema(lua_caps, tmp_path):
    caps = Rig(tmp_path, lua_caps).caps
    assert caps.validate("drop", {"item": "Ash Logs", "count": 2}) == {"item": "Ash Logs", "count": 2, "at": "feet"}
    with pytest.raises(ValueError):
        caps.validate("drop", {"item": "Ash Logs", "count": 2, "at": "player"})  # the brain's own model allows it
    with pytest.raises(ValueError):
        caps.validate("move_item", {"item": "Sandwich", "to": "chest"})
    assert caps.validate("move_item", {"item": "Sandwich", "to": "hotbar"}) == {"item": "Sandwich", "to": "hotbar"}
    assert caps.resolve("pickup", {"target": "BP_X_1", "limit": 3}) == ("interact", {"target": "BP_X_1"})


def test_old_body_without_manifest_offers_only_its_tools(tmp_path):
    """A body that lists tools but has no manifest: the brain's own schemas, still only for listed tools."""
    caps = discover(CapsClient({"tools": ["ping", "capabilities", "get_state", "say", "follow", "stop", "go_to"]}))
    rig_caps = caps
    game = FakeClientBody(grave_world())
    log = JsonlLogger(tmp_path / "b.jsonl")
    c = Controller(FakeLLM(), game, StateStore(tmp_path / "s", rig_caps.registry()), log, available_tools=caps.tools, caps=caps)
    assert c.offered() - {"remember", "run_skill", "start_goal"} == {"follow", "stop", "go_to"}


# --------------------------------------------------------------------------- today's lines, scripted model


@needs_lua
def test_grab_those_is_one_interact_on_the_named_stack(lua_caps, tmp_path):
    rig = Rig(tmp_path, lua_caps)
    rig.command("grab those on the floor near me",
                FakeLLM.say("Grabbing it.", FakeLLM.call("interact", target="BP_RuntimeSpawnedWorldItem_C_2147465124")))
    assert rig.game.body_calls() == [("interact", {"target": "BP_RuntimeSpawnedWorldItem_C_2147465124"})]
    assert rig.game.state["inventory"]["ITEM_Consumable_Tea_Pumpkin"] == 3


@needs_lua
def test_legacy_pickup_reaches_the_body_as_interact(lua_caps, tmp_path):
    rig = Rig(tmp_path, lua_caps)
    rig.command("grab those", FakeLLM.say("Got it.", FakeLLM.call("pickup", target="BP_RuntimeSpawnedWorldItem_C_2147465130",
                                                                  limit=1)))
    assert rig.game.body_calls() == [("interact", {"target": "BP_RuntimeSpawnedWorldItem_C_2147465130"})]
    assert not any("can't pick" in s for s in rig.game.chat), rig.game.chat


@needs_lua
def test_drink_the_infusion_is_one_consume(lua_caps, tmp_path):
    rig = Rig(tmp_path, lua_caps)
    rig.command("drink the pumkin spice infusuion",
                FakeLLM.say("Drinking one.", FakeLLM.call("consume", item="Pumpkin Spice Infusion")))
    assert rig.game.body_calls() == [("consume", {"item": "Pumpkin Spice Infusion"})]
    assert rig.game.chat[-1] == "Drinking one."


@needs_lua
def test_come_to_me_is_go_to_the_player(lua_caps, tmp_path):
    rig = Rig(tmp_path, lua_caps)
    rig.command("come to me", FakeLLM.say("On my way.", FakeLLM.call("go_to", target="Zezima")))
    assert rig.game.body_calls() == [("go_to", {"target": "Zezima"})]


@needs_lua
def test_get_your_stuff_is_interact_on_his_own_grave(lua_caps, tmp_path):
    rig = Rig(tmp_path, lua_caps)
    digest = "\n".join(summary(rig.game.state))
    assert "YOUR gravestone is 2 m away (id BP_PlayerGravestone_C_2147463090) holding 12 of your items" in digest
    assert "you died 5 min ago and respawned" in digest
    assert "Pumpkin Spice Infusion x1 (drink, hotbar)" in digest and "Pumpkin Spice Infusion x2 (" in digest
    rig.command("get your stuff from your grave",
                FakeLLM.say("Grabbing my gear.", FakeLLM.call("interact", target="BP_PlayerGravestone_C_2147463090")))
    assert rig.game.body_calls() == [("interact", {"target": "BP_PlayerGravestone_C_2147463090"})]


@needs_lua
def test_give_me_the_logs_is_go_to_then_drop_in_order(lua_caps, tmp_path):
    rig = Rig(tmp_path, lua_caps)
    rig.command("give me the logs", FakeLLM.say("Here you go.", FakeLLM.call("go_to", target="Zezima"),
                                                FakeLLM.call("drop", item="Ash Logs", count=4)))
    assert rig.game.body_calls() == [("go_to", {"target": "Zezima"}), ("drop", {"item": "Ash Logs", "count": 4, "at": "feet"})]

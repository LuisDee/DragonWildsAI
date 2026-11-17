"""A gather or explore that failed because the thing was not found carries what the brain's own knowledge says about
where it is found (brain/result_knowledge.py). Live 2026-11-17 (logs brain-live-20261117-205205-24152 and
-211034-9796, "thirty copper ore in the chest at your base"): two explores of 8 legs around home, then gather
"I can't find any copper within 90 m of me", and he parked the ask asking the player for a patch."""
import json

import pytest

from brain import result_knowledge as rk
from brain.knowledge import REPO_ROOT, Knowledge, _place_list
from brain.llm import FakeLLM

# the two results from the live logs, as the body sent them (trail and trips trimmed)
GATHER_COPPER = {"ok": False, "reason": "nothing_in_range", "data": {
    "radius_m": 90.0, "tool": "Stone Pickaxe", "gathered": 0, "detail": "I can't find any copper within 90 m of me.",
    "want": 30, "targets": 0, "item": "ITEM_Resources_CopperOre", "why": "no_resource_nearby", "resource": "copper",
    "total": 0}}
EXPLORE_COPPER = {"ok": False, "reason": "nothing_in_range", "data": {
    "sight_m": 40, "farthest_m": 106, "about": "copper ore rocks", "legs": 8, "travelled_m": 314,
    "detail": "explored 8 legs (about 314 m walked, at most 106 m from where I began, seeing about 40 m around) and "
              "saw nothing matching 'copper ore rocks'"}}
REGIONS = "Fractured Plains, Stormtouched Highlands, Dowdun Reach"

DB = REPO_ROOT / "data" / "wiki" / "knowledge.sqlite"
needs_wiki = pytest.mark.skipif(not DB.exists(), reason="data/wiki/knowledge.sqlite (gitignored) not here")


@pytest.fixture(scope="module")
def kb():
    return Knowledge()


def _copy(r):
    return json.loads(json.dumps(r))


@needs_wiki
def test_copper_gather_from_the_logs_gets_the_regions_and_tool(kb):
    res = _copy(GATHER_COPPER)
    assert rk.enrich(kb, "gather", {"resource": "copper", "count": 30}, res)
    assert res["knowledge"] == f"wiki, Copper Ore Node: found in {REGIONS}; tool: Bone pickaxe or better"
    assert len(res["knowledge"]) <= rk.MAX_CHARS
    assert {k: v for k, v in res.items() if k != "knowledge"} == GATHER_COPPER  # the body's result itself untouched


@needs_wiki
def test_copper_explore_from_the_logs_gets_the_regions(kb):
    res = _copy(EXPLORE_COPPER)
    assert rk.enrich(kb, "explore", {"about": "copper ore rocks", "leg_m": 40, "max_legs": 8}, res)
    assert REGIONS in res["knowledge"] and res["knowledge"].startswith("wiki, Copper Ore Node")


@needs_wiki
def test_a_found_result_is_untouched(kb):
    ok = {"ok": True, "reason": None, "data": {"resource": "copper", "gathered": 30}}
    found = {"ok": True, "data": {"found": {"name": "Copper Ore Node"}, "legs": 2}}
    for tool, args, res in (("gather", {"resource": "copper"}, ok), ("explore", {"about": "copper"}, found)):
        before = _copy(res)
        assert not rk.enrich(kb, tool, args, res) and res == before


@needs_wiki
def test_a_thing_the_wiki_lacks_adds_nothing(kb):
    for q in ("unobtainium", "Luis's tent", "ore"):  # unknown; not a resource; a category, no one node
        res = _copy(EXPLORE_COPPER)
        res["data"]["about"] = q
        assert not rk.enrich(kb, "explore", {"about": q}, res) and "knowledge" not in res


@needs_wiki
def test_a_failure_that_is_not_not_found_is_untouched(kb):
    cases = [
        ("gather", {"resource": "copper"}, {"ok": False, "reason": "wrong_tool", "data": {"why": "tool_tier_too_low"}}),
        ("gather", {"resource": "copper"}, {"ok": False, "reason": "path_blocked", "data": {}}),
        # nodes there but used up, or only floating: found, not missing
        ("gather", {"resource": "copper"}, {"ok": False, "reason": "nothing_in_range",
                                            "data": {"why": "no_resource_nearby", "used_up": 3}}),
        ("gather", {"resource": "rune_essence"}, {"ok": False, "reason": "nothing_in_range",
                                                  "data": {"why": "floating_only"}}),
        ("go_to", {"target": "copper"}, {"ok": False, "reason": "nothing_in_range", "data": {}}),
        ("explore", {"about": "copper"}, {"ok": False, "reason": "companion_down", "data": {}}),
    ]
    for tool, args, res in cases:
        before = _copy(res)
        assert not rk.enrich(kb, tool, args, res) and res == before, (tool, res)


def test_place_list_flattens_the_mirrors_bullets():
    assert _place_list("* Fractured Plains - Stormtouched Highlands - Dowdun Reach") == REGIONS
    assert _place_list("- Bloodblight Swamp - Fractured Plains - Dowdun Reach") == \
        "Bloodblight Swamp, Fractured Plains, Dowdun Reach"
    assert _place_list("Brynmoor, Ghornfell, Fellhollow") == "Brynmoor, Ghornfell, Fellhollow"


class _KB:
    def __init__(self, facts):
        self.facts, self.asked = facts, []

    def node_facts(self, q):
        self.asked.append(q)
        return self.facts.get(q)

    def kinds(self):
        return []


def test_the_agent_shows_it_to_the_model_and_logs_it(rig):
    """The not-found gather's tool message carries the fact; the turn logs result_knowledge."""
    rig.controller.knowledge = _KB({"gold": {"title": "Gold Ore Node", "location": "Bloodblight Swamp",
                                             "tool": "Iron pickaxe or better", "url": "u"}})
    rig.game.player_say("get me some gold")
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("gather", resource="gold", count=1)),
                            FakeLLM.say("no gold round here"), FakeLLM.say(""))
    rig.agent.step()
    second = rig.controller_llm.calls[1]["messages"]
    tool_msg = json.loads(next(m for m in second if m["role"] == "tool")["content"])
    assert tool_msg["reason"] == "nothing_in_range"
    assert tool_msg["knowledge"] == "wiki, Gold Ore Node: found in Bloodblight Swamp; tool: Iron pickaxe or better"
    rows = [r for r in rig.log.read_all() if r["kind"] == "result_knowledge"]
    assert [(r["tool"], r["query"]) for r in rows] == [("gather", "gold")] and rows[0]["added"] == tool_msg["knowledge"]


def test_the_agent_adds_nothing_without_a_fact(rig):
    rig.controller.knowledge = _KB({})
    rig.game.player_say("get me some gold")
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("gather", resource="gold", count=1)),
                            FakeLLM.say("no gold round here"), FakeLLM.say(""))
    rig.agent.step()
    tool_msg = json.loads(next(m for m in rig.controller_llm.calls[1]["messages"] if m["role"] == "tool")["content"])
    assert "knowledge" not in tool_msg and not [r for r in rig.log.read_all() if r["kind"] == "result_knowledge"]

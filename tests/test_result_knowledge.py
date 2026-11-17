"""A gather or explore that failed because the thing was not found carries what the brain's own knowledge says about
where it is found (brain/result_knowledge.py). Live 2026-11-17 (logs brain-live-20261117-205205-24152 and
-211034-9796, "thirty copper ore in the chest at your base"): two explores of 8 legs around home, then gather
"I can't find any copper within 90 m of me", and he parked the ask asking the player for a patch."""
import json

import pytest

from brain import result_knowledge as rk
from brain.knowledge import REPO_ROOT, Knowledge, _place_list
from brain.llm import FakeLLM
from tests.conftest import Rig

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
        # a wrong_tool that is not about his tool (an unknown why), or not from gather, is no tool fact
        ("gather", {"resource": "copper"}, {"ok": False, "reason": "wrong_tool", "data": {"why": "something_else"}}),
        ("explore", {"about": "copper"}, {"ok": False, "reason": "wrong_tool", "data": {"why": "no_tool"}}),
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
    # the rig's state is read too: with no pickaxe carried, the fact says so after the wiki line
    assert tool_msg["knowledge"].startswith("wiki, Gold Ore Node: found in Bloodblight Swamp; tool: Iron pickaxe or better")
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


def test_a_planned_step_that_finds_nothing_carries_it_too(tmp_path):
    """Live 2026-11-17 22:24Z (run 20261117-212448-L2): explore and gather ran as Planner steps, failed nothing_in_range,
    and no fact was added: only the turn's own calls were enriched. Every path's failed step carries it now: the
    step's result (which the replan and the stuck message show) and the result_knowledge row."""
    rig = Rig(tmp_path, max_replans=0)
    rig.controller.knowledge = _KB({"gold": {"title": "Gold Ore Node", "location": "Bloodblight Swamp",
                                             "tool": "Iron pickaxe or better", "url": "u"}})
    rig.planner_llm.push(FakeLLM.plan([{"skill": "gather", "args": {"resource": "gold", "count": 1}}]))
    rig.controller_llm.push(FakeLLM.say(""), FakeLLM.say(""))
    assert rig.agent.run_goal("get some gold") == "stuck"
    fact = "wiki, Gold Ore Node: found in Bloodblight Swamp; tool: Iron pickaxe or better"
    assert fact in (rig.store.tree.tasks[0].detail or "")
    rows = [r for r in rig.log.read_all() if r["kind"] == "result_knowledge"]
    assert [(r["tool"], r["query"]) for r in rows] == [("gather", "gold")]
    shown = json.dumps([m for c in rig.controller_llm.calls for m in c["messages"]])
    assert "Bloodblight Swamp" in shown
# ---- distances and the tool against what he carries (live 2026-11-17 22:2xZ, logs brain-live-20261117-221939-19116:
# shown only the region names, he asked the player where copper is and stopped; docs/research/2026-11-17-region-travel.md)

HOME = [100.0, 1892.0, -31.0]  # his base on the dev world, in Temple Woods (Brynmoor)
AT_HOME = {"position": HOME, "gear": {"HeldRight": "ITEM_Pickaxe_Stone", "HeldLeft": "ITEM_Pickaxe_Stone"},
           "inventory": {"ITEM_Pickaxe_Stone": 1, "ITEM_Resources_Stone": 12, "ITEM_Rune_Earth": 40},
           "inventory_items": [{"item": "ITEM_Pickaxe_Stone", "name": "Stone Pickaxe", "equipped": True}]}
COPPER = {"copper": {"title": "Copper Ore Node", "location": REGIONS, "tool": "Bone pickaxe or better", "url": "u"}}
TODAY = f"wiki, Copper Ore Node: found in {REGIONS}; tool: Bone pickaxe or better"


@pytest.fixture(scope="module")
def places():
    from brain.places import Places
    return Places()


def _gather(kb, state=None, places=None):
    return rk.note(kb, "gather", {"resource": "copper", "count": 30}, _copy(GATHER_COPPER), state, places=places)


def test_copper_at_home_gets_distance_and_direction_of_each_region_and_his_pickaxe(places):
    from brain.geom import direction
    q, text = _gather(_KB(COPPER), AT_HOME, places)
    assert q == "copper" and len(text) <= rk.MAX_CHARS <= 300, (len(text), text)
    assert text.startswith(TODAY)  # the wiki fact as before, then the map and the tool
    assert "Bone pickaxe or better (tier 2)" in text and "you in Temple Woods" in text
    # the same resolver go_to walks to for a region name, so go_to <name> goes where the numbers say
    for name in REGIONS.split(", "):
        best = places.where(name, HOME)["data"]["results"][0]
        assert best["name"] == name and best["match"] == "exact"
        assert f"{name} {best['distance_m']} m {direction(HOME, best['position'])}" in text, (name, text)
    assert "Fractured Plains 759 m NE, Stormtouched Highlands 826 m N, Dowdun Reach 2158 m NE" in text  # nearest first
    assert text.endswith("your best pickaxe: Stone Pickaxe (tier 1), below it")


def test_the_pickaxe_he_carries_is_read_from_bag_and_gear(places):
    bronze = {**AT_HOME, "inventory": {**AT_HOME["inventory"], "ITEM_Pickaxe_Bronze": 1}}
    assert _gather(_KB(COPPER), bronze, places)[1].endswith("your best pickaxe: Bronze Pickaxe (tier 3), meets it")
    held_only = {"position": HOME, "gear": {"HeldRight": "ITEM_Pickaxe_Iron"}, "inventory": {}}
    assert _gather(_KB(COPPER), held_only, places)[1].endswith("your best pickaxe: Iron Pickaxe (tier 4), meets it")
    none = {"position": HOME, "gear": {}, "inventory": {"ITEM_Resources_Stone": 3}}
    assert _gather(_KB(COPPER), none, places)[1].endswith("you carry no pickaxe")


def test_he_is_told_when_he_is_in_a_named_region(places):
    kb = _KB({"copper": {"title": "Copper Ore Node", "location": "Temple Woods, Fractured Plains", "tool": None}})
    text = _gather(kb, AT_HOME, places)[1]
    assert "Temple Woods (you are in it), Fractured Plains 759 m NE" in text


def test_a_region_less_fact_is_unchanged(places):
    for loc in ("Gielinor", "the deep caves of nowhere"):  # no map region or province among them
        kb = _KB({"copper": {"title": "Copper Ore Node", "location": loc, "tool": None, "url": "u"}})
        before = rk.note(kb, "gather", {"resource": "copper"}, _copy(GATHER_COPPER))
        assert before is not None and _gather(kb, AT_HOME, places) == before


def test_no_state_no_distances(places):
    assert _gather(_KB(COPPER), None, places) == ("copper", TODAY)

    def boom():  # an unreadable state is the same as none
        raise RuntimeError("get_state failed")
    assert _gather(_KB(COPPER), boom, places) == ("copper", TODAY)
    no_pos = _gather(_KB(COPPER), {"inventory": {}}, places)[1]
    assert no_pos.startswith(TODAY) and " m NE" not in no_pos and "you in" not in no_pos


def test_state_may_be_a_reader_called_only_when_there_is_a_fact(places):
    calls = []

    def read():
        calls.append(1)
        return AT_HOME
    assert rk.note(_KB({}), "gather", {"resource": "copper"}, _copy(GATHER_COPPER), read, places=places) is None
    assert not calls
    assert "Fractured Plains 759 m NE" in _gather(_KB(COPPER), read, places)[1] and calls == [1]


# ---- gather's wrong_tool (live 2026-11-17 23:19Z, logs brain-live-20261117-231925-27552 and -232246-18856, "thirty
# copper ore in the chest at your base"): the first gather copper failed "I need a pickaxe for copper and I don't have
# one" and no fact was added (only nothing_in_range had one), so he never learned copper takes a Bone pickaxe (tier 2)
# or better; he ran craft_plan Bronze Pickaxe, saw a long unlock chain and parked within 20 s, both trials.

GATHER_COPPER_NO_TOOL = {"ok": False, "reason": "wrong_tool", "data": {
    "resource": "copper", "detail": "I need a pickaxe for copper and I don't have one.", "why": "no_tool",
    "need": "pickaxe"}}
# the fork's start state from the first get_state of 231925 (bag and gear as read; no pickaxe of any kind)
FORK_START = {"position": [151.6, 1912.19, -31.58],
              "gear": {"HeldRight": "ITEM_Sword_Bronze", "HeldLeft": "ITEM_Shield_Bronze",
                       "Head": "ITEM_Armour_T2_Head_Leather"},
              "inventory": {"ITEM_Sword_Bronze": 1, "ITEM_Shield_Bronze": 1, "ITEM_Resources_Stone": 5,
                            "ITEM_Resources_AnimalBone": 4, "ITEM_Resources_Skin_Scraps": 7,
                            "ITEM_Resources_Wood_Ash": 1, "ITEM_Rune_Nature": 2040, "ITEM_Rune_Earth": 1615}}


def test_copper_no_pickaxe_from_the_logs_gets_the_tier_line(places):
    q, text = rk.note(_KB(COPPER), "gather", {"resource": "copper", "count": 30, "radius": 80},
                      _copy(GATHER_COPPER_NO_TOOL), FORK_START, places=places)
    assert q == "copper" and len(text) <= rk.MAX_CHARS
    assert text.startswith(f"wiki, Copper Ore Node: found in {REGIONS}; tool: Bone pickaxe or better (tier 2)")
    assert "Fractured Plains" in text and " m NE" in text
    assert text.endswith("you carry no pickaxe")


@needs_wiki
def test_copper_no_pickaxe_with_the_real_wiki(kb):
    res = _copy(GATHER_COPPER_NO_TOOL)
    assert rk.enrich(kb, "gather", {"resource": "copper", "count": 30}, res)
    assert res["knowledge"] == TODAY
    assert {k: v for k, v in res.items() if k != "knowledge"} == GATHER_COPPER_NO_TOOL


def test_a_tool_below_the_tier_gets_it_too(places):
    low = {"ok": False, "reason": "wrong_tool", "data": {
        "why": "tool_tier_too_low", "resource": "copper", "need_tier": 2, "have_tier": 1,
        "detail": "copper needs a tier 2 pickaxe; my best is my Stone Pickaxe (tier 1)."}}
    q, text = rk.note(_KB(COPPER), "gather", {"resource": "copper"}, low, AT_HOME, places=places)
    assert q == "copper" and "tool: Bone pickaxe or better (tier 2)" in text
    assert text.endswith("your best pickaxe: Stone Pickaxe (tier 1), below it")


def test_a_wrong_tool_the_wiki_has_nothing_on_adds_nothing():
    for name in ("oak", "maple", "rune_essence", "unobtainium"):
        res = {"ok": False, "reason": "wrong_tool", "data": {
            "resource": name, "why": "no_tool", "need": "hatchet",
            "detail": f"I need a hatchet for {name} and I don't have one."}}
        before = _copy(res)
        assert not rk.enrich(_KB({}), "gather", {"resource": name}, res, state=AT_HOME) and res == before


@needs_wiki
def test_a_wrong_tool_on_a_thing_with_no_node_page_adds_nothing(kb):
    res = {"ok": False, "reason": "wrong_tool", "data": {"resource": "unobtainium", "why": "no_tool", "need": "pickaxe"}}
    before = _copy(res)
    assert not rk.enrich(kb, "gather", {"resource": "unobtainium"}, res) and res == before

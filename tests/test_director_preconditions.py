"""GOAL M4 long tasks (mining_run_home_chest, farm_and_process_crop) from a FRESH dev character: every precondition
must be reachable from data by the Director's own research (lookup = game data + wiki, craft_plan / recipes /
buildables from the body). These checks run the REAL knowledge index over data/ (no model calls). A strict xfail
would mark a known data/retrieval gap; both found on 2026-10-26 are closed (unlock facts at index time).
"""
import pytest

from brain import director as D
from brain.knowledge import Knowledge

K = Knowledge()


def top(query, n=3):
    rows = (K.lookup(query).get("data") or {}).get("results") or []
    return " ".join(f"{r.get('title')}: {r.get('text')}" for r in rows[:n])


@pytest.mark.parametrize("query,must", [
    ("crafting table", ["Ash Logs", "mat1qty=4"]),           # the first station: 4 Ash Logs (build menu)
    ("stone pickaxe", ["Stone Pickaxe"]),                     # a starter pickaxe (Crafting Table)
    ("bone pickaxe", ["Copper"]),                             # copper and tin need tier 2: Bone Pickaxe
    ("wooden spade", ["Coarse Thread"]),                      # the farm needs a spade: Ash Logs + Coarse Thread
    ("coarse thread", ["Spinning Wheel"]),                    # thread is spun at a Spinning Wheel
    ("kiln", ["Clay"]),                                       # bread is baked in a Kiln (costs clay, fire runes)
    ("grindstone", ["Granite"]),                              # flour is ground at a Grindstone
    ("ground wheat", ["Grindstone"]),
])
def test_a_fresh_characters_preconditions_are_in_the_lookup_top_results(query, must):
    text = top(query)
    assert all(m in text for m in must), text[:600]


@pytest.mark.parametrize("query,must", [
    ("kiln unlock", "receive clay"),                        # wiki prose, lifted into an Unlock doc at index time
    ("grindstone unlock", "receive granite"),
    ("spinning wheel unlock", "flax for the first time"),   # unlocked by harvesting flax once
    ("how to unlock farming", "Growing Pains"),             # Farming opens with the Growing Pains quest
])
def test_unlocks_that_are_found_in_the_top_five(query, must):
    assert must in top(query, 5)


@pytest.mark.parametrize("query,must", [
    # the home chest: the wiki's Storage page leads to the player-built chests; the Small Chest ("Ash Chest",
    # build dump BUILDPIECE_Chest_Small) costs 16 Ash Logs + 2 Coarse Thread and unlocks with the first ash logs
    # plus the Construction perk Creature Comforts (lifted from prose into an Unlock doc at index time)
    ("storage chest build", "Storage"),
    ("chest to store items", "Player-built chests"),
    ("ash chest", "Coarse Thread"),
    ("how to unlock the ash chest", "Creature Comforts"),
])
def test_the_home_chest_piece_its_cost_and_unlock_are_found(query, must):
    assert must in top(query, 5)


def test_the_director_can_read_buildables_while_it_researches():
    assert "buildables" in D.PROXIED_READS and "buildables" in D.PROXY_TOOL_DOCS
    r = D.Research({"facts": {}, "state": {}}, None, D.BodyProxy(lambda t, a: {"ok": True, "data": {"tool": t}}),
                   {"buildables"})
    r.proxy.serve()  # establish this thread as the bridge owner, as Director.tick does
    assert "buildables" in [t["function"]["name"] for t in r.tools()]
    assert r.run("buildables", {"about": "chest"})["data"]["tool"] == "buildables"


def test_unlock_facts_are_lifted_from_any_section_of_the_page():
    from brain.knowledge import unlock_facts
    rec = {"sections": [{"heading": None, "part": 0, "text": "name: Kiln\nThe kiln burns logs. Players must receive "
                                                            "clay in their inventory to unlock the recipe for it."},
                        {"heading": "Uses", "text": "It needs fuel. Unlocks nothing else? It is unlocked early."}]}
    assert unlock_facts(rec) == ["Players must receive clay in their inventory to unlock the recipe for it.",
                                 "Unlocks nothing else?", "It is unlocked early."]

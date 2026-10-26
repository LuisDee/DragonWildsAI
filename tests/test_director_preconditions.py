"""GOAL M4 long tasks (mining_run_home_chest, farm_and_process_crop) from a FRESH dev character: every precondition
must be reachable from data by the Director's own research (lookup = game data + wiki, craft_plan / recipes /
buildables from the body). These checks run the REAL knowledge index over data/ (no model calls). A strict xfail
is a known data/retrieval gap (docs/PROGRESS.md 2026-10-26 "preconditions"): it starts passing when fixed.
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


@pytest.mark.xfail(strict=True, reason="unlock sentences live in wiki prose sections that rank below the cards")
@pytest.mark.parametrize("query,must", [
    ("kiln unlock", "receive clay"),
    ("grindstone unlock", "receive granite"),
])
def test_known_gap_how_a_station_unlocks(query, must):
    assert must in top(query, 5)


@pytest.mark.parametrize("query,must", [
    ("spinning wheel unlock", "flax for the first time"),   # unlocked by harvesting flax once
    ("how to unlock farming", "Growing Pains"),             # Farming opens with the Growing Pains quest
])
def test_unlocks_that_are_found_in_the_top_five(query, must):
    assert must in top(query, 5)


@pytest.mark.xfail(strict=True, reason="no data names the storage piece he builds for a home chest, or its unlock")
def test_known_gap_the_home_chest_piece():
    assert "Build Menu" in top("storage chest build")


def test_the_director_can_read_buildables_while_it_researches():
    assert "buildables" in D.PROXIED_READS and "buildables" in D.PROXY_TOOL_DOCS
    r = D.Research({"facts": {}, "state": {}}, None, D.BodyProxy(lambda t, a: {"ok": True, "data": {"tool": t}}),
                   {"buildables"})
    assert "buildables" in [t["function"]["name"] for t in r.tools()]
    assert r.run("buildables", {"about": "chest"})["data"]["tool"] == "buildables"

"""A pile of drops is one row (client_bridge.merge_piles, study 2026-11-19 bone pile): what the models are shown of it.
Six Bark to Bones drops were six ids in the Planner's nearby_items; it queued one interact per id, the first walk-up let
the game's item magnet take the pile, and the next queued call hit a gone id (unknown_target), six runs of six."""
from brain import planner
from brain.situation import summary

PILE = {"id": "BP_RuntimeSpawnedWorldItem_C_1", "name": "Animal Bone", "item": "ITEM_Resources_AnimalBone", "count": 6,
        "pile_n": 6, "pile_m": 3.5, "distance": 4.4}


def text(items):
    return "\n".join(summary({"position": [0, 0, 0], "health": 80, "max_health": 100, "nearby_items": items}))


def test_a_pile_row_says_it_is_a_pile_and_that_the_magnet_takes_it():
    t = text([PILE])
    assert "Animal Bone x6" in t and "id BP_RuntimeSpawnedWorldItem_C_1" in t
    assert "a pile of 6 drops within 3.5 m" in t and "item magnet" in t


def test_a_single_drop_has_no_pile_words():
    t = text([{**PILE, "count": 1, "pile_n": None, "pile_m": None}])
    assert "pile" not in t


def test_the_planner_rows_keep_the_pile_fields_and_its_rules_name_them():
    out = planner._trim_state({"nearby_items": [PILE]})
    assert out["nearby_items"][0]["pile_n"] == 6 and out["nearby_items"][0]["count"] == 6
    assert "pile_n" in planner.SYSTEM

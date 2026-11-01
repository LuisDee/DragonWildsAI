"""Building perception in the situation digest (docs/research/2026-11-01-autonomous-building.md §4.1, §6 step 1):
heights from the body's up_m, built pieces under buildables' names, pieces with no use on their own line."""
from brain.situation import height_words, perceived, summary


STATE = {
    "position": [109.75, 1841.97, -31.07], "health": 100, "max_health": 100,
    "interactables": [
        {"id": "BP_BaseBuilding_Crate_C_1", "name": "Base Building Crate", "prompt": "Open", "kind": "storage",
         "distance": 2.0, "position": [110, 1843, -32.1], "up_m": -0.2},
        {"id": "BP_LootChest_Prefab_Tier2_World_C_9", "name": "Loot Chest Prefab Tier2 World", "prompt": "Open",
         "distance": 46.7, "position": [69.8, 1861.3, -16.8], "up_m": 15.2},
    ],
    "structures": [
        {"id": "BP_BaseBuilding_Crate_C_1", "name": "Crate", "piece": "BUILDPIECE_Interior_Crate", "distance": 2.0,
         "position": [110, 1843, -32.1], "up_m": -0.2},
        {"id": "BP_Foundation_C_7", "name": "Square Foundation", "piece": "BUILDPIECE_Foundation", "distance": 5.0,
         "position": [112, 1846, -32.0], "up_m": 0.1, "ghosted": True},
    ],
}


def test_height_words_only_beyond_a_step():
    assert height_words(15.2) == "15 m up" and height_words(-4.4) == "4 m down"
    assert height_words(1.2) == "" and height_words(None) == ""


def test_built_pieces_use_buildables_names_and_heights_show():
    text = "\n".join(summary(STATE))
    assert "Crate (2 m, id BP_BaseBuilding_Crate_C_1, Open)" in text and "Base Building Crate" not in text
    assert "Loot Chest Prefab Tier2 World (47 m, 15 m up, id BP_LootChest_Prefab_Tier2_World_C_9, Open)" in text
    assert "Built pieces: Square Foundation (5 m, id BP_Foundation_C_7, ghost piece)" in text
    assert text.count("BP_BaseBuilding_Crate_C_1") == 1  # usable crate listed once, not again under Built pieces


def test_no_invented_heights_without_the_bodys_up_m():
    state = {"position": [0, 0, -30], "nearby_entities": [{"id": "k1", "name": "Kebbit", "distance": 5, "alive": True,
                                                            "position": [0, 0, 0]}]}
    things = perceived(state)
    assert things[0].up_m is None and "up" not in things[0].label()


def test_whose_each_piece_is_from_his_own_record():
    """The game keeps no owner per piece; deconstruct.lua's ledger sets mine True/False (nil = unchecked). His
    crate and someone else's are never counted as one group (brain run 19:42Z took others' crates for his)."""
    crate = {"name": "Crate", "piece": "BUILDPIECE_Interior_Crate", "up_m": 0.0}
    state = {"position": [0, 0, -30],
             "interactables": [{"id": f"C_{i}", "name": "Base Building Crate", "prompt": "Open", "distance": d}
                               for i, d in ((1, 3.0), (2, 9.0), (3, 12.0))],
             "structures": [{**crate, "id": "C_1", "distance": 3.0, "mine": True},
                            {**crate, "id": "C_2", "distance": 9.0, "mine": False},
                            {**crate, "id": "C_3", "distance": 12.0, "mine": False},
                            {"id": "W_1", "name": "Wall", "piece": "DA_T1_Wall_Large", "distance": 4.0, "mine": False},
                            {"id": "F_1", "name": "Square Foundation", "piece": "DA_T1_Foundation_Large", "distance": 5.0}]}
    text = "\n".join(summary(state))
    assert "Crate (3 m, id C_1, yours, Open)" in text
    assert "Crate x2 (9 m, id C_2, not placed by you, Open)" in text
    assert "Wall (4 m, id W_1, not placed by you)" in text
    assert "Square Foundation (5 m, id F_1)" in text  # unchecked: no claim either way


def test_house_line_says_which_frames_are_open_doorways():
    """build.lua edges + inside: a door-frame wall with no door in it is an open doorway (live 20:29Z: 4 door-frame
    walls, 1 door, read as a closed house)."""
    from brain.situation import house_line
    state = {"structures": [{"id": "BuildingPiece_93", "name": "Square Foundation", "distance": 3.0, "mine": True,
                             "edges": {"N": "WALL WITH DOOR FRAME BuildingPiece_95", "E": "WALL WITH WINDOW FRAME BuildingPiece_96",
                                       "S": "WALL WITH DOOR FRAME BuildingPiece_94", "W": "Wall BuildingPiece_97"},
                             "inside": {"N": "an open doorway, no door in it", "E": "a window opening",
                                        "S": "Door BP_T1_Door_C_1"}}]}
    line = house_line(state)
    assert "N WALL WITH DOOR FRAME BuildingPiece_95 (an open doorway, no door in it)" in line
    assert "E WALL WITH WINDOW FRAME BuildingPiece_96 (a window opening)" in line
    assert "S WALL WITH DOOR FRAME BuildingPiece_94 (with Door BP_T1_Door_C_1 in it)" in line
    assert "W Wall BuildingPiece_97; over it: nothing" in line

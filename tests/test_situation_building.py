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

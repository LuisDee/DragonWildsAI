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


def test_asked_here_keeps_the_place_he_was_asked():
    """A request's "here": the situation keeps where he stood when asked (live 21:13Z: he gathered, then built 31 m
    away), and where the player was when in sight. Perception only."""
    from brain.situation import asked_at, with_asked
    at_ask = {"position": [80.7, 1913.1, -30.7], "players": [{"name": "Zezima", "distance": 3, "position": [82.0, 1914.0, -30.6]}]}
    a = asked_at(at_ask, "Zezima", "claude build yourself a small house here")
    assert a == {"position": [80.7, 1913.1, -30.7], "request": "claude build yourself a small house here", "player": "Zezima",
                 "player_at": [82.0, 1914.0, -30.6]}
    later = with_asked({"position": [111.7, 1901.9, -30.5]}, a)
    text = "\n".join(summary(later))
    assert 'Asked: "claude build yourself a small house here" when you stood at (81, 1913, -31), 33 m from where you are now; Zezima was at (82, 1914, -31)' in text
    assert asked_at(at_ask, "Zezima", "") is None and with_asked({"position": [0, 0, 0]}, None) == {"position": [0, 0, 0]}
    assert "asked_at" not in "\n".join(summary({"position": [0, 0, 0]}))


def test_bases_line_from_his_own_record():
    """my_bases (the body's ledger of what he built, clustered): one line at any distance, nearest first (live 01:29Z:
    he walled in a new wheel 100 m from his own roofed house, which nothing in state named)."""
    st = {"position": [0, 0, 0], "my_bases": [
        {"centre": [70, -70, 0], "distance_m": 99, "direction": "NE", "pieces": 14, "covered": True,
         "stations": ["Spinning Wheel", "Crafting Table"]},
        {"centre": [0, 300, 0], "distance_m": 300, "direction": "S", "pieces": 1, "covered": False, "stations": ["Campfire"]}]}
    text = "\n".join(summary(st))
    assert ("Your bases (what you built): 99 m NE, roofed, 14 pieces (Spinning Wheel, Crafting Table)"
            " | 300 m S, no roof, 1 piece (Campfire)") in text
    assert "my_bases" not in text and "Your bases" not in "\n".join(summary({"position": [0, 0, 0]}))


def test_bases_and_farm_survive_a_full_digest():
    """MAX_LINES cut every line after Creatures (live 2026-11-02 05:33Z: "where's the farm?" with his own plot 7.5 m
    off): with every optional line filled, 'Your bases' and 'Your farm' still reach him, and burn_odds is no noise."""
    st = {"position": [0, 0, 0], "health": 50, "max_health": 100, "places": [f"place{i}" for i in range(8)],
          "my_bases": [{"centre": [70, -70, 0], "distance_m": 99, "direction": "NE", "pieces": 14, "covered": True}],
          "your_farm": "1 plot 7.5 m N: weeds coming up", "burn_odds": {"level1": 0.0, "level2": 0.46},
          "fishing_spots": [{"name": "Net Fishing Spot", "distance_m": 4}], "ore_veins": [{"name": "Copper", "distance_m": 9}],
          "nearby_entities": [{"kind": k, "name": f"{k}{i}", "id": f"{k}{i}", "distance": 5 + i, "position": [i, i, 0]}
                              for i, k in enumerate(["creature", "item", "player", "resource", "creature", "item"])]}
    lines = summary(st)
    text = "\n".join(lines)
    assert "Your bases (what you built): 99 m NE" in text and "Your farm: 1 plot 7.5 m N" in text
    assert "Burn odds" not in text


def test_an_empty_creature_list_is_said_in_words():
    """Chain sitting 2 (2026-11-17, run 103436) and window s26: `attack {"target": "rat"}` with no creature in the
    list, answered unknown_target, a miss. With no Creatures line the digest did not say the list was read and empty
    (a replay of the turn: attack 6 of 15 as logged, 0 of 15 with the line)."""
    st = {**STATE, "nearby_entities": [], "nearby_m": 50}
    assert "Creatures: none in sight within 50 m" in summary(st)
    assert "Creatures: none in sight" in summary({**STATE, "nearby_entities": []})  # a body that states no reach
    # a dead one is not a creature in sight
    dead = {"id": "rat_1", "name": "Giant Rat", "distance": 4.0, "alive": False}
    assert "Creatures: none in sight within 50 m" in summary({**st, "nearby_entities": [dead]})


def test_no_creatures_line_when_the_list_was_not_read_or_was_cut():
    text = lambda st: "\n".join(summary(st))
    assert "Creatures" not in text(STATE)  # no list in the state at all
    assert "Creatures" not in text({**STATE, "nearby_entities": [], "not_implemented": ["nearby_entities"]})
    # creatures in sight that the caps cut from the list are on the "Further off" line: "none" would be false
    cut = {**STATE, "nearby_entities": [], "nearby_m": 50,
           "further_off": [{"name": "Giant Rat", "category": "creatures", "count": 2, "distance": 44.0}]}
    assert "Creatures: none" not in text(cut) and "Giant Rat" in text(cut)
    seen = {**STATE, "nearby_entities": [{"id": "rat_1", "name": "Giant Rat", "distance": 4.0, "hostile": True}]}
    assert "Creatures: hostile Giant Rat" in text(seen) and "none in sight" not in text(seen)

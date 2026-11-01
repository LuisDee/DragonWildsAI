"""brain/gear_plan.py: the gear profile for his region, from the game's items and recipes data."""
from brain import gear_plan


def _state(**kw):
    st = {
        "gear": {"Body": "ITEM_Armour_T1_Body_Adventurers", "Legs": "ITEM_Armour_T1_Legs_Adventurers", "HeldRight": "ITEM_Club_Stone"},
        "inventory": {"ITEM_Resources_AnimalBone": 4, "ITEM_Resources_AnimalHide": 4},
        "recipes_unlocked": ["RECIPE_Weapon_Club_Stone"],
        "nearby_entities": [{"name": "Cow", "power_level": 2, "alive": True}, {"name": "Kebbit", "power_level": 1, "alive": True}],
    }
    st.update(kw)
    return st


def test_pl_is_mean_of_worn_armour_rounded_down():
    p = gear_plan.plan(_state())
    assert p["pl_now"] == 0  # body 1 + legs 1 + no head = 2/3 -> 0 (live: PL 0 in T1 body+legs)
    assert p["enemy_pl"] == 2
    assert p["pl_full_set"] == 2


def test_reinforced_set_is_reachable_through_leather_and_says_how():
    p = gear_plan.plan(_state())
    body = {o["name"]: o for o in p["slots"]["body"]["best"]}
    rb = body.get("Reinforced Body")
    assert rb and rb["status"] == "unlocks" and rb["unlocks_with"]["hold"] == ["Leather", "Animal Bone"]
    assert "Leather x8" in rb["short"] and any("Animal Hide" in v and "Tannery" in v for v in rb["via"])


def test_capped_at_the_region_but_owned_gear_counts_and_where():
    p = gear_plan.plan(_state(), stash={"your base crate at (104,1858)": ["ITEM_Shield_Bronze"]})
    assert all(o["pl"] <= 2 for o in p["slots"]["body"]["best"])  # no bronze plate for Brynmoor
    off = p["slots"]["left_hand"]["best"]
    assert off and off[0]["name"] == "Bronze Shield" and off[0]["where"] == ["your base crate at (104,1858)"]
    text = "\n".join(gear_plan.lines(p))
    assert "Bronze Shield (PL 3): you have one: your base crate at (104,1858)" in text


def test_remembered_grave_items_are_owned():
    st = _state(graves_remembered=[{"position": [44.4, 1745.0, -30.0], "lost": ["Bronze Sword x1", "Air Rune x10"]}])
    p = gear_plan.plan(st)
    w = p["slots"]["right_hand"]["best"]
    assert w and w[0]["name"] == "Bronze Sword" and w[0]["where"] == ["your grave at (44,1745)"]


def test_describe_never_raises():
    assert gear_plan.describe({"gear": None, "nearby_entities": None})[0].startswith("Gear vs this area")


def test_weak_creatures_alone_do_not_cap_him_at_his_starter_tier():
    p = gear_plan.plan(_state(nearby_entities=[{"name": "Kebbit", "power_level": 1, "alive": True}]))
    assert p["slots"]["body"]["best_pl"] == 2 and p["pl_full_set"] == 2

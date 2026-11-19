"""brain/gear_plan.py: the gear profile for his region, from the game's items and recipes data."""
from brain import gear_plan

L3_STATE = {  # ClaudeDev's armour in the L3 runs of 19 Nov: Leather Cowl (PL 2), Adventurer's Tunic and Leggings (PL 1)
    "gear": {"Head": "ITEM_Armour_T2_Head_Leather", "Body": "ITEM_Armour_T1_Body_Adventurers",
             "Legs": "ITEM_Armour_T1_Legs_Adventurers", "HeldRight": "ITEM_Sword_Bronze"},
    "inventory": {"ITEM_Resources_AnimalHideScraps": 7},
    "power_level": 0.0,
    "nearby_entities": [{"name": "Kebbit", "power_level": 1, "alive": True}],
}


def test_worn_armour_gives_his_pl_and_pieces():
    w = gear_plan.worn_armour(L3_STATE)
    assert w["pl"] == 1 and w["pieces"] == ["Leather Cowl PL 2", "Adventurer's Tunic PL 1", "Adventurer's Leggings PL 1"]


def test_for_vault_states_the_vaults_pl_and_the_armour_at_that_pl():
    """L3 2026-11-19: the vault's PL 2 was on its card only; the gear line (cap worn top + 1 = 3, no vault) sent him
    after a PL 3 bronze set for 30 min while the Reinforced set (PL 2) needed bones and leather."""
    f = gear_plan.for_vault(L3_STATE, "Crasorak Kara")
    assert f["vault"] == "Crasorak Kara" and f["enemies_pl"] == 2 and "Vault Overlord x1 PL 2" in f["enemies"]
    assert f["you_pl_from_worn_armour"] == 1 and f["you_pl_game_reads"] == 0.0
    assert f["you_wear"] == ["Leather Cowl PL 2", "Adventurer's Tunic PL 1", "Adventurer's Leggings PL 1"]
    assert "this vault's PL 2" in f["armour"] and "Reinforced Body/Platelegs" in f["armour"]
    assert "PL 3" not in f["armour"]  # the vault's level caps the line, not one tier above what he wears
    assert "PL 3" in (gear_plan.set_line(gear_plan.plan(L3_STATE), L3_STATE) or "")  # without the vault: +1
    assert gear_plan.for_vault(L3_STATE, "Temple Woods vault")["vault"] == "Crasorak Kara"  # an alias names it


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
    assert "Bronze Shield (PL 3): you have one, not on you: your base crate at (104,1858)" in text


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


def test_whole_set_per_style_sums_the_pieces_and_names_the_no_thread_style():
    """Live 2026-11-02 gear_up: per-slot lines showed the light piece first (one thread short) and he stopped at the
    wheel's blocker; the whole bill per style shows heavy needs leather and bone, no thread."""
    st = _state(inventory={"ITEM_Resources_AnimalBone": 4, "ITEM_Resources_Animal_Hide": 4,
                           "ITEM_Resources_Thread_Coarse": 3, "ITEM_Resources_Coarse_Animal_Fur": 13})
    p = gear_plan.plan(st)
    rows = {s["style"]: s for s in gear_plan.sets(p, st)}
    heavy = rows["heavy"]
    assert set(heavy["slots"]) == {"head", "body", "legs"}
    short = {x["name"]: x for x in heavy["short"]}
    assert short["Animal Bone"]["count"] == 4 + 10 + 8 - 4 and "Coarse Thread" not in short
    assert any("Tannery" in w for w in short["Leather"]["ways"]) and "Animal Hide x4" in short["Leather"]["carried"]
    line = gear_plan.set_line(p, st)
    assert "heavy PL 2 (Reinforced Helmet/Body/Platelegs)" in line and "unlock once you hold Leather + Animal Bone" in line


def test_station_rule_named_with_the_station():
    # live 2026-11-02 gear_up: 400 s building and roofing a Spinning Wheel in the open; the plan never said it needs a roof
    from brain import gear_plan as gp
    assert "roof" in gp._at("Spinning Wheel") and gp._at("Tannery") == "Tannery"
    ways = [w for r in gp._by_output().get("ITEM_Resources_Thread_Coarse") or [] for w in r.get("stations") or []]
    assert "Spinning Wheel" in ways  # the recipe data names it the way the rules file keys it


def test_pl_with_one_piece_worn_now():
    # live 2026-11-02 gear_up run 5: the Leather Cowl (PL 2) he carried would have taken him from PL 0 to 1 at once
    from brain import gear_plan as gp
    p = {"slots": {"head": {"worn": None, "worn_pl": None}, "body": {"worn": "Adventurer's Tunic", "worn_pl": 1},
                   "legs": {"worn": "Adventurer's Leggings", "worn_pl": 0}}}
    assert gp.pl_with(p, "head", 2) == 1 and gp.pl_with(p, "legs", 0) == 0


# ------------------------------------------------------------------ a vault's enemies (data/bestiary.json)
COWL = {"Head": "ITEM_Armour_T2_Head_Leather", "Body": "ITEM_Armour_T1_Body_Adventurers",
        "Legs": "ITEM_Armour_T1_Legs_Adventurers", "HeldRight": "ITEM_Sword_Bronze"}


def test_vault_target_is_its_enemies_level_not_the_best_set_he_can_reach():
    """L3 'gear up for the vault': with a PL 2 cowl worn the old target was one tier above it (PL 3 bronze, from
    Ghornfell); Crasorak Kara's enemies are all PL 2 (wiki page 3515), so the vault asks PL 2."""
    st = _state(gear=COWL, nearby_entities=[{"name": "Kebbit", "power_level": 1, "alive": True}])
    assert gear_plan.plan(st)["pl_full_set"] == 3  # the region rule: worn tier + 1
    p = gear_plan.plan(st, vault="Crasorak Kara")
    assert p["enemy_pl"] == 2 and p["pl_full_set"] == 2
    assert all(o["pl"] <= 2 or o["status"] == "owned" for s in p["slots"].values() for o in s["best"])
    v = p["vault"]
    assert v["vault"] == "Crasorak Kara" and v["pl"] == 2 and "Vault Overlord x1 PL 2" in v["enemies"]
    assert v["rows"][0].startswith("vaults/Crasorak Kara/enemies:") and "wiki 3515" in v["rows"][0]
    # rats (x9, weak to Stab, resist Crush) outnumber the guardians weak to Crush (x7); the Overlord's Crush is level 5 only
    assert v["damage_pref"][0] == "Stab" and "Crush" not in v["damage_pref"]
    assert "Vault Overlord x1" not in v["weak"].get("Crush", [])


def test_vault_need_reads_qualified_weaknesses_and_aliases():
    import pytest
    b = {"vaults": {"Test Kara": {"power_level": "3", "aliases": ["test vault"], "enemies": [
        {"name": "A", "amount": "2", "power_level": "3"}, {"name": "B", "amount": "1"}]}},
        "creatures": {"A": {"weak": ["Crush (level 3)"], "resist": ["None"]}, "B": {"weak": ["Fire (level 5)"]}}}
    n = gear_plan.vault_need("test vault", b)
    assert n["vault"] == "Test Kara" and n["pl"] == 3 and n["damage_pref"] == ["Crush"]
    assert n["enemies"] == ["A x2 PL 3", "B x1 PL 3"]
    with pytest.raises(KeyError):
        gear_plan.vault_need("Nowhere Kara", b)


def test_no_vault_is_unchanged():
    for st in (_state(), _state(gear=COWL), {"gear": {}, "inventory": {}, "recipes_unlocked": [], "nearby_entities": []}):
        a, b = gear_plan.plan(st), gear_plan.plan(st, vault=None)
        assert a == b and "vault" not in a
        assert not any("dtypes" in o for s in a["slots"].values() for o in s["best"])
        assert gear_plan.lines(a) == gear_plan.lines(b)

"""The weapons, enchant, gear-for-this-area and death-rule lines (Luis's session 2026-11-01 21:49-22:21Z)."""
from brain import situation, spells


def test_each_weapon_shows_its_real_damage_and_an_empty_ammo_slot():
    """22:05Z he took the bow (~4/hit, no arrows loaded) over a club doing ~14, with neither number in sight."""
    line = situation.weapons_line({"weapons_known": {
        "Stone Club": {"kind": "melee", "per_hit": 16.8, "per_s": 16, "from": "learned"},
        "Ash Shortbow": {"kind": "ranged", "per_hit": 4, "from": "learned", "ammo_slot": "Ammo", "ammo": 0},
        "Ash Battlestaff": {"kind": "magic", "per_hit": 52, "from": "learned", "ammo_slot": "MagicAmmo", "ammo": 120}}})
    assert line.startswith("Your weapons: Stone Club (melee) ~16.8/hit, 16/s (learned)")
    assert "Ash Shortbow (ranged) ~4/hit (learned), ammo slot EMPTY: can't use it" in line
    assert "Ash Battlestaff (magic) ~52/hit (learned), 120 in its ammo slot" in line
    assert situation.weapons_line({}) is None


def test_an_enchant_on_his_weapon_is_in_the_you_line_with_its_time_left():
    st = {"health": 100, "max_health": 100,
          "held_enchant": {"effect": "HEED_EnchantWeaponFire", "adds": "DamageType.Magical.Fire", "left_s": 212}}
    assert "Fire enchant on your weapon, 212 s left" in situation.summary(st)[0]
    assert situation.enchant_words({}) is None and situation.enchant_words({"held_enchant": None}) is None


def test_an_element_spell_says_its_element_and_when_it_is_worth_casting():
    fire = spells.element_words({"proof": {"effect": [{"kind": "held_item_effect", "time_limit_s": 300.0,
                                                       "damage_types": ["DamageType.Magical.Fire"]}]}})
    assert fire == "+Fire damage on melee hits 300 s; cast before melee unless the enemy resists Fire"
    bolt = spells.element_words({"proof": {"effect": [{"kind": "projectile", "damage_types": ["DamageType.Magical.Water"]}]}})
    assert bolt == "Water damage: best on an enemy weak to Water"
    assert spells.element_words({"proof": {"effect": [{"kind": "x"}]}}) is None


def test_the_gear_line_is_one_line_and_only_when_he_is_under_geared(monkeypatch):
    from brain import gear_plan
    p = {"pl_now": 0, "pl_full_set": 2, "enemy_pl": 2, "enemies": ["Cow PL 2"], "slots": {}}
    monkeypatch.setattr(gear_plan, "plan", lambda state, stash=None: p)
    monkeypatch.setattr(gear_plan, "lines", lambda plan, max_opts=3, compact=False: ["Gear vs this area: you are PL 0", "  head: a",
                                                                      "  body: b"])
    assert situation.gear_line({}) == "Gear vs this area: you are PL 0 Per slot: head: a | body: b"
    p["pl_now"] = 2
    assert situation.gear_line({}) is None


def test_overloaded_is_in_the_you_line_with_the_weights():
    st = {"health": 100, "max_health": 100, "bag": {"used": 30, "capacity": 32, "weight": 403.2, "max_weight": 400,
                                                    "encumbered": True}}
    assert "OVERLOADED 403/400 carry weight: walk only, no sprint or jumps" in situation.summary(st)[0]
    assert situation.load_words({"bag": {"encumbered": False, "weight": 10, "max_weight": 400}}) is None
    assert situation.load_words({}) is None


def test_dead_says_so_and_offers_no_need():
    """Chat ladder 2026-11-02 01:17:08Z: the read at his death offered "Need health (dying [0%]) -> Fillet heals 20" and
    he ate his last Fillet into the respawn."""
    from brain import needs
    st = {"dead": True, "health": 0.0, "max_health": 100.0, "sustenance": 98, "sustenance_max": 100,
          "inventory_items": [{"item": "ITEM_Fillet", "name": "Fillet", "count": 1}]}
    assert situation.summary(st)[0].startswith("You: DEAD: respawning")
    assert needs.lines(st) == []
    assert not any(ln.startswith("Need ") for ln in situation.summary(st))


def test_overloaded_is_a_need_with_the_heaviest_stacks_and_where_to_put_them():
    """02:44Z: 423/400 on a flax hunt, every trip at walking pace; a player stores or drops the junk first."""
    from brain import needs
    cat = {"items": {"ITEM_Stone": {"weight": 2.0}, "ITEM_Fur": {"weight": 0.5}}}
    st = {"bag": {"encumbered": True, "weight": 423, "max_weight": 400},
          "inventory_items": [{"item": "ITEM_Stone", "name": "Stone", "count": 77, "where": "bag"},
                              {"item": "ITEM_Fur", "name": "Fur", "count": 4, "where": "bag"}],
          "interactables": [{"name": "Ash Chest", "kind": "storage", "distance": 12.0, "id": "c1"},
                            {"name": "Player Gravestone", "kind": "storage", "distance": 1.0, "id": "g1"}]}
    ln = needs.lines(st, cat)
    assert len(ln) == 1 and ln[0].startswith("Need load (OVERLOADED 423/400, walk only")
    assert "heaviest: Stone x77 (154); Fur x4 (2)" in ln[0] and "Ash Chest (12 m, id c1)" in ln[0]
    assert "Gravestone" not in ln[0]
    assert needs.lines({"bag": {"encumbered": False}}, cat) == []


def test_weapons_line_names_the_slotted_arrows_and_the_better_ones_carried():
    """03:47Z: he crafted Fang Arrows and shot his 2 Stone ones; the line said only "2 in its ammo slot"."""
    st = {"weapons_known": {"Ash Shortbow": {"kind": "ranged", "per_hit": 4, "from": "learned", "ammo_slot": "Ammo", "ammo": 2,
                                             "ammo_name": "Stone Arrow", "ammo_carried": [{"name": "Fang Arrow", "count": 33}]}}}
    ln = situation.weapons_line(st)
    assert "2 Stone Arrow (PL 1, 5-12 dmg) in its ammo slot; also carried: 33 Fang Arrow (PL 2, 10-24 dmg)" in ln
    st["weapons_known"]["Ash Shortbow"].update(ammo=0, ammo_carried=None)
    assert "ammo slot EMPTY" in situation.weapons_line(st)


def test_no_weapon_says_so_and_where_weapons_are():
    """06:05Z: respawned with nothing, he punched a PL2 rat to death (his) with a dagger 21 m off and his bow in a grave."""
    st = {"weapons_known": [], "nearby_items": [{"name": "Stone Dagger", "id": "x1", "distance": 21.0},
                                                {"name": "Oak Logs", "id": "x2", "distance": 18.0}],
          "graves_remembered": [{"distance": 214, "lost": ["Fillet x16", "Clean Water x13", "Ash Shortbow x1"]}]}
    assert situation.weapons_line(st) == ("Your weapons: NONE in hand or bag (bare hands); lying loose nearby (not yours, free to take): Stone Dagger 21 m; "
                                          "in your graves: Ash Shortbow (214 m)")
    assert situation.weapons_line({}) is None  # nothing known about weapons: no claim

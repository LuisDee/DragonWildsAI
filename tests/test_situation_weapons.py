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
    monkeypatch.setattr(gear_plan, "plan", lambda state: p)
    monkeypatch.setattr(gear_plan, "lines", lambda plan, max_opts=3: ["Gear vs this area: you are PL 0", "  head: a",
                                                                      "  body: b"])
    assert situation.gear_line({}) == "Gear vs this area: you are PL 0 Per slot: head: a | body: b"
    p["pl_now"] = 2
    assert situation.gear_line({}) is None

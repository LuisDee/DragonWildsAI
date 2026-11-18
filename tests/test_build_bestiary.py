"""tools/build_bestiary.py: wikitext parsing, entries, the reverse index, name matching and the lookup merge.
Synthetic pages only, plus read-only checks of data/bestiary.json when it exists. The held-out eval half is never read."""
import json
import re
from pathlib import Path

import pytest

from tools import build_bestiary as bb

ROOT = Path(__file__).resolve().parents[1]

RAT = """{{External|rs=Giant rat}}
{{Infobox Monster
|version1 = Power level 1
|version2 = Power level 2
|name = Giant Rat
|health1 = 50
|health2 = 100
|race = Rat
|power_level1 = 1
|power_level2 = 2
|weakness = Stab
|resistance = Crush
|location1 = [[Temple Woods]]
|location2 = Some [[Dragonkin Vault]]s
| aggressive = yes
}}
'''Giant rats''' are [[power level]] 1-2 creatures found in [[Temple Woods]]. It is recommended to bring food.

==Attacks==
* Bite: The rat bites the player.
* Lunge: The rat jumps forward; simply dodge out of the way.

==Drops==
===100%===
{{DropsTableHead}}
{{DropsLine|name=Raw Rat Meat|quantity=1|rarity=Always}}
{{DropsLine|name=Hard Leather|quantity=2-4|rarity=Always}}
{{DropsTableBottom}}
===Other===
{{DropsTableHead}}
{{DropsLine|name=Shiny Tooth|quantity=1|rarity=1/50|raritynotes={{DropNote|Only in [[Fellhollow]]}}}}
{{DropsTableBottom}}
"""

OGRE = """{{Multi Infobox
|text1 = Fellhollow
|item1 =
{{Infobox Monster
| name = Zogre
| health = 4200
| power_level = 5
| weakness = Crush
| resistance = Slash, Stab, Air
| location = [[Hope's Fall]]<br>[[Test Kara]]
}}
|text2 = Dowdun Reach
|item2 =
{{Infobox Monster
| name = Zogre
| health = 6000
| power_level = 6
| weakness = Crush
| location = Dowdun Reach
}}
}}
'''Zogres''' are undead ogres. The zogre will also throw rocks at the player.
==Attacks==
* Belly Flop: The zogre will jump into the air and flop onto the ground.
==Drops==
===100%===
{{DropsLine|name=Hard Leather|quantity=4-8|rarity=Always}}
"""

VAULT = """{{Infobox Scenery
|name = Test Kara
|location = [[Fractured Plains]]
}}
'''Test Kara''' is the [[dragonkin vault]] found in the [[Fractured Plains]]. The vault starts off locked, and must be unlocked by interacting with 4 dragonkin statues. It is recommended to bring antipoison.

==Location==
{{Map|Test Kara|width=250px|height=250px|center=1,2|zoom=3}}

==Enemies==
* [[Power level]] 4 variants of the following:
{| class="wikitable"
|-
! Enemy !! Amount
|-
| [[Giant rat]] || 8
|-
| [[Zogre]] || 1
|}
* [[Exploding plant trap]]s

==Resources==
===Nodes===
* [[Copper ore node]]
===Other===
* [[Chest (Test Kara)]]
* [[Vault core]] - three total.
"""

CHEST = """Several '''chests''' are found in the [[Test Kara]] vault.
==Drops==
===Runes===
{{DropsTableHead}}
{{RunesDropTable}}
{{DropsTableBottom}}
==Additional==
An additional 2-3 drops will be rolled.
===Skill tomes===
{{SkillTomesV1DropTableIntro|10/100}}
{{DropsTableHead}}
{{SkillTomesV1DropTable|10/100}}
{{DropsTableBottom}}
"""

BOSS = """==List of bosses==
===Vault bosses===
{| class="wikitable sortable mw-collapsible"
!colspan=2 |Boss
!Power level
!Health
!Weakness
!Location
!Drops
|-
|[[Zogre]]
|[[File:Zogre.png|center|150x150px]]
|4
|4200
|Crush
|[[Test Kara]]
|{{plink|Zogre Pack}}
|}
"""

DV = """==Vaults==
===Vault Locations===
{| class="wikitable sortable"
! colspan="4" style="font-size:110%;" | Standard Progression Order
|-
! Order
! Vault
! Power level
! Area
|-
| 1
| [[Test Kara]]
| 4
| [[Fractured Plains]]
|}
==Rewards==
===Resources===
* [[Vault shard]] - Found within vault chests and dropped from vault monsters.
"""


def page(pid, title, wt):
    return {"pageid": pid, "title": title, "wikitext": wt, "sections": []}


RAT_SEEN = [{"name": "Attack 01", "asset": "ATK_GiantRat_Attack_01", "seen": 9, "hits_on_him": 2, "impact_s": 1.07,
             "lunge_m": 2.4, "damage_to_him": 13.0}]
# metabot.gg snapshot: it may fill Zogre's empty immune field, never the rat's wiki weakness
EXTERNAL = {"creatures": {"Giant Rat": {"journal": {"weak": ["Fire"]}},
                          "Ogre": {"affinity": {"immune": ["Poison"]}}}}


@pytest.fixture(scope="module")
def doc(tmp_path_factory):
    mirror = bb.Mirror.from_pages({
        "Giant Rat": page(1, "Giant Rat", RAT), "Zogre": page(2, "Zogre", OGRE), "Test Kara": page(3, "Test Kara", VAULT),
        "Chest (Test Kara)": page(4, "Chest (Test Kara)", CHEST), "Boss": page(5, "Boss", BOSS),
        "Dragonkin Vault": page(6, "Dragonkin Vault", DV), "Vault Shard": page(7, "Vault Shard", "x"),
    }, {"Giant rat": "Giant Rat", "Ogre": "Zogre", "Dungeon": "Dragonkin Vault"})
    ext = tmp_path_factory.mktemp("ext") / "bestiary_external.json"
    ext.write_text(json.dumps(EXTERNAL), encoding="utf-8")
    orig = bb.class_aliases, bb.observed_attacks, bb.apply_external
    bb.class_aliases = lambda names, dump=None, combat=None: {"Giant Rat": ["GiantRat"]}
    bb.observed_attacks = lambda names, skills=None: {"Giant Rat": RAT_SEEN}
    bb.apply_external = lambda creatures, path=None: orig[2](creatures, ext)
    try:
        return bb.build(mirror)
    finally:
        bb.class_aliases, bb.observed_attacks, bb.apply_external = orig


# ---------------------------------------------------------------- wikitext


def test_plain_turns_links_and_known_templates_to_words():
    assert bb.plain("[[Giant rat|giant rats]] in [[Temple Woods]]") == "giant rats in Temple Woods"
    assert bb.plain("{{plink|Velgar's Head}} and {{NA}}") == "Velgar's Head and none"
    assert bb.plain("[[File:x.png|thumb|a [[b]]]]'''Bold'''<br>next") == "Bold, next"


def test_split_top_respects_nested_links_and_templates():
    assert bb.split_top("a|b=[[x|y]]|c={{t|1}}") == ["a", "b=[[x|y]]", "c={{t|1}}"]


def test_table_rows_expand_colspan_and_take_the_last_header_row():
    (header, rows), = bb.table_rows(DV.split("==Rewards==")[0])
    assert header == ["Order", "Vault", "Power level", "Area"]
    assert bb.one_line(rows[0][1]) == "Test Kara"
    (header, rows), = bb.table_rows(BOSS)
    assert header[:3] == ["Boss", "Boss", "Power level"]


def test_advice_and_orders_are_cut_from_prose():
    assert bb.facts_only(["It is recommended to bring food."]) == []
    assert bb.fact_clauses("The rat jumps forward; simply dodge out of the way.") == "The rat jumps forward."
    assert bb.fact_clauses("This stuns him, then retaliate while he is down.") == "This stuns him."


# ---------------------------------------------------------------- entries


def test_creature_entry_fields_and_sources(doc):
    rat = doc["creatures"]["Giant Rat"]
    assert [v["power_level"] for v in rat["variants"]] == ["1", "2"]
    assert rat["weak"] == ["Stab"] and rat["resist"] == ["Crush"]
    assert "Temple Woods" in rat["locations"]
    assert {d["item"] for d in rat["drops"]} == {"Raw Rat Meat", "Hard Leather", "Shiny Tooth"}
    assert rat["drops"][2]["note"] == "Only in Fellhollow"
    assert rat["class_names"] == ["GiantRat"]
    for field in ("variants", "weak", "resist", "locations", "drops", "attacks"):
        assert rat["src"][field] == [1]
    assert "Power level 1, health 50" in rat["text"] and "Weak to Stab" in rat["text"]
    assert "Test Kara (8, power level 4)" in rat["text"]
    assert "dodge" not in rat["text"].lower() and "recommended" not in rat["text"]


def test_multi_infobox_variants_keep_their_labels(doc):
    z = doc["creatures"]["Zogre"]
    assert [(v.get("label"), v["power_level"], v["health"]) for v in z["variants"]] == \
        [("Fellhollow", "5", "4200"), ("Dowdun Reach", "6", "6000")]
    assert z["resist"] == ["Slash", "Stab", "Air"]
    assert "Belly Flop: The zogre will jump" in z["text"]
    assert "vault boss in Test Kara" in z["text"]
    assert "Ogre" in z["aliases"]


def test_vault_entry_enemies_boss_chests_and_opening(doc):
    v = doc["vaults"]["Test Kara"]
    assert [(r["name"], r["amount"], r["power_level"]) for r in v["enemies"]] == [("Giant Rat", "8", "4"), ("Zogre", "1", "4")]
    assert v["boss"][0]["creature"] == "Zogre" and v["power_level"] == "4" and v["order"] == "1"
    assert "4 dragonkin statues" in v["opens"][0]
    assert "skill tomes 10/100" in v["chests"] and "not in the mirror" in v["chests"]
    assert v["src"]["chests"] == [4] and v["src"]["boss"] == [5] and v["src"]["power_level"] == [6]
    assert "Hazards [wiki]: Exploding plant traps" in v["text"]
    assert "recommended" not in v["text"]


def test_reverse_index_names_every_source(doc):
    rows = doc["dropped_by"]["Hard Leather"]["rows"]
    assert {(r["from"], r["amount"], r["rate"]) for r in rows} == {("Giant Rat", "2-4", "always"), ("Zogre", "4-8", "always")}
    assert "Zogre Pack" in doc["dropped_by"]  # from the Boss table
    assert "Vault core" in doc["dropped_by"] or "Vault Core" in doc["dropped_by"]
    assert "chests" in doc["dropped_by"]["Vault Shard"]["text"]


def test_every_text_is_short(doc):
    for sec in ("creatures", "vaults", "dropped_by"):
        for e in doc[sec].values():
            assert len(e["text"]) <= bb.ENTRY_CHARS


def test_missing_fields_say_so(doc):
    mirror = bb.Mirror.from_pages({"Blob": page(9, "Blob", "{{Infobox Monster\n|name=Blob\n|power_level=1\n}}\nA blob.")})
    d = bb.build(mirror)
    t = d["creatures"]["Blob"]["text"]
    assert "Weak to: not in the mirror." in t and "Drops: not in the mirror." in t and "Attacks: not in the mirror." in t


MAGPIE = """{{Infobox Monster
| name = Magpie
| power_level = 1
| aggressive = No
}}
'''Magpies''' are [[power level]] 1 non-aggressive creatures in [[Ashenfall]]. They can be found on most of Ashenfall's territories. They can be scared very easily and fly away when somebody gets near them. Their feathers can be used to create [[arrows]].
"""

DOE = """{{Infobox Monster
| name = Doe
| power_level = 1
}}
'''Does''' are creatures that are non-aggressive and too fast to keep up with on foot; they should be killed via ranged attacks. Does can be alerted and will flee if the player is within 50 metres, and/or if a monster within 50 metres is hit with ranged attacks.
"""

WYRM = """{{Infobox Monster
| name = Wyrm
| power_level = 9
}}
'''Wyrms''' are generals, feared since the god's retreat from the wyrm. The wyrm will also spit fire at the player.
"""

WYRM_STRAT = """Phase 1: once his health is down he breathes fire and flies off into the air.
"""


def test_flee_and_speed_sentences_are_kept_as_behaviour():
    """The wiki's 'scared ... fly away when somebody gets near' (Magpie) is a fact a player is told; it used to be cut
    because only the lead's first sentence was kept. A flee sentence that names attacks is behaviour, not an attack note.
    Lore ('the god's retreat') and boss fight phases on a Strategies page ('flies off into the air') are not behaviour."""
    mirror = bb.Mirror.from_pages({"Magpie": page(11, "Magpie", MAGPIE), "Doe": page(12, "Doe", DOE),
                                   "Wyrm": page(13, "Wyrm", WYRM), "Wyrm/Strategies": page(14, "Wyrm/Strategies", WYRM_STRAT)})
    d = bb.build(mirror)
    mag = d["creatures"]["Magpie"]
    assert mag["behaviour"] == ["They can be scared very easily and fly away when somebody gets near them."]
    assert mag["src"]["behaviour"] == [11]
    assert "Behaviour: They can be scared very easily and fly away when somebody gets near them." in mag["text"]
    assert "found on most" not in mag["text"] and "feathers" not in mag["text"].lower()
    doe = d["creatures"]["Doe"]
    assert doe["lead"].endswith("too fast to keep up with on foot.")  # already the lead: not repeated
    assert doe["behaviour"] == ["Does can be alerted and will flee if the player is within 50 metres, and/or if a "
                                "monster within 50 metres is hit with ranged attacks."]
    assert "attack_notes" not in doe and doe["text"].count("will flee") == 1
    assert "should" not in doe["text"]
    wyrm = d["creatures"]["Wyrm"]
    assert "behaviour" not in wyrm and "flies off" not in wyrm["text"]


# ---------------------------------------------------------------- sources beyond the mirror


def test_external_fills_only_empty_fields_with_a_named_source(doc):
    rat, z = doc["creatures"]["Giant Rat"], doc["creatures"]["Zogre"]
    assert rat["weak"] == ["Stab"] and rat["src"]["weak"] == [1]  # the wiki value is never replaced
    assert z["immune"] == ["Poison"] and z["src"]["immune"] == [bb.METABOT]  # matched through the alias "Ogre"
    assert "Immune to Poison." in z["text"] and "metabot.gg datamined bestiary (immune to)" in z["text"]


def test_observed_attacks_in_entry_and_text(doc):
    rat = doc["creatures"]["Giant Rat"]
    assert rat["observed_attacks"] == RAT_SEEN and rat["src"]["observed_attacks"] == [bb.OWN]
    assert "Attacks seen in his own fights" in rat["text"] and "Attack 01 (seen 9, impact 1.07 s" in rat["text"]
    assert "about 13 damage to him per hit" in rat["text"] and "his own fights (attacks seen)" in rat["text"]
    assert doc["counts"]["creatures_missing"]["attacks_wiki"] == 0  # the rat and the ogre both have wiki attacks


def test_observed_attacks_keep_the_most_seen_record_and_skip_dodges(tmp_path):
    a = {"defense": {"attacks": {
        "Giant Rat:ATK_GiantRat_Attack_01": {"n": 5, "hit": 1, "impact_s": 1.0, "damage": 12.4},
        "Goblin Archer:ATK_RangedGoblin_Dodge_Right": {"n": 3, "avoided": 1},
        "Goblin Archer:class23": {"n": 4},
        "Kebbit:ATK_Kebbit_Attack_01": {"n": 0, "hit": 0},
        "Nobody:ATK_Nobody_Attack": {"n": 9}}}, "build": "1"}
    b = {"defense": {"attacks": {"Giant Rat:ATK_GiantRat_Attack_01": {"n": 50, "hit": 7, "impact_s": 1.1, "lunge_cm": 240,
                                                                        "damage": 13.2}}}, "build": "2"}
    (tmp_path / "dev").mkdir()
    (tmp_path / "dev" / "combat_knowledge.json").write_text(json.dumps(a), encoding="utf-8")
    (tmp_path / "dev" / "combat_memory_X.json").write_text(json.dumps(b), encoding="utf-8")
    got = bb.observed_attacks({"Giant Rat", "Goblin Archer", "Kebbit"}, tmp_path)
    assert list(got) == ["Giant Rat"]
    assert got["Giant Rat"] == [{"name": "Attack 01", "asset": "ATK_GiantRat_Attack_01", "seen": 50, "hits_on_him": 7,
                                 "impact_s": 1.1, "lunge_m": 2.4, "damage_to_him": 13.0, "build": "2"}]
    assert bb.observed_attacks({"Giant Rat"}, tmp_path / "missing") == {}


METABOT_HTML = """<ul><li id="giantrat" class="x_card "><div class="x_cardTop"><span class="x_name">Giant Rat</span>
<span class="x_faction">AI</span></div><div class="x_affinities"><span class="x_weak">Weak: Stab</span>
<span class="x_resist">Resists: Crush</span></div><p class="x_lore">Weakness: Stab
Resistance: Crush</p></li><li id="archon" class="x_card "><div class="x_cardTop"><span class="x_name">Vault Archon</span>
<span class="x_faction">Vault Guardians</span></div><div class="x_affinities"><span class="x_noaff">No notable affinities</span>
</div><p class="x_lore">Weakness: Crush
Resistance: None
Immune: Poison, Bleed, Burning</p></li><li id="b" class="x_card "><div class="x_cardTop"><span class="x_name">BOSS</span>
</div></li><li id="m" class="x_card "><div class="x_cardTop"><span class="x_name">Magpie</span></div>
<div class="x_affinities"><span class="x_noaff">No notable affinities</span></div></li></ul>"""


def test_parse_metabot_and_its_snapshot(tmp_path):
    cards = bb.parse_metabot(METABOT_HTML)
    assert set(cards) == {"Giant Rat", "Vault Archon", "Magpie"}  # the unnamed BOSS card is skipped
    assert cards["Giant Rat"]["affinity"] == {"weak": ["Stab"], "resist": ["Crush"]}
    assert cards["Vault Archon"]["journal"] == {"weak": ["Crush"], "resist": ["None"], "immune": ["Poison", "Bleed", "Burning"]}
    assert "affinity" not in cards["Magpie"]  # "No notable affinities" is not read as a fact
    html_file = tmp_path / "page.html"
    html_file.write_text(METABOT_HTML, encoding="utf-8")
    out = tmp_path / "ext.json"
    snap = bb.fetch_metabot(out, html_file)
    assert snap["url"] == bb.METABOT_URL and "credit" in snap["terms"]
    cr = {"Vault Archon": {"name": "Vault Archon", "aliases": [], "_src": bb.Src()},
          "Magpie": {"name": "Magpie", "aliases": [], "weak": ["None"], "_src": bb.Src()}}
    assert bb.apply_external(cr, out) == 3
    assert cr["Vault Archon"]["weak"] == ["Crush"] and cr["Vault Archon"]["_src"].out()["immune"] == [bb.METABOT]
    assert cr["Magpie"]["weak"] == ["None"] and not cr["Magpie"]["_src"].out()


# ---------------------------------------------------------------- the game's own tables (bestiary_tables_probe.lua)

# The probe's output as the runner writes it (client_io/out/bestiary_tables_probe.json): {ok, result}. Same shapes as
# client_mod/tests/test_bestiary_probe.lua produces over its fake engine.
PROBE = {"ok": True, "result": {
    "probe": "bestiary_tables_probe", "version": 1, "vault": None,
    "unread": ["DT_AIAttackDamage_DowdunReach: table not loaded (/DowdunReach/...)"], "truncated": [],
    "journal": {"found": 3, "with_weaknesses": 3, "entries": [
        {"asset": "JOURNAL_World_Fauna_GiantRat", "name": "Giant Rat", "power_level": 1,
         "weaknesses": ["Weakness: Slash", "Resistance: Crush", "Occasionally lacks confidence"], "locations": ["Temple Woods"],
         "ai_data": "/Game/Gameplay/AI/GiantRat/AIData_GiantRat.AIData_GiantRat_C"},
        {"asset": "JOURNAL_World_Fauna_Zogre", "name": "Zogre", "weaknesses": ["Crush"]},
        {"asset": "JOURNAL_World_Fauna_Wisp", "name": "Plague Wisp", "weaknesses": ["Weakness: Fire"]}]},
    "attack_damage": {"DT_AIAttackDamage_BG": {"rows": {"GiantRat_Bite": 12, "GiantRat_Lunge": 18, "Nobody_Hit": 5}},
                      "DT_AIAttackDamage_Fellhollow": {"rows": []}},
    "attacks": {"registry": {"n": 3, "paths": ["/Game/Gameplay/AI/GiantRat/ATK_GiantRat_Bite.ATK_GiantRat_Bite_C"]},
                "loaded": {
                    "ATK_GiantRat_Bite": {"path": "/Game/Gameplay/AI/GiantRat/Attacks/ATK_GiantRat_Bite.ATK_GiantRat_Bite_C",
                                          "flags": 1, "unblockable": True, "effects": ["GE_Poison_C"],
                                          "hits": [{"table": "DT_AIAttackDamage_BG", "row": "GiantRat_Bite", "damage": 12,
                                                    "types": ["DamageType.Physical.Stab"], "damage_class": 1, "time": 0.6}]},
                    "ATK_Mystery_Swing": {"path": "/Game/Gameplay/AI/Mystery/ATK_Mystery_Swing.ATK_Mystery_Swing_C",
                                          "hits": [{"row": "Mystery_Swing", "table_loaded": False}]}}},
    "enemy_loot": {"DT_EnemyLootDropTable": {"rows": {
        "GiantRat": [{"min_power_level": 1, "drops": ["DT_LootDropTable:GiantRat_Common"]},
                     {"min_power_level": 3, "drops": ["DT_LootDropTable:GiantRat_Common", "DT_LootDropTable:GiantRat_Night",
                                                      "DT_LootDropTable:Missing_Row"]}],
        "Ogre": [{"min_power_level": 4, "drops": ["DT_LootDropTable:Ogre_Pack"]}],
        "Unknown": [{"min_power_level": 1, "drops": ["DT_LootDropTable:GiantRat_Common"]}]}}},
    "loot_rows": {
        "DT_LootDropTable:GiantRat_Common": {"drop_chance": 1, "conditions": [], "recipes": [],
                                             "items": [{"item": "ITEM_RawRatMeat", "item_name": "Raw Rat Meat", "min": 1, "max": 1, "chance": 1}]},
        "DT_LootDropTable:GiantRat_Night": {"drop_chance": 0.1, "conditions": ["night"],
                                            "items": [{"item": "ITEM_ShinyTooth", "item_name": "Shiny Tooth", "min": 1, "max": 2, "chance": 0.02}]},
        "DT_LootDropTable:Ogre_Pack": {"drop_chance": 1, "items": [{"item": "ITEM_ZogrePack", "item_name": "Zogre Pack", "min": 1, "max": 1,
                                                                    "chance": 1, "damagers_only": True}]},
        "DT_LootDropTable:Missing_Row": False},
    "chests": {"found": 3, "actors": [
        {"id": "BP_WorldChest_Vault_C_7", "vault": "Test Kara", "profile": {"table": "DT_ChestRespawn", "row": "Vault_A"},
         "respawn": "on_opened", "roll": {"table": "DT_Rolls", "row": "Roll_A"}, "min_extra_rolls": 1, "max_extra_rolls": 2,
         "guaranteed_items": [], "guaranteed_sets": [{"set": "DT_ItemSets:Core", "items": [{"item": "ITEM_VaultCore", "item_name": "Vault Core",
                                                                                             "min": 1, "max": 1, "chance": 1}]}],
         "extra_sets": [{"set": "DT_ItemSets:Tomes", "chance": 0.1, "items": [{"item": "ITEM_SkillTome", "item_name": "Skill Tome",
                                                                               "min": 1, "max": 3, "chance": 0.5}]}]},
        {"id": "BP_WorldChest_Vault_C_9", "profile": {"table": "DT_ChestRespawn", "row": "Chest_TestKara_Small"},
         "roll": {"table": "DT_Rolls", "row": "Roll_B"}, "guaranteed_items": [{"item": "ITEM_VaultShard", "item_name": "Vault Shard",
                                                                               "min": 2, "max": 4, "chance": 1}]},
        {"id": "BP_WorldChest_Vault_C_8", "profile": {"row": "Somewhere_Else", "table_loaded": False},
         "unread": "profile table not loaded on the client"},
        {"id": "BP_WorldChest_C_3", "profile": {"table": "DT_ChestRespawn", "row": "Field_Chest"}, "roll": {"row": "Roll_C"},
         "guaranteed_items": [{"item": "ITEM_Coin", "item_name": "Coins", "min": 5, "max": 5, "chance": 1}]}]},
}}


def write_probe(tmp_path, doc, name="probe.json"):
    p = tmp_path / name
    p.write_text(json.dumps(doc), encoding="utf-8")
    return p


@pytest.fixture(scope="module")
def game_doc(tmp_path_factory):
    tmp = tmp_path_factory.mktemp("probe")
    probe = bb.load_probe([write_probe(tmp, PROBE)])
    mirror = bb.Mirror.from_pages({
        "Giant Rat": page(1, "Giant Rat", RAT), "Zogre": page(2, "Zogre", OGRE), "Test Kara": page(3, "Test Kara", VAULT),
        "Chest (Test Kara)": page(4, "Chest (Test Kara)", CHEST), "Boss": page(5, "Boss", BOSS),
        "Dragonkin Vault": page(6, "Dragonkin Vault", DV), "Vault Shard": page(7, "Vault Shard", "x"),
    }, {"Giant rat": "Giant Rat", "Ogre": "Zogre", "Dungeon": "Dragonkin Vault"})
    ext = tmp / "bestiary_external.json"
    ext.write_text(json.dumps(EXTERNAL), encoding="utf-8")
    orig = bb.class_aliases, bb.observed_attacks, bb.apply_external
    bb.class_aliases = lambda names, dump=None, combat=None: {"Giant Rat": ["GiantRat"]}
    bb.observed_attacks = lambda names, skills=None: {}
    bb.apply_external = lambda creatures, path=None: orig[2](creatures, ext)
    try:
        return bb.build(mirror, probe)
    finally:
        bb.class_aliases, bb.observed_attacks, bb.apply_external = orig


def test_journal_lines_to_affinities():
    got = bb._game_affinities(["Weakness: Stab, Fire", "Resistance: Crush", "Immune: Poison and Bleed", "Slash",
                               "Occasionally lacks confidence", "Weakness: Stab"])
    assert got == {"weak": ["Stab", "Fire", "Slash"], "resist": ["Crush"], "immune": ["Poison", "Bleed"]}
    assert bb._game_affinities(["Lives in the woods."]) == {}


def test_load_probe_takes_the_union_of_runs_and_refuses_a_failed_run(tmp_path):
    other = json.loads(json.dumps(PROBE))
    other["result"]["attacks"]["loaded"] = {"ATK_GiantRat_Lunge": {"path": "/Game/Gameplay/AI/GiantRat/ATK_GiantRat_Lunge.ATK_GiantRat_Lunge_C",
                                                                   "hits": [{"table": "DT_AIAttackDamage_BG", "row": "GiantRat_Lunge"}]}}
    other["result"]["loot_rows"]["DT_LootDropTable:GiantRat_Night"] = False  # a later run that could not read it keeps the read
    bare = write_probe(tmp_path, other["result"], "bare.json")  # the bare result (no runner wrapper) also loads
    u = bb.load_probe([write_probe(tmp_path, PROBE), bare])
    assert set(u["attacks"]) == {"ATK_GiantRat_Bite", "ATK_Mystery_Swing", "ATK_GiantRat_Lunge"}
    assert u["loot_rows"]["DT_LootDropTable:GiantRat_Night"]["drop_chance"] == 0.1
    # both ran every group: the later run's unread lines replace the earlier run's, group by group
    assert len(u["files"]) == 2 and u["unread"] == ["bare.json: DT_AIAttackDamage_DowdunReach: table not loaded (/DowdunReach/...)"]
    bad = write_probe(tmp_path, {"ok": False, "error": "load: syntax"}, "bad.json")
    with pytest.raises(ValueError, match="not a bestiary_tables_probe result"):
        bb.load_probe([bad])


# The first live run (one call, 8 s cap): journal and tables read, the registry walk cut, the rest skipped (version 1,
# no groups key: what ran comes from its sections; its unread lines are filed by their label).
LIVE_V1 = {"ok": True, "result": {
    "probe": "bestiary_tables_probe", "version": 1,
    "sections": {"journal": {"ok": True}, "attack_damage:DT_AIAttackDamage_BG": {"ok": True},
                 "attacks:registry": {"ok": True}, "attacks:find": {"ok": True}, "attacks:read": {"ok": False, "skipped": True},
                 "enemy_loot:DT_EnemyLootDropTable": {"ok": False, "skipped": True}, "chests": {"ok": False, "skipped": True}},
    "unread": ["attacks:find: time cap in the registry walk", "attacks:read: time cap reached before it started",
               "enemy_loot:DT_EnemyLootDropTable: time cap reached before it started", "chests: time cap reached before it started"],
    "journal": {"entries": [{"asset": "JOURNAL_World_Fauna_GiantRat", "name": "Giant Rat", "weaknesses": ["Weakness: Slash"]}]},
    "attack_damage": {"DT_AIAttackDamage_BG": {"rows": {"GiantRat_Bite": 12}}},
    "attacks": {"registry": {"n": 4, "paths": ["/a/ATK_A.ATK_A_C", "/b/ATK_B.ATK_B_C", "/c/ATK_C.ATK_C_C", "/d/ATK_D.ATK_D_C"]},
                "loaded": []},
    "enemy_loot": [], "loot_rows": []}}


def partial(groups, **res):
    """A version-2 result of one `only` call (dkjson writes an empty table as [])."""
    r = {"probe": "bestiary_tables_probe", "version": 2, "groups": groups, "only": groups, "unread": [], "unread_by_group": []}
    r.update(res)
    for g, lines in (res.get("unread_by_group") or {}).items():
        r["unread"] = r["unread"] + lines
    return {"ok": True, "result": r}


def test_load_probe_combines_partial_files_group_by_group(tmp_path):
    loot = partial(["enemy_loot"], unread_by_group={"enemy_loot": ["DT_LootDropTable:Missing_Row: FindRow found nothing"]},
                   enemy_loot={"DT_EnemyLootDropTable": {"rows": {"GiantRat": [{"min_power_level": 1, "drops": ["DT_LootDropTable:Rat"]}]}}},
                   loot_rows={"DT_LootDropTable:Rat": {"drop_chance": 1, "items": []}})
    journal = partial(["journal"], journal={"entries": [{"asset": "JOURNAL_World_Fauna_GiantRat", "name": "Giant Rat",
                                                          "weaknesses": ["Weakness: Stab"]}]})
    u = bb.load_probe([write_probe(tmp_path, LIVE_V1, "live.json"), write_probe(tmp_path, loot, "loot.json"),
                       write_probe(tmp_path, journal, "journal.json")])
    # each group from its own file; a group a later file did not run is left as it was
    assert u["enemy_loot"]["DT_EnemyLootDropTable"]["GiantRat"][0]["drops"] == ["DT_LootDropTable:Rat"]
    assert u["journal"]["JOURNAL_World_Fauna_GiantRat"]["weaknesses"] == ["Weakness: Stab"]  # the later journal replaced it
    assert u["attack_damage"]["DT_AIAttackDamage_BG"] == {"GiantRat_Bite": 12}               # nobody re-read it: kept
    assert u["registry"] == set(LIVE_V1["result"]["attacks"]["registry"]["paths"])
    # the later loot call replaced the live run's 'enemy_loot skipped' line; the groups it did not run keep theirs
    assert "live.json: enemy_loot:DT_EnemyLootDropTable: time cap reached before it started" not in u["unread"]
    assert "loot.json: DT_LootDropTable:Missing_Row: FindRow found nothing" in u["unread"]
    assert "live.json: chests: time cap reached before it started" in u["unread"]
    assert "live.json: attacks:find: time cap in the registry walk" in u["unread"]
    assert u["groups"] == {"journal": "journal.json", "attack_damage": "live.json", "attacks": "live.json", "enemy_loot": "loot.json"}
    # order matters only within a group: a later file that skipped a group does not undo an earlier read of it
    u2 = bb.load_probe([write_probe(tmp_path, loot, "loot.json"), write_probe(tmp_path, LIVE_V1, "live.json")])
    assert u2["enemy_loot"]["DT_EnemyLootDropTable"]["GiantRat"][0]["drops"] == ["DT_LootDropTable:Rat"]
    assert not any("enemy_loot:DT_EnemyLootDropTable: time cap" in x for x in u2["unread"])


def test_load_probe_adds_up_attack_slices_and_names_the_paths_not_walked(tmp_path):
    def sl(start, stop, n, loaded, nxt=None, lines=()):
        walk = {"start": start, "stop": stop, "n": n, "walked": stop - start + 1, **({"next": nxt} if nxt else {})}
        return partial(["attacks"], unread_by_group={"attacks": list(lines)} if lines else [],
                       attacks={"registry": {"n": n, "paths": [f"/p/{i}" for i in range(1, n + 1)]}, "walk": walk,
                                "loaded": loaded, "loaded_n": len(loaded)})
    a = sl(1, 2, 6, {"ATK_A": {"hits": []}}, 3, ["attack ATK_X: read fault"])
    b = sl(3, 4, 6, {"ATK_B": {"hits": []}}, 5)
    u = bb.load_probe([write_probe(tmp_path, LIVE_V1, "live.json"), write_probe(tmp_path, a, "a1.json"),
                       write_probe(tmp_path, b, "a3.json")])
    assert set(u["attacks"]) == {"ATK_A", "ATK_B"}
    assert "a1.json: attack ATK_X: read fault" in u["unread"]                         # slices add up, each keeps its lines
    assert not any(x.startswith("live.json: attacks") for x in u["unread"])           # the new slice 1 replaced the live run's
    assert u["registry_walk"] == {"n": 6, "covered": 4}
    assert "attacks: the registry walk covered 4 of 6 paths; not walked: 5-6" in u["unread"]
    u = bb.load_probe([write_probe(tmp_path, a, "a1.json"), write_probe(tmp_path, b, "a3.json"),
                       write_probe(tmp_path, sl(5, 6, 6, []), "a5.json")])
    assert u["registry_walk"] == {"n": 6, "covered": 6} and not any("registry walk covered" in x for x in u["unread"])


def test_game_journal_outranks_the_wiki_and_keeps_what_it_replaced(game_doc):
    rat = game_doc["creatures"]["Giant Rat"]
    assert rat["weak"] == ["Slash"] and rat["src"]["weak"] == [bb.GAME]
    assert rat["differs"] == {"weak": {"values": ["Stab"], "src": [1]}} and rat["src"]["differs"] == [1]
    assert rat["resist"] == ["Crush"] and rat["src"]["resist"] == [bb.GAME] and "resist" not in rat["differs"]
    assert rat["journal"]["lines"][2] == "Occasionally lacks confidence" and rat["src"]["journal"] == [bb.GAME]
    assert "Weak to Slash." in rat["text"] and "other sources said Stab" in rat["text"]
    assert "the game's own data on his client (" in rat["text"]
    z = game_doc["creatures"]["Zogre"]
    assert z["weak"] == ["Crush"] and z["src"]["weak"] == [bb.GAME] and "differs" not in z  # same value: no conflict
    assert z["immune"] == ["Poison"] and z["src"]["immune"] == [bb.METABOT]  # the journal said nothing: metabot stays


def test_game_attacks_join_damage_types_and_flags(game_doc):
    rat = game_doc["creatures"]["Giant Rat"]
    bite, lunge = rat["game_attacks"]
    assert bite == {"name": "Bite", "asset": "ATK_GiantRat_Bite", "damage": [12], "types": ["stab"], "class": ["melee"],
                    "unblockable": True, "effects": ["GE_Poison"]}
    assert lunge == {"name": "Lunge", "row": "DT_AIAttackDamage_BG:GiantRat_Lunge", "damage": [18]}  # row, no class loaded
    assert rat["src"]["game_attacks"] == [bb.GAME]
    assert "Attacks in the game's data (base damage before armour): Bite (12 damage, stab, melee, unblockable, effect GE_Poison)" in rat["text"]
    assert "Attacks: Bite" in rat["text"]  # the wiki's list stays beside it


def test_game_drops_per_power_level(game_doc):
    rat = game_doc["creatures"]["Giant Rat"]
    assert [lv["min_power_level"] for lv in rat["game_drops"]] == [1, 3]
    assert len(rat["game_drops"][1]["drops"]) == 2  # the unreadable row is left out, not invented
    assert "Drops in the game's tables: from power level 1: Raw Rat Meat 1 (always); from power level 3:" in rat["text"]
    assert "Shiny Tooth 1-2 (2 % of a 10 % roll at night)" in rat["text"]
    z = game_doc["creatures"]["Zogre"]  # the loot row "Ogre" matched through the wiki redirect alias
    assert z["game_drops"][0]["drops"][0]["items"][0] == {"item": "Zogre Pack", "id": "ITEM_ZogrePack", "min": 1, "max": 1,
                                                         "chance": 1, "damagers_only": True}


def test_chest_items_placed_by_label_or_row_name(game_doc):
    v = game_doc["vaults"]["Test Kara"]
    rolls = sorted(v["chest_items"]["rolls"], key=lambda r: r["roll"])
    assert [r["roll"] for r in rolls] == ["Roll_A", "Roll_B"] and v["src"]["chest_items"] == [bb.GAME]
    assert rolls[0]["extra_rolls"] == [1, 2] and rolls[0]["guaranteed"][0]["item"] == "Vault Core"
    assert "Chest loot in the game's tables: always Vault Core 1; plus 1-2 rolls among: Skill Tome 1-3 (50 %) [set 10 %]" in v["text"]
    assert "Vault Shard 2-4" in v["text"]
    assert "Chests [wiki]: " in v["text"]  # the wiki's chest page stays too
    assert game_doc["counts"]["vaults_missing"]["chest_items"] == 0


def test_probe_report_names_what_did_not_match(game_doc):
    pr = game_doc["probe"]
    assert pr["unmatched"]["journal"] == ["Plague Wisp"]
    assert pr["unmatched"]["attacks"] == ["ATK_Mystery_Swing"]
    assert pr["unmatched"]["enemy_loot"] == ["Unknown"]
    assert pr["unmatched"]["chests"] == ["BP_WorldChest_C_3 (Field_Chest)"]  # the unread chest has no loot: not listed
    assert pr["journal_matched"] == 2 and pr["replaced"] == 1 and pr["chests_placed"] == 2
    assert pr["unread"] == ["probe.json: DT_AIAttackDamage_DowdunReach: table not loaded (/DowdunReach/...)"]
    for sec in ("creatures", "vaults"):
        for k, e in game_doc[sec].items():
            assert len(e["text"]) <= bb.ENTRY_CHARS, k
            for f in e:
                if f not in ("kind", "name", "title", "page", "aliases", "text", "src", "class_names", "role", "vaults"):
                    assert e["src"].get(f), (k, f)


def test_build_cli_takes_from_probe(tmp_path, monkeypatch):
    seen = {}

    def fake_build(mirror=None, probe=None):
        seen["probe"] = probe
        return {"counts": {}, "probe": {"files": [], "unmatched": {"journal": []}, "unread": []}}
    monkeypatch.setattr(bb, "build", fake_build)
    monkeypatch.setattr(bb, "OUT", tmp_path / "bestiary.json")
    f = write_probe(tmp_path, PROBE)
    assert bb.main(["build", "--from-probe", str(f)]) == 0
    assert set(seen["probe"]["attacks"]) == {"ATK_GiantRat_Bite", "ATK_Mystery_Swing"}
    assert json.loads((tmp_path / "bestiary.json").read_text(encoding="utf-8"))["probe"]["files"] == []


# ---------------------------------------------------------------- matching and the lookup merge


def test_match_longest_name_first_with_plurals_and_aliases(doc):
    b = bb.Bestiary(doc)
    assert b.match("giant rats drops") == [("creatures", "Giant Rat")]
    assert b.match("what drops hard leather") == [("dropped_by", "Hard Leather")]
    assert b.match("Test Kara boss") == [("vaults", "Test Kara")]
    assert b.match("ogre attacks") == [("creatures", "Zogre")]
    assert b.match("iron ore") == []


class FakeKnowledge:
    build = "t"

    def __init__(self, n=3, size=900):
        self.n, self.size = n, size

    def stats(self):
        return {}

    def lookup(self, query, kind=None):
        return {"ok": True, "reason": None, "data": {"query": query, "note": "n",
                "results": [{"title": f"old{i}", "text": "x" * self.size} for i in range(self.n)]}}


def test_lookup_puts_the_entry_first_then_old_results_within_budget(doc):
    look = bb.BestiaryLookup(FakeKnowledge(), bb.Bestiary(doc))
    res = look.lookup("giant rat")
    titles = [r["title"] for r in res["data"]["results"]]
    assert titles[0] == "Giant Rat" and res["data"]["bestiary"] == ["Giant Rat"]
    assert sum(len(r["text"]) for r in res["data"]["results"]) <= bb.TEXT_BUDGET
    assert look.lookup("iron ore")["data"]["results"][0]["title"] == "old0"  # no entry: the old lookup unchanged
    only = bb.BestiaryLookup(FakeKnowledge(), bb.Bestiary(doc), budget=0).lookup("giant rat")
    assert [r["title"] for r in only["data"]["results"]] == ["Giant Rat"]


# ---------------------------------------------------------------- the built file (read only)

BUILT = ROOT / "data" / "bestiary.json"


@pytest.mark.skipif(not BUILT.exists(), reason="data/bestiary.json not built")
def test_built_file_counts_and_contract():
    d = json.loads(BUILT.read_text(encoding="utf-8"))
    assert d["schema"] == bb.SCHEMA
    assert d["counts"]["creatures"] >= 120 and d["counts"]["vaults"] >= 10 and d["counts"]["reverse_rows"] >= 300
    for sec in ("creatures", "vaults"):
        for k, e in d[sec].items():
            assert len(e["text"]) <= bb.ENTRY_CHARS, k
            assert not bb.ADVICE.search(e["text"]), k
            for f in e:
                if f not in ("kind", "name", "title", "page", "aliases", "text", "src", "class_names", "role", "vaults"):
                    assert e["src"].get(f), (k, f)
            for f, ids in e["src"].items():
                assert all(isinstance(i, int) or i in (bb.METABOT, bb.OWN, bb.GAME) for i in ids), (k, f, ids)
                if f == "observed_attacks":
                    assert ids == [bb.OWN], k
    assert d["vaults"]["Crasorak Kara"]["boss"][0]["creature"] == "Vault Overlord"
    assert "fly away when somebody gets near" in d["creatures"]["Magpie"]["text"]  # the wiki's flee sentence
    assert "Zogre" in {r["from"] for r in d["dropped_by"]["Hard Leather"]["rows"]}


def test_this_test_file_never_reads_the_heldout_half():
    src = Path(__file__).read_text(encoding="utf-8")
    assert src.count("heldout" + ".jsonl") == 0
    assert not re.search(r"HELD" + r"OUT\b", src)

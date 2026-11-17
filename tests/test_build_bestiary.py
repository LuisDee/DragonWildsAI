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


@pytest.fixture(scope="module")
def doc():
    mirror = bb.Mirror.from_pages({
        "Giant Rat": page(1, "Giant Rat", RAT), "Zogre": page(2, "Zogre", OGRE), "Test Kara": page(3, "Test Kara", VAULT),
        "Chest (Test Kara)": page(4, "Chest (Test Kara)", CHEST), "Boss": page(5, "Boss", BOSS),
        "Dragonkin Vault": page(6, "Dragonkin Vault", DV), "Vault Shard": page(7, "Vault Shard", "x"),
    }, {"Giant rat": "Giant Rat", "Ogre": "Zogre", "Dungeon": "Dragonkin Vault"})
    orig = bb.class_aliases
    bb.class_aliases = lambda names, dump=None, combat=None: {"Giant Rat": ["GiantRat"]}
    try:
        return bb.build(mirror)
    finally:
        bb.class_aliases = orig


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
    assert "Hazards: Exploding plant traps" in v["text"]
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
    assert d["vaults"]["Crasorak Kara"]["boss"][0]["creature"] == "Vault Overlord"
    assert "Zogre" in {r["from"] for r in d["dropped_by"]["Hard Leather"]["rows"]}


def test_this_test_file_never_reads_the_heldout_half():
    src = Path(__file__).read_text(encoding="utf-8")
    assert src.count("heldout" + ".jsonl") == 0
    assert not re.search(r"HELD" + r"OUT\b", src)

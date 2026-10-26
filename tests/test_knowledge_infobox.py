"""BUGS A4: when the query names a page, ``lookup`` returns the page's lead AND its infobox / structured-facts section
(a quest's requirements and start, an item's recipe, a creature's drops), by ranking (fact density, a heading the
query names), never by a per-kind rule. Fixture wikitext is made up in the wiki's shape (no mirrored text)."""
import json

import pytest

from brain.knowledge import Knowledge, fact_count, wiki_dir
from tools import wiki_mirror as wm

QUEST = """{{Infobox Quest
|name = Goblin Diplomacy
|release = 1 May 2025
}}
'''Goblin Diplomacy''' is a side [[quest]] started by talking to [[Zanik]] on a hill in [[Bramblemead Valley]].

==Overview==
{{Map|Goblin Diplomacy|height=350px|width=350px|center=160000,80000|zoom=3}}
{{Quest details
|desc = Stop the goblin prophecy.
|start = Speak to [[Zanik]] on the hill in [[Bramblemead Valley]].
|req = [[Rune Mysteries]]
|item_req =
* A [[logging axe]]
|enemies =
* [[Goblin]]s
|qtype = secondary
}}

==Starting off==
Zanik tells you the goblins are up to something in the ruins and at the guild. Goblin Diplomacy is a long quest
with lots of walking, so bring food, water and potions, and plan for a long trip across the valley to the ruins.

==The ruins==
Search the ruins for the first amulet. The goblins guard it. Fight them one at a time and loot the reliquary.

==Rewards==
* Goblin war banner
"""

ITEM = """{{Infobox Item
|name = Bronze Pickaxe
|item_type = Tool
|weight = 5.0
|description = A trusty mining tool.
}}
The '''bronze pickaxe''' is a pickaxe made at a [[blacksmith's bench]].

==Recipe==
{{Recipe
|facility = Blacksmith's Bench
|skill = Artisan
|mat1 = Bronze Bar
|mat1qty = 5
|output1 = Bronze Pickaxe
}}

==Trivia==
* The bronze pickaxe was the first pickaxe tier players saw.{{CiteDiscord|author=Mod X|date=1 May|quote=It is.}}
"""

CREATURE = """{{Infobox Monster
|name = Giant Rat
|health1 = 50
|race = Rat
|location1 = Temple Woods
|aggressive = yes
}}
'''Giant rats''' are aggressive [[monster]]s.

==Drops==
{{DropsTableHead}}
{{DropsLine|name=Raw Rat Meat|quantity=1|rarity=Always}}
{{DropsLine|name=Coarse Animal Fur|quantity=1|rarity=Always}}
{{DropsTableBottom}}

==Trivia==
* Rats were in the first trailer.{{CiteDiscord|author=Mod Y|date=2 May|quote=Rats! Many rats.}}
"""


def _wiki(d):
    (d / "pages").mkdir(parents=True, exist_ok=True)
    pages = {}
    for pid, title, text in ((1, "Goblin Diplomacy", QUEST), (2, "Bronze Pickaxe", ITEM), (3, "Giant Rat", CREATURE),
                             (4, "Rune Mysteries", "'''Rune Mysteries''' is a quest about runes.")):
        rec = {"title": title, "pageid": pid, "revid": pid, "url": wm.page_url(title), **wm.convert(title, text),
               "wikitext": text}
        (d / "pages" / f"{pid}.json").write_text(json.dumps(rec), encoding="utf-8")
        pages[title] = {"pageid": pid, "revid": pid, "fetched_at": "x", "file": f"pages/{pid}.json"}
    (d / "manifest.json").write_text(json.dumps({"pages": pages, "redirects": {}}), encoding="utf-8")
    return d


@pytest.fixture
def know(tmp_path):
    (tmp_path / "data").mkdir()
    return Knowledge(data=tmp_path / "data", wiki=_wiki(tmp_path / "wiki"))


def _wiki_hits(res, title):
    return [r for r in res["data"]["results"] if r["source"] == "wiki" and r["title"] == title]


def test_quest_lookup_returns_the_requirements(know):
    hits = _wiki_hits(know.lookup("Goblin Diplomacy", kind="quest"), "Goblin Diplomacy")
    assert [h.get("section") for h in hits] == [None, "Overview"]  # the lead, then the infobox (not "Rewards")
    assert "req=Rune Mysteries" in hits[1]["text"] and "start=Speak to Zanik" in hits[1]["text"]


def test_a_heading_the_query_names_still_wins(know):
    hits = _wiki_hits(know.lookup("Goblin Diplomacy rewards", kind="quest"), "Goblin Diplomacy")
    assert [h.get("section") for h in hits] == [None, "Rewards"]


def test_item_and_creature_pages_keep_their_key_facts(know):
    item = _wiki_hits(know.lookup("Bronze Pickaxe"), "Bronze Pickaxe")
    assert "weight: 5.0" in item[0]["text"]  # the infobox lead
    assert item[1]["section"] == "Recipe" and "mat1=Bronze Bar" in item[1]["text"]  # not the cited trivia
    rat = _wiki_hits(know.lookup("Giant Rat", kind="monster"), "Giant Rat")
    assert "health1: 50" in rat[0]["text"] and "location1: Temple Woods" in rat[0]["text"]
    assert rat[1]["section"] == "Drops" and "name=Raw Rat Meat" in rat[1]["text"]


def test_fact_count_is_generic_and_ignores_citations():
    assert fact_count("Quest details: desc=x; start=y; req=z") == 3
    assert fact_count("name: X\nweight: 5") == 2
    assert fact_count("A sentence with no facts. CiteDiscord: author=a; date=b; quote=c") == 0


@pytest.mark.skipif(not (wiki_dir() / "manifest.json").exists(), reason="no local wiki mirror")
def test_real_mirror_goblin_diplomacy_requires_rune_mysteries():
    res = Knowledge().lookup("Goblin Diplomacy", kind="quest")
    assert any("req=Rune Mysteries" in h["text"] for h in _wiki_hits(res, "Goblin Diplomacy"))

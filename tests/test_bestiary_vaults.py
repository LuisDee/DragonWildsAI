"""tools/build_vaults.py: per dragonkin vault its region and province, door (game read or wiki map centre), what opens
it, who lives inside and the boss with its level, weakness, attacks and drops; served through the bestiary's name
matching and lookup merge (tools/build_bestiary.py). Goal item 3, docs/GOAL-2026-11-17-long-jobs.md."""
import copy
import json
from pathlib import Path

import pytest

from tools import build_vaults as V
from tools.build_bestiary import Bestiary, merge

ROOT = Path(__file__).resolve().parents[1]
BESTIARY = ROOT / "data" / "bestiary.json"

PLACES = {
    "build": "123",
    "provinces": [{"name": "Brynmoor", "regions": ["Temple Woods"]}, {"name": "Ghornfell", "regions": ["Fractured Plains"]},
                  {"name": "Umbral Sands", "regions": ["Dunes of Uzzer"]}],
    "regions": [{"name": "Temple Woods", "power": 1, "province": "Brynmoor", "bbox": [0, 1800, 500, 2100]},
                {"name": "Fractured Plains", "power": 3, "province": "Ghornfell", "bbox": [600, 1100, 900, 1300]},
                {"name": "Dunes of Uzzer", "power": 7, "province": "Umbral Sands", "bbox": [3000, 200, 3500, 500]}],
    "landmarks": [{"name": "Vault Guardian Prime", "position": [3342.68, 408.59, 11.34], "region": "Dunes of Uzzer"}],
}

TAKLA_WIKI = """{{Infobox Scenery
|name = Takla Kara
|location = [[Fractured Plains]]
}}
'''Takla Kara''' is the [[dragonkin vault]] found in the western part of the [[Fractured Plains]] on a mesa. It is located behind rocks that must be mined to access the entrance. It is recommended to bring a pickaxe. The vault contains the recipes for the [[Paladin]] armour set.
==Location==
{{Map|Takla Kara|width=250px|height=250px|center=120000,71500|zoom=3}}
==Update history==
{{UH|
{{UL
|type = hotfix
|update =
* Boss areas inside Takla Kara can now be opened again with the nearby lever.
}}
}}
"""


class FakeMirror:
    def __init__(self, pages):
        self.pages = {t: {"wikitext": w, "pageid": i} for i, (t, w) in enumerate(pages.items(), 100)}

    def resolve(self, name):
        return name if name in self.pages else None

    def wikitext(self, t):
        return self.pages[t]["wikitext"]

    def pid(self, t):
        return self.pages[t]["pageid"]


def _doc():
    return {
        "creatures": {
            "Vault Overlord": {"name": "Vault Overlord", "variants": [
                {"label": "Crasorak Kara", "power_level": "2", "health": "1300"},
                {"label": "Skekven Kara", "power_level": "5", "health": "2875"}],
                "weak": ["Crush"], "immune": ["Poison"], "resist": ["None"],
                "attacks": [{"name": "Rapid spin attack", "does": "spins"}],
                "game_attacks": [{"name": "VaultOverlordSlam", "damage": [43.0]}],
                "drops": [{"item": "Stone", "amount": "15", "rate": "always"}, {"item": "Vault Shard", "amount": "6", "rate": "25/100"}],
                "text": "Vault Overlord: creature.\nSources: wiki pages 1331."},
            "Vault Incinerator": {"name": "Vault Incinerator", "variants": [{"label": "", "power_level": "3", "health": "2112"}],
                                  "weak": ["Water"], "text": "Vault Incinerator: creature.\nSources: x."},
        },
        "regions": {"Temple Woods": {"kind": "region", "province": "Brynmoor", "power_level": {"game": 1}},
                    "Fractured Plains": {"kind": "region", "province": "Ghornfell", "power_level": {"game": 3}},
                    "Umbral Sands": {"kind": "province", "province": "Umbral Sands", "power_level": {"game": [7, 7]}}},
        "vaults": {
            "Crasorak Kara": {"kind": "vault", "name": "Crasorak Kara", "page": 3515, "area": "Temple Woods",
                              "power_level": "2", "order": "1", "aliases": ["Temple Woods vault"],
                              "enemies": [{"name": "Vault Overlord", "amount": "1", "power_level": "2"}],
                              "boss": [{"creature": "Vault Overlord", "power_level": "2, 5", "health": "1300, 2875"}],
                              "src": {"area": [3515]}, "text": "old"},
            "Takla Kara": {"kind": "vault", "name": "Takla Kara", "page": 3518, "area": "Fractured Plains",
                           "power_level": "3", "boss": [{"creature": "Vault Incinerator"}], "src": {}, "text": "old"},
            "Fight Cave": {"kind": "dungeon", "name": "Fight Cave", "text": "a dungeon"},
        },
    }


@pytest.fixture()
def places(tmp_path):
    p = tmp_path / "places_123.json"
    p.write_text(json.dumps(PLACES), encoding="utf-8")
    return p


def test_map_centre_converts_wiki_map_to_game_metres():
    # Crasorak Kara: center=193500,38000 -> (380, 1935), 17 m from the door his client read at (374.58, 1918.74)
    assert V.map_centre("{{Map|Crasorak Kara|center=193500,38000|zoom=3}}") == [380.0, 1935.0]
    assert V.map_centre("{{Map|Kalistrakthen Kara|width=250px|center=-51578.39,34382.146|zoom=2}}") == [343.8, -515.8]
    assert V.map_centre("no map here") is None


def test_entry_facts_keep_the_lock_and_drop_advice():
    facts = V.entry_facts(TAKLA_WIKI)
    assert any("must be mined" in f for f in facts)
    assert not any("recommended" in f.lower() for f in facts)
    assert not any("recipes" in f for f in facts)  # what it gives is not how to get in


def test_lever_notes_from_update_history_and_walkthrough():
    assert V.lever_notes(TAKLA_WIKI) == ["Boss areas inside Takla Kara can now be opened again with the nearby lever."]
    walk = "* the stairs with the bars at the top are where the [[lever]] is to open the final door, the hallway"
    assert V.lever_notes(walk) == ["A lever opens the final door (walkthrough)."]


def test_add_vaults_door_province_boss_and_umbral(places):
    doc = _doc()
    V.add_vaults(doc, FakeMirror({"Takla Kara": TAKLA_WIKI}), places)
    cr, tk = doc["vaults"]["Crasorak Kara"], doc["vaults"]["Takla Kara"]
    assert cr["door"]["position"] == [374.58, 1918.74, -2.76] and cr["door"]["src"] == "game"
    assert cr["province"] == "Brynmoor" and cr["game_region"]["name"] == "Temple Woods"
    assert "(374.6, 1918.7, -2.8) m" in cr["text"] and "[game" in cr["text"]
    assert "Vault Overlord (power level 2, health 1300 here; weak to Crush" in cr["text"]
    assert "Slam 43" in cr["text"]  # the game's attack damage, the creature prefix cut
    assert tk["map_centre"]["position"] == [715.0, 1200.0]
    assert "not read by the game yet" in tk["text"] and "must be mined" in tk["text"]
    assert tk["province"] == "Ghornfell" and "Levers [wiki]" in tk["text"]
    # the two Umbral Sands vaults the mirror lists as TBA
    assert {"Uzzer Kara", "Manafem Kara"} <= set(doc["vaults"])
    assert "Kalphite Queen" in doc["vaults"]["Manafem Kara"]["text"]
    assert "Vault Guardian Prime" in doc["vaults"]["Uzzer Kara"]["text"]
    assert doc["vaults"]["Fight Cave"]["text"] == "a dungeon"  # not a vault: untouched
    # a boss's creature entry says where its vault is
    assert "Crasorak Kara is in Temple Woods (Brynmoor), door at (374.6, 1918.7, -2.8) m [game]." in \
        doc["creatures"]["Vault Overlord"]["text"]
    assert doc["counts"]["vault_doors_game"] == 1 and doc["vault_registry"]["dungeons_client"] == 32


def test_add_vaults_is_idempotent(places):
    doc = _doc()
    V.add_vaults(doc, FakeMirror({"Takla Kara": TAKLA_WIKI}), places)
    once = copy.deepcopy(doc)
    V.add_vaults(doc, FakeMirror({"Takla Kara": TAKLA_WIKI}), places)
    assert doc == once


def test_text_fits_the_cap_and_sources_disagreeing_are_both_kept(places):
    doc = _doc()
    tk = doc["vaults"]["Takla Kara"]
    tk["area"] = "Temple Woods"  # the wiki says one region, the game's polygon at the map centre another
    tk["enemies"] = [{"name": f"Creature {i}", "amount": str(i), "power_level": "3"} for i in range(60)]
    V.add_vaults(doc, FakeMirror({"Takla Kara": TAKLA_WIKI}), places)
    assert len(tk["text"]) <= V.ENTRY_CHARS
    assert "Fractured Plains" in tk["text"] and "the wiki says Temple Woods" in tk["text"]


def test_no_mirror_still_gives_the_game_door(places):
    doc = _doc()
    V.add_vaults(doc, None, places)
    assert "374.6" in doc["vaults"]["Crasorak Kara"]["text"]
    assert "To get in: the wiki names no key" in doc["vaults"]["Takla Kara"]["text"]


# ------------------------------------------------------------------ the committed data file, through lookup's merge

@pytest.fixture(scope="module")
def real():
    return json.loads(BESTIARY.read_text(encoding="utf-8"))


def test_every_vault_entry_in_the_data_file(real):
    va = {k: v for k, v in real["vaults"].items() if v.get("kind") == "vault"}
    assert len(va) == 12
    for k, v in va.items():
        assert len(v["text"]) <= V.ENTRY_CHARS, k
        assert v.get("province") and v.get("power_level"), k
        assert "Door:" in v["text"] and "Sources:" in v["text"], k
    assert va["Crasorak Kara"]["door"]["position"][:2] == [374.58, 1918.74]


@pytest.mark.parametrize("query,first,needles", [
    ("Crasorak Kara", "Crasorak Kara", ["374.6", "Vault Overlord", "Brynmoor"]),
    ("the temple woods vault", "Crasorak Kara", ["Vault Overlord"]),
    ("what vault drops granite maul", None, ["Skeklac Kara"]),
    ("Kalphite vault", "Manafem Kara", ["Kalphite Queen", "power level 7"]),
])
def test_lookup_merge_serves_vaults(real, query, first, needles):
    out, info = merge(Bestiary(real), query, [])
    assert info is not None
    text = "\n".join(r["text"] for r in out)
    if first:
        assert out[0]["title"] == first and out[0]["kind"] == "vault"
    for n in needles:
        assert n in text

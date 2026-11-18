"""tools/build_regions.py: per region its power level, residents with their level and resource nodes; per resource node
its regions; served through the bestiary's name matching and lookup merge (tools/build_bestiary.py)."""
import importlib.util
import json
from pathlib import Path

import pytest

from tools import build_regions as R
from tools.build_bestiary import Bestiary, merge

ROOT = Path(__file__).resolve().parents[1]

PLACES = {
    "build": "123",
    "provinces": [{"name": "Ghornfell", "quest_region_id": 2, "regions": ["Fractured Plains", "Stormtouched Highlands"]},
                  {"name": "Fellhollow", "quest_region_id": 3, "regions": ["Coalridge Pass", "Dragons' Run"]}],
    "regions": [{"name": "Fractured Plains", "power": 3, "province": "Ghornfell"},
                {"name": "Stormtouched Highlands", "power": 4, "province": "Ghornfell"},
                {"name": "Coalridge Pass", "power": 5, "province": "Fellhollow"},
                {"name": "Dragons' Run", "power": 5, "province": "Fellhollow"}],
}


def _page(title, lead, sections, infobox="Scenery"):
    return {"title": title, "pageid": 1, "infobox": infobox,
            "sections": [{"heading": None, "text": lead}] + [{"heading": h, "text": t} for h, t in sections]}


PAGES = {
    "Fractured Plains": _page("Fractured Plains", "name: Fractured Plains\nlocation: Ghornfell\nThe Fractured Plains is a "
                              "power level 2 area in Ashenfall.", [
                                  ("Nodes", "- Copper ore node\n- Blurite ore node - only inside of Takla Kara\n- Stone boulders"),
                                  ("Trees", "- Ash tree"),
                                  ("Monsters", "- Garou berserker - Ferocious warriors of the garou pack with weakness to magic, fire, and more\n- Sheep"),
                                  ("Mini-boss", "- Abyssal demon")]),
    "Coalridge Pass": _page("Coalridge Pass", "name: Coalridge Pass\nlocation: Fellhollow\nCoalridge Pass is an area.", [
        ("Nodes", "- Coal deposit"),
        ("Monsters", "- Skeletons\n- - Skeletal warrior\n- Zombies")]),
    "Fellhollow": _page("Fellhollow", "Fellhollow is a power level 5 region in Ashenfall.", [
        ("Dragon's Run", "Green dragons nest in Dragon's Run."), ("Nodes", "- Coal deposit")]),
    "Copper Ore Node": _page("Copper Ore Node", "location: * Fractured Plains - Stormtouched Highlands", [], "Resource node"),
    "Coal Node": _page("Coal Node", "location: Fellhollow", [], "Resource node"),
    "Stone Boulder": _page("Stone Boulder", "location: Ashenfall", [], "Resource node"),
    "Ash Tree": _page("Ash Tree", "location: Ashenfall", [], "Resource node"),
}

CREATURES = {
    "Garou Berserker": {"name": "Garou Berserker", "aliases": ["Garou berserker"], "aggressive": "Yes",
                        "variants": [{"power_level": "3", "health": "292"}, {"power_level": "4", "health": "405"}],
                        "locations": ["Fractured Plains", "Stormtouched Highlands"]},
    "Sheep": {"name": "Sheep", "aggressive": "No", "variants": [{"power_level": "1", "health": "50"}], "locations": []},
    "Abyssal Demon": {"name": "Abyssal Demon", "aggressive": "Yes", "role": ["mini boss"],
                      "variants": [{"power_level": "4", "health": "1,500"}, {"power_level": "7", "health": "9"}],
                      "locations": ["Fractured Plains"]},
    "Skeletal Warrior": {"name": "Skeletal Warrior", "aggressive": "Yes",
                         "variants": [{"power_level": "5", "health": "150"}], "locations": ["Fellhollow"]},
    "Zombie": {"name": "Zombie", "aggressive": "yes", "variants": [{"power_level": "5", "health": "345"}], "locations": []},
    "Green Dragon": {"name": "Green Dragon", "aggressive": "yes", "variants": [{"power_level": "5", "health": "2,800"}],
                     "locations": ["Fellhollow"]},
}

JOURNAL = [{"name": "Coal Deposit", "asset": "JOURNAL_World_Materials_Deposit_Coal", "locations": ["Ghornfell"],
            "materials": ["Coal"]},
           {"name": "Green Dragon", "asset": "JOURNAL_World_Fauna_Fellhollow_Dragon_Lesser_Green",
            "locations": ["Brynmoor"], "materials": []},
           {"name": "Skeletal Warrior", "asset": "JOURNAL_World_Factions_Fellhollow_Skeleton_Warrior",
            "locations": ["Fellhollow"], "materials": []}]


@pytest.fixture(scope="module")
def secs():
    return R.build_sections(PLACES, PAGES, CREATURES, {"Takla Kara": {"name": "Takla Kara", "area": "Fractured Plains",
                                                                      "power_level": "3"}}, JOURNAL, "places.json")


# ---------------------------------------------------------------- parsing


def test_bullet_tree_and_items():
    assert R.bullet_tree("- A\n- - a1\n- - a2\n- B") == [("A", ["a1", "a2"]), ("B", [])]
    assert R.split_item("Blurite ore node - only inside of Takla Kara") == ("Blurite ore node", "only inside of Takla Kara")
    assert R.split_item("Rune essence geyser (Rune Essence Rock) (Rune essence)") == ("Rune essence geyser", "")
    assert R.split_item("Coal nodes: Two inside the cave.") == ("Coal nodes", "Two inside the cave")
    assert R.split_item("Garou berserker - " + "x" * 70) == ("Garou berserker", "")  # a long description is no fact here


def test_names_fold_plurals_and_apostrophes():
    assert R.key("Dragons' Run") == R.key("Dragon's Run")
    assert R.key("Stone boulders") == R.key("Stone Boulder")
    assert R.own("Rune Essence (Rock)") == frozenset({"rune", "essence"})
    assert R.own("Copper Ore Node") == frozenset({"copper"})
    assert R.Creatures(CREATURES).find("Zombies") == "Zombie"  # _stem alone makes it 'zomby'


# ---------------------------------------------------------------- regions


def test_region_power_residents_levels_and_nodes(secs):
    fp = secs["regions"]["Fractured Plains"]
    assert fp["power_level"] == {"game": 3, "game_build": "123", "wiki": [2, 2]}
    assert "power level: game 3, wiki 2" in fp["differs"]  # both kept, the disagreement said
    t = fp["text"]
    assert "Power level 3 (game map, build 123; wiki: power level 2)" in t
    assert "Garou Berserker (292 HP)" in t and "power level 3 unless noted" in t  # the region's level, HP at it
    assert "Abyssal Demon (power level 4, 1,500 HP) [mini boss]" in t  # a boss keeps its own level
    assert "Passive (wiki): Sheep" in t
    assert "Copper Ore Node" in t and "Blurite ore node (only inside of Takla Kara)" in t and "Stone Boulder" in t
    assert "Trees (wiki): Ash Tree" in t
    assert len(t) <= R.ENTRY_CHARS


def test_group_labels_give_their_members(secs):
    cp = secs["regions"]["Coalridge Pass"]
    names = [r["name"] for r in cp["residents"]]
    assert "Skeletal Warrior" in names and "Zombie" in names and "Skeletons" not in names


def test_a_region_without_a_page_reads_its_province_section(secs):
    dr = secs["regions"]["Dragons' Run"]
    assert [r["name"] for r in dr["residents"]] == ["Green Dragon"]
    assert "Dragon's Run" in dr["aliases"]


def test_province_takes_its_regions_and_the_power_range(secs):
    g = secs["regions"]["Ghornfell"]
    assert g["kind"] == "province" and g["power_level"]["game"] == [3, 4]
    assert "Power level 3 to 4" in g["text"] and "Fractured Plains 3, Stormtouched Highlands 4" in g["text"]
    assert any(r["name"] == "Garou Berserker" for r in g["residents"])
    f = secs["regions"]["Fellhollow"]
    assert "Green Dragon (wiki places it in Fellhollow)" not in f["text"]  # the journal said Brynmoor, not Fellhollow
    assert "Skeletal Warrior" in f["text"]


def test_region_entry_for_a_bare_area_says_nothing_is_listed():
    secs = R.build_sections({"build": "1", "regions": [{"name": "Nowhere", "power": -1, "province": None}],
                             "provinces": []}, {}, {}, {}, [], "p.json")
    t = secs["regions"]["Nowhere"]["text"]
    assert "No power level (the map says -1)" in t
    assert "Creatures: none listed" in t and "Resources: none listed" in t


# ---------------------------------------------------------------- resources


def test_resource_lists_each_place_with_power_and_hostiles(secs):
    cu = secs["resources"]["Copper Ore Node"]
    t = cu["text"]
    assert "Fractured Plains (Ghornfell, power level 3; hostile: Garou Berserker)" in t
    assert "Stormtouched Highlands (Ghornfell, power level 4" in t
    assert "copper" in cu["loose_aliases"] and "copper ore" in cu["aliases"]


def test_resource_keeps_the_journal_and_says_where_it_differs(secs):
    coal = secs["resources"]["Coal Node"]
    assert "Coalridge Pass (Fellhollow, power level 5; hostile: Skeletal Warrior, Zombie)" in coal["text"]
    assert any("the game journal says Ghornfell; the wiki says Fellhollow" in d for d in coal["differs"])
    assert "Gives (game journal): Coal." in coal["text"]


# ---------------------------------------------------------------- the lookup path (Bestiary + merge)


@pytest.fixture(scope="module")
def bestiary(secs):
    doc = {"creatures": {k: {**v, "text": f"{k}: creature."} for k, v in CREATURES.items()},
           "vaults": {}, "dropped_by": {"Stone": {"item": "Stone", "text": "Stone: dropped by golems."},
                                        "Copper Ore": {"item": "Copper Ore", "text": "Copper Ore: dropped by none."}},
           **secs}
    return Bestiary(doc)


def test_bestiary_lookup_matches_regions_and_bare_resource_names(bestiary):
    assert bestiary.match("Fractured Plains") == [("regions", "Fractured Plains")]
    assert bestiary.match("where is copper") == [("resources", "Copper Ore Node")]
    assert bestiary.match("where can I mine coal") == [("resources", "Coal Node")]
    assert bestiary.match("Dragon's Run") == [("regions", "Dragons' Run")]


def test_bestiary_lookup_bare_names_never_start_a_longer_name(bestiary):
    assert bestiary.match("stone pickaxe") == [("dropped_by", "Stone")]  # not the Stone Boulder
    assert ("resources", "Ash Tree") not in bestiary.match("ash logs")


def test_bestiary_lookup_node_and_item_of_one_name_both_come(bestiary):
    assert bestiary.match("copper ore") == [("resources", "Copper Ore Node"), ("dropped_by", "Copper Ore")]


def test_bestiary_lookup_merge_shows_kind_and_source(bestiary):
    res, info = merge(bestiary, "Fractured Plains", [{"title": "old", "text": "x"}])
    assert res[0]["kind"] == "region" and res[0]["source"].startswith("regions (game map build 123")
    assert info["entries"] == ["Fractured Plains"] and res[-1]["title"] == "old"
    res, _ = merge(bestiary, "where is copper", [])
    assert res[0]["kind"] == "resource"


# ---------------------------------------------------------------- the committed data and the eval files


def test_committed_bestiary_has_the_regions_luis_named():
    doc = json.loads((ROOT / "data" / "bestiary.json").read_text(encoding="utf-8"))
    reg, res = doc["regions"], doc["resources"]
    assert reg["Fractured Plains"]["power_level"]["game"] == 3
    assert reg["Fellhollow"]["power_level"]["game"] == [5, 5] and reg["Dowdun Reach"]["power_level"]["game"] == [6, 6]
    assert any(r["name"].startswith("Garou") for r in reg["Fractured Plains"]["residents"])
    assert any(r["name"].startswith("Skeletal") for r in reg["Coalridge Pass"]["residents"])
    assert "Fractured Plains" in res["Tin Ore Node"]["places"] and "Fellhollow" in res["Coal Node"]["places"]
    assert all(len(e["text"]) <= R.ENTRY_CHARS for sec in (reg, res) for e in sec.values())


def _lookup_regions_eval():
    spec = importlib.util.spec_from_file_location("lookup_regions_eval", ROOT / "evals" / "lookup_regions_eval.py")
    ev = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ev)
    return ev


def test_lookup_regions_eval_cases_load_and_heldout_is_separate():
    ev = _lookup_regions_eval()
    tuned, held = ev.load_cases(ev.TUNED), ev.load_cases(ev.HELDOUT)
    assert len(tuned) == 5 and len(held) == 5
    assert not {c["id"] for c in tuned} & {c["id"] for c in held}
    assert not {c["query"].lower() for c in tuned} & {c["query"].lower() for c in held}


def test_lookup_regions_eval_scores_the_bestiary_entries_alone(bestiary):
    """The tuned asks against the committed entries only (no index): each names its entry, and the entry's text holds
    the region power and residents."""
    ev = _lookup_regions_eval()
    b = Bestiary()
    for c in ev.load_cases(ev.TUNED):
        res, info = merge(b, c["query"], [])
        assert info, c["id"]
        assert ev.score(c["answers"], ev.returned_text({"results": res}))[0], c["id"]

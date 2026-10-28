"""brain/places.py (BUGS A5): named place -> honest world position, and tools/build_places.py normalisation.
Fixture data is a made-up map in the shape of data/places_<build>.json."""
import json
import sqlite3

import pytest

from brain.places import Places, WHERE_TOOL, newest_file, where_from_snapshot
from tools import build_places as bp

VALLEY = [[0, 0], [100, 0], [100, 100], [0, 100]]
VILLAGE = [[40, 40], [60, 40], [60, 60], [40, 60]]  # inside the valley: the smaller one wins
WOODS = [[-100, 0], [0, 0], [0, 100], [-100, 100]]
DATA = {"schema": "dw_places/1", "build": "999", "provinces": [
    {"name": "Northmoor", "quest_region_id": 1, "regions": ["Bramble Valley", "Bramble Village"]},
    {"name": "Southfell", "quest_region_id": 2, "regions": ["Temple Woods"]},
    {"name": "Sandreach", "quest_region_id": 3, "regions": ["Far Dunes"]}], "regions": [
    {"name": "Bramble Valley", "region_id": 2, "power": 2, "polygon": VALLEY, "bbox": [0, 0, 100, 100],
     "province": "Northmoor"},
    {"name": "Bramble Village", "region_id": 3, "power": 2, "polygon": VILLAGE, "bbox": [40, 40, 60, 60],
     "province": "Northmoor"},
    {"name": "Temple Woods", "region_id": 1, "power": 1, "polygon": WOODS, "bbox": [-100, 0, 0, 100],
     "province": "Southfell"},
    {"name": "Far Dunes", "region_id": 9, "power": 6, "polygon": None, "bbox": [1000, 1000, 1200, 1200], "z": 5.0,
     "province": "Sandreach"}],
    "landmarks": [{"name": "Zanik", "position": [-50, 50, 1]}, {"name": "Zanik", "position": [90, 90, 2]},
                  {"name": "Shrine", "position": [20, 20, 0]}]}
HERE = [-60, 50, 0]  # in Temple Woods


class FakeKnowledge:
    def __init__(self, pages):
        self.pages = pages

    def lookup(self, query, kind=None):
        return {"ok": True, "data": {"results": [{"source": "wiki", "title": t, "text": x, "url": "u"}
                                                 for t, x in self.pages if t.lower() == query.lower()]}}


@pytest.fixture
def places():
    return Places(DATA, knowledge=FakeKnowledge([
        ("Goblin Talks", "Quest details: start=Speak to Zanik on the hill in Bramble Valley.; req=Rune Basics"),
        ("Old Guild", "The Old Guild is a ruin somewhere in Bramble Valley.")]))


def res(p, q, here=HERE, **kw):
    r = p.where(q, here, **kw)
    assert r["ok"]
    return r["data"]


def test_region_at_smallest_polygon_wins(places):
    assert places.region_name([50, 50]) == "Bramble Village"
    assert places.region_name([10, 10]) == "Bramble Valley"
    assert places.region_name([500, 500]) is None
    assert places.region_name([1100, 1100]) == "Far Dunes"  # bbox-only region


def test_region_gives_the_nearest_known_point_inside_it(places):
    d = res(places, "Bramble Valley")
    top = d["results"][0]
    assert d["you_are_in"] == "Temple Woods"
    assert top["kind"] == "region" and top["match"] == "exact" and top["region"] == "Bramble Valley"
    assert top["position"] == [20, 20, 0] and "Shrine" in top["basis"] and top["approximate"] is False
    assert top["distance_m"] == round(((20 + 60) ** 2 + 30 ** 2) ** 0.5)


def test_region_you_are_in(places):
    top = res(places, "temple woods")["results"][0]
    assert top["you_are_inside"] is True and top["distance_m"] == 0


def test_region_without_known_points_is_marked_approximate(places):
    top = res(places, "Far Dunes")["results"][0]
    assert top["approximate"] is True and "centre" in top["basis"] and top["position"] == [1100, 1100, 5.0]
    assert "bounding box" in top["shape"]


def test_npc_copies_per_province_your_province_first(places):
    d = res(places, "Zanik")
    top = d["results"][0]
    assert d["you_are_in_province"] == "Southfell"
    assert top["kind"] == "landmark" and top["position"] == [-50, 50, 1] and len(top["spots"]) == 2
    assert top["province"] == "Southfell" and top["your_province"] == "Southfell"
    assert [s["province"] for s in top["spots"]] == ["Southfell", "Northmoor"]  # nearest first, each with province
    assert top["other_provinces"] == ["Northmoor"] and top["spots_by_province"] == {"Southfell": 1, "Northmoor": 1}
    assert "copies in different provinces" in top["basis"] and "province you are in" in top["basis"]
    assert "moves" not in top["basis"] and "quest stage" not in top["basis"]  # the old unverified guess is gone
    assert top["summary"].startswith("Zanik: copy in Southfell (your province) at Temple Woods")
    assert "other copies in Northmoor (Bramble Valley" in top["summary"]


def test_npc_copy_in_your_province_wins_over_a_nearer_one(places):
    top = res(places, "Zanik", here=[5, 50, 0])["results"][0]  # Bramble Valley: Southfell copy 55 m, Northmoor 92 m
    assert top["province"] == "Northmoor" and top["position"] == [90, 90, 2]
    assert top["spots"][0]["province"] == "Southfell"  # the list itself stays nearest first
    assert top["summary"].startswith("Zanik: copy in Northmoor (your province)")


def test_npc_copies_outside_any_known_province(places):
    top = res(places, "Zanik", here=[500, 500, 0])["results"][0]
    assert "your_province" not in top and top["summary"].startswith("Zanik: nearest copy in Northmoor")


def test_province_query_lists_regions_lodestones_and_known_points(places):
    lodes = [{"id": "L2", "name": "Village stone", "position": [50, 50, 0], "can_teleport_now": True},
             {"id": "L1", "position": [-40, 40, 0]}]
    seen = [{"kind": "station", "name": "Furnace", "position": [30, 70, 0], "last_seen": 1}]
    top = res(places, "Northmoor", lodestones=lodes, remembered=seen)["results"][0]
    assert top["kind"] == "province" and top["match"] == "exact"
    assert [r["name"] for r in top["regions"]] == ["Bramble Valley", "Bramble Village"]
    assert [l["id"] for l in top["lodestones"]] == ["L2"]
    assert [k["what"] for k in top["known_points"]] == ["station Furnace you saw"]
    assert top["province"] == "Northmoor" and top["approximate"] is False and "inside the province" in top["basis"]
    inside = res(places, "southfell")["results"][0]
    assert inside["you_are_inside"] is True and inside["distance_m"] == 0
    far = res(places, "Sandreach")["results"][0]
    assert far["approximate"] is True and "centre of its biggest region Far Dunes" in far["basis"]


def test_regions_and_spots_carry_their_province(places):
    top = res(places, "Bramble Valley")["results"][0]
    assert top["province"] == "Northmoor" and top["region"] == "Bramble Valley"
    assert places.province_name([50, 50]) == "Northmoor" and places.province_name([500, 500]) is None


def test_wiki_links_a_quest_to_the_npc_spot_inside_the_region_it_names(places):
    d = res(places, "Goblin Talks")
    top = d["results"][0]
    assert top["name"] == "Zanik" and top["position"] == [90, 90, 2]  # not the nearer Temple Woods spot
    assert top["for"] == "Goblin Talks" and "not 'Goblin Talks' itself" in top["basis"] and "wiki" in top["source"]
    assert d["wiki_said"]["mentions"] == ["Bramble Valley", "Zanik"]


def test_wiki_naming_a_province_picks_that_provinces_copy():
    p = Places(DATA, knowledge=FakeKnowledge([("Goblin Trip", "Speak to Zanik somewhere in Northmoor.")]))
    top = res(p, "Goblin Trip")["results"][0]
    assert top["name"] == "Zanik" and top["province"] == "Northmoor" and top["position"] == [90, 90, 2]


def test_wiki_region_only_is_labelled_not_the_place(places):
    top = res(places, "Old Guild")["results"][0]
    assert top["kind"] == "region" and top["name"] == "Bramble Valley" and "exact spot there is unknown" in top["basis"]


def test_unknown_place_never_guessed(places):
    lodes = [{"id": "L1", "position": [-40, 40, 0]}, {"id": "L2", "position": [50, 50, 0]}]
    d = res(places, "Nowhere Keep", lodestones=lodes)
    assert d["found"] is False and d["results"] == [] and "Don't go_to it" in d["note"]
    assert "Bramble Valley" in d["regions_known"]
    assert d["provinces_known"]["Northmoor"] == ["Bramble Valley", "Bramble Village"]
    assert [l["id"] for l in d["lodestones"]] == ["L1", "L2"] and d["lodestones"][1]["region"] == "Bramble Village"


def test_own_knowledge_and_lodestones(places):
    lodes = [{"id": "L2", "name": "Village stone", "position": [50, 50, 0], "can_teleport_now": True}]
    saved = {"my base": {"position": [80, 10, 0], "note": "chests"}}
    seen = [{"kind": "station", "name": "Furnace", "position": [30, 70, 0], "last_seen": 1}]
    d = res(places, "my base", lodestones=lodes, saved=saved, remembered=seen)
    top = d["results"][0]
    assert top["kind"] == "saved" and top["position"] == [80, 10, 0] and "chests" in top["basis"]
    assert top["nearest_lodestone"]["id"] == "L2" and top["nearest_lodestone"]["can_teleport_now"] is True
    assert res(places, "furnace", remembered=seen)["results"][0]["source"] == "map memory"
    assert res(places, "village stone", lodestones=lodes)["results"][0]["kind"] == "lodestone"
    # a region's best point can be one he saw himself
    v = res(places, "Bramble Valley", here=[-5, 75, 0], remembered=seen)["results"][0]
    assert v["position"] == [30, 70, 0] and "Furnace" in v["via"]


def test_partial_name_and_empty_query(places):
    d = res(places, "Bramble")
    assert {r["name"] for r in d["results"]} >= {"Bramble Valley", "Bramble Village"}
    assert all(r["match"] == "part" for r in d["results"])
    assert places.where("the", HERE)["ok"] is False


def test_snapshot_handler_and_tool_doc(places):
    snap = {"sightings": [{"kind": "interactable", "class": "BP_WorldLodestone_C", "name": "Lodestone",
                           "id": "x", "position": [-40, 40, 0]}]}
    d = where_from_snapshot(places, {"place": "Zanik"}, {"position": HERE}, snap)["data"]
    assert d["results"][0]["nearest_lodestone"]["id"] == "x"
    assert WHERE_TOOL["function"]["name"] == "where" and WHERE_TOOL["function"]["parameters"]["required"] == ["place"]


def test_build_places_normalises_both_shapes():
    legacy_regions = [{"name": "Bramble Valley", "region_id": 2, "power": 2, "spline": {"bbox_m": [0, 0, 10, 10]}},
                      {"name": "", "region_id": 5}]
    legacy_lms = [{"desc": "Zanik", "loc": [1, 2, 3], "discover": False, "cat": None}, {"desc": "", "loc": [0, 0, 0]}]
    doc = bp.normalise(legacy_regions, legacy_lms, build="999", source={"kind": "t"})
    assert doc["regions"] == [{"name": "Bramble Valley", "region_id": 2, "power": 2, "polygon": None,
                               "bbox": [0.0, 0.0, 10.0, 10.0], "province": None, "province_source": None}]
    assert doc["landmarks"] == [{"name": "Zanik", "position": [1.0, 2.0, 3.0], "needs_discovery": False,
                                 "region": "Bramble Valley", "province": None}]
    raw = bp._payload({"ok": True, "data": {"result": {"regions": [{"name": "R", "polygon": [[0, 0], [4, 0], [4, 4]]}],
                                                       "landmarks": [{"desc": "S", "position": [1, 1, 0]}]}}})
    doc = bp.normalise(raw["regions"], raw["landmarks"], build="999", source={})
    assert doc["regions"][0]["polygon"] == [[0, 0], [4, 0], [4, 4]] and doc["regions"][0]["bbox"] == [0, 0, 4, 4]
    assert Places(doc).region_name([3, 1]) == "R"


def test_build_places_provinces_from_game_enum_wiki_and_geometry(tmp_path):
    enums = tmp_path / "999" / "luatypes"
    enums.mkdir(parents=True)
    (enums / "Dominion_enums.lua").write_text(
        "---@enum EQuestRegion\nlocal EQuestRegion = {\n    None = 0,\n    North_Moor = 1,\n    Sand_Reach = 2,\n"
        "    Dead_Isle = 3,\n    MAX = 4,\n}\n", encoding="utf-8")
    provs = bp.game_provinces("999", dumps=tmp_path)
    assert [(p["name"], p["quest_region_id"]) for p in provs] == [("North Moor", 1), ("Sand Reach", 2), ("Dead Isle", 3)]
    db = tmp_path / "k.sqlite"
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE docs(title, url, body)")
    con.executemany("INSERT INTO docs VALUES (?, ?, ?)", [
        ("Bramble Valley", "https://w/Bramble_Valley", "name: Bramble Valley\nlocation: North Moor\nA valley."),
        ("High Peaks", "https://w/High_Peaks", "name: High Peaks\nlocation: Ashenfall\nNot a province."),
        ("Ashenfall", "https://w/Ashenfall#Sand_Reach", "This region includes:\n- Far Dunes\n- High Peaks")])
    con.commit()
    con.close()
    wiki = bp.wiki_province_facts(["Bramble Valley", "Far Dunes", "High Peaks", "Dead Isle"],
                                  [p["name"] for p in provs], db=db)
    assert wiki["Bramble Valley"][0] == "North Moor" and "infobox" in wiki["Bramble Valley"][1]
    assert wiki["Far Dunes"][0] == "Sand Reach" and "Ashenfall#Sand_Reach" in wiki["Far Dunes"][1]
    assert wiki["High Peaks"][0] == "Sand Reach"  # a non-province infobox location falls through to the list
    sq = lambda x0, y0, x1, y1: [[x0, y0], [x1, y0], [x1, y1], [x0, y1]]  # noqa: E731
    regions = [{"name": "Bramble Valley", "polygon": VALLEY},
               {"name": "Far Dunes", "polygon": sq(1000, 1000, 1200, 1200)},
               {"name": "Dead Isle", "polygon": sq(-500, -500, -300, -300)},
               {"name": "Isle Hub", "polygon": sq(-450, -450, -400, -400)},
               {"name": "Isle Dock", "polygon": sq(-310, -310, -250, -250)},
               {"name": "Tagged", "tag": "MapRegion.SandReach.Tagged", "polygon": WOODS},
               {"name": "Lost", "polygon": [[5000, 5000], [5010, 5000], [5010, 5010]]}]
    doc = bp.normalise(regions, [{"desc": "Zanik", "position": [-420, -420, 0]}], build="999", source={},
                       provinces=provs, wiki=wiki)
    got = {r["name"]: (r["province"], r["province_source"]) for r in doc["regions"]}
    assert got["Bramble Valley"][0] == "North Moor" and got["Far Dunes"][0] == "Sand Reach"
    assert got["Dead Isle"] == ("Dead Isle", "the region has the province's name (game EQuestRegion)")
    assert got["Isle Hub"][0] == "Dead Isle" and "inside the bigger region Dead Isle" in got["Isle Hub"][1]
    assert got["Isle Dock"][0] == "Dead Isle" and "overlaps only Dead Isle" in got["Isle Dock"][1]
    assert got["Tagged"][0] == "Sand Reach" and "MapRegionTag" in got["Tagged"][1]  # the game's own tag wins
    assert got["Lost"] == (None, None)  # no source: left unknown, never guessed
    assert doc["landmarks"][0]["region"] == "Isle Hub" and doc["landmarks"][0]["province"] == "Dead Isle"
    assert next(p for p in doc["provinces"] if p["name"] == "Dead Isle")["regions"] == ["Dead Isle", "Isle Hub",
                                                                                       "Isle Dock"]
    assert Places(doc).where("Dead Isle", [-420, -420, 0])["data"]["you_are_in_province"] == "Dead Isle"


@pytest.mark.skipif(newest_file() is None, reason="no data/places_<build>.json")
def test_real_data_resolves_bramblemead_valley():
    p = Places()
    d = p.where("Bramblemead Valley", [50.65, 1890.26, -36.33])["data"]
    top = d["results"][0]
    assert d["found"] and top["kind"] == "region" and top["source"].startswith("game data")
    assert top["position"] and top["basis"]
    assert len(p.where("Zanik", None)["data"]["results"][0]["spots"]) >= 2


@pytest.mark.skipif(newest_file() is None, reason="no data/places_<build>.json")
def test_real_data_provinces():
    p = Places()
    assert {"Brynmoor", "Ghornfell", "Fellhollow", "Dowdun Reach", "Umbral Sands"} <= {x["name"] for x in p.provinces}
    assert all(r.get("province") for r in p.regions)
    assert next(r for r in p.regions if r["name"] == "Stormtouched Highlands")["province"] == "Ghornfell"
    temple = [50.65, 1890.26, -36.33]  # the Temple Woods lodestone
    z = p.where("Zanik", temple)["data"]["results"][0]
    assert z["province"] == "Brynmoor" and len(z["spots_by_province"]) >= 3
    assert all(s["province"] for s in z["spots"])
    f = p.where("Fellhollow", temple)["data"]["results"][0]
    assert f["kind"] == "province" and "Bleakfields Valley" in [r["name"] for r in f["regions"]]


@pytest.mark.parametrize("available", [True, False, None])
def test_current_teleport_availability_survives_place_views(places, available):
    lodes = [{"id": "L2", "position": [50, 50, 0], "can_teleport_now": available}]
    saved = {"my base": {"position": [80, 10, 0]}}
    nearest = res(places, "my base", lodestones=lodes, saved=saved)["results"][0]["nearest_lodestone"]
    province = res(places, "Northmoor", lodestones=lodes)["results"][0]["lodestones"][0]
    for view in (nearest, province):
        assert "reachable" not in view
        if available is None:
            assert "can_teleport_now" not in view
        else:
            assert view["can_teleport_now"] is available

"""brain/places.py (BUGS A5): named place -> honest world position, and tools/build_places.py normalisation.
Fixture data is a made-up map in the shape of data/places_<build>.json."""
import json

import pytest

from brain.places import Places, WHERE_TOOL, newest_file, where_from_snapshot
from tools import build_places as bp

VALLEY = [[0, 0], [100, 0], [100, 100], [0, 100]]
VILLAGE = [[40, 40], [60, 40], [60, 60], [40, 60]]  # inside the valley: the smaller one wins
WOODS = [[-100, 0], [0, 0], [0, 100], [-100, 100]]
DATA = {"schema": "dw_places/1", "build": "999", "regions": [
    {"name": "Bramble Valley", "region_id": 2, "power": 2, "polygon": VALLEY, "bbox": [0, 0, 100, 100]},
    {"name": "Bramble Village", "region_id": 3, "power": 2, "polygon": VILLAGE, "bbox": [40, 40, 60, 60]},
    {"name": "Temple Woods", "region_id": 1, "power": 1, "polygon": WOODS, "bbox": [-100, 0, 0, 100]},
    {"name": "Far Dunes", "region_id": 9, "power": 6, "polygon": None, "bbox": [1000, 1000, 1200, 1200], "z": 5.0}],
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


def test_npc_spots_nearest_first(places):
    top = res(places, "Zanik")["results"][0]
    assert top["kind"] == "landmark" and top["position"] == [-50, 50, 1] and len(top["spots"]) == 2
    assert "2 spots" in top["basis"] and "unknown until you see it" in top["basis"]


def test_wiki_links_a_quest_to_the_npc_spot_inside_the_region_it_names(places):
    d = res(places, "Goblin Talks")
    top = d["results"][0]
    assert top["name"] == "Zanik" and top["position"] == [90, 90, 2]  # not the nearer Temple Woods spot
    assert top["for"] == "Goblin Talks" and "not 'Goblin Talks' itself" in top["basis"] and "wiki" in top["source"]
    assert d["wiki_said"]["mentions"] == ["Bramble Valley", "Zanik"]


def test_wiki_region_only_is_labelled_not_the_place(places):
    top = res(places, "Old Guild")["results"][0]
    assert top["kind"] == "region" and top["name"] == "Bramble Valley" and "exact spot there is unknown" in top["basis"]


def test_unknown_place_never_guessed(places):
    lodes = [{"id": "L1", "position": [-40, 40, 0]}, {"id": "L2", "position": [50, 50, 0]}]
    d = res(places, "Nowhere Keep", lodestones=lodes)
    assert d["found"] is False and d["results"] == [] and "Don't go_to it" in d["note"]
    assert "Bramble Valley" in d["regions_known"]
    assert [l["id"] for l in d["lodestones"]] == ["L1", "L2"] and d["lodestones"][1]["region"] == "Bramble Village"


def test_own_knowledge_and_lodestones(places):
    lodes = [{"id": "L2", "name": "Village stone", "position": [50, 50, 0], "reachable": True}]
    saved = {"my base": {"position": [80, 10, 0], "note": "chests"}}
    seen = [{"kind": "station", "name": "Furnace", "position": [30, 70, 0], "last_seen": 1}]
    d = res(places, "my base", lodestones=lodes, saved=saved, remembered=seen)
    top = d["results"][0]
    assert top["kind"] == "saved" and top["position"] == [80, 10, 0] and "chests" in top["basis"]
    assert top["nearest_lodestone"]["id"] == "L2" and top["nearest_lodestone"]["reachable"] is True
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
                               "bbox": [0.0, 0.0, 10.0, 10.0]}]
    assert doc["landmarks"] == [{"name": "Zanik", "position": [1.0, 2.0, 3.0], "needs_discovery": False}]
    raw = bp._payload({"ok": True, "data": {"result": {"regions": [{"name": "R", "polygon": [[0, 0], [4, 0], [4, 4]]}],
                                                       "landmarks": [{"desc": "S", "position": [1, 1, 0]}]}}})
    doc = bp.normalise(raw["regions"], raw["landmarks"], build="999", source={})
    assert doc["regions"][0]["polygon"] == [[0, 0], [4, 0], [4, 4]] and doc["regions"][0]["bbox"] == [0, 0, 4, 4]
    assert Places(doc).region_name([3, 1]) == "R"


@pytest.mark.skipif(newest_file() is None, reason="no data/places_<build>.json")
def test_real_data_resolves_bramblemead_valley():
    p = Places()
    d = p.where("Bramblemead Valley", [50.65, 1890.26, -36.33])["data"]
    top = d["results"][0]
    assert d["found"] and top["kind"] == "region" and top["source"].startswith("game data")
    assert top["position"] and top["basis"]
    assert len(p.where("Zanik", None)["data"]["results"][0]["spots"]) >= 2

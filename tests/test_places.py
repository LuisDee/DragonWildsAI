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
    assert all(r["match"] == "leading" for r in d["results"])  # the first word of both names
    assert all(r["match"] == "part" for r in res(places, "Valley")["results"])
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


# ------------------------------------------------------------------ compass, the Where line, go_to <place name>


def test_compass_matches_the_wikis_geography_on_the_real_map():
    """north = -Y, east = +X: the wiki's 'Bramblemead Valley is south of the Whispering Swamp', 'the Fractured
    Plains, east of the Stormtouched Highlands', 'Umbral Sands, directly east of Ghornfell', 'Dowdun Reach, south of
    Silverthorn Keep' hold over the game's own region polygons."""
    from brain.geom import direction
    from brain.places import centroid
    p = Places()
    if not p.regions:
        pytest.skip("no data/places_<build>.json")
    c = {r["name"]: centroid(r["_shape"]) for r in p.regions}
    prov = {pv["name"]: [sum(c[r][i] for r in pv["regions"]) / len(pv["regions"]) for i in (0, 1)]
            for pv in p.provinces if pv.get("regions")}
    assert direction(c["Whispering Swamp"], c["Bramblemead Valley"]) == "S"
    assert direction(c["Stormtouched Highlands"], c["Fractured Plains"]) == "E"
    assert direction(prov["Ghornfell"], prov["Umbral Sands"]) == "E"
    assert direction(c["Silverthorn Keep"], prov["Dowdun Reach"]) == "S"
    assert direction([0, 0], [0, -10]) == "N" and direction([0, 0], [10, 0]) == "E"


def test_region_at_cached_and_box_filtered_agrees_with_the_plain_scan():
    """region_at keeps a point's region (the map is fixed per Places) and skips regions whose box misses the point
    (perf 2026-11-19); the answer is the plain smallest-polygon scan's, for landmarks of the repo map."""
    from brain.places import inside
    p = Places()
    if not p.regions:
        pytest.skip("no data/places_<build>.json")

    def plain(pos):
        hits = [r for r in p.regions if inside(r["_shape"], pos[0], pos[1])]
        return min(hits, key=lambda r: r["_area"]) if hits else None

    pts = [lm["position"] for rows in p.landmarks.values() for lm in rows][:400]
    assert pts and any(plain(x) for x in pts)
    for pos in pts:
        assert p.region_at(pos) is plain(pos)
        assert p.region_at(pos) is plain(pos)  # from the cache


def test_where_line_names_region_province_named_places_and_the_go_to_point():
    from brain.broker import EventBroker
    b = EventBroker()
    b.places = Places(DATA)
    b.observe({"position": [-55, 50, 0], "players": []})
    b.action_started("go_to", {"target": [-55, 10, 8]})
    line = b.where_line()
    assert line.startswith("Where: in Temple Woods (Southfell); near Zanik 5 m E, Shrine 81 m E; "), line
    assert line.endswith("your go_to point is 40 m N, 8 m higher"), line
    b.places = None  # no map data: no location words, nothing invented
    assert "Temple Woods" not in (b.where_line() or "")


class _Body:
    """A body that sees no 'Zanik' (unknown_target for any name) and walks to points."""

    def __init__(self, pos, active=()):
        self.pos, self.calls, self.active = list(pos), [], list(active)

    def get_state(self):
        return {"ok": True, "reason": None, "data": {"position": self.pos, "players": []}}

    def call(self, tool, args):
        if tool == "get_state":
            return self.get_state()
        if tool == "quests":  # the active quests and their map markers (quests.lua summary)
            return {"ok": True, "reason": None, "data": {"active": self.active}}
        self.calls.append(args)
        if tool == "look":  # after the walk: the named thing stands at the map's spot
            return {"ok": True, "reason": None, "data": {"things": [{"name": args["about"], "distance": 1.2,
                                                                      "position": self.pos}]}}
        if isinstance(args.get("target"), str):
            return {"ok": False, "reason": "unknown_target", "data": {"detail": "target_not_visible"}}
        self.pos = list(args["target"])
        return {"ok": True, "reason": None, "data": {"position": self.pos, "target_position": self.pos,
                                                       "arrive_tolerance": 3.0}}


def _executor(tmp_path, body):
    from brain.executor import Executor
    from brain.jsonl_log import JsonlLogger
    from brain.state_store import StateStore
    ex = Executor(body, StateStore(tmp_path / "state"), JsonlLogger(tmp_path / "log.jsonl"), max_attempts=1)
    ex.places = Places(DATA)
    return ex


def test_go_to_a_name_the_body_cant_see_walks_to_the_game_map_spot(tmp_path):
    from brain.state_store import Task
    body = _Body(HERE)
    out = _executor(tmp_path, body).run_task(Task(skill="go_to", args={"target": "Zanik"}))
    assert out.ok, out.reason
    assert body.calls[:2] == [{"target": "Zanik"}, {"target": [-50.0, 50.0, 1.0]}]  # the body first, then the map
    assert body.calls[2]["about"] == "Zanik" and out.data["on_arrival"] == "Zanik is here, 1 m away"
    assert out.data["resolved"] == ("'Zanik' was not in sight; walked to the game map's landmark Zanik in "
                                    "Temple Woods, Southfell"), out.data["resolved"]  # seen there: no caveat


def test_go_to_an_unknown_or_partial_name_keeps_the_bodys_answer(tmp_path):
    from brain.state_store import Task
    for name in ("the big tree", "Village"):  # nothing by that name / only part of a name
        body = _Body(HERE)
        out = _executor(tmp_path, body).run_task(Task(skill="go_to", args={"target": name}))
        assert not out.ok and out.reason == "unknown_target" and body.calls == [{"target": name}]
        assert "resolved" not in (out.data or {})


def test_go_to_a_names_leading_words_walks_there_only_when_one_name_leads_so(tmp_path):
    from brain.state_store import Task
    out = _executor(tmp_path, _Body(HERE)).run_task(Task(skill="go_to", args={"target": "Temple"}))
    assert "region Temple Woods" in out.data["resolved"], out.data  # "Temple" leads only Temple Woods (he is in it)
    body = _Body(HERE)
    out = _executor(tmp_path, body).run_task(Task(skill="go_to", args={"target": "Bramble"}))  # Valley and Village
    assert not out.ok and out.reason == "unknown_target" and body.calls == [{"target": "Bramble"}]
    assert {"Bramble Valley", "Bramble Village"} <= {x.split(" (")[0] for x in out.data["map_names_like_it"]}


def test_go_to_a_name_of_an_active_quests_map_marker_walks_to_the_marker(tmp_path):
    from brain.state_store import Task
    rc = {"quest": "Ratcatcher", "step": "Kill rats and successfully cook one rat roast from their meat.",
          "where": [{"name": "Vannaka NPC", "kind": "npc", "position": [152.5, 1787.1, -30.0], "distance_m": 94},
                    {"name": "Windmill Area", "kind": "area", "radius_m": 80, "position": [156.1, 1713.4, -3.5], "distance_m": 158}]}
    body = _Body(HERE, [rc])  # live 19:1xZ: go_to "windmill" was unknown_target; the step names it, the map marks it
    out = _executor(tmp_path, body).run_task(Task(skill="go_to", args={"target": "windmill"}))
    assert out.ok and body.calls[-1] == {"target": [156.1, 1713.4, -3.5]}, (out, body.calls)
    assert out.data["resolved"].startswith("'windmill' is not in sight; walking to the game map's Ratcatcher quest marker "
                                           "Windmill Area, 158 m away: an area of 80 m radius"), out.data["resolved"]
    two = {**rc, "where": rc["where"] + [{"name": "Windmill Top", "kind": "target", "position": [1, 2, 3]}]}
    body = _Body(HERE, [two])  # two markers lead with "windmill": the model's call, the body's answer stands
    out = _executor(tmp_path, body).run_task(Task(skill="go_to", args={"target": "windmill"}))
    assert not out.ok and out.reason == "unknown_target"


def test_real_data_bramblemead_is_the_valley():
    d = Places().where("Bramblemead", [62.6, 1873.7, -35.5])["data"]  # live 17:2xZ: go_to "Bramblemead" unknown_target
    assert d["results"][0]["name"] == "Bramblemead Valley" and d["results"][0]["match"] == "leading"


def test_go_to_the_region_you_are_in_says_so(tmp_path):
    from brain.state_store import Task
    body = _Body(HERE)
    out = _executor(tmp_path, body).run_task(Task(skill="go_to", args={"target": "Temple Woods"}))
    assert not out.ok and body.calls == [{"target": "Temple Woods"}]
    assert out.data["resolved"] == "'Temple Woods' is the game map's region Temple Woods: you are in it now"


def test_go_to_says_it_takes_map_names_only_when_the_brain_resolves_them(tmp_path):
    from conftest import Rig
    rig = Rig(tmp_path)
    target = lambda: next(t for t in rig.controller.tools  # noqa: E731
                          if t["function"]["name"] == "go_to")["function"]["parameters"]["properties"]["target"]
    assert "game's map" not in str(target().get("description"))
    rig.controller.use_map_names()
    assert str(target()["description"]).endswith("the result says what it was taken to be.")


def test_mentioned_names_map_places_in_a_chat_line():
    p = Places({**DATA, "landmarks": DATA["landmarks"] + [{"name": "Water Anima Vent", "position": [-40, 50, 0]},
                                                          {"name": "Anima Vent", "position": [0, 0, 0]}]})
    said = p.mentioned("claude head over to the water anima vent", HERE)
    assert said == ['Water Anima Vent: a landmark on the game map, nearest 20 m away in Temple Woods; '
                    'go_to "Water Anima Vent" walks there']  # the longer name wins over "Anima Vent" inside it
    assert p.mentioned("meet me in temple woods", HERE) == ["Temple Woods: a region on the game map; you are in it"]
    assert p.mentioned("the lodestone by the water anima vent", HERE)[0].endswith(
        'go_to "the lodestone by Water Anima Vent" walks to the lodestone nearest it')
    # one-word names are too common to tag ("Zanik", "Statue"); a word of a longer name only lists candidates
    assert not any("Zanik" in s for s in p.mentioned("go see zanik by the shrine", HERE))


def test_mentioned_one_word_of_a_few_map_names_lists_the_candidates():
    p = Places({**DATA, "landmarks": DATA["landmarks"] + [{"name": "Forgotten Temple", "position": [300, 0, 0]}]})
    said = p.mentioned("claude come to the temple", HERE)
    assert len(said) == 1 and said[0].startswith('"temple" is a word of the map names ')
    assert "Temple Woods (a region; you are in it)" in said[0] and "Forgotten Temple (a landmark, " in said[0]
    assert said[0].endswith("go_to takes the full name")


class _TalkBody(_Body):
    """Sees no 'Zanik' until it stands at the map's spot; then talk opens the conversation."""

    def call(self, tool, args):
        if tool == "talk":
            self.calls.append(("talk", dict(args)))
            if self.pos != [-50.0, 50.0, 1.0]:
                return {"ok": False, "reason": "unknown_target", "data": {"detail": "I can't see Zanik within 120 m."}}
            return {"ok": True, "reason": None, "data": {"npc": "Zanik", "lines": [{"speaker": "Zanik", "text": "Hi"}]}}
        return super().call(tool, args)


def test_talk_to_an_npc_out_of_sight_walks_to_its_map_spot_then_talks(tmp_path):
    from brain.state_store import Task
    from brain.state_store import MOCK_SKILLS, SkillRegistry, StateStore
    body = _TalkBody(HERE)
    ex = _executor(tmp_path, body)
    ex.store = StateStore(tmp_path / "state2", skills=SkillRegistry([*MOCK_SKILLS, "talk"], specs={"talk": {
        "name": "talk", "kind": "action", "args": {"type": "object", "properties": {"target": {"type": "string"}}}}}))
    out = ex.run_task(Task(skill="talk", args={"target": "Zanik"}))
    assert out.ok, out.reason
    assert body.calls == [("talk", {"target": "Zanik"}), {"target": [-50.0, 50.0, 1.0]}, ("talk", {"target": "Zanik"})]
    assert out.data["npc"] == "Zanik" and "walking to the game map's landmark Zanik" in out.data["resolved"]


def test_go_to_a_quest_area_he_is_already_inside_walks_to_its_centre(tmp_path):
    """Live ClaudeQ7 22:28Z: go_to "the windmill" at Vannaka, inside Ratcatcher's 80 m Windmill Area, came back
    unknown_target "you are in it now" (a miss, 10.5 s); he then walked to the marker's centre by coordinates."""
    from brain.state_store import Task
    at_vannaka = [150.94, 1789.63, -26.32]
    rc = {"quest": "Ratcatcher", "step": "Kill rats and successfully cook one rat roast from their meat.",
          "where": [{"name": "Windmill Area", "kind": "area", "radius_m": 80, "position": [156.1, 1713.4, -3.5],
                     "distance_m": 76, "inside": True}]}
    for name in ("the windmill", "windmill", "Windmill Area"):
        body = _Body(at_vannaka, [rc])
        out = _executor(tmp_path, body).run_task(Task(skill="go_to", args={"target": name}))
        assert out.ok and body.calls[-1] == {"target": [156.1, 1713.4, -3.5]}, (name, out, body.calls)
        assert f"{name!r} is the game map's Ratcatcher quest marker Windmill Area: you were already inside it (an area " \
               "of 80 m radius on the quest map); walking to its centre, 76 m away" == out.data["resolved"]


def test_go_to_a_lodestone_id_from_the_lodestones_tool_walks_to_it(tmp_path):
    from brain.state_store import Task

    class _LodeBody(_Body):
        def call(self, tool, args):
            if tool == "lodestones":
                return {"ok": True, "reason": None, "data": {"lodestones": [
                    {"id": "lodestone:5E74", "position": [-50.0, 50.0, 1.0], "distance": 53}]}}
            return super().call(tool, args)

    body = _LodeBody(HERE)
    out = _executor(tmp_path, body).run_task(Task(skill="go_to", args={"target": "lodestone:5E74"}))
    assert out.ok, out.reason
    assert body.calls[:2] == [{"target": "lodestone:5E74"}, {"target": [-50.0, 50.0, 1.0]}]
    assert out.data["resolved"].startswith("lodestone:5E74 is the lodestone at")
    body = _LodeBody(HERE)  # an id the list doesn't have: the body's own answer stands
    out = _executor(tmp_path, body).run_task(Task(skill="go_to", args={"target": "lodestone:FFFF"}))
    assert not out.ok and out.reason == "unknown_target"


VENT_MAP = {**DATA, "landmarks": DATA["landmarks"] + [{"name": "Law Anima Vent", "position": [22, 20, 0]}]}


def test_a_seen_thing_takes_the_maps_name_only_when_it_is_a_fuller_name_of_the_same_thing():
    """Brain logs of 2026-11-15 to 17: 121 of 123 renamed look rows carried another thing's name. Ash-log piles and a
    lore item within 4 m of Vannaka's map spot were shown as "Vannaka" (105 rows), a Rune Altar he had built by a vent
    as "Astral Anima Vent" (8), a Campfire as "Doric"."""
    p = Places(VENT_MAP)
    assert p.name_for("Anima Vent", [20.5, 20, 0]) == "Law Anima Vent"  # (the Shrine's spot is nearer: not its name)
    assert p.name_for("Ash Logs", [-50, 51, 1]) is None  # 1 m from Zanik's spot: a log pile, not Zanik
    assert p.name_for("Rune Altar", [22, 21, 0]) is None  # built beside the vent: not the vent
    assert p.name_for("Zanik", [-50, 51, 1]) == "Zanik"
    assert p.name_for("Anima Vent", [60, 60, 0]) is None and p.name_for(None, [22, 20, 0]) is None


def test_look_rows_beside_another_things_map_spot_keep_their_own_name():
    from brain.controller import _map_names
    rows = [{"name": "Ash Logs", "position": [-50, 51, 1], "match": 0},
            {"name": "Anima Vent", "position": [20.5, 20, 0], "match": 2}]
    assert _map_names(rows, Places(VENT_MAP), None) is None
    assert rows[0] == {"name": "Ash Logs", "position": [-50, 51, 1], "match": 0}
    assert rows[1]["name"] == "Law Anima Vent" and rows[1]["seen_as"] == "Anima Vent"
    # asked about Zanik with a log pile at Zanik's spot: the pile is no sighting of Zanik
    rows = [{"name": "Ash Logs", "position": [-50, 51, 1], "match": 0}]
    assert not _map_names(rows, Places(VENT_MAP), "Zanik") and rows[0]["name"] == "Ash Logs"
    # asked about the Water vent, the Law one in sight: its map name lacks a word of it, so it is no match
    rows = [{"name": "Anima Vent", "position": [20.5, 20, 0], "match": 2}]
    assert _map_names(rows, Places(VENT_MAP), "Water Anima Vent") is False and "match" not in rows[0]


L3_HERE = [148.48, 1912.74, -31.85]  # ClaudeDev in Temple Woods, 19 Nov (L3 runs): Crasorak Kara's door ~226 m east


@pytest.mark.skipif(newest_file() is None, reason="no data/places_<build>.json")
def test_the_word_vault_names_the_bestiary_vaults_nearest_first():
    """L3 2026-11-19 (log 30608 line 24): "vault" read only as the Vault Guardian landmarks 3.5 km off; the bestiary's
    vaults (Crasorak Kara's door 223 m away) were not part of the map names at all."""
    p = Places()
    said = p.mentioned("gear up for the vault", L3_HERE)
    line = next(s for s in said if s.startswith('"vault": the game\'s data has'))
    assert line.split("nearest: ")[1].startswith("Crasorak Kara (a vault in Temple Woods, PL 2, 226 m), ")
    assert any("Vault Guardian (a landmark" in s for s in said)  # the landmarks stay listed beside it
    assert p.mentioned("go to the Temple Woods vault", L3_HERE) == [
        '"Temple Woods vault" is Crasorak Kara (a vault in Temple Woods, PL 2, 226 m); go_to "Crasorak Kara" walks to it']


@pytest.mark.skipif(newest_file() is None, reason="no data/places_<build>.json")
def test_where_resolves_a_vault_by_name_or_full_alias_to_its_door():
    p = Places()
    top = p.where("Crasorak Kara", L3_HERE)["data"]["results"][0]
    assert (top["kind"], top["match"], top["approximate"], top["power_level"]) == ("vault", "exact", False, 2)
    assert top["position"] == [374.58, 1918.74, -2.76] and "door, read by the game" in top["basis"]
    assert p.where("Temple Woods vault", L3_HERE)["data"]["results"][0]["name"] == "Crasorak Kara"
    assert "Crasorak Kara" not in [o["name"] for o in p.where("Temple", L3_HERE)["data"]["results"]
                                   if o["match"] == "leading"]  # "Temple" leads the region, not the vault's alias


def test_a_vault_without_a_door_read_is_approximate_or_unplaced():
    vaults = {"Aa Kara": {"kind": "vault", "name": "Aa Kara", "aliases": ["Sand vault"], "area": "Temple Woods",
                          "power_level": "3", "map_centre": {"position": [-40.0, 50.0], "accuracy_m": 50}},
              "Bb Kara": {"kind": "vault", "name": "Bb Kara", "area": "Sand Reach", "power_level": "7"}}
    p = Places(DATA, vaults=vaults)
    a = p.where("Aa Kara", HERE)["data"]["results"][0]
    assert a["approximate"] and a["distance_m"] == 20 and "within about 50 m" in a["basis"]
    b = p.where("Bb Kara", HERE)["data"]["results"][0]
    assert b["position"] is None and "no position" in b["basis"]
    line = next(s for s in p.mentioned("the vault", HERE) if s.startswith('"vault"'))
    assert ("Aa Kara (a vault in Temple Woods, PL 3, 20 m (approximate)), Bb Kara (a vault in Sand Reach, PL 7, "
            "position not known)") in line

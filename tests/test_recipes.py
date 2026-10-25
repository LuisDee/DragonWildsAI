"""Recipe catalog (tools/build_recipes.py -> data/recipes_<build>.json + mod/body/recipe_data.lua),
the crafting drift check analysis (tools/craft_drift.py) and the patch pipeline's recipe diff."""
import json
import subprocess
from pathlib import Path

import pytest

from brain.paths import REPO_ROOT
from tests.test_lua_bridge import LUA
from tools import build_recipes as br
from tools import craft_drift as cd

CATALOG = REPO_ROOT / "data" / "recipes_26161880.json"
ORE = "/Game/I/ITEM_IronOre.ITEM_IronOre"
SALV = "/DR/I/ITEM_Salvage_Iron.ITEM_Salvage_Iron"
BAR = "/Game/I/ITEM_IronBar.ITEM_IronBar"
CHAR = "/Game/I/ITEM_Charcoal.ITEM_Charcoal"
TABLE_C = "/Game/S/DT_Crafting.DT_Crafting"
TABLE_P = "/Game/S/DT_Processing.DT_Processing"


def raw_doc() -> dict:
    """A tiny raw recipe_dump output (dw_recipes_raw/1)."""
    return {
        "schema": "dw_recipes_raw/1", "build": "t",
        "recipes": [
            {"path": "/Game/R/RECIPE_IronBar.RECIPE_IronBar", "id": "RECIPE_IronBar", "class": "RecipeData",
             "consumed": [{"item": ORE, "count": 3}], "created": [{"item": BAR, "count": 1}],
             "craft_time": 0.5, "max_craft_time": 1.5, "craft_quantity_multiplier": 1.2000000476837,
             "min_processing_time": 8.0, "max_processing_time": 12.0, "extra": [], "fuel_override": []},
            {"path": "/DR/R/RECIPE_IronBar_Salvage.RECIPE_IronBar_Salvage", "class": "RecipeData",
             "consumed": [{"item": SALV, "count": 9}], "created": [{"item": BAR, "count": 1}], "extra": [],
             "fuel_override": []},
            # same asset name under two mount roots -> id@root
            {"path": "/Game/R/RECIPE_Dup.RECIPE_Dup", "consumed": [], "created": [{"item": BAR, "count": 1}]},
            {"path": "/UmS/R/RECIPE_Dup.RECIPE_Dup", "consumed": [], "created": [{"item": BAR, "count": 1}]},
        ],
        "stations": [
            {"path": "/Game/S/BP_Station_Smelter.BP_Station_Smelter_C:ProcessingStation_GEN_VARIABLE", "kind": "processing",
             "template": True, "owner_class": "/Game/S/BP_Station_Smelter.BP_Station_Smelter_C",
             "owner_class_name": "BP_Station_Smelter_C", "row": {"table": TABLE_P, "row": "Furnace"},
             "interaction": {"distance": 1, "distance_name": "Medium"}},
            {"path": "/Game/S/BP_Crafting_Cauldron.BP_Crafting_Cauldron_C:CraftingStation_GEN_VARIABLE", "kind": "crafting",
             "template": True, "owner_class": "/Game/S/BP_Crafting_Cauldron.BP_Crafting_Cauldron_C",
             "owner_class_name": "BP_Crafting_Cauldron_C", "row": {"table": TABLE_C, "row": "BrewingCauldron"}},
            {"path": "/Game/S/BP_Station_Cauldron.BP_Station_Cauldron_C:ProcessingStation_GEN_VARIABLE", "kind": "processing",
             "template": True, "owner_class": "/Game/S/BP_Station_Cauldron.BP_Station_Cauldron_C",
             "owner_class_name": "BP_Station_Cauldron_C", "row": {"table": TABLE_P, "row": "BrewingCauldron"}},
        ],
        "tables": [
            {"path": TABLE_P, "kind": "processing", "rows": [
                {"row": "Furnace", "recipes": ["/Game/R/RECIPE_IronBar.RECIPE_IronBar",
                                               "/DR/R/RECIPE_IronBar_Salvage.RECIPE_IronBar_Salvage"],
                 "accepted_fuels": [CHAR], "processing_rate": 5.0},
                {"row": "BrewingCauldron", "recipes": [], "accepted_fuels": [CHAR]},
                {"row": "TestOnlyFuel", "recipes": ["/Game/R/RECIPE_IronBar.RECIPE_IronBar"]},
            ]},
            {"path": TABLE_C, "kind": "crafting", "rows": [
                {"row": "BrewingCauldron", "display_name": "Brewing Cauldron",
                 "labeled": [{"label": "Potions", "recipes": ["/Game/R/RECIPE_Dup"]}]},
            ]},
        ],
        "progression": [
            {"path": "/Game/P/DT_Progression_Core.DT_Progression_Core", "rows": [
                {"row": "T4_Bar_Iron", "query": "ALL ITEMS[ Iron Ore ]", "recipes": ["/Game/R/RECIPE_IronBar.RECIPE_IronBar"]}]},
        ],
        "items": {ORE: {"loaded": True, "name": "Iron Ore", "max_stack": 99},
                  SALV: {"loaded": True, "name": "Iron Salvage Pile", "max_stack": 99},
                  BAR: {"loaded": True, "name": "Iron Bar", "max_stack": 99},
                  CHAR: {"loaded": True, "name": "Charcoal", "max_stack": 99, "fuel_value": 120.0, "class": "FuelItemData"}},
        "players": [{"name": "Zezima", "recipes_unlocked": ["/Game/R/RECIPE_IronBar.RECIPE_IronBar", "RECIPE_Plank"]}],
        "interaction_ranges": {"ranges": {"Short": 250.0, "Medium": 350.0}},
        "errors": [],
    }


@pytest.fixture
def cat(tmp_path):
    d = tmp_path / "raw"
    d.mkdir()
    (d / "01.json").write_text(json.dumps(raw_doc()), encoding="utf-8")
    return br.normalise(br.merge_raw(d), "t")


def test_normalise_recipes_stations_unlocks(cat):
    r = cat["recipes"]["RECIPE_IronBar"]
    assert r["inputs"] == [{"item": "ITEM_IronOre", "path": ORE, "count": 3, "name": "Iron Ore"}]
    assert r["outputs"][0]["item"] == "ITEM_IronBar" and r["outputs"][0]["count"] == 1
    assert r["stations"] == ["Furnace"], "the TestOnlyFuel developer row is excluded"
    assert r["station_kinds"] == ["processing"]
    assert r["craft_quantity_multiplier"] == 1.2
    assert r["unlock"]["bundles"][0]["query"] == "ALL ITEMS[ Iron Ore ]"
    assert r["tools"] == []
    assert cat["recipes"]["RECIPE_IronBar_Salvage"]["inputs"][0]["count"] == 9
    # asset-name clash across mount roots
    assert "RECIPE_Dup@Game" in cat["recipes"] and "RECIPE_Dup@UmS" in cat["recipes"]
    st = cat["stations"]
    assert st["Furnace"]["class_names"] == ["BP_Station_Smelter_C"]
    assert st["Furnace"]["accepted_fuels"] == ["ITEM_Charcoal"] and st["Furnace"]["processing_rate"] == 5.0
    assert st["Furnace"]["interaction"]["range_cm"] == 350.0
    # one row name in two tables = two station types, each with its own class
    assert st["BrewingCauldron"]["kind"] == "crafting" and st["BrewingCauldron"]["class_names"] == ["BP_Crafting_Cauldron_C"]
    assert st["BrewingCauldron@processing"]["class_names"] == ["BP_Station_Cauldron_C"]
    assert st["TestOnlyFuel"]["test"] is True
    assert cat["players"][0]["recipes_unlocked"] == ["RECIPE_IronBar", "RECIPE_Plank"]


def test_lua_data_shape_and_serialiser(cat, tmp_path):
    d = br.lua_data(cat)
    assert d["recipes"]["RECIPE_IronBar"]["inputs"] == [[ORE, 3]]
    assert "TestOnlyFuel" not in d["stations"]
    assert d["stations"]["Furnace"]["fuels"] == [CHAR]
    assert d["items"][CHAR]["fuel"] == 120.0
    assert br.lua('a "q" \\ b\n') == '"a \\"q\\" \\\\ b\\n"'
    assert br.lua({"x": [1, 2.5, True, None], "a-b": "s"}) == '{["a-b"] = "s", x = {1, 2.5, true, nil}}'
    out = br.write_lua(cat, tmp_path / "recipe_data.lua")
    if LUA:
        code = (f"local D = dofile([[{out.as_posix()}]]); assert(D.recipes.RECIPE_IronBar.inputs[1][2] == 3); "
                f"assert(D.stations.Furnace.classes[1] == 'BP_Station_Smelter_C'); print('ok')")
        proc = subprocess.run([LUA, "-e", code], capture_output=True, text=True, timeout=30)
        assert proc.returncode == 0 and "ok" in proc.stdout, proc.stdout + proc.stderr


def test_wiki_check_matches_and_mismatches(cat):
    wiki = [{"facility": "Furnace", "output": "Iron Bar", "output_qty": 1, "materials": {"Iron Ore": 3}},
            {"facility": "Furnace", "output": "Iron Bar", "output_qty": 1, "materials": {"Iron Salvage Pile": 8}},
            {"facility": "Build Menu", "output": "Iron Bar", "output_qty": 1, "materials": {"Iron Ore": 1}}]
    chk = br.wiki_check(cat, wiki)
    assert chk["match"] == 1 and chk["qty_mismatch_count"] == 1
    assert chk["qty_mismatch"][0]["recipe"] == "RECIPE_IronBar_Salvage"


@pytest.mark.skipif(not CATALOG.exists(), reason="no live recipe catalog")
def test_live_catalog_iron_bar_matches_the_wiki():
    """Cross-check from the research doc: Iron Bar = 3 Iron Ore OR 9 Iron Salvage Pile at the Furnace."""
    c = json.loads(CATALOG.read_text(encoding="utf-8"))
    assert c["schema"] == "dw_recipes/1" and c["build"] == "26161880"
    bars = {rid: r for rid, r in c["recipes"].items()
            if [o["name"] for o in r["outputs"]] == ["Iron Bar"] and r.get("stations") == ["Furnace"]}
    got = sorted(tuple((i["name"], i["count"]) for i in r["inputs"]) for r in bars.values())
    assert got == [(("Iron Ore", 3),), (("Iron Salvage Pile", 9),)]
    assert c["stations"]["Furnace"]["kind"] == "processing"
    assert "BP_Station_Smelter_C" in c["stations"]["Furnace"]["class_names"]
    for rid, r in c["recipes"].items():
        for s in r.get("stations") or []:
            assert s in c["stations"], (rid, s)
    assert len(c["recipes"]) > 1000 and c["players"] and len(c["players"][0]["recipes_unlocked"]) > 100


# ------------------------------------------------------------------------------ drift check

PLAN_BAR2 = {"recipe": "RECIPE_IronBar", "crafts": 2, "kind": "processing", "seconds": 4.0,
             "seconds_model": "count*mean(processing_time)/rate",
             "inputs": [{"item": "ITEM_IronOre", "count": 6}], "outputs": [{"item": "ITEM_IronBar", "count": 2}],
             "fuel": {"burn_seconds": 4.0, "options": [{"item": "ITEM_Charcoal", "count": 1, "fuel_value": 120.0}]}}


def processing_events(bars=2, ore_used=6, fuel_used=1, t_out=4000):
    """Luis loads 6 ore + 2 charcoal into a furnace, it burns 1 charcoal, makes 2 bars on the
    ground, he picks them up and takes the leftover charcoal back."""
    ev = [{"kind": "armed", "t": 0},
          {"kind": "player", "t": 10, "counts": {"ITEM_IronOre": 10, "ITEM_Charcoal": 5, "ITEM_Oak": 40}},
          {"kind": "station", "t": 20, "id": "BP_Station_Smelter_C_1", "state": {"inv": {}}},
          {"kind": "player", "t": 500, "counts": {"ITEM_IronOre": 4, "ITEM_Charcoal": 3, "ITEM_Oak": 40}},
          {"kind": "station", "t": 500, "id": "BP_Station_Smelter_C_1",
           "state": {"inv": {"ResourcesInventory": {"ITEM_IronOre": 6}, "FuelInventory": {"ITEM_Charcoal": 2}}}},
          {"kind": "hook", "hook": "toggle", "phase": "pre", "t": 900},
          {"kind": "station", "t": 1000, "id": "BP_Station_Smelter_C_1",
           "state": {"recipe": "RECIPE_IronBar", "running": True,
                     "inv": {"ResourcesInventory": {"ITEM_IronOre": 6}, "FuelInventory": {"ITEM_Charcoal": 2 - fuel_used}}}},
          {"kind": "station", "t": 1000 + t_out, "id": "BP_Station_Smelter_C_1",
           "state": {"recipe": "RECIPE_IronBar", "running": False,
                     "inv": {"ResourcesInventory": {"ITEM_IronOre": 6 - ore_used} if ore_used < 6 else {},
                             "FuelInventory": {"ITEM_Charcoal": 2 - fuel_used},
                             "world_items": {"ITEM_IronBar": bars}}}},
          {"kind": "player", "t": 9000, "counts": {"ITEM_IronOre": 4, "ITEM_Charcoal": 3 + 2 - fuel_used,
                                                    "ITEM_IronBar": bars, "ITEM_Oak": 40}},
          {"kind": "station", "t": 9000, "id": "BP_Station_Smelter_C_1",
           "state": {"recipe": "RECIPE_IronBar", "inv": {"ResourcesInventory": {"ITEM_IronOre": 6 - ore_used} if ore_used < 6 else {}}}},
          ]
    return ev


def test_drift_processing_match():
    real = cd.analyse(processing_events())
    assert real["kind"] == "processing" and real["recipe"] == "RECIPE_IronBar"
    assert real["consumed"] == {"ITEM_IronOre": 6, "ITEM_Charcoal": 1}
    assert real["produced"] == {"ITEM_IronBar": 2}
    assert cd.crafts_from(real, {"outputs": [{"item": "ITEM_IronBar", "count": 1}]}) == 2
    cmp = cd.compare(real, PLAN_BAR2)
    assert cmp["ok"], cmp


def test_drift_processing_mismatch_is_reported():
    real = cd.analyse(processing_events(ore_used=4, fuel_used=2, t_out=20000))
    cmp = cd.compare(real, PLAN_BAR2)
    assert not cmp["ok"]
    whats = {(m["what"], m.get("item") if isinstance(m.get("item"), str) else None) for m in cmp["mismatches"]}
    assert ("input", "ITEM_IronOre") in whats and ("fuel", "ITEM_Charcoal") in whats and ("seconds", None) in whats


def test_drift_crafting_station_uses_the_rpc_count():
    ev = [{"kind": "armed", "t": 0},
          {"kind": "player", "t": 10, "counts": {"ITEM_Log": 5, "ITEM_Hammer": 1}},
          {"kind": "hook", "hook": "craft", "phase": "pre", "t": 1000, "recipe": "RECIPE_Plank", "count": 3,
           "counts": {"ITEM_Log": 5, "ITEM_Hammer": 1}},
          {"kind": "player", "t": 1600, "counts": {"ITEM_Log": 2, "ITEM_Hammer": 1, "ITEM_Plank": 6}}]
    real = cd.analyse(ev)
    assert real["kind"] == "crafting" and real["count"] == 3 and real["seconds_to_last_output"] == 0.6
    plan = {"recipe": "RECIPE_Plank", "crafts": 3, "kind": "crafting", "seconds": 0.72,
            "inputs": [{"item": "ITEM_Log", "count": 3}], "outputs": [{"item": "ITEM_Plank", "count": 6}]}
    assert cd.crafts_from(real, plan) == 3
    assert cd.compare(real, plan)["ok"]
    plan_bad = dict(plan, inputs=[{"item": "ITEM_Log", "count": 4}])
    m = cd.compare(real, plan_bad)["mismatches"]
    assert m == [{"what": "input", "item": "ITEM_Log", "real": 3, "emulated": 4}]


def test_drift_nothing_captured():
    assert cd.analyse([{"kind": "armed", "t": 0}])["captured"] is False


# ------------------------------------------------------------------------------ patch pipeline

def test_patch_pipeline_diffs_recipes(tmp_path):
    from tools import patch_pipeline as pp
    old = {"schema": "dw_recipes/1", "recipes": {"R1": {"inputs": [{"item": "A", "count": 3}]}, "R2": {"inputs": []}}}
    new = {"schema": "dw_recipes/1", "recipes": {"R1": {"inputs": [{"item": "A", "count": 4}]}, "R3": {"inputs": []}}}
    (tmp_path / "recipes_1.json").write_text(json.dumps(old), encoding="utf-8")
    (tmp_path / "recipes_2.json").write_text(json.dumps(new), encoding="utf-8")

    class Ctx:
        data_dir = tmp_path
    res = pp.catalog_diff(Ctx(), "1", "2")
    assert res["recipes"]["added"] == ["R3"] and res["recipes"]["removed"] == ["R2"]
    assert "R1" in res["recipes"]["changed"]
    assert any("craft_drift" in s for s in res["needs_review"])

"""Gather: the tool table in mod/body/resource_profiles.lua matches the item catalog, and the brain's
gather contract (args schema, verifier keyed by the item id the body reports, progress event)."""
import json
import re
from pathlib import Path

from brain.executor import VERIFIERS
from brain.interface import Reason, parse_event, validate_args

ROOT = Path(__file__).resolve().parents[1]


def _lua_tools():
    src = (ROOT / "mod/body/resource_profiles.lua").read_text(encoding="utf-8")
    block = src.split("M.TOOLS = {", 1)[1].split("\n}", 1)[0]
    out = {}
    for m in re.finditer(r'(ITEM_\w+) = \{ category = "(\w+)", tier = (\d+), mult = ([\d.]+) \}', block):
        out[m.group(1)] = (m.group(2), int(m.group(3)), float(m.group(4)))
    return out


def test_tool_table_matches_catalog():
    tools = _lua_tools()
    cat = json.loads((ROOT / "data/items_26161880.json").read_text(encoding="utf-8"))
    items = cat["items"].values() if isinstance(cat["items"], dict) else cat["items"]
    expected = {it["id"]: (it["category"], it["tier"], it["stats"]["damage_multiplier"])
                for it in items if it.get("category") in ("axe", "pickaxe")}
    assert expected, "catalog has no tools"
    assert set(tools) == set(expected)
    for item_id, (category, tier, mult) in expected.items():
        got = tools[item_id]
        assert got[0] == category and got[1] == tier, item_id
        assert abs(got[2] - mult) < 0.05, (item_id, got[2], mult)


def test_gather_args_schema():
    assert validate_args("gather", {"resource": "oak", "count": 4}) == {"resource": "oak", "count": 4, "mode": None, "radius": None}
    assert validate_args("gather", {"resource": "stone", "count": 2, "radius": 50})["radius"] == 50
    assert validate_args("gather", {"resource": "stone", "count": 2, "mode": "chop"})["mode"] == "chop"


def test_gather_reasons_are_deterministic():
    assert Reason.WRONG_TOOL in Reason.DETERMINISTIC
    assert Reason.INVENTORY_FULL in Reason.DETERMINISTIC
    assert Reason.NOTHING_IN_RANGE in Reason.DETERMINISTIC


def test_gather_verifier_counts_the_reported_item_id():
    check = VERIFIERS["gather"]
    base = {"inventory": {}}
    post = {"inventory": {"ITEM_Resources_Wood_Oak": 6}}
    assert check({"resource": "oak", "count": 6}, base, post, {"item": "ITEM_Resources_Wood_Oak"}) is None
    assert check({"resource": "oak", "count": 7}, base, post, {"item": "ITEM_Resources_Wood_Oak"})
    # the mock reports no item: its inventory is keyed by the resource name
    assert check({"resource": "log", "count": 2}, base, {"inventory": {"log": 2}}, {}) is None


def test_gather_progress_event_parses():
    ev = parse_event({"type": "gather_progress", "task_id": "t1", "resource": "oak",
                      "item": "ITEM_Resources_Wood_Oak", "have": 3, "want": 6})
    assert ev.have == 3 and ev.want == 6


def test_craft_verifier_counts_what_the_stay_fed_reflex_used_as_made():
    """Run 20261117-044508: he boiled 3 Clean Water, the stay-fed reflex drank 1 as they came out (the body's result
    said so in "reflex_used"), and the bag check failed the craft: "+2, wanted +3". The failure note took the place
    of the note that names the open request, and he stopped with the quest open. 7 of the 23 craft verification
    failures of 14 to 17 Nov were this."""
    check = VERIFIERS["craft"]
    water = "ITEM_Consumable_Water_Clean"
    used = [{"item": water, "name": "Clean Water", "count": 1}]
    base, post = {"inventory": {water: 0}}, {"inventory": {water: 2}}
    assert check({"item": "Clean Water", "count": 3}, base, post, {"item": water, "reflex_used": used}) is None
    assert check({"item": "Clean Water", "count": 3}, base, post, {"item": water}) == f"inventory {water} +2, wanted +3"
    # what the reflex used of another item is not this craft's output
    other = [{"item": "ITEM_Consumable_Soup_Vegetable", "count": 1}]
    assert check({"item": "Clean Water", "count": 3}, base, post, {"item": water, "reflex_used": other})
    # consume's reflex_used is one row, not a list (skills.lua): never read as a count
    assert check({"item": "Clean Water", "count": 3}, base, post, {"item": water, "reflex_used": {"item": water}})

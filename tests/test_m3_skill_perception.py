"""M3 (every skill trains): what the model can see about HOW each skill is trained, from the real client manifest
and game data (docs/research/2026-10-26-m3-skill-gaps.md). No skill -> tool table anywhere: every assertion reads
skills_progress, which only joins the wiki's in-game line, the recipe catalog and the tool descriptions."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

from brain.director import skills_progress

ROOT = Path(__file__).resolve().parents[1]
FROZEN = json.loads((ROOT / "docs" / "goal_targets.json").read_text(encoding="utf-8"))["every_skill"]["skills_frozen"]


def _lua() -> str | None:
    for c in (os.environ.get("DW_LUA"), r"C:\Program Files\WinGet\Links\lua.exe", shutil.which("lua")):
        if c and Path(c).exists():
            return c
    return None


@pytest.fixture(scope="module")
def body_tools() -> dict[str, str]:
    lua = _lua()
    if not lua:
        pytest.skip("no Lua interpreter")
    with tempfile.TemporaryDirectory() as d:
        out = subprocess.run([lua, str(ROOT / "client_mod/tests/dump_manifest.lua"), d], capture_output=True, text=True,
                             timeout=120)
    assert out.returncode == 0, out.stderr[-2000:]
    m = json.loads(out.stdout)
    return {e["name"]: e.get("description") or "" for e in m["manifest"] if e.get("llm")}


def _rows(body_tools):
    st = {"skills": [{"skill": s, "level": 1, "xp": 0} for s in FROZEN]}
    return {r["skill"]: r for r in skills_progress(st, body_tools)["skills"]}


def test_every_frozen_skill_has_a_visible_route(body_tools):
    """Each skill row names at least one body tool whose description says it trains it, or recipes that award it
    (crafted with the craft tool). A row with neither would leave initiative cases to guesswork."""
    rows = _rows(body_tools)
    assert set(rows) == set(FROZEN)
    blind = [s for s, r in rows.items() if not r["your_tools_naming_it"] and not r["recipes_awarding_xp"]]
    assert blind == [], blind
    assert "craft" in body_tools  # the recipe rows are only a route if the body can craft


def test_gather_description_says_which_profiles_train_what(body_tools):
    d = body_tools["gather"]
    assert "Trains Woodcutting:" in d and "Trains Mining:" in d
    assert "no XP: loose_stones" in d  # verified live 2026-10-26: picking stones up gives no Mining XP
    rows = _rows(body_tools)
    assert "gather" in rows["Woodcutting"]["your_tools_naming_it"]
    assert "gather" in rows["Mining"]["your_tools_naming_it"]


def test_recipe_rows_are_makeable_cheapest_first_with_display_names(body_tools):
    rows = _rows(body_tools)
    for skill in ("Artisan", "Cooking", "Runecrafting", "Construction"):
        recs = rows[skill]["recipes_awarding_xp"]
        assert recs, skill
        for r in recs:
            assert r["at"], (skill, r)  # station-less recipes answer no_station_type: never offered as a route
            assert not str(r["makes"]).startswith(("ITEM_", "DA_")), (skill, r)  # a name, not a raw asset id
            assert r["needs"] and all(" x" in n for n in r["needs"]), (skill, r)
        costs = [sum(int(n.rsplit(" x", 1)[1]) for n in r["needs"]) for r in recs]
        assert costs == sorted(costs), (skill, costs)
    assert any(r["makes"] == "Air Rune" for r in rows["Runecrafting"]["recipes_awarding_xp"])


def test_vendor_recipes_are_flagged():
    """Bought, not crafted: the flag that keeps vendor rows out of the training routes reads the game data."""
    from brain.director import recipes_by_output
    recs = [r for rs in recipes_by_output().values() for r in rs]
    vend = [r for r in recs if r["vendor"]]
    assert vend and all(r["recipe"].startswith("DA_Recipe_Vendor") for r in vend[:50])


def test_gather_mode_reaches_controller_and_director(tmp_path):
    from brain.capabilities import Capabilities
    from brain.director import _arg_list, SYSTEM

    lua = _lua()
    if not lua:
        pytest.skip("no Lua interpreter")
    out = subprocess.run([lua, str(ROOT / "client_mod/tests/dump_manifest.lua"), str(tmp_path)],
                         capture_output=True, text=True, timeout=120)
    assert out.returncode == 0, out.stderr[-2000:]
    rows = json.loads(out.stdout)["manifest"]
    entry = next(row for row in rows if row["name"] == "gather")
    caps = Capabilities(tools=["gather"], source="capabilities", manifest={"gather": entry})
    function = caps.function_schema("gather")["function"]
    assert "mode" in function["parameters"]["properties"]
    assert "not item provenance or observed XP" in function["description"]
    assert caps.validate("gather", {"resource": "x", "count": 1, "mode": "chop"})["mode"] == "chop"
    assert "mode" in _arg_list(entry["args"])
    assert "selects profile" in entry["description"]
    assert "Item possession or gain alone does not establish" in SYSTEM


def test_inventory_only_is_not_evidence_of_operation():
    from brain import predicates as P

    item = "ITEM_Resources_Wood_Ash"
    baseline = {"inventory": {item: 4}, "skills": [{"skill": "Woodcutting", "level": 1, "xp": 206}]}
    pickup = {"inventory": {item: 5}, "skills": [{"skill": "Woodcutting", "level": 1, "xp": 206}]}
    item_gain = P.validate({"gained": {"item": item, "at_least": 1}})
    xp_gain = P.validate({"skill_gain": {"name": "Woodcutting", "xp": 1}})
    assert P.evaluate(item_gain, pickup, {"baseline": baseline}).passed is True
    assert P.evaluate(xp_gain, pickup, {"baseline": baseline}).passed is False
    unknown = {"inventory": {item: 5}, "skills": [{"skill": "Woodcutting", "level": 1}]}
    assert P.evaluate(xp_gain, unknown, {"baseline": baseline}).passed is None

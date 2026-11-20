"""The Planner is shown the place facts the Controller is (L3 2026-11-20, runs 20261120-025333/025934-L3).

"claude, gear up for the vault": the Controller's map_names said "nearest: Crasorak Kara (PL 2, 227 m)"; the Planner's
input had state.places [] and no vault line, its lookup("vault") gave no vault row, so gear_for_vault never came back
and it asked the player "which vault?" and parked. Now its input carries the same places.mentioned lines and, for the
vault the goal names (or the nearest for "the vault"), gear_plan.vault_facts as the lookup card words them.
"""
from __future__ import annotations

import json

import pytest

from brain.jsonl_log import JsonlLogger
from brain.llm import FakeLLM
from brain.places import Places, newest_file
from brain.planner import Planner, _where
from brain.state_store import MOCK_SKILLS, SkillRegistry, Task, TaskTree

L3_HERE = [148.48, 1912.74, -31.85]  # ClaudeDev in Temple Woods (L3 runs): Crasorak Kara's door ~226 m east
L3_STATE = {"position": L3_HERE,
            "gear": {"Head": "ITEM_Armour_T2_Head_Leather", "Body": "ITEM_Armour_T1_Body_Adventurers",
                     "Legs": "ITEM_Armour_T1_Legs_Adventurers"},
            "inventory": {"ITEM_Resources_AnimalHideScraps": 7}, "power_level": 0.0, "places": []}
PLAN = json.dumps({"description": None, "explanation": None, "ask_help": None,
                   "tasks": [{"skill": "stop", "args": {}}]})
needs_map = pytest.mark.skipif(newest_file() is None, reason="no data/places_<build>.json")


def _user(llm: FakeLLM) -> dict:
    text = llm.calls[0]["messages"][1]["content"]
    return json.loads(text.split("\n\n")[0])


def _planner(tmp_path, places) -> tuple[Planner, FakeLLM]:
    llm = FakeLLM([PLAN])
    return Planner(llm, SkillRegistry(MOCK_SKILLS), JsonlLogger(tmp_path / "b.jsonl"), places=places), llm


@needs_map
def test_the_l3_plan_prompt_carries_the_nearest_vault_and_its_armour(tmp_path):
    planner, llm = _planner(tmp_path, Places())
    planner.plan("claude, gear up for the vault", dict(L3_STATE), {})
    user = _user(llm)
    line = next(s for s in user["map_names"] if s.startswith('"vault": the game\'s data has'))
    assert "nearest: Crasorak Kara (a vault in Temple Woods, PL 2, 226 m)" in line  # the Controller's own line
    g, = user["gear_for_vault"]
    assert (g["vault"], g["enemies_pl"], g["you_pl_from_worn_armour"]) == ("Crasorak Kara", 2, 1)
    assert "this vault's PL 2" in g["armour"] and "Reinforced Body/Platelegs" in g["armour"]
    assert "Stab" in g["enemies_weak_to"]
    added = len(json.dumps({k: user[k] for k in ("map_names", "gear_for_vault")}))
    assert added < 2400  # about 1850 characters (~470 tokens) on this state


@needs_map
def test_a_replan_carries_them_too(tmp_path):
    planner, llm = _planner(tmp_path, Places())
    tree = TaskTree(goal="gear up for Crasorak Kara", tasks=[Task(skill="stop", args={})])
    planner.replan(tree, tree.tasks[0], "blocked", dict(L3_STATE), {})
    user = _user(llm)
    assert any(s.startswith("Crasorak Kara (a vault in Temple Woods, PL 2") for s in user["map_names"])
    assert [g["vault"] for g in user["gear_for_vault"]] == ["Crasorak Kara"]


def test_a_goal_naming_no_place_gets_no_extra_block(tmp_path):
    vaults = {"Aa Kara": {"kind": "vault", "name": "Aa Kara", "area": "Temple Woods", "power_level": "3",
                          "map_centre": {"position": [-40.0, 50.0], "accuracy_m": 50}}}
    places = Places({}, vaults=vaults)
    planner, llm = _planner(tmp_path, places)
    planner.plan("chop me two logs", dict(L3_STATE), {})
    user = _user(llm)
    assert "map_names" not in user and "gear_for_vault" not in user
    assert _where(dict(L3_STATE), "gear up for the vault", None) == {}  # no map data: nothing claimed
    # the bare word with map data: the nearest vault's line, and its facts (a gap in the data says so)
    w = _where(dict(L3_STATE), "gear up for the vault", places)
    assert w["map_names"][0].startswith('"vault": the game\'s data has 1 vaults; nearest: Aa Kara')
    assert w["gear_for_vault"][0].get("unavailable") or w["gear_for_vault"][0]["vault"] == "Aa Kara"

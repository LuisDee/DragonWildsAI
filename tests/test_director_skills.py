"""GOAL M3 (every skill gains XP on his own initiative), the Director's side, on GearWorld.

The goal cases m3_<skill>_initiative put him on a fresh character with every skill at 10 except one and an open
"level up whatever needs it" job. What the Director must get right is INFORMATION: its curriculum facts list his
skills lowest first, each with how the game trains it (the wiki skill page's in-game line), the recipes that award
its XP (game data) and his tools whose own description names it (the body manifest), so the model can pick the
lagging skill and a route with tools he has. These tests check those facts for all 12 frozen skills, then run a
stand-in planner over them (``ROUTES`` below is test harness: what a model might plan from the facts, never brain
code) and check on the board that the lagging skill really gains XP. A skill whose tool the body lacks must come
out as a named capability gap, not as progress.
"""
import json
from pathlib import Path

import pytest

from brain import director as D
from brain.knowledge import skill_pages
from brain.llm import LLMResponse
from brain.mock.gear_jobs import PLAYER, JobRig
from brain.mock.gear_world import recipes_data

GOAL = json.loads((Path(__file__).resolve().parents[1] / "docs" / "goal_targets.json").read_text(encoding="utf-8"))
SKILLS = GOAL["every_skill"]["skills_frozen"]
OPEN_LINE = "go level up whatever you think needs it, I'll check back later"


def fresh_skills(rig, target):
    for s in SKILLS:
        rig.game.set_skill(s, 1 if s == target else 10, 0.0 if s == target else 1000.0)


def simplest_recipe(skill):
    """The recipe with the fewest inputs that awards ``skill`` XP at a station (game data)."""
    rows = [(len(r["inputs"]), rid, r) for rid, r in recipes_data()["recipes"].items()
            if r.get("skill") == f"SKILL_{skill}" and r.get("stations") and r.get("inputs") and r.get("xp")
            and not r.get("test")]
    return min(rows, key=lambda x: (x[0], x[1]))[2] if rows else None


def craft_route(skill):
    def setup(rig):
        r = simplest_recipe(skill)
        for i in r["inputs"]:
            rig.game.carry(i["item"], i["count"] * 3)
        rig.game.add_station(r["stations"][0], [4, 0, 0])
    return setup, lambda: [{"tool": "craft", "args": {"item": simplest_recipe(skill)["outputs"][0]["item"],
                                                      "count": 1}}]


def gather_route(item, skill, tool=None):
    def setup(rig):
        if tool:
            rig.game.carry(tool)
            rig.game.equip(tool)
        rig.game.add_resource(item, [8, 0, 0], 30, tool=None, skill=skill, xp=25)
    return setup, lambda: [{"tool": "gather", "args": {"resource": item, "count": 4}}]


def fight_route(weapon):
    def setup(rig):
        if weapon:
            rig.game.carry(weapon)
            rig.game.equip(weapon)
        rig.game.add_creature("Giant Rat", "BP_GiantRat_C", [12, 0, 0], hp=20, power_level=2, drops=[])
    return setup, lambda: [{"tool": "attack", "args": {"target": "Giant Rat_1"}}]


def tool_route(setup_fn, call):
    return setup_fn, lambda: [call]


# Test harness only: what a planner could do for each skill from the facts (wiki line + recipes + tools).
ROUTES = {
    "Agility": tool_route(lambda rig: rig.game.add_course("Chasm Dash", [10, 0, 0]),
                          {"tool": "agility_course", "args": {"course": "Chasm Dash"}}),
    "Artisan": craft_route("Artisan"),
    "Attack": fight_route("ITEM_Sword_Bronze"),
    "Construction": craft_route("Construction"),
    "Cooking": craft_route("Cooking"),
    "Farming": craft_route("Farming"),
    "Fishing": tool_route(lambda rig: rig.game.add_fishing_spot([9, 0, 0], "ITEM_Resources_Fish_Raw_Anchovies"),
                          {"tool": "fish", "args": {"count": 3}}),
    "Magic": fight_route("ITEM_Staff_Ash"),
    "Mining": gather_route("ITEM_Resources_Stone", "Mining"),
    "Ranged": fight_route("ITEM_Shortbow_Oak"),
    "Runecrafting": craft_route("Runecrafting"),
    "Woodcutting": gather_route("ITEM_Resources_Wood_Ash", "Woodcutting"),
}


def curriculum(messages):
    user = json.loads(messages[1]["content"])
    return user.get("decision"), (user.get("curriculum") or {}).get("skills") or [], user


def stand_in_planner(seen):
    """Reads the curriculum facts like a model would: the lowest skill, a route for it, a checkable XP test; a
    lagging skill none of his tools can train is a named gap. Then ends the open job by choice."""
    def respond(messages, tools):
        kind, skills, user = curriculum(messages)
        seen.append({"kind": kind, "skills": skills})
        if user.get("steps_so_far"):
            return LLMResponse(content=json.dumps({"description": "trained the lagging skill", "steps": [],
                                                   "done": True}))
        low = skills[0]
        route = ROUTES[low["skill"]]
        if not (low["your_tools_naming_it"] or low["recipes_total"] or route_tool(route) in user_tools(messages)):
            return LLMResponse(content=json.dumps({
                "description": f"{low['skill']} is lowest but none of my tools trains it", "steps": [],
                "capability_gaps": [{"primitive": f"train {low['skill']}", "kind": "action",
                                     "why": low.get("how") or "no tool or recipe trains it", "workaround": None}],
                "ask_help": f"My {low['skill']} is lowest, but I have no way to train it yet ({low.get('how')})."}))
        return LLMResponse(content=json.dumps({
            "description": f"train {low['skill']} (lowest, level {low['level']})", "explanation": low.get("how"),
            "facts": [], "steps": [{"title": f"train {low['skill']}", "why": low.get("how") or "",
                                    "hints": json.dumps({"do": route[1]()}),
                                    "success": {"skill_gain": {"name": low["skill"], "xp": 1}}}]}))
    return respond


def route_tool(route):
    return route[1]()[0]["tool"]


def user_tools(messages):
    return messages[0]["content"]


@pytest.mark.parametrize("skill", SKILLS)
def test_m3_the_lagging_skill_is_first_with_how_it_trains_and_gains_verified_xp(tmp_path, skill):
    seen = []
    rig = JobRig(tmp_path, [stand_in_planner(seen)] * 6, open_tasks=True)
    fresh_skills(rig, skill)
    ROUTES[skill][0](rig)
    rig.say(OPEN_LINE)
    rig.steps(4)
    first = seen[0]
    assert first["kind"] == "curriculum"
    low = first["skills"][0]
    assert low["skill"] == skill and low["lowest"] and low["level"] == 1
    assert low["how"] == skill_pages()[skill.lower()]["how"]  # the wiki skill page's in-game line
    assert low.get("wiki_training_page") == f"{skill} training"
    assert low["recipes_total"] or low["your_tools_naming_it"] or skill in ("Attack", "Magic", "Ranged", "Mining",
                                                                             "Woodcutting")
    t = rig.task()
    step = t.steps[0]
    assert step.status == "done", (step.failures, rig.trace())
    xp = {s["skill"]: s["xp"] for s in rig.game.get_state()["data"]["skills"]}
    assert xp[skill] > 0  # observed on the body's own skill state, not claimed
    gains = {s: xp[s] - (0.0 if s == skill else 1000.0) for s in SKILLS}
    assert max(gains, key=gains.get) == skill  # the benchmark's xp_top: the lagging skill gained the most


def test_m3_a_lagging_skill_without_a_body_tool_is_a_named_gap_not_fake_progress(tmp_path):
    """Agility with no agility_course tool: no recipe awards Agility XP and no tool names it, so the facts show
    nothing that trains it; the plan names the gap and asks, and no XP is claimed."""
    seen = []
    rig = JobRig(tmp_path, [stand_in_planner(seen)] * 4, open_tasks=True, without=("agility_course",))
    fresh_skills(rig, "Agility")
    rig.say(OPEN_LINE)
    rig.steps(3)
    low = seen[0]["skills"][0]
    assert low["skill"] == "Agility" and low["your_tools_naming_it"] == [] and low["recipes_total"] == 0
    t = rig.task()
    assert t.status == "waiting_help" and not t.steps
    assert "train Agility" in {g["primitive"] for g in rig.director.gaps.backlog()}
    said = " ".join(rig.said())
    assert "Agility" in said  # told the player, through the Controller (single voice)


def test_skills_progress_names_tools_from_the_manifest_text_only():
    state = {"skills": [{"skill": "Fishing", "level": 3, "xp": 10}, {"skill": "Mining", "level": 1, "xp": 0}]}
    rows = D.skills_progress(state, {"fish": "Fish at a spot. Trains Fishing.", "gather": "Harvest a resource."})
    assert [r["skill"] for r in rows["skills"]] == ["Mining", "Fishing"] and rows["skills"][0]["lowest"]
    assert rows["skills"][1]["your_tools_naming_it"] == ["fish"] and rows["skills"][0]["your_tools_naming_it"] == []
    assert rows["skills"][0]["how"].startswith("Mine ore")

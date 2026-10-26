"""The home chest for GOAL mining_run_home_chest, chosen from data on a fresh dev character.

Data (wiki mirror + the build dump, docs/PROGRESS.md 2026-10-26): the Crate (10 Ash Logs, up to 16 slots) is
unlocked from the start; the Small Chest "Ash Chest" (16 Ash Logs + 2 Coarse Thread, up to 32 slots) unlocks with the
Construction perk Creature Comforts, which the game grants at Construction level 16 (SkillPerkData.PerkUnlockInfo:
AssociatedSkill + RequiredSkillLevel; there is no perk-choice call in USkillPerkComponent or USkillsUIAPI). So the
choice is the model's, from what the Director's research returns: buildables (only unlocked pieces, with what he
still lacks) and lookup (capacity). The planner here is a stand-in that reads only those research results.
"""
import json
import re

import pytest

from brain.llm import LLMResponse, ToolCall
from brain.mock.gear_jobs import ASH_LOGS, COPPER, BONE_PICK, FakeKnowledge, JobRig

THREAD = "ITEM_Resources_Thread_Coarse"
WIKI = FakeKnowledge({
    "crate": "The crate is the smallest storage container for up to 16 item slots.",
    "ash chest": "The ash chest is a small storage container for up to 32 item slots. Players can unlock the small "
                 "chest by receiving ash logs in their inventory for the first time and unlocking the skill perk "
                 "Creature Comforts.",
})


def world(rig, construction: int, thread: int):
    g = rig.game
    g.carry(BONE_PICK)
    g.equip(BONE_PICK)
    g.set_skill("Construction", construction)
    if thread:
        g.carry(THREAD, thread)
    g.add_resource(ASH_LOGS, [-6, 0, 0], 60, tool=None, skill="Woodcutting")
    g.add_resource(COPPER, [12, 0, 0], 60, tool="pickaxe", skill="Mining", xp=22)
    g.add_buildable("Crate", {ASH_LOGS: 10}, kind="container", category="Storage")
    g.add_buildable("Ash Chest", {ASH_LOGS: 16, THREAD: 2}, kind="container", category="Storage",
                    unlock={"skill": "Construction", "level": 16})


def stand_in(seen):
    """Research buildables for storage, look each piece up, then pick the roomiest one he can make with what he
    carries plus what he can gather (logs): every number comes from the research results."""
    def respond(messages, tools):
        tool_msgs = [m for m in messages if m.get("role") == "tool"]
        if not tool_msgs:
            return LLMResponse(tool_calls=[ToolCall("buildables", {"about": "storage"}, "b1")])
        rows = (json.loads(tool_msgs[0]["content"]).get("data") or {}).get("pieces") or []
        if len(tool_msgs) == 1:
            return LLMResponse(tool_calls=[ToolCall("lookup", {"query": r["name"]}, f"l{i}") for i, r in enumerate(rows)])
        slots = {}
        for m in tool_msgs[1:]:
            text = json.dumps(json.loads(m["content"]))
            for r in rows:
                if r["name"].lower() in text.lower():
                    n = re.search(r"up to (\d+) item slots", text)
                    slots[r["name"]] = int(n.group(1)) if n else 0
        makeable = [r for r in rows if set(r["missing"]) <= {"Ash Logs"}]  # logs he can chop; nothing else missing
        pick = max(makeable, key=lambda r: slots.get(r["name"], 0))
        seen.append({"offered": [r["name"] for r in rows], "slots": slots, "pick": pick["name"]})
        need = pick["materials"].get("Ash Logs", 0)
        steps = [{"title": f"chop {need} ash logs", "hints": json.dumps({"do": [
                     {"tool": "gather", "args": {"resource": ASH_LOGS, "count": need}}]}),
                  "success": {"gained": {"item": ASH_LOGS, "at_least": need}}},
                 {"title": f"build the {pick['name']}", "hints": json.dumps({"do": [
                     {"tool": "build", "args": {"piece": pick["name"]}}]}),
                  "success": {"structure": {"name": pick["name"], "new": True}}}]
        return LLMResponse(content=json.dumps({
            "description": f"{pick['name']}: the roomiest storage I can make now ({slots.get(pick['name'])} slots)",
            "facts": [], "task_success": {"structure": {"name": pick["name"], "new": True}}, "steps": steps}))
    return respond


@pytest.mark.parametrize("construction,thread,expected", [
    (1, 0, "Crate"),        # fresh: the Ash Chest isn't unlocked (Creature Comforts = Construction 16)
    (16, 2, "Ash Chest"),   # unlocked and he has the thread: 32 slots beat 16
    (16, 0, "Crate"),       # unlocked, but Coarse Thread needs a Spinning Wheel: not makeable from logs alone
])
def test_the_home_chest_is_chosen_from_research_data(tmp_path, construction, thread, expected):
    seen = []
    rig = JobRig(tmp_path, [stand_in(seen)] * 6, knowledge=WIKI)
    world(rig, construction, thread)
    rig.say("set yourself up a proper home with a chest")
    rig.steps(4)
    assert seen and seen[0]["pick"] == expected, seen
    assert ("Ash Chest" in seen[0]["offered"]) == (construction >= 16)  # buildables lists unlocked pieces only
    t = rig.task()
    assert t.status == "done", rig.trace()
    assert any(s["name"] == expected for s in rig.game.get_state()["data"]["structures"])


def test_a_locked_piece_fails_truthfully_if_planned_anyway(tmp_path):
    rig = JobRig(tmp_path, [])
    world(rig, 1, 2)
    rig.game.carry(ASH_LOGS, 16)
    r = rig.game.build("Ash Chest")
    assert not r["ok"] and r["reason"] == "not_unlocked" and "haven't unlocked" in r["data"]["detail"]

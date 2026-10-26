"""GOAL M6 quests, the Director's side, on GearWorld: the Rune Mysteries prerequisite chain
(Getting Started -> Ratcatcher -> Rune Mysteries).

The body reports his quest log (client_mod/scripts/quests.lua: get_state.quests, the current step in the game's
own words). The Director plans each next step from that text plus lookup (who starts a quest, what it requires),
adds a required quest as a prerequisite job, and done is checked from the quest log (quest_step / quest_complete),
never from a claim. The planner below is a stand-in for the model: it reads only the prompt (me.quests, the
lookup result) and a harness table from step text to calls (``STEP_CALLS``, test data, never brain code).
"""
import json
import re

from brain import predicates as P
from brain.llm import LLMResponse, ToolCall
from brain.mock.gear_jobs import FakeKnowledge, JobRig

ASH, STONE = "ITEM_Resources_Wood_Ash", "ITEM_Resources_Stone"
MEAT, ROAST = "ITEM_Resources_Raw_Stringy_Meat", "ITEM_Consumable_Meat_Rat_Roast"
ESSENCE, AIR = "ITEM_Rune_Essence", "ITEM_Rune_Air"

# the wiki's quest infoboxes (data/wiki pages Getting Started / Ratcatcher / Rune Mysteries), as lookup answers
WIKI = FakeKnowledge({
    "rune mysteries": "Quest details: desc=Zanik wants you to learn the basics of crafting runes.; "
                      "start=Speak to Zanik east of Vannaka.; req=Ratcatcher",
    "ratcatcher": "Quest details: desc=Vannaka wants to teach you the basics of hunting.; "
                  "start=Speak to Vannaka south of the Windmill.; req=Getting Started",
    "getting started": "Quest details: desc=Doric wants to teach you some survival basics.; "
                       "start=Speak to Doric outside of the Temple.; req=First Steps",
})

STEP_CALLS = {  # test harness: what a planner would do for each step text
    "Gather 10 Ash Logs and 8 Stones for Doric": [{"tool": "gather", "args": {"resource": ASH, "count": 10}},
                                                   {"tool": "gather", "args": {"resource": STONE, "count": 8}}],
    "Bring the logs and stones to Doric": [{"tool": "talk", "args": {"target": "Doric"}}],
    "Kill giant rats for 4 raw rat meat": [{"tool": "attack", "args": {"target": "Giant Rat_1"}},
                                           {"tool": "attack", "args": {"target": "Giant Rat_2"}}],
    "Cook the rat meat on a campfire": [{"tool": "craft", "args": {"item": ROAST, "count": 2}}],
    "Bring the rat roasts to Vannaka": [{"tool": "talk", "args": {"target": "Vannaka"}}],
    "Craft air runes at the rune altar": [{"tool": "craft", "args": {"item": AIR, "count": 5}}],
    "Show the runes to Zanik": [{"tool": "talk", "args": {"target": "Zanik"}}],
}


def quest_world(rig):
    g = rig.game
    g.carry("ITEM_Sword_Bronze")
    g.equip("ITEM_Sword_Bronze")
    g.carry(ESSENCE, 10)
    g.add_resource(ASH, [-6, 0, 0], 30, tool=None, skill="Woodcutting")
    g.add_resource(STONE, [-8, 3, 0], 30, tool=None, skill="Mining")
    for i in range(2):
        g.add_creature("Giant Rat", "BP_GiantRat_C", [14 + i, 0, 0], hp=20, power_level=2, drops=[(MEAT, 2)])
    g.add_station("Campfire", [3, 3, 0])
    g.add_station("RuneAltar", [5, -4, 0])
    g.add_quest("First Steps", "Hans", [0, 5, 0], [{"text": "Speak to Hans", "talk": "Hans"}])
    g.quest_state["First Steps"] = {"state": "complete", "step": 1}  # done before (the tutorial)
    g.add_quest("Getting Started", "Doric", [2, 6, 0], requires=["First Steps"], steps=[
        {"text": "Gather 10 Ash Logs and 8 Stones for Doric", "have": {ASH: 10, STONE: 8}},
        {"text": "Bring the logs and stones to Doric", "talk": "Doric", "take": {ASH: 10, STONE: 8}}])
    g.add_quest("Ratcatcher", "Vannaka", [4, 6, 0], requires=["Getting Started"], steps=[
        {"text": "Kill giant rats for 4 raw rat meat", "have": {MEAT: 4}, "hint": "Rats live by the windmill."},
        {"text": "Cook the rat meat on a campfire", "have": {ROAST: 2}},
        {"text": "Bring the rat roasts to Vannaka", "talk": "Vannaka", "take": {ROAST: 2}}])
    g.add_quest("Rune Mysteries", "Zanik", [6, 6, 0], requires=["Ratcatcher"], steps=[
        {"text": "Craft air runes at the rune altar", "have": {AIR: 5}},
        {"text": "Show the runes to Zanik", "talk": "Zanik", "take": {AIR: 5}}])


def stand_in(seen):
    def respond(messages, tools):
        user = json.loads(messages[1]["content"])
        name = re.search(r"do the (.+) quest", user["job"]["text"]).group(1)
        log = user["me"].get("quests") or {}
        seen.append({"job": name, "quests": log})
        row = next((a for a in log.get("active") or [] if a["quest"] == name), None)
        out = {"description": f"{name}: next step", "facts": [], "steps": []}
        if not user["job"]["done_when"]:
            out["task_success"] = {"quest_complete": {"name": name}}
        if row is not None:
            out["steps"] = [{"title": f"{name}: {row['step']}", "hints": json.dumps({"do": STEP_CALLS[row["step"]]}),
                             "success": {"quest_step": {"name": name, "advanced": True}}}]
            return LLMResponse(content=json.dumps(out))
        if messages[-1]["role"] != "tool":  # not started: look up who starts it and what it needs
            return LLMResponse(tool_calls=[ToolCall("lookup", {"query": name}, "q1")])
        info = json.dumps(json.loads(messages[-1]["content"]))
        giver = re.search(r"start=Speak to (\w+)", info).group(1)
        req = re.search(r"req=([^;.\"]+)", info).group(1).strip()
        if req not in (log.get("complete") or []):
            out["add_tasks"] = [{"text": f"do the {req} quest", "because": f"{name} requires {req}"}]
        out["steps"] = [{"title": f"start {name}: speak to {giver}", "hints": json.dumps(
            {"do": [{"tool": "talk", "args": {"target": giver}}]}),
            "success": {"quest_step": {"name": name, "advanced": True}}}]
        return LLMResponse(content=json.dumps(out))
    return respond


def test_rune_mysteries_chain_prerequisites_then_each_step_from_the_game_text_verified_by_the_quest_log(tmp_path):
    seen = []
    rig = JobRig(tmp_path, [stand_in(seen)] * 40, knowledge=WIKI)
    quest_world(rig)
    rig.say("do the Rune Mysteries quest")
    rig.steps(30)
    tasks = {t.text: t for t in rig.director.ops.b.tasks}
    rm, rc, gs = (tasks["do the Rune Mysteries quest"], tasks["do the Ratcatcher quest"],
                  tasks["do the Getting Started quest"])
    assert [t.status for t in (gs, rc, rm)] == ["done", "done", "done"], rig.trace()
    assert rc.parent == rm.id and gs.parent == rc.id  # the chain, found from lookup (req=...)
    done = rig.game.get_state()["data"]["quests"]["complete"]
    assert {"Getting Started", "Ratcatcher", "Rune Mysteries"} <= set(done)
    # every step was the game's own current step text, and each was verified by the quest log moving on
    titles = [s.title for t in (gs, rc, rm) for s in t.steps]
    assert "Ratcatcher: Cook the rat meat on a campfire" in titles
    assert all(s.status == "done" for t in (gs, rc, rm) for s in t.steps)
    assert WIKI.queries[:3] == ["Rune Mysteries", "Ratcatcher", "Getting Started"]


def test_a_quest_step_that_does_not_move_the_log_is_not_done(tmp_path):
    """Talking to the giver before the prerequisite is complete changes nothing in the quest log: the step's
    quest_step test stays false, whatever the body or the model says."""
    state = {"quests": {"active": [], "complete": ["First Steps"], "counts": {}}}
    p = P.validate({"quest_step": {"name": "Ratcatcher", "advanced": True}})
    base = P.snapshot(state)
    assert P.evaluate(p, state, {"baseline": base}).passed is False  # not started
    moved = {"quests": {"active": [{"quest": "Ratcatcher", "step": "Kill giant rats for 4 raw rat meat"}],
                        "complete": ["First Steps"]}}
    assert P.evaluate(p, moved, {"baseline": base}).passed is True  # started during the step
    same = P.evaluate(p, moved, {"baseline": P.snapshot(moved)})
    assert same.passed is False and "not moved on" in same.detail
    assert P.evaluate(P.validate({"quest_complete": {"name": "ratcatcher"}}), moved, {}).passed is False
    assert P.evaluate(P.validate({"quest_complete": {"name": "first steps"}}), moved, {}).passed is True
    assert P.evaluate(p, {}, {}).missing == ["quests"]


def test_the_controller_digest_shows_active_quests_in_the_games_words():
    from brain.situation import quests_line
    line = quests_line({"quests": {"active": [{"quest": "Ratcatcher", "step": "Cook the rat meat on a campfire",
                                               "hint": "Use a campfire.", "counters": {"Roasts": 1}}],
                                   "complete": ["First Steps", "Getting Started"]}})
    assert line == "Quests: Ratcatcher: Cook the rat meat on a campfire (hint: Use a campfire.; Roasts 1); 2 done"
    assert quests_line({}) is None

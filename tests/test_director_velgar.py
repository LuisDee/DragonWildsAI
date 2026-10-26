"""GOAL M6 Brynmoor progression up to the Vel'gar capstone: the milestones of docs/design/velgar.md as a curriculum
(data/curricula/velgar.json) that the board verifies from state, planned from data on the mock.

Each milestone is queued as a job whose done test is the milestone's (tools/board.py curriculum). The planner below
is a stand-in for the model: it reads only the job's done test and its research results (craft_plan / compare_gear
from the body, skills, usable things in sight) and turns them into steps; no route is written anywhere. The world
gives him the raw materials each craft tree ends in (harness data: the vault and fight drops are not simulated).
"""
import json
from pathlib import Path

import pytest

from brain import board as B
from brain import predicates as P
from brain.llm import LLMResponse, ToolCall
from brain.mock.gear_jobs import JobRig
from tools.board import curriculum_records

CUR = Path(__file__).resolve().parents[1] / "data" / "curricula" / "velgar.json"
DOC = json.loads(CUR.read_text(encoding="utf-8"))
RUN = ["challenge_horn", "anti_dragon_shield", "lesser_antipoison", "berry_drizzle", "pl4_kit", "sanguine_urns",
       "attack_8"]


def leaves(tree, out):
    """Raw materials (no recipe) a craft tree ends in, and the stations it uses (harness: what the world offers)."""
    if tree.get("status") == "craft":
        out["stations"].add((tree.get("station") or [None])[0])
        for c in tree.get("inputs") or []:
            leaves(c, out)
    else:
        out["items"][tree["item"]] = out["items"].get(tree["item"], 0) + int(tree["need"])
    return out


def kit_items(g):
    """The PL 4 kit the stand-in will pick (the cheapest PL >= 4 crafted piece per slot), for the world setup."""
    from brain.director import compare_gear
    state = g.get_state()["data"]
    picks = []
    for slot in ("head", "body", "legs", "right_hand"):
        opts = [o for o in compare_gear(state, None, slot, 40)["options"]
                if (o.get("power_level") or 0) >= 4 and o.get("recipes")]
        picks.append(min(opts, key=lambda o: (o["power_level"], o["item"]))["item"])
    return picks


def world(rig):
    g = rig.game
    g.carry("ITEM_Sword_Bronze")
    g.equip("ITEM_Sword_Bronze")
    for s in ("Attack", "Artisan", "Cooking", "Magic"):
        g.set_skill(s, 1)
    want = {"ITEM_Masterworks_Challenge_Horn": 1, "ITEM_Masterworks_Shield_Anti_Dragon": 1,
            "ITEM_Consumable_Potion_T2_Lesser_Antipoison": 20, "ITEM_Consumable_BerryDrizzle_Pan-Seared": 20}
    want.update({i: 1 for i in kit_items(g)})
    need = {"items": {}, "stations": set()}
    for item, n in want.items():
        leaves(g.craft_plan(item, n)["data"]["root"], need)
    for item, n in need["items"].items():
        g.carry(item, n)
    for i, st in enumerate(sorted(x for x in need["stations"] if x)):
        g.add_station(st, [3 + i % 5, i // 5, 0])
    g.bag_slots = 400
    for i in range(6):
        g.add_urn([10 + i, 4, 0])
    for i in range(14):
        g.add_creature("Giant Rat", "BP_GiantRat_C", [20 + i, 0, 0], hp=20, power_level=2, drops=[])


def craft_steps(tree, out):
    """Bottom-up craft steps from a craft_plan tree (the body's own planner)."""
    if tree.get("status") != "craft":
        return out
    for c in tree.get("inputs") or []:
        craft_steps(c, out)
    out.append({"title": f"make {tree['need']} {tree.get('name') or tree['item']}",
                "hints": json.dumps({"do": [{"tool": "craft", "args": {"item": tree["item"], "count": tree["need"]}}]}),
                "success": {"have": {"item": tree["item"], "at_least": tree["need"]}}})
    return out


def stand_in(seen):
    def respond(messages, tools):
        user = json.loads(messages[1]["content"])
        test = user["job"]["done_when"] or ""
        me = user["me"]
        tool_msgs = [m for m in messages if m.get("role") == "tool"]
        results = [json.loads(m["content"]) for m in tool_msgs]
        seen.append(test)
        if test.startswith("carry"):  # an item: ask his crafting planner
            if not results:
                item = test.split(" ", 2)[2]
                n = int(test.split(" ")[1])
                return LLMResponse(tool_calls=[ToolCall("craft_plan", {"item": item, "count": n}, "c1")])
            steps = craft_steps(results[0]["data"]["root"], [])
            return LLMResponse(content=json.dumps({"description": "craft it from the planner's tree", "steps": steps}))
        if "power_level >= 4" in test:  # the kit: compare gear per slot, then plan each piece
            slots = ("head", "body", "legs", "right_hand")
            if not results:
                return LLMResponse(tool_calls=[ToolCall("compare_gear", {"slot": s, "limit": 40}, f"g{i}")
                                               for i, s in enumerate(slots)])
            if len(results) == len(slots):
                picks = [min([o for o in r["options"] if (o.get("power_level") or 0) >= 4 and o.get("recipes")],
                             key=lambda o: (o["power_level"], o["item"]))["item"] for r in results]
                return LLMResponse(tool_calls=[ToolCall("craft_plan", {"item": i, "count": 1}, f"p{k}")
                                               for k, i in enumerate(picks)])
            steps = []
            worn = {g.get("item") if isinstance(g, dict) else g for g in (me.get("gear") or {}).values()}
            carried = {c["item"]: c["count"] for c in me.get("carried") or []}
            for r in results[len(slots):]:
                root = r["data"]["root"]
                if root["item"] in worn:
                    continue  # this slot is done
                steps += [s for s in craft_steps(root, []) if carried.get(s["success"]["have"]["item"], 0)
                          < s["success"]["have"]["at_least"]]
                steps.append({"title": f"wear {root['name'] or root['item']}", "hints": json.dumps({"do": [
                    {"tool": "equip", "args": {"item": root["item"]}}]}),
                    "success": {"equipped": {"item": root["item"]}}})
            return LLMResponse(content=json.dumps({"description": "craft and wear a PL 4 kit", "steps": steps[:12]}))
        if test.startswith("max health"):  # urns in sight
            urns = [u for u in me.get("usable_near") or [] if "urn" in str(u.get("name")).lower() and not u.get("used")]
            steps = [{"title": f"use {u['name']} {u['id']}", "hints": json.dumps({"do": [
                {"tool": "interact", "args": {"target": u["id"]}}]}),
                "success": {"vital": {"stat": "health", "max_gain_at_least": 10}}} for u in urns[:5]]
            return LLMResponse(content=json.dumps({"description": "use the urns I can see", "steps": steps}))
        if test.startswith("Attack level"):  # fight what is near: one step per creature in sight
            steps = [{"title": f"fight {c['kind']} {c['id']}", "hints": json.dumps({"do": [
                {"tool": "attack", "args": {"target": c["id"]}}]}), "success": {"skill_gain": {"name": "Attack", "xp": 1}}}
                for c in (me.get("creatures_near") or [])[:8] if c.get("id")]
            return LLMResponse(content=json.dumps({"description": "train Attack on what's near", "steps": steps}))
        return LLMResponse(content=json.dumps({"ask_help": f"I don't know how to work on '{test}' yet."}))
    return respond


def test_every_milestone_is_a_valid_checkable_done_test():
    recs = curriculum_records(CUR)
    assert [r["text"] for r in recs] == [m["text"] for m in DOC["milestones"]]
    state = {"gear": {}, "inventory": {}, "inventory_items": [], "skills": [{"skill": "Attack", "level": 1, "xp": 0},
                                                                            {"skill": "Magic", "level": 1, "xp": 0}],
             "health": 100, "max_health": 100, "quests": {"active": [], "complete": []}}
    for m in DOC["milestones"]:
        p = P.validate(m["success"])
        r = P.evaluate(p, state, {"baseline": P.snapshot(state)})
        assert r.passed is False, (m["id"], r.detail, r.missing)  # checkable from state, and not done yet


def test_the_curriculum_queues_jobs_with_their_done_tests(tmp_path):
    ops = B.BoardOps(B.BoardStore(tmp_path))
    for rec in curriculum_records(CUR, ["attack_8", "challenge_horn"]):
        B.apply_inbox_record(ops, rec)
    t = ops.b.tasks
    assert [x.by for x in t] == ["curriculum:velgar"] * 2 and t[0].success["predicate"] == {
        "skill": {"name": "Attack", "at_least": 8}}
    with pytest.raises(B.BoardError):
        B.apply_inbox_record(ops, {"op": "add", "text": "x", "success": {"nope": {}}})


def test_the_vel_gar_milestones_run_on_the_mock_planned_from_research(tmp_path, monkeypatch):
    import brain.director as D
    monkeypatch.setattr(D, "RESEARCH_ROUNDS", 3)  # the kit needs compare_gear, then craft_plan, then the answer
    seen = []
    rig = JobRig(tmp_path, [stand_in(seen)] * 200)
    rig.director.window.per_hour = 1000  # a long curriculum: the hourly window is not what this test is about
    world(rig)
    for rec in curriculum_records(CUR, RUN):
        B.apply_inbox_record(rig.director.ops, rec)
    rig.steps(60)
    tasks = {t.text: t for t in rig.director.ops.b.tasks}
    status = {m["id"]: tasks[m["text"]].status for m in DOC["milestones"] if m["id"] in RUN}
    assert all(s == "done" for s in status.values()), (status, [(t.text, t.end_reason) for t in tasks.values()])
    st = rig.game.get_state()["data"]
    assert st["max_health"] >= 150 and {s["skill"]: s["level"] for s in st["skills"]}["Attack"] >= 8

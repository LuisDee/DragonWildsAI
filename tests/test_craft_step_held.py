"""A Planner-queued craft is checked against the fresh bag before it is sent (craft misses study 2026-11-19: 11 of
13 craft missing_materials in the counted L2 V1 + L3 runs were queued crafts sent with no model turn between, on what
the kills before them did not drop; run 235356: "craft Leather x4" queued after 3 Kebbit kills, sent with 11 of the 12
Animal Hide Scraps, three times). Short: not sent, the step fails missing_materials with the numbers and goes back to
the Planner like any failed step. Covered: sent as he chose. Facts only: the item and count are never changed."""
import json

from brain.executor import craft_shortfall
from brain.interface import ok
from brain.llm import FakeLLM
from tests.conftest import Rig

SCRAPS = "ITEM_Resources_Skin_Scraps"
LEATHER = "ITEM_Resources_Leather"


def _rig(tmp_path, monkeypatch, scraps: int):
    rig = Rig(tmp_path, max_replans=1)
    rig.game.inventory[SCRAPS] = scraps
    sent = []

    def craft(self, item, count=1):
        sent.append((item, count))
        self.inventory[SCRAPS] -= 3 * count
        self.inventory[LEATHER] += count
        return ok(item=LEATHER, crafted=count)

    def gather(self, resource, count=1):  # a kill that dropped one Animal Hide Scraps
        self.inventory[SCRAPS] += 1
        return ok(item=SCRAPS, resource=SCRAPS, gathered=1)

    monkeypatch.setattr(type(rig.game), "craft", craft)
    monkeypatch.setattr(type(rig.game), "gather", gather)
    return rig, sent


def test_a_short_queued_craft_is_held_with_the_numbers_and_replanned(tmp_path, monkeypatch):
    rig, sent = _rig(tmp_path, monkeypatch, scraps=8)
    rig.planner_llm.push(FakeLLM.plan([{"skill": "gather", "args": {"resource": SCRAPS, "count": 1}},
                                       {"skill": "craft", "args": {"item": "Leather", "count": 4}}]),
                         FakeLLM.plan([{"skill": "craft", "args": {"item": "Leather", "count": 3}}]))
    rig.controller_llm.push(FakeLLM.say(""), FakeLLM.say(""))
    assert rig.agent.run_goal("make 4 leather") == "done"
    assert sent == [("Leather", 3)]  # the x4 never went to the body; the replan's own choice did
    rows = rig.log.read_all()
    held = [r for r in rows if r["kind"] == "craft_step_held"]
    assert len(held) == 1 and held[0]["item"] == "Leather" and held[0]["count"] == 4
    assert held[0]["need"] == {"Animal Hide Scraps": 12} and held[0]["have"] == {"Animal Hide Scraps": 9}
    assert held[0]["can_make"] == 3
    res = [r["result"] for r in rows if r["kind"] == "tool_result" and r["tool"] == "craft"]
    assert res[0]["ok"] is False and res[0]["reason"] == "missing_materials" and res[0]["data"]["held_before_send"]
    assert "held_before_send" not in (res[1].get("data") or {})  # the sent one
    assert not [r for r in rows if r["kind"] == "tool_call" and r["tool"] == "craft" and r["args"].get("count") == 4]
    detail = res[0]["data"]["detail"]
    assert "Leather x4 needs 12 Animal Hide Scraps and you hold 9" in detail, detail
    assert "Animal Hide Scraps 8 -> 9 (+1)" in detail and "you can make 3 Leather" in detail, detail
    # handed back as a failed step is today: the replan sees the reason and the words
    replan = json.dumps(rig.planner_llm.calls[1]["messages"])
    assert "missing_materials" in replan and "you hold 9" in replan, replan


def test_a_covered_queued_craft_is_sent(tmp_path, monkeypatch):
    rig, sent = _rig(tmp_path, monkeypatch, scraps=11)
    rig.planner_llm.push(FakeLLM.plan([{"skill": "gather", "args": {"resource": SCRAPS, "count": 1}},
                                       {"skill": "craft", "args": {"item": "Leather", "count": 4}}]))
    rig.controller_llm.push(FakeLLM.say(""), FakeLLM.say(""))
    assert rig.agent.run_goal("make 4 leather") == "done"
    assert sent == [("Leather", 4)]
    assert not [r for r in rig.log.read_all() if r["kind"] == "craft_step_held"]


def test_his_own_craft_call_is_not_checked(tmp_path, monkeypatch):
    """A craft the model calls in its own turn goes to the body as before (the body answers)."""
    from brain.state_store import Task
    rig, sent = _rig(tmp_path, monkeypatch, scraps=2)
    rig.agent._run_task(Task(skill="craft", args={"item": "Leather", "count": 1}))
    assert sent == [("Leather", 1)]


def test_shortfall_reads_every_recipe_and_skips_unknown_items():
    recipes = {
        "R_hide": {"inputs": [{"item": "H", "name": "Animal Hide", "count": 1}],
                   "outputs": [{"item": "L", "name": "Leather", "count": 1}]},
        "R_scraps": {"inputs": [{"item": "S", "name": "Animal Hide Scraps", "count": 3}],
                     "outputs": [{"item": "L", "name": "Leather", "count": 1}]},
    }
    assert craft_shortfall({"item": "Leather", "count": 2}, {"H": 2}, recipes) is None  # one recipe covered
    s = craft_shortfall({"item": "leather", "count": 4}, {"S": 9}, recipes)
    assert s["recipe"] == "R_scraps" and s["missing"] == [{"item": "S", "name": "Animal Hide Scraps", "need": 12,
                                                          "have": 9}]
    assert s["can_make"] == 3 and s["recipes"] == 2
    assert craft_shortfall({"item": "Leather", "count": 4, "recipe": "R_hide"}, {"S": 99}, recipes)["recipe"] == "R_hide"
    assert craft_shortfall({"item": "Moon Cheese"}, {}, recipes) is None  # the data names no recipe: the body answers

"""A failed craft (missing_materials) carries the same short source facts craft_plan gives for what it lacks
(brain/plan_sources.py ``missing_facts``, the one function both use).

Live 2026-11-18 00:08Z, logs/brain-live-20261118-010135-17424.jsonl (job: 30 copper ore in his chest; copper takes a
Bone pickaxe or better): at 389 s craft Bone Pickaxe failed with "I need 8 Animal Bone for that and I have 4, and 6
Ash Logs and I have 3, and 4 Leather and I have 0" plus where he had cut ash. Nothing said where bones or leather come
from, though Bark to Bones was his to cast and a Tannery is a build-menu piece; he said "the bone pickaxe needs stuff
we don't have. I'll mine the copper with my stone pickaxe instead", left, and a goblin warrior killed him. At 953 s
the same craft failed the same way and the Planner dropped the Bone Pickaxe ("hunting more animals for bone and
leather"). craft_plan on the same items (logs/brain-live-20261118-012330-23088.jsonl, 49 s) names them."""
import copy
import json
from pathlib import Path

from brain import plan_sources as ps
from brain.interface import fail
from brain.llm import FakeLLM
from tests.conftest import Rig

FIX = json.loads((Path(__file__).parent / "fixtures" / "craft_plan_bone_pickaxe_fresh.json").read_text(encoding="utf-8"))
BARK = {"name": "Bark to Bones", "role": "other", "use_when": "Turns a tree into a stack of bones"}
ASH_SPOTS = ("Ash Logs you've gathered before: 5 about 64 m S at (369, 1790), last 00:05Z (2 min ago). Picked spots "
             "regrow: crops have taken over an hour, sticks and stones about 40 min.")
# the logged result at 389 s (row 281), its gathered_before shortened
LOGGED = {"item": "ITEM_Pickaxe_Bone", "recipe": "RECIPE_Pickaxe_Bone", "station": "Crafting Table",
          "detail": "I need 8 Animal Bone for that and I have 4, and 6 Ash Logs and I have 3, and 4 Leather and I have 0. "
                    + ASH_SPOTS,
          "missing": [{"need": 8, "item": "ITEM_Resources_AnimalBone", "have": 4, "name": "Animal Bone"},
                      {"need": 6, "item": "ITEM_Resources_Wood_Ash", "have": 3, "gathered_before": ASH_SPOTS,
                       "name": "Ash Logs"},
                      {"need": 4, "item": "ITEM_Resources_Leather", "have": 0, "name": "Leather"}]}
# his state then (get_state row 284): the parts the facts read
STATE = {"inventory": {"ITEM_Resources_Wood_Ash": 3, "ITEM_Resources_AnimalBone": 4, "ITEM_Resources_Skin_Scraps": 7,
                       "ITEM_Resources_Coarse_Animal_Fur": 7, "ITEM_Pickaxe_Stone": 1, "ITEM_Rune_Earth": 1615,
                       "ITEM_Rune_Nature": 2040},
         "stations_nearby": [{"name": "Campfire", "station": "Campfire", "id": "BP_Station_Campfire_C_1", "distance": 5.6},
                             {"name": "Spinning Wheel", "station": "Spinning Wheel", "id": "BP_SW_1", "distance": 24.0}],
         "recipes_unlocked": ["RECIPE_Pickaxe_Bone", "RECIPE_Process_Leather_From_Hide",
                              "RECIPE_Process_Leather_From_scraps"]}


class KB:
    def node_facts(self, q):
        return None

    def build_facts(self, name):
        if name.lower() != "tannery":
            return None
        return {"title": "Tannery", "skill": "Construction", "url": "u",
                "cost": [("Ash Logs", 12), ("Animal Bone", 4), ("Coarse Thread", 2)],
                "unlock": "Players must collect an animal bone to unlock the tannery."}

    def kinds(self):
        return []


def facts(**kw):
    return ps.missing_facts(copy.deepcopy(LOGGED["missing"]), state=STATE, spells=[BARK], knowledge=KB(), **kw)


def test_bone_names_his_spell_first_and_the_creatures():
    bone = facts()["Animal Bone"]
    assert bone[0].startswith("spell Bark to Bones: cast on a Tree") and "castable now" in bone[0], bone
    assert any(s.startswith("drop: Deer") or s.startswith("drop: Cow") for s in bone), bone


def test_leather_says_where_it_is_made_from_what_he_carries_and_that_the_tannery_is_his_to_build():
    lea = facts()["Leather"]
    made = next(s for s in lea if s.startswith("made at Tannery"))
    assert "1 Animal Hide (you carry 0)" in made and "3 Animal Hide Scraps (you carry 7)" in made, lea
    build = next(s for s in lea if s.startswith("Tannery"))
    assert "none near you" in build and "12 Ash Logs + 4 Animal Bone + 2 Coarse Thread" in build, lea
    # and where the hide itself comes from (craft_plan's sources for Animal Hide): a drop
    assert any(s.startswith("Animal Hide: drop: ") for s in lea), lea


def test_a_thing_he_has_gathered_gets_nothing_more():
    assert "Ash Logs" not in facts()  # its own gathered_before spots already say where


def test_the_same_lines_craft_plan_gives_one_function():
    """The bone lines on the failed craft are the ones craft_plan puts on its Animal Bone obtain step."""
    plan = ps.enrich_result(copy.deepcopy(FIX["result"]), state=STATE, spells=[BARK], knowledge=KB())
    step = next(s for s in plan["data"]["steps"] if s.get("do") == "obtain" and s.get("name") == "Animal Bone")
    assert facts()["Animal Bone"] == step["sources"][:ps.MISSING_PER_ITEM]


def test_bounded():
    got = facts()
    assert all(len(v) <= ps.MISSING_PER_ITEM and all(len(s) <= ps.LINE_CHARS for s in v) for v in got.values())
    line = ps.missing_line(got)
    assert line.startswith("Where the missing things come from: Animal Bone: spell Bark to Bones")
    assert len(line) <= ps.MISSING_CHARS
    assert ps.missing_line({}) is None


def test_on_a_failed_craft_rows_and_detail_carry_it_and_the_log_says_so():
    data = copy.deepcopy(LOGGED)

    class Log:
        rows = []

        def log(self, kind, **kw):
            self.rows.append((kind, kw))

    log = Log()
    line = ps.enrich_craft_failure(data, state=STATE, spells=[BARK], knowledge=KB(), log=log)
    bone = next(m for m in data["missing"] if m["name"] == "Animal Bone")
    assert bone["sources"][0].startswith("spell Bark to Bones")
    assert "sources" not in next(m for m in data["missing"] if m["name"] == "Ash Logs")
    assert line and "Leather: made at Tannery" in line
    assert log.rows == [("craft_sources", {"item": "ITEM_Pickaxe_Bone", "sources": ["Animal Bone", "Leather"],
                                           "chars": len(line)})]
    # anything that is not a missing_materials craft is left as it is
    assert ps.enrich_craft_failure({"detail": "x"}, state=STATE, spells=[], knowledge=KB()) is None


def test_a_planned_craft_that_fails_short_carries_it_to_the_stuck_message(tmp_path, monkeypatch):
    """The 389 s path: a Planner step, its result the stuck event's words the Controller decides on."""
    rig = Rig(tmp_path, max_replans=0)
    rig.controller.knowledge = KB()
    monkeypatch.setattr(rig.controller, "castable_spells", lambda: [BARK])
    monkeypatch.setattr(type(rig.game), "craft", lambda self, item, count=1: fail("missing_materials", **copy.deepcopy(LOGGED)))
    rig.planner_llm.push(FakeLLM.plan([{"skill": "craft", "args": {"item": "Bone Pickaxe", "count": 1}}]))
    rig.controller_llm.push(FakeLLM.say(""), FakeLLM.say(""))
    assert rig.agent.run_goal("make a bone pickaxe") == "stuck"
    detail = rig.store.tree.tasks[0].detail or ""
    assert "Animal Bone: spell Bark to Bones" in detail and "Leather: made at Tannery" in detail, detail
    shown = json.dumps([m for c in rig.controller_llm.calls for m in c["messages"]])
    assert "Bark to Bones: cast on a Tree" in shown
    assert [r["kind"] for r in rig.log.read_all()].count("craft_sources") == 1


def test_every_craft_the_brain_runs_carries_them_in_its_result(rig, monkeypatch):
    """Agent._run_task is the one door for body actions (his own calls and plan steps): the result's missing rows
    carry the sources, which is what his own call's tool message shows."""
    from brain.state_store import Task
    rig.controller.knowledge = KB()
    monkeypatch.setattr(rig.controller, "castable_spells", lambda: [BARK])
    monkeypatch.setattr(type(rig.game), "craft", lambda self, item, count=1: fail("missing_materials", **copy.deepcopy(LOGGED)))
    out = rig.agent._run_task(Task(skill="craft", args={"item": "Bone Pickaxe", "count": 1}))
    bone = next(m for m in out.data["missing"] if m["name"] == "Animal Bone")
    assert not out.ok and bone["sources"][0].startswith("spell Bark to Bones"), out.data

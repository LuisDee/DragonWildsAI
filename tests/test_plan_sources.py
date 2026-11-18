"""craft_plan names the real sources of what it cannot craft and whether a missing station is his to build
(brain/plan_sources.py). Offline check 2026-11-17 23:4xZ of craft_plan Bone Pickaxe from a fresh fork: Animal Bone a
bare obtain though Bark to Bones was his; Animal Hide only from a trader for Garou Chits; the Tannery a bare
find_station. Fixture: the real planner's answer (tests/fixtures/craft_plan_bone_pickaxe_fresh.json)."""
import copy
import json
from pathlib import Path

import pytest

from brain import plan_sources as ps
from brain.knowledge import REPO_ROOT, Knowledge

FIX = json.loads((Path(__file__).parent / "fixtures" / "craft_plan_bone_pickaxe_fresh.json").read_text(encoding="utf-8"))
DB = REPO_ROOT / "data" / "wiki" / "knowledge.sqlite"
needs_wiki = pytest.mark.skipif(not DB.exists(), reason="data/wiki/knowledge.sqlite (gitignored) not here")
BARK = {"name": "Bark to Bones", "role": "other", "use_when": "Turns a tree into a stack of bones"}


class KB:
    """The two knowledge reads plan_sources uses, without the wiki mirror."""

    def node_facts(self, q):
        return None

    def build_facts(self, name):
        if name.lower() != "tannery":
            return None
        return {"title": "Tannery", "skill": "Construction", "url": "u",
                "cost": [("Ash Logs", 12), ("Animal Bone", 4), ("Coarse Thread", 2)],
                "unlock": "Players must collect an animal bone to unlock the tannery."}


def plan():
    return copy.deepcopy(FIX["result"])


def data_of(res):
    return res["data"]


def sources(d, name):
    """The sources of ``name``: on its obtain step, else in the top-level map."""
    st = next((s for s in d["steps"] if s.get("do") == "obtain" and s.get("name") == name and "sources" in s), None)
    return st["sources"] if st else d["sources"][name]


def test_bone_names_bark_to_bones_when_it_is_his():
    res = ps.enrich_result(plan(), state={}, spells=[BARK], knowledge=KB())
    bone = sources(data_of(res), "Animal Bone")
    assert bone[0].lower().startswith("spell bark to bones: cast on a tree") and "castable now" in bone[0], bone
    assert any(s.startswith("drop: Cow") for s in bone) and any(s.startswith("drop: Deer") for s in bone)


def test_bone_spell_not_his_says_so_and_comes_after_a_cow_in_sight():
    st = {"nearby_entities": [{"name": "Cow", "id": "c1", "distance": 12, "alive": True}]}
    bone = sources(data_of(ps.enrich_result(plan(), state=st, spells=[], knowledge=KB())), "Animal Bone")
    assert bone[0].startswith("drop: Cow") and "one in sight" in bone[0], bone
    spell = next(s for s in bone if s.startswith("spell Bark to Bones"))
    assert "not among your spells now; needs Artisan 11" in spell


def test_hide_names_the_creatures_that_drop_it_before_the_trader():
    hide = sources(data_of(ps.enrich_result(plan(), state={}, spells=[], knowledge=KB())), "Animal Hide")
    drops = [s for s in hide if s.startswith("drop: ")]
    assert {s.split(" (")[0] for s in drops} <= {"drop: Cow", "drop: Deer", "drop: Wolf", "drop: Goat", "drop: Ram",
                                                 "drop: Dire Wolf"} and len(drops) >= 2, hide
    trader = [i for i, s in enumerate(hide) if s.startswith("trader ")]
    assert trader and trader[0] > max(hide.index(s) for s in drops), hide  # no chits: the trader after every drop
    assert "Iasadair" in hide[trader[0]] and "you carry 0 Garou Chit" in hide[trader[0]]


def test_drops_are_ordered_by_what_he_can_do_not_by_name():
    st = {"nearby_entities": [{"name": "Wolf", "id": "w1", "distance": 30, "alive": True}]}
    hide = sources(data_of(ps.enrich_result(plan(), state=st, spells=[], knowledge=KB())), "Animal Hide")
    assert hide[0].startswith("drop: Wolf") and "one in sight" in hide[0], hide
    # no one in sight: the easiest creature (lowest power level) that always drops it first, not "Cow" by name
    hide = sources(data_of(ps.enrich_result(plan(), state={}, spells=[], knowledge=KB())), "Animal Hide")
    assert hide[0].startswith("drop: Deer") and "PL 1" in hide[0], hide


def test_trader_first_when_he_carries_the_price():
    st = {"inventory": {"ITEM_Resources_Currency_Chit_Garou": 50}}
    hide = sources(data_of(ps.enrich_result(plan(), state=st, spells=[], knowledge=KB())), "Animal Hide")
    assert hide[0].startswith("trader Iasadair") and "you carry 50 Garou Chit" in hide[0], hide


def test_a_trader_he_cannot_pay_is_one_source_not_the_plan():
    # the logged shape: obtain 24 Garou Chit, find Iasadair, buy 4 Animal Hide, ... (chits he had none of)
    d = data_of(ps.enrich_result(plan(), state={}, spells=[], knowledge=KB()))
    names = [(s["do"], s.get("name")) for s in d["steps"]]
    assert ("obtain", "Garou Chit") not in names and ("find_station", "Iasadair") not in names, names
    assert not any(s.get("recipe") == "DA_Recipe_Vendor_UmS_Buy_Hide_Animal" for s in d["steps"]), names
    hide = next(s for s in d["steps"] if s["do"] == "obtain" and s["name"] == "Animal Hide")
    assert hide["count"] == 4 and hide["sources"][0].startswith("drop: ") and any(x.startswith("trader Iasadair") for x in hide["sources"])
    assert names.index(("obtain", "Animal Hide")) < names.index(("find_station", "Tannery"))  # before the leather it is for
    assert {m["name"] for m in d["missing"]} == {"Animal Bone", "Animal Hide"}
    leather = next(c for c in d["root"]["inputs"] if c["name"] == "Leather")
    node = leather["inputs"][0]
    assert node["status"] == "obtain" and "inputs" not in node and "recipe" not in node
    assert node["alternatives"][0] == {"recipe": "DA_Recipe_Vendor_UmS_Buy_Hide_Animal", "status": "trader", "station": "Iasadair",
                                       "detail": "I haven't unlocked Animal Hide yet (it unlocks with: ALL ITEMS[ Stone ])"}
    assert "sources" not in d  # every source sits on its step


def test_a_trader_he_can_pay_stays_the_plan():
    st = {"inventory": {"ITEM_Resources_Currency_Chit_Garou": 50}}
    d = data_of(ps.enrich_result(plan(), state=st, spells=[], knowledge=KB()))
    assert any(s.get("recipe") == "DA_Recipe_Vendor_UmS_Buy_Hide_Animal" and s["do"] == "craft" for s in d["steps"])
    assert d["sources"]["Animal Hide"][0].startswith("trader Iasadair")


def test_tannery_says_it_is_a_build_menu_piece_with_its_cost():
    st = {"inventory": {"ITEM_Resources_AnimalBone": 4, "ITEM_Resources_Wood_Ash": 1}}
    d = data_of(ps.enrich_result(plan(), state=st, spells=[], knowledge=KB()))
    fs = next(s for s in d["steps"] if s["do"] == "find_station")
    b = fs["build"]
    assert b["piece"] == "Tannery" and "12 Ash Logs + 4 Animal Bone + 2 Coarse Thread" in b["wiki"], b
    assert b["unlocked"] is False and "collect an animal bone" in b["unlock"]
    assert b["you_carry"] == "1 of 12 Ash Logs, 4 of 4 Animal Bone, 0 of 2 Coarse Thread"
    assert "build_unlocked" not in fs


def test_a_build_the_client_read_stays_and_a_trader_gets_none():
    res = plan()
    fs = next(s for s in res["data"]["steps"] if s["do"] == "find_station")
    fs.pop("build_unlocked")
    fs["build"] = {"piece": "Tannery", "cost": "12 Ash Logs + 4 Animal Bone + 2 Coarse Thread", "can_build_now": False}
    res["data"]["steps"].append({"do": "find_station", "station": "UmS_Merchant_Smith", "name": "Beartach",
                                 "recipe": "DA_Recipe_Vendor_UmS_Buy_Wood_Ash", "build_unlocked": False})
    d = data_of(ps.enrich_result(res, state={}, spells=[], knowledge=KB()))
    assert d["steps"][-1] == {"do": "find_station", "station": "UmS_Merchant_Smith", "name": "Beartach",
                              "recipe": "DA_Recipe_Vendor_UmS_Buy_Wood_Ash"}
    assert next(s for s in d["steps"] if s.get("station") == "Tannery" and s["do"] == "find_station")["build"]["can_build_now"] is False


def test_bounded_and_failures_untouched():
    d = data_of(ps.enrich_result(plan(), state={}, spells=[BARK], knowledge=KB()))
    got = {s["name"]: s["sources"] for s in d["steps"] if "sources" in s} | (d.get("sources") or {})
    assert 0 < len(got) <= ps.MAX_ITEMS
    assert all(len(v) <= ps.MAX_PER_ITEM and all(len(s) <= ps.LINE_CHARS for s in v) for v in got.values())
    assert set(got) <= {"Animal Bone", "Animal Hide", "Garou Chit"}  # Ash Logs is gathered: the plan says so
    assert len(json.dumps(got)) < 2000
    assert len(json.dumps(d)) < len(json.dumps(FIX["result"]["data"])) + 2000
    bad = {"ok": False, "reason": "unknown_recipe", "data": {"detail": "x"}}
    assert ps.enrich_result(copy.deepcopy(bad)) == bad


class Log:
    def __init__(self):
        self.rows = []

    def log(self, kind, **kw):
        self.rows.append((kind, kw))


def test_the_log_line_says_what_was_added():
    log = Log()
    ps.enrich_result(plan(), state={}, spells=[BARK], knowledge=KB(), log=log)
    assert log.rows == [("plan_sources", {"sources": ["Animal Bone", "Animal Hide"], "trader_to_obtain": ["Animal Hide"],
                                          "wiki_builds": ["Tannery"], "cards": ["Bone Pickaxe"]})]


def test_the_controller_read_of_craft_plan_carries_them(rig, monkeypatch):
    from brain.controller import Decision
    from brain.llm import ToolCall
    ctl = rig.controller
    ctl.knowledge = KB()
    ctl._state_for_reads = {"spells": [], "inventory": {}}
    monkeypatch.setattr(ctl, "_validate", lambda name, args: args)
    monkeypatch.setattr(ctl, "castable_spells", lambda: [BARK])
    monkeypatch.setattr(ctl.game, "call", lambda name, args: plan() if name == "craft_plan" else {"ok": False})
    res = ctl._read(ToolCall(name="craft_plan", arguments={"item": "Bone Pickaxe"}, id="t1"), Decision())
    bone = sources(res["data"], "Animal Bone")
    assert bone[0].startswith("spell Bark to Bones")
    rows = [json.loads(x) for x in rig.log.path.read_text(encoding="utf-8").splitlines() if x.strip()]
    assert any(r["kind"] == "plan_sources" for r in rows)


@needs_wiki
def test_real_wiki_tannery_build_facts():
    f = Knowledge().build_facts("Tannery")
    assert f["cost"] == [("Ash Logs", 12), ("Animal Bone", 4), ("Coarse Thread", 2)] and f["skill"] == "Construction"
    assert "animal bone" in f["unlock"].lower()
    assert Knowledge().build_facts("Iasadair") is None


# ------------------------------------------------------------------------------ every caller of craft_plan (park study)
# Park study 2026-11-18 (window l2_facts_1118i, run 053839): the Planner's research read craft_plan Bone Pickaxe through
# the raw client call (run_live's BodyProxy) and got "24 Garou Chit, trader Iasadair"; it made a Stone Pickaxe, which
# cannot mine copper. None of three windows had a plan_sources row. Fixture: that read as the client answered it.

LOGGED = json.loads((Path(__file__).parent / "fixtures" / "craft_plan_bone_pickaxe_053839.json").read_text(encoding="utf-8"))


class _Ctl:
    """What plan_sources.body_read takes from the Controller: has, castable spells, knowledge, places."""
    knowledge, places = KB(), None

    def has(self, tool):
        return tool in ("spells", "cast")

    def castable_spells(self):
        return [BARK]


class _Agent:
    def __init__(self, log, answer):
        self.log, self.controller, self.answer = log, _Ctl(), answer
        self.game = self

    def call(self, tool, args):
        return copy.deepcopy(self.answer) if tool == "craft_plan" else {"ok": True, "data": {"tool": tool}}

    def _fresh_state(self, reuse=False):
        return {"inventory": {"ITEM_Resources_AnimalBone": 4}}


def test_the_planners_craft_plan_research_carries_the_sources(tmp_path):
    from brain.jsonl_log import JsonlLogger
    from brain.llm import FakeLLM
    from test_tool_registry import planner, rows as log_rows
    agent = _Agent(JsonlLogger(tmp_path / "brain.jsonl"), LOGGED["result"])
    p, llm, path, _ = planner(tmp_path, FakeLLM.say("", FakeLLM.call("craft_plan", item="Bone Pickaxe")),
                              FakeLLM.plan([{"skill": "gather", "args": {"resource": "ash", "count": 5}}]),
                              body=lambda t, a: ps.body_read(agent, t, a, via="planner"))
    p.plan("mine copper", {}, {})
    got = json.loads(next(m["content"] for m in llm.calls[1]["messages"] if m["role"] == "tool"))
    bone = sources(got["data"], "Animal Bone")
    assert bone[0].startswith("spell Bark to Bones") and "castable now" in bone[0], bone
    hide = sources(got["data"], "Animal Hide")
    assert any(s.startswith("drop: ") for s in hide), hide
    tannery = next(s for s in got["data"]["steps"] if s.get("do") == "find_station" and s.get("name") == "Tannery")
    assert tannery["build"]["cost"]
    row = log_rows(path, "plan_sources")[0]
    assert row["via"] == "planner" and "Animal Bone" in row["sources"]


def test_a_body_read_that_is_not_a_craft_plan_is_the_clients_answer(tmp_path):
    from brain.jsonl_log import JsonlLogger
    agent = _Agent(JsonlLogger(tmp_path / "b.jsonl"), LOGGED["result"])
    assert ps.body_read(agent, "buildables", {}) == {"ok": True, "data": {"tool": "buildables"}}
    failed = {"ok": False, "reason": "ambiguous_target", "data": {"detail": "which one?"}}
    agent.answer = failed
    assert ps.body_read(agent, "craft_plan", {"item": "Pickaxe"}) == failed


def test_the_director_reads_craft_plan_through_the_same_function(monkeypatch):
    from brain.director import AgentPort
    seen = []
    monkeypatch.setattr(ps, "body_read", lambda agent, tool, args, via=None: seen.append((tool, via)) or {"ok": True})
    AgentPort(object(), "Luis").body_read("craft_plan", {"item": "Bone Pickaxe"})
    assert seen == [("craft_plan", "director")]


@needs_wiki
def test_lookup_puts_the_wiki_node_tool_beside_a_gathered_items_game_card():
    """Park study: lookup "copper ore" led with the game card ("buy from Beartach"), no tool, no region; "bone pickaxe
    or better" came only in the 5th (wiki) result."""
    first = Knowledge().lookup("copper ore")["data"]["results"][0]
    assert first["authoritative"] and first["title"] == "Copper Ore"
    node = first["wiki_node"]
    assert node["source"] == "wiki" and "bone pickaxe" in node["tool"].lower() and "Fractured Plains" in node["found_in"]
    crafted = next(r for r in Knowledge().lookup("bone pickaxe")["data"]["results"] if r["authoritative"])
    assert "wiki_node" not in crafted

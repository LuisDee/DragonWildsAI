"""Each craft_plan row carries the item's own game card (tier and description from the item data), and the lookup's game
card for a gathered item carries the tool tier its node needs. Planner stone study 2026-11-18 (runs 053839, 054931):
craft_plan "Pickaxe" listed 8 candidates as {name, status, item} only; the Stone Pickaxe read "missing: []" and the
Bone Pickaxe looked blocked; the only line that said stone can't mine copper was a wiki result ranked below the game
card and called "may be outdated". The Planner made a Stone Pickaxe first 3 of 3. The game's own card says it: "A
primitive pickaxe capable of mining stone and rune essence" (tier 1) against "hard enough to mine Copper and Tin
deposits" (tier 2)."""
import copy
import json
from pathlib import Path

import pytest

from brain import plan_sources as ps
from brain.knowledge import REPO_ROOT, Knowledge

FIXDIR = Path(__file__).parent / "fixtures"
LOGGED = json.loads((FIXDIR / "craft_plan_bone_pickaxe_053839.json").read_text(encoding="utf-8"))
DB = REPO_ROOT / "data" / "wiki" / "knowledge.sqlite"
needs_wiki = pytest.mark.skipif(not DB.exists(), reason="data/wiki/knowledge.sqlite (gitignored) not here")

STONE = "Stone Pickaxe (pickaxe, tier 1): A primitive pickaxe capable of mining stone and rune essence."
BONE = ("Bone Pickaxe (pickaxe, tier 2): A basic mining tool made from tough animal bone. It is hard enough to mine "
        "Copper and Tin deposits.")

# logs/brain-live-20261118-053839-17676.jsonl line 35: the client's answer to craft_plan "Pickaxe" (Planner research)
AMBIGUOUS = {"ok": False, "reason": "ambiguous_target", "id": "547b0382ea2f", "data": {
    "total": 8, "item": "Pickaxe",
    "detail": "\"Pickaxe\" could be several things (8); I can't make any of them right now. Which one do you mean?",
    "candidates": [{"name": "Bone Pickaxe", "status": "missing_input", "item": "ITEM_Pickaxe_Bone"},
                   {"name": "Stone Pickaxe", "status": "missing_input", "item": "ITEM_Pickaxe_Stone"},
                   {"name": "Adamant Pickaxe", "status": "not_unlocked", "item": "ITEM_Pickaxe_Adamant"},
                   {"name": "Bronze Pickaxe", "status": "not_unlocked", "item": "ITEM_Pickaxe_Bronze"},
                   {"name": "Iron Pickaxe", "status": "not_unlocked", "item": "ITEM_Pickaxe_Iron"},
                   {"name": "Mithril Pickaxe", "status": "not_unlocked", "item": "ITEM_Pickaxe_Mithril"},
                   {"name": "Rune Pickaxe", "status": "not_unlocked", "item": "ITEM_Pickaxe_Rune"},
                   {"name": "Steel Pickaxe", "status": "not_unlocked", "item": "ITEM_Pickaxe_Steel"}]}}


class Log:
    def __init__(self):
        self.rows = []

    def log(self, kind, **kw):
        self.rows.append((kind, kw))


def test_item_card_is_the_games_tier_and_description():
    assert ps.item_card("ITEM_Pickaxe_Stone") == STONE
    assert ps.item_card("ITEM_Pickaxe_Bone", "Bone Pickaxe") == BONE
    assert ps.item_card("ITEM_No_Such_Thing") is None


def test_the_planned_item_carries_its_card_next_to_its_name():
    d = ps.enrich_result(copy.deepcopy(LOGGED["result"]), state={})["data"]
    root = d["root"]
    assert root["is"] == BONE
    keys = list(root)
    assert keys.index("is") == keys.index("item") + 1  # read before its inputs (the log row is cut at 2000 chars)
    assert [i["item"] for i in root["inputs"]] == [i["item"] for i in LOGGED["result"]["data"]["root"]["inputs"]]


def test_each_candidate_of_an_ambiguous_name_carries_its_card():
    log = Log()
    res = ps.enrich_result(copy.deepcopy(AMBIGUOUS), state={}, log=log, via="planner")
    assert res["ok"] is False and res["reason"] == "ambiguous_target"
    cands = {c["name"]: c for c in res["data"]["candidates"]}
    assert cands["Stone Pickaxe"]["is"] == STONE and cands["Bone Pickaxe"]["is"] == BONE
    assert cands["Bronze Pickaxe"]["is"].startswith("Bronze Pickaxe (pickaxe, tier 3): ")
    assert list(cands["Stone Pickaxe"]) == ["name", "is", "status", "item"]
    assert log.rows == [("plan_sources", {"sources": [], "trader_to_obtain": [], "wiki_builds": [],
                                          "cards": [c["name"] for c in AMBIGUOUS["data"]["candidates"]],
                                          "via": "planner"})]


def test_other_failures_stay_untouched():
    bad = {"ok": False, "reason": "unknown_recipe", "data": {"detail": "x", "candidates": [{"item": "ITEM_Pickaxe_Stone"}]}}
    assert ps.enrich_result(copy.deepcopy(bad)) == bad


class _Ctl:
    knowledge, places = None, None

    def has(self, tool):
        return False


class _Agent:
    def __init__(self, log, answer):
        self.log, self.controller, self.answer = log, _Ctl(), answer
        self.game = self

    def call(self, tool, args):
        return copy.deepcopy(self.answer)

    def _fresh_state(self, reuse=False):
        return {}


def test_the_planners_research_of_an_ambiguous_name_sees_the_cards(tmp_path):
    from brain.jsonl_log import JsonlLogger
    from brain.llm import FakeLLM
    from test_tool_registry import planner, rows as log_rows
    agent = _Agent(JsonlLogger(tmp_path / "brain.jsonl"), AMBIGUOUS)
    p, llm, path, _ = planner(tmp_path, FakeLLM.say("", FakeLLM.call("craft_plan", item="Pickaxe")),
                              FakeLLM.plan([{"skill": "gather", "args": {"resource": "ash", "count": 5}}]),
                              body=lambda t, a: ps.body_read(agent, t, a, via="planner"))
    p.plan("mine copper", {}, {})
    got = json.loads(next(m["content"] for m in llm.calls[1]["messages"] if m["role"] == "tool"))
    stone = next(c for c in got["data"]["candidates"] if c["name"] == "Stone Pickaxe")
    assert stone["is"] == STONE
    row = log_rows(path, "plan_sources")[0]
    assert row["via"] == "planner" and "Stone Pickaxe" in row["cards"]


def test_the_controller_read_of_an_ambiguous_name_sees_the_cards(rig, monkeypatch):
    from brain.controller import Decision
    from brain.llm import ToolCall
    ctl = rig.controller
    ctl._state_for_reads = {}
    monkeypatch.setattr(ctl, "_validate", lambda name, args: args)
    monkeypatch.setattr(ctl.game, "call", lambda name, args: copy.deepcopy(AMBIGUOUS))
    res = ctl._read(ToolCall(name="craft_plan", arguments={"item": "Pickaxe"}, id="t1"), Decision())
    assert next(c for c in res["data"]["candidates"] if c["name"] == "Stone Pickaxe")["is"] == STONE


# ------------------------------------------------------------------------------ lookup: the node's tool tier


@needs_wiki
def test_copper_cards_tool_is_the_wiki_fact_with_the_games_tier_of_that_tool():
    data = Knowledge().lookup("copper ore")["data"]
    first = data["results"][0]
    assert first["authoritative"] and first["title"] == "Copper Ore"
    node = first["wiki_node"]
    assert node["source"] == "wiki" and "bone pickaxe" in node["tool"].lower()
    assert node["tool_tier"] == "pickaxe tier 2"  # the Bone Pickaxe's own tier in the item data
    assert node["tool_source"] == "wiki, the only source: the game data holds no gate for this node"
    assert "may be outdated" not in json.dumps(node)
    assert "wiki_node" in data["note"] and "only source" in data["note"]


@needs_wiki
def test_a_gate_the_body_reads_on_the_node_is_the_cards_tool():
    """The rock actor's own gate (DamageModifiers RequiredCategory/RequiredTier) in perception wins over the wiki."""
    from brain import tool_registry as tr
    state = {"further_off": [{"name": "Copper Ore", "item": "ITEM_Resources_CopperOre", "tool": "Pickaxe",
                              "tool_tier": 2, "category": "resources", "verb": "mine", "distance": 80.0}]}
    ctx = tr.ReadContext(snap={"state": state}, knowledge=Knowledge())
    first = tr.DECLARED["lookup"].handler(ctx, {"query": "copper ore"})["data"]["results"][0]
    node = first["wiki_node"]
    assert node["tool"] == "Pickaxe tier 2" and node["tool_source"] == "game: the node's own gate, as he saw it"
    assert "tool_tier" not in node and "Fractured Plains" in node["found_in"]


def test_node_gates_from_perception_rows():
    state = {"nearby_resources": [{"name": "Stone Boulder", "drop_item": "ITEM_Resources_Stone", "tool": "Pickaxe",
                                   "tool_tier": 1}],
             "further_off": [{"name": "Rune Essence", "item": "ITEM_Rune_Essence", "tool": "Pickaxe", "tool_tier": 1},
                             {"name": "Ash Tree", "tool": "Hatchet"}]}
    from brain.knowledge import node_gates
    assert node_gates(state) == {"ITEM_Resources_Stone": ("Pickaxe", 1), "ITEM_Rune_Essence": ("Pickaxe", 1)}
    assert node_gates(None) == {}

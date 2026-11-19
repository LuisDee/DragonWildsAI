"""The one tool registry (brain/tool_registry.py): the Controller's view is unchanged, the read-only view is shared.

The golden file holds the Controller's tool lists as the code before the registry built them (commit 858879c), for
a body without a manifest, the live manifest of 2026-11-17 (tests/fixtures/manifest_live_20261117.json) with the
knowledge index and the skill library, and the same with a task board attached. Regenerate it only from that commit:
    python tests/test_tool_registry.py --write
"""
import json
import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from brain.capabilities import Capabilities  # noqa: E402
from brain.controller import Controller  # noqa: E402
from brain.jsonl_log import JsonlLogger  # noqa: E402
from brain.llm import FakeLLM  # noqa: E402
from brain.mock import MockGame  # noqa: E402
from brain.skill_library import SkillLibrary  # noqa: E402
from brain.state_store import StateStore  # noqa: E402

FIXTURES = ROOT / "tests" / "fixtures"
GOLDEN = FIXTURES / "controller_tools_858879c.json"
MANIFEST = json.loads((FIXTURES / "manifest_live_20261117.json").read_text(encoding="utf-8"))["manifest"]


class Kinds:
    def kinds(self):
        return ["item", "recipe", "station", "location"]

    def lookup(self, query, kind=None):
        return {"query": query, "results": [{"title": "Copper Ore", "text": "found in Fractured Plains"}]}


class Board:
    hides_start_goal = True
    read_tool_names = ("board",)
    tool_names = ("board", "add_task")

    def tool_schemas(self):
        return [{"type": "function", "function": {"name": "board", "description": "The task board.",
                                                  "parameters": {"type": "object", "properties": {}}}},
                {"type": "function", "function": {"name": "add_task", "description": "Add a job.",
                                                  "parameters": {"type": "object", "properties": {
                                                      "text": {"type": "string"}}, "required": ["text"]}}}]


def controller_tool_lists(tmp: Path) -> dict:
    out = {}
    old = os.environ.get("DW_SPEECH_CHANNEL")
    try:
        for channel in ("text", "say"):
            os.environ["DW_SPEECH_CHANNEL"] = channel
            log = JsonlLogger(tmp / f"{channel}.jsonl")
            bare = Controller(FakeLLM(), MockGame.default_world(), StateStore(tmp / f"s-{channel}"), log)
            out[f"{channel}/no_manifest"] = bare.tools
            caps = Capabilities(sorted(MANIFEST), "capabilities", manifest=json.loads(json.dumps(MANIFEST)))
            lib = SkillLibrary(tmp / f"skills-{channel}", log)
            live = Controller(FakeLLM(), MockGame.default_world(), StateStore(tmp / f"l-{channel}"), log,
                              caps=caps, skills=lib, knowledge=Kinds())
            out[f"{channel}/live_manifest"] = live.tools
            live.attach_director(Board())
            out[f"{channel}/live_manifest_board"] = live.tools
    finally:
        if old is None:
            os.environ.pop("DW_SPEECH_CHANNEL", None)
        else:
            os.environ["DW_SPEECH_CHANNEL"] = old
    return out


def test_the_controller_tool_lists_are_byte_identical_to_before_the_registry(tmp_path):
    now = controller_tool_lists(tmp_path)
    before = json.loads(GOLDEN.read_text(encoding="utf-8"))
    assert sorted(now) == sorted(before)
    for key in before:
        assert json.dumps(now[key], ensure_ascii=False) == json.dumps(before[key], ensure_ascii=False), key
    assert len(before["say/live_manifest"]) == 52  # the live count of 2026-11-17 (logs ...234028, its prompt row)


# ------------------------------------------------------------------ the read-only view and the Planner's research

from brain.planner import MAX_RESEARCH_CALLS, Planner  # noqa: E402
from brain.state_store import SkillRegistry, Task, TaskTree  # noqa: E402
from brain.tool_registry import (DECLARED, DIRECTOR_READS, PLANNER_READS, BodyProxy,  # noqa: E402
                                 is_read_only, lookup_schema, planner_research)

GATHER = {"skill": "gather", "args": {"resource": "copper_ore", "count": 30}}


def rows(log_path, kind):
    return [r for r in map(json.loads, log_path.read_text(encoding="utf-8").splitlines()) if r.get("kind") == kind]


def planner(tmp_path, *script, facts=None, body=None, serve=True):
    log = JsonlLogger(tmp_path / "brain.jsonl")
    llm = FakeLLM(list(script), model="fake/planner")
    proxy = BodyProxy(body or (lambda t, a: {"ok": True, "data": {"tool": t, "args": a}}), timeout_s=5)
    if serve:
        proxy.serve()  # this thread owns the bridge, as the agent loop does
    research = planner_research(Kinds(), proxy, set(MANIFEST), MANIFEST, facts=(lambda: facts) if facts else None)
    p = Planner(llm, SkillRegistry(["go_to", "gather", "craft"]), log, research=research)
    return p, llm, tmp_path / "brain.jsonl", proxy


def tool_results(call):
    return [json.loads(m["content"]) for m in call["messages"] if m["role"] == "tool"]


def test_every_tool_is_declared_once_with_a_read_only_flag():
    assert all(is_read_only(n) for n in ("lookup", "recall", "food_options", "list_skills"))
    assert not any(is_read_only(n) for n in ("remember", "run_skill", "start_goal", "forget_skill"))
    assert is_read_only("craft_plan", MANIFEST) and is_read_only("buildables", MANIFEST)
    assert not is_read_only("gather", MANIFEST) and not is_read_only("craft", MANIFEST)
    assert all(n in DECLARED and DECLARED[n].read_only or is_read_only(n, MANIFEST) for n in PLANNER_READS)
    assert set(PLANNER_READS) <= set(DIRECTOR_READS)


def test_a_plan_may_look_something_up_first_then_plans(tmp_path):
    p, llm, log, _ = planner(tmp_path, FakeLLM.say("", FakeLLM.call("lookup", query="copper ore")),
                             FakeLLM.plan([GATHER]))
    res = p.plan("thirty copper ore in the chest", {"inventory": []}, {})
    assert [t.skill for t in res.tasks] == ["gather"]
    assert [t["function"]["name"] for t in llm.calls[0]["tools"]] == ["lookup", "craft_plan", "buildables"]
    assert llm.calls[0]["tools"][0] == lookup_schema(Kinds())  # the Controller's own declaration of lookup
    system = llm.calls[0]["messages"][0]["content"]
    assert "Read-only research tools are offered with this request (lookup, craft_plan, buildables)" in system
    assert "Fractured Plains" in json.dumps(tool_results(llm.calls[1]))
    research = rows(log, "planner_research")
    assert [(r["tool"], r["args"]) for r in research] == [("lookup", {"query": "copper ore"})]
    assert research[0]["chars"] > 0
    plan = rows(log, "plan")[-1]
    assert (plan["mode"], plan["research_calls"], plan["research"], plan["requests"], plan["tasks"]) == \
        ("plan", 1, ["lookup"], 2, ["gather"])


def test_research_calls_are_capped_then_the_plan_is_due(tmp_path):
    many = [FakeLLM.call("lookup", query=f"thing {i}") for i in range(MAX_RESEARCH_CALLS + 2)]
    p, llm, log, _ = planner(tmp_path, FakeLLM.say("", *many), FakeLLM.plan([GATHER]))
    assert [t.skill for t in p.plan("copper", {}, {}).tasks] == ["gather"]
    assert len(rows(log, "planner_research")) == MAX_RESEARCH_CALLS
    results = tool_results(llm.calls[1])
    assert len(results) == MAX_RESEARCH_CALLS + 2 and "not run: the limit is 4" in results[-1]["error"]
    assert llm.calls[1]["tool_choice"] == "none"  # no more research once the cap is reached
    plan = rows(log, "plan")[-1]
    assert plan["research_calls"] == MAX_RESEARCH_CALLS and plan["research_refused"] == 2


def test_research_rounds_are_capped_too(tmp_path):
    script = [FakeLLM.say("", FakeLLM.call("lookup", query=f"q{i}")) for i in range(MAX_RESEARCH_CALLS)]
    p, llm, log, _ = planner(tmp_path, *script, FakeLLM.plan([GATHER]))
    p.plan("copper", {}, {})
    assert len(llm.calls) == MAX_RESEARCH_CALLS + 1 and llm.calls[-1]["tool_choice"] == "none"
    assert "Research is over" in llm.calls[-1]["messages"][-1]["content"]


def test_a_research_error_does_not_break_planning(tmp_path):
    def broken(tool, args):
        raise RuntimeError("bridge down")
    p, llm, log, _ = planner(tmp_path, FakeLLM.say("", FakeLLM.call("craft_plan", item="Bone Pickaxe"),
                                                   FakeLLM.call("lookup", query="")),
                             FakeLLM.plan([GATHER]), body=broken)
    assert [t.skill for t in p.plan("copper", {}, {}).tasks] == ["gather"]
    results = tool_results(llm.calls[1])
    assert results[0]["ok"] is False and "bridge down" in json.dumps(results[0])
    assert results[1]["ok"] is False  # an invalid query is answered, not raised
    assert [r["tool"] for r in rows(log, "planner_research")] == ["craft_plan", "lookup"]


def test_a_research_factory_that_fails_plans_without_tools(tmp_path):
    log = JsonlLogger(tmp_path / "brain.jsonl")
    llm = FakeLLM([FakeLLM.plan([GATHER])])
    p = Planner(llm, SkillRegistry(["gather"]), log, research=lambda state: 1 / 0)
    assert [t.skill for t in p.plan("copper", {}, {}).tasks] == ["gather"]
    assert llm.calls[0]["tools"] is None and "research tools" not in llm.calls[0]["messages"][0]["content"]
    assert rows(tmp_path / "brain.jsonl", "planner_research_unavailable")


def test_replan_offers_the_same_research_and_recall_when_facts_exist(tmp_path):
    facts = {"copper ore regions": {"key": "copper ore regions", "value": "Fractured Plains", "source": "wiki"}}
    p, llm, log, _ = planner(tmp_path, FakeLLM.say("", FakeLLM.call("recall", query="copper ore")),
                             FakeLLM.plan([GATHER]), facts=facts)
    failed = Task(skill="gather", args={"resource": "copper_ore", "count": 30})
    p.replan(TaskTree(goal="copper", tasks=[failed]), failed, "found none", {}, {})
    assert [t["function"]["name"] for t in llm.calls[0]["tools"]] == ["lookup", "recall", "craft_plan", "buildables"]
    assert tool_results(llm.calls[1])[0]["facts"][0]["value"] == "Fractured Plains"
    assert rows(log, "plan")[-1]["mode"] == "replan"


def test_without_research_the_planner_is_offered_no_tools(tmp_path):
    llm = FakeLLM([FakeLLM.plan([GATHER])])
    Planner(llm, SkillRegistry(["gather"]), JsonlLogger(tmp_path / "b.jsonl")).plan("copper", {}, {})
    assert llm.calls[0]["tools"] is None and "research" not in llm.calls[0]["messages"][0]["content"]


def test_a_background_plan_reads_the_body_through_the_loop_thread(tmp_path):
    """DW_ASYNC_PLAN (8abcf32) runs plan() on a worker: its body reads queue for the loop, which serves them."""
    import concurrent.futures as cf
    import threading
    served_on = []
    p, llm, log, proxy = planner(tmp_path, FakeLLM.say("", FakeLLM.call("craft_plan", item="Bone Pickaxe")),
                                 FakeLLM.plan([GATHER]),
                                 body=lambda t, a: served_on.append(threading.get_ident()) or {"ok": True, "data": {}})
    with cf.ThreadPoolExecutor(max_workers=1) as pool:
        fut = pool.submit(p.plan, "copper", {"inventory": []}, {})
        while not fut.done():
            proxy.serve()  # the agent loop's pump (Agent.pump: planner_proxy.serve())
            threading.Event().wait(0.01)
        res = fut.result()
    assert [t.skill for t in res.tasks] == ["gather"] and served_on == [threading.get_ident()]
    assert tool_results(llm.calls[1]) == [{"ok": True, "data": {}}]


def test_a_lookup_of_a_vault_carries_its_pl_and_the_armour_he_can_reach_at_it():
    """L3 2026-11-19: the vault's card said "power level 2" and nothing tied it to his armour (cowl PL 2, tunic and
    leggings PL 1); the gear line he had capped at worn top + 1 and he chased a PL 3 bronze set for 30 min."""
    from brain.tool_registry import ReadContext, _lookup
    card = {"source": "bestiary (wiki mirror)", "authoritative": False, "kind": "vault", "title": "Crasorak Kara",
            "text": "Crasorak Kara: dragonkin vault in Temple Woods (Brynmoor), power level 2 [wiki]"}

    class Know:
        def lookup(self, query, kind=None, gates=None):
            return {"ok": True, "data": {"query": query, "results": [card, {"kind": "item", "title": "Vault Shard"}]}}

    state = {"gear": {"Head": "ITEM_Armour_T2_Head_Leather", "Body": "ITEM_Armour_T1_Body_Adventurers",
                      "Legs": "ITEM_Armour_T1_Legs_Adventurers"}, "inventory": {"ITEM_Resources_AnimalHideScraps": 7},
             "power_level": 0.0}
    res = _lookup(ReadContext(snap={"state": state}, knowledge=Know()), {"query": "Crasorak Kara"})
    row, other = res["data"]["results"]
    g = row["gear_for_vault"]
    assert list(row)[:5] == ["source", "authoritative", "kind", "title", "gear_for_vault"]  # within the log's 2000 chars
    assert g["enemies_pl"] == 2 and g["you_pl_from_worn_armour"] == 1 and g["you_pl_game_reads"] == 0.0
    assert "this vault's PL 2" in g["armour"] and "Reinforced Body/Platelegs" in g["armour"] and "short " in g["armour"]
    assert "gear_for_vault" not in card and "gear_for_vault" not in other  # the index's row is not changed; not a vault
    bare = _lookup(ReadContext(snap={}, knowledge=Know()), {"query": "Crasorak Kara"})  # no state: the card alone
    assert "gear_for_vault" not in bare["data"]["results"][0]


if __name__ == "__main__" and "--write" in sys.argv:
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        GOLDEN.write_text(json.dumps(controller_tool_lists(Path(d)), ensure_ascii=False, indent=1), encoding="utf-8")
    print("wrote", GOLDEN)

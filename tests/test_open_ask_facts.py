"""What the game told him about the open ask stays with that ask (brain/open_ask.py keep_fact / facts_view).

Live 2026-11-18 00:08Z, logs/brain-live-20261118-010135-17424.jsonl (ask: "claude, we need thirty copper ore in the
chest at your base"): at 244 s a failed explore for copper, a plan step, carried "Copper Ore Node ... tool: Bone
pickaxe or better (tier 2) ... your best pickaxe: Stone Pickaxe (tier 1), below it". At 389 s, after a thirst detour,
the stuck run's context (row 287) held only the failed craft's words: the Bone Pickaxe needs bones and leather. He
said "I'll mine the copper with my stone pickaxe instead" (replayed with the fact back in his context: 4 of 4 kept
the bone pickaxe; without: 0 of 4). Later (row 567) a run after a fight, no player line, queued "Mine 30 copper ore";
its stuck event (row 692) reached the model with no request at all."""
import copy
import json

from brain import open_ask as oa
from brain.interface import CommandReceived, fail
from brain.llm import FakeLLM
from brain.state_store import Task
from tests.conftest import Rig

ASK = ("Tester", "claude, we need thirty copper ore in the chest at your base")
REGIONS = "Fractured Plains, Stormtouched Highlands, Dowdun Reach"
TIER = "tool: Bone pickaxe or better"
# the live gather result (row 648 shape) and the live craft result (row 281), shortened
GATHER_COPPER = {"radius_m": 90.0, "tool": "Stone Pickaxe", "gathered": 0, "want": 30, "targets": 0,
                 "detail": "I can't find any copper within 90 m of me.", "item": "ITEM_Resources_CopperOre",
                 "why": "no_resource_nearby", "resource": "copper", "total": 0}
CRAFT_BONE = {"item": "ITEM_Pickaxe_Bone", "recipe": "RECIPE_Pickaxe_Bone", "station": "Crafting Table",
              "detail": "I need 8 Animal Bone for that and I have 4, and 6 Ash Logs and I have 3, and 4 Leather and I "
                        "have 0.",
              "missing": [{"need": 8, "item": "ITEM_Resources_AnimalBone", "have": 4, "name": "Animal Bone"},
                          {"need": 4, "item": "ITEM_Resources_Leather", "have": 0, "name": "Leather"}]}


class KB:
    def node_facts(self, q):
        if "copper" in str(q).lower():
            return {"title": "Copper Ore Node", "location": REGIONS, "tool": "Bone pickaxe or better", "url": "u"}
        return None

    def build_facts(self, name):
        return None

    def kinds(self):
        return []


def _ctx(call):
    return json.loads(call["messages"][1]["content"])


def _kinds(rig, kind):
    return [r for r in rig.log.read_all() if r.get("kind") == kind]


def _world(rig, monkeypatch):
    world = type(rig.game)
    monkeypatch.setattr(world, "gather", lambda self, resource, count=1, **k: fail("nothing_in_range",
                                                                                  **copy.deepcopy(GATHER_COPPER)))
    monkeypatch.setattr(world, "craft", lambda self, item, count=1: fail("missing_materials", **copy.deepcopy(CRAFT_BONE)))


# ---------------------------------------------------------------- the store (pure)


def test_kept_newest_first_one_per_subject_bounded_and_not_repeated_beside_its_own_result():
    f = oa.keep_fact([], "node:copper", "explore copper ore", "wiki, Copper Ore Node: 559 m N", t=0.0)
    f = oa.keep_fact(f, "craft:bone", "craft Bone Pickaxe", "I need 8 Animal Bone", t=10.0)
    f = oa.keep_fact(f, "node:copper", "gather copper", "wiki, Copper Ore Node: 463 m N", t=20.0)
    assert [x["key"] for x in f] == ["node:copper", "craft:bone"]  # the newest reading replaced the old one
    view = oa.facts_view(f, now=30.0)
    assert view == ["gather copper, 10 s ago: wiki, Copper Ore Node: 463 m N",
                    "craft Bone Pickaxe, 20 s ago: I need 8 Animal Bone"]
    # a fact already in the step result shown beside it is not shown twice
    assert oa.facts_view(f, exclude="craft failed: I need 8 Animal Bone (more words)", now=30.0) == view[:1]
    big = oa.keep_fact([], "a", "x", "word " * 200)
    big = oa.keep_fact(big, "b", "y", "word " * 200)
    shown = oa.facts_view(big)
    assert sum(map(len, shown)) <= oa.FACTS_CHARS and all(len(s) <= oa.FACT_CHARS for s in shown)
    assert oa.same_ask(ASK, ("Tester", ASK[1][:30])) and not oa.same_ask(ASK, ("Luis", ASK[1]))


# ---------------------------------------------------------------- the 389 s path


def test_a_fact_from_an_early_step_reaches_the_stuck_run_and_the_replan(tmp_path, monkeypatch):
    rig = Rig(tmp_path, max_replans=2)
    rig.controller.knowledge = KB()
    _world(rig, monkeypatch)
    rig.controller_llm.push(FakeLLM.say("on it", FakeLLM.call("start_goal", goal="Gather 30 copper ore")),
                            *[FakeLLM.say("")] * 6)
    rig.planner_llm.push(FakeLLM.plan([{"skill": "gather", "args": {"resource": "copper", "count": 30}}]),
                         FakeLLM.plan([{"skill": "craft", "args": {"item": "Bone Pickaxe", "count": 1}}]),
                         FakeLLM.plan([], ask_help="where is copper I can mine?"))
    rig.game.player_say(ASK[1], player=ASK[0])
    rig.agent.step()

    def user(call):
        return json.loads(call["messages"][-1]["content"].split("\n\n")[0])
    # the replan after the gather: the fact is the failed step's own result there (not repeated in the notes)...
    first = user(rig.planner_llm.calls[1])
    assert TIER in first["failed_task"]["result"] and "open_request" not in first["notes"]
    # ...and the replan after the craft still has it, from the ask, beside the craft's own words
    second = user(rig.planner_llm.calls[2])
    assert second["failed_task"]["skill"] == "craft" and TIER not in second["failed_task"]["result"]
    assert TIER in json.dumps(second["notes"]["open_request"]["known_facts"]), second["notes"].keys()
    # the stuck run: its step result is the craft's; the tier fact from the gather is kept with the ask
    stuck = next(c for c in rig.controller_llm.calls if (_ctx(c).get("body_event") or {}).get("type") == "stuck")
    ev = _ctx(stuck)["body_event"]
    assert ev["request"] == ASK[1] and ev["failed"] == "craft"
    assert any(TIER in s and s.startswith("gather 'copper' nothing_in_range") for s in ev["request_facts"]), ev
    assert not any("I need 8 Animal Bone" in s for s in ev["request_facts"])  # it is in "result" beside
    # the open-ask turn of that run shows them in its block
    block = next(c for c in rig.controller_llm.calls if c["messages"][-1]["content"].startswith("Open request: "))
    shown = json.loads(block["messages"][-1]["content"][len("Open request: "):])
    assert any(TIER in s for s in shown["open_request"]["known_facts"])
    assert _kinds(rig, "request_facts_shown")


def test_a_carried_run_shows_them_on_its_first_turn_and_park_drops_them(tmp_path, monkeypatch):
    rig = Rig(tmp_path)
    rig.controller.knowledge = KB()
    _world(rig, monkeypatch)
    rig.agent._open_request = ASK
    rig.agent._serving_ask = ASK
    rig.agent._run_task(Task(skill="gather", args={"resource": "copper", "count": 30}))
    rig.agent._serving_ask = None
    kept = _kinds(rig, "ask_fact_kept")
    assert [r["request"] for r in kept] == [ASK[1]]
    # a body run with no goal running carries the ask: its first turn shows the facts with the ask's words
    rig.controller_llm.push(FakeLLM.say(""), FakeLLM.say(""),  # the stop, the one STOP_FOR turn, then the open-ask turn
                            FakeLLM.say("", FakeLLM.call("park_request", reason="copper needs a bone pickaxe")))
    rig.agent._command(CommandReceived(player="Tester", text=""), addressed=True,
                       body_events=[{"type": "situation_review", "changes": ["hydration: low"]}])
    first = _ctx(rig.controller_llm.calls[0])
    assert first["open_request"]["words"] == ASK[1] and TIER in first["open_request"]["known_facts"][0]
    # the open-ask turn: parked, and the facts go with the ask
    assert rig.controller_llm.calls[2]["messages"][-1]["content"].startswith("Open request: ")
    assert rig.agent._open_request is None and rig.agent._request_facts() == []
    assert [r["why"] for r in _kinds(rig, "ask_facts_dropped")] == ["park_request"]
    assert rig.controller.open_request is None  # nothing left for the next run


def test_a_run_not_on_the_ask_keeps_nothing_and_a_new_line_drops_them(tmp_path, monkeypatch):
    rig = Rig(tmp_path)
    rig.controller.knowledge = KB()
    _world(rig, monkeypatch)
    rig.agent._open_request = ASK
    rig.agent._run_task(Task(skill="gather", args={"resource": "copper", "count": 30}))  # a run beside a goal
    assert not _kinds(rig, "ask_fact_kept")
    rig.agent._serving_ask = ASK
    rig.agent._run_task(Task(skill="gather", args={"resource": "copper", "count": 30}))
    assert rig.agent._request_facts()
    rig.agent._serving_ask = None
    rig.controller_llm.push(FakeLLM.say("hey"))
    rig.agent._command(CommandReceived(player="Tester", text="never mind, come here"))
    assert rig.agent._request_facts() == [] and "open_request" not in _ctx(rig.controller_llm.calls[0])


def test_next_turns_show_them_only_when_they_changed(rig):
    from brain.controller import Decision
    from brain.llm import ToolCall, assistant_message
    facts = ["gather 'copper' nothing_in_range: wiki, Copper Ore Node: found in X; " + TIER]
    rig.controller.open_request = {"player": ASK[0], "words": ASK[1], "known_facts": facts}
    prior = FakeLLM.say("", ToolCall("consume", {"item": "Clean Water"}, "c1"))
    for shown_before, want in ((facts, False), (None, True)):
        d = Decision(messages=[{"role": "user", "content": "x"}, assistant_message(prior)], facts_shown=shown_before)
        rig.controller_llm.push(FakeLLM.say(""))
        rig.controller.next_turn(d, {"c1": {"ok": True}}, {}, request=ASK)
        obs = rig.controller_llm.calls[-1]["messages"][-2]["content"]
        assert ("open_request_facts" in obs) is want, obs


# ---------------------------------------------------------------- a goal queued with no player line (row 567 / 692)


def test_a_goal_queued_by_a_body_run_on_the_open_ask_carries_the_ask_to_its_stuck_event(tmp_path, monkeypatch):
    rig = Rig(tmp_path, max_replans=0)
    _world(rig, monkeypatch)
    rig.agent._open_request = ASK  # asked earlier; no goal running now
    rig.controller_llm.push(FakeLLM.say("on it", FakeLLM.call("start_goal", goal="Mine 30 copper ore")),
                            *[FakeLLM.say("")] * 4)
    rig.agent._command(CommandReceived(player="Tester", text=""), addressed=True,
                       body_events=[{"type": "activity", "kind": "combat_end", "by": "reflex", "outcome": "killed",
                                     "about": "a fight you fought by reflex when attacked"}])
    assert rig.agent.pending_goal == "Mine 30 copper ore"
    rig.planner_llm.push(FakeLLM.plan([{"skill": "gather", "args": {"resource": "copper", "count": 30}}]))
    assert rig.agent.step() == "stuck"
    stuck = next(c for c in rig.controller_llm.calls if (_ctx(c).get("body_event") or {}).get("type") == "stuck")
    assert _ctx(stuck)["body_event"]["request"] == ASK[1]


# ---------------------------------------------------------------- a parked ask he takes up himself (live 20261118-034204)


def _review(rig):
    rig.agent._command(CommandReceived(player="Tester", text=""), addressed=True,
                       body_events=[{"type": "situation_review", "changes": ["hydration: low"]}])


def _opened(calls):
    return [c for c in calls if c["messages"][-1]["content"].startswith("Open request: ")]


def test_a_parked_ask_he_takes_up_again_is_open_again_and_its_stop_gets_the_one_turn(tmp_path):
    """Run 20261118-024217-L2: parked at 48 s ("Need a spare pickaxe or leather to make a bone pickaxe"); at 64 s a
    review read craft_plan Leather and recipes Bone Pickaxe and gathered ash; later water and food; at 210 s a stop
    with no call, and 12 minutes standing: the parked ask had no open-ask turn."""
    rig = Rig(tmp_path)
    rig.agent._open_request = ASK
    reason = "No pickaxe yet, so I can't mine copper. Need a spare pickaxe or leather to make a bone pickaxe."
    rig.controller_llm.push(FakeLLM.say(""), FakeLLM.say(""),  # the stop, the STOP_FOR turn, then the open-ask turn
                            FakeLLM.say("", FakeLLM.call("park_request", reason=reason)))
    _review(rig)
    assert rig.agent._open_request is None and len(_kinds(rig, "request_parked")) == 1
    # a water run beside it: nothing reopens, no open-ask turn
    n = len(rig.controller_llm.calls)
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("consume", item="water")), FakeLLM.say(""))
    _review(rig)
    assert len(rig.controller_llm.calls) == n + 2 and not rig.controller_llm.script  # a stop and no turn after it
    assert not _kinds(rig, "request_reopened") and rig.agent._open_request is None
    assert not _opened(rig.controller_llm.calls[n:])
    # his inline reads count as much as a body call (live: craft_plan Leather and recipes Bone Pickaxe were reads)
    from brain.controller import Decision
    parked = dict(rig.agent._parked)
    assert rig.agent._reopen_parked(Decision(reads=[{"tool": "recipes", "args": {"item": "Bone Pickaxe"}}])) == ASK
    rig.agent._open_request, rig.agent._parked = None, parked
    before = len(_kinds(rig, "request_reopened"))
    # the 64 s run: a step of his on Leather (a thing the park named), then a stop
    n = len(rig.controller_llm.calls)
    rig.controller_llm.push(FakeLLM.say("hunting hide for leather", FakeLLM.call("gather", resource="leather", count=1)),
                            *[FakeLLM.say("")] * 4)
    _review(rig)
    reopened, = _kinds(rig, "request_reopened")[before:]
    assert reopened["request"] == ASK[1] and reopened["item"] == "Leather" and reopened["tool"] == "gather", reopened
    assert rig.agent._open_request == ASK and _opened(rig.controller_llm.calls[n:])
    # ...and the next run with no goal carries it: the 210 s stop gets its one turn too
    n = len(rig.controller_llm.calls)
    rig.controller_llm.push(*[FakeLLM.say("")] * 4)
    _review(rig)
    assert _opened(rig.controller_llm.calls[n:])

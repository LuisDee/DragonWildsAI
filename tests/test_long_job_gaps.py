"""Negative tests for the long-job gaps (docs/GOAL-2026-11-17-long-jobs.md "Where it stands";
docs/research/2026-11-17-long-jobs-planner-actor.md "The design for this system").

Each test states, as a sentence, what a long job should do, and shows today's code does not. Every gap test is
``xfail(strict=True)``: the suite stays green today, and the day a fix lands the test XPASSes, which fails the run
and tells the fixer to remove the mark. Tests that pass today (the survey was wrong) carry no mark.
The table, what each test accepts as fixed, and which ones belong to the default path:
docs/research/2026-11-17-long-job-gap-tests.md. Offline only: scripted LLMs, the mock game, the Director's fakes.
"""
import json

import pytest

from conftest import Rig
from test_director import ManualExecutor, have, make, step as board_step, ticks, decision, gained, COPPER

from brain import director as D
from brain import gear_plan, needs
from brain.interface import CommandReceived
from brain.llm import FakeLLM
from brain.stash import Stash


def T(skill, **args):
    return {"skill": skill, "args": args}


def _kinds(rig, kind):
    return [r for r in rig.log.read_all() if r.get("kind") == kind]


def _plans(n, *tasks):
    return [FakeLLM.plan(list(tasks)) for _ in range(n)]


# --------------------------------------------------------------------------- 1. a silent turn closes the ask


def test_an_ask_is_not_closed_by_silence_before_one_turn_shows_it_open(tmp_path):
    # fixed by variant C (brain/open_ask.py; docs/research/2026-11-17-open-ask-replay.md): a silent stop no longer
    # closes the ask; one more turn shows it as data with request_done / park_request; a second silent turn leaves it
    # open, logged with after_open_ask_turn (code does not judge his claim: item 6 of the ask-ends note)
    rig = Rig(tmp_path)
    asked = ("Luis", "claude, bring me 3 logs")
    # he claims it and calls nothing, twice (the L5 promise turn, then an empty reply)
    rig.controller_llm.push(FakeLLM.say("Here you go, 3 logs!"), FakeLLM.say(""), FakeLLM.say(""))
    rig.agent._command(CommandReceived(player=asked[0], text=asked[1]))
    assert rig.game.players["Luis"].inventory.get("log", 0) == 0  # the game: nothing was given
    assert not rig.game.calls or all(n != "give" for n, _ in rig.game.calls)
    kinds = [r["kind"] for r in rig.log.read_all() if r["kind"] in ("open_ask_turn", "request_closed",
                                                                     "request_left_open")]
    # not closed by the silence itself, nor by the second silence (2026-11-18): left open, and logged so
    assert kinds == ["open_ask_turn", "request_left_open"]
    assert rig.agent._open_request == asked
    opened, = _kinds(rig, "open_ask_turn")
    assert opened["request"] == asked[1] and opened["shown"]["open_request"]["words"] == asked[1]
    last = rig.controller_llm.calls[-1]
    assert last["messages"][-1]["content"].startswith("Open request: ")
    assert {"request_done", "park_request"} <= {t["function"]["name"] for t in last["tools"]}
    assert _kinds(rig, "request_left_open")[0]["after_open_ask_turn"] is True


# --------------------------------------------------------------------------- 2. a brain restart loses the ask


class _Crash(BaseException):
    """The brain process dies here (not an Exception: nothing in the agent may swallow it)."""


@pytest.mark.xfail(strict=True, reason="gap 2: _open_request, active_goal and pending_goal are memory only "
                                       "(brain/agent.py:184, :524); brain/state_store.py:126-131 loads a task_tree.json "
                                       "nothing resumes")
def test_a_restarted_brain_still_knows_the_open_ask_and_its_goal(tmp_path):
    # brain/state_store.py:131 (_load_tree) feeds nothing in Agent; brain/agent.py:524 holds the ask in memory
    rig = Rig(tmp_path)
    asked = ("Luis", "claude, bring me 2 logs")
    rig.game.player_say(asked[1], player=asked[0])
    rig.controller_llm.push(FakeLLM.say("on it", FakeLLM.call("start_goal", goal="bring Luis 2 logs")),
                            *[FakeLLM.say("")] * 4)
    rig.planner_llm.push(FakeLLM.plan([T("gather", resource="log", count=2), T("go_to", target="Luis"),
                                       T("give", player="Luis", item="log", count=2)]))
    seen = {}

    world = type(rig.game)

    class Dies(world):  # GameInterface.call looks tools up on the class
        def go_to(self, *a, **k):  # the brain dies on the walk back, mid-goal
            seen.update(ask=rig.agent._open_request, goal=rig.agent.active_goal)
            raise _Crash()
    rig.game.__class__ = Dies
    with pytest.raises(_Crash):
        rig.agent.step()  # the ask; start_goal queues the goal and the same step starts it
    assert seen == {"ask": asked, "goal": "bring Luis 2 logs"}  # the old brain had both when it died
    assert rig.game.inventory["log"] == 2  # the step before the crash is real in the world

    # a new brain on the same state folder and the same world; nobody says anything new
    rig.game.__class__ = world
    again = Rig(tmp_path, game=rig.game)
    again.controller_llm.push(*[FakeLLM.say("")] * 6)
    again.planner_llm.push(*_plans(3, T("go_to", target="Luis"), T("give", player="Luis", item="log", count=2)))
    assert again.store.tree is not None and again.store.tree.goal == "bring Luis 2 logs"  # on disk, read back...
    held = (again.agent._open_request, again.agent.active_goal, again.agent.pending_goal)  # ...and not taken up
    for _ in range(3):
        again.agent.step()
    prompts = json.dumps([c["messages"] for c in again.controller_llm.calls + again.planner_llm.calls])
    # fixed: the new brain holds the ask or the goal, or its first model turn names it ("where you were"), or it
    # simply finished the job; any one of these
    assert (any(h for h in held) or asked[1] in prompts or "bring Luis 2 logs" in prompts
            or rig.game.players["Luis"].inventory.get("log", 0) == 2)


# --------------------------------------------------------------------------- 3, 4. death and a full bag end the job


@pytest.mark.parametrize("reason", [
    pytest.param("companion_down", id="death",
                 marks=pytest.mark.xfail(strict=True, reason="gap 3: COMPANION_DOWN is in Reason.DETERMINISTIC "
                                         "(brain/interface.py:93-99): each death spends a re-plan in _run_goal "
                                         "(brain/agent.py:1235-1237); after max_replans=2 the goal is stuck")),
    pytest.param("inventory_full", id="full_bag",
                 marks=pytest.mark.xfail(strict=True, reason="gap 4: INVENTORY_FULL is in Reason.DETERMINISTIC "
                                         "(brain/interface.py:93-99): a re-plan each time, stuck after 2")),
    pytest.param("encumbered", id="over_weight",
                 marks=pytest.mark.xfail(strict=True, reason="gap 4: ENCUMBERED is in Reason.DETERMINISTIC "
                                         "(brain/interface.py:93-99): a re-plan each time, stuck after 2")),
])
def test_a_job_outlives_three_interruptions_of_one_kind(tmp_path, reason):
    # brain/agent.py:1235 (`if tree.replans >= ... self.max_replans: return self._stuck(...)`)
    rig = Rig(tmp_path)
    rig.game.script_failure("gather", reason, times=3)  # three deaths / three full bags; the fourth try works
    rig.planner_llm.push(*_plans(6, T("gather", resource="log", count=3)))
    rig.controller_llm.push(*[FakeLLM.say("")] * 12)  # the actor may be told; he says nothing new
    result = rig.agent.run_goal("gather 3 logs")
    # fixed: none of these alone ends the job as stuck (it is preempted and resumed, or the model parks it)
    assert result != "stuck", (result, rig.store.tree.replans, rig.companion_said())


# --------------------------------------------------------------------------- 5. five fights end the job


@pytest.mark.xfail(strict=True, reason="gap 5: max_interrupts=5 (brain/agent.py:170, :1219-1224): the sixth "
                                       "'attacked' interrupt ends the goal stuck though every fight was won")
def test_a_job_outlives_six_fights_he_won(tmp_path):
    # brain/agent.py:1223 (`if interrupts > self.max_interrupts: return self._stuck(goal, task, "interrupted too often")`)
    rig = Rig(tmp_path)
    rig.game.health = rig.game.max_health = 1000  # the mock has no death: keep his health honest over six bites
    rig.game.script_failure("go_to", "attacked", times=6)  # a wolf on the walk, six times (five passes today)
    rig.planner_llm.push(*_plans(3, T("go_to", target="lake")))
    rig.controller_llm.push(*[FakeLLM.say("")] * 12)
    result = rig.agent.run_goal("go to the lake")
    wolves = [rig.game.entities[c["target"]] for c in rig.calls("attack")]
    assert len(wolves) == 6 and not any(w.alive for w in wolves)  # every fight won by the reflex
    assert result != "stuck", (result, rig.companion_said()[-1:])


# --------------------------------------------------------------------------- 6, 7. his chests


CRATE = "BP_BaseBuilding_Crate_C_2147461755"
CRATE_NEXT_SESSION = "BP_BaseBuilding_Crate_C_2147399120"  # the same crate after a relaunch: a new actor id
CRATE_AT = [103.8, 1857.8, -30.6]


def _stash_with_crate(path, cid=CRATE, contents=("2 Ash Logs", "1 Bronze Shield")):
    s = Stash(path, clock=lambda: 100.0)
    s.observe_state({"structures": [{"id": cid, "name": "Crate", "mine": True, "position": CRATE_AT}]})
    res = {"ok": True, "data": {"container": cid, "container_name": "Crate", "contents": list(contents)}}
    assert s.observe_result("store", {"item": "Ash Logs"}, res)
    return s


def test_containers_remembered_on_the_state_is_a_dict_of_labels(tmp_path):
    # brain/stash.py:62 is the only writer (observe_state), brain/stash.py:96 labels() gives a dict; the record of
    # what type the full-bag options must read (passes today: it pins the fact gap 6 rests on)
    s = _stash_with_crate(tmp_path / "containers.json")
    state = {}
    s.observe_state(state)
    assert isinstance(state["containers_remembered"], dict)
    assert list(state["containers_remembered"]) == ["your Crate at (104,1858)"]


@pytest.mark.xfail(strict=True, reason="gap 6: brain/needs.py:399-401 reads containers_remembered only if it is a "
                                       "list; brain/stash.py:62/:96 always puts a dict there")
def test_the_over_weight_options_name_a_chest_he_remembers(tmp_path):
    # brain/needs.py:400 (`if isinstance(rem, list):`)
    s = _stash_with_crate(tmp_path / "containers.json")
    state = {"bag": {"encumbered": True, "weight": 423, "max_weight": 400}, "inventory_items": []}  # no chest in sight
    s.observe_state(state)  # the real feed: brain/run_live.py hooks the stash onto every state read
    line = next(x for x in needs.lines(state, cat={}) if x.startswith("Need load"))
    assert "Crate" in line and "no chest in sight or remembered" not in line, line


@pytest.mark.xfail(strict=True, reason="gap 7: brain/stash.py keys containers.json by actor id (observe_result, "
                                       ":85-88); the id changes each session, so the remembered crate is never "
                                       "tied to the one in sight")
def test_a_remembered_chest_is_known_by_its_new_id_after_a_relaunch(tmp_path):
    # brain/stash.py:85 (`self._seen[str(cid)] = ...`), brain/stash.py:61 (_where by id only)
    _stash_with_crate(tmp_path / "containers.json")
    again = Stash(tmp_path / "containers.json")  # a new session: the same crate, same place, a new actor id
    state = {"structures": [{"id": CRATE_NEXT_SESSION, "name": "Crate", "mine": True, "position": CRATE_AT}]}
    again.observe_state(state)
    # fixed: what he remembers of that crate is reachable by the id he can store/take with now (on the state's
    # remembered entry, or in the stash's own record under that id)
    assert CRATE_NEXT_SESSION in json.dumps(state["containers_remembered"]) or CRATE_NEXT_SESSION in again.snapshot()


@pytest.mark.xfail(strict=True, reason="gap 7: brain/stash.py:85-88 records the same crate twice under two session "
                                       "ids; labels() (:96-107) merges both rows, so an item taken out stays listed")
def test_an_item_taken_from_a_chest_after_a_relaunch_is_no_longer_listed_in_it(tmp_path):
    # brain/stash.py:107 (`out.setdefault(label, []).extend(...)` over both ids' rows)
    _stash_with_crate(tmp_path / "containers.json")
    again = Stash(tmp_path / "containers.json", clock=lambda: 200.0)
    again.observe_state({"structures": [{"id": CRATE_NEXT_SESSION, "name": "Crate", "mine": True, "position": CRATE_AT}]})
    res = {"ok": True, "data": {"container": CRATE_NEXT_SESSION, "container_name": "Crate", "contents": ["2 Ash Logs"]}}
    assert again.observe_result("take", {"item": "Bronze Shield"}, res)
    items = [i for v in again.labels().values() for i in v]
    assert "ITEM_Shield_Bronze" not in items, again.labels()


# --------------------------------------------------------------------------- 8. what the Controller can read


@pytest.mark.xfail(strict=True, reason="gap 8 (a design decision, not a bug): the Controller's brain tools are "
                                       "lookup/remember/run_skill/start_goal (brain/controller.py:487-501, plus "
                                       "the board's BOARD_TOOLS); map_memory and compare_gear are the Director "
                                       "worker's RESEARCH_TOOLS only (brain/director.py:514-519, :583-592)")
def test_the_controller_can_read_his_memory_of_places_and_compare_gear(tmp_path):
    # brain/controller.py:489 (_schemas: the brain tools offered to the Controller)
    offered = set(Rig(tmp_path).controller.offered())
    offered |= {t["function"]["name"] for t in D.BOARD_TOOLS}  # what a Director adds to his list (tool_schemas)
    assert {"map_memory", "compare_gear"} <= offered, sorted(offered)


# --------------------------------------------------------------------------- 9. gear: chests and roofs


@pytest.mark.xfail(strict=True, reason="gap 9: brain/director.py:621-648 compare_gear reads held and carried items "
                                       "only (predicates._held_or_carried); containers_remembered is not read")
def test_compare_gear_counts_a_shield_in_his_chest_as_his(tmp_path):
    # brain/director.py:625 (`have = P._held_or_carried(state)`)
    s = _stash_with_crate(tmp_path / "containers.json")
    state = {"inventory": {}, "gear": {}, "inventory_items": []}
    s.observe_state(state)
    out = D.compare_gear(state, "shield", None)
    # fixed: the result says he has one and where (any shape that names the chest)
    assert "Crate" in json.dumps(out), out


def _gear_state(**kw):  # tests/test_gear_plan.py's _state: T1 body + legs, hide and bone carried, cows about
    st = {"gear": {"Body": "ITEM_Armour_T1_Body_Adventurers", "Legs": "ITEM_Armour_T1_Legs_Adventurers",
                   "HeldRight": "ITEM_Club_Stone"},
          "inventory": {"ITEM_Resources_AnimalBone": 4, "ITEM_Resources_AnimalHide": 4},
          "recipes_unlocked": ["RECIPE_Weapon_Club_Stone"],
          "nearby_entities": [{"name": "Cow", "power_level": 2, "alive": True}]}
    st.update(kw)
    return st


def test_the_gear_plan_names_the_roof_a_spinning_wheel_needs():
    # the survey's gap 9b as written ("gear_plan.plan ignores that a station works only under a roof") is wrong:
    # brain/gear_plan.py:62-66 (_at) adds data/station_rules.json's "needs a roof" to every route through a wheel,
    # and sets() (:338-348) puts a set whose shortfall needs a ruled station after one that does not
    st = _gear_state()
    p = gear_plan.plan(st)
    light = next(s for s in gear_plan.sets(p, st) if s["style"] == "light")
    ways = [w for x in light["short"] for w in x["ways"]]
    assert any("Spinning Wheel (needs a roof)" in w for w in ways), ways
    assert "needs a roof" in (gear_plan.set_line(p, st) or "")


@pytest.mark.xfail(strict=True, reason="gap 9 (narrower than surveyed): brain/gear_plan.py:166-225 plan() and "
                                       "set_line() never read the live roof state (state.my_bases[].covered, "
                                       "crafting.lua:801-826 W.shelter covered); a roofed and an open-sky wheel "
                                       "give the same plan")
def test_the_gear_plan_tells_a_roofed_wheel_from_one_under_open_sky():
    # brain/gear_plan.py:166 (plan: no read of my_bases / a station's shelter state)
    def base(covered):
        return [{"centre": [100.0, 1850.0], "distance_m": 12.0, "direction": "N", "covered": covered, "pieces": 6,
                 "stations": ["Spinning Wheel"]}]
    open_sky, roofed = _gear_state(my_bases=base(False)), _gear_state(my_bases=base(True))
    a, b = gear_plan.plan(open_sky), gear_plan.plan(roofed)
    texts = [(json.dumps(gear_plan.sets(p, st), sort_keys=True) + (gear_plan.set_line(p, st) or ""))
             for p, st in ((a, open_sky), (b, roofed))]
    assert texts[0] != texts[1]


# --------------------------------------------------------------------------- 10. the board waits while Sonnet thinks


@pytest.mark.xfail(strict=True, reason="gap 10: brain/director.py:1144 `_transition` returns False while "
                                       "self._future is not None: no step run reaches the Controller while a "
                                       "decision is pending")
def test_the_actor_gets_a_run_on_the_ask_while_its_plan_is_composed(tmp_path):
    # brain/director.py:1144 (`if task is None or self._future is not None: return False`)
    ex = ManualExecutor()  # the decision stays pending until finish()
    d, port, world, llm, clock = make(tmp_path, None, [
        decision(task_success=have(COPPER, 5), steps=[board_step("mine copper", gained(COPPER, 5))])], executor=ex)
    t = d.handle_tool("add_task", {"text": "mine some copper", "when": "now"}, "Zezima")["data"]
    for _ in range(3):
        ticks(d, 1)
        clock.t += 5.0  # 15 s of Sonnet thinking
    assert d._future is not None and not d._future.done()  # still composing
    runs = [e for e in port.events if e.get("type") != "board_notice"]
    # fixed: some run that carries the ask reached the actor (the shape of the event is the fixer's)
    assert any("mine some copper" in json.dumps(e) for e in runs), port.events
    assert d.ops.b.task(t["id"]).status != "done"

"""The no-progress breaker (brain/progress.py): what a turn changed, the same failure without progress said
plainly the 2nd time, parked the 3rd; the Director retries a busy/timeout run once instead of replanning."""
import json

from conftest import Rig
from brain.llm import FakeLLM
from brain.progress import RepeatWatch, change

S0 = {"position": [0, 0, 0], "health": 100, "inventory": {"ITEM_Log": 2}}


def test_change_says_moved_hp_and_items():
    after = {"position": [3, 4, 0], "health": 70, "inventory": {"ITEM_Log": 5, "ITEM_Water": 0}}
    assert change(S0, after) == "moved 5.0 m; HP -30; +3 Log"
    assert change(S0, S0) == "moved 0.0 m; inventory unchanged"
    assert change(S0, {"unavailable": "x"}) is None


def test_second_identical_failure_is_said_and_third_parks_once():
    w = RepeatWatch()
    args = {"target": [12.3, 34.4, 56.0]}
    assert w.note("go_to", args, "path_blocked", S0) == 1
    assert w.verdict("go_to", args, "path_blocked", 1, "Zezima") == {}
    near = {**S0, "position": [1.0, 0.5, 0]}  # < 2 m net, rounded args equal
    assert w.note("go_to", {"target": [12.1, 34.0, 56.2]}, "path_blocked", near) == 2
    assert "2nd time go_to" in w.verdict("go_to", args, "path_blocked", 2, "Zezima")["repeat"]
    assert w.note("go_to", args, "path_blocked", near) == 3
    first = w.verdict("go_to", args, "path_blocked", 3, "Zezima")["parked"]
    assert first.startswith("3rd time go_to") and "Tell Zezima" in first
    assert "already told him" in w.verdict("go_to", args, "path_blocked", 4, "Zezima")["parked"]


def test_progress_restarts_the_count():
    w = RepeatWatch()
    args = {"target": "tree_1"}
    w.note("gather", args, "blocked", S0)
    assert w.note("gather", args, "blocked", {**S0, "position": [5, 0, 0]}) == 1  # moved: a new try
    assert w.note("gather", args, "blocked", {**S0, "position": [5, 0, 0], "inventory": {"ITEM_Log": 3}}) == 1
    assert w.note("gather", args, "other_reason", S0) == 1  # another reason is another signature
    w.progressed("gather", args)
    assert w.note("gather", args, "blocked", S0) == 1


def _failing_go_to(rig):
    original, sent = rig.game.call, []

    def call(tool, args):
        if tool == "go_to":
            sent.append(args)
            return {"ok": False, "reason": "path_blocked", "data": {"detail": "a wall"}}
        return original(tool, args)
    rig.game.call = call
    return sent


def _tool_results(call):
    return [json.loads(m["content"]) for m in call["messages"] if m.get("role") == "tool"]


def test_chain_hears_the_repeat_then_parks_and_stops(tmp_path):
    rig = Rig(tmp_path, max_attempts=1)
    sent = _failing_go_to(rig)
    go = lambda: FakeLLM.call("go_to", target=[20, 0, 0])  # noqa: E731
    rig.controller_llm.push(FakeLLM.say("", go()), FakeLLM.say("", go()), FakeLLM.say("", go()),
                            FakeLLM.say("There's a wall in the way, I can't get there."), FakeLLM.say("", go()))
    rig.game.player_say("come to the cave")
    rig.agent.step()
    calls = rig.controller_llm.calls
    assert len(calls) == 4  # decide + 3 follow-ups; the 4th follow-up after the park never happens
    second, third = _tool_results(calls[2])[-1], _tool_results(calls[3])[-1]
    assert "change" in second and second["change"].startswith("this turn: moved")
    assert "2nd time go_to" in second["repeat"] and "parked" not in second
    assert third["parked"].startswith("3rd time go_to") and "path_blocked" in third["parked"]
    assert rig.agent.request_parked == third["parked"] and rig.agent.request_calls == 4
    assert "There's a wall in the way, I can't get there." in rig.companion_said()
    assert len(sent) == 3


# ------------------------------------------------------------------ the Director side

from test_director import COPPER, decision, gained, have, make, step, ticks  # noqa: E402


def _runner(results):
    """A board run per call: the next scripted (ok, reason, extra) record."""
    seen = []

    def run(ev, port):
        if ev["type"] != "board_step":
            return None
        rec = results[min(len(seen), len(results) - 1)]
        seen.append(ev)
        return {"actions": [{"tool": "gather", "args": {"resource": "copper"}, "ok": rec[0], "reason": rec[1],
                             "data": {"owner": "fed_reflex"} if rec[1] == "busy" else {}, "origin": "board"}],
                "ended": "normal", **(rec[2] if len(rec) > 2 else {})}
    return run, seen


def _job(tmp_path, results):
    run, seen = _runner(results)
    d, port, world, llm, clock = make(tmp_path, run, [
        decision(task_success=have(COPPER, 5), steps=[step("mine copper", gained(COPPER, 5))]),
        decision(ask_help="Where should I go?")])
    d.handle_tool("add_task", {"text": "collect copper"}, "Zezima")
    return d, seen, llm, clock


def test_a_busy_run_waits_and_runs_again_without_a_replan(tmp_path):
    d, seen, llm, clock = _job(tmp_path, [(False, "busy")])
    ticks(d, 2)
    assert len(seen) == 1 and len(llm.calls) == 1  # held: no second run yet, no replan
    clock.t += 6
    ticks(d, 1)
    assert len(seen) == 2  # the one retry, after the owner had a moment
    ticks(d, 3)
    assert len(seen) == 3 and len(llm.calls) == 2  # busy again: counted as usual, 2 runs without progress -> replan
    assert json.loads(llm.calls[1]["messages"][1]["content"])["decision"] == "replan"


def test_a_parked_chain_fails_the_attempt_for_a_replan(tmp_path):
    d, seen, llm, clock = _job(tmp_path, [(False, "path_blocked", {"parked": "3rd time gather ... parked"})])
    ticks(d, 3)
    assert len(seen) == 1
    request = json.loads(llm.calls[1]["messages"][1]["content"])
    assert request["decision"] == "replan" and request["detail"]["failed"]["reason"].startswith("parked: 3rd time")


def test_a_step_that_burns_its_call_budget_fails_the_attempt(tmp_path):
    from brain.director import STEP_CALL_BUDGET
    d, seen, llm, clock = _job(tmp_path, [(False, "path_blocked", {"model_calls": STEP_CALL_BUDGET})])
    ticks(d, 3)
    assert len(seen) == 1
    request = json.loads(llm.calls[1]["messages"][1]["content"])
    assert request["detail"]["failed"]["reason"].startswith(f"used {STEP_CALL_BUDGET} model calls on this step")


# ------------------------------------------------------------------ busy names who had the body (chat ladder)


def test_busy_names_the_reflex_never_the_token(tmp_path):
    from brain.interface import parse_event
    rig = Rig(tmp_path, max_attempts=1)
    original = rig.game.call

    def call(tool, args):
        if tool == "go_to":
            return {"ok": False, "reason": "busy", "data": {"detail": "movement owner token required"}}
        return original(tool, args)
    rig.game.call = call
    rig.agent.handle_event(parse_event({"type": "activity", "kind": "reflex_use", "by": "reflex", "name": "Clean Water",
                                        "item": "ITEM_Consumable_Water_Clean", "ok": True}))
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("go_to", target=[20, 0, 0])), FakeLLM.say(""))
    rig.game.player_say("come here")
    rig.agent.step()
    seen = _tool_results(rig.controller_llm.calls[1])[-1]
    assert seen["data"]["busy_by"] == "reflex" and seen["data"]["busy_item"] == "Clean Water"
    rig.controller.report_failure("go_to", "busy", seen["data"])
    assert rig.companion_said()[-1] == "I couldn't walk somewhere just then: I was busy with Clean Water."
    assert not any("token" in s for s in rig.companion_said())


def test_busy_with_the_arbiters_owner_brief_names_it(tmp_path):
    rig = Rig(tmp_path, max_attempts=1)
    rig.controller.report_failure("go_to", "busy", {"owner": {"name": "reflex:eat", "level": "reflex", "token": 7},
                                                    "detail": "busy: reflex:eat (reflex) is using my legs, for 3 s"})
    assert rig.companion_said()[-1] == "I couldn't walk somewhere just then: my reflex had hold of me."


# ------------------------------------------------------------------ the request deadline never cuts a move's report


def test_a_long_go_to_past_the_deadline_still_gets_its_report_turn(tmp_path):
    from brain import agent as agent_mod
    rig = Rig(tmp_path, max_attempts=1)
    now = [0.0]
    rig.agent.clock = lambda: now[0]
    original = rig.game.call

    def call(tool, args):
        if tool == "go_to":  # a 295 s go_to after earlier steps: the request's time is up when it ends
            now[0] += agent_mod.REQUEST_SECONDS + 5
        return original(tool, args)
    rig.game.call = call
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("go_to", target=[20, 0, 0])), FakeLLM.say("I'm there now."))
    rig.game.player_say("come here")
    rig.agent.step()
    assert len(rig.controller_llm.calls) == 2
    assert rig.controller_llm.calls[1]["messages"][-1]["content"] == agent_mod.LAST_TURN_NOTE
    assert rig.companion_said()[-1] == "I'm there now."


def test_nav_unavailable_and_resting_are_reasons_of_their_own():
    from brain.interface import Reason
    assert Reason.NAV_UNAVAILABLE == "nav_unavailable" and Reason.RESTING == "resting"
    assert {Reason.NAV_UNAVAILABLE, Reason.RESTING} <= Reason.DETERMINISTIC  # back to the model, never retried blindly


def test_recent_life_death_cause_kill_zone_and_bars():
    """Run 5 (16:37Z): a 31 m fall into the KillZVolume at food 12 %; the line names the fall and the bars, and the
    gravestone after it is not cut off."""
    from brain.situation import recent_life
    st = {"last_death": {"ago_s": 3, "killed_by": "falling into a kill zone (a drop the game kills anything in)",
                         "killed_by_class": "KillZVolume", "fell_m": 31.0, "bars": {"food": 12, "water": 61, "rest": 87},
                         "at": [48.3, 1741.0, -60.8]},
          "my_grave": {"id": "BP_PlayerGravestone_C_1", "distance": 30.0, "items": 9, "contents": ["Fillet x3"]}}
    line = recent_life(st)[0]
    assert "killed by falling into a kill zone" in line and "fell 31 m" in line, line
    assert "bars then food 12%, water 61%, rest 87%: food and water above 0, so not hunger or thirst" in line, line
    assert "YOUR gravestone is 30 m away" in line and "Fillet x3" in line, line
    raw = recent_life({"last_death": {"ago_s": 3, "killed_by": "KillZVolume"}})[0]  # an older body's raw class
    assert "kill zone" in raw and "KillZVolume" not in raw, raw
    starved = recent_life({"last_death": {"ago_s": 3, "killed_by": "my own condition", "bars": {"food": 0, "water": 40}}})[0]
    assert "food 0%, water 40%: food empty" in starved, starved


def test_recent_life_says_what_killed_him_and_where():
    from brain.situation import recent_life
    assert recent_life({"last_death": {"ago_s": 200, "respawned": True, "killed_by": "Giant Rat"}}) == [
        "Recent: you died 3 min ago (killed by Giant Rat) and respawned"]
    line = recent_life({"last_death": {"ago_s": 20, "fell_m": 12.4, "at": [99999.0, 99999.0, 0.0]}})[0]
    assert line == "Recent: you died 20 s ago (cause unknown (the game didn't say); fell 12 m; at [99999, 99999, 0])"
    assert recent_life({"last_death": {"ago_s": 20, "killed_by": {"self": False, "name": "Goblin"}}})[0].endswith(
        "(killed by Goblin)")
    # nothing said what killed him: he is told so, never left to guess (live 16:37Z "starving got me" at 12 % food)
    assert recent_life({"last_death": {"ago_s": 20}}) == ["Recent: you died 20 s ago (cause unknown (the game didn't say))"]
    assert recent_life({"last_death": {"ago_s": 20, "at": [176.25, 1863.53, -30.23]}})[0].endswith(
        "; at Temple Woods)")  # the game map's region (data/places_<build>.json)

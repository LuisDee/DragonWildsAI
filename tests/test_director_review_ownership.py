"""Offline regressions for a873: real Agent/Director/broker boundaries, scripted models only."""
import concurrent.futures as cf
import copy

import pytest

from brain import director as D
from brain.interface import Attacked
from brain.llm import FakeLLM, LLMResponse
from test_event_hygiene import Replay


def boundary(tmp_path):
    state = {"position": [0., 0., 0.], "health": 100, "max_health": 100, "inventory": {},
             "survival": {"hydration": [60, 100]}, "players": [], "bag": {"used": 1, "capacity": 10},
             "time_of_day": {"phase": "day", "sleep_allowed": False}}
    r = Replay(tmp_path, state)
    r.model.body_reply = lambda ctx: LLMResponse(content="")
    d = D.Director(D.AgentPort(r.agent, "Luis"), FakeLLM(), tmp_path / "board", log=r.log,
                   body_tools={"go_to": "walk"}, executor=D.SyncExecutor(), clock=r.clock)
    r.agent.director = d
    r.controller.attach_director(d)
    task = d.ops.add_task("an unfamiliar journey", by="player:Luis")
    task.status = "active"
    d.ops.b.current = task.id
    d._need(task, "replan", {"failed": {"reason": "held-out route failure"}})
    return r, d, task


def pending_change(r, pct=45):
    r.agent._fresh_state()
    r.body.state["survival"]["hydration"][0] = pct
    r.at(61)
    r.agent._fresh_state()
    assert r.agent.broker._pending


def review():
    return {"type": "situation_review", "changes": [{"what": "hydration", "direction": "down",
            "from_pct": 60, "to_pct": 45, "now": "a bit thirsty"}], "stats_pct": {"hydration": 45},
            "previous_review": {"ago_s": 20, "changes": [], "you_said": "earlier"}, "source": "fixture"}


@pytest.mark.parametrize("mode", ["pending", "done", "cancelled", "awaiting", "run"])
def test_owned_transition_prevents_actual_review_call_and_preserves_broker_pending(tmp_path, mode):
    r, d, task = boundary(tmp_path)
    pending_change(r)
    if mode != "awaiting":
        d.ops.b.awaiting_decision = None
    if mode in ("pending", "done", "cancelled"):
        d._future = cf.Future()
        if mode == "done":
            d._future.set_result(D.Decision(kind="replan"))
        elif mode == "cancelled":
            d._future.cancel()
    if mode == "run":
        d._in_run = True
    # If admitted, this model would retry movement or pause the board, as in a873.
    r.model.body_reply = lambda ctx: FakeLLM.say("", FakeLLM.call("pause_board", reason="model chose to pause"))
    before = copy.deepcopy(r.agent.broker._pending)
    r.agent._review_tick()
    assert d.owns_transition and not r.model.calls and not r.body.calls
    assert r.agent.broker._pending == before and r.agent.broker._last_review is None
    assert task.status == "active" and d.ops.b.paused is None


@pytest.mark.parametrize("status", ["paused", "parked", "waiting_budget", "waiting_help", "done", "cancelled"])
def test_inactive_or_budget_wait_without_future_does_not_own_transition(tmp_path, status):
    r, d, task = boundary(tmp_path)
    task.status = status
    d._learn_future = cf.Future()  # learning never owns the board decision stream
    assert not d.owns_transition
    pending_change(r)
    r.agent._review_tick()
    assert r.model.contexts and r.model.contexts[0]["body_event"]["type"] == "situation_review"


def test_awaiting_must_match_current_task_and_property_does_not_pick_or_check_budget(tmp_path, monkeypatch):
    _, d, _ = boundary(tmp_path)
    monkeypatch.setattr(d.ops, "pick_current", lambda: pytest.fail("property picked a task"))
    monkeypatch.setattr(d, "_can_think", lambda *a: pytest.fail("property checked budget"))
    assert d.owns_transition
    d.ops.b.awaiting_decision["task_id"] = "different-task"
    assert not d.owns_transition
    d.ops.b.awaiting_decision["task_id"] = d.ops.b.current
    d.ops.b.paused = {"by": "player:Luis"}
    assert not d.owns_transition
    d._future = cf.Future()
    assert d.owns_transition  # paused still must collect/discard an outstanding result


@pytest.mark.parametrize("status", ["active", "preempted", "queued"])
def test_matching_runnable_awaiting_decision_owns_transition(tmp_path, status):
    _, d, task = boundary(tmp_path)
    task.status = status
    assert d.owns_transition


def test_flush_partitions_review_from_urgent_vitals_and_native_defense_stays_available(tmp_path):
    r, d, _ = boundary(tmp_path)
    r.body.state["survival"]["hydration"][0] = 5
    old = review()
    urgent = {"type": "vitals_low", "stat": "hydration", "value": 5, "max": 100,
              "fixed_by": "drink", "carrying_one": False}
    r.agent._situations = [old, urgent]
    r.agent.flush_situations()
    assert r.model.contexts[0]["body_event"] == urgent
    assert r.agent._situations == [old] and d.owns_transition
    before = len(r.model.calls)
    r.agent.body_self_defends = True
    r.agent.handle_event(Attacked(by="held-out attacker"))
    assert len(r.model.calls) == before
    assert r.records("attacked_body_reflex")


def test_broker_pending_recovered_change_is_revalidated_after_planning_release(tmp_path):
    r, d, _ = boundary(tmp_path)
    pending_change(r)
    r.agent._review_tick()
    r.body.state["survival"]["hydration"][0] = 70
    d.ops.b.awaiting_decision = None
    r.at(122)
    r.agent._review_tick()
    assert not r.model.calls and not r.agent._situations
    assert r.records("situation_stale")[-1]["why"] == "review changes no longer true"


def test_deferred_review_refreshes_facts_once_without_rewriting_history(tmp_path):
    r, d, _ = boundary(tmp_path)
    original = review()
    r.agent._situations = [original]
    r.agent.flush_situations()
    assert not r.model.calls
    d.ops.b.awaiting_decision = None
    r.body.state["survival"]["hydration"][0] = 42
    r.agent.flush_situations()
    current = r.model.contexts[0]["body_event"]
    assert current["stats_pct"]["hydration"] == 42
    assert current["changes"][0]["to_pct"] == 45 and current["changes_are_historical"]
    assert current["previous_review"] == original["previous_review"] and current["source"] == "fixture"
    assert original == review() and not r.agent._situations
    r.agent.flush_situations()
    assert len(r.model.contexts) == 1


def test_human_chat_merging_uses_the_same_revalidation_boundary(tmp_path):
    r, d, _ = boundary(tmp_path)
    d.ops.b.awaiting_decision = None
    r.agent._situations = [review()]
    r.body.state["survival"]["hydration"][0] = 80
    r.agent._run("Luis", "status please", True)
    assert r.model.contexts[0]["command"]["text"] == "status please"
    assert "body_event" not in r.model.contexts[0]
    assert not r.agent._situations


def test_human_pause_interrupts_planning_and_stale_result_is_still_discarded(tmp_path):
    r, d, task = boundary(tmp_path)
    aw = copy.deepcopy(d.ops.b.awaiting_decision)
    d._future = cf.Future()
    d._pending = {"task_id": task.id, "key": d.ops.plan_key(task), "aw": aw, "started": r.clock()}
    r.agent._situations = [review()]
    r.model.replies["please pause"] = FakeLLM.say("", FakeLLM.call("pause_board", reason="human request"))
    r.agent._run("Luis", "please pause", True)
    assert task.status == "paused" and d.ops.b.paused["by"] == "player:Luis"
    assert "body_event" not in r.model.contexts[0] and r.agent._situations == [review()]
    d._future.set_result(D.Decision(kind="replan", value={"steps": []}, requests=1))
    d._collect_decision()
    assert d._future is None and not d.owns_transition
    assert r.records("director_discarded")[-1]["stale"] is True


@pytest.mark.parametrize("change,state,kept", [
    ({"what": "time_of_day", "from": "day", "to": "night"}, {"time_of_day": {"phase": "day"}}, False),
    ({"what": "sleep_allowed", "to": True}, {"time_of_day": {"sleep_allowed": False}}, False),
    ({"what": "bag", "used": 10, "capacity": 10}, {"bag": {"used": 1, "capacity": 10}}, False),
    ({"what": "bag", "used": 10, "capacity": 10}, {"bag": {"used": 9, "capacity": 10}}, True),
])
def test_other_review_changes_revalidated_with_existing_facts(tmp_path, change, state, kept):
    r, d, _ = boundary(tmp_path)
    d.ops.b.awaiting_decision = None
    r.agent._situations = [{"type": "situation_review", "changes": [change]}]
    assert bool(r.agent.take_situations(state)) is kept


def test_unavailable_state_is_explicit_unknown_never_old_facts_as_fresh(tmp_path):
    r, d, _ = boundary(tmp_path)
    d.ops.b.awaiting_decision = None
    r.agent._situations = [review()]
    current, = r.agent.take_situations({"unavailable": "fixture"})
    assert current["current_facts_unknown"] and current["stats_pct"] == {}
    assert current["players_near"] is None and current["bag"] is None and current["time_of_day"] is None
    assert current["changes"][0]["current_validity"] == "unknown" and current["changes_are_historical"]


def test_partial_state_does_not_turn_missing_or_nonfinite_stat_into_current_fact(tmp_path):
    r, d, _ = boundary(tmp_path)
    d.ops.b.awaiting_decision = None
    r.agent._situations = [review()]
    current, = r.agent.take_situations({"position": [0, 0, 0], "survival": {"hydration": [float("nan"), 100]}})
    assert current["stats_pct"] == {} and current["players_near"] is None
    assert current["changes"][0]["current_validity"] == "unknown"


@pytest.mark.parametrize("recorded,current,kept", [(10, 25, False), (50, 49.6, True)])
def test_recovered_triggering_band_is_dropped_and_rounded_boundary_still_works(tmp_path, recorded, current, kept):
    r, d, _ = boundary(tmp_path)
    d.ops.b.awaiting_decision = None
    old = review()
    old["changes"][0]["to_pct"] = recorded
    r.agent._situations = [old]
    r.body.state["survival"]["hydration"][0] = current
    assert bool(r.agent.take_situations()) is kept


@pytest.mark.parametrize("queued", [False, True])
@pytest.mark.parametrize("current,expected", [(10, "current"), (20, "unknown"), (35, "obsolete")])
def test_real_broker_rounded_crossing_preserves_all_none_or_mixed_band_evidence(tmp_path, queued, current, expected):
    r, d, _ = boundary(tmp_path)
    r.body.state["survival"]["hydration"][0] = 29.6
    r.agent._fresh_state()
    r.body.state["survival"]["hydration"][0] = 14.6
    r.agent._fresh_state()
    change, = r.agent.broker._pending
    assert change["from_pct"] == 30 and change["to_pct"] == 15
    historical = copy.deepcopy(change)
    if queued:
        event = r.agent.broker.review_due()
        assert event is not None
        r.agent._situations = [event]
        r.agent.flush_situations()
    else:
        r.agent._review_tick()
    assert not r.model.calls
    r.body.state["survival"]["hydration"][0] = current
    d.ops.b.awaiting_decision = None
    r.at(61)
    if queued:
        r.agent.flush_situations()
    else:
        r.agent._review_tick()
    if expected == "obsolete":
        assert not r.model.contexts
        assert r.records("situation_stale")[-1]["why"] == "review changes no longer true"
    else:
        delivered = r.model.contexts[0]["body_event"]
        assert delivered["stats_pct"]["hydration"] == current and delivered["changes_are_historical"]
        actual, = delivered["changes"]
        assert {k: v for k, v in actual.items() if k != "current_validity"} == historical
        assert (actual.get("current_validity") == "unknown") is (expected == "unknown")

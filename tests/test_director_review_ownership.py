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

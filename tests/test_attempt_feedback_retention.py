"""Offline Agent/Director feedback diagnostics, with scripted models and a mock body."""
import copy
import json

import pytest

from conftest import Rig
from brain import director as D
from brain import predicates as P
from brain.board import Step
from brain.llm import FakeLLM
from test_director import Clock, decision


FAILURE = {"detail": "held-out obstruction", "source": "fixture.native", "observed_at": 17.0, "route_feedback": {
    "generation": 72, "requested_xyz": [12.0, 34.0, 56.0], "final_position": [1.0, 2.0, 3.0],
    "unknown": ["unobserved_surface"], "partial": True}, "position": [1.0, 2.0, 3.0]}


def body_event(call):
    return json.loads(call["messages"][1]["content"])["body_event"]


def boundary(tmp_path):
    rig = Rig(tmp_path)
    rig.executor.max_attempts = 1
    calls = []
    original = rig.game.call
    def fail(tool, args):
        if tool == "go_to":
            calls.append((tool, copy.deepcopy(args)))
            data = copy.deepcopy(FAILURE)
            data["route_feedback"]["requested_xyz"] = list(args["target"])
            return {"ok": False, "reason": "path_blocked", "data": data}
        return original(tool, args)
    rig.game.call = fail
    items = P.Items(names={"log": "log"})
    planner = FakeLLM([decision(ask_help="A failed route needs a different plan.")], model="fake/director")
    d = D.Director(D.AgentPort(rig.agent, "Luis"), planner, tmp_path / "board",
                   body_tools={"go_to": "walk"}, executor=D.SyncExecutor(), clock=Clock(), log=rig.log, items=items)
    rig.agent.director = d
    rig.controller.attach_director(d)
    task = d.ops.add_task("reach an unfamiliar place", by="cli")
    task.status = "active"
    step = Step(title="reach the place", success=P.validate({"have": {"item": "log", "at_least": 99}}, items),
                first_call={"tool": "go_to", "args": {"target": [12.0, 34.0, 56.0]}})
    task.steps = [step]
    return rig, d, task, step, planner, calls


def test_actual_first_call_and_empty_run_retain_failure_in_both_model_requests(tmp_path):
    rig, d, task, step, planner, calls = boundary(tmp_path)
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("go_to", target=[13.0, 35.0, 57.0])), "", "")
    d._advance(task)
    first = body_event(rig.controller_llm.calls[0])
    feedback = first["first_call_result"]
    assert feedback["args"] == step.first_call["args"] and feedback["data"] == FAILURE
    assert feedback["origin"] == "board" and feedback["ok"] is False
    assert (first["board_task_id"], first["step_id"], first["attempt"]) == (task.id, step.id, 1)
    assert "action_id" not in feedback and "observed_at" not in feedback and "completed_at" not in feedback
    d._advance(task)
    second = body_event(rig.controller_llm.calls[2])  # second board run executes no body actions
    retained = second["last_results"]
    assert retained[0] == feedback and len(retained) == 2 and second["attempt"] == 1
    assert retained[1]["args"] == {"target": [13.0, 35.0, 57.0]}
    assert retained[1]["data"]["observed_at"] == 17.0
    assert len(calls) == 2 and len(step.actions) == 2 and step.status == "failed"
    pending = d.ops.b.awaiting_decision
    assert pending["kind"] == "replan"
    outcome = d._decide(d._snapshot(task, pending, rig.game.get_state()["data"]))
    assert not outcome.error
    failed = json.loads(planner.calls[0]["messages"][1]["content"])["detail"]["failed"]
    assert failed["last_actions"] == retained
    assert (failed["board_task_id"], failed["step_id"], failed["attempt"]) == (task.id, step.id, 1)
    assert failed["last_actions"][0]["data"]["route_feedback"]["unknown"] == ["unobserved_surface"]


def test_new_attempt_with_same_step_id_clears_previous_feedback_before_controller_request(tmp_path):
    rig, d, task, step, _, calls = boundary(tmp_path)
    rig.controller_llm.push("", "", "")
    d._advance(task)
    d._advance(task)
    assert d._last_results[step.id] and step.attempts == 1
    step.status = "pending"  # same-step retry, as the existing ordered-checkpoint replan can produce
    step.first_call = None
    d.ops.b.awaiting_decision = None
    d._advance(task)
    event = body_event(rig.controller_llm.calls[2])
    assert event["attempt"] == step.attempts == 2 and event["step_id"] == step.id
    assert "last_results" not in event and "first_call_result" not in event
    assert step.actions == [] and d._last_results[step.id] == [] and len(calls) == 1


def test_supplied_identity_and_times_are_copied_without_refresh_or_raw_mutation():
    record = {"tool": "held_out", "args": {"target": [1, 2, 3]}, "ok": False, "reason": "blocked",
              "data": FAILURE, "origin": "board", "action_id": "executor-action", "task_id": "executor-task",
              "tool_call_id": "provider-call", "source": "fixture.native", "observed_at": 101.5,
              "completed_at": 102.5, "received_at": 103.5}
    original = copy.deepcopy(record)
    first = D._result_summaries([record])[0]
    second = D._result_summaries([record])[0]
    assert first == second == record and record == original
    first["data"]["route_feedback"]["unknown"].append("modified copy")
    assert record == original


@pytest.mark.parametrize("unicode_text", [False, True])
def test_large_arguments_and_metadata_stay_inside_existing_summary_bounds(unicode_text):
    text = ("桜" if unicode_text else "x") * 3000
    records = [{"tool": f"tool_{i}", "ok": False, "reason": "blocked",
                "args": {f"field_{j}": text for j in range(40)}, "source": text,
                "action_id": text, "observed_at": 17.0,
                "data": {"rows": [{"detail": text}] * 40}} for i in range(10)]
    original = copy.deepcopy(records)
    summaries = D._result_summaries(records)
    assert [r["tool"] for r in summaries] == [r["tool"] for r in records[-8:]]
    assert len(json.dumps(summaries, allow_nan=False).encode("utf-8")) <= D.RESULTS_BUDGET
    assert all(len(json.dumps(r, allow_nan=False).encode("utf-8")) <= D.RESULT_DATA_BUDGET for r in summaries)
    assert all(r.get("args_truncated") or r.get("args_omitted") for r in summaries)
    assert all(r.get("summary_truncated") or r.get("metadata_omitted") for r in summaries)
    assert all(r.get("data_truncated") or r.get("data_omitted") for r in summaries)
    assert records == original

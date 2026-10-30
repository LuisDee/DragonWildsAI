"""Decision preservation under bounded optional refinement; no game/API calls."""
import copy
import json

import pytest

from brain.llm import FakeLLM, LLMResponse, ToolCall
from brain.llm_json import BudgetStop, DecisionError, json_decision
from test_director import decision, make, step, ticks, ListLog


def test_director_applies_fifth_valid_plan_without_sixth_advisory_call(tmp_path):
    home = {"near": {"position": [0., 0., 0.], "within_m": 2}}
    far = {"not": {"near": {"position": [0., 0., 0.], "within_m": 200}}}
    good = decision(completion_mode="ordered_steps", task_success=home, steps=[
        step("start", home), step("out", far, checkpoint_id="out"),
        step("back", home, checkpoint_id="back")])
    bad = json.loads(good)
    bad["steps"][1]["group"] = "repeat"
    bad["loops"] = {"repeat": {"until": far}}
    research = LLMResponse(tool_calls=[ToolCall("recall", {"query": "route"})])

    def drive(event, port):
        if event["type"] == "board_step":
            port.world.state["position"] = [210., 0., 0.] if event["step"]["title"] == "out" else [0., 0., 0.]
            return {"actions": [], "ended": "normal"}

    d, port, _, llm, _ = make(tmp_path, controller=drive,
                             script=[research, copy.deepcopy(research), "", json.dumps(bad), good])
    log = ListLog()
    d.log = log
    task_id = d.handle_tool("add_task", {"text": "walk away and back", "when": "now"}, "Zezima")["data"]["id"]
    ticks(d)
    task = d.ops.b.task(task_id)
    assert task.status == "done"
    assert len(llm.calls) == 5 and d.window.left() == 15
    assert [c["id"] for c in task.checkpoints] == ["out", "back"]
    assert [e["step"]["title"] for e in port.events if e["type"] == "board_step"] == ["out", "back"]
    assert any(r["kind"] == "director_advisory_skipped" and r["requests"] == 5 for r in log.rows)


def test_optional_advisory_still_runs_when_capacity_exists():
    llm = FakeLLM(['{"value":1}', '{"value":2}'])
    value, info = json_decision(llm, [], lambda t, r: (json.loads(t), ["consider evidence"]),
                                can_advise=lambda: True)
    assert value == {"value": 2} and len(llm.calls) == 2
    assert info["advised"] and "advisory_skipped" not in info


def test_unaffordable_advisory_preserves_exact_valid_value():
    value, info = json_decision(FakeLLM(['{"value":1}']), [],
                                lambda t, r: (json.loads(t), ["optional"]), can_advise=lambda: False)
    assert value == {"value": 1}
    assert info["requests"] == 1 and info["advisory_skipped"] == "capacity"
    assert not info["advised"]
    assert info["messages"][-1] == {"role": "assistant", "content": '{"value":1}'}


@pytest.mark.parametrize("response", ["invalid", LLMResponse(content='{"value":1}', finish_reason="length")])
def test_advisory_capacity_never_accepts_invalid_or_truncated_output(response):
    with pytest.raises(DecisionError):
        json_decision(FakeLLM([response]), [], lambda t, r: json.loads(t),
                      max_repairs=0, can_advise=lambda: False)


def test_hard_budget_or_cancellation_is_not_swallowed_after_valid_candidate():
    calls = []
    def guard():
        if calls:
            raise BudgetStop("cancelled")
        calls.append(1)
        return True
    with pytest.raises(BudgetStop, match="cancelled"):
        json_decision(FakeLLM(['{"value":1}']), [], lambda t, r: (json.loads(t), ["optional"]),
                      before_request=guard, can_advise=lambda: True)


def test_no_fallback_to_previous_candidate_after_invalid_revision():
    with pytest.raises(DecisionError):
        json_decision(FakeLLM(['{"value":1}', 'invalid']), [],
                      lambda t, r: (json.loads(t), ["optional"]), max_repairs=0, can_advise=lambda: True)

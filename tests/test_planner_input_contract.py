import json

import pytest

from brain.capabilities import Capabilities
from brain.director import Validator
from brain.geom import WIRE_COORDINATES
from brain.llm import FakeLLM
from test_director import COPPER, TIN, World, decision, have, make, step, ticks


def test_director_actual_request_contains_intact_manifest(tmp_path):
    schema = {"type": "object", "properties": {"distance": {"type": "number", "minimum": 37,
              "maximum": 91, "description": "detail " * 80}, "nested": {"type": "object",
              "properties": {"choice": {"enum": ["a", "b"]}}, "required": ["choice"]}},
              "required": ["distance"]}
    plan = decision(task_success=have(COPPER, 1), steps=[step("work", have(TIN, 1))])
    d, _, _, llm, _ = make(tmp_path, script=[plan], body_tools={"arbitrary": "do work", "missing": "unknown tool"})
    d.caps = Capabilities([], "test", manifest={"arbitrary": {"args": schema}})
    d.ops.add_task("work", by="cli")
    ticks(d, 2)
    system = llm.calls[0]["messages"][0]["content"]
    assert json.dumps(schema, ensure_ascii=False) in system
    assert "missing: unknown tool\n  args JSON schema: unknown (not published)" in system
    assert WIRE_COORDINATES in system
    with pytest.raises(ValueError):
        d.caps.validate("arbitrary", {"distance": 36})


def test_controller_actual_request_contains_wire_coordinates(rig):
    rig.controller_llm.push(FakeLLM.say("hello"))
    rig.controller.decide("Zezima", "hello", World().state, None)
    assert WIRE_COORDINATES in rig.controller_llm.calls[0]["messages"][0]["content"]


def test_ordered_final_true_suppresses_only_global_warning():
    world = World()
    world.add(COPPER, 1)
    v = Validator("plan", world.state, {"kind": "specific"}, research_left=lambda: False)
    out = step("out", have(TIN, 1), checkpoint_id="out")
    back = step("back", have(COPPER, 1), checkpoint_id="back")
    raw = dict(task_success=have(COPPER, 1), steps=[out, back])
    result, advisory = v(decision(completion_mode="ordered_steps", **raw), 0)
    assert result["task_success_trivial"] is True and advisory == []
    _, advisory = v(decision(task_success=raw["task_success"], steps=[step("out", have(TIN, 1))]), 0)
    assert "task_success is already true" in advisory[0]
    with pytest.raises(ValueError, match="unique checkpoint"):
        v(decision(completion_mode="ordered_steps", task_success=raw["task_success"], steps=[step("out", have(TIN, 1))]), 0)
    _, advisory = v(decision(completion_mode="ordered_steps", task_success=raw["task_success"],
                             steps=[step("out", have(COPPER, 1), checkpoint_id="out")]), 0)
    assert "steps[0]" in advisory[0] and "task_success is already true" not in advisory[0]

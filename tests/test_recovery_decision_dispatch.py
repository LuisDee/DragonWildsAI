"""Real Agent recovery dispatch over mock body/scripted models; no live or provider calls."""
import copy
import json

from conftest import Rig
from brain.interface import CommandReceived
from brain.llm import FakeLLM, ToolCall
from brain.skill_library import SkillRecord


BUSY_DETAIL = "held-out operation is temporarily owned"


def boundary(tmp_path):
    rig = Rig(tmp_path, max_attempts=1, library=True)
    rig.agent.learn_skills = False
    rig.library.save(SkillRecord.model_validate({
        "name": "walk_to_location", "description": "Walk to a chosen location.",
        "params": {axis: {"type": "float"} for axis in ("x", "y", "z")},
        "steps": [{"skill": "go_to", "args": {"target": ["$x", "$y", "$z"]}}],
        "preconditions": [], "postcondition": None}))
    sent = []
    original = rig.game.call
    def call(tool, args):
        sent.append((tool, copy.deepcopy(args)))
        if tool == "go_to" and sum(t == "go_to" for t, _ in sent) == 1:
            return {"ok": False, "reason": "busy", "data": {"detail": BUSY_DETAIL}}
        return original(tool, args)
    rig.game.call = call
    return rig, sent


def failure_call():
    return FakeLLM.say("", FakeLLM.call("go_to", target=[10, 0, 0]))


def moves(sent):
    return [args for tool, args in sent if tool == "go_to"]


def records(rig, kind):
    return [row for row in rig.log.read_all() if row["kind"] == kind]


def test_failed_directed_action_dispatches_skill_only_recovery_exactly_once(tmp_path):
    rig, sent = boundary(tmp_path)
    rig.controller_llm.push(failure_call(), FakeLLM.say("", ToolCall("run_skill", {"name": "walk_to_location",
        "params": {"x": 20., "y": 0., "z": 0.}})))
    result = rig.agent.run_directed({"type": "board_step", "step": {"title": "held-out journey"}}, "Luis")
    assert moves(sent) == [{"target": [10, 0, 0]}, {"target": [20., 0., 0.]}]
    assert len(records(rig, "skill_queued")) == 1
    assert not rig.planner_llm.calls and len(rig.controller_llm.calls) == 2
    assert [(a["tool"], a["ok"]) for a in result["actions"]] == [("go_to", False), ("go_to", True)]
    assert rig.library.get("walk_to_location").stats.runs == 1
    assert rig.agent.pending_goal is None and rig.agent.pending_skill is None
    assert not any(BUSY_DETAIL in text for text in rig.companion_said())
    old = len(moves(sent))
    assert rig.agent._after_pump(None) is None and len(moves(sent)) == old
    # The actual failed result reached the model before it selected that recovery.
    result_message = next(m for m in rig.controller_llm.calls[1]["messages"] if m["role"] == "tool")
    assert json.loads(result_message["content"])["data"]["detail"] == BUSY_DETAIL


def test_goal_only_recovery_uses_existing_pending_path_once_without_stale_speech(tmp_path):
    rig, sent = boundary(tmp_path)
    rig.controller_llm.push(failure_call(), FakeLLM.say("", FakeLLM.call("start_goal", goal="recover the chosen journey")))
    rig.agent._command(CommandReceived(player="Luis", text="continue the journey"))
    assert rig.agent.pending_goal == "recover the chosen journey"
    assert rig.agent.pending_skill is None and rig.agent.pending_tasks is None
    assert moves(sent) == [{"target": [10, 0, 0]}] and not rig.planner_llm.calls
    assert not any(BUSY_DETAIL in text for text in rig.companion_said())
    rig.planner_llm.push(FakeLLM.plan([{"skill": "go_to", "args": {"target": [20, 0, 0]}}]))
    assert rig.agent._after_pump(None) == "done"
    assert moves(sent) == [{"target": [10, 0, 0]}, {"target": [20, 0, 0]}]
    assert len(rig.planner_llm.calls) == 1 and rig.agent.pending_goal is None
    assert rig.agent._after_pump(None) is None and len(moves(sent)) == 2


def test_empty_recovery_still_reports_original_failure_without_retry(tmp_path):
    rig, sent = boundary(tmp_path)
    rig.controller_llm.push(failure_call(), "")
    rig.agent._command(CommandReceived(player="Luis", text="continue the journey"))
    assert moves(sent) == [{"target": [10, 0, 0]}]
    assert len(rig.controller_llm.calls) == 2 and not rig.planner_llm.calls
    assert len(rig.companion_said()) == 1 and BUSY_DETAIL in rig.companion_said()[0]
    assert rig.agent.pending_goal is None and rig.agent.pending_skill is None
    assert not records(rig, "skill_queued")

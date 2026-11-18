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
    assert rig.agent.step() is None and len(moves(sent)) == old
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
    assert rig.agent.step() == "done"
    assert moves(sent) == [{"target": [10, 0, 0]}, {"target": [20, 0, 0]}]
    assert len(rig.planner_llm.calls) == 1 and rig.agent.pending_goal is None
    assert rig.agent.step() is None and len(moves(sent)) == 2


def test_empty_recovery_still_reports_original_failure_without_retry(tmp_path):
    rig, sent = boundary(tmp_path)
    rig.controller_llm.push(failure_call(), "", "")
    rig.agent._command(CommandReceived(player="Luis", text="continue the journey"))
    assert moves(sent) == [{"target": [10, 0, 0]}]
    # silent after the failure with his ask open: one open-ask turn (2026-11-18), silent too, no retry
    assert len(rig.controller_llm.calls) == 3 and not rig.planner_llm.calls
    assert rig.controller_llm.calls[2]["messages"][-1]["content"].startswith("Open request: ")
    assert rig.companion_said() == []  # the model chose silence; the body's busy detail is never read out
    assert rig.agent.pending_goal is None and rig.agent.pending_skill is None
    assert not records(rig, "skill_queued")


def tool_results(rig, n):
    return [json.loads(m["content"]) for m in rig.controller_llm.calls[n]["messages"] if m["role"] == "tool"]


def test_unlearned_skill_name_comes_back_to_the_model_as_the_calls_failed_result(tmp_path):
    """Run 20261117-011014 (Getting Started from gs_start): beside an "on it" line the model called run_skill with a
    name it had made up. Code said "I haven't learned a skill called ..." and the request ended there: he stood 436 s
    with the quest step open. The failure is the model's to read, with the names he has learned."""
    rig, sent = boundary(tmp_path)
    rig.controller_llm.push(
        FakeLLM.say("on it", ToolCall("run_skill", {"name": "gather and craft stone club"}, "c1")),
        FakeLLM.say("", ToolCall("run_skill", {"name": "walk_to_location", "params": {"x": 20., "y": 0., "z": 0.}}, "c2")),
        FakeLLM.say(""))  # (asked once whether Luis should hear of the failed call: sorted, nothing to say)
    rig.agent._command(CommandReceived(player="Luis", text="make the club"))
    assert len(rig.controller_llm.calls) == 3 and len(records(rig, "failure_unreported")) == 1
    res = tool_results(rig, 1)[0]
    assert res["ok"] is False and res["reason"] == "unknown_skill"
    assert res["data"] == {"skill": "gather and craft stone club", "learned": ["walk_to_location"]}
    assert len(records(rig, "skill_queued")) == 1 and rig.agent.pending_skill == "walk_to_location"
    # ("on it" is not said: the call it came with failed first; the queued skill is the job, no open-job check)
    assert rig.companion_said() == [] and not records(rig, "open_job_check")


def test_skill_that_cannot_start_comes_back_to_the_model_too(tmp_path):
    rig, sent = boundary(tmp_path)
    rig.controller_llm.push(
        FakeLLM.say("", ToolCall("run_skill", {"name": "walk_to_location", "params": {}}, "c1")),
        FakeLLM.say("", ToolCall("run_skill", {"name": "walk_to_location", "params": {"x": 20., "y": 0., "z": 0.}}, "c2")),
        FakeLLM.say(""))  # (asked once whether Luis should hear of the failed call: sorted, nothing to say)
    rig.agent._command(CommandReceived(player="Luis", text="walk over there"))
    assert len(rig.controller_llm.calls) == 3 and len(records(rig, "failure_unreported")) == 1
    res = tool_results(rig, 1)[0]
    assert res["ok"] is False and "can't use it like that" in res["reason"] and res["data"]["skill"] == "walk_to_location"
    assert len(records(rig, "skill_queued")) == 1
    assert rig.companion_said() == []


def test_unlearned_skill_is_still_said_when_the_model_cannot_be_asked(tmp_path):
    rig, sent = boundary(tmp_path)
    rig.controller_llm.push(FakeLLM.say("", ToolCall("run_skill", {"name": "dance"}, "c1")))  # (and then the provider fails)
    rig.agent._command(CommandReceived(player="Luis", text="do the thing"))
    assert rig.companion_said()[-1] == "I haven't learned a skill called dance."

import pytest
from conftest import Rig

from brain.llm import FakeLLM
from brain.planner import PlanError
from brain.state_store import SkillRegistry, StateStore, Task


def test_follow_me_acts_then_speaks(rig):
    rig.game.player_say("follow me")
    rig.controller_llm.push(FakeLLM.say("Right behind you.", FakeLLM.call("follow", player="Luis")))
    rig.agent.step()
    assert rig.game.following == "Luis"
    names = [name for name, _ in rig.game.calls]
    assert names.index("follow") < names.index("say")  # speech comes after the action
    assert rig.companion_said() == ["Right behind you."]
    # tools offered to the model are OpenAI-style function schemas
    offered = {t["function"]["name"] for t in rig.controller_llm.calls[0]["tools"]}
    assert {"follow", "stop", "go_to", "attack", "give", "pickup", "drop", "remember", "start_goal"} <= offered


def test_failed_action_overrides_speech(rig):
    rig.game.player_say("kill that bear")
    rig.controller_llm.push(FakeLLM.say("On it!", FakeLLM.call("attack", target="bear_9")))
    rig.agent.step()
    assert rig.companion_said() == ["I couldn't attack: unknown_target."]


def test_remember_and_start_goal(rig):
    rig.game.player_say("the lake is where we'll build. get me 2 logs")
    rig.controller_llm.push(FakeLLM.say(
        "Noted, getting logs.",
        FakeLLM.call("remember", key="place:build_site", value="lake"),
        FakeLLM.call("start_goal", goal="gather 2 logs and give them to Luis"),
    ))
    rig.planner_llm.push(FakeLLM.plan([
        {"skill": "gather", "args": {"resource": "log", "count": 2}},
        {"skill": "go_to", "args": {"target": "Luis"}},
        {"skill": "give", "args": {"player": "Luis", "item": "log", "count": 2}},
    ]))
    assert rig.agent.step() == "done"
    assert rig.store.notes() == {"place:build_site": "lake"}
    assert rig.game.players["Luis"].inventory["log"] == 2
    # notes reach the planner's bounded context
    assert "place:build_site" in rig.planner_llm.calls[0]["messages"][-1]["content"]


def test_invalid_controller_calls_are_dropped(rig):
    rig.game.player_say("teleport me")
    rig.controller_llm.push(FakeLLM.say("Can't do that one.", FakeLLM.call("teleport", to="x"),
                                        FakeLLM.call("gather", resource="log")))
    rig.agent.step()
    assert rig.companion_said() == ["Can't do that one."]
    assert [n for n, _ in rig.game.calls] == ["say"]  # no action reached the body


def _planner_rig(tmp_path, *responses, skills=None):
    rig = Rig(tmp_path, skills=skills)
    rig.planner_llm.push(*responses)
    return rig


def test_planner_repairs_unknown_skill(tmp_path):
    rig = _planner_rig(
        tmp_path,
        FakeLLM.plan([{"skill": "chop_tree", "args": {}}]),
        "```json\n" + FakeLLM.plan([{"skill": "gather", "args": {"resource": "log", "count": 1}}]).content + "\n```",
    )
    res = rig.planner.plan("get a log", {}, {})
    assert [t.skill for t in res.tasks] == ["gather"]
    assert "unknown skill 'chop_tree'" in rig.planner_llm.calls[1]["messages"][-1]["content"]


def test_planner_gives_up_after_repair(tmp_path):
    rig = _planner_rig(tmp_path, "not json at all", FakeLLM.plan([{"skill": "gather", "args": {"resource": "log"}}]))
    with pytest.raises(PlanError):
        rig.planner.plan("get a log", {}, {})


def test_planner_only_uses_registered_skills(tmp_path):
    rig = _planner_rig(tmp_path,
                       FakeLLM.plan([{"skill": "place", "args": {"blueprint": "storage_hut", "location": "lake"}}]),
                       FakeLLM.plan([], ask_help="I don't know how to build yet."),
                       skills=SkillRegistry(["go_to", "gather"]))
    res = rig.planner.plan("build a hut", {}, {})
    assert res.tasks == [] and res.ask_help
    system = rig.planner_llm.calls[0]["messages"][0]["content"]
    assert '"gather"' in system and '"place"' not in system


def test_task_tree_survives_restart(tmp_path):
    store = StateStore(tmp_path / "persist")
    store.set_goal("g", [Task(skill="gather", args={"resource": "log", "count": 1}, status="done"),
                         Task(skill="go_to", args={"target": "Luis"})])
    again = StateStore(tmp_path / "persist")
    assert again.tree.goal == "g" and again.tree.next_task().skill == "go_to"


def test_old_task_tree_with_done_key_loads(tmp_path):
    (tmp_path / "old").mkdir()
    (tmp_path / "old" / "task_tree.json").write_text(
        '{"goal": "g", "tasks": [{"skill": "stop", "done": true, "status": "done"}]}', encoding="utf-8")
    task = StateStore(tmp_path / "old").tree.tasks[0]
    assert task.done and task.status == "done"

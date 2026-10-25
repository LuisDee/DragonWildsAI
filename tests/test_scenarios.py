"""Section 8 executor/integration scenarios on the mock game, with scripted LLMs."""
import json

from brain.llm import FakeLLM

GIVE_GOAL = "gather 3 logs and 2 stone, then bring them to Luis"


def T(skill, **args):
    return {"skill": skill, "args": args}


def test_happy_path(rig):
    rig.planner_llm.push(FakeLLM.plan([
        T("gather", resource="log", count=3), T("gather", resource="stone", count=2),
        T("go_to", target="Luis"), T("give", player="Luis", item="log", count=3),
        T("give", player="Luis", item="stone", count=2),
    ]))
    assert rig.agent.run_goal(GIVE_GOAL) == "done"

    assert rig.game.players["Luis"].inventory == {"log": 3, "stone": 2}
    tree = rig.store.tree
    assert tree.status == "done" and all(t.done for t in tree.tasks) and tree.replans == 0
    assert not any(s.startswith("Done") for s in rig.companion_said())  # no canned "Done: ..." line
    assert json.loads(rig.controller_llm.calls[-1]["messages"][1]["content"])["body_event"]["type"] == "goal_done"
    # persisted and logged
    on_disk = json.loads(rig.store.tree_path.read_text())
    assert on_disk["status"] == "done" and all(t["done"] for t in on_disk["tasks"])
    kinds = {r["kind"] for r in rig.log.read_all()}
    assert {"prompt", "llm_response", "tool_call", "tool_result", "task_done"} <= kinds


def test_path_blocked_transient_is_retried(rig):
    rig.game.script_failure("go_to", "path_blocked", times=1)
    rig.planner_llm.push(FakeLLM.plan([T("go_to", target="lake")]))
    assert rig.agent.run_goal("go to the lake") == "done"
    assert rig.store.tree.tasks[0].attempts == 2
    assert len(rig.planner_llm.calls) == 1  # no replan needed


def test_path_blocked_persistent_caps_retries_replans_then_asks_for_help(rig):
    rig.game.script_failure("go_to", "path_blocked", times=None)
    rig.planner_llm.push(
        FakeLLM.plan([T("go_to", target="lake")]),
        FakeLLM.plan([T("go_to", target=[30, 20, 0])], explanation="direct path blocked, try a waypoint"),
        FakeLLM.plan([T("go_to", target="lake")], explanation="try again from the waypoint"),
    )
    assert rig.agent.run_goal("go to the lake") == "stuck"

    # retry cap: 3 attempts per plan, 3 plans (initial + max_replans=2), never more
    assert len(rig.calls("go_to")) == 9
    assert all(t.attempts == 3 for t in rig.store.tree.tasks)
    # DEPS replanning happened, and the failure was described to the planner
    assert len(rig.planner_llm.calls) == 3 and rig.store.tree.replans == 2
    replan_prompt = rig.planner_llm.calls[1]["messages"][-1]["content"]
    assert "path_blocked" in replan_prompt and "explanation" in replan_prompt
    # fails loudly
    assert rig.store.tree.status == "stuck"
    assert "stuck" in rig.companion_said()[-1] and "help" in rig.companion_said()[-1]


def test_resource_missing_replans_to_another_place(rig):
    rig.game.remove_nodes("stone", within=30)
    rig.planner_llm.push(
        FakeLLM.plan([T("gather", resource="stone", count=2)]),
        FakeLLM.plan([T("go_to", target="quarry"), T("gather", resource="stone", count=2)],
                     explanation="no rocks near camp; the quarry has stone"),
    )
    assert rig.agent.run_goal("get 2 stone") == "done"

    gathers = rig.calls("gather")
    assert len(gathers) == 2  # nothing_in_range is not retried blindly; it goes to the planner
    assert rig.game.inventory["stone"] == 2
    assert "nothing_in_range" in rig.planner_llm.calls[1]["messages"][-1]["content"]
    assert rig.store.tree.replans == 1


def test_interrupted_by_luis_stop(rig):
    rig.game.script_failure("gather", "interrupted", text="stop")
    rig.planner_llm.push(FakeLLM.plan([
        T("gather", resource="log", count=3), T("go_to", target="Luis"),
        T("give", player="Luis", item="log", count=3),
    ]))
    rig.controller_llm.push(FakeLLM.say("Okay, stopping.", FakeLLM.call("stop")))
    assert rig.agent.run_goal("bring Luis 3 logs") == "interrupted"

    assert rig.calls("stop") and not rig.calls("give")
    assert rig.store.tree.status == "interrupted"
    assert rig.companion_said() == ["Okay, stopping."]
    # the controller saw the command and that a goal was active
    ctx = json.loads(rig.controller_llm.calls[0]["messages"][-1]["content"])
    assert ctx["command"]["text"] == "stop" and ctx["active_goal"] == "bring Luis 3 logs"


def test_luis_chat_does_not_interrupt(rig):
    rig.game.script_failure("gather", "interrupted", text="nice, keep going")
    rig.planner_llm.push(FakeLLM.plan([T("gather", resource="log", count=3)]))
    rig.controller_llm.push(FakeLLM.say("Will do!"))
    assert rig.agent.run_goal("gather 3 logs") == "done"
    assert rig.game.inventory["log"] == 3
    assert rig.store.tree.tasks[0].attempts == 1  # the interrupt did not use up a retry


def test_mid_task_attack_defends_then_resumes(rig):
    rig.game.script_failure("gather", "attacked")
    rig.planner_llm.push(FakeLLM.plan([
        T("gather", resource="log", count=4), T("go_to", target="Luis"),
        T("give", player="Luis", item="log", count=4),
    ]))
    assert rig.agent.run_goal("bring Luis 4 logs") == "done"

    wolf = rig.calls("attack")[0]["target"]
    assert not rig.game.entities[wolf].alive
    assert [c["count"] for c in rig.calls("gather")] == [4, 2]  # resumed with the remainder
    assert rig.game.players["Luis"].inventory["log"] == 4
    assert rig.store.tree.tasks[0].attempts == 1
    # self-defence is a reflex: the only model call is the finished goal (goal_done), none for the fight
    events = [json.loads(c["messages"][1]["content"]).get("body_event", {}).get("type") for c in rig.controller_llm.calls]
    assert events == ["goal_done"]


def test_unverified_success_is_not_trusted(rig):
    rig.game.script_failure("gather", "lie", times=None)
    rig.planner_llm.push(
        FakeLLM.plan([T("gather", resource="log", count=2)]),
        FakeLLM.plan([], ask_help="My gathering isn't working. Can you check on me?"),
    )
    assert rig.agent.run_goal("gather 2 logs") == "stuck"
    assert len(rig.calls("gather")) == 3  # retry cap holds
    assert rig.store.tree.tasks[0].last_reason.startswith("verification_failed")
    assert "Can you check on me?" in rig.companion_said()[-1]

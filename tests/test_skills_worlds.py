"""Skill library (learn after verified goals, retrieve, run_skill, stats, chat commands), per-world
memory (world id, migration, places, rule snapshots), live progress over the bridge, and the LLM
adapter's multi-turn replay (thinking blocks) and prompt caching."""
import json
import time
import types

import pytest
from conftest import Rig

from brain import worlds
from brain.bridge_client import BridgeClient
from brain.fake_body import FakeBody
from brain.jsonl_log import JsonlLogger
from brain.llm import FakeLLM, LiteLLMClient, LLMResponse, ToolCall, assistant_message, with_cache_control
from brain.mock import MockGame
from brain.run_live import LiveOptions, LiveSession
from brain.dry_run_llm import DryRunController, DryRunPlanner
from brain.skill_library import SkillLibrary, SkillRecord, check_preconditions
from brain.state_store import SkillRegistry, StateStore, Task
from brain.transport import file_transport_pair

DELIVER = {
    "name": "deliver_resource", "description": "Gather some of a resource and hand it to a player.",
    "params": {"resource": {"type": "str", "description": "gather resource, e.g. log"},
               "count": {"type": "int", "description": "how many"},
               "player": {"type": "str", "description": "who gets it"}},
    "steps": [{"skill": "gather", "args": {"resource": "$resource", "count": "$count"}},
              {"skill": "go_to", "args": {"target": "$player"}},
              {"skill": "give", "args": {"player": "$player", "item": "$resource", "count": "$count"}}],
    "preconditions": [{"player_present": "$player"}],
    "postcondition": None,
    "example_params": {"resource": "log", "count": 3, "player": "Luis"},
}
PLAN = [{"skill": "gather", "args": {"resource": "log", "count": 3}}, {"skill": "go_to", "args": {"target": "Luis"}},
        {"skill": "give", "args": {"player": "Luis", "item": "log", "count": 3}}]


def learn_rig(tmp_path) -> Rig:
    rig = Rig(tmp_path, library=True)
    rig.planner_llm.push(FakeLLM.plan(PLAN), json.dumps(DELIVER))
    assert rig.agent.run_goal("get 3 logs and bring them to me") == "done"
    return rig


# --------------------------------------------------------------------------- learning


def test_verified_goal_becomes_a_readable_skill_file(tmp_path):
    rig = learn_rig(tmp_path)
    f = tmp_path / "skills" / "deliver_resource.json"
    rec = json.loads(f.read_text(encoding="utf-8"))
    assert rec["steps"][0] == {"skill": "gather", "args": {"resource": "$resource", "count": "$count"}, "repeat": 1}
    assert rec["stats"]["runs"] == 1 and rec["stats"]["ok"] == 1
    assert rec["origin"]["goal"] == "get 3 logs and bring them to me"
    assert rig.companion_said()[-1] == "I'll remember how to do that next time (deliver_resource)."
    learner = rig.planner_llm.calls[1]["messages"]
    assert "verified_steps" in learner[1]["content"] and '"give"' in learner[0]["content"]


def test_unfaithful_generalisation_is_not_saved(tmp_path):
    rig = Rig(tmp_path, library=True)
    wrong = {**DELIVER, "example_params": {"resource": "stone", "count": 3, "player": "Luis"}}
    rig.planner_llm.push(FakeLLM.plan(PLAN), json.dumps(wrong), json.dumps(wrong))
    assert rig.agent.run_goal("get 3 logs and bring them to me") == "done"
    assert rig.library.names() == [] and not list((tmp_path / "skills").glob("*.json"))
    assert "Invalid: expanding with example_params" in rig.planner_llm.calls[2]["messages"][-1]["content"]


def test_failed_goal_is_never_learned(tmp_path):
    rig = Rig(tmp_path, library=True)
    rig.game.remove_nodes("log")
    rig.planner_llm.push(FakeLLM.plan(PLAN), FakeLLM.plan([], ask_help="No trees?"))
    assert rig.agent.run_goal("get 3 logs and bring them to me") == "stuck"
    assert rig.library.names() == [] and len(rig.planner_llm.calls) == 2


def test_single_step_goals_are_not_learned(tmp_path):
    rig = Rig(tmp_path, library=True)
    rig.planner_llm.push(FakeLLM.plan([{"skill": "go_to", "args": {"target": "lake"}}]))
    assert rig.agent.run_goal("go to the lake") == "done"
    assert len(rig.planner_llm.calls) == 1


# --------------------------------------------------------------------------- using a skill


def test_run_skill_next_time_needs_no_planner(tmp_path):
    rig = learn_rig(tmp_path)
    planner_calls = len(rig.planner_llm.calls)
    rig.game.player_say("bring me 2 stone")
    rig.controller_llm.push(FakeLLM.say("On it.", ToolCall("run_skill", {"name": "deliver_resource", "params": {"resource": "stone", "count": 2, "player": "Luis"}})))
    assert rig.agent.step() == "done"
    assert len(rig.planner_llm.calls) == planner_calls  # zero Sonnet calls
    assert rig.game.players["Luis"].inventory["stone"] == 2
    ctx = json.loads(rig.controller_llm.calls[0]["messages"][1]["content"])
    assert ctx["learned_skills"][0]["name"] == "deliver_resource"  # retrieved into the context
    st = rig.library.get("deliver_resource").stats
    assert (st.runs, st.ok) == (2, 2) and st.avg_s is not None


def test_run_skill_failure_updates_stats_and_suspect_hides_it(tmp_path):
    rig = learn_rig(tmp_path)
    rig.game.remove_nodes("stone")
    for _ in range(3):
        rig.game.player_say("bring me 2 stone")
        rig.controller_llm.push(FakeLLM.say("On it.", ToolCall("run_skill", {"name": "deliver_resource", "params": {"resource": "stone", "count": 2, "player": "Luis"}})))
        rig.planner_llm.push(FakeLLM.plan([], ask_help="No rocks here?"))
        assert rig.agent.step() == "stuck"
    st = rig.library.get("deliver_resource").stats
    assert (st.runs, st.ok, st.failed) == (4, 1, 3) and st.suspect and st.last_reason == "nothing_in_range"
    assert rig.library.retrieve("bring me stone") == []  # suspect skills are not offered


def test_run_skill_checks_params_and_preconditions(tmp_path):
    rig = learn_rig(tmp_path)
    rig.game.player_say("bring Bob 2 stone")
    rig.controller_llm.push(FakeLLM.say("On it.", ToolCall("run_skill", {"name": "deliver_resource", "params": {"resource": "stone", "count": 2, "player": "Bob"}})))
    assert rig.agent.step() is None
    assert rig.companion_said()[-1] == "Sorry, I couldn't run that skill: I can't see Bob."
    rig.game.player_say("do the thing")
    rig.controller_llm.push(FakeLLM.say("Okay.", ToolCall("run_skill", {"name": "dance", "params": {}})))
    rig.agent.step()
    assert rig.companion_said()[-1] == "I haven't learned a skill called dance."


def test_what_have_you_learned_and_forget(tmp_path):
    """Review H3: no regex routes "what have you learned" / "forget X" around the model any more.
    The model reads list_skills and chooses forget_skill (exact name); "forget the wolf, follow me"
    deletes nothing and the follow happens."""
    rig = learn_rig(tmp_path)
    calls = len(rig.controller_llm.calls)
    rig.game.player_say("forget the wolf, follow me")
    rig.controller_llm.push(FakeLLM.say("Right behind you.", FakeLLM.call("follow", player="Luis")))
    rig.agent.step()
    assert (tmp_path / "skills" / "deliver_resource.json").exists() and rig.game.following == "Luis"
    rig.game.player_say("what have you learned?")
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("list_skills")),
                            FakeLLM.say("I've learned one skill: deliver_resource."))
    rig.agent.step()
    listed = json.loads(next(m for m in rig.controller_llm.calls[-1]["messages"] if m["role"] == "tool")["content"])
    assert listed["data"]["skills"] == [{"name": "deliver_resource", "ok": 1, "runs": 1}]
    assert rig.companion_said()[-1] == "I've learned one skill: deliver_resource."
    rig.game.player_say("forget deliver resource")
    rig.controller_llm.push(FakeLLM.say("Forgotten.", ToolCall("forget_skill", {"name": "deliver_resource"})))
    rig.agent.step()
    assert rig.companion_said()[-1] == "Forgotten."
    assert not (tmp_path / "skills" / "deliver_resource.json").exists()
    assert len(rig.controller_llm.calls) == calls + 5  # + the L5 check turn after the talk-only list reply


def test_retrieval_is_bm25_with_stemming(tmp_path):
    lib = SkillLibrary(tmp_path)
    for name, desc in [("chop_and_bring", "Chop trees for logs and bring them to a player."),
                       ("mine_stone", "Mine rocks for stone."),
                       ("guard_camp", "Stand guard at camp and attack anything hostile.")]:
        lib.save(SkillRecord(name=name, description=desc, steps=[{"skill": "stop"}]))
    assert lib.retrieve("go chopping some logs")[0].name == "chop_and_bring"
    assert lib.retrieve("mining")[0].name == "mine_stone"
    assert lib.retrieve("hello there") == []
    assert len(lib.retrieve("logs stone camp", k=3)) == 3


def test_expand_repeat_products_and_composition(tmp_path):
    lib = SkillLibrary(tmp_path)
    reg = SkillRegistry()
    lib.save(SkillRecord(name="stack_gather", description="Gather stacks.",
                         params={"resource": {"type": "str"}, "stacks": {"type": "int"}, "size": {"type": "int"}},
                         steps=[{"skill": "gather", "args": {"resource": "$resource", "count": "$size"},
                                 "repeat": "$stacks"},
                                {"skill": "drop", "args": {"item": "$resource", "count": "$stacks*$size"}}]))
    lib.save(SkillRecord(name="stacks_to_luis", description="Stacks to Luis.", params={"r": {"type": "str"}},
                         steps=[{"skill": "stack_gather", "args": {"resource": "$r", "stacks": 2, "size": 5}},
                                {"skill": "go_to", "args": {"target": "Luis"}}]))
    tasks = lib.expand("stacks_to_luis", {"r": "oak"}, reg)
    assert [t.skill for t in tasks] == ["gather", "gather", "drop", "go_to"]
    assert tasks[2].args["count"] == 10 and tasks[0].args == {"resource": "oak", "count": 5, "radius": None}
    with pytest.raises(ValueError):
        lib.expand("stacks_to_luis", {}, reg)  # missing param


def test_preconditions_against_state():
    rec = SkillRecord(name="hand_over", description="x", params={"item": {"type": "str"}, "n": {"type": "int"}},
                      steps=[{"skill": "stop"}], preconditions=[{"has_item": "$item", "count": "$n"}, {"holding": "axe"}])
    state = {"inventory": {"ITEM_Resources_Wood_Oak": 8},
             "inventory_items": [{"item": "ITEM_Resources_Wood_Oak", "name": "Oak Logs"}],
             "gear": {"right": "/x/ITEM_Logging_Axe_Adamant.ITEM_Logging_Axe_Adamant"}}
    assert check_preconditions(rec, {"item": "oak logs", "n": 5}, state) == []
    assert check_preconditions(rec, {"item": "oak logs", "n": 9}, state) == ["I need 9 oak logs and have 8"]


# --------------------------------------------------------------------------- per-world memory


def test_world_guid_sources(monkeypatch):
    monkeypatch.delenv(worlds.ENV, raising=False)
    g = MockGame.default_world()
    assert worlds.resolve_world_guid(g) == ("default", "default")
    monkeypatch.setenv(worlds.ENV, "ENVGUID")
    assert worlds.resolve_world_guid(g) == ("ENVGUID", "env")
    g.world_guid = "EE0ADF284F2591BC344C6AA8A1FE985C"
    assert worlds.resolve_world_guid(g) == ("EE0ADF284F2591BC344C6AA8A1FE985C", "world_info")
    assert worlds.resolve_world_guid(g, {"world": {"guid": "../evil guid"}}) == ("evilguid", "state")


def test_legacy_files_migrate_and_default_is_adopted(tmp_path):
    root = tmp_path / "state"
    root.mkdir()
    (root / "notes.json").write_text('{"pref:axe": "adamant"}', encoding="utf-8")
    (root / "bot_state.json").write_text("{}", encoding="utf-8")  # the body's file: never touched
    d, moved = worlds.prepare_state_dir(root, "default")
    assert moved == ["notes.json"] and StateStore(d).notes() == {"pref:axe": "adamant"}
    assert (root / "bot_state.json").exists() and not (root / "notes.json").exists()
    StateStore(d).remember_place("farm", [1.0, 2.0, 3.0])
    d2, moved2 = worlds.prepare_state_dir(root, "ABC123")  # the body can name its world now
    assert d2 == root / "worlds" / "ABC123" and "default/places.json" in moved2
    assert StateStore(d2).place_position("Farm") == [1.0, 2.0, 3.0]
    assert not (root / "worlds" / "default").exists()
    d3, _ = worlds.prepare_state_dir(root, "OTHER")  # another world starts empty
    assert StateStore(d3).notes() == {}


def test_remember_place_here_then_go_there(rig):
    rig.game.pos = [5.0, 5.0, 0.0]
    rig.game.player_say("remember this spot as the farm")
    rig.controller_llm.push(FakeLLM.say("Noted, this is the farm.",
                                        FakeLLM.call("remember", key="place:farm", value="the farm", at="self")))
    rig.agent.step()
    assert rig.store.place_position("farm") == [5.0, 5.0, 0.0]
    rig.game.pos = [0.0, 0.0, 0.0]
    rig.game.player_say("go to the farm")
    rig.controller_llm.push(FakeLLM.say("Heading to the farm.", FakeLLM.call("go_to", target="farm")))
    rig.agent.step()
    assert rig.calls("go_to")[-1] == {"target": [5.0, 5.0, 0.0]} and rig.game.pos == [5.0, 5.0, 0.0]
    ctx = json.loads(rig.controller_llm.calls[1]["messages"][1]["content"])
    assert any("farm" in line for line in ctx["situation"] if line.startswith("Places"))


def test_reflex_rules_snapshot_per_world(rig):
    rig.game.player_say("every time the kalphite raises its claws, windstep away")
    rig.controller_llm.push(FakeLLM.say("Got it.", FakeLLM.call(
        "set_reflex_rule", enemy="kalphite", trigger={"kind": "telegraph"},
        actions=[{"kind": "evade"}, {"kind": "cast", "spell": "Windstep", "target": "self"}])))
    rig.agent.step()
    assert [r["enemy"] for r in rig.store.saved_rules()] == ["kalphite"]


def test_live_session_uses_the_world_folders(tmp_path):
    _, body_t = file_transport_pair(tmp_path / "bridge_io")
    game = MockGame.default_world()
    game.world_guid = "W0RLD"
    body = FakeBody(game, body_t).start()
    try:
        opts = LiveOptions(bridge_dir=tmp_path / "bridge_io", state_dir=tmp_path / "state", log_dir=tmp_path / "logs",
                           dry_run=True, wait=5.0, probe_timeout=1.0)
        out: list[str] = []
        s = LiveSession(opts, DryRunController(), DryRunPlanner(), out=out.append)
        assert s.world == "W0RLD" and s.store.dir == tmp_path / "state" / "worlds" / "W0RLD"
        assert s.skills.dir == tmp_path / "state" / "skills" / "W0RLD"
        assert "world        : W0RLD" in "\n".join(out) and s.controller.can_look
    finally:
        body.stop()


# --------------------------------------------------------------------------- live progress over the bridge


def test_progress_is_spoken_while_the_gather_is_still_running(tmp_path):
    """The body emits gather_progress mid-action; the brain says a line through a nested say
    request and still receives the gather's own result (re-entrant bridge client)."""
    brain_t, body_t = file_transport_pair(tmp_path / "bridge_io")
    game = MockGame.default_world()
    body = FakeBody(game, body_t, progress_delay=0.15).start()  # a real gather takes minutes
    try:
        client = BridgeClient(brain_t, JsonlLogger(tmp_path / "b.jsonl"), default_timeout=5.0)
        rig = Rig(tmp_path, game=client)
        ticks = iter(range(0, 10_000, 30))
        rig.controller.clock = lambda: next(ticks)  # 30 s between updates: never throttled
        rig.planner_llm.push(FakeLLM.plan([{"skill": "gather", "args": {"resource": "log", "count": 8}}]))
        assert rig.agent.run_goal("gather 8 logs") == "done"
        lines = [t for who, t in game.chat if who == "companion"]
        assert lines[0] == "Gathering: 5/8 log so far." and lines[-1] == "Done: gather 8 logs."
        assert game.inventory["log"] == 8
        kinds = [r["kind"] for r in rig.log.read_all()]
        assert "bridge_unmatched" not in kinds
    finally:
        body.stop()


# --------------------------------------------------------------------------- LLM adapter


def test_assistant_replay_keeps_thinking_blocks_and_caches_the_system_prompt(monkeypatch):
    seen = {}

    def completion(model, messages, **params):
        seen.update(model=model, messages=messages, params=params)
        tc = types.SimpleNamespace(id="toolu_1", function=types.SimpleNamespace(name="look", arguments='{"about":"sticks"}'))
        msg = types.SimpleNamespace(content="", tool_calls=[tc],
                                    thinking_blocks=[{"type": "thinking", "thinking": "", "signature": "sig"}])
        usage = types.SimpleNamespace(prompt_tokens=900, completion_tokens=20,
                                      prompt_tokens_details=types.SimpleNamespace(cached_tokens=800),
                                      cache_creation_input_tokens=0)
        return types.SimpleNamespace(choices=[types.SimpleNamespace(message=msg)], usage=usage)

    import litellm
    monkeypatch.setattr(litellm, "completion", completion)
    resp = LiteLLMClient("anthropic/claude-haiku-5-5", max_tokens=1024).complete(
        [{"role": "system", "content": "persona"}, {"role": "user", "content": "{}"}], tools=[{"x": 1}])
    sys_msg = seen["messages"][0]
    assert sys_msg["content"][0]["cache_control"] == {"type": "ephemeral"}
    assert "parallel_tool_calls" not in seen["params"]  # ordered multi-step turns (PRINCIPLES 4b)
    assert resp.message["thinking_blocks"][0]["signature"] == "sig"
    assert resp.message["tool_calls"][0]["id"] == "toolu_1" and resp.usage["cached"] == 800
    assert assistant_message(resp) is resp.message


def test_fake_responses_get_replayable_messages():
    resp = LLMResponse(content="x", tool_calls=[ToolCall("look", {"about": "a"})])
    msg = assistant_message(resp)
    assert msg["tool_calls"][0]["id"] == resp.tool_calls[0].id and json.loads(msg["tool_calls"][0]["function"]["arguments"]) == {"about": "a"}
    assert with_cache_control([{"role": "user", "content": "u"}]) == [{"role": "user", "content": "u"}]

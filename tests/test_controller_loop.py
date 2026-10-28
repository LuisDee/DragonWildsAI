"""The Controller's bounded look-then-act loop, grounding in code, and the speech rules
(research 2026-10-25 sections 3.2, 6.2, 7.1; design section 19)."""
import json

from conftest import Rig

from brain.controller import MAX_SAY, NO_LOOK_RULE, clip
from brain.interface import BODY_TOOLS, Reason
from brain.llm import FakeLLM
from brain.mock import MockGame
from brain.situation import MAX_LINES, perceived, summary


def ctx(call: dict) -> dict:
    return json.loads(call["messages"][1]["content"])


def offered(call: dict) -> set[str]:
    return {t["function"]["name"] for t in call["tools"]}


# --------------------------------------------------------------------------- the sticks example


def test_sticks_absent_the_model_says_so(rig):
    """'pick up the sticks', only oak logs around: look finds no sticks and the MODEL says so. The look
    ran read-only and its result went back to the model as a tool message (PRINCIPLES.md #2: the code
    informs, the model decides)."""
    rig.game.add_ground_item("oak_log", 2, [1, 0, 0])
    rig.game.player_say("pick up the sticks")
    rig.controller_llm.push(
        FakeLLM.say("Let me look.", FakeLLM.call("look", about="sticks")),
        FakeLLM.say("I can't see any sticks here, only some Oak Logs."),
    )
    rig.agent.step()
    assert rig.calls("pickup") == [] and rig.game.inventory["oak_log"] == 0
    assert rig.companion_said() == ["I can't see any sticks here, only some Oak Logs."]
    assert len(rig.controller_llm.calls) == 3  # + the L5 check turn after a talk-only reply (none scripted)
    second = rig.controller_llm.calls[1]["messages"]
    assert second[-2]["role"] == "assistant" and second[-2]["tool_calls"][0]["function"]["name"] == "look"
    tool_msg = next(m for m in second if m["role"] == "tool")
    assert tool_msg["tool_call_id"] == second[-2]["tool_calls"][0]["id"]
    assert json.loads(tool_msg["content"])["data"]["matched"] is False


def test_code_never_vetoes_the_models_choice(rig):
    """Live 2026-10-25: "here man pick these runes up" -> the model's correct pickup was vetoed by a
    code check on the player's words ("I can't see any man runes"). The model's call now reaches the
    body exactly as the model made it, whatever the words were."""
    rig.game.add_ground_item("oak_log", 2, [1, 0, 0])
    rig.game.player_say("here man pick these sticks up dsgrab smh")
    rig.controller_llm.push(FakeLLM.say("Got them.", FakeLLM.call("pickup", target="nearest", item="oak")))
    rig.agent.step()
    assert rig.calls("pickup") == [{"target": "nearest", "item": "oak", "limit": 1}]
    assert rig.game.inventory["oak_log"] == 2 and rig.companion_said() == ["Got them."]


def test_failed_pickup_result_goes_back_to_the_model(rig):
    """The body reports the outcome truthfully; the model gets it and decides what to say (or asks)."""
    rig.game.add_ground_item("oak_log", 2, [1, 0, 0])
    rig.game.player_say("pick up the sticks")
    rig.controller_llm.push(FakeLLM.say("On it.", FakeLLM.call("pickup", target="nearest", item="sticks")),
                            FakeLLM.say("There are no sticks here, only Oak Logs. Want those instead?"))
    rig.agent.step()
    assert rig.calls("pickup") == [{"target": "nearest", "item": "sticks", "limit": 1}]
    assert rig.game.inventory["oak_log"] == 0
    follow = rig.controller_llm.calls[1]["messages"]
    result = json.loads(next(m for m in reversed(follow) if m["role"] == "tool")["content"])
    assert result["ok"] is False and result["reason"]
    assert rig.companion_said() == ["There are no sticks here, only Oak Logs. Want those instead?"]


def test_sticks_present_look_then_interact(rig):
    sticks = rig.game.add_gatherable("Ash Branch", "stick", [4, 2, 0], count=2)
    # Sticks are foliage-like: not in get_state, not in the digest.
    assert not any("Ash Branch" in line for line in summary(rig.game.get_state()["data"]))
    rig.game.player_say("pick up the sticks")
    rig.controller_llm.push(
        FakeLLM.say("", FakeLLM.call("look", about="sticks")),
        FakeLLM.say("Grabbing those sticks.", FakeLLM.call("interact", target=sticks)),
    )
    rig.agent.step()
    assert rig.game.inventory["stick"] == 2 and sticks not in rig.game.gatherables
    assert rig.companion_said() == ["Grabbing those sticks."]
    # look + interact, then the agent loop's continuation turn (results back to the model; none scripted)
    assert [n for n, _ in rig.game.calls].count("look") == 1 and len(rig.controller_llm.calls) == 3
    assert rig.store.progress_path.read_text(encoding="utf-8").count("task interact done") == 1


def test_interact_on_an_unknown_id_reaches_the_body_and_its_answer_is_said(rig):
    rig.game.player_say("grab the berries")
    rig.controller_llm.push(FakeLLM.say("Sure.", FakeLLM.call("interact", target="bush_99")))
    rig.agent.step()  # no follow-up scripted: the model call fails, the truthful template still says why
    assert rig.calls("interact") == [{"target": "bush_99", "secondary": False}]
    assert rig.companion_said() and rig.companion_said()[0] != "Sure."


def test_unknown_word_answered_without_action(rig):
    rig.game.player_say("pick up the flurbs")
    rig.controller_llm.push(
        FakeLLM.say("", FakeLLM.call("look", about="flurbs")),
        FakeLLM.say(""),  # the model says nothing: the reply is still guaranteed
    )
    rig.agent.step()
    said = rig.companion_said()
    assert len(said) == 1 and said[0].startswith("I can't see any flurbs around here")
    assert rig.calls("pickup") == [] and rig.calls("interact") == []


def test_body_without_look_offers_no_read_tools(tmp_path):
    tools = set(BODY_TOOLS) - {"look", "inspect", "interact"}
    rig = Rig(tmp_path, available_tools=tools)
    rig.game.player_say("pick up the sticks")
    rig.controller_llm.push(FakeLLM.say("I can't see any sticks around here."))
    rig.agent.step()
    call = rig.controller_llm.calls[0]
    assert not {"look", "inspect", "interact"} & offered(call)
    assert NO_LOOK_RULE in call["messages"][0]["content"]
    assert rig.companion_said() == ["I can't see any sticks around here."]


def test_at_most_three_model_calls_per_command(rig):
    rig.game.player_say("find me something shiny")
    rig.controller_llm.push(*[FakeLLM.say("hmm", FakeLLM.call("look", about="shiny"))] * 3)
    d = rig.controller.decide("Luis", "find me something shiny", rig.game.get_state()["data"], None)
    assert d.model_calls == 3 and not d.actions
    assert "Last step" in rig.controller_llm.calls[2]["messages"][-1]["content"]
    assert [n for n, _ in rig.game.calls].count("look") == 2  # the third look is never run


def test_look_does_not_interrupt_the_active_job(rig):
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("look", about="wolf")),
                            FakeLLM.say("No wolves near us."))
    d = rig.controller.decide("Luis", "any wolves around?", rig.game.get_state()["data"], "gather 10 logs")
    assert not d.interrupts and d.speech == "No wolves near us."


# --------------------------------------------------------------------------- grounding of names


def test_attack_args_are_never_rewritten(rig):
    wolf = rig.game.add_entity("wolf", [5, 0, 0], hp=20, hostile=True)
    rig.game.player_say("kill that wolf")
    rig.controller_llm.push(FakeLLM.say("Going for it.", FakeLLM.call("attack", target=wolf)))
    rig.agent.step()
    assert rig.calls("attack") == [{"target": wolf}] and not rig.game.entities[wolf].alive


def test_attacking_a_player_is_refused_by_the_safety_rule(rig):
    """The only code gate on the model's calls: Luis's explicit safety rules (never attack a player)."""
    rig.game.player_say("attack me")
    rig.controller_llm.push(FakeLLM.say("Here I come!", FakeLLM.call("attack", target="Luis")))
    rig.agent.step()
    assert rig.calls("attack") == [] and rig.companion_said() == ["That's not safe, so I won't."]


def test_give_what_it_does_not_carry_the_body_says_so(rig):
    rig.game.inventory["log"] = 3
    rig.game.player_say("give me 2 stone")
    rig.controller_llm.push(FakeLLM.say("Here.", FakeLLM.call("give", player="Luis", item="stone", count=2)),
                            FakeLLM.say("I don't have any stone on me, only 3 logs."))
    rig.agent.step()
    assert rig.calls("give") == [{"player": "Luis", "item": "stone", "count": 2}]
    assert rig.companion_said() == ["I don't have any stone on me, only 3 logs."]


def test_pickup_of_a_perceived_item_by_name_works(rig):
    rig.game.add_ground_item("oak_log", 4, [2, 0, 0])
    rig.game.player_say("pick up the oak logs")
    rig.controller_llm.push(FakeLLM.say("Got them.", FakeLLM.call("pickup", target="nearest", item="oak")))
    rig.agent.step()
    assert rig.game.inventory["oak_log"] == 4 and rig.companion_said() == ["Got them."]


# --------------------------------------------------------------------------- the situation digest


REAL_STATE = {  # shape of a live get_state reply (build 26161880, logs/brain-live-20261025-160711)
    "health": 0.5, "max_health": 0.0, "position": [110.45, 1820.9, -30.81], "action": None, "following": None,
    "gear": {"right": "/UmbralSands/Gameplay/Character/Player/Equipment/Held/Hatchet/"
                      "ITEM_Logging_Axe_Adamant.ITEM_Logging_Axe_Adamant"},
    "inventory": {"ITEM_Resources_Wood_Oak": 8},
    "inventory_items": [{"equipped": "right", "count": 1, "item": "ITEM_Logging_Axe_Adamant", "id": "i2"},
                        {"name": "Oak Logs", "count": 8, "item": "ITEM_Resources_Wood_Oak", "id": "i7"}],
    "nearby_items": [], "nearby_resources": [], "structures": [], "places": [],
    "not_implemented": ["nearby_resources", "structures", "places"],
    "nearby_entities": [
        {"id": "BP_AI_Kebbit_Character_02_C_2147479901", "kind": "kebbit_character_02", "distance": 36.98,
         "alive": True, "hp": 39.0, "hostile": None, "position": [0, 0, 0]},
        {"id": "BP_AI_Kebbit_Character_02_C_2147479838", "kind": "kebbit_character_02", "distance": 47.4,
         "alive": True, "hp": 39.0, "hostile": None, "position": [0, 0, 0]}],
    "players": [{"name": "Zezima", "player_id": 256, "distance": 7.7, "position": [0, 0, 0]}],
    "puppet": {"controller": "AIController /Game/Maps/World/L_World..."},
}


def test_situation_from_real_state_uses_game_names_and_no_internals():
    lines = summary(REAL_STATE)
    text = "\n".join(lines)
    assert len(lines) <= MAX_LINES
    assert lines[0] == "You: health: hurt [50%], holding Adamant Logging Axe"
    assert "Carrying: Oak Logs x8" in text and "Players: Zezima 8 m" in text
    assert "Kebbit x2 (37 m, id BP_AI_Kebbit_Character_02_C_2147479901, HP 39)" in text  # nearest one's health
    assert "AIController" not in text and "not_implemented" not in text
    assert "cannot perceive trees" in text  # this body has no look and no surroundings yet


def test_situation_uses_the_body_surroundings_digest():
    state = {**REAL_STATE, "surroundings": [{"name": "Oak Tree", "kind": "tree", "count": 14, "nearest_m": 6.2,
                                             "gives": ["Oak Logs"]}]}
    text = "\n".join(summary(state))
    assert "Around: Oak Tree x14 (6 m)" in text and "cannot perceive" not in text
    assert [t.name for t in perceived(state) if t.kind == "tree"] == ["Oak Tree"]


def test_controller_context_is_bounded(rig):
    rig.controller_llm.push(FakeLLM.say("hi"))
    rig.controller.decide("Luis", "hello", rig.game.get_state()["data"], None)
    c = ctx(rig.controller_llm.calls[0])
    assert "state" not in c and len(c["situation"]) <= MAX_LINES
    assert set(c) >= {"command", "situation", "active_goal", "notes", "learned_skills", "castable_spells",
                      "reflex_rules", "recent_events"}
    assert {"look", "inspect", "interact", "run_skill", "start_goal"} <= offered(rig.controller_llm.calls[0])


# --------------------------------------------------------------------------- speech


def test_the_action_is_the_answer_and_no_canned_lines(rig):
    """Voice workstream (Luis: no stock lines): an action, a started goal or a refusal is the answer;
    only when nothing at all happened does he say he didn't catch it."""
    rig.game.player_say("follow me")
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("follow", player="Luis")))
    rig.agent.step()
    assert rig.game.following == "Luis" and rig.companion_said() == []
    rig.game.player_say("gather 5 logs and bring them")
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("start_goal", goal="gather 5 logs")))
    rig.planner_llm.push(FakeLLM.plan([], ask_help="no"))
    rig.agent.step()
    assert not any(s.startswith("On it") for s in rig.companion_said())
    assert rig.companion_said() and rig.companion_said()[-1].startswith("I'm stuck on")  # stuck is always told
    n = len(rig.companion_said())
    rig.game.player_say("hmm")
    rig.controller_llm.push(FakeLLM.say(""))
    rig.agent.step()
    assert rig.companion_said()[n:] == ["Sorry, I didn't catch that."]


def test_speech_is_one_chat_line():
    long = "word " * 80
    assert len(clip(long)) <= MAX_SAY and clip(long).endswith("…")
    assert clip("  short \n line ") == "short line"


def test_cant_do_says_why(rig):
    rig.game.script_failure("go_to", "not_implemented", times=None)
    rig.game.player_say("come here")
    rig.controller_llm.push(FakeLLM.say("Coming!", FakeLLM.call("go_to", target="Luis")))
    rig.agent.step()
    # a walk's line is said as it starts (true then, never stale after arriving: live 21:43); the
    # failure that follows says why
    assert rig.companion_said() == ["Coming!", "Sorry, I can't walk somewhere yet."]


def _gather_world() -> MockGame:
    g = MockGame()
    g.players["Luis"] = __import__("brain.mock.game", fromlist=["Player"]).Player("Luis", [1.0, 0.0, 0.0])
    for x in range(6):
        g.add_node("log", [3.0 + x, 0, 0], 5)
    return g


def test_progress_is_noted_for_body_status_not_said(tmp_path):
    """Voice workstream: doing the job needs no commentary. Progress goes to body_status ("how's it
    going?" is answerable); nothing canned is said, the finish is the model's call (goal_done)."""
    rig = Rig(tmp_path, game=_gather_world())
    rig.controller.clock = lambda: rig.game.time  # simulated seconds
    rig.planner_llm.push(FakeLLM.plan([{"skill": "gather", "args": {"resource": "log", "count": 30}}]))
    assert rig.agent.run_goal("gather 30 logs") == "done"
    assert not any(s.startswith(("Gathering", "Done")) for s in rig.companion_said())
    assert any(r["kind"] == "progress" for r in rig.log.read_all())
    assert any(line.startswith("Job progress") for line in rig.agent.broker.digest())
    goal_done = [json.loads(c["messages"][1]["content"]) for c in rig.controller_llm.calls]
    assert goal_done and goal_done[-1]["body_event"] == {"type": "goal_done", "goal": "gather 30 logs", "steps": 1}


def _said_at(rig):
    return list(zip(rig.game.chat_times, rig.companion_said()))


def test_milestones_are_noted_not_said(tmp_path):
    rig = Rig(tmp_path, game=_gather_world())
    rig.controller.clock = lambda: rig.game.time
    rig.planner_llm.push(FakeLLM.plan([{"skill": "gather", "args": {"resource": "log", "count": 2}},
                                       {"skill": "go_to", "args": {"target": "Luis"}},
                                       {"skill": "give", "args": {"player": "Luis", "item": "log", "count": 2}}]))
    assert rig.agent.run_goal("bring Luis 2 logs") == "done"
    assert not any("Step " in s for s in rig.companion_said())
    assert any(line.startswith("Job progress") and "step 3/3 done" in line for line in rig.agent.broker.digest())


def test_stuck_asks_for_help_in_one_line(rig):
    rig.planner_llm.push(FakeLLM.plan([{"skill": "gather", "args": {"resource": "gold", "count": 1}}]),
                         FakeLLM.plan([], ask_help="Where can I find gold?"))
    assert rig.agent.run_goal("get gold") == "stuck"
    last = rig.companion_said()[-1]
    assert "stuck" in last and "Where can I find gold?" in last and len(last) <= MAX_SAY
    assert Reason.NOTHING_IN_RANGE.replace("_", " ") in last or "nothing" in last


# --------------------------------------------------------------------------- the real body's look shape


class BodyShapedLook(MockGame):
    """look answers exactly like mod/body/gather.lua h_look + sense.look (ranked, match scores, no 'matched')."""

    def __init__(self, things):
        super().__init__()
        self._look_things = things

    def look(self, about=None, radius=20.0, max=15):
        self.calls.append(("look", {"about": about, "radius": radius, "max": max}))
        return {"ok": True, "reason": None, "data": {"origin": [0, 0, 0], "radius_m": radius, "about": about,
                                                     "total": len(self._look_things), "things": self._look_things}}


def test_body_look_shape_absent_and_present(tmp_path):
    logs = {"id": "BP_RuntimeSpawnedWorldItem_C_1", "class": "BP_RuntimeSpawnedWorldItem_C", "name": "Oak Logs",
            "item": "/Game/Items/ITEM_Resources_Wood_Oak", "count": 2, "kind": "item", "verb": "pickup",
            "distance": 1.2, "match": 0}
    tree = {"id": "BP_Tree_Oak_C_7", "class": "BP_Tree_Oak_C", "name": "Tree Oak (Oak Logs)", "kind": "resource",
            "verb": "chop", "drops": "Oak Logs", "distance": 6.0, "match": 0}
    game = BodyShapedLook([logs, tree])
    game.players["Luis"] = __import__("brain.mock.game", fromlist=["Player"]).Player("Luis", [1.0, 0.0, 0.0])
    rig = Rig(tmp_path, game=game)
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("look", about="sticks")),
                            FakeLLM.say("On it.", FakeLLM.call("pickup", target="BP_RuntimeSpawnedWorldItem_C_1")))
    d = rig.controller.decide("Luis", "pick up the sticks", game.get_state()["data"], None)
    # the model's choice stands (no veto); the look's "matched: false" was stated plainly to it
    assert [a.name for a in d.actions] == ["pickup"] and not d.refusals
    tool_msg = json.loads(next(m for m in rig.controller_llm.calls[1]["messages"] if m["role"] == "tool")["content"])
    assert tool_msg["data"]["matched"] is False  # stated plainly for the model

    branch = {"id": "BP_Spawner_AshBranch_C_3", "class": "BP_Spawner_AshBranch_C", "name": "Stick",
              "item": "/Game/Items/ITEM_Resources_Stick", "kind": "gatherable", "verb": "gather",
              "prompt": "Gather", "distance": 4.2, "match": 1}
    game._look_things = [branch, logs, tree]
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("look", about="sticks")),
                            FakeLLM.say("Grabbing those sticks.", FakeLLM.call("interact", target="BP_Spawner_AshBranch_C_3")))
    d = rig.controller.decide("Luis", "pick up the sticks", game.get_state()["data"], None)
    assert [a.name for a in d.actions] == ["interact"] and not d.refusals


def test_direct_gather_says_its_line_as_it_starts_and_nothing_canned(tmp_path):
    rig = Rig(tmp_path, game=_gather_world())
    rig.controller.clock = lambda: rig.game.time
    rig.game.player_say("chop some oak, 20 logs")
    rig.controller_llm.push(FakeLLM.say("Chopping 20 oak logs.", FakeLLM.call("gather", resource="log", count=20)))
    rig.agent.step()
    said = rig.companion_said()
    assert said == ["Chopping 20 oak logs."]  # said when the job starts; no "Gathering:"/"Done, gathered" lines
    assert rig.game.inventory["log"] == 20
    assert "gather" in offered(rig.controller_llm.calls[0])


def test_direct_gather_failure_still_reports_why(rig):
    rig.game.player_say("mine some gold")
    rig.controller_llm.push(FakeLLM.say("Mining gold.", FakeLLM.call("gather", resource="gold", count=5)))
    rig.agent.step()
    assert rig.companion_said() == ["Mining gold.", "There's no gold anywhere near me."]


def test_continuation_observation_reaches_provider_after_failed_action(rig):
    read = rig.game.get_state
    reads = []
    def state():
        result = read()
        reads.append(1)
        if rig.calls("pickup"):
            result["data"].update(position=[4, 5, 6], health=0, hydration=12,
                inventory_read_status={"carried": {"status": "partial", "count_semantics": "lower_bound"}},
                inventory={"oak_log": 7},
                stations_nearby=[{"name": "Workshop", "id": "station-1", "distance": 7},
                                 {"name": "Other", "id": "z" * 81, "distance": 9}])
        return result
    rig.game.get_state = state
    rig.game.player_say("pick up missing things")
    rig.controller_llm.push(FakeLLM.say("", FakeLLM.call("pickup", target="nearest", item="missing")), FakeLLM.say(""))
    rig.agent.step()
    assert len(rig.controller_llm.calls) == 2
    messages = rig.controller_llm.calls[1]["messages"]
    initial = json.loads(messages[1]["content"])
    assert initial["command"]["text"] == "pick up missing things"
    result_index = next(i for i, m in enumerate(messages) if m.get("role") == "tool")
    assert json.loads(messages[result_index]["content"])["ok"] is False
    assert messages[result_index]["tool_call_id"]
    obs = json.loads(messages[result_index + 1]["content"].removeprefix("Current observation: "))
    assert obs["position"] == [4, 5, 6] and obs["vitals"]["health"] == 0
    assert obs["vitals"]["hydration"] == 12 and "carried partial" in obs["inventory_read"]
    assert obs["stations"]["rows"][0]["distance_m"] == 7
    assert "7" in obs["inventory"] and "at least" in obs["inventory"]
    assert obs["stations"]["rows"][1]["id"] is None and obs["stations"]["rows"][1]["id_truncated"] is True
    assert reads  # the normal state read supplied the observation


def test_continuation_observation_unknown_and_bounded():
    from brain.controller import continuation_observation
    for value in (None, {}, {"unavailable": "offline"}, "bad"):
        assert continuation_observation(value)["stations"]["status"] == "unknown"
    obs = continuation_observation({"position": [True, 0, float("nan")], "health": False,
        "hydration": float("inf"), "stations_nearby": [{"name": "x" * 1000, "distance": False}] * 9})
    assert obs["position"] is None and obs["vitals"]["health"] is None and obs["vitals"]["hydration"] is None
    assert obs["stations"]["status"] == "observed" and len(obs["stations"]["rows"]) == 6
    assert obs["stations"]["omitted"] == 3 and len(obs["stations"]["rows"][0]["name"]) == 80
    assert obs["stations"]["rows"][0]["name_truncated"] is True
    assert obs["stations"]["rows"][0]["distance_m"] is None
    assert continuation_observation({"stations_nearby": []})["stations"] == {"status": "observed", "rows": [], "omitted": 0}


def test_unavailable_observation_preserves_each_tool_result_id(rig):
    from brain.controller import Decision
    from brain.llm import ToolCall, assistant_message
    prior = FakeLLM.say("", ToolCall("go_to", {"target": "a"}, "first"),
                        ToolCall("go_to", {"target": "b"}, "second"))
    decision = Decision(messages=[{"role": "user", "content": "original request"}, assistant_message(prior)])
    rig.controller_llm.push(FakeLLM.say(""))
    game_calls_before = list(rig.game.calls)
    rig.controller.next_turn(decision, {"first": {"ok": False, "reason": "blocked"},
                                        "second": {"ok": True}}, {"unavailable": "offline"}, failed=True)
    assert len(rig.controller_llm.calls) == 1 and rig.game.calls == game_calls_before
    messages = rig.controller_llm.calls[0]["messages"]
    results = [m for m in messages if m.get("role") == "tool"]
    assert [m["tool_call_id"] for m in results] == ["first", "second"]
    assert json.loads(results[0]["content"])["reason"] == "blocked" and json.loads(results[1]["content"])["ok"] is True
    observation = next(m for m in messages if isinstance(m.get("content"), str) and m["content"].startswith("Current observation: "))
    assert json.loads(observation["content"].removeprefix("Current observation: "))["status"] == "unavailable"
    assert messages[0]["content"] == "original request"

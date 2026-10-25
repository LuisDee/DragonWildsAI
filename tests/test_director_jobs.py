"""Director wave 4: the five GOAL T3 jobs and the must-not-fake jobs, end to end on GearWorld (catalog-driven mock),
with the REAL Agent, Controller, executor and the applied hooks (docs/design/director.md section 7, review H12).

The models are scripted (no API calls): the Director's decisions are FakeLLM JSON; the Controller's turns come
from a small policy that carries out each board step's planned calls (written by the scripted Director into the
step's hints as {"do": [...]}) and voices notices. That convention lives only in these tests. What is real: tool
dispatch and validation, execution against the mock, verification, segments, tallies, gaps, the success tests
(brain/predicates.py, the same format as the benchmark's evals/bench goal cases) and every board rule.
"""
import json


from brain import predicates as P
from brain.llm import LLMResponse, ToolCall
from brain.mock.gear_jobs import (ASH, BAR, BONE, BRONZE_PICK, BRONZE_SWORD, COAL, COPPER, LEATHER, OAK, PLAYER,
                                  STONE, STONE_PICK, TIN, BONE_PICK, IRON_PICK, FakeKnowledge, JobRig, call,
                                  pickaxe_world, plan, st)
from brain.mock.gear_world import GearWorld

# ------------------------------------------------------------------ T3: a better pickaxe (autonomy ladder 1)


PICKAXE_PLAN = [
    LLMResponse(tool_calls=[ToolCall("craft_plan", {"item": "Bronze Pickaxe"}, "r1"),
                            ToolCall("compare_gear", {"category": "pickaxe"}, "r2")]),
    plan(description="Bronze Pickaxe: 5 Bronze Bar + 4 Oak Logs + 2 Leather at a Blacksmith's Bench; bars from "
                     "copper and tin at the Furnace",
         facts=[{"fact": "the Bronze Pickaxe recipe", "status": "known", "source": "game_data"}],
         task_success={"gear_better": {"category": "pickaxe", "stat": "tool_tier", "where": "equipped", "than": "start"}},
         steps=[st("mine copper", {"gained": {"item": "Copper Ore", "at_least": 9}}, [call("gather", resource="copper", count=9)]),
                st("mine tin", {"gained": {"item": "Tin Ore", "at_least": 9}}, [call("gather", resource="tin", count=9)]),
                st("smelt bronze bars", {"have": {"item": "Bronze Bar", "at_least": 5}}, [call("craft", item="Bronze Bar", count=5)]),
                st("make the pickaxe", {"have": {"item": "Bronze Pickaxe", "at_least": 1}},
                   [call("craft", item="Bronze Pickaxe", count=1)]),
                st("equip it", {"equipped": {"item": "Bronze Pickaxe"}}, [call("equip", item="Bronze Pickaxe")])]),
]


def test_t3_better_pickaxe_from_research_to_a_verified_tier_upgrade(tmp_path):
    rig = JobRig(tmp_path, PICKAXE_PLAN)
    pickaxe_world(rig)
    rig.say("can you make yourself a better pickaxe")
    rig.steps(10)
    t = rig.task()
    assert t.status == "done", (t.status, t.end_reason, [(s.title, s.status, s.failures) for s in t.steps])
    assert [s.status for s in t.steps] == ["done"] * 5
    assert rig.game.gear["held_right"] == BRONZE_PICK
    assert "Bronze Pickaxe 3 vs Bone Pickaxe 2" in t.end_reason  # tool tier 2 -> 3, from the item catalog
    # research went through the proxied client planner and the catalog comparison
    tools_seen = [m.get("name") for c in rig.director_llm.calls for m in c["messages"] if m.get("role") == "tool"]
    assert tools_seen == ["craft_plan", "compare_gear"]
    assert len(rig.director_llm.calls) == 2 and rig.director.window.left() == 18
    assert len(rig.runs()) == 5 and rig.runs("board_notice")[-1]["about"] == "task_report"
    skills = {s["skill"]: s["level"] for s in rig.game.get_state()["data"]["skills"]}
    assert skills["Mining"] > 1 and skills["Artisan"] > 1  # real recipe XP + mined XP


def test_t3_negative_control_do_nothing_body_never_finishes_the_pickaxe(tmp_path):
    rig = JobRig(tmp_path, PICKAXE_PLAN + [plan(ask_help="I can't get the ore to come; can you check on me?")])
    pickaxe_world(rig)
    rig.game.remove_tool("gather")  # the body can't gather: honest failures, never a pass
    rig.say("can you make yourself a better pickaxe")
    rig.steps(10)
    t = rig.task()
    assert t.status == "waiting_help" and all(s.status != "done" for s in t.steps)
    assert rig.director.gaps.gaps["gather"]["count"] >= 1  # not_implemented became a gap
    assert rig.game.gear["held_right"] == BONE_PICK


# ------------------------------------------------------------------ T3: coal over several trips


def test_t3_coal_with_no_known_spot_researches_then_asks_once_to_be_shown(tmp_path):
    k = FakeKnowledge({"coal": "Coal is mined from coal nodes in rocky areas of Coalridge Pass and Dowdun Reach."})
    rig = JobRig(tmp_path, [
        plan(facts=[{"fact": "where coal nodes are", "status": "unknown", "source": "none"}],
             ask_help="Where is coal?"),
        LLMResponse(tool_calls=[ToolCall("lookup", {"query": "where is coal mined"}, "l1"),
                                ToolCall("map_memory", {"name": "coal"}, "l2")]),
        plan(facts=[{"fact": "where coal nodes are", "status": "known", "source": "wiki"}],
             capability_gaps=[{"primitive": "travel:long_distance", "kind": "action", "why": "no position for that region",
                               "workaround": "follow a player there"}],
             ask_help="The wiki says coal is in Coalridge Pass, but I have no position for it. Can you show me a spot?")],
        knowledge=k)
    rig.game.carry(STONE_PICK)
    rig.say("get me a load of coal")
    rig.steps(4)
    t = rig.task()
    assert t.status == "waiting_help" and "Coalridge Pass" in t.help.question
    assert k.queries == ["where is coal mined"]
    assert [r["needed"] for r in rig.log_rows("director_lookup")] == [True]
    assert rig.director.gaps.gaps["travel:long_distance"]["count"] == 1
    assert rig.director.memory.recall("coal mined")[0]["source"] == "wiki"
    notices = rig.runs("board_notice")
    assert len(notices) == 1 and notices[0]["facts"]["question"] == t.help.question


def test_t3_coal_multitrip_tallies_verified_deliveries_and_logs_the_deposit_gap(tmp_path):
    until = {"tally": {"item": "Coal", "at_least": 30}}
    spot, base = [80.0, 0.0, 0.0], [0.0, 0.0, 0.0]
    rig = JobRig(tmp_path, [plan(
        task_success=until,
        capability_gaps=[{"primitive": "deposit", "kind": "action", "why": "to put the coal in storage",
                          "workaround": "drop it at the base"}],
        steps=[st("walk to the coal spot", {"near": {"place": "coal spot", "within_m": 8}},
                  [call("go_to", target="coal spot")], group="trip"),
               st("mine coal", {"any": [{"gained": {"item": "Coal", "at_least": 12}}, {"bag": {"used_pct_at_least": 95}}]},
                  [call("gather", resource="coal", count=12)], group="trip"),
               st("walk home", {"near": {"place": "base", "within_m": 8}}, [call("go_to", target="base")], group="trip"),
               st("leave it at the base", {"lost": {"item": "Coal", "at_least": 12}},
                  [call("drop", item="Coal", count=12)], group="trip")],
        loops={"trip": {"until": until}})])
    rig.store.remember_place("coal spot", spot)
    rig.store.remember_place("base", base)
    rig.game.carry(IRON_PICK)  # coal nodes need an iron pickaxe or better (rock gates)
    rig.game.add_resource(COAL, [82, 2, 0], 200, tool="pickaxe", skill="Mining", xp=10)
    rig.say("get me a load of coal")
    rig.steps(25)
    t = rig.task()
    assert t.status == "done", (t.status, t.end_reason, [(s.title, s.status, s.failures) for s in t.steps][-6:])
    assert t.tallies[COAL] >= 30 and len(rig.director_llm.calls) == 1  # the trips needed no model calls
    assert len(t.my_drops) == 2  # two deliveries, then the third mining pass reached 36
    assert sum(g.count for g in rig.game.ground.values() if g.item == COAL) == 24
    assert rig.director.gaps.gaps["deposit"]["count"] == 1
    told = [e for e in rig.runs() if e.get("tell_player")]
    assert len(told) == 1 and "deposit" in told[0]["tell_player"][0]


def test_t3_coal_pickups_of_his_own_drops_never_inflate_the_tally(tmp_path):
    rig = JobRig(tmp_path, [plan(
        task_success={"tally": {"item": "Coal", "at_least": 10}},
        steps=[st("mine", {"gained": {"item": "Coal", "at_least": 5}}, [call("gather", resource="coal", count=5)]),
               st("drop", {"lost": {"item": "Coal", "at_least": 5}}, [call("drop", item="Coal", count=5)]),
               st("pick it back up", {"gained": {"item": "Coal", "at_least": 5}}, [call("pickup", target="ground_1")])]),
        plan(ask_help="I seem to be going round in circles with the coal; what should I do with it?")])
    rig.game.carry(IRON_PICK)
    rig.game.add_resource(COAL, [5, 0, 0], 50, tool="pickaxe")
    rig.say("get me ten coal")
    rig.steps(10)
    t = rig.task()
    assert t.tallies[COAL] == 5.0 and t.status != "done"


# ------------------------------------------------------------------ T3: farm a mob drop (prepare + abort + kills)


def test_t3_farm_a_mob_drop_prepares_counts_body_verified_kills_and_finishes(tmp_path):
    rig = JobRig(tmp_path, [])
    g = rig.game
    g.carry(BRONZE_SWORD)
    g.equip(BRONZE_SWORD)
    rats = [g.add_creature("Giant Rat", "BP_GiantRat_C", [15 + i, 0, 0], hp=20, power_level=2, drops=[(BONE, 2)])
            for i in range(3)]
    hunt = st("hunt rats", {"killed": {"kind": "rat", "at_least": 3}}, [call("attack", target=r) for r in rats],
              risk="fight")
    rig.director_llm.push(
        plan(task_success={"have": {"item": "Animal Bone", "at_least": 6}}, steps=[hunt]),
        plan(description="PL 3 sword vs PL 2 rats: no extra prep; back off below 30 % health",
             steps=[{**hunt, "abort_if": {"vital": {"stat": "health", "below_pct": 30}},
                     "escape": "walk back to the player and eat"}]))
    rig.say("farm some animal bones from the rats")
    rig.steps(8)
    t = rig.task()
    assert rig.decisions()[:2] == ["plan", "prepare"]
    assert t.status == "done" and rig.game.inventory[BONE] == 6
    assert len(t.steps[0].kills) == 3 and {k["target_class"] for k in t.steps[0].kills} == {"BP_GiantRat_C"}
    run = rig.runs()[0]
    assert run["step"]["escape"] == "walk back to the player and eat"
    me = json.loads(rig.director_llm.calls[1]["messages"][1]["content"])["me"]
    assert me["power_level"] == 3 and me["creatures_near"][0]["power_level"] == 2  # readiness facts


# ------------------------------------------------------------------ T3: a quest (perception gap, never faked)


def test_t3_quest_is_never_faked_the_gap_is_logged_and_he_asks(tmp_path):
    rig = JobRig(tmp_path, [
        plan(task_success={"quest": {"name": "Goblin Diplomacy", "completed": True}},
             steps=[st("talk to the quest giver", {"quest": {"name": "Goblin Diplomacy", "stage": 1}})]),
        plan(capability_gaps=[{"primitive": "perceive:quests", "kind": "perception", "why": "I can't see quest progress"},
                              {"primitive": "quest_dialogue", "kind": "action", "why": "I can't talk to quest characters"}],
             ask_help="I can't see or talk through quests yet. Want me to do something else meanwhile?")])
    rig.say("let's do Goblin Diplomacy")
    rig.steps(4)
    t = rig.task()
    repair = rig.director_llm.calls[1]["messages"][-1]["content"]
    assert "can't be checked from what the body reports (missing: quests)" in repair
    assert t.status == "waiting_help" and t.success is None and t.steps == []
    gaps = rig.director.gaps.gaps
    assert gaps["perceive:quests"]["count"] == 1 and gaps["quest_dialogue"]["count"] == 1


# ------------------------------------------------------------------ T3: gear progression on his own initiative


def test_t3_open_task_upgrades_gear_on_his_own_then_ends_by_choice(tmp_path):
    rig = JobRig(tmp_path, [
        LLMResponse(tool_calls=[ToolCall("compare_gear", {"category": "pickaxe"}, "r1"),
                                ToolCall("skills_progress", {}, "r2")]),
        plan(description="my pickaxe is the weakest tier and I carry what a Bronze one needs",
             steps=[st("make a Bronze Pickaxe", {"have": {"item": "Bronze Pickaxe", "at_least": 1}},
                       [call("craft", item="Bronze Pickaxe", count=1)]),
                    st("use it", {"equipped": {"item": "Bronze Pickaxe"}}, [call("equip", item="Bronze Pickaxe")])]),
        plan(description="gear is better; that is enough for now", done=True)], open_tasks=True)
    g = rig.game
    g.carry(STONE_PICK)
    g.equip(STONE_PICK)
    g.carry(BAR, 5)
    g.carry(OAK, 4)
    g.carry(LEATHER, 2)
    g.set_skill("Artisan", 1)
    g.add_station("ToolsMeleeBench", [4, 0, 0])
    rig.say("go level up and sort yourself out")
    rig.steps(8)
    t = rig.task()
    assert t.kind == "open" and t.status == "done" and t.end_reason == "ended by choice"
    assert rig.decisions() == ["curriculum", "curriculum"]
    first = json.loads(rig.director_llm.calls[0]["messages"][1]["content"])
    assert "curriculum" in first and first["curriculum"]["skills"][0]["skill"] == "Artisan"
    assert rig.game.gear["held_right"] == BRONZE_PICK and t.steps[1].status == "done"
    # the benchmark's own success test for this job (evals/bench/goal_cases goal_gear_upgrade_self_initiated)
    case = P.validate({"gear_better": {"category": "pickaxe", "stat": "tool_tier", "where": "equipped", "than": "start"}})
    start = {"gear": {"held_right": STONE_PICK}, "inventory": {BAR: 5, OAK: 4, LEATHER: 2}}
    assert P.evaluate(case, rig.game.get_state()["data"], {"baseline": start}).passed is True


# ------------------------------------------------------------------ T3: farm desert weed at our farm (plant gap)


def test_t3_desert_weed_goes_to_the_remembered_farm_and_says_what_it_cant_do(tmp_path):
    rig = JobRig(tmp_path, [
        plan(task_success={"gained": {"item": "Desert Weed", "at_least": 20}},
             capability_gaps=[{"primitive": "plant", "kind": "action", "why": "to sow the seeds in the plots", "workaround": None}],
             steps=[st("go to our farm", {"near": {"place": "our farm", "within_m": 5}}, [call("go_to", target="our farm")])]),
        plan(ask_help="I'm at the farm, but I can't plant seeds yet. Could you sow them, and I'll look after the rest?")])
    rig.store.remember_place("our farm", [30.0, 0.0, 0.0])
    rig.say("can you farm some desert weed at our farm")
    rig.steps(6)
    t = rig.task()
    assert t.steps[0].status == "done" and t.status == "waiting_help"
    assert rig.game.pos[0] > 25  # he really went there
    assert rig.runs()[0]["tell_player"] == ["I can't plant yet (to sow the seeds in the plots)"]
    assert rig.director.gaps.gaps["plant"]["count"] == 1


# ------------------------------------------------------------------ must-not-fake held-out jobs (review H12d)


def delivery(item, n):
    return {"all": [{"lost": {"item": item, "at_least": n}},
                    {"on_ground": {"item": item, "at_least": n, "player": PLAYER, "within_m": 3}}]}


def bring_plan(drop_at):
    drop_args = {"at": "player", "player": PLAYER} if drop_at == "player" else {"at": "feet"}
    return [plan(
        task_success={"all": [{"on_ground": {"item": "Ash Logs", "at_least": 20, "player": PLAYER, "within_m": 3}},
                              {"on_ground": {"item": "Stone", "at_least": 10, "player": PLAYER, "within_m": 3}}]},
        steps=[st("chop logs", {"gained": {"item": "Ash Logs", "at_least": 20}}, [call("gather", resource="ash", count=20)]),
               st("get stone", {"gained": {"item": "Stone", "at_least": 10}}, [call("gather", resource="stone", count=10)]),
               st("walk to him", {"near": {"player": PLAYER, "within_m": 4}}, [call("go_to", target=PLAYER)]),
               st("hand them over", {"all": [delivery("Ash Logs", 20), delivery("Stone", 10)]},
                  [call("drop", item="Ash Logs", count=20, **drop_args), call("drop", item="Stone", count=10, **drop_args)])]),
        plan(ask_help="I dropped them but can't tell if they reached you; did you get them?")]


def bring_world(rig, player_at=(2.0, 0.0, 0.0)):
    g = rig.game
    g.players[PLAYER].pos = list(player_at)
    g.carry(STONE_PICK)  # stone boulders need a pickaxe (any tier)
    g.add_resource(ASH, [8, 0, 0], 40, skill="Woodcutting")
    g.add_resource(STONE, [-8, 0, 0], 40, skill="Mining")


def test_must_not_fake_bring_them_to_me_is_a_real_delivery_and_stays_done_after_he_takes_it(tmp_path):
    rig = JobRig(tmp_path, bring_plan("player"))
    bring_world(rig)
    rig.say("gather 20 logs and 10 stone, then bring them to me")
    rig.steps(8)
    t = rig.task()
    assert t.status == "done" and [s.status for s in t.steps] == ["done"] * 4
    stacks = [gid for gid, gr in rig.game.ground.items()]
    for gid in stacks:
        rig.game.player_collect(PLAYER, gid)  # the stacks fly to him...
    state = rig.game.get_state()["data"]
    pred = P.validate({"on_ground": {"item": "Ash Logs", "at_least": 20, "player": PLAYER, "within_m": 3}})
    far = {**state, "players": [{"name": PLAYER, "position": [99, 0, 0]}]}  # he walked off while collecting
    assert P.evaluate(pred, far).passed is True  # magnet_target: still delivered


def test_must_not_fake_dropping_them_where_he_is_not_is_not_a_delivery(tmp_path):
    class HeWalksOff(GearWorld):  # the scripted step walks to him first; he moves away just before the drop
        def drop(self, item, count, at="feet", player=None):
            self.players[PLAYER].pos = [40.0, 0.0, 0.0]
            return super().drop(item, count, at, player)
    rig = JobRig(tmp_path, bring_plan("feet"), world_cls=HeWalksOff)
    bring_world(rig)
    rig.say("gather 20 logs and 10 stone, then bring them to me")
    rig.steps(10)
    t = rig.task()
    assert t.status != "done" and t.steps[-1].status != "done"


def test_must_not_fake_wait_for_me_at_the_lodestone_needs_place_and_time(tmp_path):
    rig = JobRig(tmp_path, [plan(
        task_success={"all": [{"near": {"place": "lodestone", "within_m": 5}}, {"elapsed": {"seconds": 120}}]},
        steps=[st("go to the lodestone", {"near": {"place": "lodestone", "within_m": 5}}, [call("go_to", target="lodestone")]),
               st("wait there", {"all": [{"near": {"place": "lodestone", "within_m": 5}}, {"elapsed": {"seconds": 120}}]})])])
    rig.store.remember_place("lodestone", [20.0, 5.0, 0.0])
    rig.say("wait for me at the lodestone")
    rig.steps(3, dt=30)
    assert rig.task().status != "done"  # there, but not long enough yet
    rig.steps(6, dt=30)
    t = rig.task()
    assert t.status == "done" and t.steps[1].status == "done" and abs(rig.game.pos[0] - 20) < 3


def test_must_not_fake_keep_the_furnace_going_reads_the_station_state(tmp_path):
    rig = JobRig(tmp_path, [plan(
        task_success={"station": {"station": "Furnace", "running": True}},
        steps=[st("start a smelt", {"station": {"station": "Furnace", "running": True}},
                  [call("craft", item="Bronze Bar", count=2)])])])
    rig.game.carry(COPPER, 3)
    rig.game.carry(TIN, 3)
    rig.game.add_station("Furnace", [6, 0, 0])
    rig.say("keep the furnace going")
    rig.steps(3)
    assert rig.task().status == "done"
    rig2 = JobRig(tmp_path / "idle", [plan(
        task_success={"station": {"station": "Furnace", "running": True}},
        steps=[st("start a smelt", {"station": {"station": "Furnace", "running": True}}, [])]),
        plan(ask_help="I've nothing to smelt; can you bring ore?")])
    rig2.game.add_station("Furnace", [6, 0, 0])
    rig2.say("keep the furnace going")
    rig2.steps(6)
    assert rig2.task().status == "waiting_help"  # an idle furnace never passes



def test_rock_gates_make_the_mock_as_strict_as_the_game():
    """Copper needs a tier-2 pickaxe, coal a tier-4 one (the derived rock-gate table); without the table (no wiki
    mirror on this machine) nodes are ungated and this test only checks that."""
    from brain.mock.gear_world import rock_gates
    g = GearWorld()
    g.carry(STONE_PICK)
    g.add_resource(COPPER, [3, 0, 0], 10)
    if not rock_gates():
        assert g.gather("copper", 1)["ok"]
        return
    r = g.gather("copper", 1)
    assert (r["ok"], r["reason"], r["data"]["tier"]) == (False, "wrong_tool", 2)
    g.carry(BONE_PICK)
    assert g.gather("copper", 1)["ok"]
    g.add_resource(COAL, [4, 0, 0], 10)
    assert g.gather("coal", 1)["reason"] == "wrong_tool"

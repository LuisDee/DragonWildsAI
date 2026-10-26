"""Director wave 4: the five GOAL T3 jobs and the must-not-fake jobs, end to end on GearWorld (catalog-driven mock),
with the REAL Agent, Controller, executor and the applied hooks (docs/design/director.md section 7, review H12).

The models are scripted (no API calls): the Director's decisions are FakeLLM JSON; the Controller's turns come
from a small policy that carries out each board step's planned calls (written by the scripted Director into the
step's hints as {"do": [...]}) and voices notices. That convention lives only in these tests. What is real: tool
dispatch and validation, execution against the mock, verification, segments, tallies, gaps, the success tests
(brain/predicates.py, the same format as the benchmark's evals/bench goal cases) and every board rule.
"""
import json

import pytest


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


# ------------------------------------------------------------------ prerequisites he gets himself (Luis: a shield before parrying)


WOOD_SHIELD = "ITEM_Shield_Wood"


def shield_job(table: bool):
    """Parent: practise parrying (needs a shield). The Director adds a prerequisite 'make a wooden shield', plans
    it from craft_plan (10 Ash Logs at a Crafting Table), and comes back to the parent."""
    parent_plan = plan(description="parrying needs a shield in the left hand; I have none",
                       facts=[{"fact": "a shield is needed to parry", "status": "known", "source": "game_data"}],
                       task_success={"equipped": {"item": "Wooden Shield"}},
                       add_tasks=[{"text": "make a wooden shield", "because": "parrying needs a shield"}],
                       steps=[st("hold up the shield", {"equipped": {"item": "Wooden Shield"}},
                                 [call("equip", item="Wooden Shield")])])
    shield_plan = [LLMResponse(tool_calls=[ToolCall("craft_plan", {"item": "Wooden Shield"}, "s1")]),
                   plan(description="Wooden Shield = 10 Ash Logs at a Crafting Table",
                        task_success={"have": {"item": "Wooden Shield", "at_least": 1}},
                        steps=[st("chop ash", {"gained": {"item": "Ash Logs", "at_least": 10}},
                                  [call("gather", resource="ash", count=10)]),
                               st("make the shield", {"have": {"item": "Wooden Shield", "at_least": 1}},
                                  [call("craft", item="Wooden Shield", count=1)])])]
    no_table = plan(description="the craft needs a Crafting Table and none is within reach",
                    capability_gaps=[{"primitive": "build a Crafting Table", "kind": "action",
                                      "why": "the Wooden Shield is made at a Crafting Table and none is near"}],
                    ask_help="I've got the ash logs, but there's no Crafting Table here and I can't build one yet. "
                             "Could you place one, or show me one?")
    return [parent_plan] + shield_plan + ([] if table else [no_table])


def shield_world(rig, table: bool):
    g = rig.game
    g.carry(BRONZE_SWORD)
    g.equip(BRONZE_SWORD)
    g.carry("ITEM_Logging_Axe_Stone")
    g.add_resource(ASH, [8, 0, 0], 40, tool="axe", min_tier=1, skill="Woodcutting")
    if table:
        g.add_station("CraftingTable", [4, 3, 0])


def test_prerequisite_shield_is_planned_gathered_crafted_then_the_parent_finishes(tmp_path):
    rig = JobRig(tmp_path, shield_job(table=True))
    shield_world(rig, table=True)
    rig.say("let's practise parrying")
    rig.steps(12)
    parent = next(t for t in rig.director.ops.b.tasks if t.by.startswith("player:"))
    kid = next(t for t in rig.director.ops.b.tasks if t.by == "self")
    assert kid.parent == parent.id and kid.status == "done" and [s.status for s in kid.steps] == ["done", "done"]
    assert parent.status == "done", (parent.status, parent.end_reason)
    assert rig.game.gear == {"held_right": BRONZE_SWORD, "held_left": WOOD_SHIELD}  # sword AND shield
    assert rig.decisions() == ["plan", "plan"]  # the parent's plan, then the prerequisite's (craft_plan research)
    tools_seen = [m.get("name") for c in rig.director_llm.calls for m in c["messages"] if m.get("role") == "tool"]
    assert "craft_plan" in tools_seen


def test_prerequisite_shield_on_a_fresh_world_without_a_station_is_an_honest_build_gap(tmp_path):
    rig = JobRig(tmp_path, shield_job(table=False))
    shield_world(rig, table=False)
    rig.say("let's practise parrying")
    rig.steps(12)
    kid = next(t for t in rig.director.ops.b.tasks if t.by == "self")
    assert kid.status == "waiting_help" and "Crafting Table" in kid.help.question
    assert kid.steps[0].status == "done" and rig.game.inventory[ASH] >= 10  # the logs were real work
    craft = rig.log_rows("tool_result")
    assert any(r["tool"] == "craft" and r["result"]["reason"] == "nothing_in_range" for r in craft)
    assert rig.director.gaps.gaps["build a Crafting Table"]["count"] == 1
    assert "build a Crafting Table" in [g["primitive"] for g in rig.director.gaps.backlog()]



def test_board_rows_for_the_observability_metrics(tmp_path):
    """board_run_start / board_run (step_id, run) / board_step_end / board_task_status, and board runs carry a
    "board-..." episode id (the observability agent's gap and idle metrics)."""
    rig = JobRig(tmp_path, PICKAXE_PLAN)
    pickaxe_world(rig)
    rig.say("can you make yourself a better pickaxe")
    rig.steps(10)
    starts, runs, ends = rig.log_rows("board_run_start"), rig.log_rows("board_run"), rig.log_rows("board_step_end")
    assert len(starts) == len(runs) == 5 and [r["step_id"] for r in starts] == [r["step_id"] for r in runs]
    assert [e["status"] for e in ends] == ["done"] * 5 and all("seconds" in e for e in ends)
    moves = [(r["from"], r["to"]) for r in rig.log_rows("board_task_status")]
    assert moves[0] == (None, "active") and moves[-1] == ("active", "done")
    tool_rows = [r for r in rig.log_rows("tool_call") if r.get("tool") == "gather"]
    assert tool_rows and all(str(r.get("episode_id", "")).startswith("board-") for r in tool_rows)


@pytest.mark.parametrize("tick_s", [1.0, 30.0, 300.0])
def test_chained_steps_leave_no_tick_of_dead_time(tmp_path, tick_s):
    """Luis: chained subtasks are seamless. A passed step, or a decision that lands, starts the next step in the
    same tick (bounded per tick), so the step-to-step gap does not depend on the agent's tick length."""
    rig = JobRig(tmp_path, PICKAXE_PLAN)
    pickaxe_world(rig)
    marks = []
    real_run = rig.director.port.run

    def timed(event):
        start = rig.clock()
        res = real_run(event)
        if event.get("type") == "board_step":
            marks.append((event["step"]["title"], start, rig.clock()))
        return res
    rig.director.port.run = timed
    rig.say("can you make yourself a better pickaxe")
    rig.steps(12, dt=tick_s)
    assert rig.task().status == "done", rig.trace()
    assert len(marks) == 5
    gaps = [b[1] - a[2] for a, b in zip(marks, marks[1:])]
    assert max(gaps) < 1.0, gaps
    dispatched = rig.log_rows("director_dispatch")[0]["ts"]
    first = rig.log_rows("board_run_start")[0]["ts"]
    assert first - dispatched < 1.0  # a decision made at once is applied in the same tick


def test_gained_and_lost_of_one_item_in_one_test_go_back_for_repair(tmp_path):
    """Live smoke 2026-10-26: "chop 5 logs, then drop them" got the done test gained 5 AND lost 5 since the job
    began. Both read one net count, so it can never pass; the model hears why and picks tally + on_ground."""
    bad = plan(task_success={"all": [{"gained": {"item": "Ash Logs", "at_least": 5}},
                                     {"lost": {"item": "Ash Logs", "at_least": 5}}]},
               steps=[st("chop", {"gained": {"item": "Ash Logs", "at_least": 5}}, [call("gather", resource="ash", count=5)]),
                      st("drop", {"lost": {"item": "Ash Logs", "at_least": 5}}, [call("drop", item="Ash Logs", count=5)])])
    good = plan(task_success={"all": [{"tally": {"item": "Ash Logs", "at_least": 5}},
                                      {"on_ground": {"item": "Ash Logs", "at_least": 5, "position": "here",
                                                     "within_m": 5}}]},
                steps=[st("chop", {"gained": {"item": "Ash Logs", "at_least": 5}}, [call("gather", resource="ash", count=5)]),
                       st("drop", {"lost": {"item": "Ash Logs", "at_least": 5}}, [call("drop", item="Ash Logs", count=5)])])
    rig = JobRig(tmp_path, [bad, good])
    bring_world(rig)
    rig.say("chop 5 ash logs, then drop them on the ground next to you")
    rig.steps(2, dt=1.0)
    repair = [m["content"] for c in rig.director_llm.calls for m in c["messages"][-1:]
              if m["role"] == "user" and "not usable" in m["content"]]
    assert repair and "can never be true" in repair[0] and "tally" in repair[0]
    t = rig.task()
    assert "tally" in json.dumps(t.success["predicate"])


# ------------------------------------------------------------------ GOAL long tasks (M2/M4), scripted plans

from brain.mock.gear_jobs import (ASH_LOGS, BREAD, FLOUR, JOBS, SPADE, WHEAT, WHEAT_SEED, farm_bread_world,  # noqa: E402
                                  home_chest_world)

HOME_CHEST_PLAN = [plan(
    description="build a chest at home, then mine copper and store it there over trips",
    task_success={"all": [{"structure": {"name": "Wooden Chest", "new": True}},
                          {"stored": {"item": COPPER, "at_least": 40, "trips_at_least": 2}},
                          {"skill_gain": {"name": "Mining", "levels": 1}}]},
    steps=[st("chop ash for the chest", {"gained": {"item": ASH_LOGS, "at_least": 10}},
              [call("gather", resource="ash", count=10)]),
           st("build the chest", {"structure": {"name": "Wooden Chest", "new": True}}, [call("build", piece="Wooden Chest")]),
           st("mine copper", {"gained": {"item": COPPER, "at_least": 20}}, [call("gather", resource="copper", count=20)],
              group="trip"),
           st("store it in the chest", {"stored": {"item": COPPER, "at_least": 20, "container": "Wooden Chest"}},
              [call("store", item=COPPER, container="Wooden Chest")], group="trip")],
    loops={"trip": {"until": {"stored": {"item": COPPER, "at_least": 40}}}})]


def test_goal_mining_run_home_chest_builds_mines_and_fills_his_chest_over_two_verified_trips(tmp_path):
    rig = JobRig(tmp_path, HOME_CHEST_PLAN)
    home_chest_world(rig)
    rig.say(JOBS["mining_run_home_chest"][0])
    rig.steps(10)
    t = rig.task()
    assert t.status == "done", (t.status, t.end_reason, [(s.title, s.status, s.failures) for s in t.steps])
    assert [s.title for s in t.steps].count("store it in the chest") == 2  # the loop requeued one more trip
    chest = next(iter(rig.game.containers.values()))
    assert chest[COPPER] == 40  # really in his chest, from his own store results
    assert len({r["run"] for r in t.stored}) == 2 and sum(r["count"] for r in t.stored) == 40
    assert len(rig.director_llm.calls) == 1  # trips repeat by code, no model call per trip


def test_goal_mining_run_granted_ore_without_trips_never_passes_the_trip_count(tmp_path):
    """The benchmark's alt_means control: ore stored in ONE run is not two trips (and given ore is no Mining)."""
    one_trip = [plan(task_success={"stored": {"item": COPPER, "at_least": 40, "trips_at_least": 2}},
                     steps=[st("store all", {"stored": {"item": COPPER, "at_least": 40}},
                               [call("store", item=COPPER, container="Wooden Chest")])]),
                plan(ask_help="I stored it all in one go; should I make another trip?")]
    rig = JobRig(tmp_path, one_trip)
    home_chest_world(rig)
    rig.game.carry(COPPER, 40)
    rig.game.carry(ASH_LOGS, 10)
    rig.game.build("Wooden Chest")  # a chest already stands (the control is about trips, not building)
    rig.say(JOBS["mining_run_home_chest"][0])
    rig.steps(6)
    t = rig.task()
    assert t.status != "done" and t.steps[0].status == "done"
    r = P.evaluate(t.success["predicate"], rig.game.get_state()["data"],
                   rig.director.ops.task_ctx(t, rig.game.get_state()["data"]))
    assert r.passed is False and "1/2 trips" in r.detail


FARM_PLAN = [plan(
    description="plot, plant, wait, harvest, then grinder + kiln for bread",
    task_success={"all": [{"structure": {"name": "Farm Plot", "new": True}}, {"tally": {"item": WHEAT, "at_least": 1}},
                          {"have": {"item": BREAD, "at_least": 1}}]},
    steps=[st("build a farm plot", {"structure": {"name": "Farm Plot", "new": True}}, [call("build", piece="Farm Plot")]),
           # a new plot has weeds (wiki "Farming"): check the soil, dig it with the spade, then plant
           st("dig the weeds and plant wheat", {"lost": {"item": WHEAT_SEED, "at_least": 1}},
              [call("farm_plots"), call("tend", item=SPADE, times=3), call("tend", item=WHEAT_SEED)]),
           st("let it grow", {"elapsed": {"seconds": 150}}),
           st("harvest", {"gained": {"item": WHEAT, "at_least": 3}}, [call("tend")]),
           st("build a grinder and a kiln", {"all": [{"structure": {"name": "Grinder", "new": True}},
                                                     {"structure": {"name": "Kiln", "new": True}}]},
              [call("build", piece="Grinder"), call("build", piece="Kiln")]),
           st("grind the wheat", {"have": {"item": FLOUR, "at_least": 3}}, [call("craft", item=FLOUR, count=3)]),
           st("bake bread", {"have": {"item": BREAD, "at_least": 1}}, [call("craft", item=BREAD, count=1)])])]


def test_goal_farm_and_process_crop_grows_harvests_grinds_and_bakes_at_his_own_stations(tmp_path):
    rig = JobRig(tmp_path, FARM_PLAN, sync_game_time=True)
    farm_bread_world(rig)
    rig.say(JOBS["farm_and_process_crop"][0])
    rig.steps(14)
    t = rig.task()
    assert t.status == "done", (t.status, t.end_reason, [(s.title, s.status, s.failures) for s in t.steps])
    assert t.tallies.get(WHEAT) == 3.0 and rig.game.inventory[BREAD] >= 1
    farming = {s["skill"]: s for s in rig.game.get_state()["data"]["skills"]}["Farming"]
    assert farming["xp"] > 0  # planting and harvesting trained Farming (the benchmark's xp_gained)
    assert len(rig.director_llm.calls) == 1


def test_goal_farm_harvesting_too_early_is_honest_and_costs_budget_not_a_fake_harvest(tmp_path):
    early = json.loads(FARM_PLAN[0])
    early["steps"] = [s for s in early["steps"] if s["title"] != "let it grow"]
    rig = JobRig(tmp_path, [json.dumps(early), plan(ask_help="The wheat isn't ready yet; I'll check it later?")],
                 sync_game_time=False)  # no game time passes: it never grows
    farm_bread_world(rig)
    rig.say(JOBS["farm_and_process_crop"][0])
    rig.steps(6)
    t = rig.task()
    harvest = next(s for s in t.steps if s.title == "harvest")
    assert harvest.status == "failed" and t.tallies.get(WHEAT) is None
    reasons = [r.get("reason") for r in rig.log_rows("tool_result") if r.get("tool") == "tend"]
    assert t.status == "waiting_help", (t.status, reasons)


def test_goal_farm_seeds_on_a_new_weedy_plot_fail_truthfully_until_he_digs():
    """A freshly built plot starts with weeds (wiki "Farming"); a seed changes nothing and the result says why."""
    g = GearWorld()
    farm_bread_world(type("R", (), {"game": g})())
    g.build("Farm Plot")
    pid = next(iter(g.plots))
    assert g.farm_plots()["data"]["plots"][0]["soil"] == "weeds"
    r = g.tend(item=WHEAT_SEED)
    assert not r["ok"] and r["reason"] == "verification_failed" and "the plot says: weeds" in r["data"]["detail"]
    assert g.tend(item=SPADE)["data"]["changed"]["soil"]["to"] == "clear"
    assert g.tend(item=WHEAT_SEED)["ok"] and g.plots[pid]["crop"] == WHEAT

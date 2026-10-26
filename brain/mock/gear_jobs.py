"""The Director's job harness on GearWorld: the REAL Agent, Controller, executor and board hooks, with the models
swapped for scripted or recorded ones. Used by tests/test_director_jobs.py (scripted Director) and
tools/director_cassettes.py (real Sonnet decisions recorded once, then replayed by tests/test_director_cassettes.py).

The Controller stand-in (``controller_policy``) carries out each board step's planned calls when the step's hints
are a JSON {"do": [...]} (a convention of the scripted Director only), adds chat lines to the board, and voices
notices. Job worlds (``JOBS``) are data: a chat line, whether the job is open-ended, and a world setup.
"""
from __future__ import annotations

import json

from .. import director as D
from ..agent import Agent
from ..capabilities import Capabilities
from ..controller import Controller
from ..executor import Executor
from ..jsonl_log import JsonlLogger
from ..llm import FakeLLM, LLMResponse, ToolCall
from ..planner import Planner
from ..state_store import StateStore
from .game import Player
from .gear_world import GearWorld, manifest

PLAYER = "Zezima"
COPPER, TIN, COAL = "ITEM_Resources_CopperOre", "ITEM_Resources_TinOre", "ITEM_Resources_Coal"
OAK, LEATHER, STONE = "ITEM_Resources_Wood_Oak", "ITEM_Resources_Leather", "ITEM_Resources_Stone"
ASH, BONE, BAR = "ITEM_Resources_Wood_Ash", "ITEM_Resources_AnimalBone", "ITEM_Resources_BronzeBar"
STONE_PICK, BRONZE_PICK, BRONZE_SWORD = "ITEM_Pickaxe_Stone", "ITEM_Pickaxe_Bronze", "ITEM_Sword_Bronze"
BONE_PICK, IRON_PICK = "ITEM_Pickaxe_Bone", "ITEM_Pickaxe_Iron"


class Clock:
    def __init__(self, t=50_000.0):
        self.t = t

    def __call__(self):
        return self.t


def controller_policy(open_tasks=False, drop_at="player"):
    """The Haiku stand-in: chat -> add_task; board_step -> the planned calls in the step's hints; notices ->
    one line. Continuation turns (tool results back) end the chain."""
    def respond(messages, tools):
        last = messages[-1]
        if last["role"] != "user" or not str(last.get("content", "")).startswith("{"):
            return LLMResponse(content="")
        ctx = json.loads(last["content"])
        be = ctx.get("body_event") or {}
        if be.get("type") == "board_step":
            hints = be["step"].get("hints") or ""
            plan = json.loads(hints).get("do", []) if hints.startswith("{") else []
            return LLMResponse(content=None, tool_calls=[ToolCall(c["tool"], c.get("args", {}), f"c{i}")
                                                         for i, c in enumerate(plan)])
        if be.get("type") == "board_notice":
            return LLMResponse(content=f"({be['about']}) {json.dumps(be['facts'], default=str)[:150]}")
        text = (ctx.get("command") or {}).get("text")
        if text:
            args = {"text": text, "when": "now", **({"open": True} if open_tasks else {})}
            return LLMResponse(content="On it.", tool_calls=[ToolCall("add_task", args, "a1")])
        return LLMResponse(content="")
    return respond


class FakeKnowledge:
    def __init__(self, answers):
        self.answers, self.queries = answers, []

    def lookup(self, query, kind=None):
        self.queries.append(query)
        text = next((v for k, v in self.answers.items() if k in query.lower()), "no results")
        return {"ok": True, "data": {"results": [{"title": query, "text": text, "authoritative": False}]}}

    def kinds(self):
        return []


class JobRig:
    def __init__(self, tmp_path, director_script, open_tasks=False, knowledge=None, world_cls=GearWorld,
                 director_llm=None, director_log=None, controller_llm=None, hides_start_goal=False,
                 sync_game_time=False):
        self.sync_game_time = sync_game_time  # game time follows the rig clock (crops grow while he waits)
        self.game = g = world_cls()
        g.players[PLAYER] = Player(PLAYER, [2.0, 0.0, 0.0])
        man = manifest()
        caps = Capabilities(tools=list(man), source="capabilities", manifest=man)
        self.log = JsonlLogger(tmp_path / "logs" / "brain.jsonl")
        self.store = StateStore(tmp_path / "state" / "worlds" / "dev", caps.registry())
        self.executor = Executor(g, self.store, self.log, max_attempts=1)
        self.controller_llm = controller_llm or FakeLLM([controller_policy(open_tasks)] * 400, model="fake/controller")
        self.controller = Controller(self.controller_llm, g, self.store, self.log, player=PLAYER, caps=caps)
        self.agent = Agent(g, self.controller, Planner(FakeLLM([]), self.store.skills, self.log), self.executor,
                           self.store, self.log)
        self.clock = Clock()
        self.director_llm = director_llm or FakeLLM(list(director_script), model="fake/director")
        self.director = D.Director(D.AgentPort(self.agent, PLAYER), self.director_llm, self.store.dir,
                                   body_tools={n: e["description"] for n, e in man.items()},
                                   log=director_log or self.log, hides_start_goal=hides_start_goal,
                                   executor=D.SyncExecutor(), clock=self.clock, places=self.store.places,
                                   knowledge=knowledge)
        self.agent.director = self.director
        self.controller.attach_director(self.director)

    def say(self, text):
        self.game.player_say(text, player=PLAYER)

    def steps(self, n=12, dt=30.0):
        for _ in range(n):
            self.agent.step()
            self.clock.t += dt
            if self.sync_game_time:
                self.game.time += dt

    def task(self):
        return self.director.ops.b.tasks[0]

    def said(self):
        return [t for who, t in self.game.chat if who == "companion"]

    def runs(self, kind="board_step"):
        out = []
        for c in self.controller_llm.calls:
            m = c["messages"][-1]
            if m["role"] == "user" and str(m["content"]).startswith("{"):
                be = json.loads(m["content"]).get("body_event") or {}
                if be.get("type") == kind:
                    out.append(be)
        return out

    def log_rows(self, kind=None):
        rows = [json.loads(x) for x in self.log.path.read_text(encoding="utf-8").splitlines() if x.strip()]
        return [r for r in rows if kind is None or r.get("kind") == kind]

    def trace(self):  # for debugging a failing scenario
        keep = ("board_run", "director_decision", "director_dispatch", "director_error", "tool_call", "tool_result",
                "director_decision_failed", "skill_invalid")
        return [{k: v for k, v in r.items() if k not in ("ts", "messages")} for r in self.log_rows() if r.get("kind") in keep]

    def decisions(self):
        return [r["decision"] for r in self.log_rows("director_dispatch")]


def plan(**kw):
    out = {"description": "plan", "explanation": None, "facts": [], "steps": [], "ask_help": None}
    out.update(kw)
    return json.dumps(out)


def st(title, success, do=(), **kw):
    return {"title": title, "why": "", "hints": json.dumps({"do": list(do)}), "success": success, **kw}


def call(tool, **args):
    return {"tool": tool, "args": args}


def pickaxe_world(rig):
    """He holds a Bone Pickaxe (tier 2): copper and tin need tier 2 (the rock gates), so the Bronze route is open."""
    g = rig.game
    g.carry(BONE_PICK)
    g.equip(BONE_PICK)
    g.carry(OAK, 4)
    g.carry(LEATHER, 2)
    g.set_skill("Mining", 1)
    g.set_skill("Artisan", 1)
    g.add_resource(COPPER, [10, 0, 0], 30, tool="pickaxe", skill="Mining", xp=15)
    g.add_resource(TIN, [12, 4, 0], 30, tool="pickaxe", skill="Mining", xp=15)
    g.add_station("Furnace", [5, 6, 0])
    g.add_station("ToolsMeleeBench", [6, -6, 0])




def coal_world(rig):
    rig.game.carry(STONE_PICK)  # coal needs an iron pickaxe (tier 4): the job needs an upgrade first


def rats_world(rig):
    g = rig.game
    g.carry(BRONZE_SWORD)
    g.equip(BRONZE_SWORD)
    for i in range(3):
        g.add_creature("Giant Rat", "BP_GiantRat_C", [15 + i, 0, 0], hp=20, power_level=2, drops=[(BONE, 2)])


def open_gear_world(rig):
    g = rig.game
    g.carry(STONE_PICK)
    g.equip(STONE_PICK)
    g.carry(BAR, 5)
    g.carry(OAK, 4)
    g.carry(LEATHER, 2)
    g.set_skill("Artisan", 1)
    g.set_skill("Mining", 1)
    g.add_station("ToolsMeleeBench", [4, 0, 0])


def farm_world(rig):
    rig.store.remember_place("our farm", [30.0, 0.0, 0.0])


def nothing(rig):
    pass


ASH_LOGS, IRON, WHEAT_SEED = "ITEM_Resources_Wood_Ash", "ITEM_Resources_IronOre", "ITEM_Farming_Seed_Wheat"
WHEAT, FLOUR, BREAD = "ITEM_Resources_Wheat", "ITEM_Resources_Ground_Wheat", "ITEM_Consumable_Bread"


def home_chest_world(rig):
    """GOAL long task mining_run_home_chest: a chest is buildable from ash logs; copper is a walk away."""
    g = rig.game
    g.carry(BONE_PICK)
    g.equip(BONE_PICK)
    g.set_skill("Mining", 1)
    g.add_buildable("Wooden Chest", {ASH_LOGS: 10}, kind="container")
    g.add_resource(ASH_LOGS, [-6, 0, 0], 20, skill="Woodcutting")
    g.add_resource(COPPER, [18, 0, 0], 60, tool="pickaxe", skill="Mining", xp=22)


def farm_bread_world(rig):
    """GOAL long task farm_and_process_crop: plot, grinder and kiln are buildable; he carries wheat seeds."""
    g = rig.game
    g.carry(WHEAT_SEED, 2)
    g.carry(ASH_LOGS, 6)
    g.carry(STONE, 10)
    g.set_skill("Farming", 1)
    g.add_buildable("Farm Plot", {ASH_LOGS: 4}, kind="plot", crops={WHEAT_SEED: (WHEAT, 3)})
    g.add_buildable("Grinder", {STONE: 4}, kind="station", station="Grinder")
    g.add_buildable("Kiln", {STONE: 6}, kind="station", station="Kiln")


# name -> (chat line, open-ended?, world setup). Chat lines follow evals/bench goal_cases drafts where one exists.
JOBS = {
    "better_pickaxe": ("can you make yourself a better pickaxe", False, pickaxe_world),
    "coal_multitrip": ("can you get me 50 coal? check the wiki for where it is, and use the lodestones if it's far",
                       False, coal_world),
    "farm_mob_drop": ("I need 6 animal bones from those rats, can you farm them for me? gear up for them first",
                      False, rats_world),
    "quest": ("let's do the Brynmoor quests, can you start on Goblin Diplomacy? the wiki has the steps", False, nothing),
    "gear_self_initiated": ("go level up and sort yourself out, I'll be back in a bit", True, open_gear_world),
    "desert_weed": ("can you farm some desert weed at our farm? we need a stack of it", False, farm_world),
    "mining_run_home_chest": ("set yourself up a proper home with a chest, then go stock it up with ore from round "
                              "here", False, home_chest_world),
    "farm_and_process_crop": ("get a little farm going at home and bake us some bread from what you grow", False,
                              farm_bread_world),
}

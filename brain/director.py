"""The Director: a Sonnet planner over the task board, and the bridge that runs board steps as Controller runs.

Design: docs/design/director.md (rev 2 + sections 12-14), review docs/reviews/2026-10-25-director-review.md.

Three loops at three speeds: Lua reflexes (frame) -> the Haiku Controller (events) -> the Director (step
boundaries only). The Director never acts and never speaks: it decides steps (each with a success predicate,
brain/predicates.py) and the Controller carries them out with its own tools, in body-initiated runs that the
board starts (``Agent.run_directed``). Done is decided by code from fresh game state, never from a claim.

Threads (review H11): ``tick()`` runs on the agent loop and is the only writer of the board, the gap log, the
knowledge memory and the skill files. A decision (one or more model requests with read-only research tools)
runs on ONE worker thread over an immutable snapshot; its result is applied by a later ``tick()`` only if the
task's plan did not change meanwhile (``BoardOps.plan_key``, review H7a). Body reads the worker needs (the
client's own crafting planner: craft_plan / recipes / stations) are proxied: the worker posts them and ``tick()``
serves them on the agent loop, between runs.

Stopping: one progress budget per task (brain/board.py); the model sees every failure in its history and decides
what to try next (no step is ever refused).

Budget: every model request needs ``budget.allows("director")`` (Luis's daily cap, brain/budget.py) and room in
the hourly window (board.HourlyWindow, DW_DIRECTOR_CALLS_PER_HOUR). DW_DIRECTOR=0 stops it on the next tick.

No item, creature, place, station or skill names in this file: they come from game data, state, memory and the
model.
"""
from __future__ import annotations

import concurrent.futures as cf
import copy
import json
import os
import queue
import threading
import time
from contextlib import nullcontext
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Any, Callable

import jsonschema

from . import item_stats
from . import needs
from . import places
from . import predicates as P
from .board import ENDED, PLAN_FIELDS, WINDOW_NAME, BoardError, BoardOps, BoardStore, HourlyWindow, Loop, Step, Task, \
    apply_inbox_record
from .capability_gaps import GapLog, default_path
from .interface import Reason
from .knowledge_memory import Efficiency, KnowledgeMemory, matches_unknown, recall
from .llm_json import BudgetStop, DecisionError, extract_json, json_decision
from .situation import quest_rows

GAP_KINDS = ("action", "perception", "knowledge")
RESEARCH_ROUNDS = 2  # wave 5: real Sonnet used every round it was given and batched 2-4 calls per round
MAX_REQUESTS = 5  # per decision: the research rounds + the answer + 2 repairs (the advisory round shares them)
MAX_STEPS = 12
RESUME_IDLE_S = 30.0
DECISION_TIMEOUT_S = 90.0
REVIEW_EVERY_S = 300.0
REFLECT_RATIO = 0.7
REFLECT_EVERY_LOOPS = 3
LEARN_MIN_WINDOW = 0.3  # skill learning only with >= 30 % of the hour's window left
PROXIED_READS = ("craft_plan", "recipes", "stations", "buildables")
# What spends the task's progress budget (brain/board.PROGRESS_BUDGET): work that moved nothing.
SPEND = {"run": 1.0, "uncounted_run": 0.25, "failed": 1.0, "decision": 1.0, "loop_no_gain": 2.0}
NO_CURRENT_STEP = "no_current_step"  # report_step outside a board run
BOARD_REFUSED = "board_refused"  # a board rule refused the tool (the reason is in data.detail)
WAIT_CHECK_S = 10.0  # a wait step's test is re-checked at most this often (no get_state on every poll)
WAIT_MAX_S = 1800.0  # a wait step whose test still fails after this is a failed attempt (the model replans)
MAX_TRANSITIONS = 8  # per tick: a passed step or a landed decision starts the next one at once (no tick of dead time).
# The bound only stops a tight loop; chat is checked between transitions and runs pump body events themselves.
MAX_REMEMBERED = 200  # per-task / per-step memories kept by the Director (pruned)

# ------------------------------------------------------------------------------ the Controller's board tools


def _fn(name: str, description: str, props: dict, required: list[str] | None = None) -> dict:
    return {"type": "function", "function": {"name": name, "description": description,
                                             "parameters": {"type": "object", "properties": props,
                                                            **({"required": required} if required else {})}}}


BOARD_TOOLS = [
    _fn("add_task", "Put a job on your task board, then plan and do it by yourself, step by step, each step checked "
        "in the game, pausing whenever a player needs you. A job belongs here when it needs more than a couple of "
        "your tools in a row, research (recipes, where things are, what something is weak to), crafting chains, "
        "travel, repeated trips, or minutes to hours of work, or when the player leaves it to you. Starting such "
        "a job with one tool call does only its first step. Describe the job in plain words as the player meant it.",
        {"text": {"type": "string", "description": "The job, in plain words."},
         "when": {"type": "string", "enum": ["now", "next", "later"],
                  "description": "now = start it now (the current job waits), next = after the current job, "
                                 "later = at the end of the queue."},
         "open": {"type": "boolean", "description": "true for an open-ended job with no fixed end."}},
        ["text"]),
    _fn("board", "Read-only: your task board: the current job, its step and progress, what is queued, what is "
        "paused or waiting for help and why.", {}),
    _fn("pause_board", "Stop working on your task board until a player wants you to carry on (resume_board).",
        {"reason": {"type": "string"}}, ["reason"]),
    _fn("resume_board", "Carry on with your task board; note = what the player told you (an answer to your "
        "question, a hint), passed to your planning.", {"note": {"type": "string"}}),
    _fn("cancel_task", "Remove a job from your task board (the current one without id).",
        {"id": {"type": "string"}, "reason": {"type": "string"}}),
    _fn("report_step", "Only while working on a board step: say that you are blocked (with the specific reason) "
        "or that you believe the step is finished. The board checks finished steps in the game itself.",
        {"outcome": {"type": "string", "enum": ["blocked", "done"]}, "reason": {"type": "string"}},
        ["outcome", "reason"]),
]
BOARD_TOOL_NAMES = tuple(t["function"]["name"] for t in BOARD_TOOLS)
_SCHEMAS = {t["function"]["name"]: t["function"]["parameters"] for t in BOARD_TOOLS}

PERSONA_LINES = """Your task board (board in your context; the board tools):
- A longer job (several tools in a row, research, crafting chains, trips, or a long time) goes on your board
  with add_task; you then plan and work it yourself. A single quick action is still one tool call. "board"
  tells you what you are doing and why.
- body_event board_step: a step of your OWN current board job, not a player's request. Work it with your tools.
  The board checks in the game when it is done. If you are blocked, call report_step(blocked, the specific reason).
  If resumed is true, preempted_by says who interrupted you, with what and what they said: if they wanted you to
  stop, wait or stay, call pause_board instead of working.
- body_event board_notice: something about your board the player should hear (a question, a gap in what you can
  do, a finished job). Tell them once, in your own words."""

STEP_INSTRUCTIONS = ("This is a step of your own current job from your task board. Work on it with your tools "
                     "(several in order are fine). Do this step only: the job's later steps come to you as their own "
                     "steps, so don't do their work now. The board checks the step in the game by itself. If you are "
                     "blocked, call report_step with outcome blocked and the specific reason. Talk only when it "
                     "helps the player: when you start a new job (say what done will mean), worthwhile facts in "
                     "just_completed, and each tell_player item once. If resumed is true, preempted_by says what "
                     "the player said and did: if they wanted you to stop, wait or stay, call pause_board instead. "
                     "first_call_result: what your plan's first call for this step already did; carry on from it.")
NOTICE_INSTRUCTIONS = ("Tell the player this about your task board once, briefly, in your own words "
                       "(and nothing else unless they asked).")

# ------------------------------------------------------------------------------ the Director's prompt

SYSTEM = """You are the long-term planner (the Director) for {name}, an AI companion playing RuneScape: Dragonwilds
like another player. You never act or speak yourself: you choose the next steps of the current job on his task
board, and his fast controller carries each step out with these body tools:
{tools}

Every step needs a success test that code checks on fresh game state (never anyone's claim):
{predicates}

Rules:
- Facts first. List the facts your plan depends on (a recipe, where something is, a creature's weakness, a
  quest step) as known (game data, what he perceived, memory) or unknown. Look unknown ones up with your tools
  before committing: recall, then game data (craft_plan / recipes / stations / compare_gear / map_memory), then
  lookup (game data before the wiki; the wiki is community text, may be outdated). Don't look up what you know.
- Steps are things his tools can do, in order, each with a test that measures the work. Tests already true now
  are trivial: choose ones that measure what the step changes. Prefer tests that can't be null.
- "start", "gained", "lost" and "elapsed" in a STEP's test mean since that step began; in the job's done test,
  since the job began. So compare gear with "start" in the job's done test, and test a step that equips
  something with "equipped".
- Repeated trips: give the steps a group and a loop with an "until" test; code repeats the group by itself.
  Steps after the loop (deliver, report) run once the loop's until test passes.
- An amount the player left open (no number) on a long job is not a token pass: aim for what the job's words
  describe (a stocked store means several full loads over several trips), and say the total you chose in
  description.
- Where the job says the result should end up (a place, a container, his home) is part of its done test. If that
  place or container doesn't exist or isn't known yet, making or finding it is a step of this job (buildables,
  map_memory), never a go_to to a name nobody knows.
- Fights (any step that kills things, risky or not): look up the creature (weakness, resistances, power level)
  and use a damage type it is weak to when he can (his weapons, an enchant spell, an attack spell), as prep steps
  before the fight; say in facts which you chose and why.
- me.resources_near lists what he can gather where he stands now; prefer those over guesses.
- A step that needs something no body tool can do: name it in capability_gaps (with a workaround if there is
  one) instead of pretending, with its kind: "action" (his body can't do it), "perception" (he can't see or
  sense it in the game), or "knowledge" (a fact you couldn't find or confirm: also list it in facts as unknown).
- If he is under-prepared for a risky step (a hard fight, a long trip), mark it risk and plan preparation;
  an abort_if test and escape hints say when and how to back off.
- The work of THIS job goes in its steps (gathering, crafting, travelling for it). add_tasks is only for a separate
  job he should do first that is worth its own place on the board (e.g. a gear upgrade he needs anyway); at most
  one per answer.
- Quests: me.quests has each active quest's current step in the game's own words (and its hint). Plan the next
  step from that text (lookup the quest for who gives it, what it requires and where), test it with quest_step
  (advanced), and give a quest job the done test quest_complete. A quest not started yet: lookup says who starts
  it and what it requires; a required quest not in me.quests.complete is a prerequisite job (add_tasks).
- steps_so_far shows what failed and why: change what you try, or ask. If you can't make progress with his tools
  and what you know, ask the player ONE specific question (ask_help).
Answer with ONE JSON object only:
{output}"""

OUTPUT_DOC = """{"description": str, "explanation": str|null,
 "facts": [{"fact": str, "for_step": str, "status": "known"|"unknown", "source": str, "confidence": str}],
 "task_success": <test>|null   (the job's own done test, first decision of a specific job only),
 "steps": [{"title": str, "why": str, "hints": str, "success": <test>, "risk": "fight"|"trip"|null,
            "abort_if": <test>|null, "escape": str|null, "needs": [primitive]|[], "group": str|null,
            "wait": bool (true: nothing to do but let time pass, e.g. a crop growing or a furnace smelting; his
                    body stays free and the test is re-checked by itself; give it a test that ends the wait),
            "first_call": {"tool": <one of his tools>, "args": {...}}|null (the step's first action when you know
                    it exactly: it runs at once, then his controller carries on from its result)}],
 "loops": {"<group>": {"until": <test>}},
 "add_tasks": [{"text": str, "because": str}], "capability_gaps": [{"primitive": str, "kind": "action"|"perception"|"knowledge", "why": str, "workaround": str|null}],
 "ask_help": str|null, "done": bool (open-ended jobs only: true when you choose to end it)}"""

KIND_NOTES = {
    "plan": "Plan the next steps of the current job.",
    "curriculum": ("This is an open-ended job. Propose the next 1-2 achievable steps that make the most "
                   "progress from where he is now (curriculum.skills lists his skills lowest first, with how each is "
                   "trained and what of his trains it; a lagging skill his tools can't train is a capability gap to "
                   "name, never progress to fake; also upgrades, what he can make, "
                   "and the history: don't repeat what just failed)."),
    "replan": ("A step failed. 1. description: what was executed and what happened (from failed). 2. explanation: "
               "the most likely cause. 3. steps: a new plan for the remaining work that avoids it, or ask_help if "
               "his tools can't get around it."),
    "prepare": ("The next step is risky (see prepare_for). Decide the preparation from combat facts: gear, the "
                "enchant or damage type that fits, buffs, food and drink, and an escape plan (abort_if + escape). "
                "Return the prep steps followed by the risky step, or the risky step alone if no prep is needed."),
    "reflect": ("A loop finished another pass. Compare the rate with the best seen and the alternatives listed "
                "(spells he can cast, other known spots) and keep or change the remaining plan; say what you "
                "changed in description."),
    "review": "Review the plan against the current state; replace the pending steps only if something changed.",
    "help_answer": "The player answered your question (notes_from_player). Plan again with it.",
}


# ------------------------------------------------------------------------------ the agent port


class AgentPort:
    """What the Director needs from the running Agent (docs/design/director.md section 8)."""

    def __init__(self, agent, player: str):
        self.agent = agent
        self.player = player

    def run(self, event: dict) -> dict:
        voice = getattr(self.agent.controller, "voice", None)
        last = voice.history[-1] if voice is not None and voice.history else None
        res = self.agent.run_directed(event, self.player)
        now = voice.history[-1] if voice is not None and voice.history else None
        return {**res, "said": now is not None and now is not last}

    def state(self) -> dict:
        return self.agent._fresh_state()

    def say(self, text: str) -> None:
        self.agent.controller.say(text, kind="notice")

    def body_read(self, tool: str, args: dict) -> dict:
        return self.agent.game.call(tool, args)

    def first_call(self, call: dict) -> dict:
        return self.agent.run_first_call(call, self.player)

    def busy(self) -> bool:
        a = self.agent
        return bool(a.active_goal or a.pending_goal or a._situations)

    def chat_pending(self) -> bool:
        return bool(getattr(self.agent, "_chat_waiting", lambda: False)())


# ------------------------------------------------------------------------------ helpers


class SyncExecutor:
    """Runs a decision at once on the calling thread (tests, dry runs)."""

    def submit(self, fn, *args, **kwargs) -> cf.Future:
        f: cf.Future = cf.Future()
        try:
            f.set_result(fn(*args, **kwargs))
        except BaseException as exc:  # noqa: BLE001 - the future carries it
            f.set_exception(exc)
        return f


class BodyProxy:
    """Body reads for the worker, served on the agent loop (the bridge has one owner)."""

    def __init__(self, call: Callable[[str, dict], dict], timeout_s: float = 20.0):
        self.call = call
        self.timeout_s = timeout_s
        self.owner: int | None = None
        self.q: queue.Queue = queue.Queue()

    def request(self, tool: str, args: dict) -> dict:
        if self.owner is None or threading.get_ident() == self.owner:
            return self._do(tool, args)
        box: dict = {"ev": threading.Event()}
        self.q.put((tool, args, box))
        if not box["ev"].wait(self.timeout_s):
            return {"ok": False, "reason": Reason.BUSY, "data": {"detail": "the body is busy right now; plan without it"}}
        return box["res"]

    def serve(self) -> None:
        self.owner = threading.get_ident()
        while True:
            try:
                tool, args, box = self.q.get_nowait()
            except queue.Empty:
                return
            box["res"] = self._do(tool, args)
            box["ev"].set()

    def _do(self, tool: str, args: dict) -> dict:
        try:
            return self.call(tool, args)
        except Exception as exc:  # a read failing is information
            return {"ok": False, "reason": Reason.BODY_ERROR, "data": {"error": repr(exc)[:200]}}


@dataclass
class Decision:
    kind: str
    value: dict | None = None
    requests: int = 0
    lookups: list[dict] = field(default_factory=list)
    tool_calls: list[dict] = field(default_factory=list)
    error: str | None = None
    budget_stop: bool = False


EFFECT_KEYS = ("items_in", "items_out", "spots_empty", "stored")


def effects_of(rec: dict) -> dict:
    """A body action's effects in one shape: {items_in: [{item, count, world_item?}], items_out: [{item, count,
    world_items}], spots_empty: [{item, why}], stored: [{item, count, container, container_name}]}. The Director
    reads only this (simplify item 2). A result that carries its own ``effects`` block (asked of the bridge client)
    is used as it is; until every tool sends one, this is the one place that reads the tools' own result fields."""
    if isinstance(rec.get("effects"), dict):
        e = rec["effects"]
        return {k: list(e.get(k) or []) for k in EFFECT_KEYS}
    args = rec.get("args") if isinstance(rec.get("args"), dict) else {}
    data = rec.get("data") if isinstance(rec.get("data"), dict) else {}
    out: dict[str, list] = {k: [] for k in EFFECT_KEYS}
    if rec.get("ok") and data.get("container") and data.get("count"):  # a verified container transfer
        row = {"item": data.get("item"), "count": data.get("count"), "container": data.get("container"),
               "container_name": data.get("container_name")}
        if rec.get("tool") == "store":  # into the container (take = out of it)
            out["items_out"].append({"item": row["item"], "count": row["count"], "world_items": []})
            out["stored"].append(row)
        else:
            out["items_in"].append({"item": row["item"], "count": row["count"]})
        return out
    if rec.get("ok") and isinstance(data.get("spent"), dict):  # materials a build used (build.lua)
        out["items_out"] += [{"item": i, "count": n, "world_items": []} for i, n in data["spent"].items() if n]
        return out
    if rec.get("ok") and isinstance(data.get("inventory"), dict):  # signed per-item changes (farm.lua tend)
        for item, d in data["inventory"].items():
            if isinstance(d, (int, float)) and d:
                out["items_in" if d > 0 else "items_out"].append({"item": item, "count": abs(d), "world_items": []})
        return out
    picked = [p for p in data.get("picked") or [] if isinstance(p, dict)]
    if picked:
        out["items_in"] += [{"item": p.get("item"), "count": p.get("count") or 1, "world_item": p.get("world_item")}
                            for p in picked]
    elif rec.get("ok") and data.get("world_items"):  # items that left him onto the ground
        out["items_out"].append({"item": data.get("item") or args.get("item"), "count": data.get("count") or
                                 args.get("count"), "world_items": [str(w) for w in data["world_items"]]})
    elif data.get("item") or args.get("item") or args.get("resource"):
        thing = data.get("item") or args.get("item") or args.get("resource")
        out["items_in" if rec.get("ok") else "items_out"].append({"item": thing, "count": data.get("count")})
    if not rec.get("ok") and rec.get("reason") == Reason.NOTHING_IN_RANGE:
        out["spots_empty"].append({"item": args.get("resource") or data.get("item"), "why": rec.get("reason")})
    return out


def _arg_list(schema: dict | None) -> str:
    """'(resource*, count*, radius)' from a tool's argument schema (* = required), for the prompt's tool list."""
    props = (schema or {}).get("properties") if isinstance(schema, dict) else None
    if not isinstance(props, dict) or not props:
        return "()" if schema else ""
    req = set(schema.get("required") or [])
    return "(" + ", ".join(f"{k}{'*' if k in req else ''}" for k in props) + ")"


def _progress_measures(meas: dict[str, float]) -> dict[str, float]:
    """No-progress uses the step's own work measures; a carried count (have:) only when nothing else exists
    (re-check 9: a drop and pick-up of the same items is not progress)."""
    own = {k: v for k, v in meas.items() if not k.startswith("have:")}
    return own or meas


def _resources_near(rows: Any, limit: int = 10) -> list[dict]:
    """get_state.nearby_resources grouped by kind: name (and item id), nodes, nearest distance and the tool the
    body says it needs. Without it the plan guesses which resource is around (M4 mock run: it planned one that wasn't)."""
    groups: dict[str, dict] = {}
    for r in rows if isinstance(rows, list) else []:
        if not isinstance(r, dict):
            continue
        name = r.get("name") or r.get("item") or r.get("resource") or r.get("kind")
        if not name:
            continue
        g = groups.setdefault(str(name), {"name": name, "nodes": 0, "nearest_m": None})
        for k in ("item", "verb", "tool", "tool_tier"):
            if r.get(k) is not None and k not in g:
                g[k] = r[k]
        g["nodes"] += 1
        d = r.get("distance")
        if isinstance(d, (int, float)) and (g["nearest_m"] is None or d < g["nearest_m"]):
            g["nearest_m"] = round(float(d), 1)
    return sorted(groups.values(), key=lambda g: g["nearest_m"] if g["nearest_m"] is not None else 1e9)[:limit]


def _compact_state(state: dict) -> dict:
    """What a planner needs from get_state: own vitals, skills, gear with stats, carried items, bag, where."""
    cat = item_stats.catalog()
    out: dict[str, Any] = {k: state.get(k) for k in ("position", "health", "max_health", "bag", "total_level")
                           if state.get(k) is not None}
    for k in ("hydration", "sustenance", "endurance", "stamina"):
        if isinstance(state.get(k), (int, float)):
            mx = state.get(f"{k}_max") or state.get(f"max_{k}")
            out[k] = f"{state[k]:g}/{mx:g}" if isinstance(mx, (int, float)) else state[k]
    if isinstance(state.get("skills"), list):
        out["skills"] = [{"skill": r.get("skill"), "level": r.get("level"), "xp": r.get("xp")}
                         for r in state["skills"] if isinstance(r, dict)]
    gear = state.get("gear") if isinstance(state.get("gear"), dict) else {}
    out["gear"] = {slot: {"item": iid, **(item_stats.stats(iid, cat) or {})} for slot, iid in gear.items() if iid}
    names = {r.get("item"): r.get("name") for r in state.get("inventory_items") or [] if isinstance(r, dict)}
    out["carried"] = [{"item": i, "name": names.get(i) or (item_stats.stats(i, cat) or {}).get("name"), "count": n}
                      for i, n in (state.get("inventory") or {}).items() if n]
    out["power_level"] = sum((item_stats.stats(i, cat) or {}).get("power_level") or 0 for i in gear.values() if i)
    out["players_near"] = [{"name": p.get("name"), "distance": p.get("distance")} for p in state.get("players") or []
                           if isinstance(p, dict)]
    out["creatures_near"] = [{"id": e.get("id"), "kind": e.get("kind") or e.get("name"), "power_level": e.get("power_level"),
                              "distance": e.get("distance"), "hostile": e.get("hostile")}
                             for e in [x for x in state.get("nearby_entities") or []  # the living, nearest first
                                       if isinstance(x, dict) and x.get("alive", True) is not False][:8]]
    if isinstance(state.get("spells"), list) and state["spells"]:  # his spell list (prep: enchants, buffs, attacks)
        out["spells"] = [{k: r.get(k) for k in ("name", "role", "castable", "reason", "needs") if r.get(k) is not None}
                         for r in state["spells"][:30] if isinstance(r, dict) and r.get("name")]
    res = _resources_near(state.get("nearby_resources"))
    if res:  # what he can gather here, one row per kind, nearest first
        out["resources_near"] = res
    if state.get("stations_nearby"):
        out["stations_nearby"] = state["stations_nearby"]
    if isinstance(state.get("interactables"), list) and state["interactables"]:  # usable things in sight
        out["usable_near"] = [{k: r.get(k) for k in ("id", "name", "prompt", "used", "distance") if r.get(k) is not None}
                              for r in state["interactables"][:12] if isinstance(r, dict)]
    if isinstance(state.get("structures"), list) and state["structures"]:  # building pieces near him
        out["structures"] = [{k: r.get(k) for k in ("id", "name", "distance") if r.get(k) is not None}
                             for r in state["structures"][:15] if isinstance(r, dict)]
    q = state.get("quests") if isinstance(state.get("quests"), dict) else None
    if q:  # his quest log, the current step in the game's own words (client_mod/scripts/quests.lua)
        out["quests"] = {"active": quest_rows(state, 8),
                         "complete": list(q.get("complete") or [])[:30]}
    if state.get("following"):
        out["following"] = state["following"]
    return out


# ------------------------------------------------------------------------------ research tools (worker side)

RESEARCH_TOOLS = [
    _fn("recall", "Facts you looked up or saw before (cached, with source and confidence). Check this first.",
        {"query": {"type": "string"}}, ["query"]),
    _fn("lookup", "Game knowledge: game data first (items, recipes, stations, spells), then the community wiki "
        "(regions, creatures, drops, quests).", {"query": {"type": "string"}, "kind": {"type": "string"}}, ["query"]),
    _fn("compare_gear", "Catalog items of a category (e.g. a tool or weapon kind) or slot with their stats, his best "
        "one now (held or carried), the deltas, and whether a recipe makes each.",
        {"category": {"type": "string"}, "slot": {"type": "string"}, "limit": {"type": "integer"}}),
    _fn("map_memory", "Places he has seen things (stations, resources, creatures, lodestones, beds, graves...), "
        "nearest first, and spots found empty or mined out.",
        {"kind": {"type": "string"}, "name": {"type": "string"}, "item": {"type": "string"},
         "limit": {"type": "integer"}}),
    _fn("skills_progress", "His skills, lowest first: level, xp, how each is trained (wiki), the recipes that award "
        "its XP and his tools that name it.", {}),
    _fn("learned_skills", "Routines he learned before (learned skills) that match the words.",
        {"query": {"type": "string"}}),
]
PROXY_TOOL_DOCS = {
    "craft_plan": _fn("craft_plan", "His own crafting planner over the game's recipes and what he carries: the tree "
                      "of gather / craft / unlock / find-station steps to make an item, with alternatives.",
                      {"item": {"type": "string"}, "count": {"type": "integer"}}, ["item"]),
    "recipes": _fn("recipes", "Recipes: for an item (every recipe and its status) or a station type.",
                   {"item": {"type": "string"}, "station": {"type": "string"}}),
    "stations": _fn("stations", "Crafting and processing stations near him and their state.", {}),
    "buildables": _fn("buildables", "Pieces he can build now (unlocked): name, material cost, what he still lacks. A "
                      "station he needs and doesn't have is often a piece to build.",
                      {"about": {"type": "string"}, "can_build_now": {"type": "boolean"}}),
}


class Research:
    """Read-only research over an immutable snapshot (safe on the worker thread)."""

    def __init__(self, snap: dict, knowledge=None, proxy: BodyProxy | None = None, body_tools: set[str] = frozenset()):
        self.snap = snap
        self.knowledge = knowledge
        self.proxy = proxy
        self.body_tools = set(body_tools)
        self.lookups: list[dict] = []

    def tools(self) -> list[dict]:
        out = [t for t in RESEARCH_TOOLS if self.knowledge is not None or t["function"]["name"] != "lookup"]
        return out + [PROXY_TOOL_DOCS[n] for n in PROXIED_READS if n in self.body_tools and self.proxy is not None]

    def run(self, name: str, args: dict) -> Any:
        if name == "recall":
            return {"facts": recall(self.snap["facts"], str(args.get("query") or ""))}
        if name == "lookup" and self.knowledge is not None:
            res = self.knowledge.lookup(str(args.get("query") or ""), args.get("kind"))
            self.lookups.append({"query": str(args.get("query") or ""), "result": res})
            return res
        if name == "compare_gear":
            return compare_gear(self.snap["state"], args.get("category"), args.get("slot"), int(args.get("limit") or 8))
        if name == "map_memory":
            from .map_memory import query  # the capability agent's store (pure query over a snapshot)
            mem = self.snap.get("map") or {}
            rows = query(mem, kind=args.get("kind"), name=args.get("name"), item=args.get("item"),
                         near=(self.snap.get("state") or {}).get("position"), limit=int(args.get("limit") or 8),
                         now=self.snap.get("now"))
            neg = [n for n in mem.get("negative") or [] if not args.get("item") or n.get("item") == args.get("item")]
            return {"seen": rows, "empty_or_mined_out": neg[-8:]}
        if name == "skills_progress":
            return skills_progress(self.snap["state"], self.snap.get("body_tools"))
        if name == "learned_skills":
            q = P.tokens(str(args.get("query") or ""))
            return {"skills": [s for s in self.snap.get("learned", []) if not q or q & P.tokens(json.dumps(s))]}
        if name in PROXIED_READS and name in self.body_tools and self.proxy is not None:
            return self.proxy.request(name, args)
        return {"ok": False, "error": f"no research tool {name!r}"}


@lru_cache(maxsize=1)
def recipes_by_output() -> dict[str, list[dict]]:
    """item id -> [{recipe, stations (display names), skill, xp}] from the shared recipe catalog (needs.catalog)."""
    data = needs.catalog()
    stations = data.get("stations") or {}
    out: dict[str, list[dict]] = {}
    for rid, r in (data.get("recipes") or {}).items():
        if r.get("test"):
            continue
        st = [(stations.get(s) or {}).get("display_name") or s for s in r.get("stations") or []]
        ins = [(i.get("name") or i.get("item"), i.get("count") or 1) for i in r.get("inputs") or []]
        for o in r.get("outputs") or []:
            out.setdefault(o.get("item"), []).append({"recipe": rid, "stations": st, "skill": r.get("skill"),
                                                      "xp": r.get("xp"), "name": o.get("name"), "inputs": ins,
                                                      "vendor": bool(r.get("vendor_reputation"))})
    return out


def compare_gear(state: dict, category: str | None, slot: str | None, limit: int = 8) -> dict:
    cat = item_stats.catalog()
    if not (category or slot):
        return {"ok": False, "error": "give a category or a slot"}
    have = P._held_or_carried(state)
    rows, best = [], None
    for iid, e in cat.items():
        st = item_stats.stats(iid, cat)
        if not st or e.get("category") == "test":
            continue
        if category and str(e.get("category") or "").lower() != category.lower():
            continue
        if slot and item_stats._slot_key(st.get("slot")) != item_stats._slot_key(slot):
            continue
        row = {"item": iid, **{k: st.get(k) for k in ("name", "slot", "power_level", "tool_tier", "damage_multiplier",
                                                      "weight", "armour") if st.get(k) is not None}}
        row["recipes"] = [{"stations": r["stations"]} for r in recipes_by_output().get(iid, [])][:2]
        if iid in have:
            row["you_have_it"] = True
            if best is None or (st.get("power_level") or 0) > (best.get("power_level") or 0):
                best = row
        rows.append(row)
    rows.sort(key=lambda r: (r.get("power_level") or 0, r.get("tool_tier") or 0))
    if best:
        for r in rows:
            r["power_level_vs_yours"] = (r.get("power_level") or 0) - (best.get("power_level") or 0)
        rows = [r for r in rows if r["power_level_vs_yours"] >= 0]
    return {"yours": best, "options": rows[:limit]}


def skills_progress(state: dict, body_tools: dict[str, str] | None = None) -> dict:
    """His skills, lowest level first, each with how it is trained: the wiki skill page's in-game line
    (knowledge.skill_pages), the recipes that award its XP (game data), and his body tools whose own description
    names the skill (the manifest). Nothing here maps a skill to an activity; a skill with none of these is one
    to research (lookup "<skill> training") or to name as a gap."""
    from .knowledge import skill_pages
    pages = skill_pages()
    by_skill: dict[str, list[dict]] = {}
    for iid, recs in recipes_by_output().items():
        for r in recs:
            # only recipes his craft tool can make: at a station (a station-less recipe answers no_station_type), not
            # bought from a vendor (M3 audit 2026-10-26: the list led with vendor/top-tier items and raw item ids)
            if r.get("skill") and r.get("xp") and r["stations"] and not r.get("vendor"):
                by_skill.setdefault(P._skill_key(r["skill"]), []).append(
                    {"makes": (item_stats.stats(iid) or {}).get("name") or r.get("name") or iid, "xp": r["xp"],
                     "at": r["stations"], "needs": [f"{n} x{c}" for n, c in r.get("inputs") or []],
                     "_cost": sum(c for _, c in r.get("inputs") or [])})
    rows = []
    for r in state.get("skills") or []:
        if not isinstance(r, dict):
            continue
        key = P._skill_key(r.get("skill"))
        page = pages.get(key) or {}
        # cheapest first (fewest inputs; input-free rows, e.g. capes, last), then the most XP: the first rows are the ones a
        # new character can start on
        recs = [{k: v for k, v in x.items() if k != "_cost"}
                for x in sorted(by_skill.get(key, []), key=lambda x: (x["_cost"] == 0, x["_cost"], -(x["xp"] or 0), str(x["makes"])))]
        word = P.tokens(str(r.get("skill") or ""))
        tools = sorted(n for n, d in (body_tools or {}).items() if word and word <= P.tokens(d or ""))
        row = {"skill": r.get("skill"), "level": r.get("level"), "xp": r.get("xp"), "how": page.get("how"),
               "recipes_awarding_xp": recs[:5], "recipes_total": len(recs), "your_tools_naming_it": tools}
        if page.get("training_page"):
            row["wiki_training_page"] = f"{page['name']} training"
        rows.append(row)
    rows.sort(key=lambda x: (x["level"] if isinstance(x["level"], (int, float)) else 1e9, x["xp"] or 0))
    if rows and isinstance(rows[0]["level"], (int, float)):
        low = rows[0]["level"]
        for x in rows:
            x["lowest"] = x["level"] == low or None
    return {"skills": rows}


# ------------------------------------------------------------------------------ decision validation

BOOKKEEPING = P.BOOKKEEPING_FIELDS
NET_CONFLICT = ("{where}: 'gained' and 'lost' of {item} in one 'all' read the same net count since the start "
                "(one is the other with the sign flipped), so both can never be true. To test collect-then-drop, "
                "use tally (what was collected over the job) with on_ground (what lies there now), or put gained "
                "and lost in separate steps")



class Validator:
    """Turns the model's JSON into a checked decision: predicates validated against the catalogs (problems go back
    as a repair), and information (facts listed as unknown, tests already true now) returned as advisories for
    one advisory round (llm_json, simplify item 4)."""

    def __init__(self, kind: str, state: dict, task: dict, items: P.Items | None = None, places: dict | None = None,
                 research_left: Callable[[], bool] = lambda: True, tools: set[str] | None = None,
                 caps=None):
        self.tools = set(tools or ())  # his body tools (a first_call must name one)
        self.caps = caps  # brain/capabilities.py: the body's own argument check (the gate a first call meets)
        self.kind, self.state, self.task = kind, state, task
        self.research_left = research_left  # unknown facts are worth an advisory only while he can still look
        self.places = places or {}
        self.unknown_seen: list[dict] = []  # facts listed as unknown in any round (lookups needed vs needless)
        self.items = items or P.Items()

    def _pred(self, p: Any, where: str, errs: list[str]) -> dict | None:
        if p is None:
            return None
        problems = P.errors(p, self.items)
        if problems:
            errs.extend(f"{where}: {x['error']}" + (f" (did you mean: {', '.join(x['candidates'])}?)"
                                                     if x.get("candidates") else "") for x in problems)
            return None
        v = P.validate(p, self.items)
        bad = P.net_conflicts(v)  # the judge's shared copy (brain/predicates.py)
        if bad:
            errs.extend(NET_CONFLICT.format(where=where, item=i) for i in bad)
            return None
        return v

    def _check_first_call(self, first: Any, where: str, errs: list[str]) -> dict | None:
        """A step's first call: one of his tools, with arguments the body's own check accepts (caps.validate: the
        same gate it meets when it runs), so the model hears now why it wouldn't run."""
        if not isinstance(first, dict):
            return None
        tool = first.get("tool")
        if not isinstance(tool, str) or (self.tools and tool not in self.tools):
            errs.append(f"{where}.first_call: tool must be one of your tools ({tool!r} is not)")
            return None
        args = first.get("args") if isinstance(first.get("args"), dict) else {}
        if self.caps is None or tool not in getattr(self.caps, "manifest", {}):
            return {"tool": tool, "args": args}
        try:
            return {"tool": tool, "args": self.caps.validate(tool, args)}
        except ValueError as exc:  # ManifestError is a ValueError
            schema = (self.caps.manifest.get(tool) or {}).get("args")
            errs.append(f"{where}.first_call args don't fit {tool}{_arg_list(schema)}: {str(exc)[:200]}")
            return None

    def __call__(self, text: str, round_: int) -> tuple[dict, list[str]]:
        raw = json.loads(extract_json(text))
        if not isinstance(raw, dict):
            raise ValueError("answer with one JSON object")
        errs: list[str] = []
        info: list[str] = []
        out: dict[str, Any] = {k: raw.get(k) for k in ("description", "explanation", "ask_help")}
        out["done"] = bool(raw.get("done"))
        out["facts"] = [f for f in raw.get("facts") or [] if isinstance(f, dict)]
        self.unknown_seen += [f for f in out["facts"] if f.get("status") == "unknown"]
        fresh = {"baseline": P.snapshot(self.state, t=0), "tallies": {}, "episodes": [], "stored": [], "now": 0,
                 "places": self.places}
        out["task_success"], out["task_success_trivial"] = None, False
        if raw.get("task_success") is not None:
            out["task_success"] = self._pred(raw["task_success"], "task_success", errs)
            tr = P.evaluate(out["task_success"], self.state, fresh) if out["task_success"] else None
            if tr is not None and tr.passed is True:
                out["task_success_trivial"] = True
                info.append("task_success is already true now.")
            elif tr is not None and tr.passed is None and not set(tr.missing) & set(BOOKKEEPING):
                # wave 5 (quest): a job whose done test can never be checked would never end; say why instead
                errs.append(f"task_success can't be checked from what the body reports (missing: "
                            f"{', '.join(tr.missing)}); choose a checkable test, or ask_help and name the gap")
        steps = []
        for i, s in enumerate((raw.get("steps") or [])[:MAX_STEPS]):
            if not isinstance(s, dict) or not str(s.get("title") or "").strip():
                errs.append(f"steps[{i}]: needs a title")
                continue
            pred = self._pred(s.get("success"), f"steps[{i}].success", errs)
            if pred is None and s.get("success") is None:
                errs.append(f"steps[{i}]: needs a success test")
            abort = self._pred(s.get("abort_if"), f"steps[{i}].abort_if", errs)
            first = self._check_first_call(s.get("first_call"), f"steps[{i}]", errs)
            if pred is None:
                continue
            r = P.evaluate(pred, self.state, fresh)
            # only the first step can be judged now: later steps run in a later state ("walk home" is true
            # at home now and not after the trip); a step already true when it activates is done at once
            trivial = r.passed is True and not steps
            if trivial:
                info.append(f"steps[{i}] '{s['title']}': its test is already true now ({r.detail}).")
            if s.get("wait") is not True and {k for k, _ in P.leaves(pred)} <= {"elapsed"}:
                # live smoke run 2: "recover the gravestone" / "set vitals policy" tested only elapsed time and
                # passed after the tools failed; information, the model may keep it
                info.append(f"steps[{i}] '{s['title']}': its test only counts time, so it passes whatever happens; "
                            f"test what the step changes, or make it a wait step (wait: true).")
            if r.passed is None:
                errs.append(f"steps[{i}] '{s['title']}': its test can't be checked from what the body reports "
                            f"(missing: {', '.join(r.missing)}); choose a checkable test or name the gap")
            row = {"title": str(s["title"])[:120], "why": str(s.get("why") or "")[:300],
                   "hints": str(s.get("hints") or "")[:500], "success": pred, "abort_if": abort,
                   "escape": s.get("escape"), "risk": s.get("risk") if s.get("risk") in ("fight", "trip") else None,
                   "needs": [str(n) for n in s.get("needs") or []][:5], "group": s.get("group") or None,
                   "wait": s.get("wait") is True, "first_call": first}
            steps.append({**row, "trivial": trivial})
        out["steps"] = steps
        out["loops"] = {}
        for g, lp in (raw.get("loops") or {}).items():
            until = self._pred((lp or {}).get("until"), f"loops.{g}.until", errs)
            if until is not None:
                out["loops"][str(g)] = until
        out["add_tasks"] = [t for t in raw.get("add_tasks") or [] if isinstance(t, dict) and t.get("text")][:3]
        out["capability_gaps"] = [g for g in raw.get("capability_gaps") or [] if isinstance(g, dict) and g.get("primitive")]
        for i, g in enumerate(out["capability_gaps"]):
            if g.get("kind") not in GAP_KINDS:  # the model says what kind of gap it is; code never guesses from words
                errs.append(f"capability_gaps[{i}] '{g['primitive']}': kind must be one of {', '.join(GAP_KINDS)}")
        if self.kind in ("plan", "help_answer") and self.task.get("kind") == "specific" and not self.task.get("success") \
                and out["task_success"] is None and not out["ask_help"]:
            errs.append("task_success is required for the first plan of a specific job")
        if not steps and not out["ask_help"] and not out["done"] and self.kind != "review":
            errs.append("give steps, ask_help, or done")
        if errs:
            raise ValueError("; ".join(errs[:12]))
        unknown = [f.get("fact") for f in out["facts"] if f.get("status") == "unknown"]
        advisories = ([f"These facts are listed as unknown: {unknown[:6]}; look them up with your tools, or say in "
                       f"explanation why the plan doesn't need them."] if unknown and self.research_left() else [])
        if info:
            advisories.append(" ".join(info[:6]) + " Tests already true measure nothing: choose tests that measure "
                              "the work, or keep them if that is really intended.")
        return out, advisories


# ------------------------------------------------------------------------------ the Director


class Director:
    def __init__(self, port, llm, state_dir: Path, *, name: str = "Claude", knowledge=None,
                 body_tools: dict[str, str] | None = None, budget=None, log=None, gaps: GapLog | None = None,
                 map_memory=None, skills=None, skills_registry=None, places: Callable[[], dict] | None = None,
                 per_hour: int | None = None, executor=None, clock: Callable[[], float] = time.time,
                 hides_start_goal: bool = False, build: str | None = None, items: P.Items | None = None,
                 caps=None):
        self.port = port
        self.llm = llm
        self.name = name
        self.knowledge = knowledge
        self.body_tools = dict(body_tools or {})  # name -> description (the body's manifest, for the prompt)
        self.caps = caps  # brain/capabilities.py: the manifest (argument names for the prompt) and its check
        self.budget = budget
        self.log = log
        self.clock = clock
        self.store = BoardStore(Path(state_dir), log=log, clock=clock, autoflush=False)
        self.ops = BoardOps(self.store, clock=clock)
        self.window = HourlyWindow(Path(state_dir) / WINDOW_NAME, per_hour=per_hour, clock=clock)
        self.gaps = gaps or GapLog(default_path(Path(state_dir)), tools=self.body_tools, log=log, clock=clock)
        self.memory = KnowledgeMemory(Path(state_dir), build=build, clock=clock)
        self.efficiency = Efficiency(Path(state_dir), clock=clock)
        self.map_memory = map_memory
        self.skills = skills
        self.skills_registry = skills_registry
        self.places = places or (lambda: {})
        self.executor = executor or cf.ThreadPoolExecutor(max_workers=1, thread_name_prefix="director")
        self.proxy = BodyProxy(port.body_read)
        self.hides_start_goal = hides_start_goal
        self.items = items or P.Items()  # item names from the game catalogs (a test world may bring its own)
        self._busy = False
        self._in_run = False
        self._future: cf.Future | None = None
        self._pending: dict | None = None
        self._learn_future: cf.Future | None = None
        self._learn_pending: dict | None = None
        self._learn_tried: list[str] = []
        self._report: dict | None = None
        self._last_state: dict = {}
        self._last_command_at: float | None = None
        self._preempted_by: dict | None = None
        self._budget_said: str | None = None
        self._picked: list[str] = []
        # per task / per step memories (pruned when a task ends, and capped)
        self._just_completed: dict[str, dict] = {}
        self._tell: dict[str, list[str]] = {}
        self._fail_count: dict[str, int] = {}
        self._review_at: dict[str, float] = {}
        self._last_results: dict[str, list] = {}
        self._report_note: dict[str, str] = {}
        self._wait_checked: dict[str, float] = {}

    # ---------------------------------------------------------------- construction for the live session

    @classmethod
    def for_session(cls, agent, planner_llm, *, store, skills=None, knowledge=None, caps=None, budget=None, log=None,
                    player: str = "", name: str = "Claude") -> "Director":
        llm = planner_llm
        try:  # review L10: a request timeout so a hung call can't block the single worker
            from .llm import LiteLLMClient
            if isinstance(planner_llm, LiteLLMClient):
                llm = LiteLLMClient(planner_llm.model, timeout=60, **planner_llm.kwargs)
        except Exception:
            pass
        manifest = getattr(caps, "manifest", {}) or {}
        tools = {n: (e.get("description") or "") for n, e in manifest.items() if e.get("llm") or n in PROXIED_READS}
        if not tools and caps is not None:
            tools = {n: "" for n in getattr(caps, "tools", [])}
        d = cls(AgentPort(agent, player), llm, store.dir, name=name, knowledge=knowledge, body_tools=tools, caps=caps,
                budget=budget, log=log, map_memory=getattr(agent, "map_memory", None), skills=skills,
                skills_registry=store.skills, places=store.places,
                hides_start_goal=True)  # wave 5 eval: with start_goal hidden Haiku put both long jobs on the board
        debug = [n for n, e in manifest.items() if e.get("kind") in ("action", "waiter") and not e.get("llm")]
        d.gaps.seed(missing=getattr(caps, "missing", None), debug_tools=debug)  # only what the body reports
        return d

    # ---------------------------------------------------------------- Controller-facing

    @property
    def tool_names(self) -> tuple[str, ...]:
        return BOARD_TOOL_NAMES

    @property
    def read_tool_names(self) -> tuple[str, ...]:
        return ("board",)

    @property
    def running(self) -> bool:
        return self._in_run

    def tool_schemas(self) -> list[dict]:
        return copy.deepcopy(BOARD_TOOLS)

    def persona_lines(self) -> str:
        return PERSONA_LINES

    def validate_tool(self, name: str, args: dict) -> dict:
        jsonschema.validate(args or {}, _SCHEMAS[name])
        return dict(args or {})

    def retrieval_text(self, body_event: dict | None) -> str:
        if isinstance(body_event, dict) and body_event.get("type") == "board_step":
            return str((body_event.get("step") or {}).get("title") or "")
        return ""

    def brief(self) -> dict | None:
        """The Controller's "current task" context: the board, or that it is empty (information for "what are you
        doing?" and for deciding whether a new job goes on it)."""
        if not self.ops.b.live():
            return {"tasks": [], "note": "your task board is empty"}
        return self.ops.brief(self._last_state or None, self.places())

    def handle_tool(self, name: str, args: dict, player: str) -> dict:
        try:
            return self._handle_tool(name, args or {}, player)
        except BoardError as exc:
            return {"ok": False, "reason": BOARD_REFUSED, "data": {"detail": str(exc)}}
        finally:
            self.store.flush()

    def _handle_tool(self, name: str, args: dict, player: str) -> dict:
        self._log("board_tool", tool=name, args=args, player=player)
        if name == "board":
            return {"ok": True, "data": self.ops.brief(self._last_state or None, self.places())}
        if name == "add_task":
            t = self.ops.add_task(str(args.get("text") or ""), by=f"player:{player}", when=str(args.get("when") or "later"),
                                  kind="open" if args.get("open") else "specific")
            data: dict[str, Any] = {"id": t.id, "status": t.status, "position": self.ops.b.tasks.index(t) + 1}
            if not self._can_think():
                data["note"] = f"queued; I'm out of planning budget, I can start it in about {self._wait_min()} min"
            elif t.status == "active":
                data["note"] = "it starts as soon as I've planned it"
            return {"ok": True, "data": data}
        if name == "pause_board":
            self.ops.pause(f"player:{player}", str(args.get("reason") or ""))
            return {"ok": True, "data": {"paused": True}}
        if name == "resume_board":
            note = args.get("note")
            was_help = any(t.status == "waiting_help" for t in self.ops.b.tasks)
            t = self.ops.resume(note)
            if t is not None and (was_help or note):
                self._need(t, "help_answer" if was_help else "plan", {"note": note})
            return {"ok": True, "data": {"resumed": t.text if t else None}}
        if name == "cancel_task":
            t = self.ops.cancel(args.get("id"), str(args.get("reason") or ""))
            self._forget(t)
            return {"ok": True, "data": {"cancelled": t.text}}
        if name == "report_step":
            if not self._in_run:
                return {"ok": False, "reason": NO_CURRENT_STEP, "data": {"detail": "no board step is running"}}
            self._report = {"outcome": args.get("outcome"), "reason": str(args.get("reason") or "")[:300]}
            return {"ok": True, "data": {"noted": True}}
        return {"ok": False, "reason": Reason.UNKNOWN_TOOL, "data": {}}

    # ---------------------------------------------------------------- hooks from the agent

    def on_player_command(self, player: str, tools: list[str], text: str | None = None) -> None:
        """A chat command ran tools. Outside a board run it preempts the board (the step's segment is already
        closed: segments only exist during runs); the resume run carries who, what they said and what ran, and the
        model judges whether they wanted him to stop (simplify item 6). Inside a run its records carry origin chat."""
        if self._in_run:
            return
        self._last_command_at = self.clock()
        self._preempted_by = {"player": player, "said": text, "tools": list(tools), "at": self.clock()}
        self.ops.preempt()
        self.store.flush()

    def observe_activity(self, event) -> None:
        f = event.model_dump() if hasattr(event, "model_dump") else dict(event)
        task = self.ops.b.current_task()
        step = task.active_step() if task else None
        if step is None or not self._in_run:
            return
        if f.get("kind") == "combat_end" and f.get("outcome") == "killed":
            self.ops.note_kill(step, f)
        if f.get("kind") == "picked_up":
            self._picked += [str(it["world_item"]) for it in f.get("items") or []
                             if isinstance(it, dict) and it.get("world_item")]

    # ---------------------------------------------------------------- the tick (agent loop)

    def tick(self) -> None:
        if os.environ.get("DW_DIRECTOR", "1") == "0":  # the kill switch, read on every tick
            return
        if self._busy:  # re-entrancy: run_directed -> run_goal -> pump -> tick (re-check 5)
            return
        self._busy = True
        try:
            self._tick()
        except Exception as exc:  # the board must never take the agent loop down
            self._log("director_error", error=repr(exc)[:500])
        finally:
            self.store.flush()  # one write per tick (simplify item 15)
            self._busy = False

    def _tick(self) -> None:
        self.proxy.serve()
        self.store.ingest_inbox(lambda r: apply_inbox_record(self.ops, r))
        self._collect_learning()
        self._revoice_help()
        # chained transitions (Luis: seamless subtasks): a step that ended or a decision that landed goes straight
        # on to the next step or decision in the same tick, bounded, and never while chat is waiting
        for _ in range(MAX_TRANSITIONS):
            if not self._transition() or self.port.chat_pending():
                return

    def _transition(self) -> bool:
        """One board transition; True when the next one can start at once."""
        self._collect_decision()
        if self.ops.b.paused:
            return False
        task = self.ops.pick_current()
        if task is None or self._future is not None:
            return False
        aw = self.ops.b.awaiting_decision
        if aw and aw.get("task_id") != task.id:
            aw = None
        if aw is None and self._needs_plan(task):
            aw = self._need(task, "curriculum" if task.kind == "open" else "plan", {})
        if aw is not None:
            self._dispatch(task, aw)
            return self._future is not None and self._future.done()  # decided already (the sync executor)
        if self.port.busy() or self.port.chat_pending():
            return False
        if task.status == "preempted" and not self._resume_ok():
            return False
        return self._advance(task)

    def _needs_plan(self, task: Task) -> bool:
        if task.kind == "specific" and task.success is None:
            return True
        if task.next_step() is None:
            return not (task.kind == "open" and self.ops.yield_open())
        return False

    def _need(self, task: Task, kind: str, detail: dict) -> dict:
        aw = {"task_id": task.id, "kind": kind, "since": self.clock(), "detail": detail}
        self.ops.b.awaiting_decision = aw
        self.store.save()
        return aw

    def _resume_ok(self) -> bool:
        if self._last_command_at is not None and self.clock() - self._last_command_at < RESUME_IDLE_S:
            return False
        return not (self._last_state or {}).get("following")

    def _fresh_state(self) -> dict:
        state = self.port.state()
        self._last_state = state if isinstance(state, dict) else {}
        return self._last_state

    # ---------------------------------------------------------------- budget

    def _over_daily_cap(self) -> bool:
        return self.budget is not None and not self.budget.allows("director")

    def _can_think(self, n: int = 1) -> bool:
        return not self._over_daily_cap() and self.window.allows(n)

    def _wait_min(self) -> int:
        return max(1, round(self.window.wait_s() / 60))

    def _spend(self, task: Task, units: float, why: str) -> bool:
        """Spend the task's progress budget; when it is used up, ask for help (True)."""
        if self.ops.spend(task, units, why):
            self._ask_help(task, None, f"no progress: {why}")
            return True
        return False

    # ---------------------------------------------------------------- decisions

    def _dispatch(self, task: Task, aw: dict) -> None:
        if not self._can_think(MAX_REQUESTS):
            if task.status != "waiting_budget":
                task.status = "waiting_budget"
                self.store.save()
            key = f"{task.id}:{int(self.window.wait_s() // 600)}"
            if self._budget_said != key:
                self._budget_said = key
                out_today = self._over_daily_cap()
                self._notice(task, "I'm out of thinking budget for today, so I'll keep to what I already know."
                             if out_today else f"Next step for '{task.text}' once my planning budget frees up, in about {self._wait_min()} min.",
                             {"budget_wait_min": None if out_today else self._wait_min()})
            return
        if task.status == "waiting_budget":
            task.status = "active"
            self.store.save()
        state = self._fresh_state()
        self._pending = {"task_id": task.id, "key": self.ops.plan_key(task), "aw": aw, "started": self.clock(),
                         "snapshot_state": state}
        self._log("director_dispatch", task=task.id, decision=aw["kind"])
        self.store.flush()
        self._future = self.executor.submit(self._decide, self._snapshot(task, aw, state))

    def _snapshot(self, task: Task, aw: dict, state: dict) -> dict:
        board = [{"id": t.id, "task": t.text, "status": t.status, "by": t.by, "why": t.end_reason,
                  "because": t.because, "parent": t.parent} for t in self.ops.b.tasks[-20:]]
        learned = []
        if self.skills is not None:
            try:
                learned = [r.brief() for r in self.skills.retrieve(task.text, k=3)]
            except Exception:
                learned = []
        cur = task.model_dump(exclude={"my_drops"})
        for s, m in zip(task.steps, cur.get("steps", [])):
            m.pop("segments", None)
            m.pop("activation", None)
            m["success_words"] = P.describe(s.success)
        prog = P.evaluate(task.success["predicate"], state, self.ops.task_ctx(task, state, self.places())).to_dict() \
            if task.success else None
        return {"kind": aw["kind"], "detail": aw.get("detail") or {}, "task": cur, "task_progress": prog,
                "board": board, "state": copy.deepcopy(state), "compact": _compact_state(state),
                "map": self.map_memory.snapshot() if self.map_memory is not None else {},
                "facts": self.memory.snapshot(), "learned": learned, "gaps": self.gaps.rows()[:12],
                "places": copy.deepcopy(self.places()), "now": self.clock(), "body_tools": dict(self.body_tools)}

    def _messages(self, snap: dict) -> list[dict]:
        manifest = getattr(self.caps, "manifest", None) or {}
        tools = "\n".join(f"- {n}{_arg_list((manifest.get(n) or {}).get('args'))}: {d}"
                          for n, d in sorted(self.body_tools.items())) or "- (unknown)"
        system = SYSTEM.format(name=self.name, tools=tools, predicates=P.SCHEMA_DOC, output=OUTPUT_DOC)
        task = snap["task"]
        user = {"decision": snap["kind"], "what_to_do": KIND_NOTES.get(snap["kind"], KIND_NOTES["plan"]),
                "job": {"text": task["text"], "kind": task["kind"], "given_by": task["by"], "because": task.get("because"),
                        "done_when": P.describe(task["success"]["predicate"]) if task.get("success") else None,
                        "done_progress": snap["task_progress"], "collected": task.get("tallies"),
                        "notes_from_player": task.get("notes_from_player")},
                "steps_so_far": [{k: s.get(k) for k in ("title", "status", "attempts", "failures", "success_words", "risk")}
                                 for s in task.get("steps", [])][-15:],
                "history": task.get("history", [])[-15:], "detail": snap["detail"],
                "board": snap["board"], "me": snap["compact"], "known_gaps": snap["gaps"],
                "learned_skills": snap["learned"], "places": list((snap.get("places") or {}).keys())[:20]}
        if snap["kind"] == "curriculum":
            user["curriculum"] = {"skills": skills_progress(snap["state"], self.body_tools)["skills"]}
        return [{"role": "system", "content": system},
                {"role": "user", "content": json.dumps(user, default=str, ensure_ascii=False)}]

    def _decide(self, snap: dict) -> Decision:
        """Worker thread: model requests over the snapshot. Writes nothing (the agent loop applies the result)."""
        dec = Decision(kind=snap["kind"])
        research = Research(snap, self.knowledge, self.proxy, set(self.body_tools))
        rounds = [0]  # research rounds used (json_decision allows RESEARCH_ROUNDS)

        def before() -> bool:
            if dec.requests >= MAX_REQUESTS or self._over_daily_cap():
                return False
            dec.requests += 1
            return True

        def on_response(resp) -> None:
            rounds[0] += bool(resp.tool_calls)
            self._log("llm_response", component="director", model=getattr(self.llm, "model", "?"),
                      content=(resp.content or "")[:4000], tool_calls=[c.name for c in resp.tool_calls],
                      usage=resp.usage)

        validator = Validator(snap["kind"], snap["state"], snap["task"], self.items, places=snap.get("places"),
                              research_left=lambda: bool(research.tools()) and rounds[0] < RESEARCH_ROUNDS,
                              tools=set(self.body_tools), caps=self.caps)
        with self._episode("director"):
            messages = self._messages(snap)
            self._log("prompt", component="director", model=getattr(self.llm, "model", "?"), decision=snap["kind"],
                      task=snap["task"]["id"], messages=messages)
            try:
                dec.value, info = json_decision(self.llm, messages, validator, tools=research.tools(),
                                                run_tool=research.run, max_tool_rounds=RESEARCH_ROUNDS, max_repairs=2,
                                                before_request=before, on_response=on_response)
                dec.tool_calls = info["tool_calls"]
            except BudgetStop as exc:
                dec.error, dec.budget_stop = str(exc), True
            except DecisionError as exc:
                dec.error = str(exc)
            except Exception as exc:  # provider errors etc.
                dec.error = f"planning call failed: {exc!r}"[:300]
        facts = validator.unknown_seen + ((dec.value or {}).get("facts") or [])
        dec.lookups = score_lookups(research.lookups, facts, dec.tool_calls)
        return dec

    def _collect_decision(self) -> None:
        if self._future is None:
            return
        pend = self._pending or {}
        if not self._future.done():
            if self.clock() - pend.get("started", self.clock()) > DECISION_TIMEOUT_S:
                self._log("director_timeout", task=pend.get("task_id"))
                self._future, self._pending = None, None  # abandoned (the worker's request has its own timeout)
                task = self.ops.b.task(pend.get("task_id"))
                if task is not None:
                    self._decision_failed(task, "my planning call timed out")
            return
        try:
            dec: Decision = self._future.result()
        except Exception as exc:
            dec = Decision(kind=pend.get("aw", {}).get("kind", "plan"), error=repr(exc)[:300])
        self._future, self._pending = None, None
        task = self.ops.b.task(pend.get("task_id"))
        stale = self.ops.plan_key(task) != pend.get("key")
        if dec.requests:
            self.window.spend(dec.requests)
        for lk in dec.lookups:
            self._log("director_lookup", query=lk["query"], needed=lk["needed"])
            if lk.get("top"):
                self.memory.put(lk["query"], lk["top"]["text"], lk["top"]["source"])
        if dec.lookups:
            self.memory.save()
        if task is None or task.status in ENDED or task.status == "paused" or stale:
            self._log("director_discarded", task=pend.get("task_id"), stale=stale,
                      status=task.status if task else None)
            return
        if dec.error:
            if not dec.budget_stop:  # out of budget: the next tick waits and says so
                self._decision_failed(task, dec.error)
            return
        self._fail_count.pop(task.id, None)
        self._apply(task, pend["aw"], dec.value or {}, pend.get("snapshot_state") or {})

    def _decision_failed(self, task: Task, why: str) -> None:
        n = self._fail_count[task.id] = self._fail_count.get(task.id, 0) + 1
        self._log("director_decision_failed", task=task.id, why=why, n=n)
        if n >= 2:  # one retry at the next boundary, then say it and park
            self.ops.b.awaiting_decision = None
            self.ops.park(task, f"planning failed: {why}")
            self._notice(task, f"My planning for '{task.text}' keeps failing, so I've put it aside.", {"why": why})

    def _apply(self, task: Task, aw: dict, v: dict, state: dict) -> None:
        self.ops.b.awaiting_decision = None
        kind = aw["kind"]
        self._log("director_decision", task=task.id, decision=kind, description=v.get("description"),
                  explanation=v.get("explanation"), steps=[s["title"] for s in v.get("steps", [])],
                  ask_help=v.get("ask_help"))
        if kind == "reflect":
            for r in (aw.get("detail") or {}).get("efficiency") or []:
                self.efficiency.log_reflection(task.text, aw["detail"].get("step"), r["key"], r.get("rate"),
                                               r.get("best"), (aw["detail"] or {}).get("alternatives") or [],
                                               v.get("description"))
        if v.get("task_success") is not None:
            if task.success is None:
                self.ops.set_success(task, v["task_success"], "director", state=state)
            elif v["task_success"] != task.success["predicate"]:
                task.history.append({"title": "note", "outcome": "ignored",
                                     "reason": "the job's done test is fixed; a new one was not used"})
        for t in v.get("add_tasks", [])[:1]:  # one prerequisite per decision (wave 5: real plans added three)
            try:
                kid = self.ops.add_task(str(t["text"]), by="self", parent=task.id, because=t.get("because"),
                                        when="next")
                self._log("director_prerequisite", task=task.id, prerequisite=kid.id, text=kid.text)
            except BoardError as exc:
                task.history.append({"title": f"prerequisite '{t['text']}'", "outcome": "refused", "reason": str(exc)})
        self._take_gaps(task, v.get("capability_gaps", []))
        if v.get("ask_help"):
            self._ask_help(task, str(v["ask_help"]))
            return
        if v.get("done") and task.kind == "open":
            self._finish_task(task, "done", "ended by choice")
            return
        existing = {(s.title, json.dumps(s.success, sort_keys=True)): s for s in task.steps if s.status == "pending"}
        new_steps = []
        for s in v.get("steps", []):
            old = existing.get((s["title"], json.dumps(s["success"], sort_keys=True)))
            if old is not None:  # the same pending step again keeps its attempts; the new plan's details win
                for f in (*PLAN_FIELDS, "trivial"):
                    setattr(old, f, s.get(f, getattr(old, f)))
                old.prepared = old.prepared or kind == "prepare" or not old.risk
                new_steps.append(old)
            else:
                new_steps.append(Step(**{**s, "prepared": kind == "prepare" or not s.get("risk")}))
        loops = {g: Loop(until=u) for g, u in (v.get("loops") or {}).items()}
        if new_steps or kind not in ("review", "reflect"):  # a review that keeps the plan returns no steps
            self.ops.set_steps(task, new_steps, loops=loops, replace_active=kind not in ("review", "reflect"))
        if not self.ops.progressed(task, state, self.places()):
            self._spend(task, SPEND["decision"], f"{kind} decision while the job hasn't moved")

    def _take_gaps(self, task: Task, gaps: list[dict]) -> None:
        """The plan's gaps: body gaps (action, perception) to the gap log, cross-checked against the body's tools;
        knowledge gaps to the knowledge memory as open facts, never as capability gaps (simplify item 7)."""
        body = False
        for g in gaps:
            if g["kind"] == "knowledge":
                self.memory.put(f"unknown: {g['primitive']}", {"why": g.get("why"), "status": "unknown"}, "memory",
                                confidence="low")
                continue
            body = True
            rec = self.gaps.record(str(g["primitive"]), kind=g["kind"], source="director", task=task.text,
                                   why=g.get("why"), workaround=g.get("workaround"))
            if rec["tool_exists"]:
                task.history.append({"title": "note", "outcome": "claim",
                                     "reason": f"'{g['primitive']}' is one of your tools; use it"})
            elif rec["new_for_task"]:
                self._tell.setdefault(task.id, []).append(
                    f"I can't {g['primitive']} yet" + (f" ({g.get('why')})" if g.get("why") else "")
                    + (f"; workaround: {g['workaround']}" if g.get("workaround") else ""))
        if body:
            self.gaps.save()
        if any(g["kind"] == "knowledge" for g in gaps):
            self.memory.save()

    # ---------------------------------------------------------------- steps (the executor bridge)

    def _advance(self, task: Task) -> bool:
        """Start (or continue) the next step; True when it ended (passed, failed or needs a decision), so the
        next transition can follow at once."""
        step = task.next_step()
        if step is None:
            return False
        now = self.clock()
        if step.status == "active" and step.wait and now - self._wait_checked.get(step.id, -1e18) < WAIT_CHECK_S:
            return False
        state = self._fresh_state()
        places = self.places()
        r = None
        if step.status == "pending":
            if step.risk and not step.prepared:
                self._need(task, "prepare", {"prepare_for": step.title, "step_id": step.id})
                return True
            self.ops.activate(step, state)
            r = P.evaluate(step.success, state, self.ops.step_ctx(task, step, state, places))
            if r.passed is None:
                self._uncheckable(task, step, r)
                return True
            if r.passed is True:  # already true when it comes up (e.g. already standing there): no run needed
                step.trivial = True
                self._step_done(task, step, r, state)
                return True
        if task.status == "preempted":
            task.status = "active"
        if step.wait:  # nothing to do: re-check the test now and then, no Controller run (sim 2026-10-26: 58 runs)
            return self._wait(task, step, state, r)
        self._review_due(task)
        self._run(task, step, state, r)
        return step.status != "active" or self.ops.b.awaiting_decision is not None

    def _wait(self, task: Task, step: Step, state: dict, r: P.Result | None) -> bool:
        self._wait_checked[step.id] = self.clock()
        r = r or P.evaluate(step.success, state, self.ops.step_ctx(task, step, state, self.places()))
        if not step.segments and not step.runs:  # logged once: obs counts the stretch as waiting, not dead
            self._log("board_wait_start", task=task.id, step_id=step.id, step=step.title, until=r.detail)
            step.runs = 1
        if r.passed is True:
            self._step_done(task, step, r, state)
            return True
        if r.passed is None:
            self._uncheckable(task, step, r)
            return True
        if self.clock() - (step.started or self.clock()) > WAIT_MAX_S:
            self._fail_attempt(task, step, f"waited {WAIT_MAX_S / 60:.0f} min and still: {r.detail}", r)
            return True
        return False

    def _review_due(self, task: Task) -> None:
        last = self._review_at.get(task.id)
        now = self.clock()
        if last is None:
            self._review_at[task.id] = now
        elif now - last >= REVIEW_EVERY_S and self.window.left() >= self.window.per_hour / 2:
            self._review_at[task.id] = now
            self._need(task, "review", {})

    def _event(self, task: Task, step: Step, r: P.Result) -> dict:
        ev: dict[str, Any] = {"type": "board_step", "instructions": STEP_INSTRUCTIONS, "task": task.text,
                              "step": {"title": step.title, "why": step.why, "hints": step.hints},
                              "step_done_when": P.describe(step.success), "step_progress": r.detail,
                              "run": step.runs + 1}
        if task.success:
            ev["job_done_when"] = P.describe(task.success["predicate"])
        if step.escape:
            ev["step"]["escape"] = step.escape
        if self._last_results.get(step.id):
            ev["last_results"] = self._last_results[step.id]
        if self._report_note.pop(step.id, None):
            ev["note"] = "you reported this step done, but the game shows: " + r.detail
        if task.status == "preempted" or self._preempted_by:
            ev["resumed"] = True
            if self._preempted_by:
                ev["preempted_by"] = self._preempted_by  # who, what they said, what ran: the model judges
        if self._just_completed.get(task.id):
            ev["just_completed"] = self._just_completed.pop(task.id)
        if self._tell.get(task.id):
            ev["tell_player"] = self._tell.pop(task.id)
        if self.skills is not None:
            try:
                ev["learned_skills"] = [x.brief() for x in self.skills.retrieve(step.title, k=2)]
            except Exception:
                pass
        return ev

    def _run(self, task: Task, step: Step, state0: dict, r0: P.Result | None = None) -> None:
        places = self.places()
        if r0 is None:
            r0 = P.evaluate(step.success, state0, self.ops.step_ctx(task, step, state0, places))
        self.ops.open_segment(step, state0)
        event = self._event(task, step, r0)
        self._preempted_by = None
        self._report, self._picked = None, []
        self._log("board_run_start", task=task.id, step_id=step.id, step=step.title, run=step.runs + 1)
        self.store.flush()  # the board on disk before a run that may take minutes
        self._in_run = True
        try:
            with self._episode("board"):
                res, state1 = self._run_with_first_call(task, step, event, places)
        finally:
            self._in_run = False
        state1 = state1 or self._fresh_state()
        recs = res.get("actions") or []
        board_recs = [x for x in recs if x.get("origin", "board") == "board"]
        fx = [(x, effects_of(x)) for x in board_recs]
        tainted = {e["item"] for x in recs if x.get("origin") == "chat"
                   for k in ("items_in", "items_out") for e in effects_of(x)[k] if e.get("item")}
        picked = [e["world_item"] for _, f in fx for e in f["items_in"] if e.get("world_item")] + self._picked
        for _, f in fx:
            for e in f["items_out"]:
                if e.get("world_items"):
                    self.ops.note_drop(task, e["world_items"], e.get("item"), e.get("count"))
            self.ops.note_stored(task, step, f["stored"])
        gains = self.ops.close_segment(task, step, state1, tainted=tainted, repicked=self.ops.repicked(task, picked))
        step.actions = (step.actions + board_recs)[-40:]
        self._last_results[step.id] = [{"tool": x.get("tool"), "ok": x.get("ok"), "reason": x.get("reason")}
                                       for x in board_recs][-8:]
        self._body_findings(task, step, fx, state1)
        ctx = self.ops.step_ctx(task, step, state1, places)
        if step.abort_if is not None:
            ab = P.evaluate(step.abort_if, state1, ctx)
            if ab.passed is True:
                self._fail_attempt(task, step, f"aborted: {ab.detail}", ab, status="aborted")
                return
        r = P.evaluate(step.success, state1, ctx)
        self._log("board_run", task=task.id, step_id=step.id, step=step.title, run=step.runs + 1,
                  ended=res.get("ended"), passed=r.passed,
                  detail=r.detail, gains=gains, actions=[(x.get("tool"), x.get("ok")) for x in board_recs])
        if r.passed is True:
            self._step_done(task, step, r, state1)
            return
        if r.passed is None:
            self._uncheckable(task, step, r)
            return
        if self._report and self._report.get("outcome") == "blocked":
            self._fail_attempt(task, step, f"blocked: {self._report.get('reason')}", r)
            return
        if self._report and self._report.get("outcome") == "done":
            self._report_note[step.id] = r.detail
        if res.get("ended") in ("chat", "interrupted"):  # not the step's fault (H7c), but it costs a little
            step.uncounted_runs += 1
            self._spend(task, SPEND["uncounted_run"], "chat kept interrupting me")
            return
        step.runs += 1
        meas = _progress_measures(r.measures)
        moved = P.grew(step.last_measures, meas) or (bool(gains) and any(x.get("ok") for x in board_recs))
        step.no_progress_runs = 0 if moved else step.no_progress_runs + 1
        step.last_measures = meas
        self.store.save()
        if not moved and self._spend(task, SPEND["run"], f"{step.title}: {r.detail}"):
            return
        if step.no_progress_runs >= 2:  # the DEPS trigger: the model replans with what happened
            self._fail_attempt(task, step, f"no progress: {r.detail}", r)

    def _run_with_first_call(self, task: Task, step: Step, event: dict, places: dict) -> tuple[dict, dict | None]:
        """The plan's first call (if any, on the step's first run) runs at once; the step may already pass on it
        (no Controller turn needed), else the Controller run carries on from its result. Returns (the run's
        result, the fresh state when the run ended with the check here, else None)."""
        call = step.first_call if step.runs == 0 and not step.uncounted_runs else None
        runner = getattr(self.port, "first_call", None)
        if not call or runner is None:
            return self.port.run(event), None
        try:
            rec = runner(call)
        except Exception as exc:  # the step still runs through the Controller
            self._log("board_first_call_error", task=task.id, step_id=step.id, error=repr(exc)[:300])
            return self.port.run(event), None
        if rec.get("skipped"):
            return self.port.run(event), None
        self._log("board_first_call", task=task.id, step_id=step.id, tool=rec.get("tool"), ok=rec.get("ok"),
                  reason=rec.get("reason"))
        state = self._fresh_state()
        r = P.evaluate(step.success, state, self.ops.step_ctx(task, step, state, places, include_open=True))
        spoke_for_job = any(s.status == "done" for s in task.steps)  # the job's first run is always voiced
        if rec.get("interrupt") or (r.passed is True and spoke_for_job and not event.get("tell_player")
                                    and not event.get("resumed") and not event.get("note")):
            # No-veto check (PRINCIPLES #2): the call that ran is the model's own (the Director's plan), it passed
            # the Controller's gates, and the step is verified done from state; skipping the turn overrides no
            # model decision. It only happens when there is nothing for the player to hear (single voice): the
            # job's first step, a message to pass on, a resume or a note always get the Controller's turn.
            return {"actions": [rec], "ended": "interrupted" if rec.get("interrupt") else "normal",
                    "said": False}, state
        event["first_call_result"] = {k: rec.get(k) for k in ("tool", "args", "ok", "reason")} | {
            "data": {k: v for k, v in (rec.get("data") or {}).items() if k in ("detail", "item", "count", "gathered",
                                                                              "crafted", "missing", "why")}}
        event["step_progress"] = r.detail
        res = self.port.run(event)
        return {**res, "actions": [rec] + list(res.get("actions") or [])}, None

    def _uncheckable(self, task: Task, step: Step, r: P.Result) -> None:
        self.gaps.from_uncheckable(r.missing, task=task.text, step=step.title)
        self._fail_attempt(task, step, f"its test can't be checked ({', '.join(r.missing)})", r)

    def _body_findings(self, task: Task, step: Step, fx: list[tuple[dict, dict]], state: dict) -> None:
        for x, f in fx:
            if x.get("ok"):
                continue
            rec = self.gaps.from_tool_result(str(x.get("tool")), x, task=task.text, step=step.title)
            if rec and rec["new_for_task"]:
                self._tell.setdefault(task.id, []).append(f"I can't {x.get('tool')} yet")
            for e in f["spots_empty"]:
                if self.map_memory is not None:
                    try:
                        self.map_memory.note_negative(e.get("item"), state.get("position"), e.get("why") or "empty",
                                                      kind="empty")
                    except Exception as exc:
                        self._log("map_memory_error", error=repr(exc))

    def _fail_attempt(self, task: Task, step: Step, reason: str, r: P.Result | None, status: str = "failed") -> None:
        """The attempt is over: the step ends with its reason, the task's budget pays, and the model replans with
        the whole failure history (it may try the same step again: nothing is refused)."""
        self.ops.finish_step(task, step, status, reason)
        if self._spend(task, SPEND["failed"], reason):
            return
        self._need(task, "replan", {"failed": {"step": step.title, "reason": reason, "attempt": step.attempts,
                                               "detail": r.detail if r else None,
                                               "last_actions": self._last_results.get(step.id, [])}})

    def _step_done(self, task: Task, step: Step, r: P.Result, state: dict) -> None:
        secs = sum((s.end or self.clock()) - s.start for s in step.segments)
        self.ops.finish_step(task, step, "done")
        facts: dict[str, Any] = {"step": step.title, "result": r.detail, "minutes": round(secs / 60, 1)}
        rates = [(f"item:{item}", self.efficiency.record(f"item:{item}", self.efficiency.rate(n, secs)))
                 for item, n in step.accumulated.items() if n > 0]
        rates += [(f"xp:{k}", self.efficiency.record(f"xp:{k}", self.efficiency.rate(dx, secs)))
                  for k, (dl, dx) in step.skill_accumulated.items() if dx]
        if task.tallies:
            facts["collected"] = dict(task.tallies)
        self._just_completed[task.id] = facts
        self._last_results.pop(step.id, None)
        self._maybe_learn(task, step, state)
        grew = any(v > 0 for v in step.accumulated.values()) or bool(step.kills) or \
            any(dl > 0 or dx > 0 for dl, dx in step.skill_accumulated.values())
        self.ops.progressed(task, state, self.places(), step_grew=grew)
        out, gained = self.ops.requeue_loop(task, step, state, self.places())
        if out == "requeued":
            if not gained and self._spend(task, SPEND["loop_no_gain"], f"a pass of '{step.group}' gained nothing"):
                return
            lp = task.loops.get(step.group or "")
            slow = any(x.get("ratio") is not None and x["ratio"] < REFLECT_RATIO for _, x in rates)
            if slow or (lp is not None and lp.done % REFLECT_EVERY_LOOPS == 0):
                self._need(task, "reflect", {"step": step.title, "efficiency": [{"key": k, **x} for k, x in rates],
                                             "alternatives": self._alternatives(step, state)})
        if task.success is not None:
            tr = P.evaluate(task.success["predicate"], state, self.ops.task_ctx(task, state, self.places()))
            if tr.passed is True:
                self._finish_task(task, "done", tr.detail)

    def _alternatives(self, step: Step, state: dict) -> dict:
        """What a reflection can weigh, from state and memory (logged as offered): spells he can cast now and other
        spots he knows for the step's items."""
        spells = [s.get("name") for s in state.get("spells") or [] if isinstance(s, dict) and s.get("castable", True)]
        spots: list[dict] = []
        if self.map_memory is not None:
            from .map_memory import query
            snap = self.map_memory.snapshot()
            for item in step.accumulated:
                spots += [{"item": item, "position": r.get("position"), "distance": r.get("distance")}
                          for r in query(snap, item=item, near=state.get("position"), limit=3)]
        return {"spells": spells[:12], "spots": spots[:6]}

    def _finish_task(self, task: Task, status: str, detail: str) -> None:
        self.ops.end_task(task, status, detail)
        self._forget(task)
        self._notice(task, f"Done with '{task.text}'.", {"job": task.text, "result": detail,
                                                         "collected": task.tallies or None}, kind="task_report")

    def _ask_help(self, task: Task, question: str | None, why: str | None = None) -> None:
        q = question or f"I'm stuck on '{task.text}' ({why}). Any idea how I should go about it?"
        seen = (self._last_state or {}).get("players")
        names = [p.get("name") for p in seen or [] if isinstance(p, dict)]
        asked = task.by.split(":", 1)[1] if task.by.startswith("player:") else (names[0] if names else None)
        self.ops.park(task, why or "needs help", question=q, player=asked)
        if isinstance(seen, list) and (not asked or asked not in names):
            task.help.revoice_pending = True  # nobody to ask here: say it when that player is around (review M1)
            self.store.save()
            return
        self._notice(task, q, {"question": q}, kind="board_notice")

    def _revoice_help(self) -> None:
        names = {p.get("name") for p in (self._last_state or {}).get("players") or [] if isinstance(p, dict)}
        for t in self.ops.b.tasks:
            h = t.help
            if t.status == "waiting_help" and h and h.revoice_pending and \
                    (h.asked_player in names or (not h.asked_player and names)):
                h.revoice_pending = False
                self.store.save()
                self._notice(t, h.question, {"question": h.question}, kind="board_notice")

    def _notice(self, task: Task, template: str, facts: dict, kind: str = "board_notice") -> None:
        """A failure, gap, help question, budget wait or task end: the Controller says it (single voice); the
        template only when the model said nothing (principle 7, review M10)."""
        ev = {"type": "board_notice", "instructions": NOTICE_INSTRUCTIONS, "about": kind, "task": task.text,
              "facts": facts}
        said = False
        if not self.port.chat_pending():
            self.store.flush()
            self._in_run = True
            try:
                with self._episode("board"):
                    said = bool(self.port.run(ev).get("said"))
            except Exception as exc:
                self._log("notice_error", error=repr(exc))
            finally:
                self._in_run = False
        if not said:
            self.port.say(template)

    def _forget(self, task: Task) -> None:
        """Drop the per-task / per-step memories of an ended task (and keep the rest capped)."""
        for d in (self._just_completed, self._tell, self._fail_count, self._review_at):
            d.pop(task.id, None)
        for s in task.steps:
            self._last_results.pop(s.id, None)
            self._report_note.pop(s.id, None)
        for s in task.steps:
            self._wait_checked.pop(s.id, None)
        for d in (self._last_results, self._report_note):
            while len(d) > MAX_REMEMBERED:
                d.pop(next(iter(d)))

    # ---------------------------------------------------------------- skill learning (re-check 4)

    def _maybe_learn(self, task: Task, step: Step, state: dict) -> None:
        if self.skills is None or self.skills_registry is None or self._learn_future is not None:
            return
        body = [x for x in step.actions if x.get("ok") and x.get("tool") in self.skills_registry]
        if len(body) < 2 or self.window.left() < LEARN_MIN_WINDOW * self.window.per_hour or self._over_daily_cap():
            return
        sig = json.dumps([task.id, [(x["tool"], x.get("args")) for x in body]], sort_keys=True, default=str)
        if sig in self._learn_tried:  # the same actions again (a loop, a repeated step): nothing new to learn
            return
        self._learn_tried = (self._learn_tried + [sig])[-MAX_REMEMBERED:]
        from .skill_library import SkillLibrary
        from .state_store import Task as PlanTask
        tasks = [PlanTask(skill=x["tool"], args=x.get("args") or {}, status="done") for x in body]
        snap, reg, lib_dir, goal = copy.deepcopy(state), self.skills_registry, self.skills.dir, step.title
        self._learn_pending = {"goal": goal, "tasks": tasks, "started": self.clock()}

        def job():  # on the worker: its own library instance (own SQLite), which writes nothing
            return SkillLibrary(lib_dir).propose(goal, tasks, snap, self.llm, reg)
        self._learn_future = self.executor.submit(job)
        self.window.spend(1)

    def _collect_learning(self) -> None:
        if self._learn_future is None or not self._learn_future.done():
            return
        fut, pend = self._learn_future, self._learn_pending or {}
        self._learn_future, self._learn_pending = None, None
        try:
            proposal = fut.result()
        except Exception as exc:
            self._log("skill_learn_error", error=repr(exc))
            return
        if proposal is None:
            return
        self.skills.load()
        rec = self.skills.accept(proposal, pend["goal"], pend["tasks"], self._fresh_state(), self.skills_registry,
                                 seconds=self.clock() - pend["started"])
        self._log("director_skill_learned" if rec else "director_skill_rejected", goal=pend["goal"],
                  name=getattr(rec, "name", None))

    # ---------------------------------------------------------------- misc

    def _log(self, kind: str, **data: Any) -> None:
        if self.log is not None:
            self.log.log(kind, **data)

    def _episode(self, prefix: str):
        """log.episode(new id) when the logger supports episodes (rows inside carry episode_id "<prefix>-...")."""
        episode = getattr(self.log, "episode", None)
        new_id = getattr(self.log, "new_episode_id", None)
        return episode(new_id(prefix)) if callable(episode) and callable(new_id) else nullcontext()


def score_lookups(lookups: list[dict], facts: list[dict], tool_calls: list[dict]) -> list[dict]:
    """needed: True when the lookup answers a fact the plan listed as unknown; False when it repeats an earlier
    lookup or recall of the same decision (needless); None when neither can be told (wave 5: Sonnet researches
    before it writes its facts, so "not listed" is not "needless")."""
    from .knowledge import _terms
    asked = [(c.get("name"), str((c.get("args") or {}).get("query") or "")) for c in tool_calls
             if c.get("name") in ("recall", "lookup")]
    out, pos = [], 0
    for lk in lookups:
        # this lookup's own place among the research calls, in order (recalls before it count as asked)
        while pos < len(asked) and not (asked[pos][0] == "lookup" and asked[pos][1] == lk["query"]):
            pos += 1
        q = _terms(lk["query"])
        earlier = [_terms(text) for _, text in asked[:pos]]
        pos += 1
        repeat = any(q and len(q & e) * 2 >= len(q) for e in earlier)
        needed = True if matches_unknown(lk["query"], facts) else (False if repeat else None)
        out.append({"query": lk["query"], "needed": needed, "top": _top_result(lk["result"])})
    return out


def _top_result(res: Any) -> dict | None:
    """The best lookup result as a cacheable fact: {text, source} (game data = game_data, else wiki)."""
    try:
        rows = (res.get("data") or {}).get("results") or []
    except AttributeError:
        return None
    if not rows:
        return None
    r = rows[0]
    return {"text": str(r.get("text") or "")[:600], "source": "game_data" if r.get("authoritative") else "wiki"}

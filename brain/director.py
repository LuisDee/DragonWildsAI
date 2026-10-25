"""The Director: a Sonnet planner over the task board, and the bridge that runs board steps as Controller runs.

Design: docs/design/director.md (rev 2 + section 12), review docs/reviews/2026-10-25-director-review.md.

Three loops at three speeds: Lua reflexes (frame) -> the Haiku Controller (events) -> the Director (step
boundaries only). The Director never acts and never speaks: it decides steps (each with a success predicate,
brain/predicates.py) and the Controller carries them out with its own tools, in body-initiated runs that the
board starts (``Agent.run_directed``). Done is decided by code from fresh game state, never from a claim.

Threads (review H11): ``tick()`` runs on the agent loop and is the only writer of the board, the gap log, the
knowledge memory and the skill files. A decision (one or more model requests with read-only research tools)
runs on ONE worker thread over an immutable snapshot; its result is applied by a later ``tick()`` only if the
board did not change meanwhile (versioned, review H7a). Body reads the worker needs (the client's own crafting
planner: craft_plan / recipes / stations) are proxied: the worker posts them and ``tick()`` serves them on the
agent loop, between runs.

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
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

import jsonschema

from . import item_stats
from . import predicates as P
from .board import (ENDED, BoardError, BoardOps, BoardStore, HourlyWindow, Loop, Step, Task, apply_inbox_record,
                    task_items)
from .capability_gaps import GapLog
from .knowledge_memory import Efficiency, KnowledgeMemory, matches_unknown, recall
from .llm_json import BudgetStop, DecisionError, extract_json, json_decision

MAX_REPLANS = 6
MAX_REQUESTS = 6  # per decision: up to 3 research rounds + the answer + 2 repairs
MAX_STEPS = 12
RESUME_IDLE_S = 30.0
DECISION_TIMEOUT_S = 90.0
STEP_WALL_S = 1800.0
REVIEW_EVERY_S = 300.0
REFLECT_RATIO = 0.7
REFLECT_EVERY_LOOPS = 3
UNCOUNTED_FACTOR = 3  # runs ended by chat/interrupts: at most 3 x max_runs per attempt (re-check 3)
LEARN_MIN_WINDOW = 0.3  # skill learning only with >= 30 % of the hour's window left
PROXIED_READS = ("craft_plan", "recipes", "stations")

# ------------------------------------------------------------------------------ the Controller's board tools


def _fn(name: str, description: str, props: dict, required: list[str] | None = None) -> dict:
    return {"type": "function", "function": {"name": name, "description": description,
                                             "parameters": {"type": "object", "properties": props,
                                                            **({"required": required} if required else {})}}}


BOARD_TOOLS = [
    _fn("add_task", "Put a job on your task board: something that takes several steps or a long time, which you "
        "then plan and work through by yourself (researching, gathering, crafting, travelling, repeating trips), "
        "pausing whenever a player needs you. Describe the job in plain words as the player meant it.",
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
- A job that takes several steps or a long time goes on your board with add_task; you then plan and work it
  yourself. "board" tells you what you are doing and why when someone asks.
- body_event board_step: a step of your OWN current board job, not a player's request. Work it with your tools.
  The board checks in the game when it is done. If you are blocked, call report_step(blocked, the specific reason).
  If resumed is true and the player had told you to stop, wait or stay, call pause_board instead of working.
- body_event board_notice: something about your board the player should hear (a question, a gap in what you can
  do, a finished job). Tell them once, in your own words."""

STEP_INSTRUCTIONS = ("This is a step of your own current job from your task board. Work on it with your tools "
                     "(several in order are fine). The board checks the step in the game by itself. If you are "
                     "blocked, call report_step with outcome blocked and the specific reason. Talk only when it "
                     "helps the player: when you start a new job (say what done will mean), worthwhile facts in "
                     "just_completed, and each tell_player item once. If resumed is true: a player interrupted "
                     "you; if they told you to stop, wait or stay, call pause_board instead of working.")
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
- A step that needs something no body tool can do: name the missing primitive in capability_gaps (with a
  workaround if there is one) instead of pretending.
- If he is under-prepared for a risky step (a hard fight, a long trip), mark it risk and plan preparation;
  an abort_if test and escape hints say when and how to back off.
- The work of THIS job goes in its steps (gathering, crafting, travelling for it). add_tasks is only for a separate
  job he should do first that is worth its own place on the board (e.g. a gear upgrade he needs anyway); at most
  one per answer.
- If you can't make progress with his tools and what you know, ask the player ONE specific question (ask_help).
Answer with ONE JSON object only:
{output}"""

OUTPUT_DOC = """{"description": str, "explanation": str|null,
 "facts": [{"fact": str, "for_step": str, "status": "known"|"unknown", "source": str, "confidence": str}],
 "task_success": <test>|null   (the job's own done test, first decision of a specific job only),
 "steps": [{"title": str, "why": str, "hints": str, "success": <test>, "risk": "fight"|"trip"|null,
            "abort_if": <test>|null, "escape": str|null, "needs": [primitive]|[], "group": str|null}],
 "loops": {"<group>": {"until": <test>}},
 "add_tasks": [{"text": str, "because": str}], "capability_gaps": [{"primitive": str, "why": str, "workaround": str|null}],
 "ask_help": str|null, "done": bool (open-ended jobs only: true when you choose to end it)}"""

KIND_NOTES = {
    "plan": "Plan the next steps of the current job.",
    "curriculum": ("This is an open-ended job. Propose the next 1-2 achievable steps that make the most "
                   "progress from where he is now (use curriculum facts: upgrades, skills, what he can make, "
                   "and the history: don't repeat what just failed)."),
    "replan": ("A step failed. 1. description: what was executed and what happened (from failed). 2. explanation: "
               "the most likely cause. 3. steps: a new plan for the remaining work that avoids it, or ask_help if "
               "his tools can't get around it."),
    "prepare": ("The next step is risky (see prepare_for). Decide the preparation from combat facts: gear, the "
                "enchant or damage type that fits, buffs, food and drink, and an escape plan (abort_if + escape). "
                "Return the prep steps followed by the risky step, or the risky step alone if no prep is needed."),
    "reflect": ("A loop finished another pass. Compare the rate with the best seen and the alternatives "
                "(spells, other spots, lodestones, better tools) and keep or change the remaining plan; say what "
                "you changed in description."),
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
            return {"ok": False, "reason": "busy", "data": {"detail": "the body is busy right now; plan without it"}}
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
            return {"ok": False, "reason": "body_error", "data": {"error": repr(exc)[:200]}}


@dataclass
class Decision:
    kind: str
    value: dict | None = None
    requests: int = 0
    lookups: list[dict] = field(default_factory=list)
    tool_calls: list[dict] = field(default_factory=list)
    error: str | None = None
    budget_stop: bool = False


def _items_touched(rec: dict) -> set[str]:
    out: set[str] = set()
    for src in (rec.get("args") or {}, rec.get("data") or {}):
        if not isinstance(src, dict):
            continue
        for k in ("item", "resource"):
            if isinstance(src.get(k), str):
                out.add(src[k])
        for p in src.get("picked") or []:
            if isinstance(p, dict) and isinstance(p.get("item"), str):
                out.add(p["item"])
    return out


def _picked_world_items(rec: dict) -> list[str]:
    d = rec.get("data") if isinstance(rec.get("data"), dict) else {}
    out = [str(p.get("world_item")) for p in d.get("picked") or [] if isinstance(p, dict) and p.get("world_item")]
    if d.get("world_item") and rec.get("tool") != "drop":
        out.append(str(d["world_item"]))
    return out


def _progress_measures(meas: dict[str, float]) -> dict[str, float]:
    """No-progress uses the step's own work measures; a carried count (have:) only when nothing else exists
    (re-check 9: a drop and pick-up of the same items is not progress)."""
    own = {k: v for k, v in meas.items() if not k.startswith("have:")}
    return own or meas


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
    out["creatures_near"] = [{"kind": e.get("kind") or e.get("name"), "power_level": e.get("power_level"),
                              "distance": e.get("distance"), "hostile": e.get("hostile")}
                             for e in (state.get("nearby_entities") or [])[:8] if isinstance(e, dict)]
    if state.get("stations_nearby"):
        out["stations_nearby"] = state["stations_nearby"]
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
    _fn("skills_progress", "His skills (level, xp) and, per skill, the recipes that award its XP.", {}),
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
        out = list(RESEARCH_TOOLS)
        if self.knowledge is None:
            out = [t for t in out if t["function"]["name"] != "lookup"]
        out += [PROXY_TOOL_DOCS[n] for n in PROXIED_READS if n in self.body_tools and self.proxy is not None]
        return out

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
            near = (self.snap.get("state") or {}).get("position")
            rows = query(mem, kind=args.get("kind"), name=args.get("name"), item=args.get("item"), near=near,
                         limit=int(args.get("limit") or 8), now=self.snap.get("now"))
            neg = [n for n in mem.get("negative") or []
                   if not args.get("item") or n.get("item") == args.get("item")][-8:]
            return {"seen": rows, "empty_or_mined_out": neg}
        if name == "skills_progress":
            return skills_progress(self.snap["state"])
        if name == "learned_skills":
            q = P.tokens(str(args.get("query") or ""))
            return {"skills": [s for s in self.snap.get("learned", []) if not q or q & P.tokens(json.dumps(s))]}
        if name in PROXIED_READS and name in self.body_tools and self.proxy is not None:
            return self.proxy.request(name, args)
        return {"ok": False, "error": f"no research tool {name!r}"}


def _recipes_by_output() -> dict[str, list[dict]]:
    from .knowledge import data_dir
    files = sorted(Path(data_dir()).glob("recipes_*.json"))
    out: dict[str, list[dict]] = {}
    if not files:
        return out
    try:
        data = json.loads(files[-1].read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return out
    stations = data.get("stations") or {}
    for rid, r in (data.get("recipes") or {}).items():
        if r.get("test"):
            continue
        for o in r.get("outputs") or []:
            st = [(stations.get(s) or {}).get("display_name") or s for s in r.get("stations") or []]
            out.setdefault(o.get("item"), []).append({"recipe": rid, "stations": st, "skill": r.get("skill"),
                                                      "xp": r.get("xp")})
    return out


_RECIPES: dict[str, list[dict]] | None = None


def recipes_by_output() -> dict[str, list[dict]]:
    global _RECIPES
    if _RECIPES is None:
        _RECIPES = _recipes_by_output()
    return _RECIPES


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
        rows = [r for r in rows if r["power_level_vs_yours"] >= 0][:limit]
    return {"yours": best, "options": rows[:limit]}


def skills_progress(state: dict) -> dict:
    by_skill: dict[str, list[dict]] = {}
    for iid, recs in recipes_by_output().items():
        for r in recs:
            if r.get("skill") and r.get("xp"):
                by_skill.setdefault(str(r["skill"]), []).append(
                    {"makes": (item_stats.stats(iid) or {}).get("name") or iid, "xp": r["xp"], "at": r["stations"]})
    rows = []
    for r in state.get("skills") or []:
        if not isinstance(r, dict):
            continue
        key = P._skill_key(r.get("skill"))
        recs = next((v for k, v in by_skill.items() if P._skill_key(k) == key), [])
        rows.append({"skill": r.get("skill"), "level": r.get("level"), "xp": r.get("xp"),
                     "recipes_awarding_xp": sorted(recs, key=lambda x: -(x["xp"] or 0))[:5]})
    return {"skills": rows}


# ------------------------------------------------------------------------------ decision validation


class Validator:
    """Turns the model's JSON into a checked decision (predicates validated against the catalogs, trivial tests
    flagged as information on the first answer, unknown facts nudged once)."""

    def __init__(self, kind: str, state: dict, task: dict, items: P.Items | None = None, research_left: bool = True,
                 places: dict | None = None):
        self.kind, self.state, self.task = kind, state, task
        self.places = places or {}
        self.unknown_seen: list[dict] = []  # facts listed as unknown in any round (lookups needed vs needless)
        self.items = items or P.Items()
        self.research_left = research_left
        self.nudged = False

    def _pred(self, p: Any, where: str, errs: list[str]) -> dict | None:
        if p is None:
            return None
        problems = P.errors(p, self.items)
        if problems:
            errs.extend(f"{where}: {x['error']}" + (f" (did you mean: {', '.join(x['candidates'])}?)"
                                                     if x.get("candidates") else "") for x in problems)
            return None
        return P.validate(p, self.items)

    def __call__(self, text: str, round_: int) -> dict:
        raw = json.loads(extract_json(text))
        if not isinstance(raw, dict):
            raise ValueError("answer with one JSON object")
        errs: list[str] = []
        info: list[str] = []
        out: dict[str, Any] = {k: raw.get(k) for k in ("description", "explanation", "ask_help")}
        out["done"] = bool(raw.get("done"))
        out["facts"] = [f for f in raw.get("facts") or [] if isinstance(f, dict)]
        self.unknown_seen += [f for f in out["facts"] if f.get("status") == "unknown"]
        fresh = {"baseline": P.snapshot(self.state, t=0), "tallies": {}, "episodes": [], "now": 0,
                 "places": self.places}
        ts = raw.get("task_success")
        out["task_success"], out["task_success_trivial"] = None, False
        if ts is not None:
            out["task_success"] = self._pred(ts, "task_success", errs)
            if out["task_success"] and P.evaluate(out["task_success"], self.state, fresh).passed is True:
                out["task_success_trivial"] = True
                info.append("task_success is already true now")
        steps = []
        for i, s in enumerate((raw.get("steps") or [])[:MAX_STEPS]):
            if not isinstance(s, dict) or not str(s.get("title") or "").strip():
                errs.append(f"steps[{i}]: needs a title")
                continue
            pred = self._pred(s.get("success"), f"steps[{i}].success", errs)
            if pred is None and s.get("success") is None:
                errs.append(f"steps[{i}]: needs a success test")
            abort = self._pred(s.get("abort_if"), f"steps[{i}].abort_if", errs)
            if pred is None:
                continue
            r = P.evaluate(pred, self.state, fresh)
            # only the first step can be judged now: later steps run in a later state ("walk home" is true
            # at home now and not after the trip); a step already true when it activates is done at once
            trivial = r.passed is True and not steps
            if trivial:
                info.append(f"steps[{i}] '{s['title']}': its test is already true now ({r.detail})")
            if r.passed is None:
                errs.append(f"steps[{i}] '{s['title']}': its test can't be checked from what the body reports "
                            f"(missing: {', '.join(r.missing)}); choose a checkable test or name the gap")
            steps.append({"title": str(s["title"])[:120], "why": str(s.get("why") or "")[:300],
                          "hints": str(s.get("hints") or "")[:500], "success": pred, "abort_if": abort,
                          "escape": s.get("escape"), "risk": s.get("risk") if s.get("risk") in ("fight", "trip") else None,
                          "needs": [str(n) for n in s.get("needs") or []][:5], "group": s.get("group") or None,
                          "trivial": trivial})
        out["steps"] = steps
        loops = {}
        for g, lp in (raw.get("loops") or {}).items():
            until = self._pred((lp or {}).get("until"), f"loops.{g}.until", errs)
            if until is not None:
                loops[str(g)] = until
        out["loops"] = loops
        out["add_tasks"] = [t for t in raw.get("add_tasks") or [] if isinstance(t, dict) and t.get("text")][:3]
        out["capability_gaps"] = [g for g in raw.get("capability_gaps") or [] if isinstance(g, dict) and g.get("primitive")]
        if self.kind in ("plan", "help_answer") and self.task.get("kind") == "specific" and not self.task.get("success") \
                and out["task_success"] is None and not out["ask_help"]:
            errs.append("task_success is required for the first plan of a specific job")
        if not steps and not out["ask_help"] and not out["done"] and self.kind != "review":
            errs.append("give steps, ask_help, or done")
        if errs:
            raise ValueError("; ".join(errs[:12]))
        unknown = [f.get("fact") for f in out["facts"] if f.get("status") == "unknown"]
        if round_ == 0 and unknown and self.research_left and not self.nudged:
            self.nudged = True
            raise ValueError(f"These facts are unknown: {unknown[:6]}. Look them up with your tools, or say in "
                             f"explanation why the plan doesn't need them.")
        if round_ == 0 and info:
            raise ValueError("Information: " + "; ".join(info[:6]) + ". Tests already true measure nothing: "
                             "choose tests that measure the work, or keep them if that is really intended.")
        return out


# ------------------------------------------------------------------------------ the Director


class Director:
    def __init__(self, port, llm, state_dir: Path, *, name: str = "Claude", knowledge=None,
                 body_tools: dict[str, str] | None = None, budget=None, log=None, gaps: GapLog | None = None,
                 map_memory=None, skills=None, skills_registry=None, places: Callable[[], dict] | None = None,
                 per_hour: int | None = None, executor=None, clock: Callable[[], float] = time.time,
                 hides_start_goal: bool = False, build: str | None = None, items: P.Items | None = None):
        self.port = port
        self.llm = llm
        self.name = name
        self.knowledge = knowledge
        self.body_tools = dict(body_tools or {})  # name -> description (the body's manifest, for the prompt)
        self.budget = budget
        self.log = log
        self.clock = clock
        self.store = BoardStore(Path(state_dir), log=log, clock=clock)
        self.ops = BoardOps(self.store, clock=clock)
        self.window = HourlyWindow(self.store, per_hour=per_hour, clock=clock)
        self.gaps = gaps or GapLog(Path(state_dir).parent.parent / "capability_gaps.json" if Path(state_dir).parent.name
                                   == "worlds" else Path(state_dir) / "capability_gaps.json", tools=self.body_tools,
                                   log=log, clock=clock)
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
        self._learn_tried: set[tuple[str, str]] = set()
        self._report: dict | None = None
        self._last_state: dict = {}
        self._last_command_at: float | None = None
        self._preempted_by: dict | None = None
        self._just_completed: dict[str, dict] = {}
        self._tell: dict[str, list[str]] = {}
        self._fail_count: dict[str, int] = {}
        self._budget_said: str | None = None
        self._picked: list[str] = []
        self._last_review: dict[str, float] = {}
        self._last_results: dict[str, list] = {}
        self._report_note: dict[str, str] = {}

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
        d = cls(AgentPort(agent, player), llm, store.dir, name=name, knowledge=knowledge, body_tools=tools,
                budget=budget, log=log, map_memory=getattr(agent, "map_memory", None), skills=skills,
                skills_registry=store.skills, places=store.places)
        debug = [n for n, e in manifest.items() if e.get("kind") in ("action", "waiter") and not e.get("llm")]
        d.gaps.seed(missing=getattr(caps, "missing", None), debug_tools=debug, known=[
            ("perceive:region_positions", "perception", "no region coordinates yet (data/regions_<build>.json)"),
            ("travel:long_distance", "action", "go_to gives up on long walks; no lodestone teleport"),
        ])
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
        if not self.ops.b.tasks:
            return None
        return self.ops.brief(self._last_state or None, self.places())

    def handle_tool(self, name: str, args: dict, player: str) -> dict:
        try:
            return self._handle_tool(name, args or {}, player)
        except BoardError as exc:
            return {"ok": False, "reason": "board_refused", "data": {"detail": str(exc)}}

    def _handle_tool(self, name: str, args: dict, player: str) -> dict:
        self._log("board_tool", tool=name, args=args, player=player)
        if name == "board":
            return {"ok": True, "data": self.ops.brief(self._last_state or None, self.places())}
        if name == "add_task":
            when = str(args.get("when") or "later")
            t = self.ops.add_task(str(args.get("text") or ""), by=f"player:{player}", when=when,
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
            return {"ok": True, "data": {"cancelled": t.text}}
        if name == "report_step":
            if not self._in_run:
                return {"ok": False, "reason": "no_current_step", "data": {"detail": "no board step is running"}}
            self._report = {"outcome": args.get("outcome"), "reason": str(args.get("reason") or "")[:300]}
            return {"ok": True, "data": {"noted": True}}
        return {"ok": False, "reason": "unknown_tool", "data": {}}

    # ---------------------------------------------------------------- hooks from the agent

    def on_player_command(self, player: str, tools: list[str]) -> None:
        """A chat command ran tools. Outside a board run it preempts the board (the step's segment is already
        closed: segments only exist during runs). Inside a run (nested) its records carry origin chat."""
        if self._in_run:
            return
        self._last_command_at = self.clock()
        self._preempted_by = {"player": player, "tools": list(tools), "at": self.clock()}
        self.ops.preempt()

    def observe_activity(self, event) -> None:
        f = event.model_dump() if hasattr(event, "model_dump") else dict(event)
        task = self.ops.b.current_task()
        step = task.active_step() if task else None
        if step is None or not self._in_run:
            return
        if f.get("kind") == "combat_end" and f.get("outcome") == "killed":
            self.ops.note_kill(step, f)
        if f.get("kind") == "picked_up":
            for it in f.get("items") or []:
                if isinstance(it, dict) and it.get("world_item"):
                    self._picked.append(str(it["world_item"]))

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
            self._busy = False

    def _tick(self) -> None:
        self.proxy.serve()
        self.store.ingest_inbox(lambda r: apply_inbox_record(self.ops, r))
        self._collect_learning()
        self._collect_decision()
        self._revoice_help()
        if self.ops.b.paused:
            return
        task = self.ops.pick_current()
        if task is None:
            return
        if self._future is not None:
            return
        aw = self.ops.b.awaiting_decision
        if aw and aw.get("task_id") != task.id:
            aw = None
        if aw is None and self._needs_plan(task):
            aw = self._need(task, "curriculum" if task.kind == "open" else "plan", {})
        if aw is not None:
            self._dispatch(task, aw)
            return
        if self.port.busy() or self.port.chat_pending():
            return
        if task.status == "preempted" and not self._resume_ok():
            return
        self._advance(task)

    def _needs_plan(self, task: Task) -> bool:
        if task.kind == "specific" and task.success is None:
            return True
        if task.next_step() is None:
            if task.kind == "open" and self.ops.yield_open():
                return False
            return True
        return False

    def _need(self, task: Task, kind: str, detail: dict) -> dict:
        aw = {"task_id": task.id, "kind": kind, "since": self.clock(), "detail": detail}
        self.ops.b.awaiting_decision = aw
        self.store.save()
        return aw

    def _resume_ok(self) -> bool:
        if self._last_command_at is not None and self.clock() - self._last_command_at < RESUME_IDLE_S:
            return False
        state = self._last_state or {}
        return not state.get("following")

    # ---------------------------------------------------------------- budget

    def _can_think(self, n: int = 1) -> bool:
        if self.budget is not None and not self.budget.allows("director"):
            return False
        return self.window.allows(n)

    def _wait_min(self) -> int:
        return max(1, round(self.window.wait_s() / 60))

    # ---------------------------------------------------------------- decisions

    def _dispatch(self, task: Task, aw: dict) -> None:
        if not self._can_think(MAX_REQUESTS):
            if task.status != "waiting_budget":
                task.status = "waiting_budget"
                self.store.save()
            key = f"{task.id}:{int(self.window.wait_s() // 600)}"
            if self._budget_said != key:
                self._budget_said = key
                out_today = self.budget is not None and not self.budget.allows("director")
                self._notice(task, "I'm out of thinking budget for today, so I'll keep to what I already know."
                             if out_today else f"I'll plan my next step for '{task.text}' in about {self._wait_min()} min.",
                             {"budget_wait_min": None if out_today else self._wait_min()})
            return
        if task.status == "waiting_budget":
            task.status = "active"
        state = self.port.state()
        self._last_state = state if isinstance(state, dict) else {}
        snap = self._snapshot(task, aw, self._last_state)
        self._pending = {"task_id": task.id, "version": self.ops.b.version, "aw": aw, "started": self.clock(),
                         "snapshot_state": self._last_state}
        self._log("director_dispatch", task=task.id, decision=aw["kind"])
        self._future = self.executor.submit(self._decide, snap)

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
        for s in cur.get("steps", []):
            s.pop("segments", None)
            s.pop("activation", None)
            s["success_words"] = None
        for s, m in zip(task.steps, cur.get("steps", [])):
            m["success_words"] = P.describe(s.success)
        ctx = self.ops.task_ctx(task, state, self.places())
        prog = P.evaluate(task.success["predicate"], state, ctx).to_dict() if task.success else None
        return {"kind": aw["kind"], "detail": aw.get("detail") or {}, "task": cur, "task_progress": prog,
                "board": board, "state": copy.deepcopy(state), "compact": _compact_state(state),
                "map": self.map_memory.snapshot() if self.map_memory is not None else {},
                "facts": self.memory.snapshot(), "learned": learned, "gaps": self.gaps.rows()[:12],
                "places": copy.deepcopy(self.places()), "now": self.clock(),
                "efficiency": aw.get("detail", {}).get("efficiency")}

    def _messages(self, snap: dict) -> list[dict]:
        tools = "\n".join(f"- {n}: {d}" for n, d in sorted(self.body_tools.items())) or "- (unknown)"
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
            user["curriculum"] = {"skills": skills_progress(snap["state"])["skills"]}
        return [{"role": "system", "content": system},
                {"role": "user", "content": json.dumps(user, default=str, ensure_ascii=False)}]

    def _decide(self, snap: dict) -> Decision:
        """Worker thread: model requests over the snapshot. Writes nothing (the agent loop applies the result)."""
        dec = Decision(kind=snap["kind"])
        research = Research(snap, self.knowledge, self.proxy, set(self.body_tools))
        count = {"n": 0}

        def before() -> bool:
            if count["n"] >= MAX_REQUESTS:
                return False
            if self.budget is not None and not self.budget.allows("director"):
                return False
            count["n"] += 1
            return True

        def on_response(resp, msgs) -> None:
            self._log("llm_response", component="director", model=getattr(self.llm, "model", "?"),
                      content=(resp.content or "")[:4000], tool_calls=[c.name for c in resp.tool_calls],
                      usage=resp.usage)

        validator = Validator(snap["kind"], snap["state"], snap["task"], self.items, places=snap.get("places"))
        episode = getattr(self.log, "episode", None)
        new_id = getattr(self.log, "new_episode_id", None)
        ctx = episode(new_id("director")) if callable(episode) and callable(new_id) else _nullcontext()
        with ctx:
            messages = self._messages(snap)
            self._log("prompt", component="director", model=getattr(self.llm, "model", "?"), decision=snap["kind"],
                      task=snap["task"]["id"], messages=messages)
            try:
                dec.value, info = json_decision(self.llm, messages, validator, tools=research.tools(),
                                                run_tool=research.run, max_tool_rounds=3, max_repairs=2,
                                                before_request=before, on_response=on_response)
                dec.tool_calls = info["tool_calls"]
            except BudgetStop as exc:
                dec.error, dec.budget_stop = str(exc), True
            except DecisionError as exc:
                dec.error = str(exc)
            except Exception as exc:  # provider errors etc.
                dec.error = f"planning call failed: {exc!r}"[:300]
        dec.requests = count["n"]
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
        stale = self.ops.b.version != pend.get("version")
        task = self.ops.b.task(pend.get("task_id"))
        if dec.requests:
            self.window.spend(dec.requests)
        for lk in dec.lookups:
            self._log("director_lookup", query=lk["query"], needed=lk["needed"])
            if lk.get("top"):
                self.memory.put(lk["query"], lk["top"]["text"], lk["top"]["source"], save=False)
        if dec.lookups:
            self.memory.save()
        if task is None or task.status in ENDED or task.status == "paused" or stale:
            self._log("director_discarded", task=pend.get("task_id"), stale=stale,
                      status=task.status if task else None)
            return
        if dec.error:
            if dec.budget_stop:
                return  # waits for budget at the next tick (said there)
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
        for g in v.get("capability_gaps", []):
            rec = self.gaps.record(str(g["primitive"]), source="director", task=task.text, why=g.get("why"),
                                   workaround=g.get("workaround"))
            if rec.get("tool_exists"):
                task.history.append({"title": "note", "outcome": "claim",
                                     "reason": f"'{g['primitive']}' is one of your tools; use it"})
            elif rec.get("new_for_task"):
                self._tell.setdefault(task.id, []).append(
                    f"I can't {g['primitive']} yet" + (f" ({g.get('why')})" if g.get("why") else "")
                    + (f"; workaround: {g['workaround']}" if g.get("workaround") else ""))
        if v.get("ask_help"):
            self._ask_help(task, str(v["ask_help"]))
            return
        if v.get("done") and task.kind == "open":
            self._finish_task(task, "done", "ended by choice")
            return
        if kind == "replan":
            task.replans += 1
            if task.replans > MAX_REPLANS:
                self._ask_help(task, None, f"replanned {MAX_REPLANS} times without finishing")
                return
        existing = {(s.title, json.dumps(s.success, sort_keys=True)): s for s in task.steps if s.status == "pending"}
        failed_out = {(s.title, json.dumps(s.success, sort_keys=True)) for s in task.steps
                      if s.status == "failed" and s.attempts >= s.max_attempts}
        new_steps = []
        for s in v.get("steps", []):
            key = (s["title"], json.dumps(s["success"], sort_keys=True))
            if key in failed_out:
                task.history.append({"title": s["title"], "outcome": "not re-added",
                                     "reason": "this exact step already failed twice"})
                continue
            old = existing.get(key)  # the same step again keeps its attempts; the new plan's details win
            if old is not None:
                for f in ("why", "hints", "abort_if", "escape", "risk", "needs", "group", "trivial"):
                    setattr(old, f, s.get(f, getattr(old, f)))
                old.prepared = old.prepared or kind == "prepare" or not old.risk
                new_steps.append(old)
            else:
                new_steps.append(Step(**{**s, "prepared": kind == "prepare" or not s.get("risk")}))
        loops = {g: Loop(until=u) for g, u in (v.get("loops") or {}).items()}
        if new_steps or kind not in ("review", "reflect"):  # a review that keeps the plan returns no steps
            self.ops.set_steps(task, new_steps, loops=loops, replace_active=kind not in ("review", "reflect"))
        if self.ops.record_decision(task, state, self.places(), new_done=self._done_since_last(task)):
            self._ask_help(task, None, "no progress over my last three plans")
        self.store.save()

    def _done_since_last(self, task: Task) -> bool:
        """A step finished since the previous decision on this task (the task-level progress rule)."""
        n = sum(1 for s in task.steps if s.status == "done")
        key = f"done:{task.id}"
        seen = self._last_review.get(key)
        self._last_review[key] = n
        return seen is not None and n > seen

    # ---------------------------------------------------------------- steps (the executor bridge)

    def _advance(self, task: Task) -> None:
        step = task.next_step()
        if step is None:
            return
        state = self.port.state()
        self._last_state = state if isinstance(state, dict) else {}
        places = self.places()
        if step.status == "pending":
            if step.risk and not step.prepared:
                self._need(task, "prepare", {"prepare_for": step.title, "step_id": step.id})
                return
            self.ops.activate(step, state)
            r = P.evaluate(step.success, state, self.ops.step_ctx(task, step, state, places))
            if r.passed is None:
                self.gaps.from_uncheckable(r.missing, task=task.text, step=step.title)
                self._fail_attempt(task, step, f"its test can't be checked ({', '.join(r.missing)})", r)
                return
            if r.passed is True:  # already true when it comes up (e.g. already standing there): no run needed
                step.trivial = True
                self._step_done(task, step, r, state)
                return
        if task.status == "preempted":
            task.status = "active"
        if step.started and self.clock() - step.started > STEP_WALL_S:
            self._park_step(task, step, "this step has taken too long")
            return
        self._review_due(task)
        self._run(task, step, state)

    def _review_due(self, task: Task) -> None:
        last = self._last_review.get(task.id)
        now = self.clock()
        if last is None:
            self._last_review[task.id] = now
            return
        if now - last >= REVIEW_EVERY_S and self.window.left() >= self.window.per_hour / 2:
            self._last_review[task.id] = now
            self._need(task, "review", {})

    def _event(self, task: Task, step: Step, state: dict, r: P.Result | None) -> dict:
        ev: dict[str, Any] = {"type": "board_step", "instructions": STEP_INSTRUCTIONS, "task": task.text,
                              "step": {"title": step.title, "why": step.why, "hints": step.hints},
                              "step_done_when": P.describe(step.success), "run": step.runs + 1,
                              "max_runs": step.max_runs}
        if task.success:
            ev["job_done_when"] = P.describe(task.success["predicate"])
        if r is not None:
            ev["step_progress"] = r.detail
        if step.escape:
            ev["step"]["escape"] = step.escape
        if self._last_results.get(step.id):
            ev["last_results"] = self._last_results[step.id]
        if self._report_note.pop(step.id, None):
            ev["note"] = "you reported this step done, but the game shows: " + (r.detail if r else "not yet")
        if task.status == "preempted" or self._preempted_by:
            ev["resumed"] = True
            if self._preempted_by:
                ev["preempted_by"] = self._preempted_by
                if "stop" in self._preempted_by.get("tools", []):
                    ev["paused_by_player"] = True
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

    def _run(self, task: Task, step: Step, state0: dict) -> None:
        places = self.places()
        r0 = P.evaluate(step.success, state0, self.ops.step_ctx(task, step, state0, places))
        self.ops.open_segment(step, state0)
        event = self._event(task, step, state0, r0)
        self._preempted_by = None
        self._report, self._picked = None, []
        self._in_run = True
        try:
            res = self.port.run(event)
        finally:
            self._in_run = False
        state1 = self.port.state()
        self._last_state = state1 if isinstance(state1, dict) else {}
        recs = res.get("actions") or []
        board_recs = [x for x in recs if x.get("origin", "board") == "board"]
        chat_recs = [x for x in recs if x.get("origin") == "chat"]
        tainted = set().union(*[_items_touched(x) for x in chat_recs]) if chat_recs else set()
        picked = [w for x in board_recs for w in _picked_world_items(x)] + self._picked
        for x in board_recs:
            d = x.get("data") if isinstance(x.get("data"), dict) else {}
            if x.get("tool") == "drop" and x.get("ok"):
                self.ops.note_drop(task, d.get("world_items") or [], d.get("item"), d.get("count"))
        gains = self.ops.close_segment(task, step, state1, tainted=tainted, repicked=self.ops.repicked(task, picked))
        step.actions = (step.actions + board_recs)[-40:]
        self._last_results[step.id] = [{"tool": x.get("tool"), "ok": x.get("ok"), "reason": x.get("reason")}
                                       for x in board_recs][-8:]
        self._body_findings(task, step, board_recs, state1)
        ctx = self.ops.step_ctx(task, step, state1, places)
        if step.abort_if is not None and P.evaluate(step.abort_if, state1, ctx).passed is True:
            self.ops.finish_step(task, step, "aborted", "its abort condition came true")
            self._need(task, "replan", {"failed": {"step": step.title, "reason": "aborted: " +
                                                   P.evaluate(step.abort_if, state1, ctx).detail}})
            return
        r = P.evaluate(step.success, state1, ctx)
        self._log("board_run", task=task.id, step=step.title, ended=res.get("ended"), passed=r.passed,
                  detail=r.detail, gains=gains, actions=[(x.get("tool"), x.get("ok")) for x in board_recs])
        if r.passed is True:
            self._step_done(task, step, r, state1)
            return
        if r.passed is None:
            self.gaps.from_uncheckable(r.missing, task=task.text, step=step.title)
            self._fail_attempt(task, step, f"its test can't be checked ({', '.join(r.missing)})", r)
            return
        if self._report and self._report.get("outcome") == "blocked":
            self._fail_attempt(task, step, f"blocked: {self._report.get('reason')}", r)
            return
        if self._report and self._report.get("outcome") == "done":
            self._report_note[step.id] = r.detail
        if res.get("ended") in ("chat", "interrupted"):  # not the step's fault (H7c), but capped (re-check 3)
            step.uncounted_runs += 1
            if step.uncounted_runs > UNCOUNTED_FACTOR * step.max_runs:
                self._park_step(task, step, "chat kept interrupting me")
            self.store.save()
            return
        step.runs += 1
        meas = _progress_measures(r.measures)
        moved = P.grew(step.last_measures, meas) or (bool(gains) and any(x.get("ok") for x in board_recs))
        step.no_progress_runs = 0 if moved else step.no_progress_runs + 1
        step.last_measures = meas
        if step.no_progress_runs >= 2:
            self._fail_attempt(task, step, f"no progress: {r.detail}", r)
        elif step.runs >= step.max_runs:
            self._fail_attempt(task, step, f"ran {step.runs} times without finishing: {r.detail}", r)
        else:
            self.store.save()

    def _body_findings(self, task: Task, step: Step, recs: list[dict], state: dict) -> None:
        for x in recs:
            if x.get("ok"):
                continue
            rec = self.gaps.from_tool_result(str(x.get("tool")), x, task=task.text, step=step.title)
            if rec and rec.get("new_for_task"):
                self._tell.setdefault(task.id, []).append(f"I can't {x.get('tool')} yet")
            if x.get("reason") == "nothing_in_range" and self.map_memory is not None:
                what = (x.get("args") or {}).get("resource") or (x.get("data") or {}).get("item")
                try:
                    self.map_memory.note_negative(what, state.get("position"), "nothing_in_range", kind="empty")
                except Exception as exc:
                    self._log("map_memory_error", error=repr(exc))

    def _fail_attempt(self, task: Task, step: Step, reason: str, r: P.Result | None) -> None:
        final = step.attempts >= step.max_attempts
        step.failures.append({"reason": reason, "detail": r.detail if r else None, "at": self.clock(),
                              "attempt": step.attempts})
        if final:
            self.ops.finish_step(task, step, "failed", reason)
        else:
            step.status = "pending"
            self.store.save()
        self._need(task, "replan", {"failed": {"step": step.title, "reason": reason, "attempt": step.attempts,
                                               "last_actions": self._last_results.get(step.id, [])}})

    def _park_step(self, task: Task, step: Step, reason: str) -> None:
        self.ops.finish_step(task, step, "parked", reason)
        self.ops.park(task, reason)
        self._notice(task, f"I've put '{task.text}' aside: {reason}.", {"why": reason})

    def _step_done(self, task: Task, step: Step, r: P.Result, state: dict) -> None:
        secs = sum((s.end or self.clock()) - s.start for s in step.segments)
        self.ops.finish_step(task, step, "done")
        facts: dict[str, Any] = {"step": step.title, "result": r.detail, "minutes": round(secs / 60, 1)}
        rates = []
        for item, n in {k: v for k, v in step.accumulated.items() if v > 0}.items():
            rate = self.efficiency.rate(n, secs)
            rates.append((f"item:{item}", self.efficiency.record(f"item:{item}", rate)))
        for k, (dl, dx) in step.skill_accumulated.items():
            if dx:
                rates.append((f"xp:{k}", self.efficiency.record(f"xp:{k}", self.efficiency.rate(dx, secs))))
        if task.tallies:
            facts["collected"] = dict(task.tallies)
        self._just_completed[task.id] = facts
        self._maybe_learn(task, step, state)
        out = self.ops.requeue_loop(task, step, state, self.places())
        if out.startswith("capped:"):
            self._need(task, "replan", {"failed": {"step": step.title, "reason": "loop ended: " + out[7:]}})
        elif out == "requeued":
            lp = task.loops.get(step.group or "")
            slow = [(k, x) for k, x in rates if x.get("ratio") is not None and x["ratio"] < REFLECT_RATIO]
            if slow or (lp is not None and lp.done % REFLECT_EVERY_LOOPS == 0):
                self._need(task, "reflect", {"efficiency": [{"key": k, **x} for k, x in rates]})
                for k, x in rates:
                    self.efficiency.log_reflection(task.text, step.title, k, x.get("rate"), x.get("best"),
                                                   ["spells", "other known spots", "lodestones", "tools"], None)
        if task.success is not None:
            tr = P.evaluate(task.success["predicate"], state, self.ops.task_ctx(task, state, self.places()))
            if tr.passed is True:
                self._finish_task(task, "done", tr.detail)

    def _finish_task(self, task: Task, status: str, detail: str) -> None:
        self.ops.end_task(task, status, detail)
        self.store.save()
        facts = {"job": task.text, "result": detail, "collected": task.tallies or None}
        self._notice(task, f"Done with '{task.text}'.", facts, kind="task_report")

    def _ask_help(self, task: Task, question: str | None, why: str | None = None) -> None:
        q = question or f"I'm stuck on '{task.text}' ({why}). Any idea how I should go about it?"
        seen = (self._last_state or {}).get("players")
        names = [p.get("name") for p in seen or [] if isinstance(p, dict)]
        asked = task.by.split(":", 1)[1] if task.by.startswith("player:") else (names[0] if names else None)
        self.ops.park(task, why or "needs help", question=q, player=asked)
        task.help.asked_at = self.clock()
        if isinstance(seen, list) and (not asked or asked not in names):
            task.help.revoice_pending = True  # nobody to ask here: say it when that player is around (review M1)
            self.store.save()
            return
        self._notice(task, q, {"question": q}, kind="board_notice")

    def _revoice_help(self) -> None:
        names = {p.get("name") for p in (self._last_state or {}).get("players") or [] if isinstance(p, dict)}
        for t in self.ops.b.tasks:
            if t.status == "waiting_help" and t.help and t.help.revoice_pending and                     (t.help.asked_player in names or (not t.help.asked_player and names)):
                t.help.revoice_pending = False
                self.store.save()
                self._notice(t, t.help.question, {"question": t.help.question}, kind="board_notice")

    def _notice(self, task: Task, template: str, facts: dict, kind: str = "board_notice") -> None:
        """A failure, gap, help question, budget wait or task end: the Controller says it (single voice); the
        template only when the model said nothing (principle 7, review M10)."""
        ev = {"type": "board_notice", "instructions": NOTICE_INSTRUCTIONS, "about": kind, "task": task.text,
              "facts": facts}
        said = False
        if not self._busy_run_blocked():
            self._in_run = True
            try:
                res = self.port.run(ev)
                said = bool(res.get("said"))
            except Exception as exc:
                self._log("notice_error", error=repr(exc))
            finally:
                self._in_run = False
        if not said:
            self.port.say(template)

    def _busy_run_blocked(self) -> bool:
        return self.port.chat_pending()

    # ---------------------------------------------------------------- skill learning (re-check 4)

    def _maybe_learn(self, task: Task, step: Step, state: dict) -> None:
        if self.skills is None or self.skills_registry is None or self._learn_future is not None:
            return
        body = [x for x in step.actions if x.get("ok") and x.get("tool") in self.skills_registry]
        if len(body) < 2 or self.window.left() < LEARN_MIN_WINDOW * self.window.per_hour:
            return
        sig = (task.id, json.dumps([(x["tool"], x.get("args")) for x in body], sort_keys=True, default=str))
        if sig in self._learn_tried:  # the same actions again (a loop, a repeated step): nothing new to learn
            return
        self._learn_tried.add(sig)
        if self.budget is not None and not self.budget.allows("director"):
            return
        from .skill_library import SkillLibrary
        from .state_store import Task as PlanTask
        tasks = [PlanTask(skill=x["tool"], args=x.get("args") or {}, status="done") for x in body]
        worker_lib = SkillLibrary(self.skills.dir)  # the worker's own instance (own SQLite); it writes nothing
        snap = copy.deepcopy(state)
        reg = self.skills_registry
        self._learn_pending = {"goal": step.title, "tasks": tasks, "started": self.clock()}

        def job():
            return worker_lib.propose(step.title, tasks, snap, self.llm, reg)
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
        state = self.port.state()
        rec = self.skills.accept(proposal, pend["goal"], pend["tasks"], state, self.skills_registry,
                                 seconds=self.clock() - pend["started"])
        self._log("director_skill_learned" if rec else "director_skill_rejected", goal=pend["goal"],
                  name=getattr(rec, "name", None))

    # ---------------------------------------------------------------- misc

    def _log(self, kind: str, **data: Any) -> None:
        if self.log is not None:
            self.log.log(kind, **data)


class _nullcontext:
    def __enter__(self):
        return None

    def __exit__(self, *exc):
        return False


def score_lookups(lookups: list[dict], facts: list[dict], tool_calls: list[dict]) -> list[dict]:
    """needed: True when the lookup answers a fact the plan listed as unknown; False when it repeats an earlier
    lookup or recall of the same decision (needless); None when neither can be told (wave 5: Sonnet researches
    before it writes its facts, so "not listed" is not "needless")."""
    seen: list[set[str]] = []
    queries = [P.tokens(str((c.get("args") or {}).get("query") or "")) for c in tool_calls
               if c.get("name") in ("recall", "lookup")]
    out = []
    for lk in lookups:
        q = P.tokens(lk["query"])
        idx = next((i for i, x in enumerate(queries) if x == q), None)
        earlier = queries[:idx] if idx is not None else seen
        repeat = any(q and len(q & e) * 2 >= len(q) for e in earlier)
        needed = True if matches_unknown(lk["query"], facts) else (False if repeat else None)
        seen.append(q)
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

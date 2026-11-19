"""One registry of the tools the models are offered (Luis 2026-11-18: one place, not a copy per model).

Each tool is declared once: its schema, whether it is read-only (it never acts on the body and writes no store) and,
for a read the brain answers, its handler over a ReadContext. A body tool is declared by the body itself (its
capability manifest, brain/capabilities.py); the registry only reads that declaration: a body tool is read-only when
the manifest says kind "read" and moves false.

Views:
* controller_view(): the Controller's full list, in the order it always had (manifest tools, rule tools, brain tools,
  the task board's tools). tests/test_tool_registry.py holds it byte-identical to the list before the registry.
* read_view(ctx, only): the read-only tools that can run in this context, limited to an allow-list: the Director's
  research (DIRECTOR_READS) and the Planner's (PLANNER_READS). run_read(ctx, name, args, offered) answers one.

A ReadContext is a snapshot (state, facts, map, learned skills) plus read-only services (the knowledge index, a body
read through brain.director.BodyProxy), so a read can run on a worker thread beside the Controller's turn: it shares
no mutable state with it.
"""
from __future__ import annotations

import copy
import queue
import threading
import time
from dataclasses import dataclass, field
from typing import Any, Callable

import jsonschema

from .interface import BRAIN_TOOLS, READ_TOOLS, RULE_TOOLS, TOOLS, Reason, tool_schema

# The acting tools offered from the brain's own schemas when the body publishes no manifest (mock, server puppet).
ACTION_TOOLS = ["follow", "stop", "go_to", "attack", "give", "pickup", "drop", "cast", "sleep", "wake", "interact",
                "gather"]


def fn(name: str, description: str, props: dict, required: list[str] | None = None) -> dict:
    return {"type": "function", "function": {"name": name, "description": description, "parameters": {
        "type": "object", "properties": props, **({"required": required} if required else {})}}}


@dataclass(frozen=True)
class ToolDef:
    name: str
    read_only: bool
    origin: str  # "brain": answered in the brain; "body": the client answers it
    schema: dict | None = None  # None: the schema comes from elsewhere (interface.TOOLS, or the body's manifest)
    handler: Callable[["ReadContext", dict], Any] | None = None  # a brain read over a ReadContext


@dataclass
class ReadContext:
    """What a read may touch. ``snap`` is a copy (state, facts, map, learned, now, body_tools); ``knowledge`` is
    read-only; ``body(tool, args)`` is a body read (BodyProxy.request), None when the body cannot be read."""
    snap: dict = field(default_factory=dict)
    knowledge: Any = None
    body: Callable[[str, dict], dict] | None = None
    body_tools: set[str] = field(default_factory=set)
    manifest: dict = field(default_factory=dict)


# ------------------------------------------------------------------------------ brain-answered reads (handlers)


def _lookup(ctx: ReadContext, args: dict) -> Any:
    from .knowledge import node_gates  # the gates of the nodes he perceives: a gathered item's card names them
    gates = node_gates(ctx.snap.get("state"))
    if gates:
        res = ctx.knowledge.lookup(str(args.get("query") or ""), args.get("kind"), gates=gates)
    else:
        res = ctx.knowledge.lookup(str(args.get("query") or ""), args.get("kind"))
    # a vault's card carries its enemies' PL against his armour and the armour he can reach at that PL (gear_plan
    # for_vault). L3 2026-11-19: the card said "power level 2" and nothing tied it to his gear; he chased PL 3 bronze
    state = ctx.snap.get("state") or {}
    rows = ((res or {}).get("data") or {}).get("results") if isinstance(res, dict) else None
    if state and isinstance(rows, list):
        from . import gear_plan
        done: set[str] = set()
        for i, r in enumerate(rows):
            if not isinstance(r, dict) or r.get("kind") != "vault" or not r.get("title") or r["title"] in done:
                continue
            done.add(r["title"])
            try:
                facts = gear_plan.for_vault(state, r["title"], stash=state.get("containers_remembered") or None)
            except Exception as exc:  # a gap in the data: the card stands, and says why it has no gear facts
                facts = {"unavailable": f"{type(exc).__name__}: {exc}"[:200]}
            # a copy (the index's own row is never changed), the facts right after the title: the planner_research
            # log row keeps a result's first 2000 characters, and the card's text runs longer
            head = {k: r[k] for k in ("source", "authoritative", "kind", "title") if k in r}
            rows[i] = {**head, "gear_for_vault": facts, **{k: v for k, v in r.items() if k not in head}}
    return res


def _recall(ctx: ReadContext, args: dict) -> Any:
    from .knowledge_memory import recall
    return {"facts": recall(ctx.snap.get("facts") or {}, str(args.get("query") or ""))}


def _compare_gear(ctx: ReadContext, args: dict) -> Any:
    from .director import compare_gear
    return compare_gear(ctx.snap.get("state") or {}, args.get("category"), args.get("slot"), int(args.get("limit") or 8))


def _map_memory(ctx: ReadContext, args: dict) -> Any:
    from .map_memory import query  # the capability agent's store (pure query over a snapshot)
    mem = ctx.snap.get("map") or {}
    rows = query(mem, kind=args.get("kind"), name=args.get("name"), item=args.get("item"),
                 near=(ctx.snap.get("state") or {}).get("position"), limit=int(args.get("limit") or 8),
                 now=ctx.snap.get("now"))
    neg = [n for n in mem.get("negative") or [] if not args.get("item") or n.get("item") == args.get("item")]
    return {"seen": rows, "empty_or_mined_out": neg[-8:]}


def _skills_progress(ctx: ReadContext, args: dict) -> Any:
    from .director import skills_progress
    return skills_progress(ctx.snap.get("state") or {}, ctx.snap.get("body_tools"))


def _learned_skills(ctx: ReadContext, args: dict) -> Any:
    import json
    from . import predicates as P
    q = P.tokens(str(args.get("query") or ""))
    return {"skills": [s for s in ctx.snap.get("learned", []) if not q or q & P.tokens(json.dumps(s))]}


def _food_options(ctx: ReadContext, args: dict) -> Any:
    from . import needs_options
    want = args.get("need")
    kinds = [want] if want in ("food", "drink") else ["food", "drink"]
    try:
        return {"ok": True, "data": {k: needs_options.options_for(ctx.snap.get("state") or {}, k) for k in kinds}}
    except Exception as exc:  # a broken digest never breaks the turn: the model hears why
        return {"ok": False, "reason": "unavailable", "error": f"{type(exc).__name__}: {exc}"[:300]}


# ------------------------------------------------------------------------------ declarations

START_GOAL = {
    "type": "function",
    "function": {
        "name": "start_goal",
        "description": ("Hand a long job of many steps to your planner (e.g. 'gather 10 logs and bring them to the "
                        "player', 'build a storage hut by the lake'): it plans the steps with your tools, runs them, "
                        "checks each in the game and reports back. A job one tool or a few calls in a row can do: call "
                        "them yourself. A learned skill that fits: run_skill."),
        "parameters": {"type": "object", "properties": {"goal": {"type": "string", "description":
                       "The job in plain words, as he asked for it."}}, "required": ["goal"]},
    },
}
# DW_ASYNC_PLAN=1 only (brain/plan_async.py): his own first steps, run while the Planner composes (agent._run_goal)
FIRST_STEPS = {"type": "array", "minItems": 1, "maxItems": 3, "description": (
    "Optional: 1 to 3 calls of your own tools that start the job, each {skill: tool name, args}. They run now, "
    "while your planner makes the plan; its plan replaces the steps not yet started."),
    "items": {"type": "object", "properties": {"skill": {"type": "string"}, "args": {"type": "object"}},
              "required": ["skill"]}}
START_GOAL_FIRST_STEPS = {"type": "function", "function": {
    **START_GOAL["function"], "parameters": {**START_GOAL["function"]["parameters"], "properties": {
        **START_GOAL["function"]["parameters"]["properties"], "first_steps": FIRST_STEPS}}}}


def start_goal_schema() -> dict:
    """start_goal as offered: with first_steps under DW_ASYNC_PLAN=1, else exactly as before."""
    from . import plan_async
    return START_GOAL_FIRST_STEPS if plan_async.enabled() else START_GOAL


LIST_SKILLS = {
    "type": "function",
    "function": {"name": "list_skills", "description": "Read-only: the skills you have learned, with how often each worked.",
                 "parameters": {"type": "object", "properties": {}}},
}
FOOD_OPTIONS = {  # brain/needs_options.py: the same digest situation shows when food or water is low, on demand
    "type": "function",
    "function": {"name": "food_options", "description": (
        "Read-only: your food or water options right now, each with what it restores, your level after, where it "
        "is, the steps, an estimated time and the risk. situation shows them by itself when a need is low."),
        "parameters": {"type": "object", "properties": {"need": {"type": "string", "enum": ["food", "drink"],
                       "description": "Leave out for both."}}}},
}
FORGET_SKILL = {
    "type": "function",
    "function": {"name": "forget_skill", "description": "Delete one learned skill by its exact name (from list_skills).",
                 "parameters": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}},
}

# Body reads the brain documents itself, for a body that publishes no manifest entry for them (an old body, tests);
# when the body publishes one, its own declaration is used.
BODY_READ_FALLBACK = {
    "craft_plan": fn("craft_plan", "Plan additional item production by default, or an inventory target; "
                     "the tree shows ingredients, acquisition alternatives and execution uncertainty.",
                     {"item": {"type": "string"},
                      "count": {"type": "integer", "description": "Additional item units, or final stock units in inventory_target mode."},
                      "quantity_mode": {"type": "string", "enum": ["additional_output", "inventory_target"],
                                        "default": "additional_output"}}, ["item"]),
    "recipes": fn("recipes", "Recipes: for an item (every recipe and its status) or a station type.",
                  {"item": {"type": "string"}, "station": {"type": "string"}}),
    "stations": fn("stations", "Crafting and processing stations near him and their state.", {}),
    "buildables": fn("buildables", "Pieces he has unlocked: name, material cost, what he still lacks. A station he "
                     "needs and doesn't have is often a piece to build. can_build_now keeps only those he has the "
                     "materials for on him; the reply's cannot_build_now tells which matching pieces that left out "
                     "and what each lacks.",
                     {"about": {"type": "string"}, "can_build_now": {"type": "boolean"}}),
}

DECLARED: dict[str, ToolDef] = {d.name: d for d in [
    # brain tools from interface.TOOLS (schema from its args model)
    ToolDef("lookup", True, "brain", handler=_lookup),
    ToolDef("remember", False, "brain"),
    ToolDef("run_skill", False, "brain"),
    ToolDef("start_goal", False, "brain", START_GOAL),
    ToolDef("list_skills", True, "brain", LIST_SKILLS),  # reads the Controller's live skill library: its own turn
    ToolDef("forget_skill", False, "brain", FORGET_SKILL),
    ToolDef("food_options", True, "brain", FOOD_OPTIONS, _food_options),
    # brain reads over a snapshot (the Director's research since wave 5)
    ToolDef("recall", True, "brain", fn("recall", "Facts you looked up or saw before (cached, with source and "
                                        "confidence). Check this first.", {"query": {"type": "string"}}, ["query"]),
            _recall),
    ToolDef("compare_gear", True, "brain", fn(
        "compare_gear", "Catalog items of a category (e.g. a tool or weapon kind) or slot with their stats, his best "
        "one now (held or carried), the deltas, and whether a recipe makes each.",
        {"category": {"type": "string"}, "slot": {"type": "string"}, "limit": {"type": "integer"}}), _compare_gear),
    ToolDef("map_memory", True, "brain", fn(
        "map_memory", "Places he has seen things (stations, resources, creatures, lodestones, beds, graves...), "
        "nearest first, and spots found empty or mined out.",
        {"kind": {"type": "string"}, "name": {"type": "string"}, "item": {"type": "string"},
         "limit": {"type": "integer"}}), _map_memory),
    ToolDef("skills_progress", True, "brain", fn(
        "skills_progress", "His skills, lowest first: level, xp, how each is trained (wiki), the recipes that award "
        "its XP and his tools that name it.", {}), _skills_progress),
    ToolDef("learned_skills", True, "brain", fn(
        "learned_skills", "Routines he learned before (learned skills) that match the words.",
        {"query": {"type": "string"}}), _learned_skills),
]}

# The allow-lists over the read-only view.
DIRECTOR_READS = ("recall", "lookup", "compare_gear", "map_memory", "skills_progress", "learned_skills",
                  "craft_plan", "recipes", "stations", "buildables", "look", "lodestones")
# The Planner's: the knowledge index, the facts he cached, the body's recipe tree (0.5 s) and buildable pieces (0.3 s).
# Left out: inventory (the Planner's state already carries it), combat_brief (reads a creature loaded near him, which a
# plan made before the trip does not have), list_skills (learned routines are no Planner skill, and it reads the
# Controller's live library), food_options (eating is the stay-fed reflex's and the Controller's), look (the state's
# nearby lists already).
PLANNER_READS = ("lookup", "recall", "craft_plan", "buildables")


def lookup_schema(knowledge) -> dict:
    """The lookup tool as the Controller has always been offered it: the kinds it can filter on from the index."""
    kinds = ", ".join(knowledge.kinds()) if knowledge is not None else ""
    return tool_schema("lookup", TOOLS["lookup"][1] + (f" kind values: {kinds}." if kinds else ""))


def brain_schema(name: str, knowledge=None) -> dict:
    if name == "lookup":
        return lookup_schema(knowledge)
    d = DECLARED.get(name)
    return d.schema if d is not None and d.schema is not None else tool_schema(name)


def body_read_entry(manifest: dict, name: str) -> dict | None:
    """The body's own declaration of a read: kind read, moves false, published args. Else None."""
    e = (manifest or {}).get(name) or {}
    if e.get("kind") == "read" and e.get("moves") is False and isinstance(e.get("args"), dict):
        return e
    return None


def is_read_only(name: str, manifest: dict | None = None) -> bool:
    d = DECLARED.get(name)
    if d is not None:
        return d.read_only
    return body_read_entry(manifest or {}, name) is not None or (not manifest and name in BODY_READ_FALLBACK)


# ------------------------------------------------------------------------------ views


def controller_view(*, caps=None, has: Callable[[str], bool] = lambda n: True, knowledge=None, skills: bool = False,
                    director=None) -> list[dict]:
    """The Controller's full list (Controller._schemas), unchanged in content and order."""
    hide_goal = director is not None and director.hides_start_goal
    brain = [brain_schema("remember"), brain_schema("run_skill")] + ([] if hide_goal else [start_goal_schema()]) + \
        ([LIST_SKILLS, FORGET_SKILL] if skills else []) + [FOOD_OPTIONS]
    if knowledge is not None:  # the kinds it can filter on come from the index itself
        brain.insert(0, lookup_schema(knowledge))
    rules = [tool_schema(n) for n in RULE_TOOLS if has(n)]
    if director is not None:
        brain = brain + list(director.tool_schemas())
    if caps is not None:  # the body's manifest: its own descriptions and schemas
        return [caps.function_schema(n) for n in caps.llm_tools()] + rules + brain
    # No manifest (mock, server puppet): the brain's own schemas, still only for tools the body has.
    acts = [n for n in ACTION_TOOLS if has(n)]
    reads = [n for n in READ_TOOLS if has(n) and n not in BRAIN_TOOLS]
    return [tool_schema(n) for n in reads + acts] + rules + brain


def read_view(ctx: ReadContext, only: tuple[str, ...]) -> list[dict]:
    """The read-only tools in ``only`` (in that order) that can run in this context."""
    out = []
    for name in only:
        d = DECLARED.get(name)
        if d is not None:
            if not d.read_only or d.handler is None or (name == "lookup" and ctx.knowledge is None):
                continue
            out.append(lookup_schema(ctx.knowledge) if name == "lookup" else d.schema)
            continue
        if ctx.body is None or name not in ctx.body_tools:
            continue
        if (e := body_read_entry(ctx.manifest, name)) is not None:
            # the body-published schema for a verified read, never a guessed one
            # https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools
            out.append({"type": "function", "function": {
                "name": name, "description": e.get("description") or "Read current body state.", "parameters": e["args"]}})
        elif name not in (ctx.manifest or {}) and name in BODY_READ_FALLBACK:
            out.append(BODY_READ_FALLBACK[name])
    return out


def run_read(ctx: ReadContext, name: str, args: dict, offered: list[dict]) -> Any:
    """Answer one call of an offered read. Errors are results (the model hears them), never exceptions."""
    schemas = {t["function"]["name"]: t["function"]["parameters"] for t in offered}
    if name not in schemas:
        return {"ok": False, "error": f"no research tool {name!r}"}
    try:
        jsonschema.validate(args, schemas[name])
    except (jsonschema.ValidationError, jsonschema.SchemaError) as exc:
        return {"ok": False, "error": f"invalid research arguments: {exc.message}"}
    d = DECLARED.get(name)
    if d is not None and d.handler is not None:
        return d.handler(ctx, args)
    if ctx.body is not None:
        return ctx.body(name, args)
    return {"ok": False, "error": f"no research tool {name!r}"}


# ------------------------------------------------------------------------------ body reads off the loop thread


class BodyProxy:
    """Body reads for the worker, served on the agent loop (the bridge has one owner).

    A worker's read waits at most ``timeout_s`` for the loop to reach it. The loop serves the queue in Agent.pump and,
    under DW_ASYNC_PLAN, between the Controller's tool calls and inside every body wait (BridgeClient.wait_hooks), so
    what keeps a read waiting is the loop being off the bridge (a model call). A read the loop never reached is
    answered then with what held the loop (``holder()``) and how long it waited; nothing was sent to the body. A read
    the loop has started is waited for: its answer is never dropped as "busy" (before 2026-11-18 it was).
    ``log``: a JsonlLogger for one ``body_read_queued`` row per worker read; ``label`` names whose reads they are."""

    def __init__(self, call: Callable[[str, dict], dict], timeout_s: float = 20.0,
                 holder: Callable[[], str | None] | None = None, log: Any = None, label: str = "worker",
                 in_flight_s: float = 60.0):
        self.call = call
        self.timeout_s = timeout_s
        self.owner: int | None = None
        self.q: queue.Queue = queue.Queue()
        self.holder = holder
        self.log = log
        self.label = label
        self.in_flight_s = in_flight_s  # a read already sent: the bridge's own timeout answers before this
        self._serving = False

    def request(self, tool: str, args: dict) -> dict:
        if self.owner is not None and threading.get_ident() == self.owner:
            return self._do(tool, args)
        # Event timeout alone does not cancel queued work; synchronize cancellation with the claim.
        # https://docs.python.org/3/library/threading.html#event-objects
        t0 = time.monotonic()
        box: dict = {"ev": threading.Event(), "lock": threading.Lock(), "cancelled": False,
                     "deadline": t0 + self.timeout_s}
        self.q.put((tool, args, box))
        if not box["ev"].wait(self.timeout_s):
            with box["lock"]:
                started = bool(box.get("started"))
                box["cancelled"] = not started
            if not started:  # never reached: the body was not asked
                waited = round(time.monotonic() - t0, 1)
                held = self._holder()
                self._log(tool, waited, None, held)
                return {"ok": False, "reason": Reason.BUSY, "data": {
                    "detail": (f"not read: the brain loop that talks to your body did not reach this read in "
                               f"{waited:g} s ({held or 'it was busy'}); nothing was asked of the body"),
                    "busy_with": held, "waited_s": waited, "read_sent": False}}
            if not box["ev"].wait(self.in_flight_s):  # sent to the body: its own answer, when it comes
                waited = round(time.monotonic() - t0, 1)
                self._log(tool, waited, box.get("served_in"), "no answer from the body")
                return {"ok": False, "reason": Reason.TIMEOUT, "data": {
                    "detail": f"sent to the body, no answer in {waited:g} s", "waited_s": waited, "read_sent": True}}
        self._log(tool, round(box["claimed_at"] - t0, 2), box.get("served_in"))
        return box["res"]

    def serve(self, where: str = "pump") -> None:
        """Answer the queued reads on this (the bridge's owner) thread. ``where`` is logged: pump, turn, body_wait."""
        if self._serving:  # a read's own body wait runs the wait hooks: never serve inside a serve
            return
        self.owner = threading.get_ident()
        self._serving = True
        try:
            while True:
                try:
                    tool, args, box = self.q.get_nowait()
                except queue.Empty:
                    return
                # Claim only a still-live request; once claimed, the read is already in flight.
                with box["lock"]:
                    if box["cancelled"] or time.monotonic() >= box["deadline"]:
                        continue
                    box["started"] = True
                    box["claimed_at"] = time.monotonic()
                    box["served_in"] = where
                box["res"] = self._do(tool, args)
                box["ev"].set()
        finally:
            self._serving = False

    def _holder(self) -> str | None:
        try:
            return self.holder() if self.holder is not None else None
        except Exception as exc:  # a description is best effort
            return f"unknown ({type(exc).__name__})"

    def _log(self, tool: str, waited_s: float, served_in: str | None, busy_with: str | None = None) -> None:
        if self.log is not None:
            self.log.log("body_read_queued", component=self.label, tool=tool, waited_s=waited_s,
                         served_in=served_in, answered=busy_with is None,
                         **({"busy_with": busy_with} if busy_with else {}))

    def _do(self, tool: str, args: dict) -> dict:
        try:
            return self.call(tool, args)
        except Exception as exc:  # a read failing is information
            return {"ok": False, "reason": Reason.BODY_ERROR, "data": {"error": repr(exc)[:200]}}


# ------------------------------------------------------------------------------ research (Director, Planner)


class Research:
    """Read-only research over an immutable snapshot (safe on a worker thread): the registry's read view."""

    def __init__(self, snap: dict, knowledge=None, proxy: BodyProxy | None = None, body_tools: set[str] = frozenset(),
                 manifest: dict | None = None, only: tuple[str, ...] = DIRECTOR_READS):
        self.snap = snap
        self.knowledge = knowledge
        self.proxy = proxy
        self.body_tools = set(body_tools)
        self.manifest = manifest or {}
        self.only = only
        self.lookups: list[dict] = []
        self.ctx = ReadContext(snap, knowledge, proxy.request if proxy is not None else None, self.body_tools,
                               self.manifest)

    def tools(self) -> list[dict]:
        return read_view(self.ctx, self.only)

    def run(self, name: str, args: dict) -> Any:
        res = run_read(self.ctx, name, args, self.tools())
        if name == "lookup" and self.knowledge is not None and not (isinstance(res, dict) and "error" in res
                                                                    and res.get("ok") is False):
            self.lookups.append({"query": str(args.get("query") or ""), "result": res})
        return res


# The Planner's research (brain/planner.py). Copper job 2026-11-17: the Planner had no tools and planned "explore near
# home" for an ore that grows only in far regions and needs a Bone pickaxe (both in the knowledge index).
def planner_research(knowledge=None, proxy: BodyProxy | None = None, body_tools=(), manifest: dict | None = None,
                     facts: Callable[[], dict] | None = None) -> Callable[[dict], Research]:
    """state -> Research over PLANNER_READS, built in the Planner's own call (a worker thread under DW_ASYNC_PLAN):
    a copy of the state, the facts read fresh, recall only when there are facts to recall."""
    def make(state: dict) -> Research:
        known = (facts() if facts is not None else None) or {}
        only = tuple(n for n in PLANNER_READS if n != "recall" or known)
        return Research({"state": copy.deepcopy(state), "facts": known}, knowledge, proxy, set(body_tools), manifest,
                        only=only)
    return make

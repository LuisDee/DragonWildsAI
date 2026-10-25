"""Controller: interprets chat, decides interrupts, and owns ALL speech.

Only ``Controller.say`` ever calls ``game.say`` (design principle 6). Speech is produced after the
action decision and is overridden if an action fails, so the companion never says one thing while
doing another.

Bounded ReAct loop (research 2026-10-25 sections 3.2 and 6): at most ``max_calls`` (3) model calls
per command. Read-only tools (``look``, ``inspect``) run inline, don't interrupt the current job and
don't end the turn; the first real action (or start_goal / run_skill / remember / a rule tool) ends
it; speech is the text of that final response. With the situation digest preloaded, most commands
take one call; "pick up the sticks" takes two when the sticks aren't in the digest.

Grounding (section 6.2), enforced in code, not only in the prompt: an action on a thing that was
not perceived (state, digest or a look this turn) is refused with ``not_perceived`` and the reply
says "I can't see any X", naming what is there instead. Never a substitute target.

Each model call carries a bounded context (principle 4): [tools + persona] = the cached prefix,
then the command, the situation digest, the active goal, notes, the top-3 learned skills, spells,
standing orders and the last N events. No transcript; a loop step appends only the tool result.
"""
from __future__ import annotations

import json
import re
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Callable

from . import grounding
from . import situation as sit
from .interface import (PROGRESS_EVENTS, READ_TOOLS, RULE_TOOLS, SENSABLE_TRIGGERS, TOOLS, Event, GameInterface,
                        GatherProgress, Reason, tool_schema, validate_args)
from .jsonl_log import JsonlLogger
from .llm import LLMClient, LLMResponse, ToolCall, assistant_message, tool_result_message
from .spells import SpellBook
from .state_store import StateStore
from .voice import Voice

MAX_SAY = 200  # one chat line (DW_SAY_MODE=direct sends real chat)

PERSONA = """You are {name}, an AI companion playing RuneScape: Dragonwilds with {player}.
You talk like a friendly fellow player: one short casual sentence, no emojis, under 150 characters.
ALWAYS reply to the player with one short line of text, also when you call a tool (unless the line
is not meant for you, see "Reading chat").

Reading chat: you hear EVERY chat line; chat lists the recent ones, oldest first, yours marked you=true.
- command.addressed=true: the player named you. Answer as usual.
- command.addressed=false: nobody named you. First decide whether the line is meant for you: a
  follow-up to a conversation you are in, an instruction while you are clearly the one being
  addressed, or a question to everyone that you can help with ("anyone got an axe?" when you
  carry one). If it is NOT for you (friends talking to each other, banter, anything else), reply
  with an EMPTY message and call no tool. Never butt into other players' conversations.

How to decide:
- Simple, immediate requests (follow me, wait here, come here, attack that, stop, give me X,
  pick that up, drop the logs) -> call the matching action tool directly. "wait here" = stop.
  "come here" = go_to the player.
- Harvesting (chop / cut / fell a tree, chop that fallen log or stump, mine a rock) -> call gather
  with the resource kind ("oak", "ash", "stone"...). gather finds standing trees, felled trees, logs
  and stumps itself, nearest first, so you do NOT need to see them in situation first.
  Ground pickups work the same way: "stone" = loose stones on the ground, "rock" = mine a boulder,
  also "sticks", "flax", "mushroom", berries and crops. It leaves stumps alone (they regrow).
  "chop it" = 1 more of that resource unless a count was given.
- Multi-step jobs (gather X then build/bring Y) -> if a learned skill in learned_skills fits and its
  params are clear, call run_skill; otherwise call start_goal with the goal in plain words.
- Facts worth keeping -> remember. A place: key "place:<name>", value "here" (where you stand),
  "{player}" (where the player stands) or a description.
- Chit-chat, praise, questions about what you see -> no tool, just answer from the situation.
- What you wear, hold or carry -> situation has "You: ... holding X", "Wearing:" and "Carrying:"; call
  inventory (read-only) for the full list with slots, counts and durability, then answer from it.
A request that needs several steps (walk to him, then drop the logs; pick it up, then drink it):
call the tools IN ORDER in ONE message. They run one after another, each checked in the game, and
stop at the first one that fails. Calling an action tool cancels whatever job you are doing, so
never pair an action with stop: "follow me" is just follow. Only call stop when the
player asks you to stop or wait. If the player only comments on your work, do not call a tool.

Seeing things (grounding):
- situation lists what you perceive right now, by in-game name, with ids for actions.
- Only act on things that are in situation or in a look/inspect result. Never substitute a
  different item or target for the one the player named.
- If the player names something you don't see in situation{look_rule}
- If it is not there, say so plainly: "I can't see any sticks around here", and mention what IS there.
- If you can't do something, say what and why in one line: you lack the skill, you can't see it,
  you don't carry it, or it is unsafe. Don't pretend.
- references (when present): the words in command.text that match things you perceive, typos
  corrected (read_as), with ids, nearest first. Use them to pick the right id.
- When an action fails, its result comes back to you: say in one truthful line what happened, and
  either try the obvious fix with one tool or ask {player}.
Use ids and names exactly as they appear. "me"/"I" is the player in command.player: pass that exact
value as the player or target argument.

Your body (body_status, body_event):
- body_status: what your body reports right now: your current or last move and how it ended, and
  what each report was about. Trust it over recent_events. A report "not about a player" is not
  about {player}.
- body_event: your body needs a decision (command.text is empty then). unreachable: a move can't
  reach its target (reason = the body's verdict, about = player or place); resumed: it can reach it
  again; vitals_low: a survival stat is low and you carry nothing for it. If one of your tools fixes
  it (e.g. something in situation you can consume or fetch), use it. Otherwise tell {player} in ONE
  short truthful line what happened and why, in plain words, and what you need from him.
- recent_activity: what your body did lately (fights and how they ended, flights, pickups, deaths,
  grave recoveries...), whoever started it (a reflex or a test command too). It is YOUR memory:
  answer "what did you just do?" or "did you kill that?" from it; notes keep the notable ones.
- Never repeat what you already said (your own lines are in chat, you=true) unless it got worse or
  {player} asks about it.
- If you can't tell what {player} means, ask ONE short question naming the things you can see.

Spells: castable_spells lists what you can cast (name, role, when to use it). "Cast X" / "shield
up" -> cast with that name (self spells need no target). If a spell is not listed, you can't cast
it: say so instead of calling cast.
Standing orders: "every time / whenever / if X, do Y" (usually about a fight) -> set_reflex_rule,
so your body reacts instantly without asking you. enemy = the enemy kind {player} named ("kalphite"),
or "*" if none. You can only sense these triggers: {triggers}.
If X is not one of them (a sound, a colour, something an enemy says, weather...), do NOT call
set_reflex_rule: say you can't sense that. Map his words: "raises its claws", "winds up",
"about to hit", "attacks" -> telegraph; "windstep away" -> actions evade then cast Windstep at self.
reflex_rules lists current orders: "what are your orders" -> list_rules; "stop doing that" /
"forget that" -> clear_rule with the matching id."""

LOOK_RULE = (": situation is only a short summary and misses many things (sticks, stones, plants, chests, "
             "stations). ALWAYS call look with about=<their words> first, before acting or saying you can't see it "
             "(read-only, it does not interrupt your job); then act on an id from its result. inspect gives "
             "details of one thing.")
NO_LOOK_RULE = ", you can't look around yet: say you can't see it."

START_GOAL = {
    "type": "function",
    "function": {
        "name": "start_goal",
        "description": "Hand a multi-step job to the planner, e.g. 'gather 10 logs and bring them to Luis'.",
        "parameters": {"type": "object", "properties": {"goal": {"type": "string"}}, "required": ["goal"]},
    },
}
ACTION_TOOLS = ["follow", "stop", "go_to", "attack", "give", "pickup", "drop", "cast", "sleep", "wake", "interact",
                "gather"]
# Actions that can run for minutes: the reply is said when they start, progress lines while they run,
# and a short result line when they end (a failure still overrides, single voice).
LONG_ACTIONS = {"gather"}
# How to name a skill in "I can't ... yet".
SKILL_PHRASES = {"fetch": "pick that up", "consume": "eat or drink that", "come_to": "come to you",
                 "recover_grave": "get my things from my grave", "follow": "follow you", "stop": "stop", "go_to": "walk somewhere", "attack": "fight",
                 "give": "hand items over", "gather": "gather", "craft": "craft", "place": "build",
                 "pickup": "pick things up", "drop": "drop things", "cast": "cast that spell",
                 "set_reflex_rule": "do that as a reflex", "list_rules": "list my orders",
                 "clear_rule": "forget orders", "sleep": "sleep", "wake": "get up",
                 "interact": "use things like that", "look": "look around", "inspect": "inspect things",
                 "run_skill": "run that skill"}
# A short reply when the action worked but the model said nothing (reply to every command).
ACKS = {"fetch": "Got it.", "consume": "Done.", "come_to": "Here.", "recover_grave": "Got my things back.",
        "follow": "Right behind you.", "stop": "Okay, stopping.", "go_to": "On my way.", "attack": "On it!",
        "give": "Here you go.", "pickup": "Got it.", "drop": "Dropped.", "cast": "Done.", "sleep": "Night night.",
        "wake": "I'm up.", "interact": "Done.", "remember": "Noted.", "set_reflex_rule": "Got it.", "gather": "On it.",
        "list_rules": "", "clear_rule": ""}
# Actions that leave the current job running (a spell or a standing order is not a new job).
NON_INTERRUPTING = {"remember", "cast", *RULE_TOOLS}
# Reasons in words, for "I couldn't X: <why>".
REASON_PHRASES = {
    Reason.PATH_BLOCKED: "I can't find a way there",
    Reason.TOO_FAR: "it's too far away",
    Reason.TIMEOUT: "it took too long",
    Reason.INVENTORY_FULL: "my bags are full",
    Reason.COMPANION_DOWN: "I'm down",
    Reason.MISSING_MATERIALS: "I'm missing materials",
    Reason.UNKNOWN_RECIPE: "I don't know that recipe",
    Reason.NOT_INTERACTABLE: "there's nothing to do with it",
    Reason.BODY_ERROR: "something glitched in my body",
}


def spell_label(spell: str | None) -> str:
    """'USD_TempestShield' -> 'Tempest Shield' (display names come from the spell list when known)."""
    if not spell:
        return "that spell"
    s = re.sub(r"^USD_", "", spell).replace("_", " ")
    return re.sub(r"(?<=[a-z])(?=[A-Z])", " ", s).strip()


def describe_rule(r: dict) -> str:
    t = r.get("trigger") or {}
    trig = t.get("kind", "?") + (f" <{t['value']:g}" if isinstance(t.get("value"), (int, float)) else "")
    if t.get("attack"):
        trig += f" ({t['attack']})"
    acts = []
    for a in r.get("actions") or []:
        if a.get("kind") == "cast":
            acts.append(f"cast {spell_label(a.get('spell'))}" + (f" at {a['target']}" if a.get("target") else ""))
        elif a.get("kind") == "switch_weapon":
            acts.append(f"switch to {a.get('item')}")
        else:
            acts.append(str(a.get("kind")))
    who = "any enemy" if r.get("enemy") in (None, "*") else r["enemy"]
    return f"{r.get('id')}: {who} {trig} -> {', '.join(acts)}"


def clip(text: str, limit: int = MAX_SAY) -> str:
    """One chat line: whitespace collapsed, cut at a word boundary."""
    t = " ".join(str(text).split())
    if len(t) <= limit:
        return t
    cut = t[: limit - 1].rsplit(" ", 1)[0].rstrip(",;:")
    return cut + "…"


@dataclass
class Decision:
    actions: list[ToolCall] = field(default_factory=list)
    speech: str | None = None
    goal: str | None = None
    skill: tuple[str, dict] | None = None  # run_skill(name, params)
    interrupts: bool = False
    # (tool, reason, data) the Controller refused before reaching the body, e.g. cant_sense, not_perceived
    refusals: list[tuple[str, str, dict]] = field(default_factory=list)
    model_calls: int = 0
    messages: list[dict] = field(default_factory=list)  # the turn so far, for a follow-up after a failure
    looks: list[dict] = field(default_factory=list)  # look results this turn (data)
    inventory: dict | None = None  # an inventory read this turn (data)


class Controller:
    def __init__(self, llm: LLMClient, game: GameInterface, store: StateStore, logger: JsonlLogger,
                 name: str = "Claude", player: str = "Luis", recent_events: int = 10,
                 spellbook: SpellBook | None = None, rules_ttl: float = 60.0,
                 available_tools: set[str] | list[str] | None = None, skills=None, max_calls: int = 3,
                 progress_interval: float = 20.0, clock: Callable[[], float] = time.monotonic, caps=None):
        self.llm = llm
        self.game = game
        self.store = store
        self.log = logger
        self.name = name
        self.player = player
        self.events: deque[dict] = deque(maxlen=recent_events)
        self.spellbook = spellbook or SpellBook(game)
        self.rules_ttl = rules_ttl
        self._rules: list[str] = []
        self._rules_at: float | None = None
        # None = every tool (the mock); else the body's capabilities decide look/inspect/interact.
        self.available = set(available_tools) if available_tools is not None else None
        # The body's capability manifest (brain.capabilities.Capabilities): when present, the tool list
        # comes from it ONLY, so the model can never be offered a tool the body lacks.
        self.caps = caps if caps is not None and getattr(caps, "has_manifest", False) else None
        if self.caps is not None and self.available is None:
            self.available = set(self.caps.tools) | set(self.caps.manifest)
        self.read_tools = set(READ_TOOLS) | (self.caps.read_tools() if self.caps else set())
        self.skills = skills  # SkillLibrary | None
        self.max_calls = max(1, max_calls)
        self.progress_interval = progress_interval
        self.clock = clock
        self._progress_at: float | None = None
        self._progress_last: str | None = None
        self.tools = self._tool_list()
        self.chat_provider: Callable[[], list[dict]] | None = None  # recent chat lines (run_live.ChatMemory)
        self.on_say: Callable[[str], None] | None = None  # told about every line the companion says
        self.voice = Voice(clock=clock)  # the single speech gate (near-duplicates)
        self.status_provider: Callable[[], list[str]] | None = None  # body_status lines (broker.digest)
        # recent_activity lines (broker.activity_lines): completed body episodes, whoever started them
        self.activity_provider: Callable[[], list[str]] | None = None

    # ---------------------------------------------------------------- tools offered (fixed per session)

    def has(self, tool: str) -> bool:
        return self.available is None or tool in self.available

    @property
    def can_look(self) -> bool:
        return self.has("look")

    def _tool_list(self) -> list[dict]:
        brain = [tool_schema("remember"), tool_schema("run_skill"), START_GOAL]
        rules = [tool_schema(n) for n in RULE_TOOLS if self.has(n)]
        if self.caps is not None:  # the body's manifest: its own descriptions and schemas
            return [self.caps.function_schema(n) for n in self.caps.llm_tools()] + rules + brain
        # No manifest (mock, server puppet): the brain's own schemas, still only for tools the body has.
        acts = [n for n in ACTION_TOOLS if self.has(n)]
        reads = [n for n in READ_TOOLS if self.has(n)]
        return [tool_schema(n) for n in reads + acts] + rules + brain

    def offered(self) -> set[str]:
        return {t["function"]["name"] for t in self.tools}

    def note_event(self, event: Event) -> None:
        if isinstance(event, PROGRESS_EVENTS):
            return  # progress is narrated, not context
        self.events.append(event.model_dump())

    # ---------------------------------------------------------------- context: spells and standing orders

    def rules_changed(self) -> None:
        self._rules_at = None

    def reflex_rules(self) -> list[str]:
        """One line per standing order, refreshed after any rule tool call (or every rules_ttl s).
        The rules themselves are snapshotted into this world's memory (reflex_rules.json)."""
        if not self.has("list_rules"):
            return []
        now = time.monotonic()
        if self._rules_at is not None and now - self._rules_at < self.rules_ttl:
            return self._rules
        self._rules_at = now
        res = self.game.list_rules()
        rules = res["data"].get("rules") if res.get("ok") else None
        self._rules = [describe_rule(r) for r in rules] if isinstance(rules, list) else []
        if isinstance(rules, list):
            try:
                self.store.save_rules(rules)
            except OSError as exc:
                self.log.log("rules_snapshot_error", error=repr(exc))
        return self._rules

    def castable_spells(self) -> list[dict]:
        if not self.has("spells") and not self.has("cast"):
            return []
        try:
            return self.spellbook.castable()
        except Exception as exc:  # context is best effort; never block a decision on it
            self.log.log("spellbook_error", error=repr(exc))
            return []

    def learned_skills(self, text: str) -> list[dict]:
        if not self.skills:
            return []
        try:
            return [r.brief() for r in self.skills.retrieve(text, k=3)]
        except Exception as exc:
            self.log.log("skill_retrieval_error", error=repr(exc))
            return []

    def _notes(self) -> dict:
        notes = self.store.notes()
        if len(notes) > 20:  # bounded: the newest 20 (insertion order)
            notes = dict(list(notes.items())[-20:])
        return notes

    def context(self, player: str, text: str, state: dict, active_goal: str | None, addressed: bool = True,
                body_event: dict | None = None) -> dict:
        tree = self.store.tree
        tasks = [t.model_dump(include={"skill", "args", "status"}) for t in tree.tasks] if tree and active_goal else []
        ctx = {
            "command": {"player": player, "text": text, "addressed": addressed},
            "situation": sit.summary(state, active_goal=active_goal, tasks=tasks, places=self.store.places(),
                                     looks_supported=self.can_look),
            "active_goal": active_goal,
            "goal_tasks": tasks,
            "notes": self._notes(),
            "learned_skills": self.learned_skills(text),
            "castable_spells": self.castable_spells(),
            "reflex_rules": self.reflex_rules(),
            "recent_events": list(self.events),
        }
        if self.status_provider:
            try:
                ctx["body_status"] = self.status_provider()
            except Exception as exc:  # context is best effort
                self.log.log("body_status_error", error=repr(exc))
        if self.activity_provider:
            try:
                ctx["recent_activity"] = self.activity_provider()
            except Exception as exc:  # context is best effort
                self.log.log("recent_activity_error", error=repr(exc))
        if body_event:
            ctx["body_event"] = body_event
        if text and state and not state.get("unavailable"):
            refs = grounding.hints(grounding.read(text, sit.perceived(state), exclude=[player, self.name]))
            if refs:
                ctx["references"] = refs  # information only: the model decides (PRINCIPLES.md #2)
        if self.chat_provider:
            try:
                ctx["chat"] = self.chat_provider()
            except Exception as exc:  # context is best effort
                self.log.log("chat_context_error", error=repr(exc))
        return ctx

    def persona(self) -> str:
        return PERSONA.format(name=self.name, player=self.player, triggers=", ".join(SENSABLE_TRIGGERS),
                              look_rule=LOOK_RULE if self.can_look else NO_LOOK_RULE)

    # ---------------------------------------------------------------- the bounded loop

    def decide(self, player: str, text: str, state: dict, active_goal: str | None, addressed: bool = True,
               body_event: dict | None = None) -> Decision:
        context = self.context(player, text, state, active_goal, addressed, body_event)
        messages = [{"role": "system", "content": self.persona()},
                    {"role": "user", "content": json.dumps(context, default=str, ensure_ascii=False)}]
        offered = self.offered()
        d = Decision()
        resp = LLMResponse()
        for step in range(self.max_calls):
            self.log.log("prompt", component="controller", model=self.llm.model, step=step,
                         messages=messages if step == 0 else messages[-2:])
            resp = self.llm.complete(messages, tools=self.tools)
            d.model_calls += 1
            self.log.log("llm_response", component="controller", step=step, content=resp.content,
                         tool_calls=[vars(c) for c in resp.tool_calls], usage=resp.usage)
            reads = [c for c in resp.tool_calls if c.name in self.read_tools and c.name in offered]
            commits = [c for c in resp.tool_calls if c.name not in self.read_tools]
            if commits or not reads:
                break  # the first real action ends the turn (reads alongside an action are dropped)
            if step == self.max_calls - 1:
                self.log.log("controller_budget_exhausted", calls=d.model_calls)
                break
            messages = messages + [assistant_message(resp)]
            for call in reads:
                messages.append(tool_result_message(call, self._read(call, d)))
            if step == self.max_calls - 2:
                messages.append({"role": "user", "content": "Last step: act now on what you found, or reply."})
        d.speech = (resp.content or "").strip() or None
        d.messages = messages + [assistant_message(resp)]
        self._collect(resp.tool_calls, d, state)
        # A real action or a new goal pre-empts the current job; remember(), spells, standing
        # orders and chat do not.
        d.interrupts = bool(d.goal or d.skill or any(a.name not in NON_INTERRUPTING for a in d.actions))
        if not d.actions and not d.goal and not d.skill and not d.refusals:
            self._unseen_fallback(d)
        return d

    def _read(self, call: ToolCall, d: Decision) -> dict:
        """Run one read-only tool (no interrupt, no task) and return a compact result for the model."""
        try:
            args = self._validate(call.name, call.arguments)
        except Exception as exc:
            return {"ok": False, "reason": Reason.INVALID_ARGS, "error": str(exc)[:300]}
        self.log.log("tool_call", tool=call.name, args=args, read_only=True)
        res = self.game.call(call.name, args)
        self.log.log("tool_result", tool=call.name, result=res, read_only=True)
        if call.name == "inventory" and res.get("ok"):
            d.inventory = res["data"]
        if call.name == "look" and res.get("ok"):
            look = {**res["data"], "_about": args.get("about")}
            d.looks.append(look)
            if args.get("about"):  # say it plainly to the model too (the body only ranks by match score)
                res = {**res, "data": {**res["data"], "matched": bool(sit.look_matched(look))}}
        if not res.get("ok") and res.get("reason") in Reason.CANT_YET:
            return {"ok": False, "reason": res["reason"], "note": f"you can't {call.name} yet"}
        return res

    def _collect(self, calls: list[ToolCall], d: Decision, state: dict) -> None:
        offered = self.offered()
        for call in calls:
            if call.name in self.read_tools:
                continue
            if call.name not in offered and self.caps is not None:  # a legacy name (pickup -> fetch)
                new, args = self.caps.resolve(call.name, call.arguments or {})
                if new != call.name and new in offered:
                    self.log.log("controller_alias", said=call.name, tool=new, args=args)
                    call.name, call.arguments = new, args
            if call.name == "start_goal" and call.arguments.get("goal"):
                d.goal = str(call.arguments["goal"])
                continue
            if call.name == "run_skill":
                self._collect_skill(call, d)
                continue
            if call.name not in offered or call.name == "start_goal":
                self.log.log("controller_unknown_tool", tool=call.name)
                if call.name in TOOLS and call.name != "start_goal":
                    # a tool this body lacks (never offered, the model reached for it anyway): say so
                    # truthfully instead of speaking a reply that claims the action
                    d.refusals.append((call.name, Reason.NOT_IMPLEMENTED, {}))
                continue
            if call.name == "set_reflex_rule":
                trig = call.arguments.get("trigger")
                kind = trig.get("kind") if isinstance(trig, dict) else trig
                if kind not in SENSABLE_TRIGGERS:  # only what the body can sense
                    self.log.log("controller_cant_sense", trigger=kind)
                    d.refusals.append((call.name, Reason.CANT_SENSE, {"trigger": kind}))
                    continue
            try:
                call.arguments = self._validate(call.name, call.arguments)
            except Exception as exc:
                self.log.log("controller_invalid_call", tool=call.name, error=str(exc))
                continue
            refusal = self.safety(call, state)
            if refusal:
                self.log.log("controller_safety_refusal", tool=call.name, args=call.arguments, refusal=refusal)
                d.refusals.append(refusal)
                continue
            d.actions.append(call)

    def _validate(self, name: str, args: dict) -> dict:
        """The body's published schema when it has one for this tool, else the brain's own model."""
        if self.caps is not None and name in self.caps.manifest:
            return self.caps.validate(name, args)
        return validate_args(name, args)

    def _collect_skill(self, call: ToolCall, d: Decision) -> None:
        name = str(call.arguments.get("name") or "")
        params = call.arguments.get("params") if isinstance(call.arguments.get("params"), dict) else {}
        if not self.skills or not self.skills.get(name):
            d.refusals.append(("run_skill", Reason.UNKNOWN_SKILL, {"skill": name}))
            return
        d.skill = (self.skills.get(name).name, params)

    # ---------------------------------------------------------------- grounding (in code)

    def safety(self, call: ToolCall, state: dict) -> tuple[str, str, dict] | None:
        """Luis's explicit safety rules: the ONLY code gate on the model's calls (PRINCIPLES.md #2).
        Never attack a player. Everything else (what the player meant, which item, whether it is
        there) is the model's decision; the body reports the outcome truthfully."""
        if call.name == "attack" and state and not state.get("unavailable"):
            target = str(call.arguments.get("target") or "")
            names = {str(p.get("name")) for p in state.get("players") or [] if isinstance(p, dict) and p.get("name")}
            if target in names or target == self.player:
                return call.name, Reason.UNSAFE, {"target": target, "safety_rule": "never attack a player"}
        return None

    def follow_up(self, d: Decision, call: ToolCall, result: dict, state: dict | None = None,
                  results: dict[str, dict] | None = None) -> Decision:
        """An action failed: hand the body's truthful result back to the model for ONE more step,
        so IT decides what to say, which fix to try, or what to ask (no code-side rewording).
        ``results``: call id -> result of the steps that ran before it (multi-step turns)."""
        msgs = list(d.messages)
        calls = (msgs[-1].get("tool_calls") or []) if msgs else []
        for tc in calls:  # every tool call of the turn needs a result
            name = (tc.get("function") or {}).get("name")
            res = result if tc.get("id") == call.id or (not call.id and name == call.name) else \
                (results or {}).get(tc.get("id")) or {"ok": None, "note": "not run: an earlier step failed"}
            msgs.append(tool_result_message(ToolCall(name or "?", {}, tc.get("id")), res))
        msgs.append({"role": "user", "content": "That action did not work (result above). Reply to the player in "
                     "one short truthful line; you may call ONE tool to fix it, or ask him."})
        self.log.log("prompt", component="controller", model=self.llm.model, step="follow_up", messages=msgs[-2:])
        resp = self.llm.complete(msgs, tools=self.tools)
        self.log.log("llm_response", component="controller", step="follow_up", content=resp.content,
                     tool_calls=[vars(c) for c in resp.tool_calls], usage=resp.usage)
        d2 = Decision(model_calls=1, speech=(resp.content or "").strip() or None)
        d2.messages = msgs + [assistant_message(resp)]
        self._collect([c for c in resp.tool_calls if c.name not in self.read_tools and c.name != "start_goal"],
                      d2, state or {})
        return d2

    @staticmethod
    def _carries(state: dict, item: str) -> bool:
        inv = {k: v for k, v in (state.get("inventory") or {}).items() if v}
        if item in inv:
            return True
        names = sit.item_names(state)
        want = sit.tokens(item)
        return bool(want) and any(want & (sit.tokens(k) | sit.tokens(names.get(k)) | sit.tokens(sit.name_of_item(k, names)))
                                  for k in inv)

    def _unseen_fallback(self, d: Decision) -> None:
        """No action: if the turn looked for something and found nothing, make sure the reply says so."""
        missed = [lk for lk in d.looks if sit.look_matched(lk) is False and lk.get("_about")]
        if missed and not d.speech:
            lk = missed[-1]
            seen = ", ".join(dict.fromkeys(str(t.get("name")) for t in lk.get("things") or [] if t.get("name")))
            d.refusals.append(("look", Reason.NOT_PERCEIVED, {"what": lk["_about"], "seen": seen}))

    # ---------------------------------------------------------------- speech (single voice)

    def say(self, text: str, kind: str = "reply") -> dict | None:
        """The only way anything is said (single voice). ``kind``: reply (to a command), notice (a body
        situation), system (pong: never gated). Near-duplicates of a recent line are not said again."""
        text = clip(text)
        if not text:
            return None
        why = self.voice.gate(text, kind)
        if why:
            self.log.log("say_suppressed", text=text, voice=kind, why=why)
            return None
        self.voice.record(text, kind)
        self.log.log("say", text=text, voice=kind)
        if self.on_say:
            try:
                self.on_say(text)
            except Exception as exc:
                self.log.log("on_say_error", error=repr(exc))
        res = self.game.say(text)
        if isinstance(res, dict):
            self.log.log("say_result", ok=res.get("ok"), reason=res.get("reason"), data=res.get("data"))
        return res

    def ack(self, tool: str) -> str | None:
        return ACKS.get(tool, "On it.") or None

    def report_failure(self, tool: str, reason: str | None, data: dict | None = None) -> None:
        """Say why an immediate action failed, in words that match what happened."""
        data = data or {}
        spell = spell_label(data.get("spell") or (data.get("rule") or {}).get("spell"))
        reason_base = (reason or "").split(":", 1)[0]
        detail = data.get("detail")
        speaks = tool == "gather" or (self.caps is not None and self.caps.speaks_detail(tool))
        if speaks and isinstance(detail, str) and detail.strip() and reason not in Reason.CANT_YET:
            # the client skills write a truthful chat sentence for each failure (manifest detail_is_speech)
            self.say(detail.strip())
        elif reason == Reason.CANT_SENSE:
            self.say("I can't sense that, so I can't react to it. I can watch for attacks starting, "
                     "health levels, enemies bunching up, stuns and spell cooldowns.")
        elif reason == Reason.NOT_PERCEIVED or (reason == Reason.UNKNOWN_TARGET and tool in ("pickup", "attack", "interact")):
            what = data.get("what") or data.get("target") or data.get("item") or "that"
            seen = data.get("seen")
            self.say(f"I can't see any {what} around here" + (f", only {seen}." if seen else "."))
        elif reason == Reason.NOT_IN_INVENTORY:
            self.say(f"I don't have any {data.get('item') or 'of that'} on me.")
        elif reason == Reason.UNKNOWN_SKILL and tool == "run_skill":
            self.say(f"I haven't learned a skill called {data.get('skill') or 'that'}.")
        elif reason == Reason.ON_COOLDOWN:
            left = data.get("remaining_s")
            self.say(f"{spell} is still on cooldown" + (f" ({float(left):.0f}s left)." if left else "."))
        elif reason == Reason.NOT_UNLOCKED:
            self.say(f"You haven't unlocked {spell}, so I can't use it either.")
        elif reason == Reason.UNSAFE:
            self.say(f"Not casting {spell} there, it would hit you." if tool == "cast"
                     else "That's not safe, so I won't.")
        elif reason == Reason.NOT_ENOUGH and tool == "cast":
            self.say(f"I don't have the runes for {spell}.")
        elif reason == Reason.WRONG_TOOL:
            need = data.get("need_category") or "the right tool"
            self.say(f"I can't, I need a {need}" + (f" (tier {data['need_tier']}+)" if data.get("need_tier") else "")
                     + " and I'm not holding one.")
        elif reason == Reason.NOTHING_IN_RANGE:
            what = data.get("resource") or data.get("item")
            self.say(f"There's no {what} anywhere near me." if what else "There's nothing like that near me.")
        elif reason in Reason.CANT_YET:
            self.say(f"Sorry, I can't {SKILL_PHRASES.get(tool, tool.replace('_', ' '))} yet.")
        elif reason == Reason.STATE_UNAVAILABLE:
            self.say(f"I can't {SKILL_PHRASES.get(tool, tool.replace('_', ' '))} yet: I can't read the game state.")
        elif reason_base in REASON_PHRASES:
            self.say(f"I couldn't {tool.replace('_', ' ')}: {REASON_PHRASES[reason_base]}.")
        else:
            self.say(f"I couldn't {tool.replace('_', ' ')}: {reason}.")

    @staticmethod
    def warning_note(warnings: list[dict]) -> str | None:
        """One sentence about a standing order the body stored but can't fully carry out yet."""
        if not warnings:
            return None
        w = warnings[0]
        spell, reason = spell_label(w.get("spell")), w.get("reason")
        if w.get("action") == "switch_weapon":
            return "Heads up: I can't switch weapons yet, so that part won't happen."
        if reason == Reason.NOT_UNLOCKED:
            return f"Heads up: you haven't unlocked {spell}, so that part won't happen."
        if reason == Reason.NOT_ENOUGH:
            return f"Heads up: I've no runes for {spell} right now."
        if reason in Reason.CANT_YET or reason == Reason.STATE_UNAVAILABLE:
            return f"Heads up: I can't cast {spell} yet, so for now I'll do the rest."
        return f"Heads up: {spell} isn't ready ({reason})."

    def ask_for_help(self, goal: str, failed: str | None, reason: str | None, question: str | None = None) -> None:
        base = (reason or "").split(":", 1)[0]
        why = REASON_PHRASES.get(base) or (reason or "").replace("_", " ")
        what = f" {failed} keeps failing ({why})." if failed else (f" ({why})" if why else "")
        self.say(f"I'm stuck on '{clip(goal, 60)}'.{what} {question or 'Can you help me out?'}".strip())

    def goal_done(self, goal: str) -> None:
        self.say(f"Done: {goal}.")

    # ---------------------------------------------------------------- progress on long jobs

    def job_started(self) -> None:
        """The start of a long job counts as the last update: the first progress line comes later."""
        self._progress_at, self._progress_last = self.clock(), None

    def progress(self, text: str) -> bool:
        """Say a short progress line at most every ``progress_interval`` seconds, never the same twice."""
        now = self.clock()
        if not text or text == self._progress_last:
            return False
        if self._progress_at is not None and now - self._progress_at < self.progress_interval:
            self.log.log("progress_skipped", text=text)
            return False
        self._progress_at, self._progress_last = now, text
        self.say(text)
        return True

    def progress_event(self, event: Event) -> bool:
        """Body progress (gather_progress / task_progress) -> a progress line, throttled."""
        have, want = getattr(event, "have", None), getattr(event, "want", None)
        if isinstance(have, int) and isinstance(want, int) and (have <= 0 or have >= want):
            return False  # nothing yet, or done (the result itself will be reported)
        if isinstance(event, GatherProgress):
            what = sit.name_of_item(event.item, {}) if event.item else (event.resource or "of them")
            return self.progress(f"Gathering: {have}/{want} {what} so far.")
        label = getattr(event, "text", None)
        if label and isinstance(have, int) and isinstance(want, int):
            return self.progress(f"{label}: {have}/{want}.")
        return self.progress(label) if label else False

    def milestone(self, done: int, total: int, task_label: str) -> bool:
        if done >= total:
            return False
        return self.progress(f"Step {done}/{total} done ({task_label}), carrying on.")

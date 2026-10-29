"""Controller: interprets chat, decides interrupts, and owns ALL speech.

Only ``Controller.say`` ever calls ``game.say`` (design principle 6). Speech is produced after the
action decision and is overridden if an action fails, so the companion never says one thing while
doing another.

Bounded ReAct loop (research 2026-10-25 sections 3.2 and 6): at most ``max_calls`` (3) model calls
per command. Read-only tools (``look``, ``inspect``) run inline, don't interrupt the current job and
don't end the turn; the first real action (or start_goal / run_skill / remember / a rule tool) ends
it; speech is the text of that final response. With the situation digest preloaded, most commands
take one call; "pick up the sticks" takes two when the sticks aren't in the digest. If the last
call still only reads, those reads are answered "not run" and ONE final call is made with only the
acting tools offered (``_final_pass``), so a turn never ends having only looked.

Grounding (section 6.2), enforced in code, not only in the prompt: an action on a thing that was
not perceived (state, digest or a look this turn) is refused with ``not_perceived`` and the reply
says "I can't see any X", naming what is there instead. Never a substitute target.

Each model call carries a bounded context (principle 4): [tools + persona] = the cached prefix,
then the command, the situation digest, the active goal, notes, the top-3 learned skills, spells,
standing orders and the last N events. No transcript; a loop step appends only the tool result.
"""
from __future__ import annotations

import json
import math
import os
import re
import time
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from . import grounding
from .geom import WIRE_COORDINATES
from . import persona as persona_file
from . import item_stats
from . import situation as sit
from .interface import (BRAIN_TOOLS, PROGRESS_EVENTS, READ_TOOLS, RULE_TOOLS, SENSABLE_TRIGGERS, TOOLS, Event, GameInterface,
                        GatherProgress, Reason, tool_schema, validate_args)
from .jsonl_log import JsonlLogger
from .llm import LLMClient, LLMResponse, ToolCall, assistant_message, request_log_fields, strip_markers, tool_result_message
from .spells import SpellBook
from .state_store import StateStore
from .voice import Voice

def _model_read_view(result):
    """Copy a read result and compact only repeated, simple read-status gaps."""
    from copy import deepcopy

    view = deepcopy(result)

    def compact(gaps):
        if not isinstance(gaps, list):
            return gaps
        groups = {}
        for gap in gaps:
            if (isinstance(gap, dict) and set(gap) == {"raw", "reason"} and
                    isinstance(gap["reason"], str) and gap["reason"] and
                    (gap["raw"] is None or type(gap["raw"]) is int)):
                groups.setdefault(gap["reason"], []).append(gap["raw"])
        out, emitted = [], set()
        for gap in gaps:
            if (isinstance(gap, dict) and set(gap) == {"raw", "reason"} and
                    isinstance(gap["reason"], str) and gap["reason"] and
                    (gap["raw"] is None or type(gap["raw"]) is int) and
                    len(groups[gap["reason"]]) > 3):
                reason = gap["reason"]
                if reason not in emitted:
                    indices = groups[reason]
                    out.append({"reason": reason, "count": len(indices), "sample_raw": indices[:3],
                                "omitted": len(indices) - 3, "truncated": True})
                    emitted.add(reason)
            else:
                out.append(gap)
        return out

    def scope(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "gaps":
                    node[key] = compact(value)
                else:
                    scope(value)
        elif isinstance(node, list):
            for item in node:
                scope(item)

    def find_status(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key in ("read_status", "inventory_read_status") and isinstance(value, dict):
                    scope(value)
                else:
                    find_status(value)
        elif isinstance(node, list):
            for item in node:
                find_status(item)

    find_status(view)
    return view


MAX_SAY = 200  # one chat line (DW_SAY_MODE=direct sends real chat)

PERSONA = """You are {name}, an AI companion playing RuneScape: Dragonwilds with {player}.
You talk like a friendly fellow player: one short casual sentence, no emojis, under 150 characters.
ALWAYS reply to the player with one short line of text, also when you call a tool (unless the line
is not meant for you, see "Reading chat").
Answer only what was asked, from the CURRENT state: where you are, whether you are moving and how far
{player} is come from body_status "Where:", never from what you said earlier. Don't list what you
carry unless asked.

Reading chat: you hear EVERY chat line; chat lists the recent ones, oldest first, yours marked you=true.
- command.addressed=true: the player named you. Answer as usual.
- command.addressed=false: nobody named you. First decide whether the line is meant for you: a
  follow-up to a conversation you are in, an instruction while you are clearly the one being
  addressed, or a question to everyone that you can help with ("anyone got an axe?" when you
  carry one). If it is NOT for you (friends talking to each other, banter, anything else), reply
  with no text at all and call no tool. Never butt into other players' conversations.

How to decide:
- Every tool's description says what it does. Pick the tool (or the tools, in order) that does what
  the player wants, with the arguments its description asks for.
- A request that needs several steps (walk to him, then drop the logs; pick it up, then drink it):
  call the tools IN ORDER in ONE message. They run one after another, each checked in the game, and
  stop at the first one that fails.
- Calling an action tool cancels whatever job you are doing, so never pair an action with stop.
  stop makes you stand still and stay. If the player only comments on your work, call no tool.
- A longer job no single tool does: run_skill when a learned skill fits and its params are clear,
  otherwise start_goal with the goal in plain words. list_skills / forget_skill manage what you
  learned.
- Facts worth keeping: remember. For a place use key "place:<name>" and at=self (where you stand)
  or at=player (where that player stands) so its position is stored.
- Talk, praise, questions about what you see, wear, hold or carry: answer from situation and the
  read-only tools; no action tool.{lookup_rule}

Seeing things (grounding):
- situation lists what you perceive right now, by in-game name, with ids for actions.
- Act on things that are in situation or in a look/inspect result, and never substitute a
  different item or target for the one the player meant.
- If the player names something you don't see in situation{look_rule}
- If it is not there, say so plainly and mention what IS there.
- If you can't do something, say what and why in one line: you lack the skill, you can't see it,
  you don't carry it, or it is unsafe. Don't pretend.
- Never invent reasons. If you don't know why something happened, say so.
- references (when present): the words in command.text that match things you perceive, typos
  corrected (read_as), with ids, nearest first. Use them to pick the right id.
- Carry your plans through: after your tools run, their results come back to you for another
  turn. Continue with the next step, or reply with a short report (no text if you already
  said it). When a step fails, fix it with the right tool or another way.
- When you have the tools and the information to solve a problem, act on your own plan and report
  briefly. Ask {player} only when it is genuinely ambiguous, risky or beyond your tools, and then
  ask once, specifically.
Use ids and names exactly as they appear. "me"/"I" is the player in command.player: pass that exact
value as the player or target argument.

Your body (body_status, body_event):
- body_status: what your body reports right now: your current or last move and how it ended, and
  what each report was about. Trust it over recent_events. A report "not about a player" is not
  about {player}.
- body_event: your body needs a decision (command.text is empty then). unreachable: a move can't
  reach its target (reason and detail = the body's measurement, about = player or place; a reason
  like leader_windstepped is the body's guess from how high he rose, so say it as a guess);
  resumed: it can reach it again; follow_ended: a follow stopped by itself; vitals_low: a survival
  stat is low and you carry nothing for it; items_dropped: a player dropped those items near you
  (decide yourself whether to pick them up, and whether to thank him); situation_review: something
  about your state changed (changes, stats_pct, time_of_day, previous_review). You may proactively
  suggest or do something when the situation calls for it, briefly, and respect the player's answers
  (chat, previous_review.you_said). Reply with no text at all to stay silent. If one of your tools fixes it, use it. Otherwise tell
  {player} in ONE short truthful line what happened and why, in plain words, and what you need.
- recent_activity: what your body did lately (fights and how they ended, flights, pickups, deaths,
  grave recoveries...), whoever started it (a reflex or a test command too). It is YOUR memory;
  notes keep the notable ones.
- Never repeat what you already said (your own lines are in chat, you=true) unless it got worse or
  {player} asks about it.
- If you can't tell what {player} means, ask ONE short question naming the things you can see.

Spells: castable_spells lists what you can cast (name, role, when to use it). A spell that is not
listed can't be cast: say so instead of calling cast.
Standing orders (set_reflex_rule): something your body should do by itself, instantly, whenever a
trigger it can sense happens (enemy = the enemy kind, or "*"). You can only sense these triggers:
{triggers}. If the player's condition is not one of them, do NOT call set_reflex_rule: say you
can't sense that. reflex_rules lists the current orders; list_rules and clear_rule manage them."""

# Talk-only follow-up turns (GOAL M1 talk_without_action): a later turn of the agent loop that only talks
# gets ONE more model call before its line is said, to call what the line says it will do. Decided on the
# reply's shape (text, no tool call), never on its words, like a stop hook that sends the model back once.
TALK_ONLY_NOTE = ("You replied without calling any tool, and nothing has been said yet. If your line says you "
                  "will do something, or that you are doing it, call the tool(s) for it now, in order (keep or "
                  "reword the line). If you can't do it now (no tool or target for it, or something is missing), "
                  "reply with the corrected line saying what's stopping you, and no tool call. Otherwise reply "
                  "with no text at all and your line is said as it is.")

# Addressed chat (a line from the player he is with) runs at this effort; everything else at the client's
# own (DW_CONTROLLER_EFFORT, low). Anthropic's effort docs for Haiku 5.5: low for chat and short tool tasks,
# but in long agent prompts low is "more likely to skip a search, stop early, or skip a check"; medium is
# the model's default. Empty = off. Each level has its own prompt-cache entry (top-level effort is part
# of the rendered prompt), so warm_up warms both. Set DW_CONTROLLER_EFFORT_ADDRESSED=medium to turn it on.
ADDRESSED_EFFORT_ENV = "DW_CONTROLLER_EFFORT_ADDRESSED"
ADDRESSED_EFFORT_DEFAULT = ""  # off until it passes the latency budget (A/B 2026-10-26: chat p50 2.45 -> 3.02 s)

# Appended to every read-only tool's description (Controller._tool_list): how _loop really runs them.
READ_ALONE = ("Runs only when called on its own: in a reply that also calls an action it is skipped, so look "
              "first, then act on its result in your next reply.")

# The read budget's last call (Controller._final_pass): only acting tools are offered.
FINAL_PASS_NOTE = ("No more looking this turn (the read-only tools are used up). Act now with your tools on what "
                   "you found, or reply in a few words (what you found, or what's stopping you).")

LOOK_RULE = (": situation is only a short summary and misses many things (sticks, stones, plants, chests, "
             "stations). ALWAYS call look with about=<their words> first, before acting or saying you can't see it "
             "(read-only, it does not interrupt your job); then act on an id from its result. inspect gives "
             "details of one thing.")
NO_LOOK_RULE = ", you can't look around yet: say you can't see it."
# One line, only when the knowledge index exists (the lookup tool is offered then).
LOOKUP_RULE = ("\n- Game facts you are not sure of (what an item does, how to make it, which regions of the world "
               "something is found in, creatures, spells, mechanics) -> call lookup (read-only) and answer from "
               "it; game data beats the wiki.")

START_GOAL = {
    "type": "function",
    "function": {
        "name": "start_goal",
        "description": "Hand a multi-step job to the planner, e.g. 'gather 10 logs and bring them to the player'.",
        "parameters": {"type": "object", "properties": {"goal": {"type": "string"}}, "required": ["goal"]},
    },
}
LIST_SKILLS = {
    "type": "function",
    "function": {"name": "list_skills", "description": "Read-only: the skills you have learned, with how often each worked.",
                 "parameters": {"type": "object", "properties": {}}},
}
FORGET_SKILL = {
    "type": "function",
    "function": {"name": "forget_skill", "description": "Delete one learned skill by its exact name (from list_skills).",
                 "parameters": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}},
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
# Actions that leave the current job running (a spell or a standing order is not a new job).
NON_INTERRUPTING = {"remember", "cast", *RULE_TOOLS}

# Speech is an explicit channel (single voice, design principle 6): only the text of a ``say`` call is ever
# heard; the model's free text is a private note (logged as controller_note, never spoken). A/B 2026-10-26:
# with thinking off, Haiku 5.5 wrote its reasoning into the free text ("HP is at 2%, water at 0..."), which
# the text channel would have said in chat. The say call is not an action: it is collected as the turn's
# line and then goes through the same single-voice rules (a failure line replaces it, a held line is said
# when the move is accepted). DW_SPEECH_CHANNEL=text restores the old channel (free text is speech).
SPEECH_CHANNEL_ENV = "DW_SPEECH_CHANNEL"
SAY_TOOL = "say"
SAY_SCHEMA = {
    "type": "function",
    "function": {
        "name": SAY_TOOL,
        "description": ("Say one line in game chat. The ONLY way anyone hears you: text you write outside say is a "
                        "private note nobody hears. Call it at most once per reply, beside your other tool calls; "
                        "the line is said when they start (if one fails first, you get to say what went wrong "
                        "instead). No say call = you stay silent."),
        "parameters": {"type": "object", "properties": {"text": {"type": "string", "description":
                       "Exactly what the players read in chat: short, casual, in your own words."}},
                       "required": ["text"]},
    },
}
# Text-channel sessions only (DW_SPEECH_CHANNEL=text): persona.md describes the say tool, so say how it is here.
TEXT_CHANNEL_NOTE = ("Speech here: there is no say tool in this session; the text of your reply is what you say in "
                     "chat, so write only the line itself (no text = silence).")
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


# Engine ids in a body's failure sentence (live 22:20:56 said "Water Volume is already in sight (3.22 m,
# id BP_WaterVolume_C_UAID_..._2108496385)": a raw_code_spoken anomaly). Same shapes tools/obs.py flags.
ENGINE_ID = re.compile(r"\b(?:BP|ITEM|USD|DIM|WBP|ABP|DA|BM)_\w+|\bfol:\S+")


def player_words(text: str, name: str | None = None) -> str:
    """A body failure sentence as a player would say it: a bracketed aside that carries an engine id
    (with its metres) is dropped, and any other id is replaced by the thing's in-game name."""
    out = re.sub(r"\s*\([^()]*(?:\bid\b|" + ENGINE_ID.pattern + r")[^()]*\)", "", text)
    out = ENGINE_ID.sub(name or "it", out)
    return re.sub(r"\s{2,}", " ", out).strip()


# spell_lines: the body's `how` per castable spell, cut to this (bounded prompt growth: one short tail per line)
SPELL_HOW_CHARS = 150


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
    invalid: list[ToolCall] = field(default_factory=list)  # calls refused before the body (the model hears why)
    looks: list[dict] = field(default_factory=list)  # look results this turn (data)
    inventory: dict | None = None  # an inventory read this turn (data)
    effort: str | None = None  # the effort this request runs at, when not the client's default (addressed chat)


class ContinuationBudgetDenied(RuntimeError):
    """A deferred turn cannot safely make another provider request."""


class ContinuationInvalidated(RuntimeError):
    """The deferred turn no longer owns its action or has lost its body state."""

    def __init__(self, reason: str, silent: bool = False):
        super().__init__(reason)
        self.silent = silent



def continuation_observation(state: dict | None) -> dict:
    """Bounded facts from this state read; unknown never means an empty census."""
    def number(value):
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            return None
        try:
            return value if math.isfinite(value) else None
        except OverflowError:
            return None

    if not isinstance(state, dict) or not state or state.get("unavailable"):
        return {"status": "unavailable", "position": None, "vitals": None,
                "inventory_read": "unknown", "inventory": "unknown", "stations": {"status": "unknown"}}

    raw_pos = state.get("position")
    if isinstance(raw_pos, (list, tuple)) and len(raw_pos) == 3:
        pos = [number(v) for v in raw_pos]
        if any(v is None for v in pos):
            pos = None
    else:
        pos = None
    vitals = {key: number(state.get(key)) for key in
              ("health", "max_health", "hydration", "hydration_max", "sustenance", "sustenance_max", "endurance", "endurance_max")}
    raw_stations = state.get("stations_nearby")
    stations = {"status": "unknown"}
    if isinstance(raw_stations, list):
        rows = []
        for row in raw_stations[:6]:
            if not isinstance(row, dict):
                rows.append({"status": "unknown"})
                continue
            name, ident = row.get("name") or row.get("station"), row.get("id")
            rows.append({"name": name[:80] if isinstance(name, str) else None,
                         "name_truncated": isinstance(name, str) and len(name) > 80,
                         "id": ident if isinstance(ident, str) and len(ident) <= 80 else None,
                         "id_truncated": isinstance(ident, str) and len(ident) > 80,
                         "distance_m": number(row.get("distance"))})
        stations = {"status": "observed", "rows": rows, "omitted": max(0, len(raw_stations) - len(rows))}
    def bounded(text):
        return text if len(text) <= 240 else text[:224] + "... [truncated]"

    return {"status": "observed", "position": pos, "vitals": vitals,
            "inventory_read": bounded(sit.inventory_read_line(state)),
            "inventory": bounded(sit.carrying(state, sit.item_names(state))), "stations": stations}

class Controller:
    def __init__(self, llm: LLMClient, game: GameInterface, store: StateStore, logger: JsonlLogger,
                 name: str = "Claude", player: str = "Luis", recent_events: int = 10,
                 spellbook: SpellBook | None = None, rules_ttl: float = 60.0,
                 available_tools: set[str] | list[str] | None = None, skills=None, max_calls: int = 3,
                 progress_interval: float = 20.0, clock: Callable[[], float] = time.monotonic, caps=None,
                 knowledge=None):
        self.llm = llm
        self.continuation_admission = None  # set only while an autonomous deferred turn is running
        self.continuation_validate = None
        self.knowledge = knowledge  # brain.knowledge.Knowledge | None: the lookup tool is offered only with one
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
        self.read_tools = set(READ_TOOLS) | (self.caps.read_tools() if self.caps else set()) | {"list_skills"}
        self.skills = skills  # SkillLibrary | None
        self.max_calls = max(1, max_calls)
        self.addressed_effort = os.environ.get(ADDRESSED_EFFORT_ENV, ADDRESSED_EFFORT_DEFAULT).strip() or None
        # speech channel: "say" (only say calls are heard; default) or "text" (free text is speech, legacy)
        self.say_channel = (os.environ.get(SPEECH_CHANNEL_ENV) or "say").strip().lower() != "text"
        self.check_talk_only = True  # TALK_ONLY_NOTE: one extra call for a talk-only follow-up turn
        self.progress_interval = progress_interval
        self.clock = clock
        self.director = None  # brain.director.Director | None: the task board's tools (attach_director)
        self._progress_at: float | None = None
        self._progress_last: str | None = None
        self.tools = self._tool_list()
        self.chat_provider: Callable[[], list[dict]] | None = None  # recent chat lines (run_live.ChatMemory)
        self.on_say: Callable[[str], None] | None = None  # told about every line the companion says
        self.voice = Voice(clock=clock)  # the single speech gate (near-duplicates)
        self.on_progress: Callable[[str], None] | None = None  # progress notes -> body_status (broker)
        self._rules_file: tuple[str, float] | None = None
        self._rules_text = ""
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
        """The offered tools; every read-only one says, truthfully, that it only runs on its own (_loop
        skips reads in a reply that also acts: live v11 replay, look + 3 interacts acted blind)."""
        out = []
        for t in self._schemas():
            f = t.get("function") or {}
            if f.get("name") in self.read_tools and READ_ALONE not in (f.get("description") or ""):
                t = {**t, "function": {**f, "description": (f.get("description") or "").rstrip() + " " + READ_ALONE}}
            out.append(t)
        if self.say_channel:
            out.insert(0, SAY_SCHEMA)
        return out

    def _schemas(self) -> list[dict]:
        hide_goal = self.director is not None and self.director.hides_start_goal
        brain = [tool_schema("remember"), tool_schema("run_skill")] + ([] if hide_goal else [START_GOAL]) + \
            ([LIST_SKILLS, FORGET_SKILL] if self.skills is not None else [])
        if self.knowledge is not None:  # the kinds it can filter on come from the index itself
            kinds = ", ".join(self.knowledge.kinds())
            brain.insert(0, tool_schema("lookup", TOOLS["lookup"][1] + (f" kind values: {kinds}." if kinds else "")))
        rules = [tool_schema(n) for n in RULE_TOOLS if self.has(n)]
        if self.director is not None:
            brain = brain + list(self.director.tool_schemas())
        if self.caps is not None:  # the body's manifest: its own descriptions and schemas
            return [self.caps.function_schema(n) for n in self.caps.llm_tools()] + rules + brain
        # No manifest (mock, server puppet): the brain's own schemas, still only for tools the body has.
        acts = [n for n in ACTION_TOOLS if self.has(n)]
        reads = [n for n in READ_TOOLS if self.has(n) and n not in BRAIN_TOOLS]
        return [tool_schema(n) for n in reads + acts] + rules + brain

    def attach_director(self, director) -> None:
        """Offer the task board's tools (docs/design/director.md §8): board tools never interrupt a job,
        board() is read-only, and start_goal is hidden when the director says it subsumes it."""
        self.director = director
        self.read_tools |= set(director.read_tool_names)
        self.tools = self._tool_list()

    def non_interrupting(self) -> set[str]:
        return NON_INTERRUPTING | (set(self.director.tool_names) if self.director is not None else set())

    def offered(self) -> set[str]:
        return {t["function"]["name"] for t in self.tools}

    def note_event(self, event: Event) -> None:
        if isinstance(event, PROGRESS_EVENTS):
            return  # progress is narrated, not context
        if getattr(event, "type", None) in ("command_received", "chat_heard"):
            return  # chat has its own memory (context "chat"); here it would push body results out of the window
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

    def spell_lines(self) -> list[str]:
        """One line per spell (speed plan §2.2: the JSON rows were ~6k characters): name, role, what it
        does (80 chars), why it can't be cast now, and HOW it is really used (``how``, body-supplied from
        data/spell_mechanics.json, SPELL_HOW_CHARS): drop-then-cast (Divine Rock: drop 5 ore), cast-on-a-thing,
        held open while walking (Recall). ``spells`` (read) has the full rows."""
        out = []
        for s in self.castable_spells():
            bits = [str(s.get("role") or "")]
            if s.get("for"):
                bits.append(f"for: {s['for']}")
            if s.get("needs"):
                bits.append(f"needs: {s['needs']}")
            if s.get("castable") is False:
                bits.append("NOT castable now: " + str(s.get("reason") or "?"))
            elif s.get("remaining_s"):
                bits.append(f"cooldown {float(s['remaining_s']):.0f}s")
            use = clip(str(s.get("use_when") or ""), 80)
            how = clip(str(s.get("how") or ""), SPELL_HOW_CHARS)
            out.append(f"{s.get('name')} ({', '.join(b for b in bits if b)})" + (f": {use}" if use else "")
                       + (f" | how: {how}" if how else ""))
        return out

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
            # spoken_to=false: a body/board run, nobody said anything (L31: "hey! what we up to?" unprompted)
            "command": {"player": player, "text": text, "addressed": addressed, "spoken_to": bool(text)},
            "situation": sit.summary(state, active_goal=active_goal, tasks=tasks, places=self.store.places(),
                                     looks_supported=self.can_look),
            "active_goal": active_goal,
            "board": self.director.brief() if self.director is not None else None,
            "goal_tasks": tasks,
            "notes": self._notes(),
            "learned_skills": self.learned_skills(text or (self.director.retrieval_text(body_event)
                                                            if self.director is not None else "")),
            "castable_spells": self.spell_lines(),
            "reflex_rules": self.reflex_rules(),
            # chat lines are in "chat", body situations in body_status: only the rest, newest 5
            "recent_events": [e for e in self.events if e.get("type") not in ("command_received", "chat_heard")][-5:],
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

    def house_rules(self) -> str:
        """Luis's house rules (brain/house_rules.md, or DW_HOUSE_RULES): rules the MODEL follows, not
        code vetoes (PRINCIPLES #2). Re-read when the file changes, so he can edit it any time."""
        path = Path(os.environ.get("DW_HOUSE_RULES") or Path(__file__).with_name("house_rules.md"))
        try:
            mtime = path.stat().st_mtime
        except OSError:
            return ""
        if self._rules_file != (str(path), mtime):
            text = path.read_text(encoding="utf-8")
            lines = [ln.strip() for ln in text.splitlines() if ln.strip().startswith(("-", "*"))]
            self._rules_file, self._rules_text = (str(path), mtime), "\n".join(lines)
        return self._rules_text

    def persona(self) -> str:
        """brain/persona.md (voice workstream; re-read on change, DW_PERSONA overrides; PERSONA is the
        fallback when the file is missing), then Luis's house rules."""
        persona = persona_file.render(persona_file.template(fallback=PERSONA), name=self.name, player=self.player,
                                      triggers=", ".join(SENSABLE_TRIGGERS),
                                      look_rule=LOOK_RULE if self.can_look else NO_LOOK_RULE,
                                      lookup_rule=LOOKUP_RULE if self.knowledge is not None else "")
        if not self.say_channel:
            persona += "\n\n" + TEXT_CHANNEL_NOTE
        if self.director is not None:
            persona += "\n\n" + self.director.persona_lines()
        rules = self.house_rules()
        if rules:
            persona += (f"\n\nHouse rules from {self.player} (always follow them; they are his, not yours to "
                        f"change):\n{rules}")
        return persona + "\n\n" + WIRE_COORDINATES

    # ---------------------------------------------------------------- the bounded loop

    def decide(self, player: str, text: str, state: dict, active_goal: str | None, addressed: bool = True,
               body_event: dict | None = None) -> Decision:
        self._state_for_reads = state
        context = self.context(player, text, state, active_goal, addressed, body_event)
        messages = [{"role": "system", "content": self.persona()},
                    {"role": "user", "content": json.dumps(context, default=str, ensure_ascii=False)}]
        d = Decision()
        if addressed and (text or "").strip() and body_event is None:
            d.effort = self.addressed_effort  # a player's line to him: think a little more (latency budget M1)
        resp, messages = self._loop(messages, d)
        d.speech = self.speech_of(resp)
        d.messages = messages + [assistant_message(resp)]
        self._collect(resp.tool_calls, d, state)
        # A real action or a new goal pre-empts the current job; remember(), spells, standing
        # orders and chat do not.
        d.interrupts = bool(d.goal or d.skill or any(a.name not in self.non_interrupting() for a in d.actions))
        if not d.actions and not d.goal and not d.skill and not d.refusals:
            self._unseen_fallback(d)
        return d

    def _loop(self, messages: list[dict], d: Decision, label: str = "") -> tuple[LLMResponse, list[dict]]:
        """At most ``max_calls`` model calls: read-only tools run inline and their results go back;
        the first response with a real action (or none at all) ends the loop."""
        offered = self.offered()
        resp = LLMResponse()
        for step in range(self.max_calls):
            tag = f"{label}{step}" if label else step
            resp = self._complete(messages, self.tools, d, step=tag)
            calls = self.acts(resp)
            reads = [c for c in calls if c.name in self.read_tools and c.name in offered]
            commits = [c for c in calls if c.name not in self.read_tools]
            if commits or not reads:
                break  # the first real action ends the turn (reads alongside an action are not run)
            if step == self.max_calls - 1:
                self.log.log("controller_budget_exhausted", calls=d.model_calls)
                resp, messages = self._final_pass(messages, resp, reads, d, tag)
                break
            messages = messages + [assistant_message(resp)]
            for call in reads:
                messages.append(tool_result_message(call, self._read(call, d)))
            self._answer_says(messages, resp)
            if step == self.max_calls - 2:
                messages.append({"role": "user", "content": "Last step: act now on what you found, or reply."})
        return resp, messages

    def _final_pass(self, messages: list[dict], resp: LLMResponse, reads: list[ToolCall], d: Decision,
                    tag) -> tuple[LLMResponse, list[dict]]:
        """The read budget ran out with the model still only looking (live 22:20:15: look, look, inventory,
        then nothing was done and a template spoke a raw failure). Like LangChain's early_stopping_method
        "generate": the over-budget reads are answered "not run" and ONE final call is made with only the
        acting tools offered, so it acts on what it found or replies. A budget, not a veto."""
        base = messages
        messages = messages + [assistant_message(resp)]
        for call in reads:  # the budget is spent: these are answered, not run
            messages.append(tool_result_message(call, {"ok": None, "note": "not run: no more looking this turn"}))
        self._answer_says(messages, resp)
        messages.append({"role": "user", "content": FINAL_PASS_NOTE})
        tools = [t for t in self.tools if t["function"]["name"] not in self.read_tools]
        try:
            final = self._complete(messages, tools, d, step=f"{tag}final")
        except (ContinuationBudgetDenied, ContinuationInvalidated):
            raise
        except Exception as exc:  # the turn ends as before (nothing done), the error is logged
            self.log.log("controller_final_pass", ok=False, error=repr(exc))
            return resp, base
        self.log.log("controller_final_pass", ok=True, actions=[c.name for c in final.tool_calls],
                     speech=self.speech_of(final, log=False))
        return final, messages

    # ---------------------------------------------------------------- the speech channel

    def speech_of(self, resp: LLMResponse, log: bool = True) -> str | None:
        """The reply's line. Say channel: the text of its say call(s) only; the free text is a private note,
        logged and never spoken. Text channel (legacy): the free text."""
        if not self.say_channel:
            return strip_markers(resp.content)
        note = strip_markers(resp.content)
        if note and log:
            self.log.log("controller_note", text=note)  # the model's own words to itself: never chat
        lines = [strip_markers(str((c.arguments or {}).get("text") or "")) for c in resp.tool_calls
                 if c.name == SAY_TOOL]
        return " ".join(x for x in lines if x) or None

    def acts(self, resp: LLMResponse) -> list[ToolCall]:
        """The reply's tool calls other than say (say is speech, not a tool the body runs)."""
        if not self.say_channel:
            return list(resp.tool_calls)
        return [c for c in resp.tool_calls if c.name != SAY_TOOL]

    @staticmethod
    def _say_result(failed: bool = False, held: bool = False) -> dict:
        """What a say call's tool result tells the model (every tool_use needs a tool_result)."""
        if held:
            return {"ok": True, "note": "not said yet: only the say in the reply that ends your turn is heard; "
                                        "call say again then if you still want to say it"}
        if failed:
            return {"ok": None, "note": "not said: a step failed first; say what's true now"}
        return {"ok": True, "note": "said"}

    def _answer_says(self, messages: list[dict], resp: LLMResponse) -> None:
        """A reply that only looked (its reads run inline) may also have called say: answer it (held)."""
        if self.say_channel:
            for call in resp.tool_calls:
                if call.name == SAY_TOOL:
                    messages.append(tool_result_message(call, self._say_result(held=True)))

    def _sent_effort(self, d: Decision | None = None) -> str | None:
        """The effort a call sends: the request's own level, else the client's default (logged, L27)."""
        return (d.effort if d is not None else None) or getattr(self.llm, "effort", None)

    def _complete(self, messages: list[dict], tools: list[dict], d: Decision, *, step=None) -> LLMResponse:
        """One model call at the request's effort (passed only when it overrides the client's default)."""
        if self.continuation_admission is not None and not self.continuation_admission():
            raise ContinuationBudgetDenied("continuation model budget unavailable or exhausted")
        self.log.log("prompt", component="controller", model=self.llm.model, step=step,
                     effort=self._sent_effort(d), **request_log_fields(self.llm, messages, tools, d.effort))
        response = (self.llm.complete(messages, tools=tools, effort=d.effort) if d.effort else
                    self.llm.complete(messages, tools=tools))
        # Paid response accounting precedes stale-continuation rejection; no action is applied here.
        d.model_calls += 1
        self.log.log("llm_response", component="controller", step=step, content=response.content,
                     tool_calls=[vars(c) for c in response.tool_calls], usage=response.usage,
                     finish_reason=response.finish_reason)
        if self.continuation_validate is not None:
            self.continuation_validate()
        return response

    def warm_up(self) -> dict | None:
        """L27 (dev run 23:32:58: the session's first model call took 11.2 s: litellm's ~5 s import, a
        cold TLS connection and the first cache write). One tiny request with the real persona + tools at
        session start, so the first chat line finds them warm. Skipped for clients without ``warm``."""
        warm = getattr(self.llm, "warm", None)
        if warm is None:
            return None
        messages = [{"role": "system", "content": self.persona()},
                    {"role": "user", "content": json.dumps({"command": {"player": self.player, "text": "",
                                                                        "addressed": False},
                                                            "note": "session warm-up: reply with no text at all"})}]
        try:
            res = warm(messages, self.tools)
        except Exception as exc:  # a failed warm-up only means the first call is cold
            self.log.log("llm_warmup", ok=False, error=repr(exc))
            return None
        self.log.log("llm_warmup", ok=True, model=self.llm.model, effort=self._sent_effort(), **res)
        if self.addressed_effort and self.addressed_effort != self._sent_effort():
            try:  # the addressed-chat level has its own cache entry (top-level effort is part of the prompt)
                more = warm(messages, self.tools, effort=self.addressed_effort)
                self.log.log("llm_warmup", ok=True, model=self.llm.model, effort=self.addressed_effort, **more)
            except Exception as exc:
                self.log.log("llm_warmup", ok=False, effort=self.addressed_effort, error=repr(exc))
        return res

    def arg_help(self, tool: str) -> dict[str, str]:
        """The offered schema's own argument descriptions (sent back with a failure so the model can
        call the tool right the next time: generic, from the tool contract)."""
        for t in self.tools:
            f = t.get("function") or {}
            if f.get("name") == tool:
                props = (f.get("parameters") or {}).get("properties") or {}
                return {k: str(v.get("description") or v.get("type") or "") for k, v in props.items()
                        if isinstance(v, dict)}
        return {}

    def next_turn(self, d: Decision, results: dict[str, dict], state: dict | None = None,
                  failed: bool = False, note: str | None = None) -> Decision:
        """The standard agent loop: the results of the turn's tool calls go back to the model, which
        continues its plan (more tools), reports, or stops (an empty reply). Reads run inline again."""
        msgs = list(d.messages)
        calls = (msgs[-1].get("tool_calls") or []) if msgs else []
        for tc in calls:  # every tool call of the turn needs a result
            name = (tc.get("function") or {}).get("name")
            res = results.get(tc.get("id")) or results.get(name) or (
                {"ok": None, "note": "not run: an earlier step failed"} if failed else
                {"ok": None, "note": "not run: a read alongside an action is skipped; call it on its own"}
                if name in self.read_tools else results.get(SAY_TOOL) or self._say_result(failed)
                if name == SAY_TOOL and self.say_channel else {"ok": None, "note": "not run"})
            msgs.append(tool_result_message(ToolCall(name or "?", {}, tc.get("id")), res))
        observation = continuation_observation(state)
        msgs.append({"role": "user", "content": "Current observation: " + json.dumps(observation, ensure_ascii=False)})
        msgs.append({"role": "user", "content": note or (
            "A step did not work (results above). Fix it with the right tool or another way; if you can't, "
            "tell the player in one short plain line what's wrong and what you need." if failed else
            "Your tools ran (results above). Continue with the next step, or stop. Say something only if the "
            "player needs to hear it (an answer he asked for, a result he can't see, a problem); otherwise "
            "reply with no text at all.")})
        self._state_for_reads = state or {}
        d2 = Decision(effort=d.effort)  # the same request keeps its effort (and its cache entry)
        resp, msgs = self._loop(msgs, d2, label="turn")
        msgs = msgs + [assistant_message(resp)]
        speech = self.speech_of(resp)
        if speech and not self.acts(resp) and note is None and self.check_talk_only:
            self._answer_says(msgs, resp)  # the held line is a tool call too: answer it before the check request
            resp, msgs, speech = self._talk_only_check(msgs, d2, speech)
        d2.speech = speech
        d2.messages = msgs
        self._collect([c for c in self.acts(resp) if c.name not in self.read_tools], d2, state or {})
        d2.interrupts = any(a.name not in self.non_interrupting() for a in d2.actions)
        return d2

    def _talk_only_check(self, msgs: list[dict], d: Decision, speech: str) -> tuple[LLMResponse, list[dict], str]:
        """A follow-up turn that only talked (its line not yet said): the model gets one more call to add
        the tool calls its line implies. Calls -> they run with its (possibly reworded) line; a new line and
        no calls -> its correction is said instead (it can't do what it first said); an empty reply -> the
        original line stands. Information only: the model's own reply is used, never rewritten.
        The agent's first-turn check (agent.PROMISE_NOTE, passed as ``note``) is never doubled."""
        try:
            resp, out = self._loop(msgs + [{"role": "user", "content": TALK_ONLY_NOTE}], d, label="check")
        except (ContinuationBudgetDenied, ContinuationInvalidated):
            raise
        except Exception as exc:  # a failed check only means the line is said as it was
            self.log.log("talk_only_check", speech=speech, error=repr(exc))
            return LLMResponse(content=speech), msgs, speech
        calls = [c.name for c in self.acts(resp)]
        reworded = self.speech_of(resp)
        self.log.log("talk_only_check", speech=speech, actions=calls, reworded=reworded)
        if not calls and not reworded:
            return LLMResponse(content=speech), msgs, speech
        return resp, out + [assistant_message(resp)], reworded or speech

    def _read(self, call: ToolCall, d: Decision) -> dict:
        """Run one read-only tool (no interrupt, no task) and return a compact result for the model."""
        if call.name == "list_skills":
            recs = self.skills.all() if self.skills else []
            return {"ok": True, "data": {"skills": [{"name": r.name, "ok": r.stats.ok, "runs": r.stats.runs}
                                                    for r in recs]}}
        try:
            args = self._validate(call.name, call.arguments)
        except Exception as exc:
            return {"ok": False, "reason": Reason.INVALID_ARGS, "error": str(exc)[:300]}
        self.log.log("tool_call", tool=call.name, args=args, read_only=True)
        if self.director is not None and call.name in self.director.read_tool_names:
            res = self.director.handle_tool(call.name, args, self.player)  # board(): the task board, read-only
        elif call.name in BRAIN_TOOLS:  # answered by the brain (knowledge index), never sent to the body
            res = self._brain_read(call.name, args)
        else:
            res = self.game.call(call.name, args)
        self.log.log("tool_result", tool=call.name, result=res, read_only=True)
        if call.name == "inventory" and res.get("ok"):
            # item stats from game data + numeric deltas to what is equipped (the model judges)
            res = {**res, "data": item_stats.enrich_inventory(res["data"], getattr(self, "_state_for_reads", None) or {})}
            d.inventory = res["data"]
        if call.name == "look" and res.get("ok"):
            look = {**res["data"], "_about": args.get("about")}
            d.looks.append(look)
            if args.get("about"):  # say it plainly to the model too (the body only ranks by match score)
                res = {**res, "data": {**res["data"], "matched": bool(sit.look_matched(look))}}
        if not res.get("ok") and res.get("reason") in Reason.CANT_YET:
            res = {**res}
            res.setdefault("note", f"you can't {call.name} yet")
        return _model_read_view(res)

    def _brain_read(self, tool: str, args: dict) -> dict:
        if tool == "lookup" and self.knowledge is not None:
            try:
                return self.knowledge.lookup(args["query"], args.get("kind"))
            except Exception as exc:  # knowledge is best effort; never break the turn on it
                return {"ok": False, "reason": Reason.BODY_ERROR, "data": {"error": repr(exc)[:200]}}
        return {"ok": False, "reason": Reason.NOT_IMPLEMENTED, "data": {"tool": tool}}

    def _collect(self, calls: list[ToolCall], d: Decision, state: dict) -> None:
        offered = self.offered()
        for call in calls:
            if call.name in self.read_tools or (call.name == SAY_TOOL and self.say_channel):
                continue  # say is the turn's line (speech_of), not an action
            if call.name not in offered and self.caps is not None:  # a legacy name (pickup -> fetch)
                new, args = self.caps.resolve(call.name, call.arguments or {})
                if new != call.name and new in offered:
                    self.log.log("controller_alias", said=call.name, tool=new, args=args)
                    call.name, call.arguments = new, args
            if call.name == "start_goal":
                if call.arguments.get("goal"):
                    d.goal = str(call.arguments["goal"])
                else:
                    d.refusals.append((call.name, Reason.INVALID_ARGS, {"error": "start_goal needs a goal"}))
                    d.invalid.append(call)
                continue
            if call.name == "forget_skill":
                d.actions.append(call)
                continue
            if call.name == "run_skill":
                self._collect_skill(call, d)
                continue
            if call.name not in offered or call.name == "start_goal":
                self.log.log("controller_unknown_tool", tool=call.name)
                # a tool this body lacks or no tool at all (the model reached for it anyway): say so
                # truthfully instead of speaking a reply that claims the action (review H4)
                d.refusals.append((call.name, Reason.NOT_IMPLEMENTED if call.name in TOOLS else Reason.UNKNOWN_TOOL, {}))
                d.invalid.append(call)
                continue
            if call.name == "set_reflex_rule":
                trig = call.arguments.get("trigger")
                kind = trig.get("kind") if isinstance(trig, dict) else trig
                if kind not in SENSABLE_TRIGGERS:  # only what the body can sense
                    self.log.log("controller_cant_sense", trigger=kind)
                    d.refusals.append((call.name, Reason.CANT_SENSE, {"trigger": kind,
                                                                      "can_sense": list(SENSABLE_TRIGGERS)}))
                    d.invalid.append(call)
                    continue
            try:
                call.arguments = self._validate(call.name, call.arguments)
            except Exception as exc:
                self.log.log("controller_invalid_call", tool=call.name, error=str(exc))
                d.refusals.append((call.name, Reason.INVALID_ARGS, {"error": str(exc)[:300]}))
                d.invalid.append(call)
                continue
            refusal = self.safety(call, state)
            if refusal:
                self.log.log("controller_safety_refusal", tool=call.name, args=call.arguments, refusal=refusal)
                d.refusals.append(refusal)
                d.invalid.append(call)
                continue
            d.actions.append(call)

    def _validate(self, name: str, args: dict) -> dict:
        """The body's published schema when it has one for this tool, else the brain's own model."""
        if self.director is not None and name in self.director.tool_names:
            return self.director.validate_tool(name, args)
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
        """An action failed: ``next_turn`` with the failure (and the earlier steps' real results)."""
        return self.next_turn(d, {**(results or {}), call.id or call.name: result}, state, failed=True)

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
        text = clip(strip_markers(text) or "")  # never a protocol marker in chat (BUGS.md L18)
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

    def report_failure(self, tool: str, reason: str | None, data: dict | None = None) -> None:
        """Say why an immediate action failed, in words that match what happened."""
        data = data or {}
        spell = spell_label(data.get("spell") or (data.get("rule") or {}).get("spell"))
        reason_base = (reason or "").split(":", 1)[0]
        detail = data.get("detail")
        speaks = tool == "gather" or (self.caps is not None and self.caps.speaks_detail(tool))
        found = data.get("found") if isinstance(data.get("found"), dict) else {}
        name = data.get("name") or found.get("name")  # the thing's in-game name, for player_words
        if speaks and isinstance(detail, str) and detail.strip() and reason not in Reason.CANT_YET:
            # the client skills write a truthful chat sentence for each failure (manifest detail_is_speech)
            self.say(player_words(detail.strip(), name))
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
            detail = data.get("detail")
            why = next((x for x in (reason, detail) if isinstance(x, str) and " " in x.strip()), None)  # a sentence
            why = re.sub(r"^[a-z_]+:\s*", "", why) if why else why  # "verification_failed: not following" -> the words
            why = player_words(why, name) if why else why
            if reason_base == Reason.VERIFICATION_FAILED:
                # the verifier's words are the brain's own measurement ("still 3.3m from target", L36): they go
                # to the model in the tool result; chat gets the plain skill line
                why = None
            self.say(f"Sorry, I couldn't {SKILL_PHRASES.get(tool, tool.replace('_', ' '))}"
                     + (f": {why.strip().rstrip('.')}." if why else "."))

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

    @staticmethod
    def stuck_line(goal: str, failed: str | None, reason: str | None, question: str | None = None) -> str:
        """The template for a stuck job: used only when the model call for the ``stuck`` situation fails
        or says nothing (a stuck job must always be told: communication is paramount)."""
        base = (reason or "").split(":", 1)[0]
        why = REASON_PHRASES.get(base) or (reason or "").replace("_", " ")
        what = f" {failed} keeps failing ({why})." if failed else (f" ({why})" if why else "")
        return f"I'm stuck on '{clip(goal, 60)}'.{what} {question or 'Can you help me out?'}".strip()

    # ---------------------------------------------------------------- progress on long jobs

    def job_started(self) -> None:
        """The start of a long job counts as the last update: the first progress line comes later."""
        self._progress_at, self._progress_last = self.clock(), None

    def progress(self, text: str) -> bool:
        """A progress note: logged and kept for body_status ("how's it going?"), never said by itself
        (voice workstream: doing the job needs no commentary)."""
        if not text or text == self._progress_last:
            return False
        self._progress_at, self._progress_last = self.clock(), text
        self.log.log("progress", text=text)
        if self.on_progress:
            self.on_progress(text)
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

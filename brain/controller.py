"""Controller: interprets chat, decides interrupts, and owns ALL speech.

Only ``Controller.say`` ever calls ``game.say`` (design principle 6). Speech
is produced after the action decision and is overridden if an action fails,
so the companion never says one thing while doing another.

Each LLM call carries a bounded context (principle 4): persona and rules, tool
definitions, notes, current goal and progress, fresh state and the last N events.
"""
from __future__ import annotations

import json
import re
import time
from collections import deque
from dataclasses import dataclass, field

from .interface import RULE_TOOLS, SENSABLE_TRIGGERS, Event, GameInterface, Reason, tool_schema, validate_args
from .jsonl_log import JsonlLogger
from .llm import LLMClient, ToolCall
from .spells import SpellBook
from .state_store import StateStore

PERSONA = """You are {name}, an AI companion playing RuneScape: Dragonwilds with {player}.
You talk like a friendly fellow player: short, casual lines (one sentence, no emojis).
Decide what to do about the player's message by calling tools:
- Simple, immediate requests (follow me, wait here, come here, attack that, stop, give me X,
  pick that up, drop the logs) -> call the matching tool directly. "wait here" = stop. "come here" = go_to the player.
- Multi-step jobs (gather X then build/bring Y) -> call start_goal with the goal in plain words.
- Facts worth keeping (places, preferences) -> call remember.
- Chit-chat -> no tool.
Call AT MOST ONE action tool per message. Calling an action tool cancels whatever job you
are doing, so never pair an action with stop: "follow me" is just follow. Only call stop
when the player asks you to stop or wait. If the player only comments on your work, do
not call a tool. Always also reply with one short line of text.
Only act on things that are actually in the state; never substitute a different item or target for the one the player named. If it isn't there, say so ("I can't see any sticks").
Use entity ids and names exactly as they appear in the state. "me"/"I" is the player in
command.player: pass that exact value as the player or target argument.
Spells: castable_spells lists what you can cast (name, role, when to use it). "Cast X" / "shield
up" -> cast with that name (self spells need no target). If a spell is not listed, you can't cast
it: say so instead of calling cast.
Standing orders: "every time / whenever / if X, do Y" (usually about a fight) -> set_reflex_rule,
so your body reacts instantly without asking you. enemy = the enemy kind Luis named ("kalphite"),
or "*" if he named none. You can only sense these triggers: {triggers}.
If X is not one of them (a sound, a colour, something an enemy says, weather...), do NOT call
set_reflex_rule: say you can't sense that. Map his words: "raises its claws", "winds up",
"about to hit", "attacks" -> telegraph; "windstep away" -> actions evade then cast Windstep at self.
reflex_rules lists current orders: "what are your orders" -> list_rules; "stop doing that" /
"forget that" -> clear_rule with the matching id."""

START_GOAL = {
    "type": "function",
    "function": {
        "name": "start_goal",
        "description": "Hand a multi-step job to the planner, e.g. 'gather 10 logs and bring them to Luis'.",
        "parameters": {"type": "object", "properties": {"goal": {"type": "string"}}, "required": ["goal"]},
    },
}
ACTION_TOOLS = ["follow", "stop", "go_to", "attack", "give", "pickup", "drop", "cast"]
# How to name a skill in "I can't ... yet".
SKILL_PHRASES = {"follow": "follow you", "stop": "stop", "go_to": "walk somewhere", "attack": "fight",
                 "give": "hand items over", "gather": "gather", "craft": "craft", "place": "build",
                 "pickup": "pick things up", "drop": "drop things", "cast": "cast that spell",
                 "set_reflex_rule": "do that as a reflex", "list_rules": "list my orders",
                 "clear_rule": "forget orders"}
# Actions that leave the current job running (a spell or a standing order is not a new job).
NON_INTERRUPTING = {"remember", "cast", *RULE_TOOLS}
CONTROLLER_TOOLS = ([tool_schema(n) for n in ACTION_TOOLS] + [tool_schema(n) for n in RULE_TOOLS]
                    + [tool_schema("remember"), START_GOAL])


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


@dataclass
class Decision:
    actions: list[ToolCall] = field(default_factory=list)
    speech: str | None = None
    goal: str | None = None
    interrupts: bool = False
    # (tool, reason, data) the Controller refused before reaching the body, e.g. cant_sense
    refusals: list[tuple[str, str, dict]] = field(default_factory=list)


class Controller:
    def __init__(self, llm: LLMClient, game: GameInterface, store: StateStore, logger: JsonlLogger,
                 name: str = "Claude", player: str = "Luis", recent_events: int = 10,
                 spellbook: SpellBook | None = None, rules_ttl: float = 60.0):
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

    def note_event(self, event: Event) -> None:
        self.events.append(event.model_dump())

    # ---------------------------------------------------------------- context: spells and standing orders

    def rules_changed(self) -> None:
        self._rules_at = None

    def reflex_rules(self) -> list[str]:
        """One line per standing order, refreshed after any rule tool call (or every rules_ttl s)."""
        now = time.monotonic()
        if self._rules_at is not None and now - self._rules_at < self.rules_ttl:
            return self._rules
        self._rules_at = now
        res = self.game.list_rules()
        rules = res["data"].get("rules") if res.get("ok") else None
        self._rules = [describe_rule(r) for r in rules] if isinstance(rules, list) else []
        return self._rules

    def castable_spells(self) -> list[dict]:
        try:
            return self.spellbook.castable()
        except Exception as exc:  # context is best effort; never block a decision on it
            self.log.log("spellbook_error", error=repr(exc))
            return []

    def decide(self, player: str, text: str, state: dict, active_goal: str | None) -> Decision:
        tree = self.store.tree
        context = {
            "command": {"player": player, "text": text},
            "active_goal": active_goal,
            "goal_tasks": [t.model_dump(include={"skill", "args", "status"}) for t in tree.tasks]
            if tree and active_goal else [],
            "notes": self.store.notes(),
            "state": state,
            "castable_spells": self.castable_spells(),
            "reflex_rules": self.reflex_rules(),
            "recent_events": list(self.events),
        }
        persona = PERSONA.format(name=self.name, player=self.player, triggers=", ".join(SENSABLE_TRIGGERS))
        messages = [
            {"role": "system", "content": persona},
            {"role": "user", "content": json.dumps(context, default=str)},
        ]
        self.log.log("prompt", component="controller", model=self.llm.model, messages=messages)
        resp = self.llm.complete(messages, tools=CONTROLLER_TOOLS)
        self.log.log("llm_response", component="controller", content=resp.content,
                     tool_calls=[vars(c) for c in resp.tool_calls])

        decision = Decision(speech=(resp.content or "").strip() or None)
        for call in resp.tool_calls:
            if call.name == "start_goal" and call.arguments.get("goal"):
                decision.goal = str(call.arguments["goal"])
            elif call.name in ACTION_TOOLS or call.name in RULE_TOOLS or call.name == "remember":
                if call.name == "set_reflex_rule":
                    trig = call.arguments.get("trigger")
                    kind = trig.get("kind") if isinstance(trig, dict) else trig
                    if kind not in SENSABLE_TRIGGERS:  # only what the body can sense
                        self.log.log("controller_cant_sense", trigger=kind)
                        decision.refusals.append((call.name, Reason.CANT_SENSE, {"trigger": kind}))
                        continue
                try:
                    call.arguments = validate_args(call.name, call.arguments)
                except Exception as exc:
                    self.log.log("controller_invalid_call", tool=call.name, error=str(exc))
                    continue
                decision.actions.append(call)
            else:
                self.log.log("controller_unknown_tool", tool=call.name)
        # A real action or a new goal pre-empts the current job; remember(), spells, standing
        # orders and chat do not.
        decision.interrupts = bool(decision.goal or any(a.name not in NON_INTERRUPTING for a in decision.actions))
        return decision

    # ---------------------------------------------------------------- speech (single voice)

    def say(self, text: str) -> dict | None:
        self.log.log("say", text=text)
        res = self.game.say(text)
        if isinstance(res, dict):
            self.log.log("say_result", ok=res.get("ok"), reason=res.get("reason"), data=res.get("data"))
        return res

    def report_failure(self, tool: str, reason: str | None, data: dict | None = None) -> None:
        """Say why an immediate action failed, in words that match what happened."""
        data = data or {}
        spell = spell_label(data.get("spell") or (data.get("rule") or {}).get("spell"))
        if reason == Reason.CANT_SENSE:
            self.say("I can't sense that, so I can't react to it. I can watch for attacks starting, "
                     "health levels, enemies bunching up, stuns and spell cooldowns.")
        elif reason == Reason.ON_COOLDOWN:
            left = data.get("remaining_s")
            self.say(f"{spell} is still on cooldown" + (f" ({float(left):.0f}s left)." if left else "."))
        elif reason == Reason.NOT_UNLOCKED:
            self.say(f"You haven't unlocked {spell}, so I can't use it either.")
        elif reason == Reason.UNSAFE:
            self.say(f"Not casting {spell} there, it would hit you.")
        elif reason == Reason.NOT_ENOUGH and tool == "cast":
            self.say(f"I don't have the runes for {spell}.")
        elif reason in Reason.CANT_YET:
            self.say(f"Sorry, I can't {SKILL_PHRASES.get(tool, tool.replace('_', ' '))} yet.")
        elif reason == Reason.STATE_UNAVAILABLE:
            self.say(f"I can't {SKILL_PHRASES.get(tool, tool.replace('_', ' '))} yet: I can't read the game state.")
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
        what = f" {failed} keeps failing ({reason})." if failed else ""
        self.say(f"I'm stuck on '{goal}'.{what} {question or 'Can you help me out?'}".strip())

    def goal_done(self, goal: str) -> None:
        self.say(f"Done: {goal}.")

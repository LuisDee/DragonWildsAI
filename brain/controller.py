"""Controller: interprets chat, decides interrupts, and owns ALL speech.

Only ``Controller.say`` ever calls ``game.say`` (design principle 6). Speech
is produced after the action decision and is overridden if an action fails,
so the companion never says one thing while doing another.

Each LLM call carries a bounded context (principle 4): persona and rules, tool
definitions, notes, current goal and progress, fresh state and the last N events.
"""
from __future__ import annotations

import json
from collections import deque
from dataclasses import dataclass, field

from .interface import Event, GameInterface, Reason, tool_schema, validate_args
from .jsonl_log import JsonlLogger
from .llm import LLMClient, ToolCall
from .state_store import StateStore

PERSONA = """You are {name}, an AI companion playing RuneScape: Dragonwilds with {player}.
You talk like a friendly fellow player: short, casual lines (one sentence, no emojis).
Decide what to do about the player's message by calling tools:
- Simple, immediate requests (follow me, wait here, come here, attack that, stop, give me X)
  -> call the matching tool directly. "wait here" = stop. "come here" = go_to the player.
- Multi-step jobs (gather X then build/bring Y) -> call start_goal with the goal in plain words.
- Facts worth keeping (places, preferences) -> call remember.
- Chit-chat -> no tool.
Calling an action tool cancels whatever job you are doing; if the player only comments
on your work, do not call a tool. Always also reply with one short line of text.
Use entity ids and names exactly as they appear in the state. "me"/"I" is the player in
command.player: pass that exact value as the player or target argument."""

START_GOAL = {
    "type": "function",
    "function": {
        "name": "start_goal",
        "description": "Hand a multi-step job to the planner, e.g. 'gather 10 logs and bring them to Luis'.",
        "parameters": {"type": "object", "properties": {"goal": {"type": "string"}}, "required": ["goal"]},
    },
}
ACTION_TOOLS = ["follow", "stop", "go_to", "attack", "give"]
# How to name a skill in "I can't ... yet".
SKILL_PHRASES = {"follow": "follow you", "stop": "stop", "go_to": "walk somewhere", "attack": "fight",
                 "give": "hand items over", "gather": "gather", "craft": "craft", "place": "build"}
CONTROLLER_TOOLS = [tool_schema(n) for n in ACTION_TOOLS] + [tool_schema("remember"), START_GOAL]


@dataclass
class Decision:
    actions: list[ToolCall] = field(default_factory=list)
    speech: str | None = None
    goal: str | None = None
    interrupts: bool = False


class Controller:
    def __init__(self, llm: LLMClient, game: GameInterface, store: StateStore, logger: JsonlLogger,
                 name: str = "Companion", player: str = "Luis", recent_events: int = 10):
        self.llm = llm
        self.game = game
        self.store = store
        self.log = logger
        self.name = name
        self.player = player
        self.events: deque[dict] = deque(maxlen=recent_events)

    def note_event(self, event: Event) -> None:
        self.events.append(event.model_dump())

    def decide(self, player: str, text: str, state: dict, active_goal: str | None) -> Decision:
        tree = self.store.tree
        context = {
            "command": {"player": player, "text": text},
            "active_goal": active_goal,
            "goal_tasks": [t.model_dump(include={"skill", "args", "status"}) for t in tree.tasks]
            if tree and active_goal else [],
            "notes": self.store.notes(),
            "state": state,
            "recent_events": list(self.events),
        }
        messages = [
            {"role": "system", "content": PERSONA.format(name=self.name, player=self.player)},
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
            elif call.name in ACTION_TOOLS or call.name == "remember":
                try:
                    call.arguments = validate_args(call.name, call.arguments)
                except Exception as exc:
                    self.log.log("controller_invalid_call", tool=call.name, error=str(exc))
                    continue
                decision.actions.append(call)
            else:
                self.log.log("controller_unknown_tool", tool=call.name)
        # Any real action or a new goal pre-empts the current job; remember() and chat do not.
        decision.interrupts = bool(decision.goal or any(a.name != "remember" for a in decision.actions))
        return decision

    # ---------------------------------------------------------------- speech (single voice)

    def say(self, text: str) -> dict | None:
        self.log.log("say", text=text)
        res = self.game.say(text)
        if isinstance(res, dict):
            self.log.log("say_result", ok=res.get("ok"), reason=res.get("reason"), data=res.get("data"))
        return res

    def report_failure(self, tool: str, reason: str | None) -> None:
        """Say why an immediate action failed, in words that match what happened."""
        if reason in Reason.CANT_YET:
            self.say(f"Sorry, I can't {SKILL_PHRASES.get(tool, tool.replace('_', ' '))} yet.")
        elif reason == Reason.STATE_UNAVAILABLE:
            self.say(f"I can't {SKILL_PHRASES.get(tool, tool.replace('_', ' '))} yet: I can't read the game state.")
        else:
            self.say(f"I couldn't {tool.replace('_', ' ')}: {reason}.")

    def ask_for_help(self, goal: str, failed: str | None, reason: str | None, question: str | None = None) -> None:
        what = f" {failed} keeps failing ({reason})." if failed else ""
        self.say(f"I'm stuck on '{goal}'.{what} {question or 'Can you help me out?'}".strip())

    def goal_done(self, goal: str) -> None:
        self.say(f"Done: {goal}.")

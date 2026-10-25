"""Rule-based stand-ins for the Controller and Planner models (``run_live --dry-run``).

No network and no API spend: the live loop, the bridge and the body can be
exercised end to end while the "model" is a handful of keyword rules. It speaks
the same LLMClient interface as LiteLLMClient and records calls like FakeLLM.
"""
from __future__ import annotations

import json
import re

from .llm import LLMResponse, ToolCall


def _context(messages: list[dict]) -> dict:
    try:
        ctx = json.loads(messages[-1]["content"])
    except (KeyError, IndexError, TypeError, json.JSONDecodeError):
        return {}
    return ctx if isinstance(ctx, dict) else {}


def _target(word: str, situation: list[str]) -> str:
    """Match a spoken creature name against the ids in the situation digest; else use the word."""
    for line in situation:
        if line.startswith("Creatures:"):
            for chunk in line.split(";"):
                m = re.search(r"id ([^),]+)", chunk)
                if m and word.lower() in chunk.lower():
                    return m.group(1).strip()
    return word


class DryRunController:
    model = "dry-run/rules"

    def __init__(self) -> None:
        self.calls: list[dict] = []

    def complete(self, messages: list[dict], tools: list[dict] | None = None) -> LLMResponse:
        self.calls.append({"messages": messages, "tools": tools})
        ctx = _context(messages)
        cmd = ctx.get("command") or {}
        player, text = str(cmd.get("player", "")), str(cmd.get("text", "")).strip()
        low = text.lower()
        situation = [str(x) for x in ctx.get("situation") or []]

        def act(line: str, name: str, **args) -> LLMResponse:
            return LLMResponse(content=f"(dry run) {line}", tool_calls=[ToolCall(name, args)])

        if "follow" in low:
            return act("Right behind you.", "follow", player=player)
        if re.search(r"\b(stop|wait|stay)\b", low):
            return act("Okay, waiting here.", "stop")
        if re.search(r"\bcome( here| back)?\b", low):
            return act("On my way.", "go_to", target=player)
        if m := re.search(r"\b(?:kill|attack|fight)\s+(?:that\s+|the\s+)?(\w+)", low):
            return act("Going for it.", "attack", target=_target(m.group(1), situation))
        if m := re.search(r"\bgive me (\d+) (\w+?)s?\b", low):
            return act("Here you go.", "give", player=player, item=m.group(2), count=int(m.group(1)))
        if re.search(r"\b(gather|collect|build|bring|chop|mine)\b", low):
            return act("I'll work on that.", "start_goal", goal=text)
        return LLMResponse(content=f"(dry run) I heard: {text}")


class DryRunPlanner:
    model = "dry-run/planner"

    def __init__(self) -> None:
        self.calls: list[dict] = []

    def complete(self, messages: list[dict], tools: list[dict] | None = None) -> LLMResponse:
        self.calls.append({"messages": messages, "tools": tools})
        return LLMResponse(content=json.dumps({
            "tasks": [], "ask_help": "I'm in dry-run mode, so I can't plan multi-step jobs.",
        }))

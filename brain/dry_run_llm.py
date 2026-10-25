"""Rule-based stand-ins for the Controller and Planner models (``run_live --dry-run``).

No network and no API spend: the live loop, the bridge and the body can be
exercised end to end while the "model" is a handful of keyword rules. It speaks
the same LLMClient interface as LiteLLMClient and records calls like FakeLLM.
"""
from __future__ import annotations

import json
import re

from .broker import fallback_line
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

        last = messages[-1] if messages else {}
        # A failed action's follow-up (Controller.follow_up): the dry run has nothing better than the
        # truthful reason template, so it says nothing and the Agent falls back to it.
        if last.get("role") == "user" and not ctx:  # a continuation / follow-up / promise-check note
            return LLMResponse(content="")
        # A tool result came back this turn (a read tool such as inventory): answer from it.
        if last.get("role") == "tool":
            try:
                res = json.loads(last.get("content") or "{}")
            except json.JSONDecodeError:
                res = {}
            data = res.get("data") or {}
            if "bag" in data or "worn" in data:
                bits = [str(i.get("name")) + (f" x{i['count']}" if (i.get("count") or 1) > 1 else "")
                        for i in (data.get("hotbar") or []) + (data.get("bag") or []) if isinstance(i, dict)]
                return LLMResponse(content="(dry run) I've got " + (", ".join(bits) or "nothing") + ".")

        # A body situation (broker): the real model phrases it; the dry run says the template line.
        if ctx.get("body_event") and not text:
            ev = ctx["body_event"]
            return LLMResponse(content=fallback_line(ev.get("events") or [ev]) or "")
        # Episodic memory: answer from recent_activity (what the body did, whoever started it).
        if re.search(r"\bwhat (did|have) you (just )?(do|done|been doing)\b|\bdid you (just )?kill\b|\bremember\b", low):
            acts = [str(a) for a in ctx.get("recent_activity") or []]
            return LLMResponse(content=f"(dry run) Last thing I did: {acts[-1]}" if acts
                               else "(dry run) Nothing much since you last asked.")

        # Reading chat: nobody named him. Speak only when the line is meant for him.
        if cmd.get("addressed") is False:
            chat = [c for c in ctx.get("chat") or [] if isinstance(c, dict)]
            if m := re.search(r"\b(?:anyone|anybody|someone|who)\b.*\b(?:got|have|has)\b\s+(?:an?\s+|any\s+|some\s+)?(\w+)", low):
                want = m.group(1).lower().rstrip("s")
                kit = " ".join(x for x in situation if x.startswith(("You:", "Wearing:", "Carrying:"))).lower()
                return LLMResponse(content=f"(dry run) I've got a {want}." if want in kit else "")
            talking = any(c.get("ago_s", 999) <= 90 and (c.get("you") or (c.get("who") == player and "claude" in
                          str(c.get("text", "")).lower())) for c in chat)
            if not talking:
                return LLMResponse(content="")  # friends talking among themselves: stay out of it

        if re.search(r"\b(wear|wearing|equipment|gear|equipped|holding)\b", low):
            worn = next((x.split(":", 1)[1].strip() for x in situation if x.startswith("Wearing:")), "nothing special")
            held = re.search(r"holding ([^,]+)", " ".join(x for x in situation if x.startswith("You:")))
            return LLMResponse(content=f"(dry run) I'm wearing {worn}" + (f", holding {held.group(1)}." if held else "."))
        if re.search(r"\b(bag|carrying|inventory|backpack)\b", low) and any(
                t.get("function", {}).get("name") == "inventory" for t in tools or []):
            return LLMResponse(content="", tool_calls=[ToolCall("inventory", {})])

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

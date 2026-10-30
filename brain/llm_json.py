"""A model decision that must come back as valid JSON, with optional read-only research tool rounds.

Shared by the Planner (brain/planner.py) and the Director (review M7a: one validate-and-repair loop). One
*request* = one ``llm.complete`` call; every request goes through ``before_request`` (the budget gates: the daily
cap and the Director's hourly window) and ``on_response(resp)`` (usage logging), so callers count requests, not
decisions (review M5a).

    value, info = json_decision(llm, messages, validate, tools=..., run_tool=..., before_request=..., on_response=...)

* ``validate(text, round)`` returns the value, or ``(value, advisories)``: advisories are information for the
  model (a fact it listed as unknown, a test that is already true). They get ONE advisory round that is not a
  repair; the answer after it is accepted whatever its advisories (simplify item 4). A ValueError (or pydantic's
  ValidationError) is a real problem: its message goes back in a repair round.
* Tool rounds: while the model calls tools (and ``max_tool_rounds`` allows), each call runs through
  ``run_tool(name, args) -> result`` and the results go back. After the limit definitions stay present (LiteLLM
  would otherwise inject a dummy tool), but tool_choice=none disables research; violations still get refused.
  The request scope reaches synchronous forwarding wrappers and request logging without new keywords.
* Raises ``DecisionError`` when no valid answer came back, ``BudgetStop`` when ``before_request`` refused.
"""
from __future__ import annotations

import json
from typing import Any, Callable

from pydantic import ValidationError

from .llm import LLMClient, LLMResponse, assistant_message, request_tool_choice, tool_result_message

RESEARCH_OVER = "Research is over: answer now with the JSON object only, without calling more tools."


class DecisionError(Exception):
    pass


class BudgetStop(DecisionError):
    """before_request refused: out of budget (daily cap or hourly window)."""


def extract_json(text: str) -> str:
    start, end = (text or "").find("{"), (text or "").rfind("}")
    if start == -1 or end < start:
        raise ValueError("no JSON object in the response; answer with one JSON object")
    return text[start: end + 1]


def json_decision(llm: LLMClient, messages: list[dict], validate: Callable[[str, int], Any], *,
                  tools: list[dict] | None = None, run_tool: Callable[[str, dict], Any] | None = None,
                  max_tool_rounds: int = 3, max_repairs: int = 1,
                  before_request: Callable[[], bool] | None = None,
                  on_response: Callable[[LLMResponse], None] | None = None,
                  on_request: Callable[[list[dict], list[dict] | None], None] | None = None) -> tuple[Any, dict]:
    """Returns (value, info) with info = {requests, tool_calls: [{name, args, refused}], repairs, advised,
    messages}."""
    msgs = list(messages)
    info: dict[str, Any] = {"requests": 0, "tool_calls": [], "repairs": 0, "advised": False}
    can_research = bool(tools) and run_tool is not None
    tool_rounds = 0

    def repair(why: str) -> None:
        if info["repairs"] >= max_repairs:
            info["messages"] = msgs
            raise DecisionError(why)
        info["repairs"] += 1

    while True:
        if before_request is not None and not before_request():
            info["messages"] = msgs
            raise BudgetStop("out of budget")
        if can_research and tool_rounds >= max_tool_rounds and not info.get("research_over"):
            info["research_over"] = True
            msgs = msgs + [{"role": "user", "content": RESEARCH_OVER}]
        # Keep definitions for historical tool blocks, but disable further tool use at the limit.
        # https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools#controlling-claudes-output
        # https://github.com/BerriAI/litellm/blob/v1.106.4/litellm/llms/anthropic/chat/transformation.py
        choice = "none" if can_research and tool_rounds >= max_tool_rounds else None
        with request_tool_choice(choice):
            if on_request is not None:
                on_request(msgs, tools if can_research else None)
            resp = llm.complete(msgs, tools) if can_research else llm.complete(msgs)
        info["requests"] += 1
        if on_response is not None:
            on_response(resp)
        # Incomplete tool blocks must never be executed. Report the ceiling rather than blindly retry.
        # https://platform.claude.com/docs/en/build-with-claude/handling-stop-reasons
        if resp.finish_reason in ("length", "max_tokens", "model_context_window_exceeded"):
            raise DecisionError(f"model output truncated (finish_reason={resp.finish_reason})")
        if can_research and resp.tool_calls:
            over = tool_rounds >= max_tool_rounds
            tool_rounds += 1
            msgs = msgs + [assistant_message(resp)]
            for call in resp.tool_calls:
                info["tool_calls"].append({"name": call.name, "args": call.arguments, "refused": over})
                if over:
                    result = {"ok": False, "error": "research is over: answer with the JSON object now"}
                else:
                    try:
                        result = run_tool(call.name, call.arguments or {})
                    except Exception as exc:  # a research tool failing is information, not a crash
                        result = {"ok": False, "error": repr(exc)[:300]}
                msgs.append(tool_result_message(call, result))
            if over:
                repair("kept researching after the research limit")
            continue
        text = resp.content or ""
        try:
            out = validate(text, info["repairs"])
        except (ValueError, ValidationError) as exc:
            repair(f"no valid decision after {info['repairs']} repair(s): {str(exc)[:500]}")
            msgs = msgs + [{"role": "assistant", "content": text},
                           {"role": "user", "content": f"That answer was not usable: {exc}\n"
                                                       f"Return the corrected JSON object only."}]
            continue
        value, advisories = out if isinstance(out, tuple) and len(out) == 2 and isinstance(out[1], list) else (out, [])
        if advisories and not info["advised"]:  # one round of information, not a repair
            info["advised"] = True
            msgs = msgs + [{"role": "assistant", "content": text},
                           {"role": "user", "content": "Before you commit: " + " ".join(advisories) +
                            " Answer with the JSON object again (changed, or the same if it stands)."}]
            continue
        info["messages"] = msgs + [{"role": "assistant", "content": text}]
        return value, info

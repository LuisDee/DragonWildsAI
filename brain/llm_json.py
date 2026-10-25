"""A model decision that must come back as valid JSON, with optional read-only research tool rounds.

The validate-and-repair loop of ``Planner._ask`` (brain/planner.py), shared so the Director doesn't keep a second
copy (review M7a). One *request* = one ``llm.complete`` call; every request goes through ``before_request`` (the
budget gates: the daily cap and the Director's hourly window) and ``on_response`` (usage logging), so callers
count requests, not decisions (review M5a).

    value, info = json_decision(llm, messages, validate, tools=..., run_tool=..., before_request=..., on_response=...)

* ``validate(text, round) -> value`` raises ValueError (or pydantic's ValidationError) with a message the model
  reads in the next repair round. ``round`` is 0 on the first answer, so a validator can treat some findings as
  information the first time and accept them on a repair (review H1: "already true now").
* Tool rounds: while the model calls tools (and ``max_tool_rounds`` allows), each call runs through
  ``run_tool(name, args) -> result`` and the results go back; then it must answer. Once the tool rounds are used
  up, the request is made without tools.
* Raises ``DecisionError`` when no valid answer came back, ``BudgetStop`` when ``before_request`` refused.
"""
from __future__ import annotations

import json
from typing import Any, Callable

from pydantic import ValidationError

from .llm import LLMClient, LLMResponse, assistant_message, tool_result_message


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
                  on_response: Callable[[LLMResponse, list[dict]], None] | None = None) -> tuple[Any, dict]:
    """Returns (value, info) with info = {requests, tool_calls: [{name, args}], repairs, messages}."""
    msgs = list(messages)
    info: dict[str, Any] = {"requests": 0, "tool_calls": [], "repairs": 0}
    tool_rounds = 0
    repairs = 0
    while True:
        if before_request is not None and not before_request():
            info["messages"] = msgs
            raise BudgetStop("out of budget")
        offer = tools if tools and run_tool is not None and tool_rounds < max_tool_rounds else None
        resp = llm.complete(msgs, offer) if offer else llm.complete(msgs)
        info["requests"] += 1
        if on_response is not None:
            on_response(resp, msgs)
        if offer and resp.tool_calls:
            tool_rounds += 1
            msgs = msgs + [assistant_message(resp)]
            for call in resp.tool_calls:
                info["tool_calls"].append({"name": call.name, "args": call.arguments})
                try:
                    result = run_tool(call.name, call.arguments or {})
                except Exception as exc:  # a research tool failing is information, not a crash
                    result = {"ok": False, "error": repr(exc)[:300]}
                msgs.append(tool_result_message(call, result))
            continue
        text = resp.content or ""
        try:
            value = validate(text, repairs)
        except (ValueError, ValidationError) as exc:
            if repairs >= max_repairs:
                info["messages"] = msgs
                raise DecisionError(f"no valid decision after {repairs} repair(s): {str(exc)[:500]}") from exc
            repairs += 1
            info["repairs"] = repairs
            msgs = msgs + [{"role": "assistant", "content": text},
                           {"role": "user", "content": f"That answer was not usable: {exc}\n"
                                                       f"Return the corrected JSON object only."}]
            continue
        info["messages"] = msgs + [{"role": "assistant", "content": text}]
        return value, info


def as_json(value: Any) -> str:
    return json.dumps(value, default=str, ensure_ascii=False)

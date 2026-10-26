"""Thin provider-agnostic LLM adapter.

Real calls go through LiteLLM (https://docs.litellm.ai/), which speaks the
OpenAI chat/tool-calling format to Anthropic, xAI, OpenAI and others. The
provider is chosen purely by the model string, e.g. ``anthropic/<model>`` or
``xai/<model>``; LiteLLM reads the matching API key env var itself
(ANTHROPIC_API_KEY, XAI_API_KEY, ...).

Model names come from env vars:
  DW_CONTROLLER_MODEL  fast, cheap model for the Controller
  DW_PLANNER_MODEL     stronger model for the Planner

Tests use ``FakeLLM`` and never touch the network.
"""
from __future__ import annotations

import json
import time
import re
import os
from dataclasses import dataclass, field
from typing import Any, Callable, Protocol

CONTROLLER_MODEL_ENV = "DW_CONTROLLER_MODEL"
PLANNER_MODEL_ENV = "DW_PLANNER_MODEL"


@dataclass
class ToolCall:
    name: str
    arguments: dict[str, Any] = field(default_factory=dict)
    id: str | None = None


@dataclass
class LLMResponse:
    content: str | None = None
    tool_calls: list[ToolCall] = field(default_factory=list)
    # The assistant message exactly as the provider returned it, for multi-turn tool loops. With
    # Anthropic thinking on (default on Haiku 5.5 / Sonnet 5.5) the next request must carry this
    # message's ``thinking_blocks`` unchanged, or it is rejected (LiteLLM "reasoning content" docs).
    message: dict | None = None
    usage: dict | None = None


class LLMClient(Protocol):
    model: str

    def complete(self, messages: list[dict], tools: list[dict] | None = None) -> LLMResponse: ...


# Protocol markers a model or a proxy can put into the text ("[System: Empty message content
# sanitised to satisfy protocol]", live 21:24:15, BUGS.md L18): never speech.
_MARKER = re.compile(r"\[System:[^\]]*\]")


def strip_markers(text: str | None) -> str | None:
    """The text without protocol/system markers; None when nothing real is left."""
    if not text:
        return text
    out = _MARKER.sub("", text).strip()
    return out or None


def assistant_message(resp: LLMResponse) -> dict:
    """The assistant turn to append before tool results (OpenAI format, as LiteLLM expects)."""
    if resp.message:
        return resp.message
    msg: dict[str, Any] = {"role": "assistant", "content": resp.content or (None if resp.tool_calls else "")}
    if resp.tool_calls:
        for i, c in enumerate(resp.tool_calls):
            c.id = c.id or f"call_{i}_{c.name}"
        msg["tool_calls"] = [{"id": c.id, "type": "function",
                              "function": {"name": c.name, "arguments": json.dumps(c.arguments)}}
                             for c in resp.tool_calls]
    return msg


def tool_result_message(call: ToolCall, result: Any) -> dict:
    content = result if isinstance(result, str) else json.dumps(result, default=str, ensure_ascii=False)
    return {"role": "tool", "tool_call_id": call.id or f"call_0_{call.name}", "name": call.name, "content": content}


def with_cache_control(messages: list[dict]) -> list[dict]:
    """Mark the (stable) system prompt as a cache breakpoint. Tools render before system, so the
    cached prefix is tools + persona; volatile context lives in later messages. Haiku 5.5 and
    Sonnet 5.5 cache prefixes from 512 tokens; shorter ones are silently not cached."""
    out = []
    for m in messages:
        if m.get("role") == "system" and isinstance(m.get("content"), str) and not out:
            m = {**m, "content": [{"type": "text", "text": m["content"], "cache_control": {"type": "ephemeral"}}]}
        out.append(m)
    return out


def _usage(resp: Any) -> dict | None:
    u = getattr(resp, "usage", None)
    if u is None:
        return None
    details = getattr(u, "prompt_tokens_details", None)
    return {"prompt": getattr(u, "prompt_tokens", None), "completion": getattr(u, "completion_tokens", None),
            "cached": getattr(details, "cached_tokens", None) if details else None,
            "cache_write": getattr(u, "cache_creation_input_tokens", None)}


class LiteLLMClient:
    """Real model client. Importing litellm is deferred so tests stay fast and offline."""

    # No temperature/top_p/top_k: the Claude API rejects sampling params on every model since
    # 2026-10-21. max_tokens must leave room for the model's (default-on) thinking plus tool args.
    def __init__(self, model: str, max_tokens: int = 8192, **kwargs: Any):
        self.model = model
        self.kwargs = {"max_tokens": max_tokens, **kwargs}

    @property
    def effort(self) -> str | None:
        """The effort actually sent (output_config.effort), for the logs (BUGS.md L27 #2)."""
        return ((self.kwargs.get("output_config") or {}).get("effort")) if isinstance(self.kwargs, dict) else None

    def warm(self, messages: list[dict], tools: list[dict] | None = None) -> dict:
        """L27: pay the cold start before the first chat line, not in it. Imports litellm (~5 s here),
        opens the TLS connection and writes the prompt cache for the real prefix (tools + system), with a
        tiny reply. Returns {s, usage}; raises like complete()."""
        t0 = time.monotonic()
        saved = self.kwargs
        self.kwargs = {**saved, "max_tokens": 64}
        try:
            resp = self.complete(messages, tools)
        finally:
            self.kwargs = saved
        return {"s": round(time.monotonic() - t0, 2), "usage": resp.usage}

    def complete(self, messages: list[dict], tools: list[dict] | None = None) -> LLMResponse:
        import litellm

        params = dict(self.kwargs)
        if tools:
            # Several tool calls per response are allowed (PRINCIPLES 4b: the model composes primitives, e.g.
            # go_to then drop): the agent runs them IN ORDER, each verified, stopping at the first failure.
            # (They were disabled because the model paired follow with stop; the persona now forbids that.)
            params.update(tools=tools, tool_choice="auto")
        if self.model.startswith("anthropic/"):
            messages = with_cache_control(messages)
        resp = litellm.completion(model=self.model, messages=messages, **params)
        msg = resp.choices[0].message
        calls = []
        raw_calls = []
        for tc in msg.tool_calls or []:
            try:
                args = json.loads(tc.function.arguments or "{}")
            except json.JSONDecodeError:
                args = {"_raw": tc.function.arguments}
            calls.append(ToolCall(tc.function.name, args, tc.id))
            raw_calls.append({"id": tc.id, "type": "function",
                              "function": {"name": tc.function.name, "arguments": tc.function.arguments or "{}"}})
        text = strip_markers(msg.content)
        # L18: an empty text beside tool calls is replayed as None, never "", which LiteLLM would replace
        # with a "[System: Empty message content sanitised ...]" placeholder the model then imitates
        replay: dict[str, Any] = {"role": "assistant", "content": text or (None if msg.tool_calls else "")}
        if raw_calls:
            replay["tool_calls"] = raw_calls
        thinking = getattr(msg, "thinking_blocks", None)
        if thinking:
            replay["thinking_blocks"] = [dict(b) if not isinstance(b, dict) else b for b in thinking]
        return LLMResponse(content=text, tool_calls=calls, message=replay, usage=_usage(resp))


def _model_from_env(var: str) -> str:
    model = os.environ.get(var)
    if not model:
        raise RuntimeError(f"Set {var} to a LiteLLM model string, e.g. 'anthropic/<model-id>'.")
    return model


def missing_keys(model: str) -> list[str]:
    """API-key env vars the model's provider needs but are unset (asks LiteLLM; slow first import)."""
    import litellm

    info = litellm.validate_environment(model=model)
    return [] if info.get("keys_in_environment") else list(info.get("missing_keys") or [])


def controller_llm() -> LiteLLMClient:
    return LiteLLMClient(_model_from_env(CONTROLLER_MODEL_ENV), max_tokens=4096)


def planner_llm() -> LiteLLMClient:
    return LiteLLMClient(_model_from_env(PLANNER_MODEL_ENV), max_tokens=16000)


# --------------------------------------------------------------------------- fake

Responder = Callable[[list[dict], list[dict] | None], LLMResponse]


class FakeLLM:
    """Deterministic scripted LLM for tests.

    ``script`` items are consumed in order; each is an LLMResponse, a plain
    string (content), or a callable ``(messages, tools) -> LLMResponse``.
    Every call is recorded in ``self.calls`` for assertions.
    """

    def __init__(self, script: list[LLMResponse | str | Responder] | None = None, model: str = "fake/scripted"):
        self.model = model
        self.script = list(script or [])
        self.calls: list[dict] = []

    def push(self, *items: LLMResponse | str | Responder) -> None:
        self.script.extend(items)

    def complete(self, messages: list[dict], tools: list[dict] | None = None) -> LLMResponse:
        self.calls.append({"messages": messages, "tools": tools})
        if not self.script:
            raise AssertionError("FakeLLM script exhausted")
        item = self.script.pop(0)
        if callable(item):
            return item(messages, tools)
        if isinstance(item, str):
            return LLMResponse(content=item)
        return item

    # Convenience constructors.
    @staticmethod
    def say(text: str, *calls: ToolCall) -> LLMResponse:
        return LLMResponse(content=text, tool_calls=list(calls))

    @staticmethod
    def call(name: str, **arguments: Any) -> ToolCall:
        return ToolCall(name, arguments)

    @staticmethod
    def plan(tasks: list[dict], **extra: Any) -> LLMResponse:
        return LLMResponse(content=json.dumps({**extra, "tasks": tasks}))

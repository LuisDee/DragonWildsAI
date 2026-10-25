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


class LLMClient(Protocol):
    model: str

    def complete(self, messages: list[dict], tools: list[dict] | None = None) -> LLMResponse: ...


class LiteLLMClient:
    """Real model client. Importing litellm is deferred so tests stay fast and offline."""

    # No temperature/top_p/top_k: the Claude API rejects sampling params on every model since
    # 2026-10-21. max_tokens must leave room for the model's (default-on) thinking plus tool args.
    def __init__(self, model: str, max_tokens: int = 8192, **kwargs: Any):
        self.model = model
        self.kwargs = {"max_tokens": max_tokens, **kwargs}

    def complete(self, messages: list[dict], tools: list[dict] | None = None) -> LLMResponse:
        import litellm

        params = dict(self.kwargs)
        if tools:
            params.update(tools=tools, tool_choice="auto")
        resp = litellm.completion(model=self.model, messages=messages, **params)
        msg = resp.choices[0].message
        calls = []
        for tc in msg.tool_calls or []:
            try:
                args = json.loads(tc.function.arguments or "{}")
            except json.JSONDecodeError:
                args = {"_raw": tc.function.arguments}
            calls.append(ToolCall(tc.function.name, args, tc.id))
        return LLMResponse(content=msg.content, tool_calls=calls)


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

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
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import dataclass, field
from typing import Any, Callable, Protocol

CONTROLLER_MODEL_ENV = "DW_CONTROLLER_MODEL"
PLANNER_MODEL_ENV = "DW_PLANNER_MODEL"

_REQUEST_TOOL_CHOICE: ContextVar[str | dict | None] = ContextVar("llm_request_tool_choice", default=None)


@contextmanager
def request_tool_choice(choice: str | dict | None):
    """Scope one synchronous request's serialization through unchanged forwarding wrappers."""
    # Python3.12 set/reset supports exceptions and isolated concurrent contexts; a wrapper
    # offloading to another thread would need explicit copy_context().run, not implicit inheritance.
    # https://docs.python.org/3.12/library/contextvars.html
    # https://peps.python.org/pep-0567/#offloading-execution-to-other-threads
    token = _REQUEST_TOOL_CHOICE.set(choice)
    try:
        yield
    finally:
        _REQUEST_TOOL_CHOICE.reset(token)


def _effective_tool_choice(choice):
    return choice if choice is not None else _REQUEST_TOOL_CHOICE.get()


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
    finish_reason: str | None = None


class LLMClient(Protocol):
    model: str

    def complete(self, messages: list[dict], tools: list[dict] | None = None,
                 effort: str | None = None, *, tool_choice: str | dict | None = None) -> LLMResponse:
        """Optional per-call effort/tool choice; None inherits request scope/client defaults."""
        ...


# Protocol markers a model or a proxy can put into the text ("[System: Empty message content
# sanitised to satisfy protocol]", live 21:24:15, BUGS.md L18): never speech.
_MARKER = re.compile(r"\[System:[^\]]*\]")


# A reply that is ONLY an all-caps placeholder ("EMPTY", "(EMPTY)", "NO TEXT", "<SILENT>"): the model took
# "reply with no text" literally (live 08:49, BUGS.md L31). A format check on the whole reply, not a phrase list.
_PLACEHOLDER = re.compile(r"[\[(<\"'`*_]*\s*[A-Z][A-Z _\-]{3,}\s*[\])>\"'`*_.]*")


def strip_markers(text: str | None) -> str | None:
    """The text without protocol/system markers; None when nothing real is left (incl. a bare placeholder)."""
    if not text:
        return text
    out = _MARKER.sub("", text).strip()
    if out and _PLACEHOLDER.fullmatch(out):
        return None
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


# Body diagnostics that stay in the logs and never reach a model (forensics 2026-10-31 §3.2: a stale 6 KB terrain
# blob in 78/110 prompts, ray samples, route traces, read-status gaps). Dropped at any depth of a result; the
# body's one-sentence reason/detail is kept untouched.
LOG_ONLY_KEYS = frozenset({"terrain", "navigation_observation", "barrier_samples", "route_feedback", "read_status",
                           "inventory_read_status", "route_trace", "ray_samples", "rays", "samples", "match_basis",
                           "actor_position"})


# Movement results (BODY 2026-10-31): the body's one trip sentence (data.trip; data.trips, one per explore leg; a
# failure's detail starts with it) says what the move did: start and end, metres, closest approach, falls, why. Beside
# it, the arrival check's numbers are the executor's inputs, not news, and a cause already in the detail is a repeat.
TRIP_NOISE_KEYS = frozenset({"arrive_tolerance", "vertical_tolerance_m", "vertical_distance_m", "dist_m", "trail"})
# tostring() of a Lua table or function (a go_to's "target": "table: 000001289324C2F0"): an address, no information
LUA_ADDRESS = re.compile(r"^(table|function|userdata): (0x)?[0-9A-Fa-f]+$")


def _noise(k: str, v: Any, d: dict, trip: bool) -> bool:
    if k in LOG_ONLY_KEYS or (isinstance(v, str) and LUA_ADDRESS.match(v)):
        return True
    if not trip:
        return False
    detail = d.get("detail")
    return k in TRIP_NOISE_KEYS or (k in ("trip", "why") and isinstance(v, str) and bool(v)
                                    and isinstance(detail, str) and v in detail)


def model_view(value: Any) -> Any:
    """``value`` without LOG_ONLY_KEYS, Lua addresses, and the numbers beside a trip sentence; floats to 2
    decimals ("vertical_distance_m": 0.046060739173195). Dicts and lists walked; everything else as is."""
    if isinstance(value, dict):
        trip = isinstance(value.get("trip"), str) or isinstance(value.get("trips"), list)
        return {k: model_view(v) for k, v in value.items() if not _noise(k, v, value, trip)}
    if isinstance(value, list):
        return [model_view(v) for v in value]
    if isinstance(value, float):
        return round(value, 2)
    return value


def tool_result_message(call: ToolCall, result: Any) -> dict:
    content = result if isinstance(result, str) else json.dumps(model_view(result), default=str, ensure_ascii=False)
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
    # Incremental caching (Anthropic prompt-caching docs: move a breakpoint to the end of the conversation each
    # turn): the tail user message is a second breakpoint, so the next call of the same request (a chain turn,
    # a read's follow-up) reads this whole prefix from cache instead of re-sending the context uncached
    # (M1 2026-10-26: every chain turn showed cached=13418 of 18-22k prompt tokens). 2 of the 4 allowed.
    last = out[-1] if len(out) > 1 else None
    if last and out[0].get("role") == "system" and last.get("role") == "user" and isinstance(last.get("content"), str) \
            and last["content"]:
        out[-1] = {**last, "content": [{"type": "text", "text": last["content"], "cache_control": {"type": "ephemeral"}}]}
    return out


def _usage(resp: Any) -> dict | None:
    u = getattr(resp, "usage", None)
    if u is None:
        return None
    details = getattr(u, "prompt_tokens_details", None)
    return {"prompt": getattr(u, "prompt_tokens", None), "completion": getattr(u, "completion_tokens", None),
            "cached": getattr(details, "cached_tokens", None) if details else None,
            "cache_write": getattr(u, "cache_creation_input_tokens", None)}


def _call_meta(resp: Any, latency_ms: int) -> dict:
    """This call's timing, identity and cost, merged into ``usage`` so every llm_response row carries them
    (telemetry item 7, docs/research/2026-11-01-telemetry.md). OTel GenAI analogues: latency_ms ~
    gen_ai.client.operation.duration (wall time the brain waited, incl. LiteLLM), response_id ~ gen_ai.response.id
    (LiteLLM's id; Anthropic's msg_ id is not passed through), request_id = the provider's request-id header
    (Anthropic req_..., what its support traces), cost_usd = LiteLLM's own price-map cost
    (_hidden_params["response_cost"], the same as litellm.completion_cost; https://docs.litellm.ai/docs/completion/token_usage)."""
    hidden = getattr(resp, "_hidden_params", None)
    hidden = hidden if isinstance(hidden, dict) else {}
    headers = hidden.get("additional_headers") or {}
    cost = hidden.get("response_cost")
    rid = getattr(resp, "id", None)
    return {"latency_ms": latency_ms, "response_id": rid if isinstance(rid, str) else None,
            "request_id": headers.get("request-id") or headers.get("llm_provider-request-id"),
            "cost_usd": round(cost, 7) if isinstance(cost, (int, float)) else None}


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

    def warm(self, messages: list[dict], tools: list[dict] | None = None, effort: str | None = None) -> dict:
        """L27: pay the cold start before the first chat line, not in it. Imports litellm (~5 s here),
        opens the TLS connection and writes the prompt cache for the real prefix (tools + system), with a
        tiny reply. Returns {s, usage}; raises like complete()."""
        t0 = time.monotonic()
        saved = self.kwargs
        self.kwargs = {**saved, "max_tokens": 64}
        try:
            resp = self.complete(messages, tools) if effort is None else self.complete(messages, tools, effort=effort)
        finally:
            self.kwargs = saved
        return {"s": round(time.monotonic() - t0, 2), "usage": resp.usage}

    def request_payload(self, messages: list[dict], tools: list[dict] | None = None,
                        effort: str | None = None, *, tool_choice: str | dict | None = None) -> dict:
        """LiteLLM input: explicit choice wins over request scope, then existing defaults."""
        params = dict(self.kwargs)
        if effort and self.model.startswith("anthropic/"):  # one call at another level (output_config.effort)
            params["output_config"] = {**(params.get("output_config") or {}), "effort": effort}
        if tools:
            # Several tool calls per response are allowed (PRINCIPLES 4b: the model composes primitives, e.g.
            # go_to then drop): the agent runs them IN ORDER, each verified, stopping at the first failure.
            # (They were disabled because the model paired follow with stop; the persona now forbids that.)
            params.update(tools=tools, tool_choice="auto")
        tool_choice = _effective_tool_choice(tool_choice)
        if tool_choice is not None:
            # Explicit per-request control, without changing shared settings or default callers.
            # https://docs.litellm.ai/docs/completion/input
            params["tool_choice"] = tool_choice
        if self.model.startswith("anthropic/"):
            messages = with_cache_control(messages)
        return {"model": self.model, "messages": messages, **params}

    def complete(self, messages: list[dict], tools: list[dict] | None = None,
                 effort: str | None = None, *, tool_choice: str | dict | None = None) -> LLMResponse:
        import litellm

        options = {"tool_choice": tool_choice} if tool_choice is not None else {}
        t0 = time.monotonic()
        resp = litellm.completion(**self.request_payload(messages, tools, effort, **options))
        latency_ms = round((time.monotonic() - t0) * 1000)
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
        # LiteLLM exposes provider termination as a choice finish_reason:
        # https://docs.litellm.ai/docs/completion/output
        # usage: token counts + this call's latency_ms, cost_usd, response_id, request_id (_call_meta)
        usage = {**(_usage(resp) or {}), **_call_meta(resp, latency_ms)}
        return LLMResponse(content=text, tool_calls=calls, message=replay, usage=usage,
                           finish_reason=getattr(resp.choices[0], "finish_reason", None))


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
    model = _model_from_env(CONTROLLER_MODEL_ENV)
    effort = os.environ.get("DW_CONTROLLER_EFFORT", "low").strip()
    extra = {"output_config": {"effort": effort}} if effort and model.startswith("anthropic/") else {}
    return LiteLLMClient(model, max_tokens=1024, **extra)


def planner_llm() -> LiteLLMClient:
    return LiteLLMClient(_model_from_env(PLANNER_MODEL_ENV), max_tokens=int(os.environ.get("DW_PLANNER_MAX_TOKENS", "16000")))


def request_log_fields(llm: LLMClient, messages: list[dict], tools: list[dict] | None = None,
                       effort: str | None = None, *, tool_choice: str | dict | None = None, since: int = 0) -> dict:
    """The request as logged: the messages as the caller built them (no cache blocks), the tools, and the
    effective settings (max_tokens, effort, tool_choice). ``since``: a later call of the same request logs
    only the messages added after the first ``since`` (the first call logged the rest, and the tools)."""
    tool_choice = _effective_tool_choice(tool_choice)
    options = {"tool_choice": tool_choice} if tool_choice is not None else {}
    request = (llm.request_payload(messages, tools, effort, **options) if isinstance(llm, LiteLLMClient) else
               {"model": llm.model, "messages": messages, "tools": tools, "effort": effort, **options})
    out = {"settings": {k: v for k, v in request.items() if k not in ("messages", "tools")}}
    if since and since <= len(messages):
        return {**out, "messages": messages[since:], "messages_from": since}
    return {**out, "messages": messages, "tools": request.get("tools")}


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

    def complete(self, messages: list[dict], tools: list[dict] | None = None,
                 effort: str | None = None, *, tool_choice: str | dict | None = None) -> LLMResponse:
        tool_choice = _effective_tool_choice(tool_choice)
        options = {"tool_choice": tool_choice} if tool_choice is not None else {}
        self.calls.append({"messages": messages, "tools": tools, "effort": effort, **options})
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

"""Offline request-boundary regressions; no model, game or live runner calls."""
import copy
import concurrent.futures as cf
import json
import sys
import threading
import types

import pytest

from brain import llm as L
from brain.dry_run_llm import DryRunController, DryRunPlanner
from brain.llm_json import BudgetStop, DecisionError, json_decision
from brain.mock.sim_session import Latency
from evals.bench.agents import BudgetExceeded, CountingLLM
from tools.director_cassettes import CapReached, Capped
from test_director import ListLog, decision, have, make, step, COPPER
from test_model_interface_contract import provider_response


TOOLS = [{"type": "function", "function": {"name": "read", "parameters": {
    "type": "object", "properties": {"key": {"type": "string"}}, "required": ["key"]}}}]
MESSAGES = [{"role": "system", "content": "Plan using read-only research."}, {"role": "user", "content": "work"}]


def response_calls(*keys):
    return provider_response(None, "tool_calls", [types.SimpleNamespace(id=f"read-{key}",
        function=types.SimpleNamespace(name="read", arguments=json.dumps({"key": key}))) for key in keys])


def provider(monkeypatch, responses, *, thread_ids=None):
    sent, script = [], iter(responses)
    def complete(**kwargs):
        if thread_ids is not None:
            thread_ids.append(threading.get_ident())
        sent.append(copy.deepcopy(kwargs))
        result = next(script)
        if isinstance(result, Exception):
            raise result
        return result
    monkeypatch.setitem(sys.modules, "litellm", types.SimpleNamespace(completion=complete))
    return sent


def test_actual_requests_count_batched_tool_rounds_disable_after_limit_and_log_exact_choice(monkeypatch):
    sent = provider(monkeypatch, [response_calls("a", "b"), response_calls("c"),
                                  provider_response("not JSON"), provider_response('{"ready":true}')])
    client = L.LiteLLMClient("anthropic/test", max_tokens=4096, output_config={"effort": "low"})
    settings, tools, messages = copy.deepcopy(client.kwargs), copy.deepcopy(TOOLS), copy.deepcopy(MESSAGES)
    events, traces, reads = [], [], []
    def trace(msgs, defs, **options):
        events.append("request")
        traces.append(L.request_log_fields(client, msgs, defs, **options))
    value, info = json_decision(client, messages, lambda text, _: json.loads(text), tools=tools,
        run_tool=lambda name, args: reads.append(args["key"]) or {"ok": True}, max_tool_rounds=2,
        before_request=lambda: events.append("admit") or True,
        on_request=trace, on_response=lambda resp: events.append(("response", resp.usage, resp.finish_reason)))
    assert value == {"ready": True} and reads == ["a", "b", "c"] and info["repairs"] == 1
    assert [s["tool_choice"] for s in sent] == ["auto", "auto", "none", "none"]
    assert all(s["tools"] == tools for s in sent)
    assert len([m for m in sent[2]["messages"] if m["role"] == "tool"]) == 3
    assert client.kwargs == settings and messages == MESSAGES and tools == TOOLS
    assert info["requests"] == 4 and len(traces) == 4
    assert events[::3] == ["admit"] * 4 and events[1::3] == ["request"] * 4
    assert all(e[0] == "response" and e[1]["completion"] == 30 for e in events[2::3])
    for trace, actual in zip(traces, sent):
        assert {**trace["settings"], "messages": trace["messages"], "tools": trace["tools"]} == actual


def test_provider_violation_after_none_is_refused_and_each_response_counted(monkeypatch):
    sent = provider(monkeypatch, [response_calls("allowed"), response_calls("late"), provider_response("{}")])
    reads, responses = [], []
    _, info = json_decision(L.LiteLLMClient("anthropic/test"), MESSAGES, lambda text, _: json.loads(text),
        tools=TOOLS, run_tool=lambda name, args: reads.append(args["key"]) or {"ok": True}, max_tool_rounds=1,
        on_response=lambda resp: responses.append(resp.usage))
    assert reads == ["allowed"] and info["requests"] == len(responses) == 3
    assert [s["tool_choice"] for s in sent] == ["auto", "none", "none"]
    refusal = next(m for m in sent[2]["messages"] if m.get("tool_call_id") == "read-late")
    assert "research is over" in refusal["content"] and info["tool_calls"][-1]["refused"] is True


def test_denied_exhausted_request_has_no_provider_or_request_log(monkeypatch):
    sent = provider(monkeypatch, [response_calls("one")])
    admissions, responses, requests = [], [], []
    def admit():
        admissions.append(1)
        return len(admissions) == 1
    with pytest.raises(BudgetStop):
        json_decision(L.LiteLLMClient("anthropic/test"), MESSAGES, lambda text, _: {}, tools=TOOLS,
            run_tool=lambda *args: {"ok": True}, max_tool_rounds=1, before_request=admit,
            on_request=lambda *args, **kw: requests.append(kw), on_response=responses.append)
    assert len(admissions) == 2 and len(sent) == len(responses) == len(requests) == 1
    assert sent[0]["tool_choice"] == "auto" and requests == [{}]


def test_denied_zero_round_request_never_enters_scope_or_provider(monkeypatch):
    sent = provider(monkeypatch, [])
    client = L.LiteLLMClient("anthropic/test")
    with pytest.raises(BudgetStop):
        json_decision(client, MESSAGES, lambda *a: {}, tools=TOOLS, run_tool=lambda *a: {}, max_tool_rounds=0,
            before_request=lambda: False, on_request=lambda *a: pytest.fail("denied request logged"))
    assert not sent and client.request_payload(MESSAGES, TOOLS)["tool_choice"] == "auto"


def test_no_research_and_normal_caller_defaults_are_unchanged(monkeypatch):
    sent = provider(monkeypatch, [provider_response("{}")])
    client = L.LiteLLMClient("anthropic/test", max_tokens=1024)
    before = copy.deepcopy(client.kwargs)
    assert client.request_payload(MESSAGES, TOOLS)["tool_choice"] == "auto"
    assert "tool_choice" not in client.request_payload(MESSAGES)
    assert client.request_payload(MESSAGES, TOOLS, tool_choice="none")["tool_choice"] == "none"
    json_decision(client, MESSAGES, lambda text, _: {}, on_request=lambda m, t: None)
    assert "tool_choice" not in sent[0] and client.kwargs == before


def test_advisory_response_does_not_spend_a_research_round():
    fake = L.FakeLLM(["{}", L.FakeLLM.say("", L.FakeLLM.call("read", key="one")),
                     L.FakeLLM.say("", L.FakeLLM.call("read", key="two")), "{}"])
    validations = []
    def validate(text, repairs):
        validations.append(text)
        return ({}, ["need another fact"]) if len(validations) == 1 else {}
    _, info = json_decision(fake, MESSAGES, validate, tools=TOOLS, run_tool=lambda *args: {}, max_tool_rounds=2)
    assert info["requests"] == 4
    assert [call.get("tool_choice") for call in fake.calls] == [None, None, None, "none"]


def test_zero_research_rounds_requests_none_and_violating_fake_never_executes():
    fake = L.FakeLLM([L.FakeLLM.say("", L.FakeLLM.call("read", key="late"))])
    responses = []
    with pytest.raises(DecisionError):
        json_decision(fake, MESSAGES, lambda *args: {}, tools=TOOLS,
            run_tool=lambda *args: pytest.fail("late read executed"), max_tool_rounds=0, max_repairs=0,
            on_response=responses.append)
    assert fake.calls[0]["tool_choice"] == "none" and len(responses) == 1


@pytest.mark.parametrize("kind", ["latency", "counting", "capped"])
def test_real_forwarding_wrappers_keep_none_and_existing_caps(monkeypatch, kind):
    threads = []
    sent = provider(monkeypatch, [response_calls("one"), provider_response("{}")], thread_ids=threads)
    inner = L.LiteLLMClient("anthropic/test", max_tokens=4096, output_config={"effort": "low"})
    clock = types.SimpleNamespace(t=0)
    record = []
    if kind == "latency":
        wrapped = Latency(inner, clock, 2)
    elif kind == "counting":
        wrapped = CountingLLM(inner, "sonnet", 2)
    else:
        wrapped = Capped(inner, 2, record)
    traces, trace_threads, responses, admissions = [], [], [], []
    def trace(msgs, defs):
        trace_threads.append(threading.get_ident())
        traces.append(L.request_log_fields(wrapped, msgs, defs))
    _, info = json_decision(wrapped, MESSAGES, lambda text, _: json.loads(text), tools=TOOLS,
        run_tool=lambda *args: {}, max_tool_rounds=1, on_request=trace, on_response=responses.append,
        before_request=lambda: admissions.append(True) or True)
    assert [s["tool_choice"] for s in sent] == ["auto", "none"]
    assert threads == trace_threads == [threading.get_ident()] * 2
    assert info["requests"] == len(responses) == len(admissions) == 2
    assert "tool_choice" not in traces[0]["settings"] and traces[1]["settings"]["tool_choice"] == "none"
    assert all(trace["request_boundary"] == "llm.complete" for trace in traces)
    assert all(s["max_tokens"] == 4096 and s["output_config"] == {"effort": "low"} for s in sent)
    if kind == "latency":
        assert wrapped.n == 2 and clock.t == 4
    else:
        with pytest.raises(BudgetExceeded if kind == "counting" else CapReached):
            wrapped.complete(MESSAGES, TOOLS)
        assert len(sent) == 2
        if kind == "counting":
            assert wrapped.calls == 2 and len(wrapped.usage) == 2 and wrapped.exceeded
        else:
            assert wrapped.n == len(record) == 2


@pytest.mark.parametrize("client_type", [DryRunController, DryRunPlanner])
def test_unchanged_dry_clients_work_without_new_keywords(client_type):
    client = client_type()
    client.complete(MESSAGES, TOOLS)
    with L.request_tool_choice("none"):
        client.complete(MESSAGES, TOOLS)
    assert client.calls[0] == client.calls[1] == {"messages": MESSAGES, "tools": TOOLS}


@pytest.mark.parametrize("where", ["provider", "request_log", "response_log"])
def test_exhausted_scope_resets_when_provider_or_request_log_raises(monkeypatch, where):
    sent = provider(monkeypatch, [RuntimeError("fake provider failure") if where == "provider" else provider_response("{}")])
    client = L.LiteLLMClient("anthropic/test")
    observed = []
    def trace(msgs, defs):
        observed.append(L.request_log_fields(client, msgs, defs)["settings"]["tool_choice"])
        if where == "request_log":
            raise RuntimeError("fake request log failure")
    def response_log(resp):
        assert client.request_payload(MESSAGES, TOOLS)["tool_choice"] == "auto"
        if where == "response_log":
            raise RuntimeError("fake response log failure")
    with pytest.raises(RuntimeError):
        json_decision(client, MESSAGES, lambda *a: {}, tools=TOOLS, run_tool=lambda *a: {},
                      max_tool_rounds=0, on_request=trace, on_response=response_log)
    assert observed == ["none"] and len(sent) == (0 if where == "request_log" else 1)
    assert client.request_payload(MESSAGES, TOOLS)["tool_choice"] == "auto"
    assert L.request_log_fields(client, MESSAGES, TOOLS)["settings"]["tool_choice"] == "auto"


def test_nested_scope_and_explicit_override_restore_original_settings():
    client = L.LiteLLMClient("anthropic/test", max_tokens=1024)
    original = copy.deepcopy(client.kwargs)
    with L.request_tool_choice("none"):
        assert client.request_payload(MESSAGES, TOOLS)["tool_choice"] == "none"
        assert client.request_payload(MESSAGES, TOOLS, tool_choice="auto")["tool_choice"] == "auto"
        assert client.request_payload(MESSAGES, TOOLS, tool_choice=None)["tool_choice"] == "none"
        with pytest.raises(RuntimeError):
            with L.request_tool_choice("auto"):
                assert client.request_payload(MESSAGES, TOOLS)["tool_choice"] == "auto"
                raise RuntimeError("nested failure")
        assert client.request_payload(MESSAGES, TOOLS)["tool_choice"] == "none"
    assert client.request_payload(MESSAGES, TOOLS)["tool_choice"] == "auto" and client.kwargs == original


def test_two_concurrent_threads_isolate_exhausted_and_ordinary_requests(monkeypatch):
    barrier = threading.Barrier(2)
    sent = []
    def complete(**kwargs):
        sent.append((threading.get_ident(), kwargs["tool_choice"]))
        barrier.wait(timeout=5)
        return provider_response("{}")
    monkeypatch.setitem(sys.modules, "litellm", types.SimpleNamespace(completion=complete))
    client = L.LiteLLMClient("anthropic/test")
    traces = []
    def exhausted():
        json_decision(client, MESSAGES, lambda *a: {}, tools=TOOLS, run_tool=lambda *a: {}, max_tool_rounds=0,
            on_request=lambda m, t: traces.append(L.request_log_fields(client, m, t)))
        return client.request_payload(MESSAGES, TOOLS)["tool_choice"]
    with cf.ThreadPoolExecutor(max_workers=2) as pool:
        pending = pool.submit(exhausted)
        ordinary = pool.submit(client.complete, MESSAGES, TOOLS)
        assert pending.result(timeout=5) == "auto"
        ordinary.result(timeout=5)
    assert len({ident for ident, _ in sent}) == 2 and sorted(choice for _, choice in sent) == ["auto", "none"]
    assert traces[0]["settings"]["tool_choice"] == "none"


def test_director_actual_exhausted_prompt_log_matches_adapter_input(tmp_path, monkeypatch):
    valid = decision(task_success=have(COPPER, 1), steps=[step("work", have(COPPER, 1))])
    sent = provider(monkeypatch, [response_calls("a"), response_calls("b"), provider_response(valid)])
    d, _, world, _, _ = make(tmp_path)
    d.llm = L.LiteLLMClient("anthropic/test", max_tokens=4096)
    d.log = ListLog()
    task = d.ops.add_task("work", by="cli")
    result = d._decide(d._snapshot(task, {"kind": "plan"}, world.state))
    assert not result.error
    prompts = [row for row in d.log.rows if row["kind"] == "prompt"]
    responses = [row for row in d.log.rows if row["kind"] == "llm_response"]
    assert len(prompts) == len(responses) == result.requests == 3
    assert [r["settings"]["tool_choice"] for r in prompts] == ["auto", "auto", "none"]
    for prompt, actual in zip(prompts, sent):
        assert {**prompt["settings"], "messages": prompt["messages"], "tools": prompt["tools"]} == actual

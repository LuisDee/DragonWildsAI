"""Offline model-boundary diagnostics; no game or paid provider calls."""
import copy
import json
import sys
import threading
import time
import types

import pytest

from brain import director as D
from brain import llm as L
from brain.llm_json import BudgetStop, DecisionError, json_decision
from brain.run_live import make_llms
from test_director import COPPER, TIN, ListLog, decision, have, make, step


def provider_response(content="{}", finish_reason="stop", tool_calls=None):
    msg = types.SimpleNamespace(content=content, tool_calls=tool_calls)
    usage = types.SimpleNamespace(prompt_tokens=120, completion_tokens=30)
    return types.SimpleNamespace(choices=[types.SimpleNamespace(message=msg, finish_reason=finish_reason)], usage=usage)


def test_live_factories_share_limits_effort_and_configurable_planner_trial(monkeypatch):
    monkeypatch.setenv(L.CONTROLLER_MODEL_ENV, "anthropic/controller-test")
    monkeypatch.setenv(L.PLANNER_MODEL_ENV, "anthropic/director-test")
    monkeypatch.delenv("DW_CONTROLLER_EFFORT", raising=False)
    monkeypatch.delenv("DW_PLANNER_MAX_TOKENS", raising=False)
    controller, planner = make_llms(False)
    assert controller.kwargs == L.controller_llm().kwargs == {"max_tokens": 1024, "output_config": {"effort": "low"}}
    assert planner.kwargs == L.planner_llm().kwargs == {"max_tokens": 4096}
    monkeypatch.setenv("DW_CONTROLLER_EFFORT", "")
    monkeypatch.setenv("DW_PLANNER_MAX_TOKENS", "3072")
    controller, planner = make_llms(False)
    assert controller.kwargs == {"max_tokens": 1024} and planner.kwargs == {"max_tokens": 3072}
    monkeypatch.setenv(L.CONTROLLER_MODEL_ENV, "other/controller-test")
    monkeypatch.setenv("DW_CONTROLLER_EFFORT", "medium")
    assert L.controller_llm().kwargs == {"max_tokens": 1024}


def test_serialized_trace_matches_adapter_input_and_preserves_finish_usage(monkeypatch):
    sent = []
    monkeypatch.setitem(sys.modules, "litellm", types.SimpleNamespace(
        completion=lambda **kw: sent.append(copy.deepcopy(kw)) or provider_response(finish_reason="length")))
    client = L.LiteLLMClient("anthropic/test", max_tokens=4096, output_config={"effort": "low"}, timeout=60)
    messages = [{"role": "system", "content": "persona"}, {"role": "user", "content": "state"}]
    tools = [{"type": "function", "function": {"name": "read", "parameters": {"type": "object"}}}]
    before = copy.deepcopy(messages)
    trace = L.request_log_fields(client, messages, tools, "medium")
    response = client.complete(messages, tools, effort="medium")
    assert {**trace["settings"], "messages": trace["messages"], "tools": trace["tools"]} == sent[0]
    assert trace["request_boundary"] == "litellm.completion"
    assert trace["settings"]["tool_choice"] == "auto"
    assert trace["settings"]["output_config"] == {"effort": "medium"}
    assert trace["messages"][0]["content"][0]["cache_control"] == {"type": "ephemeral"}
    assert response.finish_reason == "length" and response.usage["completion"] == 30
    assert messages == before and client.effort == "low"


def test_director_prompt_log_equals_the_litellm_input_after_cache_transformation(tmp_path, monkeypatch):
    sent = []
    valid = decision(task_success=have(COPPER, 1), steps=[step("work", have(TIN, 1))])
    monkeypatch.setitem(sys.modules, "litellm", types.SimpleNamespace(
        completion=lambda **kw: sent.append(copy.deepcopy(kw)) or provider_response(valid)))
    d, _, world, _, _ = make(tmp_path)
    d.llm = L.LiteLLMClient("anthropic/director-test", max_tokens=4096)
    d.log = ListLog()
    task = d.ops.add_task("work", by="cli")
    result = d._decide(d._snapshot(task, {"kind": "plan"}, world.state))
    prompt = next(row for row in d.log.rows if row["kind"] == "prompt")
    assert not result.error
    assert {**prompt["settings"], "messages": prompt["messages"], "tools": prompt["tools"]} == sent[0]
    response = next(row for row in d.log.rows if row["kind"] == "llm_response")
    assert response["finish_reason"] == "stop" and response["usage"]["completion"] == 30


@pytest.mark.parametrize("reason", ["length", "max_tokens", "model_context_window_exceeded"])
@pytest.mark.parametrize("content,calls", [("{\"looks_valid\": true}", []),
    ("{\"partial\":", [L.ToolCall("look", {"_raw": "{\"radius\":"})])])
def test_truncation_is_accounted_before_validation_or_tools_and_never_retried(reason, content, calls):
    events = []
    llm = L.FakeLLM([L.LLMResponse(content=content, tool_calls=calls, finish_reason=reason,
                                  usage={"completion": 2048})])
    with pytest.raises(DecisionError, match=f"truncated.*{reason}"):
        json_decision(llm, [], lambda *a: events.append("validate"), tools=[{"type": "function"}],
                      run_tool=lambda *a: events.append("tool"), max_repairs=5,
                      before_request=lambda: events.append("gate") or True,
                      on_request=lambda *a: events.append("request"),
                      on_response=lambda r: events.append((r.finish_reason, r.usage)))
    assert events == ["gate", "request", (reason, {"completion": 2048})]
    assert len(llm.calls) == 1


def research(proxy, **manifest_changes):
    # Shape and bounds published by manifest.lua:104 and lodestone.lua:375.
    manifest = {"look": {"kind": "read", "moves": False, "description": "Read nearby things.", "args": {
        "type": "object", "properties": {"radius": {"type": "number", "minimum": 1, "maximum": 80},
        "max": {"type": "integer", "minimum": 1, "maximum": 40}, "about": {"type": "string"}}}},
        "lodestones": {"kind": "read", "moves": False, "args": {"type": "object", "properties": {}}}}
    manifest.update(manifest_changes)
    return D.Research({"facts": {}, "state": {}}, proxy=proxy, body_tools=set(manifest), manifest=manifest)


def test_research_advertises_manifest_reads_and_replays_truthful_errors_and_observations():
    reads = []
    observation = {"ok": True, "data": {"source": "client.look", "observed_at": 123, "things": []}}
    proxy = D.BodyProxy(lambda n, a: reads.append((n, a)) or observation)
    proxy.serve()
    r = research(proxy)
    schemas = {t["function"]["name"]: t["function"]["parameters"] for t in r.tools()}
    assert schemas["look"] == r.manifest["look"]["args"] and "lodestones" in schemas
    llm = L.FakeLLM([L.LLMResponse(tool_calls=[L.ToolCall("unavailable"), L.ToolCall("look", {"radius": 81}),
                      L.ToolCall("look", {"radius": 20}), L.ToolCall("lodestones")]), '{"ok":true}'])
    requests, gates = [], []
    value, _ = json_decision(llm, [], lambda t, _: json.loads(t), tools=r.tools(), run_tool=r.run,
                            before_request=lambda: gates.append(1) or True,
                            on_request=lambda m, t: requests.append(copy.deepcopy(m)))
    results = [json.loads(m["content"]) for m in requests[1] if m["role"] == "tool"]
    assert value == {"ok": True} and len(gates) == len(llm.calls) == 2
    assert "no research tool" in results[0]["error"]
    assert "invalid research arguments" in results[1]["error"]
    assert results[2:] == [observation, observation]
    assert reads == [("look", {"radius": 20}), ("lodestones", {})]


@pytest.mark.parametrize("change", [{"kind": "action", "moves": False, "args": {}},
                                   {"kind": "read", "moves": True, "args": {}},
                                   {"kind": "read", "moves": False}])
def test_unverified_manifest_entry_is_not_callable(change):
    r = research(D.BodyProxy(lambda *a: pytest.fail("must not call body")), look=change)
    assert "look" not in {t["function"]["name"] for t in r.tools()}
    assert r.run("look", {})["ok"] is False


def test_worker_without_owner_cannot_call_bridge_and_expired_queue_does_not_run():
    calls = []
    proxy = D.BodyProxy(lambda *a: calls.append(threading.get_ident()), timeout_s=0.01)
    with D.cf.ThreadPoolExecutor(max_workers=1) as pool:
        result = pool.submit(proxy.request, "look", {}).result(timeout=1)
    assert result["reason"] == D.Reason.BUSY and not calls
    proxy.serve()
    assert not calls and proxy.q.empty()


def test_deadline_prevents_late_claim_even_before_waiter_records_cancellation():
    proxy = D.BodyProxy(lambda *a: pytest.fail("expired queued read ran"), timeout_s=0)
    proxy.request("look", {})
    tool, args, box = proxy.q.get_nowait()
    box["cancelled"] = False  # waiter delayed between Event.wait timeout and acquiring the lock
    box["deadline"] = time.monotonic() - 1
    proxy.q.put((tool, args, box))
    proxy.serve()
    assert proxy.q.empty() and "started" not in box


def test_worker_live_read_is_served_only_on_established_owner():
    calls, queued = [], threading.Event()
    proxy = D.BodyProxy(lambda *a: calls.append(threading.get_ident()) or {"ok": True}, timeout_s=1)
    proxy.serve()
    put = proxy.q.put
    proxy.q.put = lambda entry: (put(entry), queued.set())
    with D.cf.ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(proxy.request, "look", {})
        assert queued.wait(1)
        proxy.serve()
        assert future.result(timeout=1) == {"ok": True}
    assert calls == [threading.get_ident()]


def test_semantic_repair_is_logged_in_actual_next_request_and_each_call_is_gated(tmp_path):
    invalid = decision(steps=[step("work", have(TIN, 1))], ask_help="conflicting decision")
    valid = decision(task_success=have(COPPER, 1), steps=[step("work", have(TIN, 1))])
    d, _, world, llm, _ = make(tmp_path, script=[invalid, valid])
    d.log = ListLog()
    checks = []
    d.budget = types.SimpleNamespace(allows=lambda component: checks.append(component) or True)
    task = d.ops.add_task("work", by="cli")
    result = d._decide(d._snapshot(task, {"kind": "plan"}, world.state))
    prompts = [row for row in d.log.rows if row["kind"] == "prompt"]
    assert not result.error and len(checks) == result.requests == len(prompts) == 2
    assert [p["messages"] for p in prompts] == [c["messages"] for c in llm.calls]
    assert "not usable" in prompts[1]["messages"][-1]["content"]
    assert task.status != "done"  # model output cannot apply completion from the worker


def test_budget_refusal_prevents_retry_and_request_trace():
    llm = L.FakeLLM(["invalid", "{}"])
    traces, gates = [], []
    def gate():
        gates.append(1)
        return len(gates) == 1
    with pytest.raises(BudgetStop):
        json_decision(llm, [], lambda t, _: json.loads(t), before_request=gate,
                      on_request=lambda *a: traces.append(a))
    assert len(gates) == 2 and len(llm.calls) == len(traces) == 1


def test_controller_trace_keeps_full_next_messages_tools_and_finish_reason(rig):
    rig.controller_llm.push(L.LLMResponse(tool_calls=[L.ToolCall("look", {"about": "tree"})],
                                        finish_reason="tool_calls", usage={"completion": 15}),
                            L.LLMResponse(content="Seen.", finish_reason="stop", usage={"completion": 5}))
    rig.controller.decide("Luis", "look around", rig.game.get_state()["data"], None)
    prompts = [row for row in rig.log.read_all() if row["kind"] == "prompt"]
    responses = [row for row in rig.log.read_all() if row["kind"] == "llm_response"]
    assert len(prompts) == len(responses) == 2
    assert [p["messages"] for p in prompts] == [c["messages"] for c in rig.controller_llm.calls]
    assert [p["tools"] for p in prompts] == [c["tools"] for c in rig.controller_llm.calls]
    assert any(m["role"] == "tool" for m in prompts[1]["messages"])
    assert [r["finish_reason"] for r in responses] == ["tool_calls", "stop"]


def test_controller_failed_primitive_is_in_full_next_request_and_serialized_trace(rig, monkeypatch):
    from brain.controller import Decision
    sent = []
    monkeypatch.setitem(sys.modules, "litellm", types.SimpleNamespace(
        completion=lambda **kw: sent.append(copy.deepcopy(kw)) or provider_response("I cannot reach that route.")))
    rig.controller.llm = L.LiteLLMClient("anthropic/controller-test", max_tokens=1024, output_config={"effort": "low"})
    previous = L.LLMResponse(tool_calls=[L.ToolCall("go_to", {"target": [1, 2, 3]}, "failed-action")])
    d = Decision(messages=[{"role": "system", "content": "persona"}, L.assistant_message(previous)], effort="medium")
    failure = {"ok": False, "reason": "path_blocked", "data": {"source": "client.move", "observed_at": 123,
               "observed_position": [0, 0, 0], "unknown": ["unloaded_floor"]}}
    rig.controller.next_turn(d, {"failed-action": failure}, state={}, failed=True)
    prompt = next(row for row in rig.log.read_all() if row["kind"] == "prompt")
    assert {**prompt["settings"], "messages": prompt["messages"], "tools": prompt["tools"]} == sent[0]
    result = next(m for m in prompt["messages"] if m.get("tool_call_id") == "failed-action")
    assert json.loads(result["content"]) == failure
    assert prompt["settings"]["output_config"]["effort"] == "medium"


@pytest.mark.parametrize("path", ["loop", "final_pass"])
def test_controller_logs_and_counts_paid_response_before_continuation_rejection(rig, path):
    from brain.controller import ContinuationInvalidated, Decision
    response = L.LLMResponse(tool_calls=[L.ToolCall("go_to", {"target": [1, 2, 3]})],
                             usage={"completion": 27}, finish_reason="tool_calls")
    rig.controller_llm.push(response)
    d = Decision()
    def invalidate():
        rows = [r for r in rig.log.read_all() if r["kind"] == "llm_response"]
        assert d.model_calls == len(rows) == 1
        assert rows[0]["usage"] == {"completion": 27} and rows[0]["finish_reason"] == "tool_calls"
        raise ContinuationInvalidated("task ended while the model was responding")
    rig.controller.continuation_validate = invalidate
    with pytest.raises(ContinuationInvalidated):
        if path == "loop":
            rig.controller._loop([], d)
        else:
            pending = L.LLMResponse(tool_calls=[L.ToolCall("look", {}, "unrun-read")])
            rig.controller._final_pass([], pending, pending.tool_calls, d, "budget")
    assert len(rig.controller_llm.calls) == d.model_calls == 1
    assert rig.game.calls == [] and d.actions == []
    assert len([r for r in rig.log.read_all() if r["kind"] == "llm_response"]) == 1

"""Offline Director-worker accounting; no real model, bridge or game calls."""
import concurrent.futures as cf
import copy
import json
import sys
import threading
import types

import pytest

from brain.board import Step
from brain.jsonl_log import JsonlLogger
from brain.llm import FakeLLM, LiteLLMClient, LLMResponse
from brain.llm_json import BudgetStop
from brain.skill_library import SkillLibrary
from brain.state_store import SkillRegistry
from test_director import make
from test_skill_library_split import DELIVER, NEAR, done_tasks
from tools import spend


USAGES = [{"prompt": 5387, "completion": 220, "cached": 0, "cache_write": 5383},
          {"prompt": 5710, "completion": 391, "cached": 5383, "cache_write": 323}]


def response(valid, usage):
    proposal = copy.deepcopy(DELIVER)
    if not valid:
        proposal["example_params"]["resource"] = "stone"  # well-formed, semantically unfaithful
    return LLMResponse(content=json.dumps(proposal), usage=usage, finish_reason="stop")


@pytest.fixture
def worker(tmp_path):
    pool = cf.ThreadPoolExecutor(max_workers=1)
    d, _, world, llm, _ = make(tmp_path, executor=pool)
    d.log = JsonlLogger(tmp_path / "logs" / "brain-worker.jsonl")
    d.skills = SkillLibrary(tmp_path / "skills", log=d.log)
    d.skills_registry = SkillRegistry()
    llm.model = "anthropic/claude-sonnet-5-5"
    world.state.update(copy.deepcopy(NEAR))
    task = d.ops.add_task("bring logs", by="cli")
    step = Step(title="bring logs", success={"have": {"item": "log", "at_least": 1}},
                actions=[{"tool": t.skill, "args": t.args, "ok": True} for t in done_tasks()])
    yield d, world.state, task, step, llm
    pool.shutdown(wait=True, cancel_futures=True)


def learner_rows(d, kind):
    return [r for r in d.log.read_all() if r["kind"] == kind and r.get("component") == "skill_learner"]


def priced_rows(d):
    return spend.calls(d.log.path.parent, 0, float("inf"), spend.load_prices(), files=[d.log.path])


def test_actual_director_worker_logs_both_paid_responses_and_spend_exactly_once(worker):
    d, state, task, step, llm = worker
    llm.push(response(False, USAGES[0]), response(True, USAGES[1]))
    checks = []
    d.budget = types.SimpleNamespace(allows=lambda kind: checks.append((kind, threading.get_ident())) or True)
    before_window = d.window.left()
    d._maybe_learn(task, step, state)
    assert d._learn_future.result(timeout=3) is not None
    assert d.skills.names() == []  # worker cannot accept/write the skill
    d._collect_learning()
    assert d.skills.names() == ["deliver_resource"]
    assert len(checks) == 3  # initial scheduling check + two proposal-loop admission checks
    assert checks[0] == ("director", threading.get_ident())
    assert all(kind == "director" and thread != threading.get_ident() for kind, thread in checks[1:])
    assert d.window.left() == before_window - 1  # existing hourly job semantics preserved
    prompts, responses = learner_rows(d, "prompt"), learner_rows(d, "llm_response")
    assert len(prompts) == len(responses) == len(llm.calls) == 2
    assert [p["messages"] for p in prompts] == [c["messages"] for c in llm.calls]
    assert all(p["request_boundary"] == "llm.complete" for p in prompts)
    assert all(p["tools"] is None and p["settings"]["model"] == llm.model for p in prompts)
    invalid = next(r for r in d.log.read_all() if r["kind"] == "skill_invalid")
    assert prompts[1]["messages"][-1]["content"] == f"Invalid: {invalid['error']}\nReturn corrected JSON only."
    assert [r["round"] for r in responses] == [0, 1]
    assert [r["usage"] for r in responses] == USAGES
    assert all(r["model"] == llm.model and r["finish_reason"] == "stop" and r["tool_calls"] == [] for r in responses)
    rows = priced_rows(d)
    assert len(rows) == 2 and all(r["source"] == "generators" for r in rows)
    assert sum(r["usd"] for r in rows) == pytest.approx(0.0209293)
    d._collect_learning()  # collection/acceptance must not account for the same responses again
    assert len(priced_rows(d)) == 2


@pytest.mark.parametrize("admitted", [0, 1])
def test_worker_denied_request_never_calls_provider_and_keeps_already_paid_usage(worker, admitted):
    d, state, task, step, llm = worker
    llm.push(response(False, USAGES[0]), response(True, USAGES[1]))
    checks = []
    def allows(kind):
        checks.append(kind)
        if len(checks) == admitted + 2:  # scheduling first, then admitted calls, then refusal
            assert len(learner_rows(d, "llm_response")) == admitted
            return False
        return True
    d.budget = types.SimpleNamespace(allows=allows)
    d._maybe_learn(task, step, state)
    with pytest.raises(BudgetStop, match="skill learning daily budget"):
        d._learn_future.result(timeout=3)
    d._collect_learning()
    assert len(checks) == admitted + 2
    assert len(llm.calls) == len(learner_rows(d, "prompt")) == admitted
    responses = learner_rows(d, "llm_response")
    assert len(responses) == len(priced_rows(d)) == admitted
    if admitted:
        assert responses[0]["usage"] == USAGES[0] and responses[0]["finish_reason"] == "stop"
    errors = [r for r in d.log.read_all() if r["kind"] == "skill_learn_error"]
    assert len(errors) == 1 and "BudgetStop" in errors[0]["error"]
    assert d.skills.names() == []


def test_invalid_exhaustion_preserves_each_response_without_acceptance(worker):
    d, state, task, step, llm = worker
    llm.push(response(False, USAGES[0]), response(False, USAGES[1]))
    d._maybe_learn(task, step, state)
    assert d._learn_future.result(timeout=3) is None
    d._collect_learning()
    assert len(learner_rows(d, "llm_response")) == len(priced_rows(d)) == 2
    assert d.skills.names() == []


def test_standalone_proposal_logs_exact_litellm_input_and_keeps_optional_admission_default(tmp_path, monkeypatch):
    sent = []
    def complete(**request):
        sent.append(copy.deepcopy(request))
        return types.SimpleNamespace(choices=[types.SimpleNamespace(finish_reason="stop",
            message=types.SimpleNamespace(content=json.dumps(DELIVER), tool_calls=None))],
            usage=types.SimpleNamespace(prompt_tokens=10, completion_tokens=5))
    monkeypatch.setitem(sys.modules, "litellm", types.SimpleNamespace(completion=complete))
    logger = JsonlLogger(tmp_path / "brain-standalone.jsonl")
    lib = SkillLibrary(tmp_path / "skills", log=logger)
    llm = LiteLLMClient("anthropic/claude-sonnet-5-5", max_tokens=4096)
    assert lib.propose("bring logs", done_tasks(), NEAR, llm, SkillRegistry()) is not None
    prompt = next(r for r in logger.read_all() if r["kind"] == "prompt")
    assert {**prompt["settings"], "messages": prompt["messages"]} == sent[0]
    assert prompt["tools"] is None and prompt["request_boundary"] == "litellm.completion"
    response_row = next(r for r in logger.read_all() if r["kind"] == "llm_response")
    assert response_row["usage"] == {"prompt": 10, "completion": 5, "cached": None, "cache_write": None}
    assert response_row["finish_reason"] == "stop" and response_row["model"] == llm.model

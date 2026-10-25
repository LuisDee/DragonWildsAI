"""Eval harness checks that make no API calls: case files load, scoring works, the runner refuses."""
import importlib.util
from pathlib import Path

from brain.llm import FakeLLM

spec = importlib.util.spec_from_file_location("run_evals", Path(__file__).parents[1] / "evals" / "run_evals.py")
run_evals = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run_evals)


def test_case_files_are_small_and_valid():
    ctl = run_evals.load_cases("controller_cases.jsonl")
    pl = run_evals.load_cases("planner_cases.jsonl")
    assert 10 <= len(ctl) <= 15 and 10 <= len(pl) <= 15
    assert all({"id", "utterance", "expected"} <= c.keys() for c in ctl)
    assert all("goal" in c and ("success" in c or c.get("expect_ask_help")) for c in pl)


def test_runner_refuses_without_yes_or_model(monkeypatch, capsys):
    monkeypatch.delenv("DW_CONTROLLER_MODEL", raising=False)
    monkeypatch.delenv("DW_PLANNER_MODEL", raising=False)
    assert run_evals.main(["--suite", "controller"]) == 2
    assert "planned calls: 13" in capsys.readouterr().out


def test_runner_refuses_without_api_key(monkeypatch, capsys):
    monkeypatch.setenv("DW_PLANNER_MODEL", "anthropic/some-model")
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    assert run_evals.main(["--suite", "planner", "--yes"]) == 2
    assert "API key" in capsys.readouterr().out


def test_scoring_with_fake_models(tmp_path):
    ctl_case = {"id": "x", "utterance": "follow me", "expected": [{"tool": "follow", "args": {"player": "luis"}}]}
    good = FakeLLM([FakeLLM.say("ok", FakeLLM.call("follow", player="Luis"))])
    assert run_evals.eval_controller_case(ctl_case, good, tmp_path)["passed"]
    bad = FakeLLM([FakeLLM.say("ok", FakeLLM.call("stop"))])
    assert not run_evals.eval_controller_case(ctl_case, bad, tmp_path)["passed"]

    pl_case = {"id": "p", "goal": "bring Luis 3 logs", "success": {"luis_inventory": {"log": 3}}}
    gather = {"skill": "gather", "args": {"resource": "log", "count": 3}}
    give = {"skill": "give", "args": {"player": "Luis", "item": "log", "count": 3}}
    ok_plan = FakeLLM([FakeLLM.plan([gather, {"skill": "go_to", "args": {"target": "Luis"}}, give])])
    assert run_evals.eval_planner_case(pl_case, ok_plan, tmp_path)["passed"]
    # skipping go_to violates give's precondition (reach), which simulation catches
    no_walk = FakeLLM([FakeLLM.plan([gather, give])])
    res = run_evals.eval_planner_case({**pl_case, "id": "p2"}, no_walk, tmp_path)
    assert not res["passed"] and "too_far" in res["error"]

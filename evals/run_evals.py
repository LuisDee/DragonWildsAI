"""Offline evals for the Controller and Planner against a real model.

THIS SPENDS API MONEY. It prints the planned call count and model, then refuses
to run unless you pass --yes and the provider's API key env var is set.

    python evals/run_evals.py --suite controller --yes
    python evals/run_evals.py --suite planner --limit 3 --yes

Models come from DW_CONTROLLER_MODEL / DW_PLANNER_MODEL (LiteLLM model strings).
Results are appended to logs/evals-<timestamp>.jsonl.
"""
from __future__ import annotations

import argparse
import math
import os
import re
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from brain import paths  # noqa: E402
from brain.controller import Controller  # noqa: E402
from brain.executor import Executor  # noqa: E402
from brain.interface import BODY_TOOLS  # noqa: E402
from brain.jsonl_log import JsonlLogger, read_jsonl  # noqa: E402
from brain.llm import CONTROLLER_MODEL_ENV, PLANNER_MODEL_ENV, LLMClient, LiteLLMClient  # noqa: E402
from brain.mock import BLUEPRINTS, RECIPES, MockGame  # noqa: E402
from brain.planner import Planner, PlanError  # noqa: E402
from brain.state_store import StateStore  # noqa: E402

HERE = Path(__file__).resolve().parent


def load_cases(name: str) -> list[dict]:
    return read_jsonl(HERE / name)


def mock_notes() -> dict:
    notes = {f"recipe:{k}": f"{v['inputs']} -> {v['yield']} {k}" for k, v in RECIPES.items()}
    notes.update({f"blueprint:{k}": f"needs {v}" for k, v in BLUEPRINTS.items()})
    return notes


def _matches(expected: dict, got: dict) -> bool:
    norm = lambda v: v.lower() if isinstance(v, str) else v  # noqa: E731
    return all(norm(got.get(k)) == norm(v) for k, v in expected.items())


# ------------------------------------------------------------------ controller


def eval_controller_case(case: dict, llm: LLMClient, workdir: Path) -> dict:
    """One command through the Controller's bounded loop (<= 3 calls; look/inspect run on the mock).
    Grounding refusals count as "no action": the case passes only if nothing reached the body."""
    game = _setup_world(case)
    store = StateStore(workdir / case["id"])
    tools = set(BODY_TOOLS) - {"look", "inspect", "interact"} if case.get("no_look") else None
    ctl = Controller(llm, game, store, JsonlLogger(workdir / "controller.jsonl"), available_tools=tools)
    state = {**game.get_state()["data"], **case.get("state_patch", {})}
    d = ctl.decide("Luis", case["utterance"], state, case.get("active_goal"))
    got = [{"tool": a.name, "args": a.arguments} for a in d.actions]
    if d.goal:
        got.append({"tool": "start_goal", "args": {"goal": d.goal}})
    exp = case["expected"]
    passed = len(got) == len(exp) and all(
        g["tool"] == e["tool"] and _matches(e["args"], g["args"]) for g, e in zip(got, exp)
    )
    for k, v in (case.get("expect_args_contain") or {}).items():
        passed = passed and bool(got) and str(v).lower() in str(got[0]["args"].get(k, "")).lower()
    if case.get("expect_speech"):
        passed = passed and bool(re.search(case["expect_speech"], d.speech or "", re.I) or d.refusals)
    return {"id": case["id"], "passed": passed, "got": got, "speech": d.speech, "expected": exp,
            "model_calls": d.model_calls, "refusals": d.refusals}


# ------------------------------------------------------------------ planner


def _setup_world(case: dict) -> MockGame:
    game = MockGame.default_world()
    for step in case.get("setup", []):
        if step == "remove_stone_near_camp":
            game.remove_nodes("stone", within=30)
        elif step == "wolf_near_camp":
            game.add_entity("wolf", [8, 3, 0], hp=30, hostile=True, damage=8)
        elif step == "oak_logs_on_ground":
            game.add_ground_item("oak_log", 2, [1, 0, 0])
        elif step == "sticks_nearby":
            game.add_ground_item("oak_log", 2, [1, 0, 0])
            game.add_gatherable("Ash Branch", "stick", [4, 2, 0], count=2)
        elif step.startswith("companion_has:"):
            _, item, n = step.split(":")
            game.inventory[item] += int(n)
    return game


def _success(game: MockGame, spec: dict) -> bool:
    if "luis_inventory" in spec and any(game.players["Luis"].inventory[k] < v
                                       for k, v in spec["luis_inventory"].items()):
        return False
    if "inventory" in spec and any(game.inventory[k] < v for k, v in spec["inventory"].items()):
        return False
    if "near_place" in spec and math.dist(game.pos, game.places[spec["near_place"]]) > 3:
        return False
    if "structure" in spec and not any(s["blueprint"] == spec["structure"] for s in game.structures):
        return False
    if "no_alive" in spec and any(e.alive and e.kind == spec["no_alive"] and math.dist(e.pos, game.pos) < 60
                                  for e in game.entities.values()):
        return False
    return True


def eval_planner_case(case: dict, llm: LLMClient, workdir: Path) -> dict:
    game = _setup_world(case)
    store = StateStore(workdir / case["id"])
    log = JsonlLogger(workdir / "planner.jsonl")
    planner = Planner(llm, store.skills, log)
    try:
        plan = planner.plan(case["goal"], game.get_state()["data"], mock_notes())
    except PlanError as exc:
        return {"id": case["id"], "passed": False, "error": str(exc)}
    tasks = [{"skill": t.skill, "args": t.args} for t in plan.tasks]
    if case.get("expect_ask_help"):
        return {"id": case["id"], "passed": bool(plan.ask_help) and not tasks, "tasks": tasks,
                "ask_help": plan.ask_help}
    if not tasks or len(tasks) > case.get("max_tasks", 12):
        return {"id": case["id"], "passed": False, "tasks": tasks, "error": "bad task count"}
    # Preconditions and order are checked by actually executing the plan on the mock.
    ex = Executor(game, store, log, max_attempts=1)
    for t in plan.tasks:
        out = ex.run_task(t)
        if not out.ok:
            return {"id": case["id"], "passed": False, "tasks": tasks, "error": f"{t.skill} failed: {out.reason}"}
    return {"id": case["id"], "passed": _success(game, case["success"]), "tasks": tasks}


# ------------------------------------------------------------------ knowledge (lookup)


class _CountingKnowledge:
    """The real index (data/ + data/wiki/), counting the model's lookups."""

    def __init__(self, inner):
        self.inner, self.queries = inner, []

    def kinds(self):
        return self.inner.kinds()

    def lookup(self, query, kind=None):
        self.queries.append({"query": query, "kind": kind})
        return self.inner.lookup(query, kind)


def eval_knowledge_case(case: dict, llm: LLMClient, workdir: Path) -> dict:
    """A game-fact question: passes when the MODEL chose to call lookup, took no action, and its reply
    states the fact (expect_speech regex). Held-out: no case text appears in the persona or tools."""
    from brain.knowledge import Knowledge
    know = _CountingKnowledge(Knowledge())
    game = _setup_world(case)
    ctl = Controller(llm, game, StateStore(workdir / case["id"]), JsonlLogger(workdir / "knowledge.jsonl"),
                     knowledge=know)
    d = ctl.decide("Luis", case["utterance"], game.get_state()["data"], None)
    said = d.speech or ""
    passed = bool(know.queries) and not d.actions and not d.goal and bool(re.search(case["expect_speech"], said, re.I | re.S))
    return {"id": case["id"], "passed": passed, "lookups": know.queries, "speech": said,
            "model_calls": d.model_calls, "actions": [a.name for a in d.actions]}


# ------------------------------------------------------------------ main

SUITES = {
    "controller": ("controller_cases.jsonl", CONTROLLER_MODEL_ENV, eval_controller_case, 3),  # bounded loop
    "planner": ("planner_cases.jsonl", PLANNER_MODEL_ENV, eval_planner_case, 2),  # 1 + one repair
    "knowledge": ("knowledge_cases.jsonl", CONTROLLER_MODEL_ENV, eval_knowledge_case, 3),  # lookup + answer
}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--suite", choices=[*SUITES, "all"], default="all")
    ap.add_argument("--limit", type=int, default=None, help="only the first N cases per suite")
    ap.add_argument("--yes", action="store_true", help="confirm you accept the API spend")
    args = ap.parse_args(argv)

    plan = []
    # "all" = the original suites; knowledge needs the local wiki mirror (data/wiki/), so it runs on request
    for name in [n for n in SUITES if n != "knowledge"] if args.suite == "all" else [args.suite]:
        file, env, fn, max_calls = SUITES[name]
        cases = load_cases(file)[: args.limit]
        model = os.environ.get(env)
        plan.append((name, cases, model, fn, max_calls, env))
        print(f"[{name}] {len(cases)} cases, model={model or f'<unset {env}>'}, "
              f"planned calls: {len(cases)} (max {len(cases) * max_calls})")

    missing = [env for _, _, model, _, _, env in plan if not model]
    if missing:
        print(f"Refusing: set {', '.join(missing)}.")
        return 2
    import litellm

    for _, _, model, *_ in plan:
        env_check = litellm.validate_environment(model=model)
        if not env_check.get("keys_in_environment"):
            print(f"Refusing: API key for {model} not set (missing {env_check.get('missing_keys')}).")
            return 2
    if not args.yes:
        print("Refusing: pass --yes to confirm the API calls above.")
        return 2

    out = JsonlLogger(paths.log_dir() / f"evals-{time.strftime('%Y%m%d-%H%M%S')}.jsonl")
    with tempfile.TemporaryDirectory() as tmp:
        for name, cases, model, fn, _, _ in plan:
            llm = LiteLLMClient(model, max_tokens=1024 if name in ("controller", "knowledge") else 16000)
            results = [fn(c, llm, Path(tmp)) for c in cases]
            for r in results:
                out.log("eval_result", suite=name, model=model, **r)
                print(f"  {'PASS' if r['passed'] else 'FAIL'} {r['id']}")
            passed = sum(r["passed"] for r in results)
            print(f"[{name}] pass rate {passed}/{len(results)}")
    print(f"results: {out.path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

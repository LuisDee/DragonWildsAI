r"""Real-model checks for the Director (docs/design/director.md wave 5), with hard call caps.

    .venv\Scripts\python.exe -m tools.director_cassettes record [--jobs better_pickaxe,quest] [--yes]
    .venv\Scripts\python.exe -m tools.director_cassettes start_goal_eval [--yes]

record: for each job in brain/mock/gear_jobs.JOBS, the REAL Sonnet (DW_PLANNER_MODEL) makes the job's first
  decision on GearWorld (with the real knowledge index for lookup, and the client planner / catalog research tools);
  every response is saved as a cassette in tests/fixtures/director_cassettes/<job>.json, which
  tests/test_director_cassettes.py replays offline. The Controller is the scripted stand-in (no Haiku calls).
start_goal_eval: the REAL Haiku (DW_CONTROLLER_MODEL) decides a few chat lines with the board tools offered, once
  with start_goal also offered and once with it hidden (the question of design section 6); prints the choices.

Without --yes nothing is called: the plan and the call caps are printed. Every call is logged with model and
component in logs/evals-director-*.jsonl, so tools.spend prices it (source: evals). The caps are hard: the
wrapper refuses the call after the cap, whatever the loop wants.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
from pathlib import Path

from brain import paths
from brain.jsonl_log import JsonlLogger
from brain.llm import LiteLLMClient, LLMResponse

CASSETTES = paths.REPO_ROOT / "tests" / "fixtures" / "director_cassettes"
SONNET_CAP = 24
HAIKU_CAP = 15
EVAL_LINES = [
    "can you make yourself a better pickaxe",
    "get me a load of coal from the quarry and bring it back here",
    "chop 3 ash logs",
    "come over here",
    "what are you working on?",
]


class CapReached(RuntimeError):
    pass


class Capped:
    """An LLMClient that counts real requests against a hard cap and records every response."""

    def __init__(self, inner, cap: int, record: list):
        self.inner, self.cap, self.record = inner, cap, record
        self.model = inner.model
        self.n = 0

    def complete(self, messages, tools=None) -> LLMResponse:
        if self.n >= self.cap:
            raise CapReached(f"call cap {self.cap} reached")
        self.n += 1
        resp = self.inner.complete(messages, tools)
        self.record.append({"content": resp.content, "usage": resp.usage,
                            "tool_calls": [{"name": c.name, "arguments": c.arguments, "id": c.id}
                                           for c in resp.tool_calls]})
        return resp


def _model(var: str) -> str:
    m = os.environ.get(var)
    if not m:
        raise SystemExit(f"set {var} (e.g. anthropic/claude-sonnet-5-5)")
    return m


def record(jobs: list[str], yes: bool) -> int:
    from brain.knowledge import open_knowledge
    from brain.mock.gear_jobs import JOBS, JobRig
    model = _model("DW_PLANNER_MODEL")
    unknown = [j for j in jobs if j not in JOBS]
    if unknown:
        raise SystemExit(f"unknown jobs {unknown}; known: {sorted(JOBS)}")
    print(f"record {len(jobs)} job(s) with {model}: expected ~3 requests each, hard cap {SONNET_CAP} in total")
    if not yes:
        print("dry run: pass --yes to make the calls")
        return 0
    log = JsonlLogger(paths.log_dir() / f"evals-director-cassettes-{time.strftime('%Y%m%d-%H%M%S')}.jsonl")
    knowledge = open_knowledge(log)
    total = {"n": 0}
    CASSETTES.mkdir(parents=True, exist_ok=True)
    for job in jobs:
        chat, open_task, setup = JOBS[job]
        rec: list = []
        left = SONNET_CAP - total["n"]
        if left <= 0:
            print(f"{job}: skipped (cap reached)")
            continue
        llm = Capped(LiteLLMClient(model, max_tokens=16000, timeout=60), left, rec)
        with tempfile.TemporaryDirectory() as tmp:
            rig = JobRig(Path(tmp), [], open_tasks=open_task, knowledge=knowledge, director_llm=llm, director_log=log)
            setup(rig)
            rig.say(chat)
            for _ in range(3):
                rig.steps(1, dt=1.0)
                if rig.director.ops.b.awaiting_decision is None and rig.director._future is None \
                        and rig.director.ops.b.tasks and llm.n:
                    break
            rows = [r for r in log.read_all() if r.get("task") in {t.id for t in rig.director.ops.b.tasks}]
            task = rig.director.ops.b.tasks[0] if rig.director.ops.b.tasks else None
            out = {"job": job, "chat": chat, "open": open_task, "model": model,
                   "recorded_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "requests": llm.n,
                   "responses": rec,
                   "outcome": {"status": task.status if task else None,
                               "success": task.success["predicate"] if task and task.success else None,
                               "steps": [{"title": s.title, "success": s.success, "risk": s.risk, "hints": s.hints,
                                          "group": s.group} for s in task.steps] if task else [],
                               "help": task.help.question if task and task.help else None,
                               "gaps": [g["primitive"] for g in rig.director.gaps.rows()],
                               "events": [r for r in rows if r.get("kind") in
                                          ("director_decision", "director_decision_failed", "director_lookup")]}}
        total["n"] += llm.n
        (CASSETTES / f"{job}.json").write_text(json.dumps(out, indent=1, ensure_ascii=False, default=str),
                                               encoding="utf-8")
        print(f"{job}: {llm.n} request(s); {out['outcome']['status']}; steps="
              f"{[s['title'] for s in out['outcome']['steps']]}; help={out['outcome']['help']!r}")
    print(f"total Sonnet requests: {total['n']} (cap {SONNET_CAP}); log: {log.path}")
    return 0


def start_goal_eval(yes: bool) -> int:
    from brain.mock.gear_jobs import PLAYER, JobRig, pickaxe_world
    model = _model("DW_CONTROLLER_MODEL")
    print(f"start_goal eval with {model}: {len(EVAL_LINES)} lines x 2 conditions, hard cap {HAIKU_CAP} requests")
    if not yes:
        print("dry run: pass --yes to make the calls")
        return 0
    log = JsonlLogger(paths.log_dir() / f"evals-director-start-goal-{time.strftime('%Y%m%d-%H%M%S')}.jsonl")
    rec: list = []
    llm = Capped(LiteLLMClient(model, max_tokens=4096, timeout=60), HAIKU_CAP, rec)
    results = []
    for hide in (False, True):
        for line in EVAL_LINES:
            with tempfile.TemporaryDirectory() as tmp:
                rig = JobRig(Path(tmp), [], controller_llm=llm, hides_start_goal=hide)
                rig.controller.log = log
                pickaxe_world(rig)
                state = rig.game.get_state()["data"]
                try:
                    d = rig.controller.decide(PLAYER, line, state, None)
                except CapReached:
                    print("cap reached; stopping")
                    break
                chosen = [a.name for a in d.actions] + (["start_goal"] if d.goal else []) + \
                         (["run_skill"] if d.skill else [])
                results.append({"start_goal_offered": not hide, "line": line, "tools": chosen, "speech": d.speech})
                print(f"{'with' if not hide else 'without'} start_goal | {line!r} -> {chosen} {d.speech!r}")
    out = paths.log_dir() / "evals" / f"director_start_goal_{time.strftime('%Y%m%d-%H%M%S')}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"model": model, "requests": llm.n, "results": results}, indent=1), encoding="utf-8")
    print(f"Haiku requests: {llm.n} (cap {HAIKU_CAP}); results: {out}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="tools.director_cassettes")
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("record")
    r.add_argument("--jobs", default="")
    r.add_argument("--yes", action="store_true")
    e = sub.add_parser("start_goal_eval")
    e.add_argument("--yes", action="store_true")
    a = ap.parse_args(argv)
    if a.cmd == "record":
        from brain.mock.gear_jobs import JOBS
        return record([j for j in a.jobs.split(",") if j] or list(JOBS), a.yes)
    return start_goal_eval(a.yes)


if __name__ == "__main__":
    sys.exit(main())

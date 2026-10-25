"""Benchmark runner (design §2, §6, §9.1).

  .venv\\Scripts\\python.exe -m evals.bench plan     --cases evals/bench/cases            # what would run, call counts
  .venv\\Scripts\\python.exe -m evals.bench run      --cases ... --target mock [--agent companion|dry|fake]
  .venv\\Scripts\\python.exe -m evals.bench controls --cases ... --target mock             # validity LINT on the mock
  .venv\\Scripts\\python.exe -m evals.bench generate --t0                                  # T0 + spell-use cases from data
  .venv\\Scripts\\python.exe -m evals.bench report   <run_dir>

Targets: mock (BenchWorld; never counts for GOAL, review finding 3) and dev (the dev server through the client
bridge; needs bench_probe.lua + the dev referee; preflight guards in evals/bench/devtarget.py). Real-model runs check
the $10/day cap first (tools.obs spend) and print their worst-case call counts (design §10).

Each run writes logs/evals/<YYYYMMDD>/<run_id>/: run.json, cases.jsonl, report.json, report.md, traces/*.json, and
appends one row to logs/evals/scoreboard.jsonl (sha256 of run.json and cases.jsonl, so goal_check can re-derive).
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
import traceback
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from brain import predicates as P

from . import hashes, leaves  # noqa: F401  (registers the benchmark leaves)
from .agents import CONTROLS, NEGATIVE, BudgetExceeded, build_companion, control_steps, run_script
from .observer import NOT_ACTIONS, Abort, ObservedGame, evidence_ctx
from .spec import Case, calls_cap, case_hash, lint, load_cases
from .world import BenchWorld

ROOT = hashes.ROOT
EVALS = ROOT / "logs" / "evals"
SCOREBOARD = EVALS / "scoreboard.jsonl"
LINT_DIR = EVALS / "validity_lint"
MOCK_REFEREE = frozenset({"damage", "death", "item_change", "item_spawned", "craft"})
IDLE_TICK_S = 5.0
MAX_STEPS = 400


def iso(t: float | None = None) -> str:
    return datetime.fromtimestamp(t if t is not None else time.time(), timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


@dataclass
class CaseResult:
    case_id: str
    case_hash: str
    family: str
    tier: str
    agent: str
    target: str
    result: str
    reason: str | None
    detail: str
    progress: float = 0.0
    repeat_i: int = 0
    long_task: str | None = None
    basic: str | None = None
    skill: str | None = None
    mode: str | None = None
    capstone: str | None = None
    spell: str | None = None
    entry_hash: str = ""
    heldout: bool = False
    hints_used: int = 0
    calls: dict = field(default_factory=dict)
    usage: list = field(default_factory=list)
    latency_s: float | None = None
    sim_s: float | None = None
    wall_s: float | None = None
    failures: list = field(default_factory=list)
    mismatches: list = field(default_factory=list)
    missing: list = field(default_factory=list)
    process: dict = field(default_factory=dict)
    trace: str | None = None
    trace_sha256: str | None = None


# ------------------------------------------------------------------ the evidence view of the world


def probe_state(probe: dict | None) -> dict:
    """A get_state-shaped dict built ONLY from the harness probe (core leaves read this, never the companion's own
    get_state: review finding 1)."""
    p = probe or {}
    me = p.get("position") or [0.0, 0.0, 0.0]

    def dist(q):
        return round(math.dist(me, q or me), 1)
    return {"inventory": dict(p.get("inventory") or {}), "position": list(me), "health": p.get("health"),
            "players": [{"name": x.get("name"), "position": x.get("position"), "distance": dist(x.get("position"))}
                        for x in p.get("players") or []],
            "nearby_items": [{"id": g.get("id"), "item": g.get("item"), "count": g.get("count"), "position": g.get("position"),
                              "distance": dist(g.get("position"))} for g in p.get("ground") or []],
            "nearby_entities": [{"id": c.get("id"), "kind": c.get("kind"), "position": c.get("position"), "hp": c.get("hp"),
                                 "alive": c.get("alive"), "distance": dist(c.get("position"))} for c in p.get("creatures") or []],
            "skills": [{"skill": k, "level": (v or {}).get("level"), "xp": (v or {}).get("xp")}
                       for k, v in (p.get("skills") or {}).items()] if isinstance(p.get("skills"), dict) else p.get("skills"),
            "gear": p.get("gear"), "bag": p.get("bag"),
            # quests from the probe (QuestProgressComponent): EQuestState 2 = Complete
            "quests": [{"name": q.get("name") or q.get("asset"), "asset": q.get("asset"), "stage": q.get("objective"),
                        "completed": q.get("state") == 2} for q in p.get("quests") or []] if "quests" in p else None,
            "hydration": (p.get("vitals") or {}).get("hydration"), "sustenance": (p.get("vitals") or {}).get("sustenance")}


def judge(case: Case, game: ObservedGame, world, bindings: dict, spells: dict) -> tuple[str, str | None, P.Result, dict]:
    """(result, reason, success Result, ctx) from the observer's record: success AND every guard, mismatches first."""
    st0 = probe_state(game.rec.probe0)
    st1 = probe_state(game.rec.probe1 or game.rec.probe0)
    ctx = evidence_ctx(game.rec, st0, spells, now=float((game.rec.probe1 or {}).get("t", 0)), places=bindings.get("_places"),
                       referee_supports=set(MOCK_REFEREE))
    from .agents import bind
    succ = P.evaluate(P.validate(bind(case.success, bindings)), st1, ctx)
    guards = [P.evaluate(P.validate(bind(g, bindings)), st1, ctx) for g in case.guards]
    if ctx["mismatches"]:
        return "error", "sensor_mismatch", succ, ctx
    if any(g.passed is False for g in guards):
        return "fail", "guard", succ, ctx
    if succ.passed is None or any(g.passed is None for g in guards):
        return "unverifiable", "perception_gap", succ, ctx
    return ("pass", None, succ, ctx) if succ.passed else ("fail", "not_achieved", succ, ctx)


# ------------------------------------------------------------------ one case on the mock


def build_world(case: Case, world_factory=BenchWorld) -> tuple[BenchWorld, dict]:
    world = world_factory()
    bindings: dict[str, Any] = {}
    for step in case.fixtures.setup:
        s = dict(step)
        verb, name = s.pop("verb"), s.pop("as", None)
        out = world.setup(verb, **s)
        if name:
            bindings[name] = out
    bindings["_places"] = dict(world.places)
    return world, bindings


def requires_met(case: Case, world: BenchWorld) -> tuple[bool, list[str]]:
    st = probe_state(world.probe())
    unmet = []
    for r in case.fixtures.requires:
        res = P.evaluate(P.validate(r), st, {})
        if res.passed is not True:
            unmet.append(res.detail)
    return not unmet, unmet


def entry_hash(case: Case, spells: dict | None = None) -> str:
    """The case's own judge-data entry (its spell's spell_effects.json record): part of the validity key."""
    sid = (case.tags or {}).get("spell")
    if not sid:
        return ""
    import hashlib
    sp = (spells if spells is not None else leaves.default_spells()).get(sid)
    return hashlib.sha256(json.dumps(sp, sort_keys=True).encode()).hexdigest()[:16] if sp else ""


def new_result(case: Case, agent: str, target: str, repeat_i: int = 0) -> CaseResult:
    return CaseResult(case.id, case_hash(case), case.family, case.tier, agent, target, "skip", None, "", repeat_i=repeat_i,
                      long_task=case.long_task, basic=case.basic, skill=case.skill, mode=case.mode, capstone=case.capstone,
                      spell=(case.tags or {}).get("spell"),
                      entry_hash=entry_hash(case), heldout=case.heldout)


def run_case_mock(case: Case, agent: str, workdir: Path, controller_llm=None, planner_llm=None, repeat_i: int = 0,
                  world_factory=BenchWorld) -> CaseResult:
    """Play one case on BenchWorld with the companion (a given LLM: FakeLLM/dry-run/real) or a control."""
    world, bindings = build_world(case, world_factory)
    spells = world.spell_data
    base = new_result(case, agent, "mock", repeat_i)
    ok, unmet = requires_met(case, world)
    if not ok:
        base.reason, base.detail = "precondition", "; ".join(unmet)
        return base
    game = ObservedGame(world, world.probe, _drain(world), clock=lambda: world.time)
    workdir.mkdir(parents=True, exist_ok=True)
    w0 = time.time()
    game.start()
    hints_used, chat_wall, comp = 0, None, None
    try:
        if agent == "companion":
            comp = build_companion(game, workdir, controller_llm, planner_llm, calls_cap(case))
            sim_limit = float(case.limits.sim_s or case.limits.wall_s)
            pending = sorted(case.chat, key=lambda c: c.at_s)
            chat_wall = time.time()
            idle = 0.0
            for _ in range(MAX_STEPS):
                while pending and pending[0].at_s <= world.time - (game.rec.probe0 or {}).get("t", 0):
                    comp.hear(pending.pop(0).text)
                if comp.controller_llm.exceeded or comp.planner_llm.exceeded:
                    raise BudgetExceeded("model-call cap reached")
                n0 = len(game.rec.observations) + len(game.rec.said)
                comp.step()
                game._drain_referee()
                if comp.controller_llm.exceeded or comp.planner_llm.exceeded:
                    raise BudgetExceeded("model-call cap reached")
                if _passed_now(case, game, bindings, spells):
                    break
                if world.time - (game.rec.probe0 or {}).get("t", 0) >= sim_limit:
                    break
                if len(game.rec.observations) + len(game.rec.said) == n0 and not pending:
                    idle += IDLE_TICK_S
                    world.tick(IDLE_TICK_S)
                    if idle >= case.limits.idle_s:
                        if hints_used < min(case.limits.hints_max, len(case.hints.ladder)):
                            comp.hear(case.hints.ladder[hints_used])
                            hints_used += 1
                            if comp.controller_llm.exceeded or comp.planner_llm.exceeded:
                                raise BudgetExceeded("model-call cap reached")
                            idle = 0.0
                        else:
                            break
                else:
                    idle = 0.0
        else:
            steps = control_steps(case, agent)
            if steps is None:
                base.result, base.reason, base.detail = "skip", "control_na", (case.controls.na or {}).get(agent, "no script")
                return base
            run_script(steps, game, world, bindings)
    except BudgetExceeded as exc:
        game.finish()
        r = _finish(base, case, game, world, bindings, spells, workdir, comp, hints_used, chat_wall, w0)
        r.result, r.reason, r.detail = "error", "budget", str(exc)
        return r
    except Abort as exc:
        game.finish()
        r = _finish(base, case, game, world, bindings, spells, workdir, comp, hints_used, chat_wall, w0)
        r.result, r.reason, r.detail = "error", "aborted", str(exc)
        return r
    game.finish()
    return _finish(base, case, game, world, bindings, spells, workdir, comp, hints_used, chat_wall, w0)


def _drain(world):
    pos = {"i": 0}

    def take():
        new = world.referee[pos["i"]:]
        pos["i"] = len(world.referee)
        return list(new)
    return take


def _passed_now(case, game, bindings, spells) -> bool:
    game.rec.probe1 = game._probe()
    try:
        res, _, _, _ = judge(case, game, None, bindings, spells)
    finally:
        game.rec.probe1 = None
    return res == "pass"


def _finish(base: CaseResult, case: Case, game: ObservedGame, world, bindings, spells, workdir: Path, comp, hints_used,
            chat_wall, w0) -> CaseResult:
    result, reason, succ, ctx = judge(case, game, world, bindings, spells)
    r = base
    r.result, r.reason, r.detail, r.progress, r.missing = result, reason, succ.detail, succ.progress, list(succ.missing)
    r.mismatches = list(ctx["mismatches"])
    r.hints_used = hints_used
    r.sim_s = round(float((game.rec.probe1 or {}).get("t", 0)) - float((game.rec.probe0 or {}).get("t", 0)), 1)
    r.wall_s = round(time.time() - w0, 2)
    r.failures = [{"tool": o.tool, "reason": o.reply.get("reason"), "detail": ((o.reply.get("data") or {}).get("detail"))}
                  for o in game.rec.observations if not o.reply.get("ok")]
    acts = [o for o in game.rec.observations if o.tool not in NOT_ACTIONS]
    if chat_wall is not None and acts:
        r.latency_s = round(acts[0].wall0 - chat_wall, 3)
    if comp is not None:
        fam: dict[str, int] = {}
        for c in (comp.controller_llm, comp.planner_llm):
            fam[c.family] = fam.get(c.family, 0) + c.calls
        r.calls, r.usage = fam, comp.controller_llm.usage + comp.planner_llm.usage
    r.process = process_metrics(case, game)
    trace = {"case": case.id, "case_hash": r.case_hash, "agent": r.agent, "bindings": {k: v for k, v in bindings.items()},
             "observations": [o.to_dict() for o in game.rec.observations], "referee": game.rec.referee,
             "episodes": game.rec.episodes, "said": game.rec.said, "reads": game.rec.reads,
             "probe0": game.rec.probe0, "probe1": game.rec.probe1, "result": result, "reason": reason, "detail": succ.detail}
    tdir = workdir / "traces"
    tdir.mkdir(parents=True, exist_ok=True)
    tf = tdir / f"{case.id}__{r.agent}__{r.repeat_i}.json"
    tf.write_text(json.dumps(trace, default=str), encoding="utf-8")
    r.trace, r.trace_sha256 = str(tf), hashes.sha256_file(tf)
    return r


def process_metrics(case: Case, game: ObservedGame) -> dict:
    """Process metrics (design §4.3): read the trace's tool calls, never decide success."""
    out: dict[str, Any] = {}
    reads = game.rec.reads
    acts = [o for o in game.rec.observations if o.tool not in NOT_ACTIONS]
    if case.needs_fact is not None:
        kind = (case.needs_fact or {}).get("kind")
        first_act = acts[0].t0 if acts else float("inf")
        looked = any(x["tool"] == "lookup" and x["t"] <= first_act for x in reads)
        if kind in (None, "none"):
            out["needless_lookup"] = any(x["tool"] == "lookup" for x in reads)
        else:
            out["lookup_when_needed"] = looked
            truth = (case.needs_fact or {}).get("truth")
            if truth is not None:
                out["fact_correct"] = any(str(truth).lower() in json.dumps(o.args).lower() for o in acts)
    proj = [e for e in game.rec.referee if e.get("kind") == "projectile" and e.get("by") == "self"]
    if proj:
        out["shots"], out["hits"] = len(proj), sum(1 for e in proj if e.get("hit"))
    tele = [e for e in game.rec.referee if e.get("kind") in ("telegraph", "defended") and e.get("telegraphed")]
    if tele:
        out["telegraphs"] = sum(1 for e in tele if e.get("kind") == "telegraph")
        out["dodged"] = sum(1 for e in tele if e.get("kind") == "defended" and e.get("outcome") in ("dodged", "parried", "negated"))
    rate_item, base_rate = (case.tags or {}).get("rate_item"), (case.tags or {}).get("baseline_rate_per_min")
    if rate_item and base_rate and game.rec.probe0 and game.rec.probe1:
        gained = (game.rec.probe1.get("inventory") or {}).get(rate_item, 0) - (game.rec.probe0.get("inventory") or {}).get(rate_item, 0)
        mins = max(1e-6, (float(game.rec.probe1.get("t", 0)) - float(game.rec.probe0.get("t", 0))) / 60.0)
        out["efficiency_pct"] = round(100.0 * (gained / mins) / float(base_rate), 1)
    dmg_in = [e for e in game.rec.referee if e.get("kind") == "damage" and e.get("target") == "self"]
    if dmg_in:
        out["damage_taken"] = sum(float(e.get("amount", 0)) for e in dmg_in)
    return out


# ------------------------------------------------------------------ a run


def run_dir(target: str, tag: str = "") -> tuple[str, Path]:
    now = datetime.now(timezone.utc)
    rid = f"{now:%Y%m%d-%H%M%S}-{target}{('-' + tag) if tag else ''}"
    d = EVALS / f"{now:%Y%m%d}" / rid
    d.mkdir(parents=True, exist_ok=True)
    return rid, d


def manifest_ref(path: Path | None) -> dict | None:
    if path is None or not Path(path).exists():
        return None
    m = json.loads(Path(path).read_text(encoding="utf-8"))
    rel = Path(path).resolve()
    rel = rel.relative_to(ROOT) if rel.is_relative_to(ROOT) else rel
    return {"path": str(rel).replace("\\", "/"), "sha256": hashes.sha256_file(path), "version": m.get("version")}


def write_run(rid: str, d: Path, target: str, agent: str, results: list[CaseResult], cases: list[Case], full: bool,
              manifest: dict | None = None, scoreboard: Path | None = SCOREBOARD, extra: dict | None = None) -> dict:
    from .report import render_md, summarize
    run = {"schema": "dw_bench_run/1", "run_id": rid, "at": iso(), "target": target, "agent": agent, "full": full,
           "suite_manifest": manifest, "git_sha": hashes.head_sha(), "companion_hash": hashes.companion_hash(),
           "judge_hash": hashes.judge_hash(), "scorer_hash": hashes.scorer_hash(), "body_hash": hashes.body_hash(),
           "build": hashes.game_build(), "cases": len(results), **(extra or {})}
    (d / "run.json").write_text(json.dumps(run, indent=1), encoding="utf-8")
    with open(d / "cases.jsonl", "w", encoding="utf-8") as f:
        for r in results:
            f.write(json.dumps(asdict(r), default=str) + "\n")
    rep = summarize(run, results)
    (d / "report.json").write_text(json.dumps(rep, indent=1, default=str), encoding="utf-8")
    (d / "report.md").write_text(render_md(rep), encoding="utf-8")
    row = {"schema": "dw_scoreboard/1", "kind": "bench", "run_id": rid, "at": run["at"], "target": target, "agent": agent,
           "full": full, "dir": str(d.relative_to(ROOT)) if d.is_relative_to(ROOT) else str(d),
           "run_sha256": hashes.sha256_file(d / "run.json"), "cases_sha256": hashes.sha256_file(d / "cases.jsonl"),
           "companion_hash": run["companion_hash"], "judge_hash": run["judge_hash"], "build": run["build"],
           "counts": rep["counts"], "calls": rep["calls"]}
    if scoreboard is not None:
        scoreboard.parent.mkdir(parents=True, exist_ok=True)
        with open(scoreboard, "a", encoding="utf-8") as f:
            f.write(json.dumps(row) + "\n")
    return {"run": run, "report": rep, "row": row, "dir": str(d)}


def run_mock(cases: list[Case], agent: str = "companion", controller_llm=None, planner_llm=None, repeat: int = 1,
             scoreboard: Path | None = SCOREBOARD, tag: str = "", full: bool = False, log=print, llm: str = "fake",
             manifest_path: Path | None = None) -> dict:
    rid, d = run_dir("mock", tag)
    results = []
    for c in cases:
        for i in range(max(1, repeat if repeat else c.limits.repeat)):
            try:
                r = run_case_mock(c, agent, d / "work" / f"{c.id}__{i}", controller_llm, planner_llm, i)
            except Exception as exc:  # one broken case never stops the run
                r = new_result(c, agent, "mock", i)
                r.result, r.reason, r.detail = "error", "harness", f"{type(exc).__name__}: {exc}"
                r.failures = [{"traceback": traceback.format_exc()[-2000:]}]
            log(f"  [{c.id}#{i}] {r.result}{' (' + r.reason + ')' if r.reason else ''}: {r.detail}")
            results.append(r)
    return write_run(rid, d, "mock", agent, results, cases, full, manifest_ref(manifest_path), scoreboard=scoreboard,
                     extra={"llm": llm, "models": {"controller": getattr(controller_llm, "model", None),
                                                   "planner": getattr(planner_llm, "model", None)}})


def lint_controls(cases: list[Case], out_dir: Path = LINT_DIR, log=print) -> dict:
    """Validity LINT on the mock (review finding 3: never feeds goal_check). Oracle must pass, every negative fail."""
    out_dir.mkdir(parents=True, exist_ok=True)
    rid, d = run_dir("mock", "controls")
    summary = {}
    for c in cases:
        rec = {"case_id": c.id, "case_hash": case_hash(c), "target": "mock", "at": iso(), "controls": {}}
        for ctl in CONTROLS:
            try:
                r = run_case_mock(c, ctl, d / "work" / f"{c.id}__{ctl}")
                rec["controls"][ctl] = {"result": r.result, "reason": r.reason, "detail": r.detail, "trace_sha256": r.trace_sha256}
            except Exception as exc:
                rec["controls"][ctl] = {"result": "error", "reason": "harness", "detail": repr(exc)}
        cs = rec["controls"]
        neg = {k: v["result"] for k, v in cs.items() if k in NEGATIVE and v["result"] != "skip"}
        rec["valid_lint"] = cs.get("oracle", {}).get("result") == "pass" and all(v == "fail" for v in neg.values())
        rec["problems"] = ([] if cs.get("oracle", {}).get("result") == "pass" else [f"oracle {cs.get('oracle', {}).get('result')}: {cs.get('oracle', {}).get('detail')}"]) + \
                          [f"{k} {v} (must fail)" for k, v in neg.items() if v != "fail"]
        (out_dir / f"{rec['case_hash']}.json").write_text(json.dumps(rec, indent=1), encoding="utf-8")
        summary[c.id] = rec
        log(f"  [{c.id}] {'LINT OK' if rec['valid_lint'] else 'LINT FAIL'} {'; '.join(rec['problems'])}")
    return summary


# ------------------------------------------------------------------ budget preflight (design §10)


def worst_case_usd(calls: dict[str, int], models: dict[str, str], prompt_tokens: int = 20000, max_tokens: int = 2048) -> float | None:
    """The most a batch can cost: every call at the full prompt, all uncached, at the dearest tier."""
    try:
        from tools import spend
        prices = spend.load_prices()
    except Exception:
        return None
    total = 0.0
    for fam, n in calls.items():
        model = models.get(fam)
        if not model or not n:
            continue
        usd, _ = spend.price(model, {"prompt": prompt_tokens, "completion": max_tokens, "cached": 0, "cache_write": prompt_tokens}, prices)
        if usd is None:
            return None
        total += usd * n
    return total


def spend_preflight(calls: dict[str, int], models: dict[str, str]) -> tuple[bool, str]:
    """Refuse (fail closed) when the spend can't be read, the cap is hit, or this batch could cross it."""
    import subprocess
    try:
        p = subprocess.run([sys.executable, "-m", "tools.obs", "spend", "--json"], cwd=ROOT, capture_output=True,
                           text=True, timeout=180, encoding="utf-8", errors="replace")
        s = json.loads(p.stdout)
    except Exception as exc:
        return False, f"cannot read today's spend (tools.obs spend): {exc!r}"
    if s.get("state") == "cap":
        return False, f"daily cap reached: ${s.get('spent_usd')} of ${s.get('cap_usd')}"
    worst = worst_case_usd(calls, models)
    if worst is None:
        return False, "cannot price the planned calls (data/model_prices.json)"
    cap, spent = float(s.get("cap_usd") or 10), float(s.get("spent_usd") or 0)
    if spent + worst > cap:
        return False, f"spent ${spent:.2f} + worst case ${worst:.2f} > cap ${cap:.2f}"
    return True, f"spent ${spent:.2f} + worst case ${worst:.2f} <= cap ${cap:.2f}"


def plan_calls(cases: list[Case], repeat: int = 1) -> dict[str, int]:
    tot: dict[str, int] = {}
    for c in cases:
        for k, v in calls_cap(c).items():
            tot[k] = tot.get(k, 0) + v * max(1, repeat or c.limits.repeat)
    return tot


# ------------------------------------------------------------------ CLI


def _llms(kind: str):
    if kind == "fake":
        return None, None
    if kind == "dry":
        from brain.dry_run_llm import DryRunController, DryRunPlanner
        return DryRunController(), DryRunPlanner()
    if kind == "real":
        from brain.run_live import make_llms
        return make_llms(False)
    raise SystemExit(f"unknown --llm {kind}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python -m evals.bench", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("plan", "run", "controls", "lint"):
        s = sub.add_parser(name)
        s.add_argument("--cases", default=str(ROOT / "evals" / "bench" / "cases"))
        s.add_argument("--only", help="comma list of case ids (marks the run partial)")
        s.add_argument("--target", default="mock", choices=("mock", "dev"))
        s.add_argument("--llm", default="dry", choices=("fake", "dry", "real"))
        s.add_argument("--repeat", type=int, default=0)
        s.add_argument("--yes", action="store_true", help="real-model runs: confirm the printed call plan")
        s.add_argument("--no-scoreboard", action="store_true")
    g = sub.add_parser("generate")
    g.add_argument("--t0", action="store_true", help="T0 spell + station cases and T1 spell-use cases from data")
    g.add_argument("--out", default=str(ROOT / "evals" / "bench" / "cases"))
    r = sub.add_parser("report")
    r.add_argument("run_dir")
    a = ap.parse_args(argv)
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:
        pass
    if a.cmd == "generate":
        from .generator import write_t0
        for line in write_t0(Path(a.out)):
            print(line)
        return 0
    if a.cmd == "report":
        from .report import render_md
        print(render_md(json.loads((Path(a.run_dir) / "report.json").read_text(encoding="utf-8"))))
        return 0
    cases = load_cases(Path(a.cases))
    if a.only:
        want = {x.strip() for x in a.only.split(",")}
        cases = [c for c in cases if c.id in want]
    if a.cmd == "lint":
        bad = {c.id: p for c in cases if (p := lint(c))}
        for cid, p in bad.items():
            print(f"LINT {cid}: {'; '.join(p)}")
        print(f"{len(cases) - len(bad)}/{len(cases)} cases lint-clean")
        return 1 if bad else 0
    calls = plan_calls(cases, a.repeat)
    print(f"{len(cases)} cases on {a.target}; model-call ceiling: {calls} (llm={a.llm})")
    if a.cmd == "plan":
        return 0
    if a.target == "dev":
        print("dev target: needs bench_probe.lua + the dev referee and main's go-ahead (evals/bench/devtarget.py)")
        return 2
    if a.cmd == "controls":
        res = lint_controls(cases)
        ok = sum(1 for v in res.values() if v["valid_lint"])
        print(f"controls lint: {ok}/{len(res)} cases valid on the mock (lint only, never counts for GOAL)")
        return 0 if ok == len(res) else 1
    if a.llm == "real":
        models = {"haiku": os.environ.get("DW_CONTROLLER_MODEL", ""), "sonnet": os.environ.get("DW_PLANNER_MODEL", "")}
        okay, why = spend_preflight(calls, models)
        print(f"spend preflight: {why}")
        if not okay:
            return 3
        if not a.yes:
            print("real-model run: re-run with --yes to confirm the call plan above")
            return 2
    c_llm, p_llm = _llms(a.llm)
    out = run_mock(cases, "companion", c_llm, p_llm, a.repeat, None if a.no_scoreboard else SCOREBOARD,
                   full=not a.only, llm=a.llm)
    print(f"RESULT {out['report']['counts']}  report: {out['dir']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Run benchmark cases on the DEV world with the full companion stack (design §7.1): a harness brain session over the
client bridge's debug channel, Claude's real client, judged by the harness probe + dev referee (devtarget.py).

  .venv\\Scripts\\python.exe -m evals.bench.devrun --cases evals/bench/cases/t0_spells.json --only a,b --calls 6 --yes

Preconditions (checked, fail closed): the client is on the local dev server (never Shockbyte), run_live is not running,
the $10/day spend cap holds for the worst case, main's go-ahead for the run. Measurement runs before Luis's judge tag
are written with full=False and never count for GOAL.

Front-end returns (BUGS L24): the game crashes on the 3rd return to the menu in one client process. Never disconnect or
rejoin the client by hand (disconnect.lua) between runs: --switch gets it onto dev through tools/client_boot.ps1 -Target
dev, which relaunches the process instead when its 2 returns are used (tools.scenario_run.frontend_state reports them).
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

from brain.interface import ChatHeard

from . import hashes, leaves  # noqa: F401
from .agents import BudgetExceeded, CountingLLM, model_family
from .devtarget import REFEREE_SUPPORTS, DevTarget, forbidden_addresses, joined_from_game_log
from .observer import NOT_ACTIONS, Abort, ObservedGame, evidence_ctx
from .runner import CaseResult, judge, new_result, process_metrics, run_dir, write_run, spend_preflight
from .spec import Case, calls_cap, load_cases

ROOT = hashes.ROOT
POLL_S = 0.25
_WARMED = {"done": False}  # controller.warm_up() once per process, before the first case (broker review, L27)
GUID = "E71C5DC146F0A55B69FF52A881255DEF"  # ClaudeDev on the dev server (DISCOVERIES 2026-10-25)


def user_env(names: tuple[str, ...] = ("ANTHROPIC_API_KEY", "DW_CONTROLLER_MODEL", "DW_PLANNER_MODEL")) -> None:
    """The model settings live in the Windows user environment (tools/start_brain.ps1); load them into this process
    without printing them."""
    for n in names:
        if os.environ.get(n):
            continue
        try:
            v = subprocess.run(["powershell", "-NoProfile", "-Command", f"[Environment]::GetEnvironmentVariable('{n}','User')"],
                               capture_output=True, text=True, timeout=30).stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            v = ""
        if v:
            os.environ[n] = v


def default_dev() -> DevTarget:
    from tools.scenario_run import Ops, run_client_cmd

    def server_debug(args: dict) -> dict:
        from brain.bridge_client import BridgeClient
        from brain.transport import file_transport_pair
        brain_side, _ = file_transport_pair(body="server", channel="main")
        return BridgeClient(brain_side).request("debug_run", {"module": "bench", "args": args}, timeout=30)
    ops = Ops()
    return DevTarget(GUID, client_cmd=run_client_cmd, server_debug=server_debug, joined=joined_from_game_log,
                     forbidden=forbidden_addresses, brain_running=ops.brain_running)


def character_policy(case: Case) -> str:
    """'fresh' = a brand-new dev character for this case (fixtures.character), else 'main' (ClaudeDev)."""
    return str((case.fixtures.model_extra or {}).get("character") or "main")


class FixtureGap(Abort):
    """Case setup failed (main 2026-10-26: e.g. raise_skills before it is verified): reads as a fixture gap."""


def build_dev_companion(game, workdir: Path, caps_cap: dict[str, int], log_name: str = "brain.jsonl"):
    """The real Controller/Planner/Executor/broker over the observed bridge, with the body's capability manifest and
    the knowledge index, its state in this case's own fresh directory (design §7.3)."""
    from brain.capabilities import discover
    from brain.controller import Controller
    from brain.executor import Executor
    from brain.jsonl_log import JsonlLogger
    from brain.knowledge import open_knowledge
    from brain.planner import Planner
    from brain.run_live import LiveAgent, make_llms
    from brain.state_store import StateStore

    log = JsonlLogger(workdir / log_name)
    caps = discover(game.inner, log, 5.0)
    c, p = make_llms(False)
    ctl = CountingLLM(c, model_family(c.model), int(caps_cap.get(model_family(c.model), 6)), log)
    pln = CountingLLM(p, "sonnet", max(1, int(caps_cap.get("sonnet", 0))), log)
    store = StateStore(workdir / "state", caps.registry())
    executor = Executor(game, store, log, max_attempts=1)
    controller = Controller(ctl, game, store, log, name="Claude", player="Tester", available_tools=caps.tools, caps=caps,
                            knowledge=open_knowledge(log))
    agent = LiveAgent(game, controller, Planner(pln, store.skills, log), executor, store, log,
                      prefixes=["claude ", "claude,", "@claude "], calls_per_min=1000, debounce_s=0.0)
    agent.body_self_defends = "combat_status" in caps.extras
    if os.environ.get("DW_DIRECTOR") == "1":  # Luis 2026-10-26: main variants run with the task board + Director
        from brain.director import Director
        from brain.skill_library import SkillLibrary
        os.environ["DW_WORLD_GUID"] = "dev_bench"  # belt and braces: nothing here may resolve to the shockbyte world
        # the board, learned skills and knowledge memory live in this case's fresh directory: no carry-over between
        # cases, never the shockbyte world folder (director.md §14 precondition 3)
        d = Director.for_session(agent, pln, store=store, skills=SkillLibrary(workdir / "skills", log),
                                 knowledge=controller.knowledge, caps=caps, budget=None, log=log, player="Tester")
        log.log("bench_director", on=True, board_dir=str(store.dir))
        agent.director = d
        controller.attach_director(d)
    if not _WARMED["done"] and hasattr(controller, "warm_up"):
        try:
            controller.warm_up()  # primes the provider's prompt cache so case 1's latency isn't a cold start
        except Exception as exc:  # warm-up is an optimisation; never a reason to fail a case
            log.log("bench_warm_up_error", error=repr(exc))
        _WARMED["done"] = True
    return agent, ctl, pln, log


def run_case_dev(case: Case, dev: DevTarget, workdir: Path, calls_cap_: dict[str, int], log=print) -> CaseResult:
    from brain.bridge_client import BridgeClient
    from brain.jsonl_log import JsonlLogger
    from brain.transport import file_transport_pair

    r = new_result(case, "companion", "dev")
    r.character = dev.character_name
    workdir.mkdir(parents=True, exist_ok=True)
    w0 = time.time()
    ctl = pln = None
    try:
        dev.guard()
        bindings: dict = {}
        for step in case.fixtures.setup:
            s = dict(step)
            verb, name = s.pop("verb"), s.pop("as", None)
            s["purpose"] = f"case {case.id} ({case.variant}): " + str(s.get("purpose") or "setup")
            try:
                out = dev.setup(verb, **s)
            except Abort as exc:  # an unverified or failed fixture: the case can't be set up - a gap, never his fail
                raise FixtureGap(f"{verb}: {exc}") from exc
            if name:
                bindings[name] = out
        brain_side, _ = file_transport_pair(body="client", channel="debug")
        client = BridgeClient(brain_side, logger=JsonlLogger(workdir / "bridge.jsonl"))
        game = ObservedGame(client, dev.probe, dev.referee_events, clock=time.time, guard=dev.guard)
        dev.referee_start()
        agent, ctl, pln, blog = build_dev_companion(game, workdir, calls_cap_)
        game.start()
        chat_wall = time.time()
        for line in case.chat:
            agent.heard(ChatHeard(player="Tester", text=line.text))
        last = time.time()
        n_seen = 0
        while time.time() - w0 < case.limits.wall_s:
            agent.step()
            if ctl.exceeded or pln.exceeded:
                raise BudgetExceeded("model-call cap reached")
            n = len(game.rec.observations) + len(game.rec.said)
            if n != n_seen:
                n_seen, last = n, time.time()
                if game.rec.observations and _passed(case, game, bindings):
                    break
            elif time.time() - last > case.limits.idle_s:
                break
            time.sleep(POLL_S)
        game.finish()
        result, reason, succ, ctx = judge_dev(case, game, bindings)
        r.result, r.reason, r.detail, r.progress, r.missing = result, reason, succ.detail, succ.progress, list(succ.missing)
        r.mismatches = list(ctx["mismatches"])
        acts = [o for o in game.rec.observations if o.tool not in NOT_ACTIONS]
        r.latency_s = round(acts[0].wall0 - chat_wall, 2) if acts else None
        r.calls = {ctl.family: ctl.calls, pln.family: pln.calls}
        r.usage = ctl.usage + pln.usage
        r.failures = [{"tool": o.tool, "reason": o.reply.get("reason"), "detail": (o.reply.get("data") or {}).get("detail")}
                      for o in game.rec.observations if not o.reply.get("ok")]
        r.process = process_metrics(case, game)
        trace = {"case": case.id, "case_hash": r.case_hash, "observations": [o.to_dict() for o in game.rec.observations],
                 "referee": game.rec.referee, "said": game.rec.said, "reads": game.rec.reads, "setup": dev.setup_log,
                 "probe0": game.rec.probe0, "probe1": game.rec.probe1, "result": result, "reason": reason}
        tf = workdir / "trace.json"
        tf.write_text(json.dumps(trace, default=str), encoding="utf-8")
        r.trace, r.trace_sha256 = str(tf), hashes.sha256_file(tf)
    except BudgetExceeded as exc:
        r.result, r.reason, r.detail = "error", "budget", str(exc)
        if ctl is not None:  # keep what was spent visible in the scoreboard
            r.calls = {ctl.family: ctl.calls, pln.family: pln.calls}
            r.usage = ctl.usage + pln.usage
    except FixtureGap as exc:
        r.result, r.reason, r.detail = "unverifiable", "fixture_gap", str(exc)
    except Abort as exc:
        r.result, r.reason, r.detail = "error", "aborted", str(exc)
    finally:
        try:
            dev.referee_stop()
        except Exception:
            pass
    r.wall_s = round(time.time() - w0, 1)
    return r


def judge_dev(case: Case, game: ObservedGame, bindings: dict):
    from brain import predicates as P
    from .agents import bind
    from .runner import probe_state
    st0, st1 = probe_state(game.rec.probe0), probe_state(game.rec.probe1 or game.rec.probe0)
    ctx = evidence_ctx(game.rec, st0, leaves.default_spells(), now=time.time(), referee_supports=set(REFEREE_SUPPORTS))
    succ = P.evaluate(P.validate(bind(case.success, bindings)), st1, ctx)
    guards = [P.evaluate(P.validate(bind(g, bindings)), st1, ctx) for g in case.guards]
    if ctx["mismatches"]:
        return "error", "sensor_mismatch", succ, ctx
    if any(g.passed is False for g in guards):
        return "fail", "guard", succ, ctx
    if succ.passed is None or any(g.passed is None for g in guards):
        return "unverifiable", "perception_gap", succ, ctx
    return ("pass", None, succ, ctx) if succ.passed else ("fail", "not_achieved", succ, ctx)


def _passed(case: Case, game: ObservedGame, bindings: dict) -> bool:
    game.rec.probe1 = game.rec.observations[-1].after
    try:
        return judge_dev(case, game, bindings)[0] == "pass"
    finally:
        game.rec.probe1 = None


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cases", required=True)
    ap.add_argument("--only", required=True, help="comma list of case ids (a dev run is always partial before the judge tag)")
    ap.add_argument("--calls", type=int, default=6, help="Haiku calls per case (cap)")
    ap.add_argument("--sonnet", type=int, default=0, help="Sonnet (Director) calls per case (cap); needs DW_DIRECTOR=1")
    ap.add_argument("--yes", action="store_true")
    ap.add_argument("--switch", action="store_true",
                    help="first move the client onto dev via client_boot.ps1 -Target dev (relaunches instead of a 3rd "
                         "front-end return, BUGS L24)")
    a = ap.parse_args(argv)
    if os.environ.get("DW_DIRECTOR") == "1" and a.sonnet <= 0:
        ap.error("DW_DIRECTOR=1 runs the Sonnet Director: pass --sonnet N (its per-case call cap) so the plan states it")
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:
        pass
    want = [x.strip() for x in a.only.split(",")]
    cases = [c for c in load_cases(Path(a.cases)) if c.id in want]
    cap = {"haiku": a.calls, "sonnet": a.sonnet}
    total = {"haiku": a.calls * len(cases), "sonnet": a.sonnet * len(cases)}
    user_env()
    models = {"haiku": os.environ.get("DW_CONTROLLER_MODEL", ""), "sonnet": os.environ.get("DW_PLANNER_MODEL", "")}
    print(f"{len(cases)} cases on DEV, model-call ceiling {total} ({models['haiku']})")
    ok, why = spend_preflight(total, models)
    print(f"spend preflight: {why}")
    if not ok:
        return 3
    if not a.yes:
        print("re-run with --yes to start")
        return 2
    from tools.scenario_run import Ops, frontend_state, relaunched
    fe = frontend_state()
    print(f"front-end returns: {fe}" + (" -> the next disconnect/rejoin relaunches the client (BUGS L24)"
                                         if fe and fe.get("needs_relaunch") else ""))
    if a.switch:
        b = Ops().boot("dev")
        print(f"switch to dev: ok={b.get('ok')} joined={b.get('joined')} reason={b.get('reason')}"
              + (" (relaunched, BUGS L24)" if relaunched(b) else ""))
        if not b.get("ok"):
            return 4
    dev = default_dev()
    rid, d = run_dir("dev", "measure")
    from .devchar import MAIN_CHARACTER, default_switch, fresh_name
    switch = default_switch(dev)
    results = []
    for i, c in enumerate(cases):
        # main 2026-10-26: cases that need a pristine start get their own new character; the rest run on ClaudeDev
        policy = character_policy(c)
        fresh = policy == "fresh"
        name = fresh_name(c.id, f"{rid[-4:]}{i}") if fresh else MAIN_CHARACTER
        try:
            if policy.startswith("chain:"):
                raise Abort(f"{policy}: continuing a previous case's character needs the dev-save snapshot (route B), "
                            "not built yet")
            info = switch.ensure(name, create=fresh)
            dev.character_guid, dev.character_name = info["guid"], name
        except Abort as exc:
            res = new_result(c, "companion", "dev")
            res.character, res.result, res.reason, res.detail = name, "unverifiable", "fixture_gap", f"character: {exc}"
            print(f"  [{c.id}] {res.result} ({res.reason}): {res.detail}")
            results.append(res)
            continue
        if info.get("relaunched"):
            print(f"  character {name}: {'created and ' if info.get('created') else ''}joined (client relaunched, BUGS L24)")
        res = run_case_dev(c, dev, d / "work" / c.id, cap)
        print(f"  [{c.id}] {res.result}{' (' + res.reason + ')' if res.reason else ''}: {res.detail} | latency {res.latency_s} s, "
              f"calls {res.calls}, failures {res.failures[:2]}")
        results.append(res)
    out = write_run(rid, d, "dev", "companion", results, cases, False, extra={"llm": "real", "models": models,
                                                                              "measurement": "pre-judge-tag"})
    print(f"RESULT {out['report']['counts']}  report: {out['dir']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

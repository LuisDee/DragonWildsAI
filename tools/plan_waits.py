r"""Plan waits: per Planner plan or replan, how long the body stood waiting for it. Read-only over brain logs.

Goal item 1 (docs/GOAL-2026-11-17-long-jobs.md): "the thinking model plans and revises while the fast model keeps
acting; neither waits for the other". DW_ASYNC_PLAN=1 (brain/plan_async.py) runs the Planner call on a worker; this
tool gives the number the window on it is judged by, from logs/brain-live-*.jsonl alone (no model call, nothing sent).

  .venv\Scripts\python.exe -m tools.plan_waits report --since 2026-11-18
  .venv\Scripts\python.exe -m tools.plan_waits report --since 2026-11-18T07:30 --list
  .venv\Scripts\python.exe -m tools.plan_waits report --since 2026-11-18 --json > out.json

Times are UTC (--since/--until as tools/think_act.py: YYYY-MM-DD or YYYY-MM-DDTHH:MM).

Per plan (one Planner composition, a plan or a replan):
  mode         "async": a plan_started row opened it (DW_ASYNC_PLAN=1; it ends at plan_arrived / plan_abandoned in the
               same episode; the worker's own planner prompt and llm_response rows inside it belong to it).
               "sync": a planner prompt row outside any async composition (flag off writes no plan_* rows; a quiet
               goal inside a board run plans in line even with the flag on, and is sync here too).
               A session is "async" when it wrote any plan_started row.
  request      sync: the planner prompt row. async: the plan_started row (logged right after the worker is handed
               the call; a worker prompt row up to ASYNC_LEAD_S before it is taken as its own).
  planner_s    the Planner call: sync, request to the `plan` row (else the last planner llm_response before the
               episode moves on); async, plan_arrived composed_s (else its age_s, else the row's time).
  body_wait_s  request to the first body call after it (or, if a player's line is heard first after the plan
               landed, to that line: from then he waits on the player, not the Planner), minus the seconds a body
               call was running meanwhile. None when neither came before the session ended.
  body_calls   body calls started between the request and the plan's end, with the seconds of body running inside
               the Planner call (body_during_s); async also has the brain's own count (acted_while_planning n).
  over_5s      body_wait_s > 5 (WAIT_BAR_S). The share of plans over it is the window's number.

A body call is a tool_call with a task_id that is not read_only (the executor's; set_vitals_policy excepted), from
it to its tool_result; a command left running (action_left_running) runs to its late result or the next command;
the stay-fed reflex's own activities (*_started to *_end) count as body running too (tools/think_act.py the same).

Windows: a log file belongs to the job or quest window whose trial run named it (logs/evals/job_runs.jsonl
brain_logs, job_windows.jsonl trials; quest_runs.jsonl brain_log, quest_steps.jsonl trials). Others are "-".
"""
from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from pathlib import Path
from typing import Iterator

from tools import ab
from tools.think_act import LOGS, overlap, parse_when, pick_files, union, utc

WAIT_BAR_S = 5.0
ASYNC_LEAD_S = 2.0          # a worker's planner prompt logged before its plan_started row (thread race)
LEFT_RUNNING_CAP_S = 600.0
NON_ACT = {"set_vitals_policy"}
KEEP = {"session_start", "event", "prompt", "llm_response", "tool_call", "tool_result", "say", "request_state",
        "action_left_running", "bridge_late_result", "plan", "plan_invalid", "plan_question", "plan_started",
        "plan_arrived", "plan_abandoned", "acted_while_planning"}
_KIND = re.compile(rb'^\{"ts": ([0-9.]+), "kind": "([a-z_]+)"')


# ------------------------------------------------------------------ reading
def slim(d: dict) -> dict | None:
    k, ts = d.get("kind"), d.get("ts")
    if k not in KEEP or not isinstance(ts, (int, float)):
        return None
    r = {"ts": float(ts), "kind": k, "ep": d.get("episode_id")}
    if k == "session_start":
        r["name"] = d.get("name")
    elif k == "event":
        e = d.get("event") if isinstance(d.get("event"), dict) else {}
        if e.get("type") == "chat_heard":
            r.update(type="chat_heard", player=e.get("player"))
        elif e.get("type") == "activity" and isinstance(e.get("kind"), str):
            r.update(type="activity", what=e["kind"], ets=e.get("ts"))
        else:
            return None
    elif k == "prompt":
        r["component"] = d.get("component")
        if d.get("component") == "planner":  # a replan's request carries the failed step (brain/planner.py replan)
            msgs = d.get("messages") if isinstance(d.get("messages"), list) else []
            last = msgs[-1] if msgs and isinstance(msgs[-1], dict) else {}
            r["replan"] = "failed_task" in json.dumps(last.get("content", ""), default=str)
    elif k == "llm_response":
        r["component"] = d.get("component")
    elif k in ("tool_call", "tool_result"):
        r.update(tool=d.get("tool"), task_id=d.get("task_id"), read_only=bool(d.get("read_only")))
    elif k in ("action_left_running", "bridge_late_result"):
        r.update(id=d.get("id"), tool=d.get("tool"))
    elif k == "plan":
        r.update(component=d.get("component"), mode=d.get("mode"))
    elif k in ("plan_started", "plan_arrived", "plan_abandoned"):
        r.update(plan_kind=d.get("plan_kind"), age_s=d.get("age_s"), composed_s=d.get("composed_s"),
                 ok=d.get("ok"), applied=d.get("applied"), stale=d.get("stale"))
    elif k == "acted_while_planning":
        r["n"] = d.get("n")
    return r


def read_rows(path: Path) -> Iterator[dict]:
    """Stream one brain log as slim rows; bridge traffic and other big rows are skipped before parsing."""
    with open(path, "rb") as f:
        for raw in f:
            m = _KIND.match(raw)
            if not m or m.group(2).decode() not in KEEP:
                continue
            try:
                d = json.loads(raw)
            except ValueError:
                continue
            r = slim(d)
            if r is not None:
                yield r


# ------------------------------------------------------------------ one session
def body_intervals(rows: list[dict]) -> tuple[list[dict], list[tuple[float, float]]]:
    """(body calls [{start, end, tool, ep}], unioned body-running intervals) of one session's sorted rows."""
    last_ts = rows[-1]["ts"] if rows else 0.0
    calls: list[dict] = []
    open_calls: dict = {}
    left: list[dict] = []
    reflex: list[tuple[float, float]] = []
    open_reflex: dict[str, float] = {}
    for r in rows:
        k, ts = r["kind"], r["ts"]
        if k == "tool_call" and r.get("task_id") and not r.get("read_only") and r.get("tool") not in NON_ACT:
            c = {"start": ts, "end": None, "tool": r.get("tool"), "ep": r.get("ep")}
            calls.append(c)
            open_calls[r["task_id"]] = c
            for x in left:
                if x["end"] is None:
                    x["end"] = ts
        elif k == "tool_result" and r.get("task_id") in open_calls:
            open_calls.pop(r["task_id"])["end"] = ts
        elif k == "action_left_running":
            left.append({"start": ts, "end": None, "id": r.get("id")})
        elif k == "bridge_late_result":
            for x in left:
                if x["end"] is None and x["id"] == r.get("id"):
                    x["end"] = ts
        elif k == "event" and r.get("type") == "activity":
            what, _, phase = str(r.get("what")).rpartition("_")
            at = float(r["ets"]) if isinstance(r.get("ets"), (int, float)) and abs(r["ets"] - ts) < 120 else ts
            if phase == "started":
                open_reflex.setdefault(what, at)
            elif what in open_reflex:
                a = open_reflex.pop(what)
                reflex.append((a, max(a, at)))
    for c in calls:
        if c["end"] is None:
            c["end"] = last_ts
    for x in left:
        x["end"] = min(x["end"] if x["end"] is not None else last_ts, x["start"] + LEFT_RUNNING_CAP_S)
    reflex += [(a, last_ts) for a in open_reflex.values()]
    iv = union([(c["start"], c["end"]) for c in calls] + [(x["start"], x["end"]) for x in left] + reflex)
    return calls, iv


def compositions(rows: list[dict]) -> list[dict]:
    """The Planner compositions of one session's sorted rows: async ones first found, then sync prompts outside."""
    comps: list[dict] = []
    open_async: dict = {}
    for r in rows:
        k, ep = r["kind"], r.get("ep")
        if k == "plan_started":
            if ep in open_async:
                comps.append({**open_async.pop(ep), "outcome": "cut"})
            open_async[ep] = {"mode": "async", "ep": ep, "request": r["ts"], "end": None,
                              "kind": r.get("plan_kind") or "plan", "outcome": None, "acted_logged": None,
                              "asked_player": False}
        elif ep in open_async:
            c = open_async[ep]
            if k == "acted_while_planning":
                c["acted_logged"] = r.get("n")
            elif k == "plan_question":
                c["asked_player"] = True
            elif k in ("plan_arrived", "plan_abandoned"):
                took = r.get("composed_s") if isinstance(r.get("composed_s"), (int, float)) else r.get("age_s")
                c["end"] = c["request"] + float(took) if isinstance(took, (int, float)) else r["ts"]
                c["landed"] = r["ts"]
                c["outcome"] = ("abandoned" if k == "plan_abandoned" else
                                "stale" if r.get("stale") else "plan" if r.get("ok") else "no_plan")
                comps.append(open_async.pop(ep))
    last_ts = rows[-1]["ts"] if rows else 0.0
    for c in open_async.values():
        c.update(outcome="cut", end=last_ts, landed=last_ts)
        comps.append(c)

    def in_async(ts: float, ep) -> bool:
        return any(c["ep"] == ep and c["request"] - ASYNC_LEAD_S <= ts <= (c.get("landed") or c["end"])
                   for c in comps if c["mode"] == "async")

    open_sync: dict = {}

    def close(ep, outcome):
        c = open_sync.pop(ep)
        c["outcome"] = c["outcome"] or outcome
        c["end"] = c["end"] if c["end"] is not None else c["request"]
        c["landed"] = c["end"]
        comps.append(c)

    for r in rows:
        k, ep, ts = r["kind"], r.get("ep"), r["ts"]
        if k == "prompt" and r.get("component") == "planner":
            if in_async(ts, ep):
                continue
            if ep in open_sync:
                close(ep, "plan" if open_sync[ep]["end"] is not None else "cut")
            open_sync[ep] = {"mode": "sync", "ep": ep, "request": ts, "end": None,
                             "kind": "replan" if r.get("replan") else "plan", "outcome": None, "acted_logged": None,
                             "asked_player": False, "done": False}
            continue
        if ep not in open_sync:
            continue
        c = open_sync[ep]
        if k == "llm_response" and r.get("component") == "planner" and not c["done"]:
            c["end"] = ts
        elif k == "plan" and not c["done"]:
            c.update(end=ts, done=True, outcome="plan")
            if r.get("mode") == "replan":
                c["kind"] = "replan"
        elif k == "plan_question":
            c["asked_player"] = True
        elif k in ("tool_call", "say", "request_state") or (k == "prompt" and r.get("component") != "planner"):
            close(ep, "plan" if c["end"] is not None else "no_plan")
    for ep in list(open_sync):
        close(ep, "plan" if open_sync[ep]["end"] is not None else "cut")
    for c in comps:
        c.pop("done", None)
    comps.sort(key=lambda c: c["request"])
    return comps


def analyse(rows: list[dict], source: str = "") -> dict:
    """All plans of one session (pure: no file access)."""
    rows = sorted(rows, key=lambda r: r["ts"])
    if not rows:
        return {"source": source, "async_session": False, "plans": []}
    me = next((str(r.get("name") or "") for r in rows if r["kind"] == "session_start"), "")
    calls, body_iv = body_intervals(rows)
    heard = [r["ts"] for r in rows if r["kind"] == "event" and r.get("type") == "chat_heard"
             and (r.get("player") or "") != me]
    plans = []
    for c in compositions(rows):
        req, end = c["request"], max(c["request"], c["end"])
        nxt = next((b for b in calls if b["start"] >= req), None)
        line = next((t for t in heard if t >= c.get("landed", end)), None)
        if nxt is not None and (line is None or nxt["start"] <= line):
            stop, by = nxt["start"], "body"
        elif line is not None:
            stop, by = line, "player"
        else:
            stop, by = None, None
        during = [b for b in calls if req <= b["start"] <= end]
        wait = None if stop is None else round(max(0.0, (stop - req) - overlap(req, stop, body_iv)), 2)
        plans.append({
            "source": source, "ep": c["ep"], "mode": c["mode"], "kind": c["kind"], "utc": utc(req), "ts": req,
            "outcome": c["outcome"], "asked_player": c["asked_player"],
            "planner_s": round(end - req, 2), "body_wait_s": wait, "wait_ended_by": by,
            "first_body_call": ({"tool": nxt["tool"], "after_s": round(nxt["start"] - req, 2)} if nxt else None),
            "body_calls": len(during), "body_tools": [b["tool"] for b in during][:12],
            "body_during_s": round(overlap(req, end, body_iv), 2), "acted_logged": c["acted_logged"],
            "over_5s": None if wait is None else wait > WAIT_BAR_S,
        })
    return {"source": source, "async_session": any(r["kind"] == "plan_started" for r in rows), "plans": plans}


# ------------------------------------------------------------------ windows
def _jsonl(p: Path) -> Iterator[dict]:
    try:
        with open(p, encoding="utf-8") as f:
            for line in f:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if isinstance(d, dict):
                    yield d
    except OSError:
        return


def window_map(evals: Path) -> dict[str, dict]:
    """log file stem -> {window, item, run} from the trial records (job and quest windows)."""
    runs: dict[str, dict] = {}
    for d in _jsonl(evals / "job_runs.jsonl"):
        item = d.get("item") or f"job: {d.get('job')}" + (f" / {d['rung']}" if d.get("rung") else "")
        for b in d.get("brain_logs") or []:
            runs.setdefault(str(d.get("run")), {"item": item, "logs": []})["logs"].append(b)
    for d in _jsonl(evals / "quest_runs.jsonl"):
        if d.get("brain_log"):
            runs.setdefault(str(d.get("run")), {"item": f"quest: {d.get('quest')}", "logs": []})["logs"].append(
                d["brain_log"])
    out: dict[str, dict] = {}
    for fname in ("job_windows.jsonl", "quest_steps.jsonl"):
        for w in _jsonl(evals / fname):
            for t in w.get("trials") or []:
                run = runs.get(str(t.get("run")))
                if not run:
                    continue
                for b in run["logs"]:
                    out[Path(str(b)).stem.replace("brain-live-", "")] = {
                        "window": w.get("window"), "item": run["item"], "run": t.get("run")}
    for run_id, run in runs.items():  # a run whose window record is missing still names its item
        for b in run["logs"]:
            out.setdefault(Path(str(b)).stem.replace("brain-live-", ""),
                           {"window": None, "item": run["item"], "run": run_id})
    return out


# ------------------------------------------------------------------ summary
def summ(xs) -> dict:
    v = sorted(float(x) for x in xs if x is not None)
    if not v:
        return {"n": 0, "median": None, "p90": None, "worst": None}
    return {"n": len(v), "median": round(statistics.median(v), 2),
            "p90": round(v[max(0, -(-9 * len(v) // 10) - 1)], 2), "worst": round(v[-1], 2)}


def side(plans: list[dict]) -> dict:
    known = [p for p in plans if p["body_wait_s"] is not None]
    k = sum(1 for p in known if p["over_5s"])
    lo, hi = ab.wilson(k, len(known))
    return {"plans": len(plans), "known": len(known), "over_5s": k,
            "share_over_5s": round(k / len(known), 3) if known else None, "ci95": [round(lo, 3), round(hi, 3)],
            "body_wait_s": summ(p["body_wait_s"] for p in known), "planner_s": summ(p["planner_s"] for p in plans),
            "with_body_calls": sum(1 for p in plans if p["body_calls"] > 0),
            "replans": sum(1 for p in plans if p["kind"] == "replan"),
            "asked_player": sum(1 for p in plans if p["asked_player"]),
            "ended_by_player": sum(1 for p in known if p["wait_ended_by"] == "player")}


def aggregate(results: list[dict], wmap: dict[str, dict] | None = None) -> dict:
    wmap = wmap or {}
    plans = [p for r in results for p in r["plans"]]
    for p in plans:
        w = wmap.get(p["source"]) or {}
        p["window"], p["item"], p["run"] = w.get("window"), w.get("item"), w.get("run")
    out = {"bar_s": WAIT_BAR_S, "sessions": len(results),
           "async_sessions": sum(1 for r in results if r["async_session"]),
           "sides": {m: side([p for p in plans if p["mode"] == m]) for m in ("sync", "async")}, "windows": []}
    keys: dict = {}
    for p in plans:
        keys.setdefault((p["window"] or "-", p["item"] or "-", p["mode"]), []).append(p)
    for (w, item, mode), ps in sorted(keys.items(), key=lambda kv: min(p["ts"] for p in kv[1])):
        s = side(ps)
        out["windows"].append({"window": w, "item": item, "mode": mode, "sources": sorted({p["source"] for p in ps}),
                               "plans": s["plans"], "over_5s": s["over_5s"], "known": s["known"],
                               "median_wait_s": s["body_wait_s"]["median"], "median_planner_s": s["planner_s"]["median"],
                               "with_body_calls": s["with_body_calls"]})
    out["plans"] = plans
    return out


def run(since: float | None, until: float | None, logs: Path | None = None) -> list[dict]:
    out = []
    for p in pick_files(since, until, logs if logs is not None else LOGS):
        res = analyse(list(read_rows(p)), p.stem.replace("brain-live-", ""))
        res["plans"] = [x for x in res["plans"] if (since is None or x["ts"] >= since)
                        and (until is None or x["ts"] < until)]
        if res["plans"]:
            out.append(res)
    return out


def _side_line(name: str, s: dict) -> str:
    if not s["plans"]:
        return f"  {name:5} no plans"
    w, pl = s["body_wait_s"], s["planner_s"]
    share = f"{s['over_5s']} of {s['known']} = {s['share_over_5s']:.0%}" if s["known"] else "n/a"
    return (f"  {name:5} plans {s['plans']} (replans {s['replans']}, asked the player {s['asked_player']})  "
            f"body wait > {WAIT_BAR_S:g} s: {share} (95 % {s['ci95'][0]:.0%}-{s['ci95'][1]:.0%})\n"
            f"        body wait s: median {w['median']} p90 {w['p90']} worst {w['worst']} (n {w['n']}; "
            f"{s['ended_by_player']} cut at a player's line)\n"
            f"        Planner call s: median {pl['median']} p90 {pl['p90']} worst {pl['worst']}; "
            f"plans with body calls during the call: {s['with_body_calls']} of {s['plans']}")


def render(agg: dict, listing: bool = False) -> str:
    lines = [f"plan waits: {agg['sessions']} sessions ({agg['async_sessions']} with DW_ASYNC_PLAN rows)",
             _side_line("sync", agg["sides"]["sync"]), _side_line("async", agg["sides"]["async"]), "", "per window:"]
    for w in agg["windows"]:
        lines.append(f"  {w['window']:16} {w['item'][:34]:34} {w['mode']:5} plans {w['plans']:2}  "
                     f">5s {w['over_5s']}/{w['known']}  wait med {w['median_wait_s']}  planner med "
                     f"{w['median_planner_s']}  with body calls {w['with_body_calls']}  ({', '.join(w['sources'])})")
    if listing:
        lines += ["", "per plan:"]
        for p in agg["plans"]:
            fb = p["first_body_call"]
            lines.append(f"  {p['utc']} {p['source']} {p['mode']:5} {p['kind']:6} {p['outcome']:9} "
                         f"planner {p['planner_s']:6.2f}  wait {p['body_wait_s']} ({p['wait_ended_by']})  "
                         f"calls during {p['body_calls']}  first {fb['tool'] if fb else None}"
                         f"{'  asked player' if p['asked_player'] else ''}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="tools.plan_waits", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("report")
    r.add_argument("--since")
    r.add_argument("--until")
    r.add_argument("--logs", help="the logs directory (default: this checkout's logs)")
    r.add_argument("--list", action="store_true", help="one line per plan")
    r.add_argument("--json", action="store_true")
    ns = ap.parse_args(argv)
    logs = Path(ns.logs) if ns.logs else LOGS
    agg = aggregate(run(parse_when(ns.since), parse_when(ns.until), logs), window_map(logs / "evals"))
    if ns.json:
        print(json.dumps(agg, indent=1, default=str))
    else:
        print(render(agg, ns.list))
    return 0


if __name__ == "__main__":
    sys.exit(main())

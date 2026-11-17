r"""Think and act: does the fast model act while the slow one thinks? Measures from recorded live play.

The goal (docs/GOAL-2026-11-17-long-jobs.md, "The two models on one job") and the research note's Decision item 3
(docs/research/2026-11-17-long-jobs-planner-actor.md) ask for four numbers. This tool computes them from the brain's
own log rows (logs/brain-live-*.jsonl), with no model call and nothing sent to the game.

  .venv\Scripts\python.exe -m tools.think_act report --since 2026-11-14 --until 2026-11-18
  .venv\Scripts\python.exe -m tools.think_act report --since 2026-11-01T22:00 --until 2026-11-02T04:00 \
      --grep "gear up properly|sort your bag out"
  .venv\Scripts\python.exe -m tools.think_act report --since 2026-11-14 --json > out.json
  .venv\Scripts\python.exe -m tools.think_act ask 20261115-235756-19752/chat-0001-52b5     # one ask's timeline

Times are UTC (rows carry epoch "ts"; a log file NAME is local time, UTC+1, and is used only to pick files).

Definitions (the rows each one reads, with the line that writes them, are in the baseline doc):
  ask            a chat episode (episode_id "chat-...") with a player's line heard (event chat_heard) that the
                 Controller was called for and did not mark "ignored". Its time is the first line heard.
  window         from the ask to the next ask of the same session (or the session's end), cut back to the last row
                 that belongs to an episode or the Director. A hunger run or a goal's end mid-job is part of the
                 job's wall time; a trial session (quest_run, rung4_gate) ends when the harness ends it.
  act            a body command dispatched for the ask: a tool_call with a task_id (the executor's, brain/executor.py
                 :495) in the ask's own episode or a board-* episode, except set_vitals_policy. A chat line is
                 not an act; the first line said (say_result ok) is reported beside it.
  body running   a body command between its tool_call and tool_result (any episode), a command the brain left
                 running (action_left_running, to its late result or the next command), and the reflex's own
                 fights and flights (activity *_started to *_end).
  model thinking an llm_response's wall time: start = its ts minus usage.latency_ms (llm.py _call_meta; the start is
                 DERIVED, the prompt row is the fallback). Planner = components "planner" and "director";
                 "skill_learner" is Sonnet too and is shown apart.
  composition    one plan being made: a planner prompt row to its last llm_response (repairs included), or a
                 director_dispatch to its director_decision / _discarded / _decision_failed / _timeout.
  stand          seconds of a composition with no body running.
  stale          a composition that landed when the state it was made on had changed in a way that matters
                 (rule in stale_reasons()).
"""
from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Iterable, Iterator

ROOT = Path(__file__).resolve().parents[1]
LOGS = ROOT / "logs"

PLANNER = {"planner", "director"}
LEARNER = {"skill_learner"}
NON_ACT = {"set_vitals_policy"}            # a policy write, no motion and nothing done for the ask
JOB_PREFIXES = ("board-", "director-")     # episodes a long job runs in besides the ask's own
MOVED_M = 20.0                             # the owner's "moved more than 20 m"
AT_TARGET_M = 3.0                          # a go_to whose target is this close at landing was already done
BASIS_MAX_S = 60.0                         # the state a plan was made on: the last read at most this long before
LAND_MAX_S = 15.0                          # the state at landing: the first read at most this long after
LEFT_RUNNING_CAP_S = 600.0
RECENT_S = 600.0                           # a file written in the last 10 minutes may belong to a live brain

_KIND = re.compile(rb'^\{"ts": ([0-9.]+), "kind": "([a-z_]+)"')
KEEP = {"session_start", "event", "chat_decision", "prompt", "llm_response", "tool_call", "tool_result", "say",
        "say_result", "bridge_send", "bridge_recv", "action_left_running", "bridge_late_result", "plan_invalid",
        "director_dispatch", "director_decision", "director_discarded", "director_decision_failed",
        "director_timeout", "request_state"}


# ------------------------------------------------------------------ reading
def _usage(u) -> dict:
    u = u if isinstance(u, dict) else {}
    return {k: u.get(k) for k in ("prompt", "completion", "cached", "cache_write", "latency_ms", "cost_usd")}


def _args(a) -> dict:
    a = a if isinstance(a, dict) else {}
    return {k: a[k] for k in ("target", "item", "resource", "count", "piece", "name", "quest") if k in a}


def slim(d: dict, gs_ids: set) -> dict | None:
    """One parsed log row cut to what the measures read (None: not needed). ``gs_ids`` collects get_state ids."""
    k, ts, ep = d.get("kind"), d.get("ts"), d.get("episode_id")
    if not isinstance(ts, (int, float)) or k not in KEEP:
        return None
    r = {"ts": float(ts), "kind": k, "ep": ep}
    if k == "session_start":
        r.update({x: d.get(x) for x in ("name", "planner_model", "controller_model", "director", "world")})
    elif k == "event":
        e = d.get("event") if isinstance(d.get("event"), dict) else {}
        t = e.get("type")
        if t == "chat_heard":
            r.update(type=t, player=e.get("player"), text=str(e.get("text") or ""))
        elif t == "activity" and isinstance(e.get("kind"), str):
            r.update(type=t, what=e["kind"], ets=e.get("ts"))
        else:
            return None
    elif k == "chat_decision":
        r.update(decision=d.get("decision"), player=d.get("player"))
    elif k == "prompt":
        r.update(component=d.get("component"), model=d.get("model"))
        if d.get("component") == "planner":  # a replan's request carries the failed step (brain/planner.py replan)
            last = (d.get("messages") or [{}])[-1] if isinstance(d.get("messages"), list) else {}
            r["replan"] = "failed_task" in json.dumps(last.get("content") if isinstance(last, dict) else "")
    elif k == "llm_response":
        r.update(component=d.get("component"), model=d.get("model"), usage=_usage(d.get("usage")))
    elif k == "tool_call":
        r.update(tool=d.get("tool"), task_id=d.get("task_id"), read_only=bool(d.get("read_only")), args=_args(d.get("args")))
    elif k == "tool_result":
        res = d.get("result") if isinstance(d.get("result"), dict) else {}
        data = res.get("data") if isinstance(res.get("data"), dict) else {}
        r.update(tool=d.get("tool"), task_id=d.get("task_id"), read_only=bool(d.get("read_only")), ok=res.get("ok"),
                 reason=res.get("reason"), detail=str(data.get("detail") or data.get("why") or "")[:160])
    elif k == "say":
        r.update(text=str(d.get("text") or "")[:120])
    elif k == "say_result":
        r.update(ok=bool(d.get("ok")))
    elif k == "bridge_send":
        m = d.get("msg") if isinstance(d.get("msg"), dict) else {}
        if m.get("tool") == "get_state" and m.get("id"):
            gs_ids.add(m["id"])
        return None
    elif k == "bridge_recv":
        m = d.get("msg") if isinstance(d.get("msg"), dict) else {}
        data = m.get("data") if isinstance(m.get("data"), dict) else {}
        if m.get("id") not in gs_ids or not isinstance(data.get("position"), list):
            return None
        inv = data.get("inventory") if isinstance(data.get("inventory"), dict) else {}
        r.update(kind="state", pos=[float(x) for x in data["position"][:3]], fight=bool(data.get("fight")),
                 dead=bool(data.get("dead")), inv={str(a): b for a, b in inv.items() if isinstance(b, (int, float))})
    elif k == "action_left_running":
        r.update(id=d.get("id"), tool=d.get("tool"))
    elif k == "bridge_late_result":
        r.update(id=d.get("id"), tool=d.get("tool"))
    elif k in ("director_dispatch", "director_decision", "director_discarded", "director_decision_failed",
               "director_timeout"):
        r.update(task=d.get("task"), decision=d.get("decision"))
    elif k == "request_state":
        r.update(ended=d.get("ended"))
    return r


def read_rows(path: Path) -> Iterator[dict]:
    """Stream one brain log as slim rows. Big rows that are never needed (most bridge traffic) are not parsed."""
    gs: set = set()
    with open(path, "rb") as f:
        for raw in f:
            m = _KIND.match(raw)
            if not m:
                continue
            kind = m.group(2).decode()
            if kind not in KEEP:
                continue
            if kind == "bridge_send" and b'"get_state"' not in raw[:400]:
                continue
            if kind == "bridge_recv" and (b'"position"' not in raw or b'"inventory"' not in raw):
                continue
            try:
                d = json.loads(raw)
            except ValueError:
                continue
            r = slim(d, gs)
            if r is not None:
                yield r


# ------------------------------------------------------------------ intervals
def union(iv: Iterable[tuple[float, float]]) -> list[tuple[float, float]]:
    out: list[list[float]] = []
    for a, b in sorted((a, b) for a, b in iv if b > a):
        if out and a <= out[-1][1]:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return [(a, b) for a, b in out]


def overlap(a: float, b: float, iv: list[tuple[float, float]]) -> float:
    """Seconds of [a, b] covered by the (unioned) intervals."""
    return sum(max(0.0, min(b, y) - max(a, x)) for x, y in iv)


def clip(iv: list[tuple[float, float]], a: float, b: float) -> list[tuple[float, float]]:
    return [(max(a, x), min(b, y)) for x, y in iv if min(b, y) > max(a, x)]


def shares(a: float, b: float, body, controller, planner, learner) -> dict:
    """Exclusive split of [a, b]: body and planner at once, body, controller, planner, learner, nothing (seconds).
    The order is the precedence: a second counts in the first class it belongs to."""
    cats = {"body": union(clip(body, a, b)), "controller": union(clip(controller, a, b)),
            "planner": union(clip(planner, a, b)), "learner": union(clip(learner, a, b))}
    cuts = sorted({a, b, *[t for iv in cats.values() for p in iv for t in p]})
    out = {"body_and_planner": 0.0, "body": 0.0, "controller": 0.0, "planner": 0.0, "learner": 0.0, "nothing": 0.0}
    for x, y in zip(cuts, cuts[1:]):
        mid = (x + y) / 2
        on = {c for c, iv in cats.items() if any(p <= mid < q for p, q in iv)}
        if "body" in on and "planner" in on:
            c = "body_and_planner"
        else:
            c = next((c for c in ("body", "controller", "planner", "learner") if c in on), "nothing")
        out[c] += y - x
    return {k: round(v, 2) for k, v in out.items()}


# ------------------------------------------------------------------ one session
def _dist(p, q) -> float:
    return math.dist(p, q) if p and q else 0.0


def _bag_change(a: dict, b: dict) -> tuple[list[str], list[str]]:
    """(non-consumable items whose count changed, consumables that changed). The reflex eats and drinks on its own."""
    names = set(a) | set(b)
    ch = sorted(n for n in names if (a.get(n) or 0) != (b.get(n) or 0))
    return [n for n in ch if "Consumable" not in n], [n for n in ch if "Consumable" in n]


def stale_reasons(comp: dict, basis: dict | None, land: dict | None, fights: list[float], nxt: dict | None) -> list[str]:
    """The rule for measure 4. A plan landed stale when, between the state it was made on (the last get_state read
    at most BASIS_MAX_S before it began) and the first read after it landed, any of these held:
      moved      he moved more than MOVED_M metres
      bag        a non-consumable item's count changed (food and drink alone: 'bag_minor', not counted)
      fight      a fight started (an activity combat_started inside the composition, or 'fight' set at landing)
      died       he died
      first_done the plan's first step was already done: its first body command answered "already ..." or was a
                 go_to whose target was within AT_TARGET_M of where he stood at landing
    """
    out: list[str] = []
    if basis and land:
        if _dist(basis["pos"], land["pos"]) > MOVED_M:
            out.append("moved")
        hard, soft = _bag_change(basis["inv"], land["inv"])
        if hard:
            out.append("bag")
        elif soft:
            out.append("bag_minor")
        if land["dead"] and not basis["dead"]:
            out.append("died")
        if land["fight"] and not basis["fight"]:
            out.append("fight")
    if "fight" not in out and any(comp["start"] <= t <= comp["end"] for t in fights):
        out.append("fight")
    if nxt:
        if "already" in f"{nxt.get('reason') or ''} {nxt.get('detail') or ''}".lower():
            out.append("first_done")
        elif nxt.get("tool") == "go_to" and land and isinstance((nxt.get("args") or {}).get("target"), list):
            t = nxt["args"]["target"]
            if len(t) >= 2 and all(isinstance(x, (int, float)) for x in t[:3]) and \
                    math.dist(land["pos"][:2], [float(x) for x in t[:2]]) <= AT_TARGET_M:
                out.append("first_done")
    return out


def analyse(rows: list[dict], source: str = "") -> dict:
    """All measures of one session from its slim rows (read_rows / slim). Pure: no file access."""
    rows = sorted(rows, key=lambda r: r["ts"])
    if not rows:
        return {"source": source, "asks": [], "compositions": []}
    first_ts, last_ts = rows[0]["ts"], rows[-1]["ts"]
    session = next((r for r in rows if r["kind"] == "session_start"), {})
    me = str(session.get("name") or "")

    # --- llm calls, body intervals, reflex, says, states
    llm: list[dict] = []
    last_prompt: dict[tuple, float] = {}
    body: list[dict] = []
    open_body: dict[str, dict] = {}
    left: list[dict] = []
    reflex: list[tuple[float, float]] = []
    open_reflex: dict[str, float] = {}
    fights: list[float] = []
    says: list[dict] = []
    states: list[dict] = []
    for r in rows:
        k, ts = r["kind"], r["ts"]
        if k == "prompt":
            last_prompt[(r.get("component"), r.get("ep"))] = ts
        elif k == "llm_response":
            u = r.get("usage") or {}
            lat = u.get("latency_ms")
            start = ts - lat / 1000.0 if isinstance(lat, (int, float)) else \
                last_prompt.get((r.get("component"), r.get("ep")), ts)
            llm.append({"component": r.get("component"), "model": r.get("model"), "start": start, "end": ts,
                        "ep": r.get("ep"), "usage": u, "derived": isinstance(lat, (int, float))})
        elif k == "tool_call" and r.get("task_id") and not r.get("read_only"):
            b = {"start": ts, "end": None, "tool": r.get("tool"), "args": r.get("args"), "ep": r.get("ep"),
                 "task_id": r["task_id"]}
            body.append(b)
            open_body[r["task_id"]] = b
            for lr in left:  # a command left running ends when the next one is sent at the latest
                if lr["end"] is None:
                    lr["end"] = ts
        elif k == "tool_result" and r.get("task_id") in open_body:
            b = open_body.pop(r["task_id"])
            b.update(end=ts, ok=r.get("ok"), reason=r.get("reason"), detail=r.get("detail"))
        elif k == "action_left_running":
            left.append({"start": ts, "end": None, "id": r.get("id"), "tool": r.get("tool")})
        elif k == "bridge_late_result":
            for lr in left:
                if lr["end"] is None and lr["id"] == r.get("id"):
                    lr["end"] = ts
        elif k == "event" and r.get("type") == "activity":
            what, _, phase = str(r.get("what")).rpartition("_")
            at = float(r["ets"]) if isinstance(r.get("ets"), (int, float)) and abs(r["ets"] - ts) < 120 else ts
            if phase == "started":
                open_reflex.setdefault(what, at)
                if what == "combat":
                    fights.append(at)
            elif what in open_reflex:
                a = open_reflex.pop(what)
                reflex.append((a, max(at, a)))
        elif k == "say":
            says.append({"ts": ts, "ep": r.get("ep"), "text": r.get("text"), "ok": None})
        elif k == "say_result":
            s = next((s for s in reversed(says) if s["ok"] is None), None)
            if s:
                s.update(ok=r.get("ok"), heard=ts)
        elif k == "state":
            states.append(r)
    for b in body:
        if b["end"] is None:
            b.update(end=last_ts, open=True)
    for lr in left:
        lr["end"] = min(lr["end"] if lr["end"] is not None else last_ts, lr["start"] + LEFT_RUNNING_CAP_S)
    for what, a in open_reflex.items():
        reflex.append((a, last_ts))
    body_iv = union([(b["start"], b["end"]) for b in body] + [(x["start"], x["end"]) for x in left] + reflex)
    ctrl_iv = union((c["start"], c["end"]) for c in llm if c["component"] == "controller")
    plan_iv = union((c["start"], c["end"]) for c in llm if c["component"] in PLANNER)
    learn_iv = union((c["start"], c["end"]) for c in llm if c["component"] in LEARNER)

    # --- compositions
    comps: list[dict] = []
    open_plan: dict[str | None, dict] = {}
    open_dir: dict | None = None
    for r in rows:
        k, ts, ep = r["kind"], r["ts"], r.get("ep")
        if k == "prompt" and r.get("component") == "planner":
            if ep in open_plan:
                comps.append(open_plan.pop(ep))
            open_plan[ep] = {"kind": "planner", "start": ts, "end": ts, "ep": ep, "calls": [], "outcome": None,
                             "decision": "replan" if r.get("replan") else "plan"}
        elif k == "llm_response" and r.get("component") == "planner" and ep in open_plan:
            c = open_plan[ep]
            c["calls"].append(r.get("usage") or {})
            c["end"] = ts
        elif k == "plan_invalid" and ep in open_plan:
            open_plan[ep]["invalid"] = open_plan[ep].get("invalid", 0) + 1
        elif ep in open_plan and k in ("tool_call", "say", "prompt", "request_state"):
            c = open_plan.pop(ep)
            c["outcome"] = "plan" if k == "tool_call" else "no_plan"
            comps.append(c)
        if k == "director_dispatch":
            if open_dir:
                open_dir["outcome"] = open_dir["outcome"] or "superseded"
                comps.append(open_dir)
            open_dir = {"kind": "director", "start": ts, "end": ts, "ep": None, "calls": [], "outcome": None,
                        "task": r.get("task"), "decision": r.get("decision")}
        elif k == "llm_response" and r.get("component") == "director" and open_dir:
            open_dir["calls"].append(r.get("usage") or {})
            open_dir["ep"] = open_dir["ep"] or ep
        elif k in ("director_decision", "director_discarded", "director_decision_failed", "director_timeout") and open_dir:
            open_dir.update(end=ts, outcome={"director_decision": "plan", "director_discarded": "discarded",
                                             "director_decision_failed": "failed", "director_timeout": "timeout"}[k])
            comps.append(open_dir)
            open_dir = None
    for c in open_plan.values():
        c["outcome"] = c["outcome"] or ("plan" if c["calls"] else "cut")
        comps.append(c)
    if open_dir:
        open_dir.update(end=last_ts, outcome="cut")
        comps.append(open_dir)
    comps.sort(key=lambda c: c["start"])

    for c in comps:
        c["secs"] = round(c["end"] - c["start"], 2)
        c["stand"] = round((c["end"] - c["start"]) - overlap(c["start"], c["end"], body_iv), 2)
        c["usd"] = round(sum(float(u.get("cost_usd") or 0) for u in c["calls"]), 5)
        basis = next((s for s in reversed(states) if c["start"] - BASIS_MAX_S <= s["ts"] <= c["start"] + 0.01), None)
        nxt = next((b for b in body if b["start"] >= c["end"] - 0.01), None)
        lim = min(c["end"] + LAND_MAX_S, nxt["start"] + 0.01 if nxt else c["end"] + LAND_MAX_S)
        land = next((s for s in states if c["end"] - 0.01 <= s["ts"] <= lim), None)
        c["next"] = ({"tool": nxt["tool"], "args": nxt["args"], "after_s": round(nxt["start"] - c["end"], 2),
                      "ok": nxt.get("ok"), "reason": nxt.get("reason")} if nxt else None)
        c["basis_known"] = bool(basis and land)
        c["stale"] = stale_reasons(c, basis, land, fights, nxt if c["outcome"] == "plan" else None) \
            if c["outcome"] == "plan" else []
        c["body_during"] = round(overlap(c["start"], c["end"], body_iv), 2)
        # the whole stand the plan sits in: from the end of the body work before it to the first command after it
        last_end = max((y for x, y in body_iv if y <= c["start"] + 0.01), default=None)
        c["idle_before_s"] = round(c["start"] - last_end, 2) if last_end is not None else None
        c["gap_s"] = round(nxt["start"] - last_end, 2) if (nxt and last_end is not None and c["body_during"] < 0.5) \
            else None
        c["source"] = source

    # --- asks
    eps: dict[str, dict] = {}
    for r in rows:
        ep = r.get("ep")
        if not ep:
            continue
        e = eps.setdefault(ep, {"first": r["ts"], "last": r["ts"], "heard": None, "controller": False,
                                "decisions": []})
        e["last"] = r["ts"]
        if r["kind"] == "event" and r.get("type") == "chat_heard" and e["heard"] is None:
            e["heard"] = r
        elif r["kind"] == "prompt" and r.get("component") == "controller":
            e["controller"] = True
        elif r["kind"] == "chat_decision":
            e["decisions"].append(r.get("decision"))
    ask_eps = sorted((ep for ep, e in eps.items() if ep.startswith("chat-") and e["heard"] and e["controller"]
                      and (e["heard"].get("player") or "") != me
                      and not ("ignored" in e["decisions"] and "addressed" not in e["decisions"])),
                     key=lambda ep: eps[ep]["heard"]["ts"])
    asks: list[dict] = []
    for i, ep in enumerate(ask_eps):
        e = eps[ep]
        t0 = e["heard"]["ts"]
        cap = eps[ask_eps[i + 1]]["heard"]["ts"] if i + 1 < len(ask_eps) else last_ts
        # the window: to the next ask, cut back to the last row of any episode (or a Director row) before it, so
        # telemetry alone after the work (pings, dropped events) does not count as his time
        end = max([t0] + [r["ts"] for r in rows if t0 <= r["ts"] <= cap
                          and (r.get("ep") or r["kind"].startswith("director_"))])
        mine = lambda x: x == ep or (x or "").startswith("board-")
        acts = [b for b in body if t0 <= b["start"] <= end and mine(b["ep"]) and b["tool"] not in NON_ACT]
        said = [s for s in says if t0 <= s["ts"] <= end and s["ep"] == ep and s.get("ok")]
        cs = [c for c in comps if t0 <= c["start"] <= end]
        plan_calls = [c for c in llm if c["component"] in PLANNER and t0 <= c["end"] <= end]
        ctrl_calls = [c for c in llm if c["component"] == "controller" and t0 <= c["end"] <= end]
        learn_calls = [c for c in llm if c["component"] in LEARNER and t0 <= c["end"] <= end]
        landed = [c for c in cs if c["outcome"] == "plan"]
        first_plan = landed[0]["end"] if landed else None
        after_plan = next((b for b in acts if first_plan is not None and b["start"] >= first_plan - 0.01), None)
        ask_id = f"{source}/{ep}" if source else ep
        asks.append({
            "id": ask_id, "source": source, "ts": t0, "utc": utc(t0), "player": e["heard"].get("player"),
            "text": e["heard"].get("text", "")[:100], "window_s": round(end - t0, 1),
            "planner": bool(cs),
            "first_act_s": round(acts[0]["start"] - t0, 2) if acts else None,
            "first_act": acts[0]["tool"] if acts else None,
            "act_before_plan": bool(acts and cs and acts[0]["start"] < cs[0]["start"]),
            "first_say_s": round(said[0]["ts"] - t0, 2) if said else None,
            "first_act_after_plan_s": round(after_plan["start"] - t0, 2) if after_plan else None,
            "stand_plan_s": round(sum(max(0.0, min(c["end"], end) - max(c["start"], t0)) -
                                      overlap(max(c["start"], t0), min(c["end"], end), body_iv) for c in cs), 2),
            "compositions": len(cs), "planner_calls": len(plan_calls),
            "planner_tokens": {k: sum(int((c["usage"] or {}).get(k) or 0) for c in plan_calls)
                               for k in ("prompt", "completion", "cached")},
            "planner_usd": round(sum(float((c["usage"] or {}).get("cost_usd") or 0) for c in plan_calls), 5),
            "controller_calls": len(ctrl_calls),
            "controller_usd": round(sum(float((c["usage"] or {}).get("cost_usd") or 0) for c in ctrl_calls), 5),
            "learner_calls": len(learn_calls),
            "share": shares(t0, end, body_iv, ctrl_iv, plan_iv, learn_iv),
            "stale": sum(1 for c in landed if set(c["stale"]) - {"bag_minor"}),
            "landed": len(landed),
        })
    return {"source": source, "asks": asks, "compositions": comps,
            "planner_api": [c for c in llm if c["component"] in PLANNER],
            "controller_api": [c for c in llm if c["component"] == "controller"]}


# ------------------------------------------------------------------ statistics
def utc(ts: float | None) -> str | None:
    return None if ts is None else datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def summ(xs: Iterable[float | None]) -> dict:
    """n, median, p90 (nearest rank), worst, mean, sd of the values that are not None."""
    v = sorted(float(x) for x in xs if x is not None)
    if not v:
        return {"n": 0, "median": None, "p90": None, "worst": None, "mean": None, "sd": None}
    return {"n": len(v), "median": round(statistics.median(v), 2), "p90": round(v[max(0, math.ceil(0.9 * len(v)) - 1)], 2),
            "worst": round(v[-1], 2), "mean": round(statistics.fmean(v), 2),
            "sd": round(statistics.stdev(v), 2) if len(v) > 1 else 0.0}


def need_mean(sd: float, delta: float, alpha: float = 0.05, power: float = 0.8) -> int:
    """Asks per arm to tell two means apart by ``delta`` (two-sided, normal approximation, equal SD):
    n = 2 (z_{1-a/2} + z_{power})^2 sd^2 / delta^2."""
    from statistics import NormalDist
    z = NormalDist().inv_cdf(1 - alpha / 2) + NormalDist().inv_cdf(power)
    return math.ceil(2 * z * z * sd * sd / (delta * delta))


def aggregate(results: list[dict]) -> dict:
    asks = [a for r in results for a in r["asks"]]
    comps = [c for r in results for c in r["compositions"]]
    papi = [c for r in results for c in r["planner_api"]]
    capi = [c for r in results for c in r["controller_api"]]
    out: dict = {"asks": len(asks), "files": len(results)}
    for label, sel in (("all", asks), ("with_planner", [a for a in asks if a["planner"]]),
                       ("without_planner", [a for a in asks if not a["planner"]])):
        tot = {k: sum(a["share"][k] for a in sel) for k in ("body_and_planner", "body", "controller", "planner",
                                                             "learner", "nothing")}
        wall = sum(tot.values()) or 1.0
        out[label] = {
            "n": len(sel),
            "no_act": sum(1 for a in sel if a["first_act_s"] is None),
            "first_act_s": summ(a["first_act_s"] for a in sel),
            "first_act_log_sd": round(statistics.stdev([math.log(a["first_act_s"]) for a in sel
                                                        if a["first_act_s"] and a["first_act_s"] > 0]), 3)
            if sum(1 for a in sel if a["first_act_s"]) > 2 else None,
            "first_say_s": summ(a["first_say_s"] for a in sel),
            "first_act_after_plan_s": summ(a["first_act_after_plan_s"] for a in sel),
            "act_before_plan": sum(1 for a in sel if a["act_before_plan"]),
            "first_act_le_10s": sum(1 for a in sel if a["first_act_s"] is not None and a["first_act_s"] <= 10),
            "stand_plan_s": summ(a["stand_plan_s"] for a in sel if a["planner"]),
            "compositions_per_ask": summ(a["compositions"] for a in sel),
            "planner_calls_per_ask": summ(a["planner_calls"] for a in sel),
            "planner_usd_per_ask": summ(a["planner_usd"] for a in sel),
            "planner_tokens": {k: sum(a["planner_tokens"][k] for a in sel) for k in ("prompt", "completion", "cached")},
            "controller_calls_per_ask": summ(a["controller_calls"] for a in sel),
            "controller_usd_per_ask": summ(a["controller_usd"] for a in sel),
            "share_s": {k: round(v, 1) for k, v in tot.items()},
            "share_pct": {k: round(100 * v / wall, 1) for k, v in tot.items()},
        }
    landed = [c for c in comps if c["outcome"] == "plan"]
    known = [c for c in landed if c["basis_known"]]
    stale = [c for c in landed if set(c["stale"]) - {"bag_minor"}]
    reasons: dict[str, int] = {}
    for c in landed:
        for s in c["stale"]:
            reasons[s] = reasons.get(s, 0) + 1
    out["compositions"] = {
        "n": len(comps), "by_kind": {k: sum(1 for c in comps if c["kind"] == k) for k in ("planner", "director")},
        "by_decision": {d: sum(1 for c in comps if str(c.get("decision")) == d)
                        for d in sorted({str(c.get("decision")) for c in comps})},
        "outcomes": {o: sum(1 for c in comps if c["outcome"] == o) for o in sorted({c["outcome"] for c in comps})},
        "secs": summ(c["secs"] for c in comps), "stand": summ(c["stand"] for c in comps),
        "stand_over_5s": sum(1 for c in comps if c["stand"] > 5.0),
        "idle_before_s": summ(c["idle_before_s"] for c in comps), "gap_s": summ(c["gap_s"] for c in comps),
        "body_during_any": sum(1 for c in comps if c["body_during"] > 0.5),
        "landed": len(landed), "basis_known": len(known), "stale": len(stale), "stale_reasons": reasons,
        "usd": summ(c["usd"] for c in comps)}
    out["planner_api"] = {"n": len(papi), "latency_s": summ((c["usage"].get("latency_ms") or 0) / 1000 for c in papi
                                                           if c["usage"].get("latency_ms") is not None),
                          "prompt_tok": summ(c["usage"].get("prompt") for c in papi),
                          "completion_tok": summ(c["usage"].get("completion") for c in papi),
                          "usd": round(sum(float(c["usage"].get("cost_usd") or 0) for c in papi), 4)}
    out["controller_api"] = {"n": len(capi), "latency_s": summ((c["usage"].get("latency_ms") or 0) / 1000 for c in capi
                                                              if c["usage"].get("latency_ms") is not None),
                             "usd": round(sum(float(c["usage"].get("cost_usd") or 0) for c in capi), 4)}
    worst = sorted(comps, key=lambda c: -c["stand"])[:10]
    out["worst_stands"] = [{"source": c["source"], "utc": utc(c["start"]), "kind": c["kind"], "stand_s": c["stand"],
                            "secs": c["secs"], "calls": len(c["calls"]), "outcome": c["outcome"], "next": c["next"]}
                           for c in worst]
    out["stale_examples"] = [{"source": c["source"], "utc": utc(c["start"]), "kind": c["kind"], "stale": c["stale"],
                              "next": c["next"]} for c in stale[:10]]
    return out


# ------------------------------------------------------------------ files
def parse_when(s: str | None) -> float | None:
    if not s:
        return None
    s = s.rstrip("Z")
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M", "%Y-%m-%d"):
        try:
            return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc).timestamp()
        except ValueError:
            continue
    raise ValueError(f"not a date: {s!r} (YYYY-MM-DD or YYYY-MM-DDTHH:MM, UTC)")


_NAME = re.compile(r"brain-live-(\d{8})-(\d{6})-\d+\.jsonl$")


def pick_files(since: float | None, until: float | None, logs: Path | None = None, now: float | None = None) -> list[Path]:
    """Brain logs whose name (local time, about UTC+1) lies within a day of the window; never one written in the
    last RECENT_S (a live brain may own it)."""
    now = time.time() if now is None else now
    logs = LOGS if logs is None else logs
    out = []
    for p in sorted(logs.glob("brain-live-*.jsonl")):
        m = _NAME.search(p.name)
        if not m:
            continue
        t = datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M%S").replace(tzinfo=timezone.utc).timestamp()
        if since is not None and t < since - 86400 or until is not None and t > until + 86400:
            continue
        try:
            if now - p.stat().st_mtime < RECENT_S:
                continue
        except OSError:
            continue
        out.append(p)
    return out


def run(since: float | None, until: float | None, grep: str | None = None, logs: Path | None = None) -> list[dict]:
    rx = re.compile(grep, re.I) if grep else None
    out = []
    for p in pick_files(since, until, logs):
        res = analyse(list(read_rows(p)), p.stem.replace("brain-live-", ""))
        keep = [a for a in res["asks"] if (since is None or a["ts"] >= since) and (until is None or a["ts"] < until)
                and (rx is None or rx.search(a["text"] or ""))]
        if not keep:
            continue
        lo, hi = min(a["ts"] for a in keep), max(a["ts"] + a["window_s"] for a in keep)
        res["asks"] = keep
        res["compositions"] = [c for c in res["compositions"] if lo <= c["start"] <= hi]
        res["planner_api"] = [c for c in res["planner_api"] if lo <= c["end"] <= hi]
        res["controller_api"] = [c for c in res["controller_api"] if lo <= c["end"] <= hi]
        out.append(res)
    return out


# ------------------------------------------------------------------ output
def _s(d: dict) -> str:
    return "n=0" if not d["n"] else f"n={d['n']} median {d['median']} p90 {d['p90']} worst {d['worst']}"


def render(agg: dict) -> str:
    L = [f"asks {agg['asks']} in {agg['files']} files"]
    for label in ("all", "with_planner", "without_planner"):
        g = agg[label]
        L += [f"\n[{label}] n={g['n']} (no act at all: {g['no_act']})",
              f"  1 first act s        {_s(g['first_act_s'])}  (<=10 s: {g['first_act_le_10s']} of {g['n']})",
              f"    first line said s  {_s(g['first_say_s'])}",
              f"    first act after the plan landed s {_s(g['first_act_after_plan_s'])}; acted before the plan: {g['act_before_plan']}",
              f"  2 stand while planning s per ask {_s(g['stand_plan_s'])}",
              f"  3 compositions/ask   {_s(g['compositions_per_ask'])}; planner API calls/ask {_s(g['planner_calls_per_ask'])}",
              f"    planner $/ask      {_s(g['planner_usd_per_ask'])}; tokens {g['planner_tokens']}",
              f"    controller calls/ask {_s(g['controller_calls_per_ask'])}; $/ask {_s(g['controller_usd_per_ask'])}",
              f"  share of wall %      {g['share_pct']}"]
    c = agg["compositions"]
    L += [f"\n[compositions] n={c['n']} {c['by_kind']} {c['by_decision']} outcomes {c['outcomes']}",
          f"  wall s {_s(c['secs'])}", f"  stand s {_s(c['stand'])}  (over 5 s: {c['stand_over_5s']} of {c['n']}; "
                                       f"body ran during {c['body_during_any']})",
          f"  idle before it s {_s(c['idle_before_s'])}; whole gap last command end to next command s {_s(c['gap_s'])}",
          f"  4 stale: {c['stale']} of {c['landed']} landed (state known for {c['basis_known']}); reasons {c['stale_reasons']}",
          f"[planner API] n={agg['planner_api']['n']} latency s {_s(agg['planner_api']['latency_s'])} ${agg['planner_api']['usd']}",
          f"[controller API] n={agg['controller_api']['n']} latency s {_s(agg['controller_api']['latency_s'])} ${agg['controller_api']['usd']}",
          "\nworst stands while a plan was composed:"]
    for w in agg["worst_stands"]:
        L.append(f"  {w['stand_s']:7.1f} s  {w['source']}  {w['utc']}  {w['kind']} ({w['calls']} calls, {w['outcome']})  "
                 f"next: {json.dumps(w['next'])[:140]}")
    if agg["stale_examples"]:
        L.append("stale plans:")
        for w in agg["stale_examples"]:
            L.append(f"  {w['source']}  {w['utc']}  {w['kind']} {w['stale']}  next: {json.dumps(w['next'])[:140]}")
    return "\n".join(L)


def ask_timeline(ask_id: str, logs: Path | None = None) -> str:
    """One ask: its rows in time order, with the class of each stretch."""
    stem, _, ep = ask_id.partition("/")
    if not ep:
        raise SystemExit("ASK_ID is <file stem>/<episode>, e.g. 20261115-235756-19752/chat-0001-52b5")
    path = (LOGS if logs is None else logs) / f"brain-live-{stem}.jsonl"
    rows = list(read_rows(path))
    res = analyse(rows, stem)
    a = next((x for x in res["asks"] if x["id"] == ask_id), None)
    if a is None:
        raise SystemExit(f"no ask {ep} in {path.name}; asks there: {[x['id'] for x in res['asks']][:20]}")
    t0, t1 = a["ts"], a["ts"] + a["window_s"]
    L = [f"{a['id']}  {a['utc']} UTC  {a['player']}: {a['text']!r}",
         f"window {a['window_s']} s; first act {a['first_act_s']} s ({a['first_act']}); first line {a['first_say_s']} s; "
         f"stand while planning {a['stand_plan_s']} s; compositions {a['compositions']}; planner calls {a['planner_calls']} "
         f"${a['planner_usd']}; controller calls {a['controller_calls']} ${a['controller_usd']}; stale {a['stale']} of {a['landed']}",
         f"share s {a['share']}", ""]
    for r in rows:
        if not (t0 - 0.5 <= r["ts"] <= t1 + 0.5) or r["kind"] in ("state", "request_state", "chat_decision"):
            continue
        k, x = r["kind"], ""
        if k == "event":
            x = f"{r.get('type')} {r.get('player') or ''} {r.get('text') or r.get('what') or ''}"[:100]
        elif k in ("prompt", "llm_response"):
            u = r.get("usage") or {}
            x = f"{r.get('component')}" + (f" {u.get('latency_ms')} ms ${u.get('cost_usd')}" if k == "llm_response" else "")
        elif k in ("tool_call", "tool_result"):
            x = f"{r.get('tool')} {json.dumps(r.get('args'))[:80] if k == 'tool_call' else (r.get('ok'), r.get('reason'), r.get('detail', '')[:60])}"
            x += "" if r.get("task_id") else " (read)"
        elif k == "say":
            x = r.get("text") or ""
        elif k.startswith("director_"):
            x = f"{r.get('task')} {r.get('decision') or ''}"
        L.append(f"{r['ts'] - t0:8.1f}  {(r.get('ep') or '-')[:18]:18}  {k:20} {x}")
    for c in res["compositions"]:
        if t0 <= c["start"] <= t1:
            L.append(f"composition {c['kind']} at {c['start'] - t0:.1f} s: {c['secs']} s, stand {c['stand']} s, "
                     f"{len(c['calls'])} calls ${c['usd']}, {c['outcome']}, stale {c['stale']}, next {c['next']}")
    return "\n".join(L)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="tools.think_act", description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("report", help="the measures over a time window")
    r.add_argument("--since")
    r.add_argument("--until")
    r.add_argument("--grep", help="only asks whose words match this regex (case-insensitive)")
    r.add_argument("--json", action="store_true")
    r.add_argument("--asks", action="store_true", help="with --json: every ask's row too")
    a = sub.add_parser("ask", help="one ask's timeline")
    a.add_argument("ask_id")
    ns = ap.parse_args(argv)
    if ns.cmd == "ask":
        print(ask_timeline(ns.ask_id))
        return 0
    res = run(parse_when(ns.since), parse_when(ns.until), ns.grep)
    agg = aggregate(res)
    if ns.json:
        if ns.asks:
            agg["ask_rows"] = [x for r_ in res for x in r_["asks"]]
        print(json.dumps(agg, indent=1, default=str))
    else:
        print(render(agg))
    return 0


if __name__ == "__main__":
    sys.exit(main())

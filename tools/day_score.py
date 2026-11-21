"""The scorer of a day of play (goal stage D): one broad ask run for hours on one world (tools/job_run.py `day`).

    .venv\\Scripts\\python.exe -m tools.day_score report                 # every day run, one line each
    .venv\\Scripts\\python.exe -m tools.day_score show RUN               # one run's report
    .venv\\Scripts\\python.exe -m tools.day_score rescore RUN [--write]  # again from its record and its brain logs

From the run's record (job_run.run_job with day: the trace of get_state samples, his stock every 10 minutes, the tool
calls and the stands), its brain logs (deaths, his positions between two samples) and nothing he said:
- progression: the game's power level at the start, the end and over time; each skill's level and XP gained, the
  total level; the regions he entered along his positions (brain/places.py, data/places_<build>.json);
- deaths: a companion_down result, a fight that ended "died", a death_during_call row, a sample that read him dead;
  merged when within DEATH_MERGE_S of each other (one death fails every call until the respawn);
- misses per 5 minutes of work and idle (total stand, the longest, stands over 5 s): job_run's own counts, unchanged;
- food and drink he carried and what his chests held, over the day (job_run.stock_read, as a sequence reads it);
- spend (model calls and $ from the brain log rows, chat_ladder.model_calls);
- Luis's baselines (docs/BASELINES-2026-11-01-luis.md): what exists is compared, what does not is said.

Writes one row to logs/evals/day_runs.jsonl (the score) and the record to logs/evals/day_runs/<run>.json. failure_ledger
scan reads the rows (ledger_recs): a day with a death or a stand over 5 s gets one ledger row, its first wrong.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

from brain import paths

ROOT = paths.REPO_ROOT
DAY_OUT = ROOT / "logs" / "evals" / "day_runs.jsonl"
RECORD_DIR = ROOT / "logs" / "evals" / "day_runs"
LUIS_TASKS = ROOT / "evals" / "baselines" / "luis_20261101_tasks.json"   # committed: per task, from the recorder
LUIS_STANDARD = paths.LIVE_ROOT / "logs" / "reports" / "standard-luis-2026-11-01.json"  # the VM's: deaths per window
# No helper in tools/ merged deaths at 30 s (coplay_ladder.death_times merges at 15 s, ask_ends at 60 s): the brief's
# figure. A death fails every call until the respawn (companion_down), and the fight's end, the call's result and the
# next sample all report the same one within seconds
DEATH_MERGE_S = 30.0
QUIET_S = 40.0           # quest_run.QUIET_S: a stand this long ended a trial "quiet"; a day goes on, and counts them


# ------------------------------------------------------------------ one sample (job_run.run_job calls this per read)
def _num(v: Any) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def point(raw: dict | None, snap: dict, t: float) -> dict:
    """One get_state read as the trace keeps it: {t, pos, pl, total_level, skills {name: [level, xp]}, vitals,
    food, drink, dead}. raw is the get_state reply (skills and total_level are not in the snapshot)."""
    d = raw or {}
    if isinstance(d.get("data"), dict) and "ok" in d:
        d = d["data"]
    skills = {}
    for r in d.get("skills") or []:
        if isinstance(r, dict) and (r.get("skill") or r.get("name")):
            skills[str(r.get("skill") or r.get("name"))] = [_num(r.get("level")), _num(r.get("xp"))]
    pos = snap.get("position")
    cons = snap.get("consumables") or {}
    out = {"t": round(float(t), 1),
           "pos": [round(float(v), 1) for v in pos[:3]] if isinstance(pos, (list, tuple)) and len(pos) >= 2 else None,
           "pl": snap.get("power_level"), "total_level": _num(d.get("total_level")), "skills": skills or None,
           "vitals": snap.get("vitals"), "food": cons.get("food"), "drink": cons.get("drink"),
           "dead": bool(snap.get("dead"))}
    return out


# ------------------------------------------------------------------ how it ended
def end_class(rec: dict, job_deadline: float | None = None) -> tuple[str, str]:
    """(budget | spend cap | harness, words). The budget is the day's own end; the spend cap (--usd, --max-haiku) and a
    harness fault (the stop file, a window that cut the budget, anything else) are the run's."""
    why = rec.get("ended")
    budget = (rec.get("day") or {}).get("budget_s")
    wall = rec.get("wall_s")
    if why == "deadline":
        if job_deadline is not None and budget is not None and float(budget) < float(job_deadline) - 1:
            return "harness", f"the window cut the budget from {float(job_deadline):.0f} to {float(budget):.0f} s"
        return "budget", f"ran its budget ({wall} s)"
    if why in ("budget", "haiku cap"):
        return "spend cap", f"the run's spend cap ({'--usd' if why == 'budget' else '--max-haiku'}) at {wall} s"
    if why == "stopped":
        return "harness", f"stopped by the stop file at {wall} s"
    return "harness", f"ended {why!r} at {wall} s"


def not_counted(rec: dict, job_deadline: float | None = None) -> str | None:
    """Why a day says nothing about him as a whole day (a run fault, CLAUDE.md section 2 rule 3), or None. What he did
    until then is still scored and reported."""
    if rec.get("not_counted"):
        return rec["not_counted"]
    cls, words = end_class(rec, job_deadline)
    if cls == "budget":
        return None
    return f"{words}: the day was cut short by the run, not by him (rule 3); what he did until then is scored"


# ------------------------------------------------------------------ progression
def power(trace: list[dict]) -> dict:
    """The game's power level: at the start and the end (first and last read that has it), the most, and the series
    at each change [[t, pl]]."""
    pts = [(p["t"], p["pl"]) for p in trace if _num(p.get("pl")) is not None]
    series = []
    for t, v in pts:
        if not series or series[-1][1] != v:
            series.append([t, v])
    return {"start": pts[0][1] if pts else None, "end": pts[-1][1] if pts else None,
            "max": max((v for _, v in pts), default=None), "gained": (pts[-1][1] - pts[0][1]) if pts else None,
            "series": series, "reads": len(pts)}


def skills(trace: list[dict]) -> dict:
    """Each skill's level and XP at the first and the last read that has it, and what was gained; the total level."""
    first: dict[str, list] = {}
    last: dict[str, list] = {}
    for p in trace:
        for name, (lv, xp) in (p.get("skills") or {}).items():
            first.setdefault(name, [lv, xp])
            last[name] = [lv, xp]
    rows = {}
    for name in sorted(last):
        (l0, x0), (l1, x1) = first[name], last[name]
        rows[name] = {"level": [l0, l1], "xp": [x0, x1],
                      "levels_gained": (l1 - l0) if l0 is not None and l1 is not None else None,
                      "xp_gained": round(x1 - x0, 1) if x0 is not None and x1 is not None else None}
    tl = [p.get("total_level") for p in trace if _num(p.get("total_level")) is not None]
    gained = [r["xp_gained"] for r in rows.values() if r["xp_gained"] is not None]
    return {"skills": rows, "total_level": [tl[0], tl[-1]] if tl else None,
            "total_levels_gained": (tl[-1] - tl[0]) if tl else None,
            "xp_gained": round(sum(gained), 1) if gained else None,
            "trained": sorted(k for k, r in rows.items() if (r["xp_gained"] or 0) > 0)}


def _places():
    from tools import job_run
    return job_run._places()


def regions(positions: list[tuple[float, Any]]) -> dict:
    """The regions along his positions [(t, [x, y, ...])], in time order: each entry {region, province, power, t}
    when he came into a region he was not in at the read before; reached = the distinct ones, new = those other than
    where he started, top_power = the highest region power he stood in."""
    pl = _places()
    entries, cur = [], None
    for t, pos in sorted(((t, p) for t, p in positions if isinstance(p, (list, tuple)) and len(p) >= 2),
                         key=lambda x: x[0]):
        r = pl.region_at(pos)
        name = r.get("name") if r else None
        if name != cur and name is not None:
            entries.append({"region": name, "province": r.get("province"),
                            "power": r.get("power") if isinstance(r.get("power"), int) and r["power"] >= 0 else None,
                            "t": round(float(t), 1)})
        cur = name if name is not None else cur
    reached = list(dict.fromkeys(e["region"] for e in entries))
    start = reached[0] if reached else None
    powers = [e["power"] for e in entries if e["power"] is not None]
    return {"entries": entries, "reached": reached, "start": start, "new": [r for r in reached if r != start],
            "top_power": max(powers, default=None), "positions": len(positions)}


# ------------------------------------------------------------------ deaths
def _merge(ts: list[tuple[float, str]], gap: float = DEATH_MERGE_S) -> list[dict]:
    out: list[dict] = []
    for t, src in sorted(ts):
        if out and t - out[-1]["t_last"] <= gap:
            out[-1]["t_last"] = t
            out[-1]["sources"].append(src)
        else:
            out.append({"t": round(t, 1), "t_last": t, "sources": [src]})
    for d in out:
        d.pop("t_last")
    return out


def death_signals(rec: dict, rows: list[dict] | None = None, t0: float | None = None) -> list[tuple[float, str]]:
    """(seconds into the run, source) of every report of a death: a tool result companion_down (the record's calls,
    at their end), a sample that read him dead after one that did not (the trace), and from the brain log a fight that
    ended "died" and a death_during_call row (its ago_s back)."""
    out = []
    for c in rec.get("tool_calls") or []:
        if c.get("reason") == "companion_down":
            out.append((float(c.get("t") or 0) + float(c.get("dur_s") or 0), f"{c.get('tool')} companion_down"))
    prev = False
    for p in (rec.get("day") or {}).get("trace") or []:
        if p.get("dead") and not prev:
            out.append((float(p["t"]), "a read: dead"))
        prev = bool(p.get("dead"))
    if rows and t0 is not None:
        for r in rows:
            k = r.get("kind")
            ev = r.get("event") if k == "event" and isinstance(r.get("event"), dict) else None
            if ev and ev.get("type") == "activity" and ev.get("kind") == "combat_end" and ev.get("outcome") == "died":
                out.append((float(ev.get("ts") or r.get("ts") or 0) - t0, f"died to {ev.get('target')} ({ev.get('by')})"))
            elif k == "death_during_call":
                out.append((float(r.get("ts") or 0) - float(r.get("ago_s") or 0) - t0,
                            f"death during {r.get('tool')}: {str(r.get('cause') or '')[:80]}"))
    return [(round(t, 1), s) for t, s in out if t >= -1]


def deaths(rec: dict, rows: list[dict] | None = None, t0: float | None = None) -> dict:
    merged = _merge(death_signals(rec, rows, t0))
    return {"n": len(merged), "t": [d["t"] for d in merged], "list": merged, "merge_s": DEATH_MERGE_S,
            "brain_log_read": bool(rows)}


# ------------------------------------------------------------------ the brain log (read from the files, streamed)
READ_KINDS = ("tool_result", "event", "death_during_call", "bridge_recv", "llm_response", "prompt")
_KIND_RX = re.compile(r'"kind":\s*"([a-z_]+)"')


def brain_rows(rec: dict, log_dir: Path | None = None) -> list[dict]:
    """The rows of the run's brain logs the scorer reads (deaths; his positions in the brain's own get_state replies,
    with position and hydration only), between its t0 and its end. [] when the logs are gone."""
    t0 = (rec.get("day") or {}).get("t0")
    if t0 is None:
        return []
    t1 = float(t0) + float(rec.get("wall_s") or 0) + 5
    out = []
    for name in rec.get("brain_logs") or []:
        p = Path(log_dir or paths.log_dir()) / name
        if not p.exists():
            continue
        with open(p, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = _KIND_RX.search(line, 0, 200)
                if not m or m.group(1) not in READ_KINDS:
                    continue
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                ts = r.get("ts")
                if not isinstance(ts, (int, float)) or not float(t0) - 1 <= ts <= t1:
                    continue
                if r.get("kind") == "bridge_recv":
                    d = (r.get("msg") or {}).get("data")
                    if not (isinstance(d, dict) and "hydration" in d and isinstance(d.get("position"), list)):
                        continue
                    r = {"ts": ts, "kind": "bridge_recv", "msg": {"data": {"position": d["position"]}}}
                elif r.get("kind") == "prompt":
                    r = {k: r[k] for k in ("ts", "kind", "component", "model") if k in r}
                out.append(r)
    return sorted(out, key=lambda r: r["ts"])


def positions(rec: dict, rows: list[dict] | None = None) -> list[tuple[float, list]]:
    """His positions over the run (seconds in): the trace's samples, and the brain's own get_state replies."""
    t0 = (rec.get("day") or {}).get("t0")
    out = [(float(p["t"]), p["pos"]) for p in (rec.get("day") or {}).get("trace") or [] if p.get("pos")]
    if rows and t0 is not None:
        out += [(float(r["ts"]) - float(t0), r["msg"]["data"]["position"]) for r in rows if r.get("kind") == "bridge_recv"]
    return sorted(out, key=lambda x: x[0])


# ------------------------------------------------------------------ idle, misses, stock, spend
def idle_of(rec: dict) -> dict:
    """job_run's stands (quest_run.timeline: no tool, model call or reflex work for over 5 s), as recorded."""
    stands = rec.get("idle_over_5s") or []
    wall = float(rec.get("wall_s") or 0)
    total = rec.get("idle_total_s")
    total = float(total) if total is not None else round(sum(float(i.get("s") or 0) for i in stands), 1)
    return {"total_s": total, "longest_s": rec.get("longest_stand_s", max((i.get("s") or 0 for i in stands), default=0)),
            "stands_over_5s": len(stands),
            "per_hour": round(len(stands) / (wall / 3600.0), 1) if wall > 0 else None,
            "share": round(total / wall, 3) if wall > 0 else None,
            "quiet_spells": sum(1 for i in stands if float(i.get("s") or 0) >= QUIET_S),
            "to_end_s": next((i["s"] for i in stands if i.get("to_end")), None)}


def misses_of(rec: dict) -> dict:
    """job_run's miss count exactly (job_run.misses over the run's calls, work = active less the stands)."""
    m = rec.get("misses") or {}
    work = (float(rec.get("active_s") or 0) - float(rec.get("idle_total_s") or 0)) if rec.get("active_s") is not None else None
    kinds: dict[str, int] = {}
    for x in m.get("list") or []:
        kinds[str(x.get("kind"))] = kinds.get(str(x.get("kind")), 0) + 1
    return {"n": m.get("n"), "per_5min": m.get("per_5min"), "work_s": round(work, 1) if work is not None else None,
            "kinds": dict(sorted(kinds.items(), key=lambda kv: -kv[1]))}


def stock_of(rec: dict) -> dict:
    """Food and drink he carried at every sample (the trace) and his stock reads every 10 minutes (carried and in his
    chests, read from the game), at the start, the end and over the day."""
    d = rec.get("day") or {}
    reads = []
    for s in d.get("stock") or []:
        c = s.get("consumables") or {}
        reads.append({"t": s.get("t"), "food": c.get("food"), "drink": c.get("drink"),
                      "chest_food": s.get("chest_food"), "chest_drink": s.get("chest_drink"),
                      "chests": {cid: {k: r.get(k) for k in ("food", "drink", "items") if r.get(k) is not None}
                                 for cid, r in (s.get("chests") or {}).items() if r.get("read")},
                      "chests_unread": sorted(cid for cid, r in (s.get("chests") or {}).items() if not r.get("read")),
                      **({"unread": s["unread"]} if s.get("unread") else {})})
    carried = [[p["t"], p.get("food"), p.get("drink")] for p in d.get("trace") or []
               if p.get("food") is not None or p.get("drink") is not None]
    good = [r for r in reads if not r.get("unread")]
    return {"reads": reads, "carried_series": carried,
            "start": good[0] if good else None, "end": good[-1] if good else None,
            "low_food": min((x[1] for x in carried if x[1] is not None), default=None),
            "low_drink": min((x[2] for x in carried if x[2] is not None), default=None)}


def first_action(rec: dict) -> float | None:
    """When his first world action started (seconds after the ask): the first call that is not a read or a line, as
    Luis's first_action_s is his first move or press after his own start marker."""
    from tools import standard_score as ss
    ts = [float(c["t"]) for c in rec.get("tool_calls") or []
          if c.get("t") is not None and c.get("tool") not in ss.READ_ONLY_TOOLS and c.get("tool") != "say"]
    return min(ts, default=None)


def spend_of(rec: dict, rows: list[dict] | None = None) -> dict:
    out = {"usd": rec.get("usd"), "haiku": rec.get("haiku"), "sonnet": rec.get("sonnet"), "from": "record"}
    if rows and any(r.get("kind") == "llm_response" for r in rows):
        from tools import chat_ladder as cl
        c = cl.model_calls(rows)
        out.update(usd=c["usd"], haiku=c["haiku"], sonnet=c["sonnet"], **{"from": "brain log"})
    wall = float(rec.get("wall_s") or 0)
    if isinstance(out["usd"], (int, float)) and wall > 0:
        out["usd_per_hour"] = round(out["usd"] / (wall / 3600.0), 3)
    return out


# ------------------------------------------------------------------ Luis's baselines
def _read_json(p: Path) -> dict | None:
    try:
        return json.loads(Path(p).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def luis(tasks_path: Path | None = None, standard_path: Path | None = None, base: dict | None = None) -> dict:
    """What Luis's recording of 2026-11-01 gives that a day can be held against (docs/BASELINES-2026-11-01-luis.md):
    his 41 tasks (evals/baselines/luis_20261101_tasks.json), the windows the human bar is built from
    (data/baselines/luis-2026-11-01.json), and the deaths per window of the standard report when it is on this VM.
    Each figure says how it was measured. Nothing per hour of progression exists there: missing says so."""
    from tools import quest_run as q
    tasks = (_read_json(tasks_path or LUIS_TASKS) or {}).get("tasks") or []
    b = base if base is not None else (_read_json(q.BASELINE) or {})
    wins = b.get("windows") or []
    task_s = sum(float(t.get("duration_s") or 0) for t in tasks)
    out: dict = {"source": "docs/BASELINES-2026-11-01-luis.md", "tasks": len(tasks), "task_s": round(task_s, 1)}
    if wins:
        work = sum(float(w.get("work_s") or 0) for w in wins)
        idle = sum(float(w.get("idle_s") or 0) for w in wins)
        wall = sum(float(w.get("wall_s") or 0) for w in wins)
        mis = sum(int(w.get("misses") or 0) for w in wins)
        presses = sum(int(w.get("presses") or 0) for w in wins)
        out["idle"] = {"share": round(idle / wall, 3) if wall else None, "idle_s": round(idle, 1),
                       "wall_s": round(wall, 1),
                       "how": "Luis standing still 2 s or more with no press, action or inventory change (standard_score "
                              "idle_s) over his task windows; not the day's measure, where a stand is no tool, model "
                              "call or reflex work for over 5 s"}
        out["press_misses"] = {"n": mis, "presses": presses,
                               "per_5min": round(mis / (work / 300.0), 2) if work else None,
                               "how": "an interact press that got nothing within 1.5 s (opening a station counts too), "
                                      "per 5 min of task work: not the harness's miss (a failed world action)"}
    if tasks:
        stands = [s for t in tasks for s in t.get("stands_over_5s") or []]
        fa = sorted(float(t["first_action_s"]) for t in tasks if _num(t.get("first_action_s")) is not None)
        out["stands_over_5s"] = {"n": len(stands), "task_s": round(task_s, 1),
                                 "how": "standing over 5 s by his speed alone, working or not (chopping, crafting, "
                                        "building are stands): the bar for Claude is no stand over 5 s without work"}
        out["first_action_median_s"] = fa[len(fa) // 2] if fa else None
        hp = [t.get("hp") for t in tasks if isinstance(t.get("hp"), list) and t["hp"]]
        out["lowest_hp"] = min((min(h) for h in hp), default=None)
    std = _read_json(standard_path or LUIS_STANDARD)
    if std and std.get("windows"):
        out["deaths"] = {"n": sum(int(w.get("deaths") or 0) for w in std["windows"]), "windows": len(std["windows"]),
                         "how": "death rows of the vitals log in his task windows (logs/reports/standard-luis-2026-11-01"
                                ".json)"}
        runs = [r for w in std["windows"] for r in w.get("idle_runs") or []]
        out["idle"] = {**out.get("idle", {}), "longest_s": max(runs, default=0.0)}
    elif out.get("lowest_hp") is not None:
        out["deaths"] = {"n": None, "how": f"no death count on this machine; his health read no lower than "
                                           f"{out['lowest_hp']} in any task (min and max per task)"}
    out["missing"] = ["power level per hour", "skill XP or levels per hour", "regions per hour", "deaths per hour",
                      "food and drink carried or stored"]
    out["missing_why"] = ("his recording is 41 marked tasks in 41 minutes on the dev world (12:40-13:21 UTC); it reads "
                          "no power level, no skill, no region and no stock, and no day of his longer than that exists")
    return out


def compare(sc: dict, base: dict) -> list[dict]:
    """Each figure of the day beside Luis's, where his exists; where it does not, the row says so."""
    rows = []
    hb = sc.get("human") or {}
    rows.append({"what": "time (Luis's unit times over his successful steps: quest_run.human_bar)",
                 "day": sc.get("active_s"), "luis": hb.get("human_s"),
                 "ratio": sc.get("ratio"), "note": "a task's bar is 1.5x his time; a day has no task markers"})
    fa = base.get("first_action_median_s")
    rows.append({"what": "first action after the ask (s)", "day": sc.get("first_action_s"), "luis": fa,
                 "note": "Luis's median over 41 tasks, from his own start line; the bar allows model latency: about 3 s"})
    i = base.get("idle") or {}
    rows.append({"what": "idle share", "day": (sc.get("idle") or {}).get("share"), "luis": i.get("share"),
                 "note": i.get("how")})
    rows.append({"what": "stands over 5 s", "day": (sc.get("idle") or {}).get("stands_over_5s"),
                 "luis": (base.get("stands_over_5s") or {}).get("n"),
                 "note": (f"his in {((base.get('stands_over_5s') or {}).get('task_s') or 0) / 60:.1f} min of tasks; "
                          + str((base.get("stands_over_5s") or {}).get("how")))})
    pm = base.get("press_misses") or {}
    rows.append({"what": "misses per 5 min of work", "day": (sc.get("misses") or {}).get("per_5min"),
                 "luis": pm.get("per_5min"), "note": pm.get("how")})
    dd = base.get("deaths") or {}
    rows.append({"what": "deaths", "day": (sc.get("deaths") or {}).get("n"), "luis": dd.get("n"),
                 "note": (f"in his {dd.get('windows')} task windows ({base.get('task_s', 0) / 60:.1f} min); "
                          if dd.get("windows") else "") + str(dd.get("how") or "not recorded")})
    for what in base.get("missing") or []:
        rows.append({"what": what, "day": None, "luis": None, "note": "no baseline: " + base.get("missing_why", "")})
    return rows


# ------------------------------------------------------------------ the score
def verdict(rec: dict) -> dict:
    """A day's bars, each one a standard that exists: no death (tools/standard_score.level: a death is never to
    standard; Luis died in none of his tasks), no stand over 5 s without work (the baselines' bar), and counted (not
    cut by the run). No bar on progression or misses: Luis has no per-hour figure, and the miss bar is 1 a job. The
    deaths here are the record's own (calls and samples); the score row adds the brain log's."""
    d = rec.get("deaths_t")
    n = len(d) if isinstance(d, list) else deaths(rec)["n"]
    bars = {"deaths": n == 0, "stands": not (rec.get("idle_over_5s") or []), "counted": not not_counted(rec)}
    ms = [{"t": m.get("t"), "tool": m.get("tool"), "reason": m.get("kind")} for m in (rec.get("misses") or {}).get("list") or []]
    return {"pass": all(bars.values()), "bars": bars, "misses": ms, "truth": "not judged"}


def score(rec: dict, rows: list[dict] | None = None, base: dict | None = None) -> dict:
    """The day's score from its record (and its brain log rows when given: brain_rows)."""
    d = rec.get("day") or {}
    trace = d.get("trace") or []
    t0 = d.get("t0")
    wall = float(rec.get("wall_s") or 0)
    cls, words = end_class(rec)
    dth = deaths(rec, rows, t0)
    sc = {"run": rec.get("run"), "item": rec.get("item") or "day", "kind": "day", "ask": d.get("ask"),
          "world": d.get("world"), "character": rec.get("character"), "checkpoint": rec.get("checkpoint"),
          "brain_logs": rec.get("brain_logs"), "wall_s": rec.get("wall_s"), "hours": round(wall / 3600.0, 3),
          "active_s": rec.get("active_s"), "budget_s": d.get("budget_s"), "ended": rec.get("ended"),
          "end_class": cls, "end_why": words, "not_counted": rec.get("not_counted"),
          "lines_sent": d.get("lines_sent", len(rec.get("lines") or [])), "first_step_s": rec.get("first_step_s"),
          "first_action_s": first_action(rec),
          "power_level": power(trace), "skills": skills(trace), "regions": regions(positions(rec, rows)),
          "deaths": dth, "misses": misses_of(rec), "idle": idle_of(rec), "stock": stock_of(rec),
          "spend": spend_of(rec, rows), "human": {k: (rec.get("human") or {}).get(k) for k in ("human_s", "steps", "walk_m")},
          "ratio": rec.get("ratio"), "trace_reads": len(trace), "world_restore": rec.get("world_restore")}
    if d.get("end_unread"):
        sc["end_unread"] = d["end_unread"]
    v = verdict({**rec, "deaths_t": dth["t"]})
    sc.update(verdict=v, pass_=v["pass"], bars=v["bars"])
    b = base if base is not None else luis()
    sc["baselines"] = compare(sc, b)
    sc["baselines_missing"] = b.get("missing") or []
    return sc


def ledger_row(sc: dict, rec: dict) -> dict:
    """The day_runs.jsonl row: the score, and what failure_ledger.first_wrong reads (the stands, the deaths' times, the
    misses, whether it ran its budget)."""
    return {**{k: v for k, v in sc.items() if k != "baselines"}, "baselines": sc.get("baselines"),
            "done": sc["end_class"] == "budget", "idle_over_5s": rec.get("idle_over_5s") or [],
            "deaths_t": sc["deaths"]["t"], "record": str(record_path(sc["run"]))}


def record_path(run: str, folder: Path | None = None) -> Path:
    return Path(folder or RECORD_DIR) / f"{run}.json"


def write(row: dict, rec: dict, out: Path | None = None, folder: Path | None = None) -> Path:
    """The record to logs/evals/day_runs/<run>.json and the row appended to logs/evals/day_runs.jsonl."""
    rp = record_path(row["run"], folder)
    rp.parent.mkdir(parents=True, exist_ok=True)
    rp.write_text(json.dumps(rec, default=str), encoding="utf-8")
    p = Path(out or DAY_OUT)
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("a", encoding="utf-8") as f:
        f.write(json.dumps({**row, "record": str(rp)}, default=str) + "\n")
    return p


def finish(rec: dict, log_dir: Path | None = None) -> dict:
    """The window's end of a day: scored with its brain logs, written, the report printed. Returns the window's trial
    row (run, pass, ended, misses, deaths, day_row)."""
    rows = brain_rows(rec, log_dir)
    sc = score(rec, rows)
    row = ledger_row(sc, rec)
    write(row, rec)
    print(report(sc))
    return {"run": sc["run"], "pass": sc["pass_"], "ended": sc["ended"], "end_class": sc["end_class"],
            "misses": sc["misses"]["n"], "deaths": sc["deaths"]["n"], "wall_s": sc["wall_s"], "day_row": True,
            **({"not_counted": sc["not_counted"]} if sc.get("not_counted") else {})}


# ------------------------------------------------------------------ the report
def _f(v: Any, nd: int = 1) -> str:
    if v is None:
        return "-"
    if isinstance(v, float):
        return f"{v:.{nd}f}".rstrip("0").rstrip(".") if nd else f"{v:.0f}"
    return str(v)


def report(sc: dict) -> str:
    pl, sk, rg, dt = sc["power_level"], sc["skills"], sc["regions"], sc["deaths"]
    mi, idl, st, sp = sc["misses"], sc["idle"], sc["stock"], sc["spend"]
    out = [f"== day {sc['run']}: {sc.get('ask')!r} on {sc.get('world') or '?'} ({sc.get('character') or '?'})",
           f"ran {_f(sc['wall_s'])} s of {_f(sc.get('budget_s'))}, ended on the {sc['end_class']} ({sc['end_why']}); "
           f"lines sent {sc['lines_sent']}; first action {_f(sc.get('first_action_s'))} s, first verified step "
           f"{_f(sc.get('first_step_s'))} s"
           + (f"; NOT COUNTED: {sc['not_counted']}" if sc.get("not_counted") else ""),
           f"power level {_f(pl['start'])} -> {_f(pl['end'])} (max {_f(pl['max'])}; "
           + (", ".join(f"{_f(v)} at {_f(t, 0)} s" for t, v in pl["series"][:8]) or "never read") + ")",
           f"skills: total level {' -> '.join(_f(x) for x in sk['total_level']) if sk['total_level'] else '-'}, "
           f"XP +{_f(sk['xp_gained'])}; "
           + (", ".join(f"{k} {_f(r['level'][0])}->{_f(r['level'][1])} (+{_f(r['xp_gained'])} xp)"
                        for k, r in sk["skills"].items() if (r["xp_gained"] or 0) > 0) or "none trained"),
           "regions: " + (" > ".join("%s (power %s, %s s)" % (e["region"], _f(e["power"]), _f(e["t"], 0))
                                     for e in rg["entries"]) or "none read")
           + f"; new {len(rg['new'])}, top power {_f(rg['top_power'])}",
           f"deaths {dt['n']}" + (f" at {', '.join(_f(t, 0) + ' s' for t in dt['t'])}" if dt["t"] else "")
           + f" (merged within {_f(dt['merge_s'], 0)} s; brain log {'read' if dt['brain_log_read'] else 'not read'})",
           f"misses {_f(mi['n'])}, {_f(mi['per_5min'], 2)} per 5 min of work ({_f(mi['work_s'])} s)"
           + (f"; {', '.join(f'{k} x{n}' for k, n in list(mi['kinds'].items())[:4])}" if mi["kinds"] else ""),
           f"idle {_f(idl['total_s'])} s ({_f((idl['share'] or 0) * 100, 0)} %), longest stand {_f(idl['longest_s'])} s, "
           f"{idl['stands_over_5s']} over 5 s ({_f(idl['per_hour'])}/h), {idl['quiet_spells']} of {_f(QUIET_S, 0)} s or "
           "more (a trial would have ended quiet)",
           "stock: " + (" | ".join(f"{_f(r['t'], 0)} s carried {_f(r['food'])} food {_f(r['drink'])} drink, chests "
                                   f"{_f(r['chest_food'])} food {_f(r['chest_drink'])} drink"
                                   + (f" (unread: {r['unread'][:40]})" if r.get("unread") else "")
                                   for r in st["reads"][:6]) or "not read")
           + (f" (+{len(st['reads']) - 6} reads)" if len(st["reads"]) > 6 else ""),
           f"spend ${_f(sp['usd'], 3)} ({_f(sp.get('usd_per_hour'), 3)}/h): Haiku {_f(sp['haiku'])}, Sonnet "
           f"{_f(sp['sonnet'])} (from the {sp['from']})",
           "bars: " + ", ".join(f"{k} {'ok' if ok else 'NO'}" for k, ok in sc["bars"].items())
           + f" -> {'PASS' if sc['pass_'] else 'FAIL'} (progression has no bar: no baseline)",
           "against Luis (docs/BASELINES-2026-11-01-luis.md):"]
    for b in sc.get("baselines") or []:
        if b["luis"] is None and b["day"] is None:
            continue
        out.append(f"  {b['what']}: day {_f(b['day'], 3)}, Luis {_f(b['luis'], 3)}"
                   + (f", ratio {_f(b.get('ratio'), 2)}" if b.get("ratio") is not None else "")
                   + (f" ({b['note']})" if b.get("note") else ""))
    if sc.get("baselines_missing"):
        out.append("  no baseline of Luis's for: " + "; ".join(sc["baselines_missing"]))
    return "\n".join(out)


# ------------------------------------------------------------------ the ledger and the CLI
def all_rows(path: Path | None = None) -> list[dict]:
    p = Path(path or DAY_OUT)
    if not p.exists():
        return []
    return [json.loads(line) for line in p.read_text(encoding="utf-8").splitlines() if line.strip()]


def ledger_recs(path: Path | None = None) -> list[dict]:
    """The day rows as runs failure_ledger.scan can hold (run, item, verdict, the stands and deaths first_wrong reads)."""
    return [r for r in all_rows(path) if r.get("run")]


def ledger_verdict(row: dict) -> dict:
    return row.get("verdict") or verdict(row)


def ledger_not_counted(row: dict) -> str | None:
    return row.get("not_counted")


def read_record(row: dict) -> dict | None:
    return _read_json(Path(row["record"])) if row.get("record") else None


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("report")
    sh = sub.add_parser("show")
    sh.add_argument("run")
    rs = sub.add_parser("rescore")
    rs.add_argument("run")
    rs.add_argument("--write", action="store_true", help="append the new score as a row (the old one stays)")
    a = ap.parse_args(argv)
    rows = all_rows()
    if a.cmd == "report":
        if not rows:
            print(f"no day runs in {DAY_OUT}")
        for r in rows:
            print(f"{r['run']} {r.get('end_class'):<9} {_f(r.get('wall_s'))} s PL {_f(r['power_level']['start'])}->"
                  f"{_f(r['power_level']['end'])} XP +{_f(r['skills']['xp_gained'])} regions {len(r['regions']['reached'])} "
                  f"deaths {r['deaths']['n']} misses/5min {_f(r['misses']['per_5min'], 2)} idle "
                  f"{_f(r['idle']['total_s'])} s ${_f(r['spend']['usd'], 3)}"
                  + ("  NOT COUNTED" if r.get("not_counted") else ""))
        return 0
    row = next((r for r in reversed(rows) if r.get("run") == a.run), None)
    if row is None:
        print(f"no day run {a.run}")
        return 2
    if a.cmd == "show":
        print(report(row))
        return 0
    rec = read_record(row)
    if rec is None:
        print(f"{a.run}: its record {row.get('record')} is gone")
        return 2
    sc = score(rec, brain_rows(rec))
    print(report(sc))
    if a.write:
        p = Path(DAY_OUT)
        with p.open("a", encoding="utf-8") as f:
            f.write(json.dumps({**ledger_row(sc, rec), "rescored": True}, default=str) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

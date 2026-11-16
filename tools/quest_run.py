"""Quest runs from chat (Rung 5): send Claude a line, let the live brain play, and time every step against the game's
own quest log. Reuses the chat ladder's plumbing (the dev "Tester" sender, a fresh brain on the client body).

    .venv\\Scripts\\python.exe -m tools.quest_run run --confirm --quest "Getting Started" \\
        --line "claude, go and see Doric outside the temple and do what he asks"
    .venv\\Scripts\\python.exe -m tools.quest_run report            # the last runs, one line each

A run holds the live lock ("quests"), tops Claude up (tools.supply --heal), starts a brain (player Tester), sends
each --line in turn (the next one once the brain has gone quiet), and ends when the quest reaches --until (complete,
or a change of step), at --deadline, at the Haiku cap, or when everything is quiet. The record (logs/evals/
quest_runs.jsonl) holds the quest steps with their times, every tool call with its duration and result, what Claude
said, idle stretches over 5 s (no tool running, no model call), and the model calls and $.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

from brain import paths
from tools import obs, spend
from tools import chat_ladder as cl

ROOT = paths.REPO_ROOT
OUT = ROOT / "logs" / "evals" / "quest_runs.jsonl"
FRESH_OUT = ROOT / "logs" / "evals" / "quest_fresh.jsonl"
POLL_S = 3.0
QUIET_S = 40.0
IDLE_S = 5.0


# commands that don't move him: another agent's status reads never hold a run back (chat_ladder.foreign_driver; live
# 17:0xZ a window was refused for one `inventory` read 25 s earlier)
NOT_DRIVING = ("ping", "capabilities", "me", "stop", "quests", *cl.READ_ONLY_TOOLS)


def driver(window_s: float = 60.0) -> str | None:
    """A body command (not a pure read) written to the client bridge in the last window_s: someone else drives him."""
    now = time.time()
    for name in ("debug_to_client.jsonl", "brain_to_client.jsonl"):
        for r in reversed(cl._tail_rows(cl.CLIENT_BRIDGE / name)):
            t = r.get("ts")
            if not isinstance(t, (int, float)) or now - t > window_s:
                break
            if r.get("tool") not in NOT_DRIVING:
                return f"{name}: {r.get('tool')} {now - t:.0f} s ago"
    return None


def preflight(a) -> list[str]:
    """chat_ladder's preflight, with its "someone drove" check replaced by one that ignores pure reads (and none at all
    inside a fresh-character window: the lock has been ours since the character was made; the commands are our own)."""
    bad = [b for b in cl.preflight(a) if not b.startswith("someone drove the client")]
    if not getattr(a, "in_lock", False) and (who := driver()) is not None:
        bad.append(f"someone drove the client in the last 60 s ({who})")
    return bad


# ------------------------------------------------------------------ the human time bar (Luis has no quest baseline)
BASELINE = ROOT / "data" / "baselines" / "luis-2026-11-01.json"
# average adult silent reading, 238 words/min (Brysbaert 2019, "How many words do we read per minute?", J. Memory and
# Language 109): the time a player takes to read an NPC's lines
READ_WPS = 238 / 60
PRESS_TOOLS = ("interact", "equip", "consume", "drop", "pickup")  # one press each, at his pickup press time


def _baseline() -> dict:
    return json.loads(BASELINE.read_text(encoding="utf-8"))


def _per_item(b: dict, family: str) -> float | None:
    """Seconds per item gained in Luis's windows of a family (chop: 40.94 s for 13 Ash Logs = 3.15 s per log)."""
    secs = items = 0.0
    for w in b.get("windows") or []:
        if w.get("family") == family and isinstance(w.get("gained"), dict) and w.get("unit_s"):
            secs += float(w["unit_s"]) * float(w.get("units") or 1)
            items += sum(float(v) for v in w["gained"].values())
    return secs / items if items else None


def _positions(rows: list[dict]) -> list[tuple[float, list]]:
    out = []
    for r in rows:
        if r.get("kind") == "bridge_recv":
            d = (r.get("msg") or {}).get("data") or {}
            p = d.get("position") if isinstance(d, dict) and "hydration" in d else None
            if isinstance(p, list) and len(p) >= 2:
                out.append((float(r.get("ts") or 0), p))
    return out


def _got(d: dict) -> float:
    """Items a gather got: "Got 23 ash." -> 23 (else its count)."""
    det = str(d.get("detail") or "")
    if det.startswith("Got "):
        try:
            return float(det[4:].split(" ", 1)[0])
        except ValueError:
            pass
    return float(d.get("count") or 0)


def human_bar(rows: list[dict], lines_sent: int, b: dict | None = None) -> dict:
    """What the run's SUCCESSFUL steps would take Luis: walking the straight line between where each one ended at his
    sprint pace (travel_speed_mps), his per-unit times for the work (craft, cook, kill, chop, mine, build, presses,
    spells), reading the NPCs' lines, and his reaction time (REACT_S) per chat line and per step. A failed call costs
    nothing (a player wouldn't make it); its walk counts only as far as the next step needed it."""
    b = b or _baseline()
    fam, react, v = b["families"], float(b["constants"]["REACT_S"]), float(b["travel_speed_mps"])

    def unit(f: str) -> float:
        return float(fam[f]["unit_s"])

    pos = _positions(rows)

    def at(ts: float):
        return next((p for t, p in pos if t >= ts), pos[-1][1] if pos else None)

    here = pos[0][1] if pos else None
    parts: dict[str, float] = {}

    def add(k: str, x: float) -> None:
        parts[k] = parts.get(k, 0.0) + x

    walk_m, steps, notes = 0.0, 0, []
    for r in rows:
        if r.get("kind") == "event" and (r.get("event") or {}).get("type") == "activity":
            e = r["event"]
            if e.get("kind") == "combat_end" and e.get("outcome") == "killed":
                n = int(e.get("kills") or 1)
                add("kill", n * unit("kill"))
                notes.append(f"{n} kill(s) ({e.get('by')})")
            continue
        if r.get("kind") != "tool_result" or r.get("read_only") or r.get("tool") == "say":
            continue
        res = r.get("result") or {}
        if res.get("ok") is not True:
            continue
        tool, d = r.get("tool"), res.get("data") if isinstance(res.get("data"), dict) else {}
        end = at(float(r.get("ts") or 0))
        if here and end:
            walk_m += ((end[0] - here[0]) ** 2 + (end[1] - here[1]) ** 2) ** 0.5
            here = end
        steps += 1
        if tool == "talk":
            words = sum(len(str(x.get("text") or "").split()) for x in d.get("lines") or [] if isinstance(x, dict))
            add("read", words / READ_WPS)
        elif tool == "craft":
            f = "cook" if d.get("fuel_used") else "craft"  # a fuelled station (campfire, furnace): his cook time
            add(f, float(d.get("crafts") or d.get("count") or 1) * unit(f))
        elif tool == "build":
            add("build", unit("build"))
        elif tool == "gather":
            f = {"Woodcutting": "chop", "Mining": "mine"}.get(str(d.get("trains") or ""))
            per = (_per_item(b, f) if f else None) or unit("pickup")
            add(f or "pickup", _got(d) * per)
        elif tool == "cast":
            add("spell", unit("spell"))
        elif tool in PRESS_TOOLS:
            add("press", unit("pickup"))
        # go_to / come_to / follow: their walking is the distance above
    add("walk", walk_m / v)
    add("react", react * (lines_sent + steps))
    total = round(sum(parts.values()), 1)
    return {"human_s": total, "parts": {k: round(x, 1) for k, x in parts.items()}, "walk_m": round(walk_m),
            "steps": steps, "notes": notes, "basis": f"{BASELINE.name}: sprint {v} m/s, REACT_S {react} s, "
                                                       f"reading {READ_WPS * 60:.0f} words/min"}


DELIVERABLES = ROOT / "data" / "quest_deliverables.json"


def carried(cli, quest: str) -> dict[str, int]:
    """The quest's deliverables he already holds at its start ({item: count}; data/quest_deliverables.json). A run
    that starts holding any did not do the quest's work (live ClaudeQ2-Q5: an inherited Stone Club made Getting
    Started one talk, four Rat Roasts made Ratcatcher one), so it is recorded as not counted."""
    items = (json.loads(DELIVERABLES.read_text(encoding="utf-8")).get("quests") or {}).get(quest) or []
    if not items:
        return {}
    st = cli.request("get_state", {}, timeout=15)
    inv = ((st.get("data") or {}).get("inventory") if isinstance(st, dict) else None) or {}
    return {i: inv[i] for i in items if inv.get(i)}


def quests(cli) -> dict | None:
    r = cli.request("quests", {"all": True}, timeout=10)
    return r.get("data") if isinstance(r, dict) and r.get("ok") else None


def quest_row(q: dict | None, name: str) -> dict:
    """{state, step} of one quest from a quests read."""
    if not q:
        return {"state": "unknown"}
    for a in q.get("active") or []:
        if a.get("quest") == name:
            return {"state": "given", "step": a.get("step")}
    if name in (q.get("complete") or []):
        return {"state": "complete"}
    if name in (q.get("ungiven") or []):
        return {"state": "ungiven"}
    return {"state": "absent"}


def timeline(rows: list[dict], t0: float, t_end: float | None = None) -> dict:
    """Tool calls (start, duration, result), speech, and the idle stretches between brain activity (and, given t_end,
    the stand from the last activity to the end of the run: live 17:2xZ a chain stopped on its budget and he stood
    193 s to the deadline, which the stretches between calls never saw)."""
    calls, open_ = [], {}
    says = []
    busy: list[tuple[float, float]] = []  # intervals with a tool running, a model call in flight, or reflex work
    prompt_at = None
    acts: dict[str, float] = {}  # the body's own work, open: "combat" from combat_started, "flee" from flee_started
    for r in rows:
        k, ts = r.get("kind"), float(r.get("ts") or 0)
        key = r.get("call") or r.get("task_id") or f"{r.get('tool')}@{ts}"
        ev = r.get("event") if k == "event" and isinstance(r.get("event"), dict) else None
        if ev and ev.get("type") == "activity" and isinstance(ev.get("kind"), str):
            # live 19:38Z (ClaudeQ3): reflex fights and a flee ran 40 s after his last call; that is work, not a stand,
            # and the run must not end "quiet" in the middle of it
            what, _, phase = ev["kind"].rpartition("_")
            at = float(ev.get("ts") or ts)
            if phase == "started":
                acts.setdefault(what, at)
            elif what in acts:
                busy.append((acts.pop(what), at))
            continue
        if k == "tool_call":
            open_[key] = {"tool": r.get("tool"), "args": r.get("args"), "t": round(ts - t0, 1), "_ts": ts}
        elif k == "tool_result" and key in open_:
            c = open_.pop(key)
            res = r.get("result") or {}
            d = res.get("data") if isinstance(res.get("data"), dict) else {}
            c.update({"dur_s": round(ts - c["_ts"], 1), "ok": res.get("ok"), "reason": res.get("reason"),
                      "detail": obs.short(d.get("detail") or d.get("why") or "", 160)})
            if d.get("quests_changed"):
                c["quests_changed"] = d["quests_changed"]
            if d.get("options"):
                c["options"] = [o.get("text") for o in d["options"] if isinstance(o, dict)]
            busy.append((c["_ts"], ts))
            calls.append(c)
        elif k == "prompt":
            prompt_at = ts
        elif k == "llm_response" and prompt_at is not None:
            busy.append((prompt_at, ts))
            prompt_at = None
        elif k == "say":
            says.append({"t": round(ts - t0, 1), "text": r.get("text") or (r.get("args") or {}).get("text")})
    for c in list(open_.values()):
        c["dur_s"], c["ok"] = None, None
        calls.append(c)
    last_ts = max((float(r.get("ts") or 0) for r in rows), default=t0)
    for what, a in acts.items():  # still going: busy to the end (or to the last row seen)
        busy.append((a, t_end if t_end is not None else max(last_ts, a)))
    for c in calls:
        c.pop("_ts", None)
    busy.sort()
    idle, cur = [], t0
    for a, b in busy:
        if a - cur > IDLE_S:
            idle.append({"from": round(cur - t0, 1), "s": round(a - cur, 1)})
        cur = max(cur, b)
    if t_end is not None and t_end - cur > IDLE_S:
        idle.append({"from": round(cur - t0, 1), "s": round(t_end - cur, 1), "to_end": True})
    return {"calls": calls, "says": says, "idle": idle, "last_busy": cur, "body_busy": sorted(acts)}


def leave_dialogue(cli, tries: int = 3, settle_s: float = 1.5) -> list[dict]:
    """Leave any conversation he has open the way a player does (talk {target, leave}: the panel's Cancel), and
    check that it closed, so each quest run starts clean (live ClaudeQ3/Q4: Doric's after-quest dialogue was still
    open when the next quest's first talk read it back). Returns what was left, [] when nothing was open."""
    out = []
    for _ in range(tries):
        try:
            st = cli.request("get_state", {}, timeout=15)
        except Exception:
            break
        conv = ((st.get("data") or {}).get("conversation") if isinstance(st, dict) else None) or None
        if not conv:
            break
        who = conv.get("npc") or conv.get("speaker")
        try:
            r = cli.request("talk", {"target": who, "leave": True} if who else {"leave": True}, timeout=20) or {}
        except Exception as exc:
            r = {"ok": False, "reason": repr(exc)[:120]}
        d = r.get("data") if isinstance(r.get("data"), dict) else {}
        out.append({"npc": who, "ok": r.get("ok"), "reason": r.get("reason"), "detail": obs.short(d.get("detail") or "", 120)})
        time.sleep(settle_s)  # the after-quest dialogue can open a moment after the last one ended
    return out


def holds(calls: list[dict]) -> list[dict]:
    """The body's own word that a hold interaction kept him in place (an Anima Vent's siphon is a Hold: 16653dc lets
    go at a skill's end, and a walk lets go first and says so; a go_to that could not let go ends "rooted"). Read from
    the results only, so a run that was held reads as that known cause."""
    return [{"tool": c.get("tool"), "t": c.get("t"), "reason": c.get("reason"), "detail": c.get("detail")}
            for c in calls if c.get("reason") == "rooted" or "let go of" in str(c.get("detail") or "")]


def verdict(rec: dict) -> dict:
    """The goal's bars for one quest run (GOAL-2026-11-01: done, <= 1.5x the human bar, <= 1 miss, no stand > 5 s), by
    the graders' own miss rule (tools/standard_score: a world action that failed; never an interruption or a read-only
    lookup). `done` alone is not a pass: chain 20261116-085113 finished all four quests with 1, 2, 3 and 3 misses.
    Whether his lines were true is the judge's (not run here): `truth` says so."""
    from tools import standard_score as ss
    misses = [{"t": c.get("t"), "tool": c["tool"], "reason": c.get("reason")} for c in rec.get("tool_calls") or []
              if c.get("ok") is False and c.get("reason") not in ss.NO_MISS_REASONS and c["tool"] not in ss.READ_ONLY_TOOLS]
    stands = [i["s"] for i in rec.get("idle_over_5s") or []]
    bars = {"done": bool(rec.get("done")), "time": rec.get("ratio") is not None and rec["ratio"] <= 1.5,
            "misses": len(misses) <= 1, "stands": not stands, "counted": not rec.get("not_counted")}
    return {"pass": all(bars.values()), "bars": bars, "misses": misses, "truth": "not judged"}


def cmd_run(a) -> int:
    if not a.confirm:
        print("refusing: a live run moves Claude and sends test chat on the dev server; pass --confirm")
        return 2
    a.start_brain, a.use_running_brain = True, False
    from tools.live_lock import held
    from tools import m1_session
    import contextlib
    import subprocess
    in_lock = getattr(a, "in_lock", False)  # a fresh-character window: the caller holds the lock for the whole window
    with (contextlib.nullcontext() if in_lock else held("quests", a.wait)):
        t_wait = time.time()  # the last holder may have driven him a moment ago: give its commands 60 s to age out
        while not in_lock and driver() is not None and time.time() - t_wait < 70:
            time.sleep(5)
        bad = preflight(a)
        if bad:
            print("not running:\n  " + "\n  ".join(bad))
            return 3
        if not getattr(a, "no_heal", False):  # a fresh character plays with what it has: no top-up
            subprocess.run([sys.executable, "-m", "tools.supply", "--heal"], cwd=str(ROOT))
        fixtures = []
        if a.grant:  # dev fixture (dev server only, nobody else on): e.g. gear lost to an unreachable grave
            from evals.bench.devrun import default_dev
            dev = default_dev()
            dev.brain_running = lambda: False
            for g in a.grant:
                item, _, n = g.partition(":")
                dev.setup("grant", purpose=f"quest_run {a.quest}: {g}", item=item, count=int(n or 1))
                fixtures.append(g)
        ok, how = cl.ensure_sender()
        if not ok:
            print("sender:", how)
            return 4
        before = spend.spend_today()["spent_usd"]
        p, brain_file = cl.start_brain(a, before)
        if brain_file is None:
            cl.stop_brain(p)
            print("brain did not start")
            return 5
        cli = cl._debug_client()
        left_before = leave_dialogue(cli)  # each quest starts clean: a dialogue left open by the last run is closed
        try:
            held_at_start = carried(cli, a.quest)
        except Exception as exc:  # a report: a failed read is recorded, it never stops the run
            held_at_start = {"error": repr(exc)[:120]}
        q0 = quests(cli)
        steps = [{"t": 0.0, **quest_row(q0, a.quest)}]
        t0 = time.time()
        lines = list(a.line)
        sent = []
        why, ended = None, None
        next_line_at = t0
        try:
            while True:
                now = time.time()
                if lines and now >= next_line_at:
                    line = lines.pop(0)
                    okl, det = m1_session.send_speech_direct(line)
                    sent.append({"t": round(time.time() - t0, 1), "line": line, "sent": okl})
                    next_line_at = float("inf")
                q = quests(cli)
                row = quest_row(q, a.quest)
                if q and (row.get("state"), row.get("step")) != (steps[-1].get("state"), steps[-1].get("step")):
                    steps.append({"t": round(now - t0, 1), **row})
                    print(f"[{now - t0:6.1f}s] {a.quest}: {row}")
                rows = cl.brain_rows([brain_file], t0 - 1, now + 1)
                tl = timeline(rows, t0)
                calls = cl.model_calls(rows)
                busy = [r for r in rows if r.get("kind") in ("prompt", "llm_response", "tool_call", "tool_result", "say")]
                open_prompt = bool(busy) and busy[-1].get("kind") == "prompt"
                open_tool = any(c.get("dur_s") is None for c in tl["calls"]) or bool(tl["body_busy"])
                quiet = now - max(tl["last_busy"], float(busy[-1]["ts"]) if busy else t0)
                if a.until == "complete" and row.get("state") == "complete":
                    why = "quest complete"
                elif a.until == "change" and len(steps) > 1:
                    why = "quest step changed"
                elif calls["haiku"] > a.max_haiku:
                    why = "haiku cap"
                elif now - t0 > a.deadline:
                    why = "deadline"
                elif not open_prompt and not open_tool and quiet >= QUIET_S and calls["calls"]:
                    if lines:
                        next_line_at = now
                    else:
                        why = "quiet"
                if why:
                    ended = now
                    break
                time.sleep(POLL_S)
        finally:
            time.sleep(2.0)
            cl.stop_brain(p)
            # the body may still run the brain's last job (live 16:0xZ: a grave interact outlived the run and the next
            # lock holder's calls were all refused "busy"): stop it, and leave an open dialogue, before the lock goes
            try:
                cli.request("stop", {}, timeout=15)
            except Exception:
                pass
            left_after = leave_dialogue(cli)
    rows = cl.brain_rows([brain_file], t0 - 1, ended + 3)
    tl = timeline(rows, t0, ended)
    calls = cl.model_calls(rows)
    rec = {"run": time.strftime("%Y%m%d-%H%M%S", time.gmtime(t0)), "quest": a.quest, "until": a.until,
           "character": getattr(a, "character", None) or "ClaudeDev",
           "lines": sent, "fixtures": fixtures, "ended": why, "wall_s": round(ended - t0, 1), "steps": steps,
           "done": steps[-1].get("state") == "complete" if a.until == "complete" else len(steps) > 1,
           "tool_calls": tl["calls"], "says": tl["says"], "idle_over_5s": tl["idle"],
           "idle_total_s": round(sum(i["s"] for i in tl["idle"]), 1),
           "longest_stand_s": max([i["s"] for i in tl["idle"]], default=0),
           "haiku": calls["haiku"], "sonnet": calls["sonnet"], "usd": calls["usd"], "brain_log": brain_file.name,
           "holds": holds(tl["calls"]), "dialogue_left": {"before": left_before, "after": left_after},
           "carried_at_start": held_at_start}
    if held_at_start:
        rec["not_counted"] = "deliverable carried: " + ", ".join(f"{k} x{v}" for k, v in held_at_start.items())
    try:
        bar = human_bar(rows, len(sent))
        rec["human"] = bar
        # a run that ended quiet waited QUIET_S after his last activity: that wait is the harness's, not his
        rec["active_s"] = round(tl["last_busy"] - t0, 1) if why == "quiet" else rec["wall_s"]
        rec["ratio"] = round(rec["active_s"] / bar["human_s"], 2) if bar["human_s"] else None
    except Exception as exc:  # the bar is a report: a broken baseline file never loses the run's record
        rec["human"], rec["ratio"] = {"error": repr(exc)}, None
    rec["verdict"] = verdict(rec)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec) + "\n")
    print(json.dumps({k: rec[k] for k in ("quest", "ended", "wall_s", "done", "steps", "idle_total_s", "longest_stand_s", "haiku", "sonnet", "usd")}, indent=1))
    v = rec["verdict"]
    print(("PASS" if v["pass"] else "FAIL") + " by the goal's bars: " + ", ".join(f"{k} {'ok' if x else 'NO'}" for k, x in v["bars"].items())
          + f"; {len(v['misses'])} miss(es): " + ", ".join(f"{m['tool']} {m['reason']}" for m in v["misses"]))
    if rec.get("not_counted"):
        print(f"NOT COUNTED: {rec['not_counted']}")
    h = rec.get("human") or {}
    if h.get("human_s"):
        print(f"human bar {h['human_s']} s ({', '.join(f'{k} {x}' for k, x in h['parts'].items())}; walk {h['walk_m']} m; "
              f"{h['steps']} steps) -> Claude {rec['active_s']} s = {rec['ratio']}x (pass <= 1.5x)")
    for c in tl["calls"]:
        print(f"  {c['t']:6.1f}s {c['tool']:<12} {c.get('dur_s')!s:>6}s ok={c.get('ok')} {c.get('reason') or ''} "
              f"{json.dumps(c.get('args'))[:80]} | {c.get('detail', '')}")
    for s in tl["says"]:
        print(f"  {s['t']:6.1f}s say: {s['text']}")
    return 0 if rec["done"] else 1


# A fresh character's quest chain, in order: the line a player would send for each (the brain works out the rest)
FRESH_PLAN = (
    ("First Steps", "claude, go and talk to the Wise Old Man by the temple and do what he asks", 240),
    ("Getting Started", "claude, go and see Doric outside the temple and do whatever he asks you to", 300),
    ("Ratcatcher", "claude, go and see Vannaka near the windmill and do his quest", 480),  # + fuel to chop
    ("Rune Mysteries", "claude, go and see Zanik and do her quest", 900),  # both parts: the game names them alike; 50 logs from none
)


def _on_main(sw, cli, tries: int = 3) -> dict | None:
    """Back on ClaudeDev with his pawn in the world (the dev server lists him, the body answers get_state)."""
    from evals.bench.devchar import MAIN_CHARACTER
    for i in range(tries):
        try:
            back = sw.ensure(MAIN_CHARACTER, wait_s=150)
            st = cli.request("get_state", {}, timeout=20)
            if isinstance(st, dict) and st.get("ok") and (st.get("data") or {}).get("position"):
                return {**back, "position": st["data"]["position"]}
            print(f"back on {MAIN_CHARACTER} but no pawn yet: {str(st)[:160]}")
            time.sleep(15)
        except Exception as exc:
            print(f"return to {MAIN_CHARACTER} failed (try {i + 1}): {exc!r}"[:300])
    return None


def cmd_fresh(a) -> int:
    """ONE lock window for a quest-cleared clone of ClaudeDev (main + Luis, 2026-11-01: tools/quest_clone.py, made
    here if its save does not exist yet; same level and gear, the FTUE chain cleared): switch to it (evals/bench/
    devchar.py, Claude's own account, dev world), run FRESH_PLAN in one go with no fixture top-ups, switch back to
    ClaudeDev and see his pawn before the lock goes. The lock is never released while the client is on another
    character."""
    if not a.confirm:
        print("refusing: this relaunches the client on a new character; pass --confirm")
        return 2
    import argparse as ap_
    from evals.bench.devchar import NAME_RE, default_switch
    from evals.bench.devrun import default_dev
    from tools.live_lock import held
    name = a.name or f"ClaudeQ{time.strftime('%d%H%M', time.gmtime())}"
    if not NAME_RE.match(name):
        print(f"invalid character name {name!r}")
        return 2
    out = {"window": time.strftime("%Y%m%d-%H%M%S", time.gmtime()), "character": name, "runs": []}
    with held("quests", a.wait):
        t0 = time.time()
        dev = default_dev()
        dev.brain_running = lambda: False
        sw = default_switch(dev)
        cli = cl._debug_client()
        try:
            if not sw.exists(name):
                from tools import quest_clone
                if quest_clone.main(["make", "--name", name]) != 0:
                    raise RuntimeError(f"quest_clone could not make {name}")
            made = sw.ensure(name, create=False, wait_s=150)
            out["made"] = {**made, "s": round(time.time() - t0, 1)}
            print(f"[{time.time() - t0:6.1f}s] on {name}: {made}")
            names = [q for q, _, _ in FRESH_PLAN]
            plan = FRESH_PLAN[names.index(a.start):] if a.start in names else FRESH_PLAN
            for quest, line, deadline in plan:
                left = a.window_s - a.reserve_s - (time.time() - t0)
                if left < 90:
                    out["runs"].append({"quest": quest, "skipped": f"window: {left:.0f} s left"})
                    break
                ns = ap_.Namespace(confirm=True, quest=quest, line=[line], until="complete", deadline=min(deadline, left),
                                   max_haiku=a.max_haiku, usd=a.usd, world=f"dev_{name}", wait=0, grant=[], judge=False,
                                   in_lock=True, no_heal=True, character=name)
                rc = cmd_run(ns)
                last = json.loads(OUT.read_text(encoding="utf-8").splitlines()[-1])  # the record cmd_run just wrote
                v = last.get("verdict") or {}
                out["runs"].append({"quest": quest, "rc": rc, "at_s": round(time.time() - t0, 1), "pass": v.get("pass"),
                                    "ratio": last.get("ratio"), "misses": len(v.get("misses") or []),
                                    "longest_stand_s": last.get("longest_stand_s")})
                if rc != 0:
                    break  # the next quest is given by this one
        except Exception as exc:
            out["error"] = repr(exc)[:400]
            print("fresh window error:", out["error"])
        finally:
            back = _on_main(sw, cli)
            out["back"] = back
            out["window_s"] = round(time.time() - t0, 1)
            FRESH_OUT.parent.mkdir(parents=True, exist_ok=True)
            with FRESH_OUT.open("a", encoding="utf-8") as f:
                f.write(json.dumps(out) + "\n")
            print(json.dumps(out, indent=1)[:3000])
            while back is None:  # never release the lock while the client is on another character (main's rule)
                print("STUCK: the client is not back on ClaudeDev; keeping the lock and retrying every 2 min")
                time.sleep(120)
                back = _on_main(sw, cli, tries=1)
    return 0 if all(r.get("rc") == 0 for r in out["runs"]) and out["runs"] and out["runs"][-1].get("quest") == FRESH_PLAN[-1][0] else 1


def cmd_report(a) -> int:
    if not OUT.exists():
        print("no runs yet")
        return 0
    for line in OUT.read_text(encoding="utf-8").splitlines()[-a.n:]:
        r = json.loads(line)
        if "human" not in r and r.get("brain_log"):  # older runs: the bar from their brain log
            try:
                import calendar
                t0 = calendar.timegm(time.strptime(r["run"], "%Y%m%d-%H%M%S"))
                rows = cl.brain_rows([ROOT / "logs" / r["brain_log"]], t0 - 1, t0 + r["wall_s"] + 3)
                h = human_bar(rows, len(r.get("lines") or []))
                r["human"], r["ratio"] = h, round(r["wall_s"] / h["human_s"], 2) if h["human_s"] else None
            except Exception as exc:
                r["human"] = {"error": repr(exc)}
        h = r.get("human") or {}
        v = verdict(r)
        print(f"{r['run']} {r['quest']:<18} {r['ended']:<16} {r['wall_s']:>6}s done={r['done']} "
              f"{'PASS' if v['pass'] else 'FAIL'} misses={len(v['misses'])} "
              f"calls={len(r['tool_calls'])} idle={r['idle_total_s']}s haiku={r['haiku']} sonnet={r['sonnet']} ${r['usd']}"
              + (f" human={h['human_s']}s ratio={r.get('ratio')}x {h.get('parts')}" if h.get("human_s") else "")
              + (f" NOT COUNTED ({r['not_counted']})" if r.get("not_counted") else ""))
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--confirm", action="store_true")
    r.add_argument("--quest", required=True, help="the quest's name as the game's quest log gives it")
    r.add_argument("--line", action="append", required=True, help="a chat line (repeat: sent in turn when quiet)")
    r.add_argument("--until", choices=("complete", "change"), default="complete")
    r.add_argument("--deadline", type=float, default=420.0)
    r.add_argument("--max-haiku", type=int, default=60)
    r.add_argument("--usd", type=float, default=1.0, help="this run's spend cap on top of today's spend")
    r.add_argument("--world", default="dev_quests")
    r.add_argument("--wait", type=float, default=1800.0, help="seconds to wait for the live lock")
    r.add_argument("--grant", action="append", default=[], help="dev fixture before the run: ITEM_id[:count]")
    r.add_argument("--judge", action="store_true", help=argparse.SUPPRESS)
    fr = sub.add_parser("fresh", help="one lock window: a new character runs the quest chain, then back to ClaudeDev")
    fr.add_argument("--confirm", action="store_true")
    fr.add_argument("--name", help="the clone's name (default ClaudeQ<ddhhmm>; made by tools/quest_clone.py if its save does not exist)")
    fr.add_argument("--wait", type=float, default=3000.0, help="seconds to wait for the live lock")
    fr.add_argument("--window-s", type=float, default=1200.0, help="the whole window, switch back included")
    fr.add_argument("--from", dest="start", default=None, help="start the chain at this quest (a clone that already did the ones before)")
    fr.add_argument("--reserve-s", type=float, default=240.0, help="kept for the switch back to ClaudeDev")
    fr.add_argument("--max-haiku", type=int, default=60)
    fr.add_argument("--usd", type=float, default=0.4, help="each run's spend cap on top of today's spend (Rune Mysteries 20261116-074002 ran out of 0.1 at its second part)")
    rp = sub.add_parser("report")
    rp.add_argument("-n", type=int, default=10)
    a = ap.parse_args(argv)
    return {"run": cmd_run, "fresh": cmd_fresh, "report": cmd_report}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())

r"""Build runs from chat: send Claude ONE line ("claude build yourself a small house here"), let the live brain play
it, then time every piece against Luis's build standard and check every build reply against the census.

    .venv\Scripts\python.exe -m tools.build_run run --confirm [--line "..."] [--deadline 1500] [--max-haiku 80]
    .venv\Scripts\python.exe -m tools.build_run score --since 2026-11-01T16:00Z --until 2026-11-01T16:20Z
    .venv\Scripts\python.exe -m tools.build_run report

The model drives it: the harness only sends the line, waits, and measures (chat ladder plumbing: the dev "Tester"
sender, a fresh brain on the client body; tools.quest_run's timeline). A run holds the live lock ("build"), tops
Claude up (tools.supply --heal) and ends when the brain has been quiet QUIET_S, at --deadline or at the Haiku cap.
Measures (logs/evals/build_runs.jsonl):
  pieces    census ids that are new after the run (get_state.structures, mine or not), with name and position
  presses   the recorder's build_spawn RPCs in the window (tools.standard_score.score_window, family "build"):
            work_s, unit_s (s per piece) against data/baselines' build unit_s (Luis: 3.81 s) and his 24-piece
            base (146 s, 6.1 s/piece wall)
  truth     every ok build reply's structure must stand in the census where it said (<= TRUE_M), and a reply that
            says "NOT flush/square" or "flush/squarely" must match its own measured flush flag
  tools     every tool call (duration, result), what he said, idle stretches, model calls and $
"""
from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from brain import paths
from tools import chat_ladder as cl
from tools import obs

ROOT = paths.REPO_ROOT
OUT = ROOT / "logs" / "evals" / "build_runs.jsonl"
POLL_S, QUIET_S = 3.0, 45.0
TRUE_M = 0.15
LUIS_BASE = {"pieces": 24, "wall_s": 146.0}


def structures(cli) -> dict[str, dict]:
    r = cli.request("get_state", {}, timeout=15)
    rows = ((r or {}).get("data") or {}).get("structures") or []
    return {s["id"]: s for s in rows if isinstance(s, dict) and s.get("id")}


CLEAR_M = 40.0  # a fresh spot: this far from every built piece (his, Luis's, other runs')


def all_pieces() -> dict:
    """Every built piece the client knows (client_mod/commands/build_pieces_all.lua: the GlobalBuildingManager
    census) -> {"me": [x, y, z], "pts": [[x, y, z], ...]} | {} when the probe fails."""
    p = subprocess.run(["sh", "tools/client_cmd.sh", "client_mod/commands/build_pieces_all.lua", "30"], cwd=str(ROOT),
                       capture_output=True, text=True, timeout=60)
    try:
        r = json.loads(p.stdout.strip().splitlines()[-1]).get("result") or {}
    except (ValueError, IndexError):
        return {}
    return r if r.get("ok") else {}


def nearest_piece(spot: list[float], pts: list[list[float]]) -> dict | None:
    """The built piece nearest the spot (2D), for the run row."""
    best = min(pts, key=lambda q: math.dist(spot[:2], q[:2]), default=None)
    return {"position": best, "distance_m": round(math.dist(spot[:2], best[:2]), 1)} if best else None


def home(ledger: list[dict]) -> list[float] | None:
    """His base: the piece of his own ledger (data/skills/<world>/my_pieces.json) with the most of his pieces
    within 10 m."""
    at = [e["at"] for e in ledger if isinstance(e.get("at"), list) and len(e["at"]) >= 3]
    return max(at, key=lambda p: sum(1 for q in at if math.dist(p[:2], q[:2]) <= 10.0), default=None)


def fresh_spot(pts: list[list[float]], base: list[float], nav: dict, clear_m: float = CLEAR_M,
               ring: tuple[float, float] = (40.0, 110.0), step: float = 4.0, level_m: float = 1.5,
               stand: tuple[float, float] | None = None) -> list[float] | None:
    """A spot near the base (ring metres from it) at least clear_m from every built piece, on ground he has walked
    (nav memory routes: >= 6 points within 8 m, level within 1.5 m), 20+ m from learned water. Nearest the base."""
    walk = [q for r in nav.get("routes") or [] for q in r.get("pts") or [] if len(q) >= 3]
    wc = 2.0
    water = [((int(a) + 0.5) * wc, (int(b) + 0.5) * wc) for a, b in (str(k).split(":") for k in nav.get("water_cells") or [])]
    grid: dict[tuple[int, int], list] = {}  # walked points by 8 m cell (a 220 m ring scans ~12k spots)
    for q in walk:
        grid.setdefault((int(q[0] // 8), int(q[1] // 8)), []).append(q)

    def walked(x: float, y: float, r: float) -> list:
        cx, cy = int(x // 8), int(y // 8)
        return [q for i in (-1, 0, 1) for j in (-1, 0, 1) for q in grid.get((cx + i, cy + j), ())
                if math.dist((x, y), q[:2]) <= r]
    best = None
    n = int(ring[1] // step)
    for i in range(-n, n + 1):
        for j in range(-n, n + 1):
            c = (base[0] + i * step, base[1] + j * step)
            d = math.dist(c, base[:2])
            if not ring[0] <= d <= ring[1] or (best and d >= best[0]):
                continue
            if any(math.dist(c, q[:2]) < clear_m for q in pts) or any(math.dist(c, w) < 20.0 for w in water):
                continue
            near = walked(c[0], c[1], 8.0)
            zs = [q[2] for q in near]
            if len(near) < 6 or max(zs) - min(zs) > level_m:
                continue
            if stand and len(walked(c[0] + stand[0], c[1] + stand[1], 4.0)) < 3:
                continue  # rung 2: he stands there beside the stand-in, on ground he has walked
            best = (d, [round(c[0], 1), round(c[1], 1), round(sum(zs) / len(zs) + 0.9, 1)])
    return best[1] if best else None


def build_results(rows: list[dict]) -> list[dict]:
    out = []
    for r in rows:
        if r.get("kind") != "tool_result" or r.get("tool") not in ("build", "build_blueprint"):
            continue
        res = r.get("result") or {}
        d = res.get("data") if isinstance(res.get("data"), dict) else {}
        # a `pieces` batch: one row per piece it built (each with its own fit sentence), then the stop, if any
        for p in d.get("built_pieces") or []:
            out.append({"ts": float(r.get("ts") or 0), "ok": True, "reason": None, "structure": p.get("structure"),
                        "position": p.get("position"), "flush": p.get("flush"), "attached_to": p.get("attached_to"),
                        "side": p.get("side"), "name": p.get("name"), "said": p.get("fit") or ""})
        if d.get("built_pieces") is not None:
            if not res.get("ok"):
                out.append({"ts": float(r.get("ts") or 0), "ok": False, "reason": res.get("reason"), "structure": None,
                            "position": None, "flush": None, "attached_to": None, "side": None, "name": None,
                            "said": d.get("detail")})
            continue
        out.append({"ts": float(r.get("ts") or 0), "ok": res.get("ok"), "reason": res.get("reason"),
                    "structure": d.get("structure"), "position": d.get("position"), "flush": d.get("flush"),
                    "attached_to": d.get("attached_to"), "side": d.get("side"), "name": d.get("name"),
                    "said": d.get("built") or d.get("detail")})
    return out


def truth(results: list[dict], after: dict[str, dict]) -> list[dict]:
    """Each ok build reply against the census after the run; each flush sentence against its own measured flag."""
    out = []
    for b in results:
        if not b["ok"]:
            continue
        v = {"structure": b["structure"], "name": b["name"]}
        s = after.get(b["structure"]) if isinstance(b["structure"], str) else None
        if s is None:
            v["verdict"], v["why"] = "missing", "not in the census after the run (taken down later, or never there)"
        else:
            p, q = s.get("position") or [0, 0, 0], b["position"] or [0, 0, 0]
            off = math.dist(p[:3], q[:3])
            v["census_off_m"] = round(off, 3)
            v["verdict"] = "true" if off <= TRUE_M else "false"
        said = b["said"] or ""
        if b["flush"] is True and " NOT " in said:
            v["verdict"], v["why"] = "false", "says NOT flush but measured flush"
        if b["flush"] is False and (" sits flush" in said or "squarely" in said):
            v["verdict"], v["why"] = "false", "says flush but measured not flush"
        out.append(v)
    return out


RUNG2_LINE = ("claude, tear down my house here, then build yourself a house with a foundation, walls, a roof and a door, "
              "plus a crafting table, firepit and crate, and put your spare logs in the crate")
FIXTURE_AT = (8.0, 0.0)  # the stand-in's centre foundation from the spot he stands on (its 3 x 3 cells span +-4.5 m)
LEDGER = ROOT / "data" / "skills" / "dev" / "my_pieces.json"
GUARD_M = 30.0  # main 2026-11-02: the stand-in and all he tears down stay this far from anything already built
FIXTURE_HALF_M = 6.4  # half the 3 x 3 house's diagonal (9 m square)


def guard(points: list[list[float]], pts: list[list[float]]) -> dict:
    """The nearest already-built piece (Luis's remaining foundations, stations, containers, plots, anyone's) to any of
    ``points`` (2D) -> {ok, nearest_m, at, piece}: ok only when every point is GUARD_M or more from all of them."""
    if not pts:  # no census read: nothing is known to be clear
        return {"ok": False, "nearest_m": None, "why": "no census of built pieces"}
    best = None
    for q in points:
        for c in pts:
            d = math.dist(q[:2], c[:2])
            if best is None or d < best[0]:
                best = (d, q, c)
    if best is None:
        return {"ok": True, "nearest_m": None}
    return {"ok": best[0] >= GUARD_M, "nearest_m": round(best[0], 1), "at": best[1], "piece": best[2]}


FIXTURE_BLUEPRINT = "small_house"  # live 01:57Z: the 29-piece luis_house walled him in mid-build (9 of 29, "walls
#                                    everywhere", go_to timeout); the 2-cell house went up whole in run 6 (+ its door 23:5xZ)


def fixture_house(cli, spot: list[float], pts: list[list[float]], blueprint: str = FIXTURE_BLUEPRINT) -> dict:
    """Harness fixture, not play (Rung 2 streak): a stand-in for Luis's house. His real one was torn down live once
    (2026-11-01 14:38Z, d36a500) and is gone, so each run rebuilds it from his house's recorded layout
    (data/blueprints/luis_house.json, his census pids 15-45) with the body's own build_blueprint over the debug channel
    (no model), its materials granted by the dev fixture, and then strikes it from Claude's placement ledger so his
    census reads it as "not placed by you", like Luis's. -> {ok, pieces: [{id, piece, name, position}], s, granted}"""
    from evals.bench.devrun import default_dev
    dev = default_dev()
    dev.brain_running = lambda: False
    # the stand-in on the spot itself (fresh_spot checked that ground: flat, walked), Claude FIXTURE_AT west of it
    # (live 02:3xZ: 8 m off the spot it stood on a slope and 3 walls never settled)
    at = [round(spot[0], 2), round(spot[1], 2), spot[2]]
    # the guard, before anything is built: the stand-in's whole footprint (centre + its half diagonal) and the spot
    pre = guard([spot, at, [spot[0] - FIXTURE_AT[0], spot[1] - FIXTURE_AT[1], spot[2]]], pts)
    if pre["ok"] and pre["nearest_m"] is not None and pre["nearest_m"] - FIXTURE_HALF_M < GUARD_M:
        pre = {**pre, "ok": False, "why": f"footprint edge {pre['nearest_m'] - FIXTURE_HALF_M:.1f} m < {GUARD_M:.0f} m"}
    if not pre["ok"]:
        return {"ok": False, "reason": "guard", "guard_before": pre, "pieces": [], "n": 0, "at": at}
    before = structures(cli)
    t0, granted, r = time.time(), {}, {}
    for _ in range(2):
        r = cli.request("build_blueprint", {"blueprint": blueprint, "at": at, "facing": "E"}, timeout=2500) or {}
        missing = (r.get("data") or {}).get("missing") if r.get("reason") == "missing_materials" else None
        if not missing:
            break
        for m in missing:
            n = int(m["need"]) - int(m.get("have") or 0) + 2
            dev.setup("grant", purpose="rung2 fixture: materials for the stand-in of Luis's house", item=m["item"], count=n)
            granted[m["item"]] = granted.get(m["item"], 0) + n
        time.sleep(2.0)
    after = structures(cli)
    pieces = [{"id": k, "piece": v.get("piece"), "name": v.get("name"), "position": v.get("position")}
              for k, v in after.items() if k not in before and v.get("position")]
    # off his ledger: the body re-reads the file after 30 s (deconstruct.lua ledger_every_s), so wait that out before
    # the line, or a note from the cached copy would write the stand-in back as his
    struck = 0
    if LEDGER.exists():
        d = json.loads(LEDGER.read_text(encoding="utf-8"))
        keep = [e for e in d.get("pieces") or [] if not any(
            e.get("piece") == q["piece"] and isinstance(e.get("at"), list) and math.dist(e["at"], q["position"]) <= 0.3
            for q in pieces)]
        struck = len(d.get("pieces") or []) - len(keep)
        d["pieces"] = keep
        tmp = LEDGER.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(d, indent=2, ensure_ascii=False), encoding="utf-8", newline="\n")
        tmp.replace(LEDGER)
    time.sleep(35.0)
    post = guard([q["position"] for q in pieces], pts)  # every piece he may tear down, measured where it stands
    return {"ok": bool(r.get("ok")) and post["ok"], "reason": r.get("reason") if post["ok"] else "guard",
            "guard_before": pre, "guard_after": post, "pieces": pieces, "n": len(pieces), "at": at,
            "s": round(time.time() - t0, 1), "granted": granted, "struck_from_ledger": struck,
            "detail": str((r.get("data") or {}).get("detail") or (r.get("data") or {}).get("built") or "")[:300]}


def standing(fx: list[dict], census: list[list[float]], after: dict[str, dict]) -> list[dict]:
    """Which stand-in pieces still stand: the same piece type within 0.3 m in get_state's structures, else no census
    point there at all = gone; a census point but no typed read = unknown (out of get_state's reach, or a new piece
    of his on the same spot)."""
    out = []
    for q in fx:
        same = any(v.get("piece") == q["piece"] and v.get("position") and math.dist(v["position"], q["position"]) <= 0.3
                   for v in after.values())
        pt = any(math.dist(c, q["position"]) <= 0.3 for c in census)
        out.append({**q, "state": "standing" if same else ("gone" if not pt else "unknown")})
    return out


def items(new: list[dict], tl: dict, fx_state: list[dict] | None) -> dict:
    """Rung 2's item list, each from game state: the stand-in torn down, his own house (foundation, walls, roof, door in
    a frame), a crafting table, a firepit and a crate (new pieces in the census, his), and items stored in his crate."""
    names = [str(n.get("name") or "") for n in new if n.get("mine") is not False]

    def has(*w):
        return any(any(x.lower() in nm.lower() for x in w) for nm in names)
    crates = {n["id"] for n in new if "Crate" in str(n.get("name") or "")}
    stored = [c for c in tl.get("calls") or [] if c.get("tool") == "store" and c.get("ok")
              and (not crates or str((c.get("args") or {}).get("container") or "") in crates)]
    out = {"house_foundation": has("Foundation"), "house_walls": has("Wall"), "house_roof": has("Roof"),
           "house_door": any(nm == "Door" for nm in names) and has("Door Frame"), "crafting_table": has("Crafting Table"),
           "firepit": has("Campfire", "Fire Pit", "Firepit"), "crate": has("Crate"), "stored": bool(stored)}
    if fx_state is not None:
        gone = sum(1 for q in fx_state if q["state"] == "gone")
        out["teardown"] = bool(fx_state) and gone == len(fx_state)
        out["teardown_detail"] = (f"{gone} of {len(fx_state)} gone, "
                                  f"{sum(1 for q in fx_state if q['state'] == 'standing')} standing")
    out["all"] = all(v for k, v in out.items() if k != "teardown_detail")
    return out


def judge(t0: float, t1: float, line: str, outcome: dict) -> dict:
    """Every report true: tools/truth_judge.py (Haiku, the facts of the window, the census outcome)."""
    from tools import truth_check as tc
    from tools import truth_judge as tj
    v = tc.analyse_window(ROOT, t0 - 1, t1 + 1)
    v = tj.apply(v, {"request": line, "kind": "build", "t0": t0, "outcome": outcome})
    j = v.get("judge") or {}
    return {"truthful": v.get("truthful"), "source": v.get("truth_source"),
            "flags": [{k: f.get(k) for k in ("kind", "claim", "why")} for f in v.get("flags") or []][:6],
            "unverified": len(v.get("unverified") or []), "usd": j.get("usd"), "error": v.get("judge_error")}


def score(t0: float, t1: float, who: str = "ClaudeDev") -> dict:
    from tools import recorder_io as rio
    from tools import standard_score as ss
    rec = rio.load(since=t0 - 5, until=t1 + 5)
    w = rec.canon(who)
    m = ss.score_window(rec, w, t0, t1, "build") if w else {}
    spawns = [r["ts"] for r in rec.rpcs(w, t0, t1) if r.get("rpc") == "build_spawn"] if w else []
    base = (ss.latest_baselines().get("families") or {}).get("build") or {}
    n = len(spawns)
    return {"who": w, "build_spawns": n, "spawn_gaps_s": [round(b - a, 1) for a, b in zip(spawns, spawns[1:])],
            "work_s": m.get("work_s"), "unit_s": m.get("unit_s") if n else None, "path_m": m.get("path_m"),
            "idle_s": m.get("idle_s"), "luis_unit_s": base.get("unit_s"),
            "luis_base_s_per_piece": round(LUIS_BASE["wall_s"] / LUIS_BASE["pieces"], 2),
            "wall_s_per_piece": round((t1 - t0) / n, 1) if n else None}


def cmd_run(a) -> int:
    if not a.confirm:
        print("refusing: a live run starts a brain, moves Claude and spends materials on the dev server; pass --confirm")
        return 2
    a.start_brain, a.use_running_brain = True, False
    from tools.live_lock import held
    from tools import m1_session, spend
    from tools.quest_run import timeline
    with held("build", a.wait):
        t_wait = time.time()
        while cl.recent_bridge_driver() is not None and time.time() - t_wait < 70:
            time.sleep(5)
        bad = cl.preflight(a)
        if bad:
            print("not running:\n  " + "\n  ".join(bad))
            return 3
        subprocess.run([sys.executable, "-m", "tools.supply", "--heal"], cwd=str(ROOT))
        ok, how = cl.ensure_sender()
        if not ok:
            print("sender:", how)
            return 4
        cli = cl._debug_client()
        site = None
        if a.at or a.fresh:  # harness setup, before the line and the clock: stand him on the fresh spot "here" means
            census = all_pieces()
            pts = census.get("pts") or []
            if a.at:
                spot, how = [float(v) for v in a.at.split(",")], "given"
            else:
                skills = ROOT / "data" / "skills" / a.nav_world
                nav = json.loads((skills / "nav_memory.json").read_text(encoding="utf-8"))
                mine = skills / "my_pieces.json"
                base = (home(json.loads(mine.read_text(encoding="utf-8")).get("pieces") or []) if mine.exists() else None)                     or census.get("me") or [0, 0, 0]
                # rung 2: the stand-in goes 8 m off the spot and spans 6.4 m more, and all of it stays GUARD_M clear
                clear = GUARD_M + math.hypot(*FIXTURE_AT) + FIXTURE_HALF_M + 1.0 if a.rung2 else CLEAR_M
                # rung 2: level within 1.0 m over 8 m (the stand-in on a slope never settled, 02:3xZ), a wider ring (the dev
                # world near his base is built up: "no fresh spot" at 45 m clear within 110 m, 02:4xZ)
                spot = (fresh_spot(pts, base, nav, clear, ring=(40.0, 220.0), level_m=1.0, stand=(-FIXTURE_AT[0], -FIXTURE_AT[1]))
                        if a.rung2 else fresh_spot(pts, base, nav, clear))
                how = f"census ({len(pts)} pieces), {clear:.0f}+ m clear, near his base {base}"
                if spot is None:
                    print("no fresh spot found near him")
                    return 6
            g = cli.request("go_to", {"target": spot}, timeout=150)
            here = ((cli.request("me", {}, timeout=10) or {}).get("data") or {}).get("position")
            site = {"spot": spot, "chosen": how, "nearest_piece": nearest_piece(spot, pts) if pts else None,
                    "census_pieces": len(pts), "go_to_ok": g.get("ok"), "go_to_reason": g.get("reason"), "stands_at": here}
            print(f"at: {json.dumps(site)}")
        fx = None
        if a.rung2:
            if not site:
                print("--rung2 needs --fresh or --at (the stand-in goes beside the spot)")
                return 7
            fx = fixture_house(cli, site["spot"], pts)
            print(f"fixture: {json.dumps({k: v for k, v in fx.items() if k != 'pieces'})}")
            if fx.get("reason") == "guard":
                print(f"guard: the stand-in is not {GUARD_M:.0f} m clear of every built piece; not sending the line")
                return 9
            if fx["n"] < 9:
                print("the stand-in house did not go up; not sending the line")
                return 8
            cli.request("go_to", {"target": [site["spot"][0] - FIXTURE_AT[0], site["spot"][1] - FIXTURE_AT[1], site["spot"][2]]}, timeout=60)
        before = structures(cli)
        spent0 = spend.spend_today()["spent_usd"]
        p, brain_file = cl.start_brain(a, spent0)
        if brain_file is None:
            cl.stop_brain(p)
            print("brain did not start")
            return 5
        t0 = time.time()
        okl, _ = m1_session.send_speech_direct(a.line)
        why, ended = None, None
        try:
            while True:
                now = time.time()
                rows = cl.brain_rows([brain_file], t0 - 1, now + 1)
                tl = timeline(rows, t0)
                calls = cl.model_calls(rows)
                busy = [r for r in rows if r.get("kind") in ("prompt", "llm_response", "tool_call", "tool_result", "say")]
                open_prompt = bool(busy) and busy[-1].get("kind") == "prompt"
                # a call still open counts only if no model reply came after it: a turn stops at its first failure,
                # so a later call of that turn never runs and never gets a result (live 19:42Z: a `look` after a
                # failed build stayed "open" and the run never went quiet)
                last_llm = max((float(r.get("ts") or 0) for r in rows if r.get("kind") == "llm_response"), default=0.0)
                open_tool = any(c.get("dur_s") is None and t0 + c["t"] >= last_llm for c in tl["calls"])
                quiet = now - max(tl["last_busy"], float(busy[-1]["ts"]) if busy else t0)
                if calls["haiku"] > a.max_haiku:
                    why = "haiku cap"
                elif now - t0 > a.deadline:
                    why = "deadline"
                elif not open_prompt and not open_tool and quiet >= QUIET_S and calls["calls"]:
                    why = "quiet"
                if why:
                    ended = now
                    break
                time.sleep(POLL_S)
        finally:
            time.sleep(2.0)
            cl.stop_brain(p)
        after = structures(cli)
        census_after = (all_pieces().get("pts") or []) if fx else []
    rows = cl.brain_rows([brain_file], t0 - 1, ended + 3)
    tl = timeline(rows, t0)
    calls = cl.model_calls(rows)
    results = build_results(rows)
    new = [{"id": k, "name": v.get("name"), "position": v.get("position"), "mine": v.get("mine")}
           for k, v in after.items() if k not in before]
    gone = [k for k in before if k not in after]
    rec = {"run": time.strftime("%Y%m%d-%H%M%S", time.gmtime(t0)), "line": a.line, "sent": okl, "ended": why,
           "wall_s": round(ended - t0, 1), "t0": t0, "t1": ended, "site": site, "pieces_new": new, "pieces_gone": gone,
           "builds": [{k: b[k] for k in ("ok", "reason", "structure", "name", "attached_to", "side", "flush")}
                      | {"t": round(b["ts"] - t0, 1)} for b in results],
           "truth": truth(results, after), "score": score(t0, ended),
           "tool_calls": tl["calls"], "says": tl["says"], "idle_over_5s": tl["idle"],
           "idle_total_s": round(sum(i["s"] for i in tl["idle"]), 1),
           "haiku": calls["haiku"], "sonnet": calls["sonnet"], "usd": calls["usd"], "brain_log": brain_file.name}
    if fx is not None:
        fx_state = standing(fx["pieces"], census_after, after)
        decon = [c for c in tl["calls"] if c.get("tool") == "deconstruct"]
        rec["fixture"] = {k: v for k, v in fx.items() if k != "pieces"} | {"state": fx_state}
        rec["items"] = items(new, tl, fx_state)
        rec["teardown"] = {"calls": len(decon), "s": round(sum(float(c.get("dur_s") or 0) for c in decon), 1),
                           "pieces": len(fx_state)}
        rec["judge"] = judge(t0, ended, a.line, {"check": "the stand-in house torn down; his own house (foundation, walls, "
                             "roof, door), crafting table, firepit and crate built; items stored in his crate",
                             "done": rec["items"]["all"], "how": json.dumps(rec["items"])})
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec) + "\n")
    show(rec)
    return 0


def show(rec: dict) -> None:
    print(json.dumps({k: rec.get(k) for k in ("line", "ended", "wall_s", "haiku", "sonnet", "usd", "idle_total_s", "score",
                                              "items", "teardown", "judge") if k in rec}, indent=1))
    print("new pieces:", json.dumps(rec.get("pieces_new"))[:1500])
    for v in rec.get("truth") or []:
        print("  truth", v)
    for c in rec.get("tool_calls") or []:
        print(f"  {c['t']:6.1f}s {c['tool']:<12} {c.get('dur_s')!s:>6}s ok={c.get('ok')} {c.get('reason') or ''} "
              f"{json.dumps(c.get('args'))[:90]} | {c.get('detail', '')}")
    for s in rec.get("says") or []:
        print(f"  {s['t']:6.1f}s say: {s['text']}")


def _ts(s: str) -> float:
    return datetime.fromisoformat(s.replace("Z", "+00:00")).replace(tzinfo=timezone.utc).timestamp()


def cmd_score(a) -> int:
    print(json.dumps(score(_ts(a.since), _ts(a.until), a.who), indent=1))
    return 0


def cmd_report(a) -> int:
    if not OUT.exists():
        print("no runs yet")
        return 0
    for line in OUT.read_text(encoding="utf-8").splitlines()[-a.n:]:
        r = json.loads(line)
        s = r.get("score") or {}
        bad = sum(1 for v in r.get("truth") or [] if v.get("verdict") != "true")
        print(f"{r['run']} {r['ended']:<9} {r['wall_s']:>6}s new={len(r.get('pieces_new') or [])} spawns={s.get('build_spawns')} "
              f"unit_s={s.get('unit_s')} (Luis {s.get('luis_unit_s')}) untrue={bad} haiku={r['haiku']} sonnet={r['sonnet']} ${r['usd']}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--confirm", action="store_true")
    r.add_argument("--line", default="claude build yourself a small house here")
    r.add_argument("--deadline", type=float, default=1500.0)
    r.add_argument("--max-haiku", type=int, default=80)
    r.add_argument("--usd", type=float, default=1.5, help="this run's spend cap on top of today's spend")
    r.add_argument("--world", default="dev_build")
    r.add_argument("--wait", type=float, default=1800.0, help="seconds to wait for the live lock")
    r.add_argument("--at", default="", help="x,y,z metres: walk him there first (the fresh spot the line's 'here' means)")
    r.add_argument("--fresh", action="store_true", help=f"pick the spot from the census: {CLEAR_M:.0f}+ m from any built piece, near him")
    r.add_argument("--nav-world", default="dev", help="the body's world id for its nav memory (data/skills/<id>)")
    r.add_argument("--rung2", action="store_true", help="the Rung 2 streak run: a stand-in of Luis's house goes up beside "
                   "the spot first (harness fixture), then the line (default RUNG2_LINE) asks for all of rung 2")
    sc = sub.add_parser("score")
    sc.add_argument("--since", required=True)
    sc.add_argument("--until", required=True)
    sc.add_argument("--who", default="ClaudeDev")
    rp = sub.add_parser("report")
    rp.add_argument("-n", type=int, default=10)
    a = ap.parse_args(argv)
    if a.cmd == "run" and a.rung2 and a.line == "claude build yourself a small house here":
        a.line = RUNG2_LINE
    return {"run": cmd_run, "score": cmd_score, "report": cmd_report}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())

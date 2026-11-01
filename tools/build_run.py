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


def build_results(rows: list[dict]) -> list[dict]:
    out = []
    for r in rows:
        if r.get("kind") != "tool_result" or r.get("tool") != "build":
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
                open_tool = any(c.get("dur_s") is None for c in tl["calls"])
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
    rows = cl.brain_rows([brain_file], t0 - 1, ended + 3)
    tl = timeline(rows, t0)
    calls = cl.model_calls(rows)
    results = build_results(rows)
    new = [{"id": k, "name": v.get("name"), "position": v.get("position"), "mine": v.get("mine")}
           for k, v in after.items() if k not in before]
    gone = [k for k in before if k not in after]
    rec = {"run": time.strftime("%Y%m%d-%H%M%S", time.gmtime(t0)), "line": a.line, "sent": okl, "ended": why,
           "wall_s": round(ended - t0, 1), "t0": t0, "t1": ended, "pieces_new": new, "pieces_gone": gone,
           "builds": [{k: b[k] for k in ("ok", "reason", "structure", "name", "attached_to", "side", "flush")}
                      | {"t": round(b["ts"] - t0, 1)} for b in results],
           "truth": truth(results, after), "score": score(t0, ended),
           "tool_calls": tl["calls"], "says": tl["says"], "idle_over_5s": tl["idle"],
           "idle_total_s": round(sum(i["s"] for i in tl["idle"]), 1),
           "haiku": calls["haiku"], "sonnet": calls["sonnet"], "usd": calls["usd"], "brain_log": brain_file.name}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec) + "\n")
    show(rec)
    return 0


def show(rec: dict) -> None:
    print(json.dumps({k: rec.get(k) for k in ("line", "ended", "wall_s", "haiku", "sonnet", "usd", "idle_total_s", "score")}, indent=1))
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
    sc = sub.add_parser("score")
    sc.add_argument("--since", required=True)
    sc.add_argument("--until", required=True)
    sc.add_argument("--who", default="ClaudeDev")
    rp = sub.add_parser("report")
    rp.add_argument("-n", type=int, default=10)
    a = ap.parse_args(argv)
    return {"run": cmd_run, "score": cmd_score, "report": cmd_report}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())

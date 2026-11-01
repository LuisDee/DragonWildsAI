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
POLL_S = 3.0
QUIET_S = 40.0
IDLE_S = 5.0


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


def timeline(rows: list[dict], t0: float) -> dict:
    """Tool calls (start, duration, result), speech, and the idle stretches between brain activity."""
    calls, open_ = [], {}
    says = []
    busy: list[tuple[float, float]] = []  # intervals with a tool running or a model call in flight
    prompt_at = None
    for r in rows:
        k, ts = r.get("kind"), float(r.get("ts") or 0)
        key = r.get("call") or r.get("task_id") or f"{r.get('tool')}@{ts}"
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
    for c in calls:
        c.pop("_ts", None)
    busy.sort()
    idle, cur = [], t0
    for a, b in busy:
        if a - cur > IDLE_S:
            idle.append({"from": round(cur - t0, 1), "s": round(a - cur, 1)})
        cur = max(cur, b)
    return {"calls": calls, "says": says, "idle": idle, "last_busy": cur}


def cmd_run(a) -> int:
    if not a.confirm:
        print("refusing: a live run moves Claude and sends test chat on the dev server; pass --confirm")
        return 2
    a.start_brain, a.use_running_brain = True, False
    from tools.live_lock import held
    from tools import m1_session
    import subprocess
    with held("quests", a.wait):
        t_wait = time.time()  # the last holder may have driven him a moment ago: give its commands 60 s to age out
        while cl.recent_bridge_driver() is not None and time.time() - t_wait < 70:
            time.sleep(5)
        bad = cl.preflight(a)
        if bad:
            print("not running:\n  " + "\n  ".join(bad))
            return 3
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
                open_tool = any(c.get("dur_s") is None for c in tl["calls"])
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
            for tool in ("stop", "talk"):
                try:
                    cli.request(tool, {"leave": True} if tool == "talk" else {}, timeout=15)
                except Exception:
                    pass
    rows = cl.brain_rows([brain_file], t0 - 1, ended + 3)
    tl = timeline(rows, t0)
    calls = cl.model_calls(rows)
    rec = {"run": time.strftime("%Y%m%d-%H%M%S", time.gmtime(t0)), "quest": a.quest, "until": a.until,
           "lines": sent, "fixtures": fixtures, "ended": why, "wall_s": round(ended - t0, 1), "steps": steps,
           "done": steps[-1].get("state") == "complete" if a.until == "complete" else len(steps) > 1,
           "tool_calls": tl["calls"], "says": tl["says"], "idle_over_5s": tl["idle"],
           "idle_total_s": round(sum(i["s"] for i in tl["idle"]), 1),
           "haiku": calls["haiku"], "sonnet": calls["sonnet"], "usd": calls["usd"], "brain_log": brain_file.name}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec) + "\n")
    print(json.dumps({k: rec[k] for k in ("quest", "ended", "wall_s", "done", "steps", "idle_total_s", "haiku", "sonnet", "usd")}, indent=1))
    for c in tl["calls"]:
        print(f"  {c['t']:6.1f}s {c['tool']:<12} {c.get('dur_s')!s:>6}s ok={c.get('ok')} {c.get('reason') or ''} "
              f"{json.dumps(c.get('args'))[:80]} | {c.get('detail', '')}")
    for s in tl["says"]:
        print(f"  {s['t']:6.1f}s say: {s['text']}")
    return 0 if rec["done"] else 1


def cmd_report(a) -> int:
    if not OUT.exists():
        print("no runs yet")
        return 0
    for line in OUT.read_text(encoding="utf-8").splitlines()[-a.n:]:
        r = json.loads(line)
        print(f"{r['run']} {r['quest']:<18} {r['ended']:<16} {r['wall_s']:>6}s done={r['done']} "
              f"calls={len(r['tool_calls'])} idle={r['idle_total_s']}s haiku={r['haiku']} sonnet={r['sonnet']} ${r['usd']}")
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
    rp = sub.add_parser("report")
    rp.add_argument("-n", type=int, default=10)
    a = ap.parse_args(argv)
    return {"run": cmd_run, "report": cmd_report}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())

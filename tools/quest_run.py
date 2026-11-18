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

Working one quest (or one step of it) alone, before any chain (docs/GOAL-2026-11-01.md "How the work is run"):
    ... -m tools.quest_run step --confirm --from rm_part2 --quest "Rune Mysteries" -k 5    # 5 trials from a checkpoint
    ... -m tools.quest_run rates                                  # pass rate and streak per item, void runs left out
`step` forks a checkpoint (tools/quest_clone.py) into K new characters in ONE lock window, runs the quest on each and
prints passes of K. A checkpoint kept by --save-as is a pair (tools/checkpoint_pair.py: the save and the world of
that moment); each trial from a pair restores its world and plays its own character (same guid) instead of a fork. `fresh` (the whole chain: the 3-in-a-row gate) refuses to start while a quest in it has not passed
4 of its last 5 counted trials.
"""
from __future__ import annotations

import argparse
import contextlib
import json
import math
import sys
import time
from pathlib import Path

from brain import paths
from tools import live_guard, obs, spend
from tools import chat_ladder as cl

ROOT = paths.REPO_ROOT
OUT = ROOT / "logs" / "evals" / "quest_runs.jsonl"
FRESH_OUT = ROOT / "logs" / "evals" / "quest_fresh.jsonl"
STEP_OUT = ROOT / "logs" / "evals" / "quest_steps.jsonl"
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


CODE_DIRS = ("client_mod", "brain")  # what a window plays with; the Lua hot-loads into the running client


def dirty_code(root: Path = ROOT) -> list[str]:
    """Uncommitted changes under client_mod/ and brain/, as git's short status rows. A window plays the working tree,
    not a commit: on 2026-11-16/17 an unfinished combat.lua hot-loaded into a trial for 19 s and cost the window.
    Empty when git cannot say."""
    import subprocess
    try:
        out = subprocess.run(["git", "status", "--porcelain", "--", *CODE_DIRS], cwd=root, capture_output=True,
                             text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return []
    return [row.strip() for row in out.stdout.splitlines() if row.strip()] if out.returncode == 0 else []


def refuse_dirty(a, rows: list[str] | None = None) -> bool:
    """True (and says why) when a window would start on uncommitted code. --dirty-ok REASON lets it run and prints the
    reason, so the window's log holds it. Not asked inside a window (in_lock): its start was checked."""
    rows = dirty_code() if rows is None else rows
    if not rows or getattr(a, "in_lock", False):
        return False
    if getattr(a, "dirty_ok", None):
        print(f"running on uncommitted code ({len(rows)} files): {a.dirty_ok}")
        return False
    print("not running: uncommitted changes in " + " or ".join(d + "/" for d in CODE_DIRS) + " (a window plays the "
          "working tree):\n  " + "\n  ".join(rows[:12]) + "\ncommit them, or pass --dirty-ok REASON")
    return True


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


def carried(cli, quest: str | None) -> dict[str, int]:
    """The quest's deliverables he already holds at its start ({item: count}; data/quest_deliverables.json). A run
    that starts holding any did not do the quest's work (live ClaudeQ2-Q5: an inherited Stone Club made Getting
    Started one talk, four Rat Roasts made Ratcatcher one), so it is recorded as not counted. quest None: every
    quest's deliverables (the read at a chain's start)."""
    by_quest = json.loads(DELIVERABLES.read_text(encoding="utf-8")).get("quests") or {}
    items = by_quest.get(quest) or [] if quest else sorted({i for l in by_quest.values() for i in l})
    if not items:
        return {}
    st = cli.request("get_state", {}, timeout=15)
    inv = ((st.get("data") or {}).get("inventory") if isinstance(st, dict) else None) or {}
    return {i: inv[i] for i in items if inv.get(i)}


HEAD_START_SHARE = 0.1


def head_start(held: dict, quest: str, chain: dict | None = None) -> dict:
    """The deliverables held at the start that did part of the quest's work: every one, except a leftover under a
    tenth of an amount the quest asks for (data/quest_deliverables.json "amounts"; none given = 1, so any counts).
    Chain 101313: one Ash Log left from the fire of the quest before, 49 of Zanik's 50 chopped in the run. The human
    bar is computed from what he gathered in the run, so a leftover does not make the bar easier.
    chain: what he held of them when the chain of quests began (cmd_fresh reads it). Only that much can be a head
    start: the rest he got earlier in the same chain, on the clock of the quest before and against its bar (chain
    112351: 7 Ash Logs chopped in Getting Started, 8 held at Rune Mysteries, 42 chopped for a bar of 42)."""
    amounts = (json.loads(DELIVERABLES.read_text(encoding="utf-8")).get("amounts") or {}).get(quest) or {}
    if isinstance(chain, dict) and "error" not in chain and "error" not in (held or {}):
        held = {k: min(v, chain.get(k, 0)) for k, v in (held or {}).items() if isinstance(v, (int, float))}
        held = {k: v for k, v in held.items() if v > 0}
    return {k: v for k, v in (held or {}).items()
            if not isinstance(v, (int, float)) or v >= max(1, HEAD_START_SHARE * amounts.get(k, 1))}


def not_counted(rec: dict) -> str | None:
    """Why a run does not count, or None. From what he held at its start; a record without that read keeps what was
    written in it."""
    if rec.get("checkpoint"):  # a trial from a checkpoint starts mid-quest by design: its own item (item_key)
        return None
    held = rec.get("carried_at_start")
    if not isinstance(held, dict):
        return rec.get("not_counted")
    hs = head_start(held, rec.get("quest") or "", rec.get("held_at_chain_start"))
    return ("deliverable carried: " + ", ".join(f"{k} x{v}" for k, v in hs.items())) if hs else None


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
    # read-only calls (look, recipes, ...) carry no call or task id: their result closes the oldest open call of the same
    # tool that has none (keyed by its own time, a look's call stayed open for ever and the L2 trial of 2026-11-17 never
    # ended "quiet": it ran on to its deadline)
    idless: dict[str, list[str]] = {}
    for r in rows:
        k, ts = r.get("kind"), float(r.get("ts") or 0)
        key = r.get("call") or r.get("task_id")
        if key is None and k == "tool_call":
            key = f"{r.get('tool')}@{ts}"
            idless.setdefault(str(r.get("tool")), []).append(key)
        elif key is None and k == "tool_result":
            q_ = idless.get(str(r.get("tool"))) or []
            key = q_.pop(0) if q_ else f"{r.get('tool')}@{ts}"
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
            "misses": len(misses) <= 1, "stands": not stands, "counted": not not_counted(rec)}
    return {"pass": all(bars.values()), "bars": bars, "misses": misses, "truth": "not judged"}


def cmd_run(a) -> int:
    if not a.confirm:
        print("refusing: a live run moves Claude and sends test chat on the dev server; pass --confirm")
        return 2
    if refuse_dirty(a):
        return 7
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
        until_step = (getattr(a, "until_step", None) or "").lower()  # end when the quest's step reads like this
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
                elif until_step and len(steps) > 1 and until_step in str(row.get("step") or "").lower():
                    why = "quest step reached"
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
           "done": (steps[-1].get("state") == "complete" or why == "quest step reached") if a.until == "complete"
           else len(steps) > 1,
           "tool_calls": tl["calls"], "says": tl["says"], "idle_over_5s": tl["idle"],
           "idle_total_s": round(sum(i["s"] for i in tl["idle"]), 1),
           "longest_stand_s": max([i["s"] for i in tl["idle"]], default=0),
           "haiku": calls["haiku"], "sonnet": calls["sonnet"], "usd": calls["usd"], "brain_log": brain_file.name,
           "holds": holds(tl["calls"]), "dialogue_left": {"before": left_before, "after": left_after},
           "carried_at_start": held_at_start}
    if getattr(a, "chain_held", None) is not None:
        rec["held_at_chain_start"] = a.chain_held
    if getattr(a, "checkpoint", None):
        rec["checkpoint"], rec["until_step"] = a.checkpoint, getattr(a, "until_step", None)
    if not_counted(rec):
        rec["not_counted"] = not_counted(rec)
    elif held_at_start:
        rec["leftover"] = ", ".join(f"{k} x{v}" for k, v in held_at_start.items())
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


@live_guard.live_entry("a lock window on forked characters (quest_run/job_run)")
@contextlib.contextmanager
def clone_window(wait_s: float, out: dict, out_file: Path):
    """ONE lock window on other characters of Claude's own account (evals/bench/devchar.py, dev world): yields
    (switch, client, t0); whatever the body of the window does or raises, it ends back on ClaudeDev with his pawn seen
    and `out` appended to out_file. The lock is never released while the client is on another character."""
    from evals.bench.devchar import default_switch
    from evals.bench.devrun import default_dev
    from tools.live_lock import held
    with held("quests", wait_s):
        t0 = time.time()
        dev = default_dev()
        dev.brain_running = lambda: False
        sw = default_switch(dev)
        cli = cl._debug_client()
        try:
            yield sw, cli, t0
        except Exception as exc:
            out["error"] = repr(exc)[:400]
            print("window error:", out["error"])
        finally:
            back = _on_main(sw, cli)
            out["back"] = back
            out["window_s"] = round(time.time() - t0, 1)
            out_file.parent.mkdir(parents=True, exist_ok=True)
            with out_file.open("a", encoding="utf-8") as f:
                f.write(json.dumps(out) + "\n")
            print(json.dumps(out, indent=1)[:3000])
            while back is None:  # never release the lock while the client is on another character (main's rule)
                print("STUCK: the client is not back on ClaudeDev; keeping the lock and retrying every 2 min")
                time.sleep(120)
                back = _on_main(sw, cli, tries=1)


def _last_run() -> dict:
    return json.loads(OUT.read_text(encoding="utf-8").splitlines()[-1])  # the record cmd_run just wrote


def _summary(last: dict) -> dict:
    v = last.get("verdict") or {}
    return {"run": last.get("run"), "pass": v.get("pass"), "ratio": last.get("ratio"), "ended": last.get("ended"),
            "misses": len(v.get("misses") or []), "longest_stand_s": last.get("longest_stand_s")}


def all_runs() -> list[dict]:
    if not OUT.exists():
        return []
    return [json.loads(line) for line in OUT.read_text(encoding="utf-8").splitlines() if line.strip()]


def item_key(rec: dict) -> str:
    """What a run is a trial of: the quest from its start, or the quest from a checkpoint (to a step, when given)."""
    if not rec.get("checkpoint"):
        return rec.get("quest") or "?"
    return f"{rec.get('quest')} @ {rec['checkpoint']}" + (f" -> {rec['until_step']}" if rec.get("until_step") else "")


def trials(recs: list[dict], void: set[str]) -> list[tuple[dict, bool]]:
    """(run, passed) of the runs that say something about him, oldest first: to completion (not a probe to the first
    change of step), counted (no head start), and not void (the ledger's word that the harness was at fault)."""
    return [(r, verdict(r)["pass"]) for r in recs
            if r.get("until") == "complete" and r["run"] not in void and not not_counted(r)]


def rates(recs: list[dict], void: set[str], n: int = 10) -> dict[str, dict]:
    """Per item: passes of its newest n trials, and the streak of passes up to the newest (the goal's gate is a
    streak of 3 on the quest from its start; a checkpoint item only says whether the gate is worth trying)."""
    by: dict[str, list[bool]] = {}
    for r, ok in trials(recs, void):
        by.setdefault(item_key(r), []).append(ok)
    out = {}
    for k, oks in by.items():
        last = oks[-n:]
        streak = next((i for i, ok in enumerate(reversed(oks)) if not ok), len(oks))
        out[k] = {"passes": sum(last), "of": len(last), "streak": streak}
    return out


GUARD_OF, GUARD_NEED = 5, 4


def chain_guard(recs: list[dict], void: set[str], quest_names: list[str]) -> list[str]:
    """Why the whole chain should not run yet: a quest in it that has not passed GUARD_NEED of its newest GUARD_OF
    trials (from its start or from a checkpoint). A chain costs 15 to 26 minutes of the one body and resets every
    streak on one failure, so it is the last step, not the way to find out (17 h run of 2026-11-15/16: 13 chains,
    Rune Mysteries 2 of 14)."""
    why = []
    for q in quest_names:
        last = [ok for r, ok in trials(recs, void) if r.get("quest") == q][-GUARD_OF:]
        if sum(last) < GUARD_NEED:
            why.append(f"{q}: {sum(last)} of its last {len(last)} trial(s) passed (need {GUARD_NEED} of {GUARD_OF})")
    return why


def cmd_fresh(a) -> int:
    """ONE lock window for a quest-cleared clone of ClaudeDev (main + Luis, 2026-11-01: tools/quest_clone.py, made
    here if its save does not exist yet; same level and gear, the FTUE chain cleared): switch to it, run FRESH_PLAN
    in one go with no fixture top-ups, and switch back (clone_window)."""
    if not a.confirm:
        print("refusing: this relaunches the client on a new character; pass --confirm")
        return 2
    if refuse_dirty(a):
        return 7
    import argparse as ap_
    from evals.bench.devchar import NAME_RE
    from tools import failure_ledger
    name = a.name or f"ClaudeQ{time.strftime('%d%H%M', time.gmtime())}"
    if not NAME_RE.match(name):
        print(f"invalid character name {name!r}")
        return 2
    names = [q for q, _, _ in FRESH_PLAN]
    plan = FRESH_PLAN[names.index(a.start):] if a.start in names else FRESH_PLAN
    blocked = chain_guard(all_runs(), failure_ledger.voided(), [q for q, _, _ in plan])
    if blocked and not a.chain_anyway:
        print("not running the chain:\n  " + "\n  ".join(blocked) + "\nwork each alone first (quest_run step), "
              "or pass --chain-anyway REASON")
        return 6
    out = {"window": time.strftime("%Y%m%d-%H%M%S", time.gmtime()), "character": name, "runs": []}
    if blocked:
        out["chain_anyway"] = {"reason": a.chain_anyway, "guard": blocked}
    with clone_window(a.wait, out, FRESH_OUT) as (sw, cli, t0):
        if not sw.exists(name):
            from tools import quest_clone
            if quest_clone.main(["make", "--name", name]) != 0:
                raise RuntimeError(f"quest_clone could not make {name}")
        made = sw.ensure(name, create=False, wait_s=150)
        out["made"] = {**made, "s": round(time.time() - t0, 1)}
        print(f"[{time.time() - t0:6.1f}s] on {name}: {made}")
        try:  # what he holds of any quest's deliverables now: only that can be a head start later (head_start)
            chain_held = carried(cli, None)
        except Exception as exc:
            chain_held = {"error": repr(exc)[:120]}
        out["held_at_chain_start"] = chain_held
        for quest, line, deadline in plan:
            left = a.window_s - a.reserve_s - (time.time() - t0)
            if left < 90:
                out["runs"].append({"quest": quest, "skipped": f"window: {left:.0f} s left"})
                break
            ns = ap_.Namespace(confirm=True, quest=quest, line=[line], until="complete", deadline=min(deadline, left),
                               max_haiku=a.max_haiku, usd=a.usd, world=f"dev_{name}", wait=0, grant=[], judge=False,
                               in_lock=True, no_heal=True, character=name, chain_held=chain_held)
            rc = cmd_run(ns)
            out["runs"].append({"quest": quest, "rc": rc, "at_s": round(time.time() - t0, 1), **_summary(_last_run())})
            if rc != 0:
                break  # the next quest is given by this one
    return 0 if all(r.get("rc") == 0 for r in out["runs"]) and out["runs"] and out["runs"][-1].get("quest") == FRESH_PLAN[-1][0] else 1


SWITCH_S = 70.0  # a switch of character, measured (quest_fresh.jsonl "made.s": 57 to 67 s)
AUTOSAVE_S = 330.0  # the client writes a character's save every 5 minutes


START_M = 6.0  # a trial starts within this of where the checkpoint's save was written


def to_start(cli, place: list[float] | None, tries: int = 4, timeout: float = 200.0) -> dict | None:
    """Walk the fork to where its checkpoint was saved, before the trial's clock: the server spawns a new guid at the
    world spawn (quest_clone.place_of). Harness work on Claude's own fork, not part of the trial. None = the save
    names no place."""
    if not place:
        return None
    t, r = time.time(), None
    for i in range(tries):
        r = cli.request("go_to", {"target": place}, timeout=timeout)
        d = (r.get("data") if isinstance(r, dict) else None) or {}
        if isinstance(r, dict) and r.get("ok"):
            return {"place": place, "ok": True, "walk_s": round(time.time() - t, 1), "tries": i + 1, "trip": d.get("trip")}
    st = cli.request("get_state", {}, timeout=20)
    pos = ((st.get("data") if isinstance(st, dict) else None) or {}).get("position")
    near = bool(pos) and math.dist(pos, place) <= START_M
    return {"place": place, "ok": near, "walk_s": round(time.time() - t, 1), "tries": tries, "position": pos,
            "why": None if near else str((r or {}).get("data") if isinstance(r, dict) else r)[:300]}


def clock_on(dev, days: int, purpose: str, vitals: dict | None = None) -> dict:
    """A dev fixture (dev server only): move the game clock on by `days` days, less a few minutes, so that what
    earlier trials mined or picked has grown back when this one starts. Why: a mined node grows back after its
    RespawnDuration of GAME time (essence rocks: 2 days = 48 real minutes) and only while no player is within its
    MinimumDistanceToPlayers (100 m), so inside one window the third trial found the rocks spent (window
    20261116-173343: PASS, PASS, then three trials at 8 used-up rocks). Seen live 18:04Z: rocks spent at 17:50Z were
    whole again 3 minutes after the clock went on 3 days with him 215 m away. It uses the bench fixture set_time, one
    call per day (each sets the hour to just before the current one, so the time of day stays what it was).
    The server ages the one player on it through the skipped days: food and water to 0 and rest to 35 % within a
    second, and his reflex then eats and drinks from the bag (probe ClaudeP161838; window 20261116-181015 began three
    trials thirsty at 21 % with the water gone). So it runs on a fork that has played and is thrown away, never on the
    one about to play, and `vitals` (what get_state read just before) is put back with the fixture set_stat so the
    fork does not starve while it is still on the server.
    Limit: that fork stands within 100 m of what it mined, and a node grows back only with no player that near. It is
    taken that the node catches up once he has left (seen 17:07Z: a rock long overdue was whole ten minutes after he
    left); a window whose later trials find used-up rocks says this is wrong."""
    out: dict = {"days": 0, "advanced_h": 0.0}
    try:
        now = dev.setup("set_time", purpose=purpose, read=True)
        out["before"] = {"day": now.get("day"), "hour": round(float(now.get("hour") or 0), 2)}
        hour = float(now["hour"])
        for _ in range(days):
            r = dev.setup("set_time", purpose=purpose, hours=round((hour - 0.05) % 24, 3))
            out["days"] += 1
            out["advanced_h"] = round(out["advanced_h"] + float(r.get("advanced_h") or 0), 2)
            hour = float(r.get("after_h") if r.get("after_h") is not None else hour)
        out["ok"] = out["advanced_h"] >= 23.0 * days
    except Exception as exc:  # the trial still runs; its row says the clock did not move
        out["ok"], out["error"] = False, repr(exc)[:200]
    for stat, value in (vitals or {}).items():
        try:
            r = dev.setup("set_stat", purpose=purpose, stat=stat, value=value)
            out.setdefault("vitals_back", {})[stat] = round(float(r.get("after")), 1)
        except Exception as exc:
            out.setdefault("vitals_error", {})[stat] = repr(exc)[:120]
    return out


def vitals_of(cli) -> dict:
    """His food, water and rest as get_state reads them now ({stat: value}); {} when unreadable."""
    st = cli.request("get_state", {}, timeout=20)
    sv = ((st.get("data") if isinstance(st, dict) else None) or {}).get("survival") or {}
    return {k: v[0] for k, v in sv.items() if isinstance(v, list) and v and isinstance(v[0], (int, float))}


def cmd_step(a) -> int:
    """ONE lock window, K trials of one quest (or of it up to --until-step) from a checkpoint: each trial is a new
    fork of the checkpoint's save (tools/quest_clone.py fork), walked to where that save was written (to_start), so
    every trial starts from the same quest state, bag and place, and a fix is judged by passes of K instead of by one
    run. A fork that does not get to the place is not a trial. --save-as: when the first trial is done, wait for the
    game's next save of that fork and keep it as a new checkpoint (the next step's start)."""
    if not a.confirm:
        print("refusing: this relaunches the client on forked characters; pass --confirm")
        return 2
    if refuse_dirty(a):
        return 7
    import argparse as ap_
    from tools import quest_clone
    line = a.line or [l for q, l, _ in FRESH_PLAN if q == a.quest]
    if not line:
        print(f"no --line given and {a.quest!r} is not in FRESH_PLAN")
        return 2
    src = quest_clone.source_of(a.checkpoint)  # before the lock: a wrong label never costs a window
    place = quest_clone.place_of(a.checkpoint)
    if a.save_as and (quest_clone.CHECKPOINT_DIR / f"{a.save_as}.json").exists():
        print(f"checkpoint {a.save_as!r} exists already: pick a new --save-as label")
        return 2
    # a checkpoint pair (tools/checkpoint_pair.py): every trial restores its world and plays its own character
    from tools import checkpoint_pair as cpair
    others_ok = getattr(a, "others_ok", "") or ""
    pairs, pair, why = cpair.window_pair(a.checkpoint, others_ok, a.save_as)
    if why:
        print(f"not running: {why}")
        return 2
    stamp = time.strftime("%d%H%M", time.gmtime())
    forks = [f"ClaudeS{stamp}{chr(97 + i)}" for i in range(min(a.k, 26))]
    out = {"window": time.strftime("%Y%m%d-%H%M%S", time.gmtime()), "checkpoint": a.checkpoint, "source": str(src),
           "quest": a.quest, "until_step": a.until_step, "k": a.k, "place": place, "trials": []}
    if pair:
        out["pair"] = {k: pair[k] for k in ("world", "char_name", "char_guid", "char_saved_at")}
    used = []
    with clone_window(a.wait, out, STEP_OUT) as (sw, cli, t0):
        for i, name in enumerate(forks):
            left = a.window_s - a.reserve_s - (time.time() - t0) - SWITCH_S - (cpair.PAIR_S if pair else 0)
            if left < 90:
                out["trials"].append({"character": name, "skipped": f"window: {left:.0f} s left"})
                break
            try:
                got = cpair.start_character(a.checkpoint, name, pair, pairs, quest_clone.fork, others_ok)
            except SystemExit as exc:  # a refusal (the name is taken): the window's error, and the forks before it still get parked
                raise RuntimeError(f"fork: {exc}") from None
            except cpair.Refused as exc:
                raise RuntimeError(f"checkpoint pair: {exc}") from None
            name = got["name"]
            if not got["paired"]:
                used.append(name)
            made = sw.ensure(name, create=False, wait_s=150)
            print(f"[{time.time() - t0:6.1f}s] on {name}: {made}")
            fault = cpair.identity_fault(made, pair)
            if fault:
                out["trials"].append({"character": name, "skipped": fault, "void": "harness"})
                break
            if got["paired"]:
                got["prep"]["file_after_join"] = pairs.file_check(pair, got["prep"]["written_at"])
            start = to_start(cli, place)
            if start is not None:
                print(f"[{time.time() - t0:6.1f}s] to the checkpoint's place: {start}")
                left = a.window_s - a.reserve_s - (time.time() - t0)
                if not start["ok"] or left < 90:
                    out["trials"].append({"character": name, "start": start, "skipped": "not at the checkpoint's place"
                                          if not start["ok"] else f"window: {left:.0f} s left after the walk"})
                    continue
            memory = f"dev_{name}_{chr(97 + i)}" if got["paired"] else f"dev_{name}"  # a pair's trials share a name only
            ns = ap_.Namespace(confirm=True, quest=a.quest, line=list(line), until="complete", until_step=a.until_step,
                               deadline=min(a.deadline, left), max_haiku=a.max_haiku, usd=a.usd, world=memory,
                               wait=0, grant=[], judge=False, in_lock=True, no_heal=True, character=name,
                               checkpoint=a.checkpoint)
            rc = cmd_run(ns)
            t_end = time.time()
            last = _last_run()
            out["trials"].append({"character": name, "rc": rc, "at_s": round(t_end - t0, 1), "start": start, **_summary(last)})
            if got["paired"]:
                out["trials"][-1]["prep"] = {k: got["prep"].get(k) for k in
                                             ("s", "parked", "deaths_forgotten", "file_after_join")}
            keep_tried = False
            if a.save_as and last.get("done") and "saved_as" not in out:
                keep_tried = True
                try:  # the pair: his save and the world, both written after the trial ended
                    kept = pairs.keep(a.save_as, name, t_end=t_end, wait_s=AUTOSAVE_S,
                                      note=f"quest {a.quest} run {last.get('run')}", window=out["window"])
                except cpair.Refused as exc:
                    kept = {"kept": False, "why": str(exc)}
                if kept["kept"]:
                    out["saved_as"] = str(pairs.checkpoint_dir / f"{a.save_as}.json")
                    out["saved_pair"] = kept
                else:  # the next done trial tries again
                    out["trials"][-1]["not_saved"] = f"pair not kept: {kept['why']}"
            # now, on the fork that has played (after any --save-as): never on one about to play; not for a pair's
            # trials (the next one restores the world) nor after a pair keep (it stopped the client)
            if a.regrow_days > 0 and not got["paired"] and not keep_tried:
                from evals.bench.devrun import default_dev
                dev = default_dev()
                dev.brain_running = lambda: False
                # the fixture's guard wants the guid of the one player on the server: the fork, not ClaudeDev (the
                # first window with this refused all five: "other_players_connected")
                dev.character_guid, dev.character_name = made["guid"], name
                grown = clock_on(dev, a.regrow_days, f"quest_run step {a.checkpoint}: what this trial used grows back",
                                 vitals=vitals_of(cli))
                out["trials"][-1]["clock_after"] = grown
                print(f"[{time.time() - t0:6.1f}s] game clock moved on: {grown}")
    if out.get("back") and not a.keep_forks:  # back on ClaudeDev: the forks' saves leave the character list
        print("parked:", quest_clone.park(used))
        if pair:
            print("parked:", pairs.park(pair["char_name"], time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())))
    done = [t for t in out["trials"] if "pass" in t]
    print(f"== {a.quest} from {a.checkpoint}: {sum(1 for t in done if t['pass'])} of {len(done)} passed "
          f"({', '.join('PASS' if t['pass'] else 'FAIL ' + str(t['ended']) for t in done)})")
    return 0 if done and all(t["pass"] for t in done) else 1


def cmd_rates(a) -> int:
    from tools import failure_ledger
    void = failure_ledger.voided()
    recs = [r for r in all_runs() if r["run"] >= a.since]
    print(f"{'item':<44} last {a.n:<3} streak   (void runs left out: {sum(1 for r in recs if r['run'] in void)})")
    for k, r in sorted(rates(recs, void, a.n).items()):
        print(f"{k:<44} {r['passes']:>2} of {r['of']:<2} {r['streak']:>4}" + ("   3 in a row" if r["streak"] >= 3 else ""))
    blocked = chain_guard(recs, void, [q for q, _, _ in FRESH_PLAN])
    print("chain: " + ("ready" if not blocked else "not yet\n  " + "\n  ".join(blocked)))
    return 0


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
              + (f" NOT COUNTED ({not_counted(r)})" if not_counted(r) else "")
              + (f" (leftover at the start: {r['carried_at_start']})" if r.get("carried_at_start") and not not_counted(r) else ""))
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
    fr.add_argument("--chain-anyway", metavar="REASON", help="run the chain although a quest in it is under 4 of its last 5 (the reason is recorded)")
    st = sub.add_parser("step", help="one lock window: K trials of one quest from a checkpoint, each on a new fork of it")
    st.add_argument("--confirm", action="store_true")
    st.add_argument("--from", dest="checkpoint", required=True, help="a checkpoint label or a clone's name (tools/quest_clone.py keep)")
    st.add_argument("--quest", required=True)
    st.add_argument("--line", action="append", help="the chat line (default: the quest's line in FRESH_PLAN)")
    st.add_argument("--until-step", help="end a trial, done, when the quest's step contains this text (default: quest complete)")
    st.add_argument("-k", type=int, default=5, help="trials")
    st.add_argument("--deadline", type=float, default=600.0, help="per trial")
    st.add_argument("--save-as", metavar="LABEL", help="keep the first done trial's next save as this checkpoint")
    st.add_argument("--keep-forks", action="store_true", help="leave the forks in the character list")
    st.add_argument("--others-ok", default="", metavar="WORDS", help="a checkpoint pair's world is restored although "
                    "another player joined since it was kept (world_snapshot's rule): Luis's words")
    st.add_argument("--regrow-days", type=int, default=3, help="game days the dev clock is moved on after each trial, so "
                    "what it mined has grown back for the next (0: leave the clock alone)")
    st.add_argument("--wait", type=float, default=3000.0, help="seconds to wait for the live lock")
    st.add_argument("--window-s", type=float, default=3600.0, help="the whole window, switch back included")
    st.add_argument("--reserve-s", type=float, default=240.0, help="kept for the switch back to ClaudeDev")
    st.add_argument("--max-haiku", type=int, default=60)
    st.add_argument("--usd", type=float, default=0.4, help="each trial's spend cap on top of today's spend")
    for p in (r, fr, st):
        p.add_argument("--dirty-ok", metavar="REASON", help="run although client_mod/ or brain/ has uncommitted "
                       "changes (the reason is printed into the window's log)")
    rt = sub.add_parser("rates", help="pass rate and streak per item, void runs left out; and whether the chain may run")
    rt.add_argument("-n", type=int, default=10)
    rt.add_argument("--since", default="20261116", help="only runs from this run id on")
    rp = sub.add_parser("report")
    rp.add_argument("-n", type=int, default=10)
    a = ap.parse_args(argv)
    return {"run": cmd_run, "fresh": cmd_fresh, "step": cmd_step, "rates": cmd_rates, "report": cmd_report}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())

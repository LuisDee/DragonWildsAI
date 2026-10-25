"""Observability over Claude's logs: per-episode traces, metrics and anomaly detectors (docs/design/observability.md).

An *episode* is one player request (chat line(s) -> decision -> model calls -> tool calls -> body results -> speech),
one body-initiated decision (situation_review, vitals_low, unreachable ...), or one autonomous goal. It is rebuilt
offline from the logs the stack already writes; nothing in brain/ or client_mod/ is changed:

  brain    logs/brain-live-*.jsonl          prompts, model replies (usage), tool calls/results, bridge send/recv, speech
  chat     client_io/events/chat.jsonl      what players said (game time), for lines the brain never heard
  body     logs/client/mod_*.jsonl          client_action_start/end (same id as the bridge message), bridge start/stop
  goals    logs/state/worlds/*/progress.jsonl  goal started / done / stuck / interrupted
  watchdog logs/client_watchdog.jsonl       crashes and hangs (stability)

  .venv\\Scripts\\python.exe -m tools.obs episode --last 5
  .venv\\Scripts\\python.exe -m tools.obs episode --since 20:54 --until 21:18 [--verbose]
  .venv\\Scripts\\python.exe -m tools.obs metrics --since 20:54 --until 21:18 [--json]
  .venv\\Scripts\\python.exe -m tools.obs anomalies --since 20:54 --until 21:18      # also appends logs/anomalies.jsonl
  .venv\\Scripts\\python.exe -m tools.obs anomalies --follow                          # live tail (re-scans every 5 s)
  .venv\\Scripts\\python.exe -m tools.obs otel --since 20:54 --out logs/traces.otlp.json [--push http://127.0.0.1:6006/v1/traces]
  .venv\\Scripts\\python.exe -m tools.obs spend [--today | --day YYYY-MM-DD] [--json]     # $ vs the daily cap (tools/spend.py)

Times are UTC (like tools/timeline.py); --local reads and shows local time.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import statistics
import sys
import time
import urllib.request
from dataclasses import dataclass, field
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Iterable

from tools import spend as _spend
from tools.spend import spend_today, spent_today_usd  # noqa: F401  (re-exported: the brain's guard, evals, goal_check)
from tools.timeline import ROOT, jsonl, parse_ts, parse_when, redact, short

STALL_S = 15.0           # a player line with no response (speech or body action) after this long
UNHEARD_S = 20.0         # a chat line the brain did not log as heard within this long
REPEAT_N, REPEAT_GAP_S = 3, 180.0
LATE_SUCCESS_S = 90.0
NOT_ACTIONS = {"say", "remember", "forget_skill"}
NOISE_KINDS = {"bridge_unmatched", "bridge_malformed", "bridge_unknown_event", "event_dropped", "help_suppressed",
               "progress_skipped", "say_result", "capabilities", "skill_load_error", "situation_stale"}
CRASH_EVENTS = {"client_crash_dump", "client_crash_reporter", "client_hang", "client_gone"}
LIVE_WORLDS = {"shockbyte"}


# ------------------------------------------------------------------ loading
def _first_ts(path: Path) -> float | None:
    for d in jsonl(path):
        return parse_ts(d.get("ts"))
    return None


def _overlapping(files: Iterable[Path], since: float | None, until: float | None) -> list[Path]:
    """Files ordered by their first record; keep those that can overlap [since, until] (zone-free: no file names)."""
    stamped = sorted((t, f) for f in files if (t := _first_ts(f)) is not None)
    out = []
    for i, (start, f) in enumerate(stamped):
        nxt = stamped[i + 1][0] if i + 1 < len(stamped) else float("inf")
        if (until is None or start <= until) and (since is None or nxt >= since):
            out.append(f)
    return out


@dataclass
class Corpus:
    brain: list[dict] = field(default_factory=list)       # every brain-live record, time-ordered, with "_file"
    sessions: list[dict] = field(default_factory=list)    # {file, start, end, world}
    chat: list[dict] = field(default_factory=list)        # chat.jsonl rows (players and Claude)
    body: list[dict] = field(default_factory=list)        # mod_*.jsonl rows (ts parsed)
    goals: list[dict] = field(default_factory=list)       # progress.jsonl goal rows
    watchdog: list[dict] = field(default_factory=list)
    vitals: list[dict] = field(default_factory=list)      # vitals.jsonl death / fatal rows only
    since: float | None = None
    until: float | None = None


def load(root: Path, since: float | None, until: float | None, pad: float = 300.0) -> Corpus:
    """Everything that can touch [since, until]; brain records padded so an episode that started just before
    the window still has its trigger."""
    c = Corpus(since=since, until=until)
    lo = since - pad if since is not None else None
    hi = until + pad if until is not None else None
    for f in _overlapping((root / "logs").glob("brain-live-*.jsonl"), lo, hi):
        recs = [d for d in jsonl(f) if isinstance(parse_ts(d.get("ts")), float)]
        world = next((d.get("world") for d in recs if d.get("kind") == "session_start"), None)
        if recs:
            c.sessions.append({"file": f.name, "start": recs[0]["ts"], "end": recs[-1]["ts"], "world": world})
        for d in recs:
            if (lo is None or d["ts"] >= lo) and (hi is None or d["ts"] <= hi):
                d["_file"] = f.name
                c.brain.append(d)
    c.brain.sort(key=lambda d: d["ts"])
    for d in jsonl(root / "client_io" / "events" / "chat.jsonl"):
        t = parse_ts(d.get("ts") or d.get("iso"))
        if t is not None and (lo is None or t >= lo) and (hi is None or t <= hi):
            c.chat.append({**d, "ts": t})
    for f in _overlapping((root / "logs" / "client").glob("mod_*.jsonl"), lo, hi):
        for d in jsonl(f):
            t = parse_ts(d.get("ts"))
            if t is not None and (lo is None or t >= lo) and (hi is None or t <= hi):
                c.body.append({**d, "ts": t})
    c.body.sort(key=lambda d: d["ts"])
    for f in (root / "logs" / "state" / "worlds").glob("*/progress.jsonl"):
        for d in jsonl(f):
            t = parse_ts(d.get("ts"))
            if t is not None and str(d.get("msg", "")).startswith(("goal", "stuck", "replanned")) and \
                    (lo is None or t >= lo) and (hi is None or t <= hi):
                c.goals.append({**d, "ts": t})
    c.goals.sort(key=lambda d: d["ts"])
    for d in jsonl(root / "client_io" / "events" / "vitals.jsonl"):
        if d.get("type") in ("death", "fatal"):
            t = parse_ts(d.get("ts") or d.get("iso"))
            if t is not None and (since is None or t >= since) and (until is None or t <= until):
                c.vitals.append({**d, "ts": t})
    c.vitals.sort(key=lambda d: d["ts"])
    for d in jsonl(root / "logs" / "client_watchdog.jsonl"):
        t = parse_ts(d.get("ts"))
        if t is not None and (since is None or t >= since) and (until is None or t <= until):
            c.watchdog.append({**d, "ts": t})
    return c


# ------------------------------------------------------------------ episodes
@dataclass
class Step:
    ts: float
    kind: str            # model | read | action | say | decision | event | note | bridge
    text: str
    end: float | None = None
    level: str = "info"
    attrs: dict = field(default_factory=dict)


@dataclass
class Episode:
    kind: str                       # chat | body | goal | ignored | ping
    start: float                    # player said it (game time) / body trigger / goal start
    player: str | None = None
    request: str = ""               # what the player said (merged burst) or the body event summary
    lines: list[dict] = field(default_factory=list)   # [{said, heard, text, decision}]
    steps: list[Step] = field(default_factory=list)
    planned: list[str] = field(default_factory=list)  # body actions the model asked for (all turns)
    ran: list[dict] = field(default_factory=list)     # [{tool, ok, reason, attempt, ts, end}]
    said: list[dict] = field(default_factory=list)    # [{ts, text}]
    model_calls: list[dict] = field(default_factory=list)
    decision: str | None = None
    first_model: float | None = None
    first_action: float | None = None
    first_say: float | None = None
    end: float | None = None
    file: str | None = None
    state_reads: int = 0
    anomalies: list[dict] = field(default_factory=list)

    @property
    def id(self) -> str:
        return datetime.fromtimestamp(self.start, timezone.utc).strftime("%H%M%S") + self.kind[0]

    @property
    def first_response(self) -> float | None:
        xs = [x for x in (self.first_action, self.first_say) if x is not None]
        return min(xs) if xs else None

    def add(self, step: Step) -> None:
        self.steps.append(step)
        if step.kind not in ("event", "trigger"):  # later body events don't make the episode longer
            self.end = max(self.end or step.ts, step.end or step.ts)


def _norm(s: str) -> str:
    return " ".join(str(s).lower().split())


def _context(rec: dict) -> dict | None:
    """The decide prompt's context JSON (command + body_event), or None when this prompt is not a decision start."""
    if rec.get("component") != "controller":
        return None
    msgs = rec.get("messages") or []
    last = msgs[-1] if msgs else {}
    content = last.get("content") if isinstance(last, dict) else None
    if last.get("role") != "user" or not isinstance(content, str) or not content.startswith("{"):
        return None
    try:
        ctx = json.loads(content)
    except ValueError:
        return None
    return ctx if isinstance(ctx, dict) and isinstance(ctx.get("command"), dict) else None


def _body_summary(ev: dict | None) -> str:
    if not isinstance(ev, dict):
        return "body event"
    t = ev.get("type", "?")
    if t == "situation_review":
        ch = ", ".join(f"{c.get('what')} {c.get('from_pct', c.get('from', ''))}->{c.get('to_pct', c.get('to', ''))}"
                       for c in ev.get("changes") or [] if isinstance(c, dict))
        return f"situation_review ({ch})"
    if t == "events":
        return "; ".join(_body_summary(e) for e in ev.get("events") or [])
    keep = {k: v for k, v in ev.items() if k in ("stat", "value", "reason", "target", "where", "kind")}
    return f"{t} {short(keep, 100)}"


def _result_text(r: dict) -> tuple[bool, str | None, str]:
    res = r.get("result") or {}
    data = res.get("data") or {}
    detail = data.get("detail") or data.get("why") or ""
    return bool(res.get("ok")), res.get("reason"), str(detail)


def build_episodes(c: Corpus) -> list[Episode]:
    eps: list[Episode] = []
    cur: Episode | None = None
    goal: Episode | None = None
    pending: list[dict] = []             # heard lines not yet decided: {player, text, said, heard, decision}
    owner_of_task: dict[str, Episode] = {}
    open_prompt: dict[str, tuple[float, Episode, dict]] = {}
    last_tool_call: dict | None = None
    sends: dict[str, tuple[float, str, Episode | None]] = {}
    goal_rows = list(c.goals)
    redecided = False
    last_owner: Episode | None = None

    def attach(step: Step, ep: Episode | None = None):
        target = ep or last_owner or cur or goal
        if target is not None:
            target.add(step)

    def start_goal(ts: float, text: str, file: str | None):
        nonlocal goal, last_owner
        goal = Episode("goal", ts, request=text, file=file)
        eps.append(goal)
        last_owner = goal

    def goal_row(g: dict, file: str | None) -> None:
        nonlocal goal
        if g.get("msg") == "goal started":
            start_goal(g["ts"], str(g.get("goal")), file)
        elif goal is not None:
            goal.add(Step(g["ts"], "note", f"goal {g.get('msg')}: {short(g.get('reason') or '', 120)}",
                          level="warn" if g.get("msg") != "goal done" else "info"))
            goal.decision = str(g.get("msg"))
            if g.get("msg") in ("goal done", "stuck", "goal interrupted"):
                goal = None

    for rec in c.brain:
        ts, k = rec["ts"], rec.get("kind")
        while goal_rows and goal_rows[0]["ts"] <= ts:   # goal boundaries from the state store
            goal_row(goal_rows.pop(0), rec.get("_file"))
        if k == "session_start":
            cur, pending, open_prompt, last_owner, last_tool_call = None, [], {}, None, None
            continue
        if k == "event":
            e = rec.get("event") or {}
            et = e.get("type")
            if et in ("chat_heard", "command_received"):
                pending.append({"player": e.get("player"), "text": str(e.get("text", "")),
                                "said": parse_ts(e.get("ts")) or ts, "heard": ts, "decision": None})
                continue
            if et == "activity":
                attach(Step(ts, "event", f"body {e.get('kind')}: {short(e.get('detail') or {x: y for x, y in e.items() if x not in ('type', 'ts', 'iso')}, 140)}",
                            level="warn" if e.get("kind") in ("death", "fled", "stuck") else "info", attrs=e))
                continue
            attach(Step(ts, "event", f"{et}: {short({x: y for x, y in e.items() if x != 'type'}, 140)}",
                        level="warn" if et in ("vitals_low", "unreachable", "attacked") else "info", attrs=e))
            continue
        if k == "chat_decision":
            dec, text = rec.get("decision"), _norm(rec.get("text", ""))
            for p in reversed(pending):
                if _norm(p["text"]) == text and p["decision"] in (None, "pending"):
                    p["decision"] = f"{dec} ({rec.get('reason')})"
                    break
            if dec == "ignored" and not str(rec.get("reason", "")).startswith("model"):  # rate cap: no model call
                mine = [p for p in pending if p["player"] == rec.get("player")]
                pending = [p for p in pending if p not in mine]
                if mine:
                    ep = Episode("ignored", min(p["said"] for p in mine), rec.get("player"), rec.get("text", ""),
                                 lines=mine, decision=f"ignored ({rec.get('reason')})", file=rec.get("_file"), end=ts)
                    eps.append(ep)
            elif dec == "ping":
                mine = [p for p in pending if _norm(p["text"]) == text]
                pending = [p for p in pending if p not in mine]
                ep = Episode("ping", mine[0]["said"] if mine else ts, rec.get("player"), rec.get("text", ""), lines=mine,
                             decision="ping", file=rec.get("_file"), end=ts)
                eps.append(ep)
            elif str(rec.get("reason", "")).startswith("model") and cur is not None:
                cur.decision = f"{dec} ({rec.get('reason')})"
                if dec == "ignored":
                    cur.kind = "ignored"
            continue
        if k == "prompt":
            comp = rec.get("component") or "?"
            ctx = _context(rec)
            if comp == "planner" and goal is None:
                start_goal(ts, "(planner) " + short((rec.get("messages") or [{}])[-1].get("content"), 100), rec.get("_file"))
            if ctx is not None and not redecided:
                cmd = ctx["command"]
                text = str(cmd.get("text") or "")
                if text:
                    pieces = {_norm(x) for x in text.split(" / ") if x.strip()}
                    mine = [p for p in pending if p["player"] == cmd.get("player") and
                            any(_norm(p["text"]) == q or q in _norm(p["text"]) or _norm(p["text"]) in q for q in pieces)]
                    pending = [p for p in pending if p not in mine]
                    start = min([p["said"] for p in mine] or [ts])
                    cur = Episode("chat", start, cmd.get("player"), text, lines=mine, file=rec.get("_file"))
                    if ctx.get("body_event"):
                        cur.add(Step(ts, "note", "also deciding: " + _body_summary(ctx["body_event"])))
                else:
                    prev = cur
                    began = prev.model_calls[0]["ts"] if prev and prev.model_calls else float("-inf")
                    trig = [s for s in (prev.steps if prev else []) if s.kind == "trigger" and ts - s.ts < 10 and s.ts > began]
                    cur = Episode("body", min([s.ts for s in trig] or [ts]), cmd.get("player"),
                                  _body_summary(ctx.get("body_event")), file=rec.get("_file"))
                    for s in trig:  # the trigger was logged before this decision started: it belongs here
                        prev.steps.remove(s)
                        cur.add(s)
                eps.append(cur)
            redecided = False
            target = goal if comp == "planner" else cur
            if target is not None:
                open_prompt[comp] = (ts, target, rec)
                last_owner = target
            continue
        if k == "llm_response":
            comp = rec.get("component") or "?"
            t0, ep, prec = open_prompt.pop(comp, (None, cur, {}))
            u = rec.get("usage") or {}
            calls = rec.get("tool_calls") or []
            model = str(prec.get("model", "")).split("/")[-1]
            call = {"ts": t0 or ts, "end": ts, "latency": round(ts - t0, 3) if t0 else None, "component": comp,
                    "model": model, "step": rec.get("step"), "prompt_tok": u.get("prompt"), "completion_tok": u.get("completion"),
                    "cached_tok": u.get("cached"), "cache_write_tok": u.get("cache_write"),
                    "calls": [{"name": x.get("name"), "args": x.get("arguments"), "id": x.get("id")} for x in calls],
                    "content": rec.get("content")}
            if ep is None:
                continue
            ep.model_calls.append(call)
            ep.first_model = ep.first_model or ts
            bits = [f"{x.get('name')}({short(x.get('arguments'), 90)})" for x in calls]
            if rec.get("content"):
                bits.append(f'says "{short(rec["content"], 200)}"')
            lat = f"{call['latency']:.1f} s" if call["latency"] is not None else "?"
            tok = f"{u.get('prompt')}+{u.get('completion')} tok, cached {u.get('cached') or 0}" if u else ""
            ep.add(Step(t0 or ts, "model", f"{comp} {model} [{rec.get('step')}] {lat} {tok} -> " + ("; ".join(bits) or "(nothing)"),
                        end=ts, attrs=call))
            continue
        if k == "speech_redecided":
            redecided = True
            attach(Step(ts, "note", f"speech re-decided on fresh state {short(rec.get('changed'), 80)}; first draft unsaid: "
                                    f'"{short(rec.get("first"), 120)}"'))
            continue
        if k == "tool_call":
            tool = str(rec.get("tool"))
            if rec.get("read_only"):
                ep = cur
                if ep is not None:
                    ep.add(Step(ts, "read", f"{tool}({short(rec.get('args'), 90)})", attrs={"tool": tool}))
                last_tool_call = {"rec": rec, "ep": ep, "read": True}
                continue
            tid = rec.get("task_id")
            ep = owner_of_task.get(tid) if tid else None
            if ep is None:
                if cur is not None and tool in cur.planned_left():
                    ep = cur
                elif goal is not None:
                    ep = goal
                else:
                    ep = cur
                if tid and ep is not None:
                    owner_of_task[tid] = ep
            if ep is None:
                continue
            if ep is cur and tool in cur.planned_left():
                cur.consume(tool)
            step = Step(ts, "action", f"{tool}({short(rec.get('args'), 90)})" + (f" try {rec.get('attempt')}" if (rec.get("attempt") or 1) > 1 else ""),
                        attrs={"tool": tool, "task_id": tid, "attempt": rec.get("attempt"), "args": rec.get("args")})
            ep.add(step)
            ep.first_action = ep.first_action or ts
            last_tool_call = {"rec": rec, "ep": ep, "step": step}
            last_owner = ep
            continue
        if k == "tool_result":
            ok, reason, detail = _result_text(rec)
            if rec.get("read_only"):
                if last_tool_call and last_tool_call.get("read") and last_tool_call["ep"] is not None:
                    ep = last_tool_call["ep"]
                    for s in reversed(ep.steps):
                        if s.kind == "read" and s.end is None:
                            s.end = ts
                            s.text += f" -> ok={ok}" + (f" {reason}" if reason else "")
                            break
                continue
            tid = rec.get("task_id")
            ep = owner_of_task.get(tid) if tid else (last_tool_call or {}).get("ep")
            if ep is None:
                continue
            step = next((s for s in reversed(ep.steps) if s.kind == "action" and s.end is None and
                         s.attrs.get("tool") == rec.get("tool")), None)
            if step is not None:
                step.end = ts
                step.level = "info" if ok else "warn"
                step.attrs.update(ok=ok, reason=reason, detail=detail)
                step.text += f" -> {'ok' if ok else 'FAIL ' + str(reason)} {ts - step.ts:.1f} s" + (f' "{short(detail, 110)}"' if detail else "")
                ep.ran.append({"tool": rec.get("tool"), "ok": ok, "reason": reason, "attempt": step.attrs.get("attempt"),
                               "ts": step.ts, "end": ts, "detail": detail, "args": step.attrs.get("args"),
                               "bridge_id": step.attrs.get("bridge_id"), "task_id": step.attrs.get("task_id")})
                ep.end = max(ep.end or ts, ts)
            continue
        if k in ("task_done", "task_failed"):
            continue  # the tool_result already carries it
        if k == "bridge_send":
            msg = rec.get("msg") or {}
            tool = str(msg.get("tool"))
            ep = (last_tool_call or {}).get("ep") or cur
            sends[str(msg.get("id"))] = (ts, tool, ep)
            if tool == "get_state" and ep is not None:
                ep.state_reads += 1
            lt = last_tool_call or {}
            if lt.get("step") is not None and lt["step"].attrs.get("tool") == tool and "bridge_id" not in lt["step"].attrs:
                lt["step"].attrs["bridge_id"] = msg.get("id")
            continue
        if k == "bridge_recv":
            continue
        if k == "say":
            text = str(rec.get("text", ""))
            ep = last_owner or cur or goal
            if ep is None:
                continue
            ep.said.append({"ts": ts, "text": text, "voice": rec.get("voice")})
            ep.first_say = ep.first_say or ts
            ep.add(Step(ts, "say", f'"{text}"', attrs={"voice": rec.get("voice")}))
            continue
        if k in ("situation_review", "event_triage"):
            ev = rec.get("event") or {"type": "situation_review", "changes": rec.get("changes")}
            attach(Step(ts, "trigger", f"{k}: {_body_summary(ev)}" + (f" -> {rec.get('verdict')} ({rec.get('why')})" if rec.get("verdict") else "")))
            continue
        if k in ("bridge_timeout", "bridge_restart_detected", "bridge_command_lost", "bridge_wait_interrupted"):
            sid = str(rec.get("id"))
            ep = sends.get(sid, (0, "", None))[2] or cur
            attach(Step(ts, "bridge", f"{k} {rec.get('tool')} " + short({x: y for x, y in rec.items() if x not in ("ts", "kind", "_file", "tool")}, 120),
                        level="warn", attrs=rec), ep)
            continue
        if k in ("chain_turn", "chain_stopped", "situation_unspoken", "controller_invalid_call", "controller_unknown_tool",
                 "controller_safety_refusal", "controller_budget_exhausted", "command_error", "next_turn_error",
                 "loop_error", "goal_error", "verification_failed", "cooldown_wait", "state_unavailable", "plan_invalid"):
            lvl = "warn" if k not in ("chain_turn", "cooldown_wait") else "info"
            attach(Step(ts, "note", f"{k} " + short({x: y for x, y in rec.items() if x not in ("ts", "kind", "_file", "traceback")}, 160), level=lvl,
                        attrs=rec))
            continue
        if k in NOISE_KINDS or k in ("session_end", "ping_reply", "help"):
            if k == "help":
                attach(Step(ts, "note", f"help {rec.get('key')}: {short(rec.get('text'), 120)}"))
            continue
        attach(Step(ts, "note", f"{k} " + short({x: y for x, y in rec.items() if x not in ("ts", "kind", "_file")}, 140)))

    for g in goal_rows:  # goal ends logged after the last brain record
        goal_row(g, None)
    for e in eps:
        if e.decision is None and e.lines:
            e.decision = e.lines[-1].get("decision")
    for p in pending:  # heard, never decided (the session ended or the brain is still busy)
        eps.append(Episode("chat", p["said"], p["player"], p["text"], lines=[p], decision="never decided", file=None,
                           end=p["heard"]))
    _attach_body(eps, c)
    eps.sort(key=lambda e: e.start)
    if c.since is not None or c.until is not None:
        eps = [e for e in eps if (c.since is None or e.start >= c.since) and (c.until is None or e.start <= c.until)]
    return eps


def _planned_left(self: Episode) -> list[str]:
    planned = []
    for m in self.model_calls:
        planned += [x["name"] for x in m["calls"] if x["name"]]
    left = list(planned)
    for t in getattr(self, "_consumed", []):
        if t in left:
            left.remove(t)
    return left


def _consume(self: Episode, tool: str) -> None:
    if not hasattr(self, "_consumed"):
        self._consumed = []
    self._consumed.append(tool)


Episode.planned_left = _planned_left
Episode.consume = _consume


def _attach_body(eps: list[Episode], c: Corpus) -> None:
    """The body's own start/end for each action (mod log, same id as the bridge message; 1 s resolution)."""
    starts, ends = {}, {}
    for d in c.body:
        data = d.get("data") or {}
        if d.get("event") == "client_action_start":
            starts[str(data.get("id"))] = d["ts"]
        elif d.get("event") == "client_action_end":
            ends[str(data.get("id"))] = (d["ts"], data)
    for ep in eps:
        for s in ep.steps:
            bid = s.attrs.get("bridge_id") if s.kind == "action" else None
            if bid and bid in starts:
                end = ends.get(bid)
                s.attrs["body"] = {"start": starts[bid], "end": end[0] if end else None,
                                   "reason": (end[1].get("reason") if end else None)}


# ------------------------------------------------------------------ rendering
def _hms(t: float | None, tz: timezone = timezone.utc) -> str:
    return datetime.fromtimestamp(t, tz).strftime("%H:%M:%S") if t is not None else "--:--:--"


def _dur(a: float | None, b: float | None) -> str:
    return f"{b - a:.1f} s" if a is not None and b is not None else "n/a"


def render_episode(ep: Episode, n: int, tz: timezone = timezone.utc, verbose: bool = False) -> str:
    fails = sum(1 for r in ep.ran if not r["ok"])
    head = f"#{n} [{ep.id}] {ep.kind.upper()} {_hms(ep.start, tz)}"
    if ep.kind in ("chat", "ignored", "ping"):
        head += f'  {ep.player}: "{short(ep.request, 160)}"'
    else:
        head += f"  {short(ep.request, 160)}"
    head += (f"\n    {_dur(ep.start, ep.end)} total, {len(ep.model_calls)} model calls, {len(ep.ran)} body actions"
             f" ({fails} failed), {ep.state_reads} state reads")
    if ep.decision:
        head += f", decision: {ep.decision}"
    out = [head]
    if ep.kind in ("chat", "ignored"):
        out.append(f"    latency: heard +{_dur(ep.start, min([p['heard'] for p in ep.lines] or [ep.start]))}"
                   f", first model reply +{_dur(ep.start, ep.first_model)}, first action +{_dur(ep.start, ep.first_action)}"
                   f", first speech +{_dur(ep.start, ep.first_say)}")
        if len(ep.lines) > 1:
            for p in ep.lines:
                out.append(f"    line {_hms(p['said'], tz)} (heard +{p['heard'] - p['said']:.1f} s) \"{short(p['text'], 100)}\" -> {p['decision']}")
    for s in ep.steps:
        if not verbose and s.kind in ("event",) and s.level == "info":
            continue
        mark = "!" if s.level != "info" else " "
        off = f"+{s.ts - ep.start:6.1f}"
        label = {"model": "think", "read": "read", "action": "do", "say": "SAY", "note": "note", "event": "body",
                 "bridge": "bridge", "trigger": "trigger"}.get(s.kind, s.kind)
        extra = ""
        if s.kind == "action" and s.attrs.get("body"):
            b = s.attrs["body"]
            extra = f"  [body {_hms(b['start'], tz)}-{_hms(b['end'], tz)}{' ' + b['reason'] if b.get('reason') else ''}]"
        out.append(f"   {mark}{off} {label:<7} {s.text}{extra}")
    for a in ep.anomalies:
        out.append(f"   !! anomaly {a['kind']}: {a['text']}")
    return "\n".join(out)


# ------------------------------------------------------------------ anomalies
PROMISE_RX = re.compile(r"\b(i'?ll|i will|i'm going to|i am going to|i'm heading|i am heading|heading (?:to|over|back)|"
                        r"on my way|let me|i'm off to)\b", re.I)
CONDITIONAL_RX = re.compile(r"\b(if you|want me to|should i|shall i|can i|would you|unless|when you|once you|after you)\b", re.I)
NOT_A_DEED_RX = re.compile(r"\b(?:i'?ll|i will)\s+(?:not|never|stop|wait|stay|stand|be here|keep (?:that|it) in mind|remember|"
                           r"let you know|tell you|ask)\b", re.I)
STAT_RX = re.compile(r"\b\d{1,3}(?:\.\d+)?\s?%|\b\d+(?:\.\d+)?\s?m (?:from|away|to)\b|\bHP\b\s*\d", re.I)
SUCCESS_RX = re.compile(r"^(?:done\b|all done\b)|\b(?:gathered \d+|got \d+|picked up|it worked|finished)\b", re.I)
FAIL_WORDS_RX = re.compile(r"\b(didn't|did not|couldn't|could not|can't|cannot|won't|failed|no runes were used|not selected|"
                           r"didn't go off|isn't working)\b", re.I)
NEG_PROMISE_RX = re.compile(r"\b(?:no more|won't|will not|stop|not going to|i'll stop)\s+(\w+)", re.I)
ENGINE_ID_RX = re.compile(r"\b(?:BP|ITEM|USD|DIM|WBP|ABP|DA|BM)_\w+|\bfol:\S+|table: [0-9A-F]{8,}")
COLON_CODE_RX = re.compile(r"\bI couldn'?t [\w ]+:\s*([a-z][a-z_ ]+)\.?$", re.I)


def _sentences(text: str) -> list[str]:
    return [s.strip() for s in re.split(r"(?<=[.!?])\s+", text) if s.strip()]


def reason_vocab(c: Corpus) -> set[str]:
    """Body/brain reason codes: the interface's Reason constants plus every reason/why seen in these logs."""
    vocab: set[str] = set()
    try:
        from brain.interface import Reason
        vocab |= {v for k, v in vars(Reason).items() if k.isupper() and isinstance(v, str)}
    except Exception:
        pass
    for d in c.brain:
        if d.get("kind") == "tool_result":
            res = d.get("result") or {}
            for v in (res.get("reason"), (res.get("data") or {}).get("why")):
                if isinstance(v, str) and re.fullmatch(r"[a-z]+(?:_[a-z0-9]+)+", v):
                    vocab.add(v)
    return vocab


def _anom(kind: str, ts: float, text: str, ep: Episode | None, level: str = "warn", key: str | None = None, **data) -> dict:
    a = {"ts": datetime.fromtimestamp(ts, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
         "kind": kind, "level": level, "episode": ep.id if ep else None, "text": redact(text),
         "key": key or f"{kind}:{round(ts, 1)}", "data": data}
    if ep is not None:
        ep.anomalies.append(a)
    return a


def detect(c: Corpus, eps: list[Episode], now: float | None = None, stall_s: float = STALL_S) -> list[dict]:
    out: list[dict] = []
    vocab = reason_vocab(c)
    spaced = {v.replace("_", " ") for v in vocab}
    late = [d for d in c.brain if d.get("kind") == "event" and (d.get("event") or {}).get("kind") == "cast_late_success"]
    end_of_data = now or (c.until if c.until is not None else (c.brain[-1]["ts"] if c.brain else time.time()))

    for ep in eps:
        # ---- stall: the player's line waited too long for any response
        if ep.kind == "chat":
            resp = ep.first_response
            wait = (resp if resp is not None else end_of_data) - ep.start
            if wait > stall_s and not (resp is None and ep.decision and ep.decision.startswith("ignored")):
                heard = min([p["heard"] for p in ep.lines] or [ep.start])
                busy = _blocked_by(eps, ep, ep.start, heard) or _busy_with(c, ep.start, heard)
                why = f"heard after {heard - ep.start:.1f} s" + (f" (brain busy: {busy})" if busy else "")
                if ep.first_model:
                    why += f"; model replied +{ep.first_model - ep.start:.1f} s"
                out.append(_anom("stall", ep.start, f'"{short(ep.request, 80)}" waited {wait:.0f} s for a response; {why}'
                                 + ("" if resp is not None else " (no response yet)"), ep,
                                 "error" if wait > 60 else "warn", f"stall:{ep.id}", wait_s=round(wait, 1),
                                 heard_lag_s=round(heard - ep.start, 1), busy_with=busy, answered=resp is not None))
        # ---- promise without action / raw codes / stat narration / contradictions, per spoken line
        reads = _read_tools(ep)

        def acted_on(t: float) -> bool:
            """An action started after the line, or the model call that produced the line also asked for one that ran."""
            if any(r["ts"] >= t - 1.5 for r in ep.ran):
                return True
            src = [m for m in ep.model_calls if m["end"] <= t + 0.1]
            return bool(src) and any(x["name"] not in reads and x["name"] not in NOT_ACTIONS and
                                     any(r["tool"] == x["name"] and r["ts"] >= src[-1]["end"] - 0.1 for r in ep.ran)
                                     for x in src[-1]["calls"])
        goal_after = lambda t: any(g.kind == "goal" and 0 <= g.start - t <= 10 for g in eps)  # noqa: E731
        neg_seen: list[tuple[str, float, str]] = []
        for s in ep.said:
            text, t = s["text"], s["ts"]
            for sent in _sentences(text):
                if PROMISE_RX.search(sent) and not CONDITIONAL_RX.search(sent) and not sent.endswith("?") \
                        and not NOT_A_DEED_RX.search(sent) and not acted_on(t) and not goal_after(t):
                    out.append(_anom("promise_without_action", t, f'said "{short(sent, 120)}" and no body action followed', ep,
                                     key=f"promise:{round(t, 1)}", sentence=sent))
                    break
            codes = sorted({v for v in vocab if re.search(rf"\b{re.escape(v)}\b", text)} |
                           set(ENGINE_ID_RX.findall(text)) |
                           {sp for sp in spaced if " " in sp and re.match(rf"^\W*{re.escape(sp)}\b", text, re.I)})
            m = COLON_CODE_RX.search(text)
            if m and (m.group(1).strip().replace(" ", "_").lower() in vocab) and m.group(1).strip() not in codes:
                codes.append(m.group(1).strip())
            if codes:
                out.append(_anom("raw_code_spoken", t, f'said "{short(text, 120)}" (raw: {", ".join(codes)})', ep,
                                 key=f"raw:{round(t, 1)}", codes=codes))
            if STAT_RX.search(text):
                asked = ep.kind == "chat" and "?" in ep.request
                if not asked:
                    out.append(_anom("stat_narration", t, f'unprompted numbers: "{short(text, 140)}"', ep,
                                     "warn" if ep.kind == "body" else "info", key=f"stat:{round(t, 1)}",
                                     unprompted=ep.kind == "body", matches=STAT_RX.findall(text)))
            before = [r for r in ep.ran if r["end"] <= t + 0.5]
            if SUCCESS_RX.search(text) and before and not any(r["ok"] for r in before):
                out.append(_anom("contradictory_speech", t, f'claimed success "{short(text, 100)}" but every action failed '
                                 f"({', '.join(sorted({str(r['reason']) for r in before}))})", ep, key=f"contra-ok:{round(t, 1)}",
                                 rule="success_claim_all_failed"))
            if re.match(r"^\W*(all )?done\b", text, re.I):
                left = [x for x in ep.planned_left() if x not in NOT_ACTIONS and x not in _read_tools(ep)]
                if left and before:
                    out.append(_anom("contradictory_speech", t, f'said "{short(text, 60)}" but planned {", ".join(left)} never ran', ep,
                                     key=f"contra-done:{round(t, 1)}", rule="done_with_unrun_plan", unrun=left))
            for r in ep.ran:
                spell = (r.get("args") or {}).get("spell") if isinstance(r.get("args"), dict) else None
                if r["tool"] == "cast" and not r["ok"] and spell and spell.lower() in text.lower() and FAIL_WORDS_RX.search(text):
                    hit = next((d for d in late if d["ts"] >= t - 5 and (d.get("event") or {}).get("ts", d["ts"]) - t <= LATE_SUCCESS_S
                                and str((d.get("event") or {}).get("spell", "")).lower() == spell.lower()), None)
                    if hit:
                        out.append(_anom("contradictory_speech", t, f'said {spell} failed ("{short(text, 80)}") but the body '
                                         f"later reported it went off", ep, key=f"contra-late:{round(t, 1)}", rule="failure_then_late_success"))
                        break
            for m in NEG_PROMISE_RX.finditer(text):
                neg_seen.append((m.group(1).lower(), t, text))
        # negative promise contradicted by a later action in a later episode (checked below across episodes)
        ep._neg = neg_seen  # type: ignore[attr-defined]

        # ---- tool timeouts
        by_task: dict[str, list[dict]] = {}
        for r in ep.ran:
            if r["reason"] == "timeout":
                by_task.setdefault(str(r.get("task_id") or r["ts"]), []).append(r)
        for tid, rs in by_task.items():
            secs = [round(r["end"] - r["ts"]) for r in rs]
            out.append(_anom("tool_timeout", rs[0]["ts"], f"{rs[0]['tool']} timed out" + (f" {len(rs)}x" if len(rs) > 1 else "")
                             + f" after {'/'.join(map(str, secs))} s" + (f' ("{short(rs[-1]["detail"], 80)}")' if rs[-1]["detail"] else ""),
                             ep, "error" if sum(secs) > 60 else "warn", key=f"timeout:{tid}", tool=rs[0]["tool"],
                             seconds=secs, attempts=len(rs)))

    # ---- negative promise followed by doing it anyway (within 5 min)
    for ep in eps:
        for stem, t, text in getattr(ep, "_neg", []):
            for later in eps:
                for r in later.ran:
                    if 0 < r["ts"] - t <= 300 and len(stem) >= 4 and (stem.startswith(r["tool"]) or r["tool"].startswith(stem[:4])):
                        player_between = later is not ep and later.kind == "chat"
                        out.append(_anom("contradictory_speech", r["ts"], f'said "{short(text, 80)}" then ran {r["tool"]} '
                                         f"{r['ts'] - t:.0f} s later" + (" (the player asked again)" if player_between else ""),
                                         later, "info" if player_between else "warn", key=f"contra-neg:{round(t, 1)}",
                                         rule="said_wont_then_did"))
                        break
                else:
                    continue
                break

    # ---- repeated failures with the same reason
    fails = sorted(((r["ts"], r["tool"], r["reason"], ep) for ep in eps for r in ep.ran if not r["ok"]), key=lambda x: x[0])
    groups: dict[tuple, list] = {}
    for f in fails:
        g = groups.setdefault((f[1], f[2]), [])
        if g and f[0] - g[-1][-1][0] > REPEAT_GAP_S:
            g.append([f])
        elif g:
            g[-1].append(f)
        else:
            g.append([f])
    for (tool, reason), runs in groups.items():
        for run in runs:
            if len(run) >= REPEAT_N:
                n_eps = len({id(x[3]) for x in run})
                out.append(_anom("repeated_failure", run[0][0], f"{tool} failed {len(run)}x with {reason} in "
                                 f"{run[-1][0] - run[0][0]:.0f} s across {n_eps} episode(s)", run[-1][3],
                                 "error" if len(run) >= 6 else "warn", key=f"repeat:{tool}:{reason}:{round(run[0][0], 1)}",
                                 tool=tool, reason=reason, count=len(run)))

    # ---- lines the brain never heard (no brain running, or a blocked loop that never caught up)
    heard = [(p["player"], _norm(p["text"]), p["heard"]) for ep in eps for p in ep.lines]
    for d in c.chat:
        if d.get("type") != "chat" or d.get("self") or (c.since is not None and d["ts"] < c.since) or \
                (c.until is not None and d["ts"] > c.until):
            continue
        txt = _norm(d.get("text", ""))
        if any(pl == d.get("from") and h >= d["ts"] - 2 and (t == txt or txt in t) for pl, t, h in heard):
            continue
        if end_of_data - d["ts"] < UNHEARD_S:
            continue
        running = any(s["start"] - 5 <= d["ts"] <= s["end"] + 30 for s in c.sessions)
        out.append(_anom("stall", d["ts"], f'{d.get("from")}: "{short(d.get("text"), 80)}" was never heard by the brain'
                         + ("" if running else " (no brain session running)"), None, "error" if running else "warn",
                         key=f"unheard:{d['ts']}:{hashlib.md5(txt.encode()).hexdigest()[:6]}", wait_s=None, brain_running=running))

    # ---- bridge restarts with commands in flight
    sends, recvs = {}, {}
    file_end = {s["file"]: s["end"] for s in c.sessions}
    for d in c.brain:
        msg = d.get("msg") or {}
        if d.get("kind") == "bridge_send" and msg.get("tool") not in ("ping", "capabilities"):
            sid = str(msg.get("id"))
            sends[sid] = (d["ts"], msg.get("tool"))
            recvs.setdefault(sid, file_end.get(d.get("_file"), float("inf")) + 0.5)  # its brain session ended: nobody waits
        elif d.get("kind") == "bridge_recv":
            recvs[str(msg.get("id"))] = d["ts"]
        elif d.get("kind") == "bridge_timeout":
            recvs[str(d.get("id"))] = min(recvs.get(str(d.get("id")), float("inf")), d["ts"])
        elif d.get("kind") in ("bridge_restart_detected", "bridge_command_lost"):
            ep = _episode_at(eps, d["ts"])
            out.append(_anom("bridge_restart_in_flight", d["ts"], f"{d['kind']}: {d.get('tool')} (id {d.get('id')})", ep, "error",
                             key=f"{d['kind']}:{d.get('id')}", tool=d.get("tool"), id=d.get("id"), source="brain"))
    answered = {str((d.get("msg") or {}).get("id")) for d in c.brain if d.get("kind") == "bridge_recv"}
    for b in c.body:
        if b.get("event") not in ("client_bridge_started", "client_bridge_stopped"):
            continue
        T = b["ts"]
        inflight = [(i, ts, tool) for i, (ts, tool) in sends.items() if ts < T and recvs.get(i, float("inf")) > T + 1
                    and T - ts < 200]
        if inflight:
            names = ", ".join(f"{tool} (sent {_hms(ts)}{', answered ' + _hms(recvs[i]) if i in answered else ', never answered'})"
                              for i, ts, tool in inflight)
            out.append(_anom("bridge_restart_in_flight", T, f"body bridge {b['event'].split('_')[-1]} with {len(inflight)} command(s) "
                             f"in flight: {names}", _episode_at(eps, inflight[0][1]), "error",
                             key=f"bridge:{b['event']}:{T}", ids=[i for i, _, _ in inflight], source="mod"))
    out.sort(key=lambda a: a["ts"])
    uniq, seen = [], set()
    for a in out:
        t = parse_ts(a["ts"])
        if (c.since is not None and t < c.since - 1) or (c.until is not None and t > c.until + 1):
            continue
        if a["key"] not in seen:
            seen.add(a["key"])
            uniq.append(a)
    return uniq


def _read_tools(ep: Episode) -> set[str]:
    return {s.attrs.get("tool") for s in ep.steps if s.kind == "read"}


def _episode_at(eps: list[Episode], t: float) -> Episode | None:
    best = None
    for e in eps:
        if e.start <= t and (e.end is None or t <= e.end + 1):
            best = e
    return best


def _blocked_by(eps: list[Episode], me: Episode, t0: float, t1: float) -> str | None:
    """The other episode's body task (all its executor attempts) that overlapped the wait the longest."""
    best, best_overlap = None, 0.0
    for e in eps:
        if e is me:
            continue
        tasks: dict[str, list[dict]] = {}
        for r in e.ran:
            tasks.setdefault(str(r.get("task_id") or r["ts"]), []).append(r)
        for rs in tasks.values():
            a, b = rs[0]["ts"], rs[-1]["end"]
            overlap = min(b, t1) - max(a, t0)
            if overlap > best_overlap:
                n = f" x{len(rs)} attempts" if len(rs) > 1 else ""
                best = f"{rs[0]['tool']}{n} {_hms(a)}-{_hms(b)}, {'ok' if rs[-1]['ok'] else rs[-1]['reason']} (episode {e.id})"
                best_overlap = overlap
    return best if best_overlap > 1.0 else None


def _busy_with(c: Corpus, t0: float, t1: float | None = None) -> str | None:
    """What kept the brain from the player's line between t0 (said) and t1 (heard): the body command or model
    call that overlapped that wait the longest."""
    t1 = t0 if t1 is None else t1
    spans: list[tuple[float, float, str]] = []
    sent: dict[str, tuple[float, str]] = {}
    prompt_at: float | None = None
    for d in c.brain:
        if d["ts"] > t1 + 600:
            break
        k, msg = d.get("kind"), d.get("msg") or {}
        if k == "bridge_send" and msg.get("tool") not in ("ping",):
            sent[str(msg.get("id"))] = (d["ts"], str(msg.get("tool")))
        elif k in ("bridge_recv", "bridge_timeout"):
            sid = str(msg.get("id") if k == "bridge_recv" else d.get("id"))
            if sid in sent:
                ts, tool = sent.pop(sid)
                spans.append((ts, d["ts"], f"{tool} sent {_hms(ts)}, " + ("answered" if k == "bridge_recv" else "timed out") +
                              f" {_hms(d['ts'])}"))
        elif k == "prompt":
            prompt_at = d["ts"]
        elif k == "llm_response" and prompt_at is not None:
            spans.append((prompt_at, d["ts"], f"model call {_hms(prompt_at)}-{_hms(d['ts'])}"))
            prompt_at = None
    spans += [(ts, float("inf"), f"{tool} sent {_hms(ts)}, never answered") for ts, tool in sent.values()]
    best, best_overlap = None, 0.0
    for a, b, text in spans:
        overlap = min(b, max(t1, t0 + 0.01)) - max(a, t0)
        if overlap > best_overlap:
            best, best_overlap = text, overlap
    return best


# ------------------------------------------------------------------ metrics
def pct(xs: list[float], p: float) -> float | None:
    if not xs:
        return None
    xs = sorted(xs)
    k = max(0, min(len(xs) - 1, round(p / 100 * (len(xs) - 1))))
    return round(xs[k], 2)


def dist(xs: list[float]) -> dict:
    return {"n": len(xs), "p50": pct(xs, 50), "p90": pct(xs, 90), "max": round(max(xs), 2) if xs else None}


def _observed(c: Corpus) -> list[tuple[float, float]]:
    lo = c.since if c.since is not None else float("-inf")
    hi = c.until if c.until is not None else float("inf")
    return [(max(s["start"], lo), min(s["end"], hi)) for s in c.sessions if min(s["end"], hi) > max(s["start"], lo)]


def metrics(c: Corpus, eps: list[Episode], anomalies: list[dict]) -> dict:
    chats = [e for e in eps if e.kind == "chat" and e.decision != "never decided"]
    answered = [e for e in chats if e.first_response is not None and not (e.decision or "").startswith("ignored")]
    first_resp = [e.first_response - e.start for e in answered]
    first_act = [e.first_action - e.start for e in chats if e.first_action is not None]
    heard = [p["heard"] - p["said"] for e in chats for p in e.lines]
    calls = [m for e in eps for m in e.model_calls]
    by_comp: dict[str, list[float]] = {}
    for m in calls:
        if m["latency"] is not None:
            by_comp.setdefault(f"{m['component']}/{m['model']}", []).append(m["latency"])
    prompt_tok = [m["prompt_tok"] for m in calls if m["prompt_tok"]]
    cached = sum(m["cached_tok"] or 0 for m in calls)
    ran = [r for e in eps for r in e.ran]
    tools: dict[str, dict] = {}
    for r in ran:
        t = tools.setdefault(r["tool"], {"n": 0, "failed": 0, "reasons": {}, "seconds": []})
        t["n"] += 1
        t["seconds"].append(r["end"] - r["ts"])
        if not r["ok"]:
            t["failed"] += 1
            t["reasons"][str(r["reason"])] = t["reasons"].get(str(r["reason"]), 0) + 1
    tool_rows = {k: {"n": v["n"], "failed": v["failed"], "fail_rate": round(v["failed"] / v["n"], 2), "reasons": v["reasons"],
                     "p50_s": pct(v["seconds"], 50), "p90_s": pct(v["seconds"], 90)} for k, v in sorted(tools.items())}
    reasons: dict[str, int] = {}
    for r in ran:
        if not r["ok"]:
            reasons[str(r["reason"])] = reasons.get(str(r["reason"]), 0) + 1
    talk_only = [e for e in answered if e.said and not e.ran]
    a_counts: dict[str, int] = {}
    for a in anomalies:
        a_counts[a["kind"]] = a_counts.get(a["kind"], 0) + 1
    rtt: dict[str, list[float]] = {}
    sends = {}
    for d in c.brain:
        msg = d.get("msg") or {}
        if d.get("kind") == "bridge_send":
            sends[str(msg.get("id"))] = (d["ts"], str(msg.get("tool")))
        elif d.get("kind") == "bridge_recv" and str(msg.get("id")) in sends:
            t0, tool = sends.pop(str(msg.get("id")))
            if (c.since is None or t0 >= c.since) and (c.until is None or t0 <= c.until):
                rtt.setdefault(tool, []).append(d["ts"] - t0)
    kinds: dict[str, int] = {}
    for e in eps:
        kinds[e.kind] = kinds.get(e.kind, 0) + 1
    return {
        "episodes": kinds,
        "chat_to_first_response_s": dist(first_resp),
        "chat_to_first_action_s": dist(first_act),
        "chat_heard_lag_s": dist(heard),
        "model_latency_s": {k: dist(v) for k, v in sorted(by_comp.items())},
        "model_calls": len(calls),
        "model_calls_per_episode": round(len(calls) / max(1, len([e for e in eps if e.model_calls])), 2),
        "prompt_tokens": dist([float(x) for x in prompt_tok]),
        "prompt_cache_share": round(cached / sum(prompt_tok), 2) if prompt_tok else None,
        "state_reads_per_action": round(sum(e.state_reads for e in eps) / max(1, len(ran)), 2),
        "tools": tool_rows,
        "failures_by_reason": dict(sorted(reasons.items(), key=lambda x: -x[1])),
        "retries": sum(1 for r in ran if (r.get("attempt") or 1) > 1),
        "talk_only_replies": len(talk_only),
        "promises_without_action": a_counts.get("promise_without_action", 0),
        "bridge_rtt_s": {k: dist(v) for k, v in sorted(rtt.items()) if k in ("get_state", "ping", "look", "inventory", "say")},
        "anomalies": a_counts,
    }


def goal_metrics(c: Corpus, eps: list[Episode], anomalies: list[dict], m: dict) -> dict:
    """The stable JSON contract for tools/goal_check.py (schema dw_obs_metrics/1)."""
    obs = _observed(c)
    hours = round(sum(b - a for a, b in obs) / 3600, 3) if obs else 0.0
    per_h = (lambda n: round(n / hours, 3) if hours > 0 else None)  # noqa: E731
    worlds = {s.get("world") for s in c.sessions if any(a <= s["end"] and s["start"] <= b for a, b in obs)}
    source = None if not worlds else "live" if worlds <= LIVE_WORLDS else "dev" if not (worlds & LIVE_WORLDS) else "mixed"
    stalls30 = [a for a in anomalies if a["kind"] == "stall" and ((a["data"].get("wait_s") or 0) > 30 or a["data"].get("wait_s") is None)]
    crashes = sorted(w["ts"] for w in c.watchdog if w.get("event") in CRASH_EVENTS)
    longest = None
    if obs:
        cuts = [obs[0][0]] + [t for t in crashes if obs[0][0] <= t <= obs[-1][1]] + [obs[-1][1]]
        runs = []
        for a, b in zip(cuts, cuts[1:]):
            runs.append(sum(max(0.0, min(b, y) - max(a, x)) for x, y in obs))
        longest = round(max(runs) / 3600, 3) if runs else None
    lat = m["chat_to_first_action_s"]
    window_since = c.since if c.since is not None else (obs[0][0] if obs else None)
    window_until = c.until if c.until is not None else (obs[-1][1] if obs else None)
    iso = lambda t: datetime.fromtimestamp(t, timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z") if t is not None else None  # noqa: E731
    count = lambda k: sum(1 for a in anomalies if a["kind"] == k)  # noqa: E731
    return {
        "schema": "dw_obs_metrics/1",
        "generated_at": iso(time.time()),
        "window": {"since": iso(window_since), "until": iso(min(window_until, time.time()) if window_until else None)},
        "source": source,
        "hours_observed": hours,
        "latency": {"chat_to_first_action_s": {"p50": lat["p50"], "p90": lat["p90"], "n": lat["n"]}},
        "anomalies_per_hour": {"stat_narration": per_h(count("stat_narration")),
                               "talk_without_action": per_h(count("promise_without_action")),
                               "stall_over_30s": per_h(len(stalls30))},
        "stability": {"longest_run_without_crash_h": longest, "crashes": len(crashes), "stalls_over_30s": len(stalls30)},
        "voice": {"score": None, "n": 0, "source": None},
        "deaths": deaths(c),
        "detail": m,
    }


def deaths(c: Corpus) -> dict:
    """Each death row classified: a survival stat at 0 at the death (starvation / dehydration), else the game's
    fatal notice within 5 s (a creature or player killer = combat), else other."""
    out = {"total": 0, "starvation": 0, "dehydration": 0, "combat": 0, "other": 0}
    fatals = [d for d in c.vitals if d.get("type") == "fatal"]
    for d in c.vitals:
        if d.get("type") != "death":
            continue
        out["total"] += 1
        surv = d.get("survival") or {}

        def zero(stat: str) -> bool:
            v = surv.get(stat)
            return isinstance(v, (list, tuple)) and bool(v) and float(v[0]) <= 0.0
        f = next((x for x in fatals if abs(x["ts"] - d["ts"]) <= 5), None)
        status = {str(x).lower() for x in (f or {}).get("status") or []}
        killer = (f or {}).get("killed_by") or {}
        if zero("sustenance") or "starvation" in status:
            out["starvation"] += 1
        elif zero("hydration") or "dehydration" in status:
            out["dehydration"] += 1
        elif killer and not killer.get("self"):
            out["combat"] += 1
        else:
            out["other"] += 1
    return out


def render_metrics(m: dict) -> str:
    def row(name, d):
        return f"  {name:<28} n={d['n']:<4} p50={d['p50']}  p90={d['p90']}  max={d['max']}"
    out = ["episodes: " + ", ".join(f"{k}={v}" for k, v in m["episodes"].items()),
           "latency (s):", row("chat -> first response", m["chat_to_first_response_s"]),
           row("chat -> first body action", m["chat_to_first_action_s"]), row("chat -> heard by brain", m["chat_heard_lag_s"])]
    for k, v in m["model_latency_s"].items():
        out.append(row("model " + k, v))
    pt = m["prompt_tokens"]
    out.append(f"model calls: {m['model_calls']} ({m['model_calls_per_episode']}/episode), prompt tokens p50={pt['p50']} "
               f"p90={pt['p90']}, cache share {m['prompt_cache_share']}, state reads per action {m['state_reads_per_action']}")
    out.append("tools:")
    for k, v in m["tools"].items():
        rs = ", ".join(f"{r} x{n}" for r, n in sorted(v["reasons"].items(), key=lambda x: -x[1]))
        out.append(f"  {k:<14} n={v['n']:<3} failed={v['failed']:<3} ({v['fail_rate']:.0%})  p50={v['p50_s']} s"
                   f"  p90={v['p90_s']} s  {rs}")
    out.append("failures by reason: " + (", ".join(f"{k} x{v}" for k, v in m["failures_by_reason"].items()) or "none"))
    out.append(f"retries: {m['retries']}   talk-only replies: {m['talk_only_replies']}   "
               f"promises without action: {m['promises_without_action']}")
    if m["bridge_rtt_s"]:
        out.append("bridge round trip (s): " + ", ".join(f"{k} p50={v['p50']} p90={v['p90']}" for k, v in m["bridge_rtt_s"].items()))
    out.append("anomalies: " + (", ".join(f"{k} x{v}" for k, v in m["anomalies"].items()) or "none"))
    return "\n".join(out)


# ------------------------------------------------------------------ OpenTelemetry (OTLP/JSON, GenAI + OpenInference attributes)
def _attr(k: str, v) -> dict:
    if isinstance(v, bool):
        return {"key": k, "value": {"boolValue": v}}
    if isinstance(v, int):
        return {"key": k, "value": {"intValue": str(v)}}
    if isinstance(v, float):
        return {"key": k, "value": {"doubleValue": v}}
    return {"key": k, "value": {"stringValue": v if isinstance(v, str) else json.dumps(v, default=str, ensure_ascii=False)}}


def _hid(*parts, n: int = 32) -> str:
    return hashlib.sha256("|".join(map(str, parts)).encode()).hexdigest()[:n]


def _ns(t: float) -> str:
    return str(int(t * 1e9))


def to_otlp(eps: list[Episode]) -> dict:
    spans = []
    for ep in eps:
        tid = _hid(ep.file, ep.start, ep.kind)
        root = _hid(tid, "root", n=16)
        err = any(a["level"] in ("warn", "error") for a in ep.anomalies)
        spans.append({"traceId": tid, "spanId": root, "name": f"invoke_agent {ep.kind}", "kind": 1,
                      "startTimeUnixNano": _ns(ep.start), "endTimeUnixNano": _ns(ep.end or ep.start),
                      "attributes": [_attr("gen_ai.operation.name", "invoke_agent"), _attr("gen_ai.agent.name", "Claude"),
                                     _attr("openinference.span.kind", "AGENT"), _attr("dw.episode.kind", ep.kind),
                                     _attr("dw.episode.id", ep.id), _attr("input.value", ep.request),
                                     _attr("output.value", " / ".join(s["text"] for s in ep.said)),
                                     _attr("dw.player", ep.player or ""), _attr("dw.decision", ep.decision or "")]
                      + ([_attr("dw.latency.first_response_s", round(ep.first_response - ep.start, 3))] if ep.first_response else []),
                      "events": [{"timeUnixNano": _ns(parse_ts(a["ts"])), "name": f"anomaly.{a['kind']}",
                                  "attributes": [_attr("message", a["text"]), _attr("level", a["level"])]} for a in ep.anomalies],
                      "status": {"code": 2 if err else 1}})
        for i, s in enumerate(ep.steps):
            if s.kind not in ("model", "action", "read", "say"):
                continue
            sid = _hid(tid, i, n=16)
            a = s.attrs
            if s.kind == "model":
                attrs = [_attr("gen_ai.operation.name", "chat"), _attr("gen_ai.provider.name", "anthropic"),
                         _attr("gen_ai.request.model", a.get("model") or ""), _attr("openinference.span.kind", "LLM"),
                         _attr("dw.step", str(a.get("step")))]
                for k_, v_ in (("gen_ai.usage.input_tokens", "prompt_tok"), ("gen_ai.usage.output_tokens", "completion_tok"),
                               ("gen_ai.usage.cache_read.input_tokens", "cached_tok"),
                               ("gen_ai.usage.cache_creation.input_tokens", "cache_write_tok"),
                               ("llm.token_count.prompt", "prompt_tok"), ("llm.token_count.completion", "completion_tok"),
                               ("llm.token_count.prompt_details.cache_read", "cached_tok")):
                    if a.get(v_) is not None:
                        attrs.append(_attr(k_, int(a[v_])))
                attrs.append(_attr("output.value", json.dumps({"content": a.get("content"), "tool_calls": a.get("calls")},
                                                              ensure_ascii=False, default=str)))
                name, status = f"chat {a.get('model')}", 1
            elif s.kind in ("action", "read"):
                attrs = [_attr("gen_ai.operation.name", "execute_tool"), _attr("gen_ai.tool.name", a.get("tool") or ""),
                         _attr("openinference.span.kind", "TOOL"), _attr("tool.name", a.get("tool") or ""),
                         _attr("input.value", json.dumps(a.get("args"), default=str)), _attr("dw.read_only", s.kind == "read")]
                if a.get("reason"):
                    attrs.append(_attr("error.type", a["reason"]))
                if a.get("detail"):
                    attrs.append(_attr("output.value", a["detail"]))
                if a.get("attempt"):
                    attrs.append(_attr("dw.attempt", int(a["attempt"])))
                name, status = f"execute_tool {a.get('tool')}", (2 if a.get("ok") is False else 1)
            else:
                attrs = [_attr("openinference.span.kind", "CHAIN"), _attr("dw.say.text", s.text.strip('"'))]
                name, status = "say", 1
            spans.append({"traceId": tid, "spanId": sid, "parentSpanId": root, "name": name, "kind": 3 if s.kind == "model" else 1,
                          "startTimeUnixNano": _ns(s.ts), "endTimeUnixNano": _ns(s.end or s.ts), "attributes": attrs,
                          "status": {"code": status}})
            body = a.get("body") if s.kind == "action" else None
            if body and body.get("start") is not None:
                spans.append({"traceId": tid, "spanId": _hid(sid, "body", n=16), "parentSpanId": sid, "name": f"body {a.get('tool')}",
                              "kind": 1, "startTimeUnixNano": _ns(body["start"]), "endTimeUnixNano": _ns(body.get("end") or body["start"]),
                              "attributes": [_attr("dw.body.reason", body.get("reason") or "")], "status": {"code": 1}})
    return {"resourceSpans": [{"resource": {"attributes": [_attr("service.name", "dragonwilds-companion")]},
                               "scopeSpans": [{"scope": {"name": "tools.obs", "version": "1"}, "spans": spans}]}]}


# ------------------------------------------------------------------ CLI
def _window(a, tz) -> tuple[float | None, float | None]:
    day = date.fromisoformat(a.date) if a.date else datetime.now(tz).date()
    since, until = parse_when(a.since, tz, day), parse_when(a.until, tz, day)
    if since is None and getattr(a, "last", None):
        since = time.time() - 6 * 3600
    return since, until


def spend_anomalies(root: Path, since: float | None, until: float | None, now: float | None = None) -> list[dict]:
    """spend_warn (80 %) / spend_cap (100 %) of the daily cap, at the call that crossed it, for each UTC day touched."""
    hi = until if until is not None else (now or time.time())
    lo = since if since is not None else hi - 86400
    out = []
    try:
        days = _spend.days_between(lo, hi)
        for day in days[-3:]:
            s = _spend.spend_day(day, root / "logs")
            for kind, at in (("spend_warn", s["warn_crossed_at"]), ("spend_cap", s["cap_crossed_at"])):
                t = parse_ts(at) if at else None
                if t is not None and lo - 1 <= t <= hi + 1:
                    out.append(_anom(kind, t, f"model spend {day} reached {'80%' if kind == 'spend_warn' else '100%'} of the "
                                     f"${s['cap_usd']:.2f} daily cap (now ${s['spent_usd']:.2f}, {s['pct_of_cap']}%)", None,
                                     "warn" if kind == "spend_warn" else "error", key=f"{kind}:{day}",
                                     spent_usd=s["spent_usd"], cap_usd=s["cap_usd"]))
    except Exception as exc:  # no price table, unreadable logs: say so instead of staying silent
        out.append(_anom("spend_unknown", hi, f"spend could not be computed: {exc!r}", None, "warn",
                         key=f"spend_unknown:{datetime.fromtimestamp(hi, timezone.utc).date()}"))
    return out


def analyse(root: Path, since: float | None, until: float | None, now: float | None = None):
    c = load(root, since, until)
    eps = build_episodes(c)
    anomalies = sorted(detect(c, eps, now=now) + spend_anomalies(root, since, until, now), key=lambda a: a["ts"])
    return c, eps, anomalies


def append_anomalies(path: Path, anomalies: list[dict]) -> list[dict]:
    seen = {d.get("key") for d in jsonl(path)} if path.exists() else set()
    new = [a for a in anomalies if a["key"] not in seen]
    if new:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as f:
            for a in new:
                f.write(json.dumps(a, ensure_ascii=False, default=str) + "\n")
    return new


def follow_tick(root: Path, window: float, out: Path | None, shown: set[str], now: float | None = None) -> list[dict]:
    """One live re-scan of the last ``window`` seconds: the anomalies not seen before (appended to ``out``).
    A line still waiting counts as a stall once it is older than STALL_S (``now`` is the end of the data)."""
    now = time.time() if now is None else now
    _, _, anomalies = analyse(root, now - window, None, now=now)
    fresh = append_anomalies(out, anomalies) if out else anomalies
    fresh = [x for x in fresh if x["key"] not in shown]
    shown.update(x["key"] for x in fresh)
    return fresh


def _fmt_anom(a: dict) -> str:
    t = a["ts"][11:19]
    return f"{t} {a['level']:<5} {a['kind']:<24} {('[' + a['episode'] + ']') if a['episode'] else '':<10} {a['text']}"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sp = sub.add_parser("spend", help="model API spend vs the daily cap (data/model_prices.json)")
    sp.add_argument("--today", action="store_true", help="this UTC day (the default)")
    sp.add_argument("--day", help="a UTC day YYYY-MM-DD")
    sp.add_argument("--json", action="store_true", help="the dw_obs_spend/1 object")
    sp.add_argument("--root", default=str(ROOT), help=argparse.SUPPRESS)
    for name in ("episode", "metrics", "anomalies", "otel"):
        p = sub.add_parser(name)
        p.add_argument("--since", help="HH:MM[:SS] (UTC unless --local), ISO, or 15m / 2h ago")
        p.add_argument("--until")
        p.add_argument("--date", help="day for bare HH:MM (YYYY-MM-DD)")
        p.add_argument("--local", action="store_true")
        p.add_argument("--root", default=str(ROOT), help=argparse.SUPPRESS)
        p.add_argument("--now", type=float, help=argparse.SUPPRESS)
        if name == "episode":
            p.add_argument("--last", type=int, help="only the last N episodes (default window: 6 h)")
            p.add_argument("--kind", help="comma list: chat,body,goal,ignored,ping")
            p.add_argument("-v", "--verbose", action="store_true", help="also body events and trigger notes")
        if name == "metrics":
            p.add_argument("--json", action="store_true", help="the dw_obs_metrics/1 JSON object (tools/goal_check.py)")
        if name == "anomalies":
            p.add_argument("--follow", action="store_true", help="live: re-scan every --interval s and print new ones")
            p.add_argument("--interval", type=float, default=5.0)
            p.add_argument("--window", type=float, default=900.0, help="follow mode: seconds of history re-scanned")
            p.add_argument("--out", default=None, help="anomaly file (default logs/anomalies.jsonl; '-' = don't write)")
            p.add_argument("--stall", type=float, default=STALL_S)
        if name == "otel":
            p.add_argument("--out", default=None, help="OTLP/JSON file (default logs/traces.otlp.json)")
            p.add_argument("--push", help="POST the OTLP/JSON to an OTLP/HTTP endpoint, e.g. http://127.0.0.1:6006/v1/traces")
    a = ap.parse_args(argv)
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    root = Path(a.root)
    if a.cmd == "spend":
        s = _spend.spend_day(date.fromisoformat(a.day) if a.day else datetime.now(timezone.utc).date(), root / "logs")
        print(json.dumps(s, ensure_ascii=False) if a.json else _spend.render(s))
        return 0
    tz = datetime.now().astimezone().tzinfo if a.local else timezone.utc

    if a.cmd == "anomalies" and a.follow:
        out = root / "logs" / "anomalies.jsonl" if a.out in (None, "") else None if a.out == "-" else Path(a.out)
        print(f"following (window {a.window:.0f} s, every {a.interval:.0f} s) -> {out or 'stdout only'}", flush=True)
        shown: set[str] = set()
        while True:
            for x in follow_tick(root, a.window, out, shown):
                print(_fmt_anom(x), flush=True)
            time.sleep(a.interval)

    since, until = _window(a, tz)
    c, eps, anomalies = analyse(root, since, until, now=a.now)
    if a.cmd == "episode":
        if a.kind:
            keep = {k.strip() for k in a.kind.split(",")}
            eps = [e for e in eps if e.kind in keep]
        if a.last:
            eps = eps[-a.last:]
        if not eps:
            print("(no episodes in this window; try --since HH:MM)")
        for i, ep in enumerate(eps, 1):
            print(redact(render_episode(ep, i, tz, a.verbose)))
            print()
    elif a.cmd == "metrics":
        m = metrics(c, eps, anomalies)
        if a.json:
            print(json.dumps(goal_metrics(c, eps, anomalies, m), ensure_ascii=False, default=str))
        else:
            print(render_metrics(m))
    elif a.cmd == "anomalies":
        if a.stall != STALL_S:
            anomalies = detect(c, eps, now=a.now, stall_s=a.stall)
        out = root / "logs" / "anomalies.jsonl" if a.out is None else None if a.out == "-" else Path(a.out)
        if out:
            n = len(append_anomalies(out, anomalies))
        for x in anomalies:
            print(_fmt_anom(x))
        print(f"({len(anomalies)} anomalies" + (f"; {n} new written to {out}" if out else "") + ")")
    elif a.cmd == "otel":
        doc = to_otlp(eps)
        out = Path(a.out) if a.out else root / "logs" / "traces.otlp.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
        n = len(doc["resourceSpans"][0]["scopeSpans"][0]["spans"])
        print(f"{len(eps)} traces, {n} spans -> {out}")
        if a.push:
            req = urllib.request.Request(a.push, data=json.dumps(doc).encode(), headers={"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=10) as r:
                    print(f"pushed: HTTP {r.status}")
            except Exception as exc:  # e.g. an endpoint that only takes protobuf: use the OTel Collector (see design note)
                print(f"push failed: {exc!r}")
                return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

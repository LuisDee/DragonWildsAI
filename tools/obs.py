"""Observability over Claude's logs: per-episode traces, metrics and anomaly detectors (docs/design/observability.md).

An *episode* is one player request (chat line(s) -> decision -> model calls -> tool calls -> body results -> speech),
one body-initiated decision (situation_review, vitals_low, unreachable, a board step ...), a Director decision or one
autonomous goal. Rows are grouped by the brain's ``episode_id`` (brain/jsonl_log.py stamps it on every row); logs
written before that existed fall back to matching by text and time. Nothing in brain/ or client_mod/ is changed:

  brain    <log_dir>/brain-live-*.jsonl          prompts, model replies (usage), tool calls/results, bridge, speech
  chat     client_io/events/chat.jsonl           what players said (game time), for lines the brain never heard
  body     <log_dir>/client/mod_*.jsonl          client_action_start/end (same id as the bridge message), bridge start/stop
  goals    <state_dir>/worlds/*/progress.jsonl   goal started / done / stuck / interrupted
  watchdog <log_dir>/client_watchdog.jsonl       crashes and hangs (stability)
(<log_dir>, <state_dir>: brain/paths.py, DW_LOG_DIR / DW_STATE_DIR; --root R reads R/logs, R/logs/state, R/client_io.)

  .venv\\Scripts\\python.exe -m tools.obs episode --last 5
  .venv\\Scripts\\python.exe -m tools.obs episode --since 20:54 --until 21:18 [--verbose]
  .venv\\Scripts\\python.exe -m tools.obs metrics --since 20:54 --until 21:18 [--json]
  .venv\\Scripts\\python.exe -m tools.obs anomalies --since 20:54 --until 21:18      # also appends <log_dir>/anomalies.jsonl
  .venv\\Scripts\\python.exe -m tools.obs anomalies --follow                          # live tail (re-scans every 5 s)
  .venv\\Scripts\\python.exe -m tools.obs otel --since 20:54 --out logs/traces.otlp.json [--push http://127.0.0.1:6006/v1/traces]
  .venv\\Scripts\\python.exe -m tools.obs task --last 3 [--brain-log <case>/brain.jsonl] [--json]   # long tasks: steps, gaps, idle
  .venv\\Scripts\\python.exe -m tools.obs spend [--today | --day YYYY-MM-DD] [--json]     # $ vs the daily cap (tools/spend.py)

Times are UTC (like tools/timeline.py); --local reads and shows local time.
"""
from __future__ import annotations

import argparse
import bisect
import glob as _glob
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from collections import Counter
from dataclasses import dataclass, field
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Callable, Iterable

from brain import paths
from brain.fileio import append_jsonl
from tools import obs_tasks as _tasks
from tools import spend as _spend
from tools.spend import _iso, _model_id, spend_today  # noqa: F401  (spend_today re-exported for callers of tools.obs)
from tools.timeline import jsonl, parse_ts, parse_when, redact, short

STALL_S = 15.0           # a player line with no response (speech or body action) after this long
UNHEARD_S = 20.0         # a chat line the brain did not log as heard within this long
REPEAT_N, REPEAT_GAP_S = 3, 180.0
LATE_SUCCESS_S = 90.0
NOT_ACTIONS = {"say", "remember", "forget_skill"}
TRIVIAL_ACTIONS = {"stop"} | NOT_ACTIONS   # not a "first action", not world-changing
NOISE_KINDS = {"bridge_unmatched", "bridge_malformed", "bridge_unknown_event", "event_dropped", "help_suppressed",
               "progress_skipped", "say_result", "capabilities", "skill_load_error", "situation_stale",
               "session_end", "ping_reply", "bridge_recv", "task_done", "task_failed"}
NOTE_KINDS = {"chain_turn", "chain_stopped", "situation_unspoken", "controller_invalid_call", "controller_unknown_tool",
              "controller_safety_refusal", "controller_budget_exhausted", "command_error", "next_turn_error",
              "loop_error", "goal_error", "verification_failed", "cooldown_wait", "state_unavailable", "plan_invalid"}
BRIDGE_KINDS = {"bridge_timeout", "bridge_restart_detected", "bridge_command_lost", "bridge_wait_interrupted"}
CRASH_EVENTS = {"client_crash_dump", "client_crash_reporter", "client_hang", "client_gone"}
# A session is live when its session_start says so (live / world_kind); older logs: by world name.
LIVE_WORLDS = {w.strip() for w in os.environ.get("DW_LIVE_WORLDS", "shockbyte").split(",") if w.strip()}


# ------------------------------------------------------------------ loading
@dataclass
class Dirs:
    logs: Path
    state: Path
    events: Path
    repo: Path

    @classmethod
    def default(cls) -> "Dirs":
        return cls(paths.log_dir(), paths.state_dir(), paths.REPO_ROOT / "client_io" / "events", paths.REPO_ROOT)

    @classmethod
    def of(cls, root: "Path | Dirs | str | None") -> "Dirs":
        if isinstance(root, Dirs):
            return root
        if root is None:
            return cls.default()
        r = Path(root)
        return cls(r / "logs", r / "logs" / "state", r / "client_io" / "events", r)


def _in(t: float | None, lo: float | None, hi: float | None) -> bool:
    return t is not None and (lo is None or t >= lo) and (hi is None or t <= hi)


def _rows_in(path: Path, lo: float | None, hi: float | None, keep: Callable[[dict], bool] | None = None) -> list[dict]:
    """Rows of one JSONL with a parsable ts (or iso) inside [lo, hi], ts normalised to unix seconds."""
    out = []
    for d in jsonl(path):
        if keep is not None and not keep(d):
            continue
        t = parse_ts(d.get("ts") or d.get("iso"))
        if _in(t, lo, hi):
            out.append({**d, "ts": t})
    return out


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
    brain: list[dict] = field(default_factory=list)       # every brain record, time-ordered, with "_file"
    sessions: list[dict] = field(default_factory=list)    # {file, start, end, world, live, companion_sha, ...}
    chat: list[dict] = field(default_factory=list)        # chat.jsonl rows (players and Claude)
    body: list[dict] = field(default_factory=list)        # mod_*.jsonl rows (ts parsed)
    goals: list[dict] = field(default_factory=list)       # progress.jsonl goal rows
    watchdog: list[dict] = field(default_factory=list)
    vitals: list[dict] = field(default_factory=list)      # vitals.jsonl death / fatal rows only
    companion_sha: str | None = None                     # the --companion-sha filter, when given
    since: float | None = None
    until: float | None = None
    _spans: dict | None = None

    @property
    def bridge(self) -> dict[str, dict]:
        if self._spans is None:
            self._spans = _bridge_spans(self)
        return self._spans


def _bridge_spans(c: Corpus) -> dict[str, dict]:
    """Every bridge command: {id: {tool, sent, file, recv, timeout}} (one pass over the brain rows)."""
    out: dict[str, dict] = {}
    for d in c.brain:
        k = d.get("kind")
        if k == "bridge_send":
            msg = d.get("msg") or {}
            out[str(msg.get("id"))] = {"tool": str(msg.get("tool")), "sent": d["ts"], "file": d.get("_file"),
                                       "recv": None, "timeout": None}
        elif k == "bridge_recv":
            s = out.get(str((d.get("msg") or {}).get("id")))
            if s is not None and s["recv"] is None:
                s["recv"] = d["ts"]
        elif k == "bridge_timeout":
            s = out.get(str(d.get("id")))
            if s is not None and s["timeout"] is None:
                s["timeout"] = d["ts"]
    return out


_sha_cache: dict[tuple[str, int], str | None] = {}


def _git_sha_at(repo: Path, t: float) -> str | None:
    """The commit HEAD had at time t (the last commit before it), or None without git history."""
    key = (str(repo), int(t))
    if key not in _sha_cache:
        try:
            r = subprocess.run(["git", "-C", str(repo), "log", "-1", f"--before={_iso(t)}", "--format=%H"],
                               capture_output=True, text=True, timeout=10)
            _sha_cache[key] = r.stdout.strip() or None if r.returncode == 0 else None
        except (OSError, subprocess.SubprocessError):
            _sha_cache[key] = None
    return _sha_cache[key]


def session_sha(repo: Path, start_rec: dict | None, start: float) -> dict:
    """{companion_sha, dirty, sha_source}: from session_start when the brain logs it (companion_sha / git_sha / sha,
    dirty), else inferred as the last commit before the session started (dirty unknown: the working tree isn't logged)."""
    rec = start_rec or {}
    sha = rec.get("companion_sha") or rec.get("git_sha") or rec.get("sha")
    if sha:
        return {"companion_sha": str(sha), "dirty": rec.get("dirty", rec.get("git_dirty")), "sha_source": "session_start"}
    sha = _git_sha_at(repo, start)
    return {"companion_sha": sha, "dirty": None, "sha_source": "git_log_before_start" if sha else None}


def _is_live(start_rec: dict | None) -> bool | None:
    rec = start_rec or {}
    if isinstance(rec.get("live"), bool):
        return rec["live"]
    if rec.get("world_kind"):
        return rec["world_kind"] == "live"
    return rec["world"] in LIVE_WORLDS if rec.get("world") else None


def expand_logs(patterns: Iterable[str]) -> list[Path]:
    """--brain-log values: paths or globs (** allowed), comma-separated or repeated."""
    out: list[Path] = []
    for pat in patterns:
        for part in [x.strip() for x in str(pat).split(",") if x.strip()]:
            hits = sorted(_glob.glob(part, recursive=True)) or ([part] if Path(part).exists() else [])
            out += [Path(h) for h in hits if Path(h).is_file() and Path(h) not in out]
    return out


def load(root: "Path | Dirs | None", since: float | None, until: float | None, pad: float = 300.0,
         companion_sha: str | None = None, brain_logs: list[Path] | None = None) -> Corpus:
    """Everything that can touch [since, until]; brain records padded so an episode that started just before
    the window still has its trigger. ``companion_sha``: only brain sessions at those commits (comma-separated
    prefixes), and only the chat/body/vitals/watchdog rows inside those sessions."""
    d = Dirs.of(root)
    c = Corpus(since=since, until=until, companion_sha=companion_sha)
    lo = since - pad if since is not None else None
    hi = until + pad if until is not None else None
    prefixes = [x.strip() for x in str(companion_sha or "").split(",") if x.strip()]
    # The default scan is the live brain only (brain-live-*.jsonl at the top of the log dir). Benchmark and eval
    # sessions under logs/evals/ never count toward live metrics; read them explicitly with brain_logs.
    files = brain_logs if brain_logs is not None else d.logs.glob("brain-live-*.jsonl")
    for f in _overlapping(files, lo, hi):
        recs = [r for r in jsonl(f) if isinstance(parse_ts(r.get("ts")), float)]
        if not recs:
            continue
        start_rec = next((r for r in recs if r.get("kind") == "session_start"), None)
        sess = {"file": f.name, "start": recs[0]["ts"], "end": recs[-1]["ts"], "world": (start_rec or {}).get("world"),
                "live": _is_live(start_rec), **session_sha(d.repo, start_rec, recs[0]["ts"])}
        if prefixes and not any(str(sess["companion_sha"] or "").startswith(x) for x in prefixes):
            continue
        c.sessions.append(sess)
        for r in recs:
            if _in(r["ts"], lo, hi):
                r["_file"] = f.name
                c.brain.append(r)
    c.brain.sort(key=lambda r: r["ts"])
    if brain_logs is not None:  # an explicit (eval/benchmark) brain log: the live chat/body/vitals files are not its world
        c.chat = [{"ts": parse_ts((r.get("event") or {}).get("ts")) or r["ts"], "type": "chat", "self": False,
                   "from": (r.get("event") or {}).get("player"), "text": (r.get("event") or {}).get("text", "")}
                  for r in c.brain if r.get("kind") == "event" and (r.get("event") or {}).get("type") in ("chat_heard", "command_received")]
        return c
    c.chat = _rows_in(d.events / "chat.jsonl", lo, hi)
    c.body = sorted((r for f in _overlapping((d.logs / "client").glob("mod_*.jsonl"), lo, hi) for r in _rows_in(f, lo, hi)),
                    key=lambda r: r["ts"])
    c.goals = sorted((r for f in (d.state / "worlds").glob("*/progress.jsonl")
                      for r in _rows_in(f, lo, hi, lambda x: str(x.get("msg", "")).startswith(("goal", "stuck", "replanned")))),
                     key=lambda r: r["ts"])
    c.vitals = sorted(_rows_in(d.events / "vitals.jsonl", since, until, lambda x: x.get("type") in ("death", "fatal")),
                      key=lambda r: r["ts"])
    c.watchdog = _rows_in(d.logs / "client_watchdog.jsonl", since, until)
    if prefixes:  # only what happened while a brain at those commits ran
        inside = lambda t: any(x["start"] - 5 <= t <= x["end"] + 30 for x in c.sessions)  # noqa: E731
        c.chat, c.body = [r for r in c.chat if inside(r["ts"])], [r for r in c.body if inside(r["ts"])]
        c.vitals, c.watchdog = [r for r in c.vitals if inside(r["ts"])], [r for r in c.watchdog if inside(r["ts"])]
    return c


# ------------------------------------------------------------------ episodes
@dataclass
class Step:
    ts: float
    kind: str            # model | read | action | say | note | event | bridge | trigger
    text: str
    end: float | None = None
    level: str = "info"
    attrs: dict = field(default_factory=dict)


@dataclass
class Episode:
    kind: str                       # chat | body | goal | director | ignored | ping
    start: float                    # player said it (game time) / body trigger / goal start
    player: str | None = None
    request: str = ""               # what the player said (merged burst) or the body event summary
    lines: list[dict] = field(default_factory=list)   # [{said, heard, text, decision}]
    steps: list[Step] = field(default_factory=list)
    ran: list[dict] = field(default_factory=list)     # [{tool, ok, reason, attempt, ts, end, ...}]
    said: list[dict] = field(default_factory=list)    # [{ts, text}]
    model_calls: list[dict] = field(default_factory=list)
    decision: str | None = None
    first_model: float | None = None
    first_action: float | None = None
    first_say: float | None = None
    end: float | None = None
    file: str | None = None
    eid: str | None = None          # the brain's episode_id, when logged
    state_reads: int = 0
    anomalies: list[dict] = field(default_factory=list)
    consumed: list[str] = field(default_factory=list)  # planned tools that already ran
    negations: list[tuple[str, float, str]] = field(default_factory=list)  # (verb stem, ts, line): "won't X"

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

    def planned_left(self) -> list[str]:
        left = [x["name"] for m in self.model_calls for x in m["calls"] if x["name"]]
        for t in self.consumed:
            if t in left:
                left.remove(t)
        return left

    def consume(self, tool: str) -> None:
        self.consumed.append(tool)

    def read_tools(self) -> set[str]:
        return {s.attrs.get("tool") for s in self.steps if s.kind == "read"}


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
    if t == "board_step":
        return f"board_step '{(ev.get('step') or {}).get('title')}' run {ev.get('run')} ({short(ev.get('task'), 60)})"
    keep = {k: v for k, v in ev.items() if k in ("stat", "value", "reason", "target", "where", "kind", "about")}
    return f"{t} {short(keep, 100)}"


def _result_text(r: dict) -> tuple[bool, str | None, str]:
    res = r.get("result") or {}
    data = res.get("data") or {}
    detail = data.get("detail") or data.get("why") or ""
    return bool(res.get("ok")), res.get("reason"), str(detail)


def _brief(rec: dict, drop: tuple = ()) -> str:
    return short({x: y for x, y in rec.items() if x not in ("ts", "kind", "_file", "episode_id", "traceback") + drop}, 160)


class _Builder:
    """Turns the brain rows into episodes. With ``episode_id`` on the rows, ownership is by id; for older logs the
    owner is the episode of the last decide prompt / tool call (and chat lines are matched to it by text)."""

    def __init__(self, c: Corpus):
        self.c = c
        self.eps: list[Episode] = []
        self.by_eid: dict[str, Episode] = {}
        self.cur: Episode | None = None
        self.goal: Episode | None = None
        self.pending: list[dict] = []           # heard lines not yet decided: {player, text, said, heard, decision, eid}
        self.owner_of_task: dict[str, Episode] = {}
        self.open_prompt: dict[str, tuple[float, Episode, dict]] = {}
        self.last_tool: dict | None = None
        self.last_owner: Episode | None = None
        self.redecided = False
        self.goal_rows = list(c.goals)

    # ---- ownership
    def owner(self, rec: dict) -> Episode | None:
        eid = rec.get("episode_id")
        if eid and eid in self.by_eid:
            return self.by_eid[eid]
        return self.last_owner or self.cur or self.goal

    def new(self, ep: Episode, rec: dict | None = None) -> Episode:
        self.eps.append(ep)
        eid = (rec or {}).get("episode_id")
        if eid and eid not in self.by_eid:
            ep.eid = eid
            self.by_eid[eid] = ep
        return ep

    def attach(self, step: Step, rec: dict, ep: Episode | None = None) -> None:
        target = ep or self.owner(rec)
        if target is not None:
            target.add(step)

    # ---- goals (state store rows)
    def start_goal(self, ts: float, text: str, file: str | None, rec: dict | None = None) -> None:
        self.goal = self.new(Episode("goal", ts, request=text, file=file), rec)
        self.last_owner = self.goal

    def goal_row(self, g: dict, file: str | None) -> None:
        if g.get("msg") == "goal started":
            self.start_goal(g["ts"], str(g.get("goal")), file)
        elif self.goal is not None:
            self.goal.add(Step(g["ts"], "note", f"goal {g.get('msg')}: {short(g.get('reason') or '', 120)}",
                               level="warn" if g.get("msg") != "goal done" else "info"))
            self.goal.decision = str(g.get("msg"))
            if g.get("msg") in ("goal done", "stuck", "goal interrupted"):
                self.goal = None

    # ---- the run
    def run(self) -> list[Episode]:
        handlers = {"session_start": self.on_session, "event": self.on_event, "chat_decision": self.on_chat_decision,
                    "prompt": self.on_prompt, "llm_response": self.on_response, "speech_redecided": self.on_redecided,
                    "tool_call": self.on_tool_call, "tool_result": self.on_tool_result, "bridge_send": self.on_bridge_send,
                    "say": self.on_say, "situation_review": self.on_trigger, "event_triage": self.on_trigger}
        for rec in self.c.brain:
            ts, k = rec["ts"], rec.get("kind")
            while self.goal_rows and self.goal_rows[0]["ts"] <= ts:
                self.goal_row(self.goal_rows.pop(0), rec.get("_file"))
            if k in handlers:
                handlers[k](rec, ts)
            elif k in BRIDGE_KINDS:
                self.on_bridge_note(rec, ts)
            elif k in NOTE_KINDS:
                self.attach(Step(ts, "note", f"{k} {_brief(rec)}", level="info" if k in ("chain_turn", "cooldown_wait") else "warn",
                                 attrs=rec), rec)
            elif k == "help":
                self.attach(Step(ts, "note", f"help {rec.get('key')}: {short(rec.get('text'), 120)}"), rec)
            elif k not in NOISE_KINDS:
                self.attach(Step(ts, "note", f"{k} {_brief(rec)}"), rec)
        for g in self.goal_rows:  # goal ends logged after the last brain record
            self.goal_row(g, None)
        return self.finish()

    def finish(self) -> list[Episode]:
        eps = self.eps
        for e in eps:
            if e.decision is None and e.lines:
                e.decision = e.lines[-1].get("decision")
        for p in self.pending:  # heard, never decided (the session ended or the brain is still busy)
            eps.append(Episode("chat", p["said"], p["player"], p["text"], lines=[p], decision="never decided", end=p["heard"]))
        _attach_body(eps, self.c)
        eps.sort(key=lambda e: e.start)
        c = self.c
        if c.since is not None or c.until is not None:
            eps = [e for e in eps if _in(e.start, c.since, c.until)]
        return eps

    def on_session(self, rec: dict, ts: float) -> None:
        self.cur, self.pending, self.open_prompt, self.last_owner, self.last_tool = None, [], {}, None, None

    def on_event(self, rec: dict, ts: float) -> None:
        e = rec.get("event") or {}
        et = e.get("type")
        if et in ("chat_heard", "command_received"):
            self.pending.append({"player": e.get("player"), "text": str(e.get("text", "")), "said": parse_ts(e.get("ts")) or ts,
                                 "heard": ts, "decision": None, "eid": rec.get("episode_id")})
            return
        if et == "activity":
            detail = e.get("detail") or {x: y for x, y in e.items() if x not in ("type", "ts", "iso")}
            self.attach(Step(ts, "event", f"body {e.get('kind')}: {short(detail, 140)}",
                             level="warn" if e.get("kind") in ("death", "fled", "stuck") else "info", attrs=e), rec)
            return
        self.attach(Step(ts, "event", f"{et}: {short({x: y for x, y in e.items() if x != 'type'}, 140)}",
                         level="warn" if et in ("vitals_low", "unreachable", "attacked") else "info", attrs=e), rec)

    def on_chat_decision(self, rec: dict, ts: float) -> None:
        dec, text = rec.get("decision"), _norm(rec.get("text", ""))
        for p in reversed(self.pending):
            if _norm(p["text"]) == text and p["decision"] in (None, "pending"):
                p["decision"] = f"{dec} ({rec.get('reason')})"
                break
        if dec == "ignored" and not str(rec.get("reason", "")).startswith("model"):  # rate cap: no model call
            mine = self.take_lines(lambda p: p["player"] == rec.get("player"), rec.get("episode_id"))
            if mine:
                self.new(Episode("ignored", min(p["said"] for p in mine), rec.get("player"), rec.get("text", ""), lines=mine,
                                 decision=f"ignored ({rec.get('reason')})", file=rec.get("_file"), end=ts), rec)
        elif dec == "ping":
            mine = self.take_lines(lambda p: _norm(p["text"]) == text, rec.get("episode_id"))
            self.new(Episode("ping", mine[0]["said"] if mine else ts, rec.get("player"), rec.get("text", ""), lines=mine,
                             decision="ping", file=rec.get("_file"), end=ts), rec)
        elif str(rec.get("reason", "")).startswith("model"):
            ep = self.by_eid.get(rec.get("episode_id")) or self.cur
            if ep is not None:
                ep.decision = f"{dec} ({rec.get('reason')})"
                if dec == "ignored":
                    ep.kind = "ignored"

    def take_lines(self, fallback: Callable[[dict], bool], eid: str | None) -> list[dict]:
        """The pending lines this decision covers: those of its episode id, else the fuzzy fallback (old logs)."""
        mine = [p for p in self.pending if eid and p.get("eid") == eid] or \
               [p for p in self.pending if not (eid and p.get("eid")) and fallback(p)]
        self.pending = [p for p in self.pending if p not in mine]
        return mine

    def on_prompt(self, rec: dict, ts: float) -> None:
        comp = rec.get("component") or "?"
        ctx = _context(rec)
        eid = rec.get("episode_id")
        if comp == "planner" and self.goal is None:
            self.start_goal(ts, "(planner) " + short((rec.get("messages") or [{}])[-1].get("content"), 100), rec.get("_file"), rec)
        if comp == "director" and eid not in self.by_eid:
            self.new(Episode("director", ts, request=f"{rec.get('decision')} for task {rec.get('task')}", file=rec.get("_file")), rec)
        if ctx is not None and not self.redecided and not (eid and eid in self.by_eid and self.by_eid[eid].model_calls):
            self.cur = self.decide_episode(rec, ctx, ts)
        elif ctx is not None and eid and eid in self.by_eid:
            self.cur = self.by_eid[eid]
        self.redecided = False
        target = self.goal if comp == "planner" else self.by_eid.get(eid) if eid in self.by_eid else self.cur
        if target is not None:
            self.open_prompt[comp] = (ts, target, rec)
            self.last_owner = target

    def decide_episode(self, rec: dict, ctx: dict, ts: float) -> Episode:
        cmd = ctx["command"]
        text = str(cmd.get("text") or "")
        eid = rec.get("episode_id")
        if text:
            pieces = {_norm(x) for x in text.split(" / ") if x.strip()}
            mine = self.take_lines(lambda p: p["player"] == cmd.get("player") and
                                   any(_norm(p["text"]) == q or q in _norm(p["text"]) or _norm(p["text"]) in q for q in pieces), eid)
            ep = self.new(Episode("chat", min([p["said"] for p in mine] or [ts]), cmd.get("player"), text, lines=mine,
                                  file=rec.get("_file")), rec)
            if ctx.get("body_event"):
                ep.add(Step(ts, "note", "also deciding: " + _body_summary(ctx["body_event"])))
            return ep
        prev = self.cur
        began = prev.model_calls[0]["ts"] if prev and prev.model_calls else float("-inf")
        trig = [s for s in (prev.steps if prev else []) if s.kind == "trigger" and ts - s.ts < 10 and s.ts > began]
        ep = self.new(Episode("body", min([s.ts for s in trig] or [ts]), cmd.get("player"), _body_summary(ctx.get("body_event")),
                              file=rec.get("_file")), rec)
        for s in trig:  # the trigger was logged before this decision started: it belongs here
            prev.steps.remove(s)
            ep.add(s)
        return ep

    def on_response(self, rec: dict, ts: float) -> None:
        comp = rec.get("component") or "?"
        eid = rec.get("episode_id")
        if comp in self.open_prompt:
            t0, ep, prec = self.open_prompt.pop(comp)
        elif eid in self.by_eid and self.by_eid[eid].model_calls:  # a further round of the same decision (Director research)
            ep = self.by_eid[eid]
            t0, prec = ep.model_calls[-1]["end"], {"model": ep.model_calls[-1]["model"]}
        else:
            t0, ep, prec = None, self.by_eid.get(eid, self.cur), {}
        u = rec.get("usage") or {}
        calls = [x if isinstance(x, dict) else {"name": str(x)} for x in (rec.get("tool_calls") or [])]  # director: names only
        model = _model_id(prec.get("model") or rec.get("model")) or ""
        call = {"ts": t0 or ts, "end": ts, "latency": round(ts - t0, 3) if t0 else None, "component": comp,
                "model": model, "step": rec.get("step"), "prompt_tok": u.get("prompt"), "completion_tok": u.get("completion"),
                "cached_tok": u.get("cached"), "cache_write_tok": u.get("cache_write"),
                "calls": [{"name": x.get("name"), "args": x.get("arguments"), "id": x.get("id")} for x in calls],
                "content": rec.get("content")}
        if ep is None:
            return
        ep.model_calls.append(call)
        ep.first_model = ep.first_model or ts
        bits = [f"{x.get('name')}({short(x.get('arguments'), 90)})" for x in calls]
        if rec.get("content"):
            bits.append(f'says "{short(rec["content"], 200)}"')
        lat = f"{call['latency']:.1f} s" if call["latency"] is not None else "?"
        tok = f"{u.get('prompt')}+{u.get('completion')} tok, cached {u.get('cached') or 0}" if u else ""
        ep.add(Step(t0 or ts, "model", f"{comp} {model} [{rec.get('step')}] {lat} {tok} -> " + ("; ".join(bits) or "(nothing)"),
                    end=ts, attrs=call))

    def on_redecided(self, rec: dict, ts: float) -> None:
        self.redecided = True
        self.attach(Step(ts, "note", f"speech re-decided on fresh state {short(rec.get('changed'), 80)}; first draft unsaid: "
                                     f'"{short(rec.get("first"), 120)}"'), rec)

    def on_tool_call(self, rec: dict, ts: float) -> None:
        tool = str(rec.get("tool"))
        eid = rec.get("episode_id")
        if rec.get("read_only"):
            ep = self.by_eid.get(eid) if eid in self.by_eid else self.cur
            if ep is not None:
                ep.add(Step(ts, "read", f"{tool}({short(rec.get('args'), 90)})", attrs={"tool": tool}))
            self.last_tool = {"rec": rec, "ep": ep, "read": True}
            return
        tid = rec.get("task_id")
        ep = self.owner_of_task.get(tid) if tid else None
        if ep is None:
            if eid in self.by_eid:
                ep = self.by_eid[eid]
            elif self.cur is not None and tool in self.cur.planned_left():
                ep = self.cur
            else:
                ep = self.goal or self.cur
            if tid and ep is not None:
                self.owner_of_task[tid] = ep
        if ep is None:
            return
        if tool in ep.planned_left():
            ep.consume(tool)
        step = Step(ts, "action", f"{tool}({short(rec.get('args'), 90)})" + (f" try {rec.get('attempt')}" if (rec.get("attempt") or 1) > 1 else ""),
                    attrs={"tool": tool, "task_id": tid, "attempt": rec.get("attempt"), "args": rec.get("args")})
        ep.add(step)
        ep.first_action = ep.first_action or ts
        self.last_tool = {"rec": rec, "ep": ep, "step": step}
        self.last_owner = ep

    def on_tool_result(self, rec: dict, ts: float) -> None:
        ok, reason, detail = _result_text(rec)
        if rec.get("read_only"):
            lt = self.last_tool or {}
            if lt.get("read") and lt.get("ep") is not None:
                for s in reversed(lt["ep"].steps):
                    if s.kind == "read" and s.end is None:
                        s.end = ts
                        s.text += f" -> ok={ok}" + (f" {reason}" if reason else "")
                        break
            return
        tid = rec.get("task_id")
        ep = self.owner_of_task.get(tid) if tid else (self.last_tool or {}).get("ep")
        if ep is None:
            return
        step = next((s for s in reversed(ep.steps) if s.kind == "action" and s.end is None and
                     s.attrs.get("tool") == rec.get("tool")), None)
        if step is None:
            return
        step.end = ts
        step.level = "info" if ok else "warn"
        step.attrs.update(ok=ok, reason=reason, detail=detail)
        step.text += f" -> {'ok' if ok else 'FAIL ' + str(reason)} {ts - step.ts:.1f} s" + (f' "{short(detail, 110)}"' if detail else "")
        ep.ran.append({"tool": rec.get("tool"), "ok": ok, "reason": reason, "attempt": step.attrs.get("attempt"),
                       "ts": step.ts, "end": ts, "detail": detail, "args": step.attrs.get("args"),
                       "bridge_id": step.attrs.get("bridge_id"), "task_id": step.attrs.get("task_id")})
        ep.end = max(ep.end or ts, ts)

    def on_bridge_send(self, rec: dict, ts: float) -> None:
        msg = rec.get("msg") or {}
        tool = str(msg.get("tool"))
        lt = self.last_tool or {}
        ep = self.by_eid.get(rec.get("episode_id")) if rec.get("episode_id") in self.by_eid else (lt.get("ep") or self.cur)
        if tool == "get_state" and ep is not None:
            ep.state_reads += 1
        if lt.get("step") is not None and lt["step"].attrs.get("tool") == tool and "bridge_id" not in lt["step"].attrs:
            lt["step"].attrs["bridge_id"] = msg.get("id")

    def on_say(self, rec: dict, ts: float) -> None:
        ep = self.owner(rec)
        if ep is None:
            return
        text = str(rec.get("text", ""))
        ep.said.append({"ts": ts, "text": text, "voice": rec.get("voice")})
        ep.first_say = ep.first_say or ts
        ep.add(Step(ts, "say", f'"{text}"', attrs={"voice": rec.get("voice")}))

    def on_trigger(self, rec: dict, ts: float) -> None:
        k = rec.get("kind")
        ev = rec.get("event") or {"type": "situation_review", "changes": rec.get("changes")}
        self.attach(Step(ts, "trigger", f"{k}: {_body_summary(ev)}" + (f" -> {rec.get('verdict')} ({rec.get('why')})" if rec.get("verdict") else "")),
                    rec)

    def on_bridge_note(self, rec: dict, ts: float) -> None:
        span = self.c.bridge.get(str(rec.get("id"))) or {}
        ep = self.by_eid.get(rec.get("episode_id")) or _episode_at(self.eps, span["sent"]) if span else self.cur
        self.attach(Step(ts, "bridge", f"{rec.get('kind')} {rec.get('tool')} {_brief(rec, ('tool',))}", level="warn", attrs=rec),
                    rec, ep)


def build_episodes(c: Corpus) -> list[Episode]:
    return _Builder(c).run()


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


STEP_LABELS = {"model": "think", "read": "read", "action": "do", "say": "SAY", "note": "note", "event": "body",
               "bridge": "bridge", "trigger": "trigger"}


def render_episode(ep: Episode, n: int, tz: timezone = timezone.utc, verbose: bool = False) -> str:
    fails = sum(1 for r in ep.ran if not r["ok"])
    head = f"#{n} [{ep.id}] {ep.kind.upper()} {_hms(ep.start, tz)}"
    head += f'  {ep.player}: "{short(ep.request, 160)}"' if ep.kind in ("chat", "ignored", "ping") else f"  {short(ep.request, 160)}"
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
        if not verbose and s.kind == "event" and s.level == "info":
            continue
        mark = "!" if s.level != "info" else " "
        extra = ""
        if s.kind == "action" and s.attrs.get("body"):
            b = s.attrs["body"]
            extra = f"  [body {_hms(b['start'], tz)}-{_hms(b['end'], tz)}{' ' + b['reason'] if b.get('reason') else ''}]"
        out.append(f"   {mark}+{s.ts - ep.start:6.1f} {STEP_LABELS.get(s.kind, s.kind):<7} {s.text}{extra}")
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
DONE_RX = re.compile(r"^\W*(all )?done\b", re.I)
FAIL_WORDS_RX = re.compile(r"\b(didn't|did not|couldn't|could not|can't|cannot|won't|failed|no runes were used|not selected|"
                           r"didn't go off|isn't working)\b", re.I)
NEG_PROMISE_RX = re.compile(r"\b(?:no more|won't|will not|stop|not going to|i'll stop)\s+(\w+)", re.I)
ENGINE_ID_RX = re.compile(r"\b(?:BP|ITEM|USD|DIM|WBP|ABP|DA|BM)_\w+|\bfol:\S+|table: [0-9A-F]{8,}")
COLON_CODE_RX = re.compile(r"\bI couldn'?t [\w ]+:\s*([a-z][a-z_ ]+)\.?$", re.I)
SNAKE_RX = re.compile(r"[a-z]+(?:_[a-z0-9]+)+")
_SENT_RX = re.compile(r"(?<=[.!?])\s+")


def _sentences(text: str) -> list[str]:
    return [s.strip() for s in _SENT_RX.split(text) if s.strip()]


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
            vocab |= {v for v in (res.get("reason"), (res.get("data") or {}).get("why")) if isinstance(v, str) and SNAKE_RX.fullmatch(v)}
    return vocab


class _Codes:
    """One compiled alternation for the reason vocabulary (and its spaced form at the start of a line)."""

    def __init__(self, vocab: set[str]):
        self.vocab = vocab
        words = sorted(vocab, key=len, reverse=True)
        spaced = sorted({v.replace("_", " ") for v in vocab if "_" in v}, key=len, reverse=True)
        self.word_rx = re.compile(r"\b(" + "|".join(map(re.escape, words)) + r")\b") if words else None
        self.spaced_rx = re.compile(r"^\W*(" + "|".join(map(re.escape, spaced)) + r")\b", re.I) if spaced else None

    def find(self, text: str) -> list[str]:
        codes = set(self.word_rx.findall(text)) if self.word_rx else set()
        codes |= set(ENGINE_ID_RX.findall(text))
        if self.spaced_rx and (m := self.spaced_rx.match(text)):
            codes.add(m.group(1).lower())
        out = sorted(codes)
        m = COLON_CODE_RX.search(text)
        if m and m.group(1).strip().replace(" ", "_").lower() in self.vocab and m.group(1).strip() not in out:
            out.append(m.group(1).strip())
        return out


def _anom(kind: str, ts: float, text: str, ep: Episode | None, level: str = "warn", key: str | None = None, **data) -> dict:
    a = {"ts": _iso(ts), "kind": kind, "level": level, "episode": ep.id if ep else None, "text": redact(text),
         "key": key or f"{kind}:{round(ts, 1)}", "data": data}
    if ep is not None:
        ep.anomalies.append(a)
    return a


class _Detect:
    """The anomaly detectors over one corpus and its episodes (each detector is one method)."""

    def __init__(self, c: Corpus, eps: list[Episode], now: float | None, stall_s: float):
        self.c, self.eps, self.stall_s = c, eps, stall_s
        self.codes = _Codes(reason_vocab(c))
        self.late = [d for d in c.brain if d.get("kind") == "event" and (d.get("event") or {}).get("kind") == "cast_late_success"]
        self.end_of_data = now or (c.until if c.until is not None else (c.brain[-1]["ts"] if c.brain else time.time()))
        self.busy = _BusyIndex(c)

    def run(self) -> list[dict]:
        out: list[dict] = []
        for ep in self.eps:
            out += self.stall(ep)
            for s in ep.said:
                out += self.speech(ep, s["text"], s["ts"])
            out += self.timeouts(ep)
        out += self.negations() + self.repeats() + self.unheard() + self.bridge_restarts()
        out.sort(key=lambda a: a["ts"])
        uniq, seen = [], set()
        for a in out:
            if _in(parse_ts(a["ts"]), None if self.c.since is None else self.c.since - 1,
                   None if self.c.until is None else self.c.until + 1) and a["key"] not in seen:
                seen.add(a["key"])
                uniq.append(a)
        return uniq

    def stall(self, ep: Episode) -> list[dict]:
        """A player's line waited too long for any response."""
        if ep.kind != "chat":
            return []
        resp = ep.first_response
        wait = (resp if resp is not None else self.end_of_data) - ep.start
        if wait <= self.stall_s or (resp is None and ep.decision and ep.decision.startswith("ignored")):
            return []
        heard = min([p["heard"] for p in ep.lines] or [ep.start])
        busy = _blocked_by(self.eps, ep, ep.start, heard) or self.busy.longest(ep.start, heard)
        why = f"heard after {heard - ep.start:.1f} s" + (f" (brain busy: {busy})" if busy else "")
        if ep.first_model:
            why += f"; model replied +{ep.first_model - ep.start:.1f} s"
        return [_anom("stall", ep.start, f'"{short(ep.request, 80)}" waited {wait:.0f} s for a response; {why}'
                      + ("" if resp is not None else " (no response yet)"), ep, "error" if wait > 60 else "warn",
                      f"stall:{ep.id}", wait_s=round(wait, 1), heard_lag_s=round(heard - ep.start, 1), busy_with=busy,
                      answered=resp is not None)]

    def acted_on(self, ep: Episode, t: float) -> bool:
        """An action started after the line, or the model call that produced the line also asked for one that ran."""
        if any(r["ts"] >= t - 1.5 for r in ep.ran):
            return True
        src = [m for m in ep.model_calls if m["end"] <= t + 0.1]
        reads = ep.read_tools()
        return bool(src) and any(x["name"] not in reads and x["name"] not in NOT_ACTIONS and
                                 any(r["tool"] == x["name"] and r["ts"] >= src[-1]["end"] - 0.1 for r in ep.ran)
                                 for x in src[-1]["calls"])

    def speech(self, ep: Episode, text: str, t: float) -> list[dict]:
        """promise without action, raw codes, stat narration, contradictions, per spoken line."""
        out = []
        goal_after = any(g.kind == "goal" and 0 <= g.start - t <= 10 for g in self.eps)
        for sent in _sentences(text):
            if PROMISE_RX.search(sent) and not CONDITIONAL_RX.search(sent) and not sent.endswith("?") \
                    and not NOT_A_DEED_RX.search(sent) and not self.acted_on(ep, t) and not goal_after:
                out.append(_anom("promise_without_action", t, f'said "{short(sent, 120)}" and no body action followed', ep,
                                 key=f"promise:{round(t, 1)}", sentence=sent))
                break
        codes = self.codes.find(text)
        if codes:
            out.append(_anom("raw_code_spoken", t, f'said "{short(text, 120)}" (raw: {", ".join(codes)})', ep,
                             key=f"raw:{round(t, 1)}", codes=codes))
        if STAT_RX.search(text) and not (ep.kind == "chat" and "?" in ep.request):
            out.append(_anom("stat_narration", t, f'unprompted numbers: "{short(text, 140)}"', ep,
                             "warn" if ep.kind == "body" else "info", key=f"stat:{round(t, 1)}",
                             unprompted=ep.kind == "body", matches=STAT_RX.findall(text)))
        before = [r for r in ep.ran if r["end"] <= t + 0.5]
        if SUCCESS_RX.search(text) and before and not any(r["ok"] for r in before):
            out.append(_anom("contradictory_speech", t, f'claimed success "{short(text, 100)}" but every action failed '
                             f"({', '.join(sorted({str(r['reason']) for r in before}))})", ep, key=f"contra-ok:{round(t, 1)}",
                             rule="success_claim_all_failed"))
        if DONE_RX.match(text):
            left = [x for x in ep.planned_left() if x not in NOT_ACTIONS and x not in ep.read_tools()]
            if left and before:
                out.append(_anom("contradictory_speech", t, f'said "{short(text, 60)}" but planned {", ".join(left)} never ran', ep,
                                 key=f"contra-done:{round(t, 1)}", rule="done_with_unrun_plan", unrun=left))
        for r in ep.ran:
            spell = (r.get("args") or {}).get("spell") if isinstance(r.get("args"), dict) else None
            if r["tool"] == "cast" and not r["ok"] and spell and spell.lower() in text.lower() and FAIL_WORDS_RX.search(text):
                hit = next((d for d in self.late if d["ts"] >= t - 5 and (d.get("event") or {}).get("ts", d["ts"]) - t <= LATE_SUCCESS_S
                            and str((d.get("event") or {}).get("spell", "")).lower() == spell.lower()), None)
                if hit:
                    out.append(_anom("contradictory_speech", t, f'said {spell} failed ("{short(text, 80)}") but the body '
                                     f"later reported it went off", ep, key=f"contra-late:{round(t, 1)}", rule="failure_then_late_success"))
                    break
        ep.negations += [(m.group(1).lower(), t, text) for m in NEG_PROMISE_RX.finditer(text)]
        return out

    def timeouts(self, ep: Episode) -> list[dict]:
        by_task: dict[str, list[dict]] = {}
        for r in ep.ran:
            if r["reason"] == "timeout":
                by_task.setdefault(str(r.get("task_id") or r["ts"]), []).append(r)
        out = []
        for tid, rs in by_task.items():
            secs = [round(r["end"] - r["ts"]) for r in rs]
            out.append(_anom("tool_timeout", rs[0]["ts"], f"{rs[0]['tool']} timed out" + (f" {len(rs)}x" if len(rs) > 1 else "")
                             + f" after {'/'.join(map(str, secs))} s" + (f' ("{short(rs[-1]["detail"], 80)}")' if rs[-1]["detail"] else ""),
                             ep, "error" if sum(secs) > 60 else "warn", key=f"timeout:{tid}", tool=rs[0]["tool"],
                             seconds=secs, attempts=len(rs)))
        return out

    def negations(self) -> list[dict]:
        """Said "won't / no more / stop X", then ran tool X within 5 min."""
        out = []
        for ep in self.eps:
            for stem, t, text in ep.negations:
                if len(stem) < 4:
                    continue
                hit = next(((later, r) for later in self.eps for r in later.ran if 0 < r["ts"] - t <= 300 and
                            (stem.startswith(r["tool"]) or r["tool"].startswith(stem[:4]))), None)
                if hit:
                    later, r = hit
                    asked = later is not ep and later.kind == "chat"
                    out.append(_anom("contradictory_speech", r["ts"], f'said "{short(text, 80)}" then ran {r["tool"]} '
                                     f"{r['ts'] - t:.0f} s later" + (" (the player asked again)" if asked else ""),
                                     later, "info" if asked else "warn", key=f"contra-neg:{round(t, 1)}", rule="said_wont_then_did"))
        return out

    def repeats(self) -> list[dict]:
        """>= REPEAT_N failures of the same (tool, reason), gaps <= REPEAT_GAP_S."""
        fails = sorted(((r["ts"], r["tool"], r["reason"], ep) for ep in self.eps for r in ep.ran if not r["ok"]), key=lambda x: x[0])
        groups: dict[tuple, list[list]] = {}
        for f in fails:
            runs = groups.setdefault((f[1], f[2]), [])
            if runs and f[0] - runs[-1][-1][0] <= REPEAT_GAP_S:
                runs[-1].append(f)
            else:
                runs.append([f])
        out = []
        for (tool, reason), runs in groups.items():
            for run in runs:
                if len(run) >= REPEAT_N:
                    out.append(_anom("repeated_failure", run[0][0], f"{tool} failed {len(run)}x with {reason} in "
                                     f"{run[-1][0] - run[0][0]:.0f} s across {len({id(x[3]) for x in run})} episode(s)", run[-1][3],
                                     "error" if len(run) >= 6 else "warn", key=f"repeat:{tool}:{reason}:{round(run[0][0], 1)}",
                                     tool=tool, reason=reason, count=len(run)))
        return out

    def unheard(self) -> list[dict]:
        """Lines the brain never heard (no brain running, or a blocked loop that never caught up)."""
        c = self.c
        heard = [(p["player"], _norm(p["text"]), p["heard"]) for ep in self.eps for p in ep.lines]
        out = []
        for d in c.chat:
            if d.get("type") != "chat" or d.get("self") or not _in(d["ts"], c.since, c.until):
                continue
            txt = _norm(d.get("text", ""))
            if any(pl == d.get("from") and h >= d["ts"] - 2 and (t == txt or txt in t) for pl, t, h in heard):
                continue
            if self.end_of_data - d["ts"] < UNHEARD_S:
                continue
            running = any(s["start"] - 5 <= d["ts"] <= s["end"] + 30 for s in c.sessions)
            out.append(_anom("stall", d["ts"], f'{d.get("from")}: "{short(d.get("text"), 80)}" was never heard by the brain'
                             + ("" if running else " (no brain session running)"), None, "error" if running else "warn",
                             key=f"unheard:{d['ts']}:{hashlib.md5(txt.encode()).hexdigest()[:6]}", wait_s=None, brain_running=running))
        return out

    def bridge_restarts(self) -> list[dict]:
        """The brain's own restart/lost rows, or a mod-log bridge start/stop while a brain command was unanswered."""
        c = self.c
        out = [_anom("bridge_restart_in_flight", d["ts"], f"{d['kind']}: {d.get('tool')} (id {d.get('id')})",
                     _episode_at(self.eps, d["ts"]), "error", key=f"{d['kind']}:{d.get('id')}", tool=d.get("tool"),
                     id=d.get("id"), source="brain")
               for d in c.brain if d.get("kind") in ("bridge_restart_detected", "bridge_command_lost")]
        file_end = {s["file"]: s["end"] for s in c.sessions}
        resolved = {i: min(x for x in (s["recv"], s["timeout"], file_end.get(s["file"], float("inf")) + 0.5) if x is not None)
                    for i, s in c.bridge.items() if s["tool"] not in ("ping", "capabilities")}
        for b in c.body:
            if b.get("event") not in ("client_bridge_started", "client_bridge_stopped"):
                continue
            T = b["ts"]
            inflight = [(i, c.bridge[i]["sent"], c.bridge[i]["tool"]) for i, end in resolved.items()
                        if c.bridge[i]["sent"] < T and end > T + 1 and T - c.bridge[i]["sent"] < 200]
            if inflight:
                names = ", ".join(f"{tool} (sent {_hms(ts)}" + (f", answered {_hms(c.bridge[i]['recv'])})" if c.bridge[i]["recv"]
                                                                  else ", never answered)") for i, ts, tool in inflight)
                out.append(_anom("bridge_restart_in_flight", T, f"body bridge {b['event'].split('_')[-1]} with {len(inflight)} "
                                 f"command(s) in flight: {names}", _episode_at(self.eps, inflight[0][1]), "error",
                                 key=f"bridge:{b['event']}:{T}", ids=[i for i, _, _ in inflight], source="mod"))
        return out


def detect(c: Corpus, eps: list[Episode], now: float | None = None, stall_s: float = STALL_S) -> list[dict]:
    return _Detect(c, eps, now, stall_s).run()


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


class _BusyIndex:
    """Bridge commands and model calls as spans sorted by start (bisect), for "what was the brain doing then"."""

    LOOKBACK_S = 600.0

    def __init__(self, c: Corpus):
        spans: list[tuple[float, float, str]] = []
        for s in c.bridge.values():
            if s["tool"] == "ping":
                continue
            if s["recv"] is not None or s["timeout"] is not None:
                done = min(x for x in (s["recv"], s["timeout"]) if x is not None)
                spans.append((s["sent"], done, f"{s['tool']} sent {_hms(s['sent'])}, " +
                              ("answered" if done == s["recv"] else "timed out") + f" {_hms(done)}"))
            else:
                spans.append((s["sent"], float("inf"), f"{s['tool']} sent {_hms(s['sent'])}, never answered"))
        prompt_at = None
        for d in c.brain:
            if d.get("kind") == "prompt":
                prompt_at = d["ts"]
            elif d.get("kind") == "llm_response" and prompt_at is not None:
                spans.append((prompt_at, d["ts"], f"model call {_hms(prompt_at)}-{_hms(d['ts'])}"))
                prompt_at = None
        self.spans = sorted(spans)
        self.starts = [s[0] for s in self.spans]

    def longest(self, t0: float, t1: float | None = None) -> str | None:
        """The span that overlapped [t0, t1] the longest."""
        t1 = t0 if t1 is None else t1
        best, best_overlap = None, 0.0
        for a, b, text in self.spans[bisect.bisect_left(self.starts, t0 - self.LOOKBACK_S):bisect.bisect_right(self.starts, t1)]:
            overlap = min(b, max(t1, t0 + 0.01)) - max(a, t0)
            if overlap > best_overlap:
                best, best_overlap = text, overlap
        return best


# ------------------------------------------------------------------ metrics
def pct(xs: list[float], p: float) -> float | None:
    if not xs:
        return None
    xs = sorted(xs)
    return round(xs[max(0, min(len(xs) - 1, round(p / 100 * (len(xs) - 1))))], 2)


def dist(xs: list[float]) -> dict:
    return {"n": len(xs), "p50": pct(xs, 50), "p90": pct(xs, 90), "max": round(max(xs), 2) if xs else None}


def _observed(c: Corpus) -> list[tuple[float, float]]:
    lo = c.since if c.since is not None else float("-inf")
    hi = c.until if c.until is not None else float("inf")
    return [(max(s["start"], lo), min(s["end"], hi)) for s in c.sessions if min(s["end"], hi) > max(s["start"], lo)]


def first_world_action(e: Episode) -> float | None:
    """When the first body action that changes something started (stop / say / remember don't count)."""
    return next((r["ts"] for r in e.ran if r["tool"] not in TRIVIAL_ACTIONS), None)


def first_action_of_passing_plan(e: Episode) -> float | None:
    """The first action of the first model plan whose world-changing actions all succeeded. A plan is the action set
    of one model call (its retries included: a task passes when its last attempt is ok). None when no plan passed."""
    plans: dict[int, dict[str, list[dict]]] = {}
    for r in e.ran:
        if r["tool"] in TRIVIAL_ACTIONS:
            continue
        idx = max((i for i, m in enumerate(e.model_calls) if m["end"] <= r["ts"] + 0.1), default=-1)
        plans.setdefault(idx, {}).setdefault(str(r.get("task_id") or r["ts"]), []).append(r)
    for idx in sorted(plans):
        tasks = plans[idx]
        if tasks and all(rs[-1]["ok"] for rs in tasks.values()):
            return min(rs[0]["ts"] for rs in tasks.values())
    return None


def exposure(c: Corpus, eps: list[Episode], obs: list[tuple[float, float]]) -> dict:
    """How much real play the window holds. An hour (UTC clock hour, observed part only) is active when a brain ran,
    at least one world-changing body action started and a real player chatted in it."""
    acts = [r["ts"] for e in eps for r in e.ran if r["tool"] not in TRIVIAL_ACTIONS]
    chat = [d["ts"] for d in c.chat if d.get("type") == "chat" and not d.get("self") and _in(d["ts"], c.since, c.until)
            and any(a - 5 <= d["ts"] <= b + 30 for a, b in obs)]
    hours = sum(b - a for a, b in obs) / 3600
    active = 0.0
    for a, b in obs:
        h = a - (a % 3600)
        while h < b:
            lo, hi = max(a, h), min(b, h + 3600)
            if any(lo <= t < hi for t in acts) and any(lo <= t < hi for t in chat):
                active += hi - lo
            h += 3600
    return {"active_hours": round(active / 3600, 3), "tool_calls_per_hour": round(len(acts) / hours, 2) if hours > 0 else None,
            "world_changing_tool_calls": len(acts), "player_chat_lines": len(chat), "sessions": len(obs)}


def metrics(c: Corpus, eps: list[Episode], anomalies: list[dict]) -> dict:
    chats = [e for e in eps if e.kind == "chat" and e.decision != "never decided"]
    answered = [e for e in chats if e.first_response is not None and not (e.decision or "").startswith("ignored")]
    calls = [m for e in eps for m in e.model_calls]
    by_comp: dict[str, list[float]] = {}
    for m in calls:
        if m["latency"] is not None:
            by_comp.setdefault(f"{m['component']}/{m['model']}", []).append(m["latency"])
    prompt_tok = [m["prompt_tok"] for m in calls if m["prompt_tok"]]
    ran = [r for e in eps for r in e.ran]
    tools: dict[str, dict] = {}
    for r in ran:
        t = tools.setdefault(r["tool"], {"n": 0, "failed": 0, "reasons": Counter(), "seconds": []})
        t["n"] += 1
        t["seconds"].append(r["end"] - r["ts"])
        if not r["ok"]:
            t["failed"] += 1
            t["reasons"][str(r["reason"])] += 1
    rtt: dict[str, list[float]] = {}
    for s in c.bridge.values():
        if s["recv"] is not None and _in(s["sent"], c.since, c.until):
            rtt.setdefault(s["tool"], []).append(s["recv"] - s["sent"])
    a_counts = Counter(a["kind"] for a in anomalies)
    return {
        "episodes": dict(Counter(e.kind for e in eps)),
        "chat_to_first_response_s": dist([e.first_response - e.start for e in answered]),
        "chat_to_first_action_s": dist([t - e.start for e in chats if (t := first_world_action(e)) is not None]),
        "chat_to_first_action_of_passing_plan_s": dist([t - e.start for e in chats if (t := first_action_of_passing_plan(e)) is not None]),
        "chat_heard_lag_s": dist([p["heard"] - p["said"] for e in chats for p in e.lines]),
        "model_latency_s": {k: dist(v) for k, v in sorted(by_comp.items())},
        "model_calls": len(calls),
        "model_calls_per_episode": round(len(calls) / max(1, len([e for e in eps if e.model_calls])), 2),
        "prompt_tokens": dist([float(x) for x in prompt_tok]),
        "prompt_cache_share": round(sum(m["cached_tok"] or 0 for m in calls) / sum(prompt_tok), 2) if prompt_tok else None,
        "state_reads_per_action": round(sum(e.state_reads for e in eps) / max(1, len(ran)), 2),
        "tools": {k: {"n": v["n"], "failed": v["failed"], "fail_rate": round(v["failed"] / v["n"], 2), "reasons": dict(v["reasons"]),
                      "p50_s": pct(v["seconds"], 50), "p90_s": pct(v["seconds"], 90)} for k, v in sorted(tools.items())},
        "failures_by_reason": dict(Counter(str(r["reason"]) for r in ran if not r["ok"]).most_common()),
        "retries": sum(1 for r in ran if (r.get("attempt") or 1) > 1),
        "talk_only_replies": len([e for e in answered if e.said and not e.ran]),
        "promises_without_action": a_counts.get("promise_without_action", 0),
        "bridge_rtt_s": {k: dist(v) for k, v in sorted(rtt.items()) if k in ("get_state", "ping", "look", "inventory", "say")},
        "anomalies": dict(a_counts),
    }


def goals_paths(d: Dirs, brain_logs: list[Path] | None = None, given: list[str] | None = None) -> list[Path]:
    """Board goals.json files: --goals, else beside an explicit brain log (its dir tree, ../state/worlds/*, or a flat
    "<name>__goals.json" twin), else the live store <state_dir>/worlds/*/goals.json."""
    if given:
        return [Path(x.strip()) for g in given for x in str(g).split(",") if x.strip() and Path(x.strip()).exists()]
    if brain_logs:
        out: list[Path] = []
        for b in brain_logs:
            twin = [b.with_name(b.name.split("__")[0] + "__goals.json")] if "__" in b.name else []
            for cand in twin + list(b.parent.rglob("goals.json")) + list(b.parent.parent.glob("state/worlds/*/goals.json")):
                if cand.exists() and cand not in out:
                    out.append(cand)
        return out
    return sorted((d.state / "worlds").glob("*/goals.json"))


def long_tasks(c: Corpus, goals: list[Path]) -> list[_tasks.TaskT]:
    """Board jobs (Director) in the window: per-step runs, gaps between steps, idle (tools/obs_tasks.py)."""
    tasks = _tasks.analyse(c.brain, _tasks.load_goals(goals))
    return [t for t in tasks if t.start is not None and _in(t.start, None if c.since is None else c.since - 1, c.until)]


def goal_metrics(c: Corpus, eps: list[Episode], anomalies: list[dict], m: dict,
                 tasks: list[_tasks.TaskT] | None = None) -> dict:
    """The stable JSON contract for tools/goal_check.py (schema dw_obs_metrics/1)."""
    obs = _observed(c)
    hours = round(sum(b - a for a, b in obs) / 3600, 3) if obs else 0.0
    per_h = (lambda n: round(n / hours, 3) if hours > 0 else None)  # noqa: E731
    in_window = [x for x in c.sessions if any(a <= x["end"] and x["start"] <= b for a, b in obs)]
    lives = {x["live"] for x in in_window}
    source = None if not in_window else "live" if lives == {True} else "dev" if lives <= {False, None} else "mixed"
    stalls30 = [a for a in anomalies if a["kind"] == "stall" and ((a["data"].get("wait_s") or 0) > 30 or a["data"].get("wait_s") is None)]
    crashes = sorted(w["ts"] for w in c.watchdog if w.get("event") in CRASH_EVENTS)
    longest = None
    if obs:
        cuts = [obs[0][0]] + [t for t in crashes if obs[0][0] <= t <= obs[-1][1]] + [obs[-1][1]]
        runs = [sum(max(0.0, min(b, y) - max(a, x)) for x, y in obs) for a, b in zip(cuts, cuts[1:])]
        longest = round(max(runs) / 3600, 3) if runs else None
    lat, pas = m["chat_to_first_action_s"], m["chat_to_first_action_of_passing_plan_s"]
    lt = _tasks.summary(tasks or [])  # tracked metric (not a GOAL gate yet): gaps between steps, idle share
    window_since = c.since if c.since is not None else (obs[0][0] if obs else None)
    window_until = c.until if c.until is not None else (obs[-1][1] if obs else None)
    count = Counter(a["kind"] for a in anomalies)
    return {
        "schema": "dw_obs_metrics/1",
        "generated_at": _iso(time.time()),
        "window": {"since": _iso(window_since), "until": _iso(min(window_until, time.time()) if window_until else None)},
        "source": source,
        "hours_observed": hours,
        "latency": {"chat_to_first_action_s": {"p50": lat["p50"], "p90": lat["p90"], "n": lat["n"]},
                    "chat_to_first_action_of_passing_plan_s": {"p50": pas["p50"], "p90": pas["p90"], "n": pas["n"]}},
        "exposure": exposure(c, eps, obs),
        "companion": {"filter": c.companion_sha, "shas": sorted({x["companion_sha"] for x in in_window if x["companion_sha"]}),
                      "sessions": [{"file": x["file"], "start": _iso(x["start"]), "end": _iso(x["end"]), "world": x["world"],
                                    "companion_sha": x["companion_sha"], "dirty": x["dirty"], "sha_source": x["sha_source"]}
                                   for x in in_window]},
        "anomalies_per_hour": {"stat_narration": per_h(count["stat_narration"]),
                               "talk_without_action": per_h(count["promise_without_action"]),
                               "stall_over_30s": per_h(len(stalls30))},
        "stability": {"longest_run_without_crash_h": longest, "crashes": len(crashes), "stalls_over_30s": len(stalls30)},
        "voice": {"score": None, "n": 0, "source": None},
        "deaths": deaths(c),
        **{k: lt[k] for k in ("task_gap_p50", "task_gap_p90", "idle_share", "longest_idle_s")},
        "long_tasks": lt,
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
           row("chat -> first body action", m["chat_to_first_action_s"]),
           row("chat -> passing plan's 1st act", m["chat_to_first_action_of_passing_plan_s"]),
           row("chat -> heard by brain", m["chat_heard_lag_s"])]
    out += [row("model " + k, v) for k, v in m["model_latency_s"].items()]
    pt = m["prompt_tokens"]
    out.append(f"model calls: {m['model_calls']} ({m['model_calls_per_episode']}/episode), prompt tokens p50={pt['p50']} "
               f"p90={pt['p90']}, cache share {m['prompt_cache_share']}, state reads per action {m['state_reads_per_action']}")
    out.append("tools:")
    for k, v in m["tools"].items():
        rs = ", ".join(f"{r} x{n}" for r, n in Counter(v["reasons"]).most_common())
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


USAGE_ATTRS = (("gen_ai.usage.input_tokens", "prompt_tok"), ("gen_ai.usage.output_tokens", "completion_tok"),
               ("gen_ai.usage.cache_read.input_tokens", "cached_tok"), ("gen_ai.usage.cache_creation.input_tokens", "cache_write_tok"),
               ("llm.token_count.prompt", "prompt_tok"), ("llm.token_count.completion", "completion_tok"),
               ("llm.token_count.prompt_details.cache_read", "cached_tok"))


def _step_span(s: Step) -> tuple[str, list[dict], int]:
    a = s.attrs
    if s.kind == "model":
        attrs = [_attr("gen_ai.operation.name", "chat"), _attr("gen_ai.provider.name", "anthropic"),
                 _attr("gen_ai.request.model", a.get("model") or ""), _attr("openinference.span.kind", "LLM"),
                 _attr("dw.step", str(a.get("step")))]
        attrs += [_attr(k, int(a[v])) for k, v in USAGE_ATTRS if a.get(v) is not None]
        attrs.append(_attr("output.value", json.dumps({"content": a.get("content"), "tool_calls": a.get("calls")},
                                                      ensure_ascii=False, default=str)))
        return f"chat {a.get('model')}", attrs, 1
    if s.kind in ("action", "read"):
        attrs = [_attr("gen_ai.operation.name", "execute_tool"), _attr("gen_ai.tool.name", a.get("tool") or ""),
                 _attr("openinference.span.kind", "TOOL"), _attr("tool.name", a.get("tool") or ""),
                 _attr("input.value", json.dumps(a.get("args"), default=str)), _attr("dw.read_only", s.kind == "read")]
        if a.get("reason"):
            attrs.append(_attr("error.type", a["reason"]))
        if a.get("detail"):
            attrs.append(_attr("output.value", a["detail"]))
        if a.get("attempt"):
            attrs.append(_attr("dw.attempt", int(a["attempt"])))
        return f"execute_tool {a.get('tool')}", attrs, 2 if a.get("ok") is False else 1
    return "say", [_attr("openinference.span.kind", "CHAIN"), _attr("dw.say.text", s.text.strip('"'))], 1


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
                      + ([_attr("dw.brain.episode_id", ep.eid)] if ep.eid else [])
                      + ([_attr("dw.latency.first_response_s", round(ep.first_response - ep.start, 3))] if ep.first_response else []),
                      "events": [{"timeUnixNano": _ns(parse_ts(a["ts"])), "name": f"anomaly.{a['kind']}",
                                  "attributes": [_attr("message", a["text"]), _attr("level", a["level"])]} for a in ep.anomalies],
                      "status": {"code": 2 if err else 1}})
        for i, s in enumerate(ep.steps):
            if s.kind not in ("model", "action", "read", "say"):
                continue
            sid = _hid(tid, i, n=16)
            name, attrs, status = _step_span(s)
            spans.append({"traceId": tid, "spanId": sid, "parentSpanId": root, "name": name, "kind": 3 if s.kind == "model" else 1,
                          "startTimeUnixNano": _ns(s.ts), "endTimeUnixNano": _ns(s.end or s.ts), "attributes": attrs,
                          "status": {"code": status}})
            body = s.attrs.get("body") if s.kind == "action" else None
            if body and body.get("start") is not None:
                spans.append({"traceId": tid, "spanId": _hid(sid, "body", n=16), "parentSpanId": sid, "name": f"body {s.attrs.get('tool')}",
                              "kind": 1, "startTimeUnixNano": _ns(body["start"]), "endTimeUnixNano": _ns(body.get("end") or body["start"]),
                              "attributes": [_attr("dw.body.reason", body.get("reason") or "")], "status": {"code": 1}})
    return {"resourceSpans": [{"resource": {"attributes": [_attr("service.name", "dragonwilds-companion")]},
                               "scopeSpans": [{"scope": {"name": "tools.obs", "version": "1"}, "spans": spans}]}]}


# ------------------------------------------------------------------ analysis entry points
def spend_anomalies(root: "Path | Dirs | None", since: float | None, until: float | None, now: float | None = None) -> list[dict]:
    """spend_warn (80 %) / spend_cap (100 %) of the daily cap, at the call that crossed it, for each UTC day touched."""
    d = Dirs.of(root)
    hi = until if until is not None else (now or time.time())
    lo = since if since is not None else hi - 86400
    out = []
    try:
        files = _spend._files(d.logs)  # listed once for every day
        for day in _spend.days_between(lo, hi)[-3:]:
            s = _spend.spend_day(day, d.logs, files=files)
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


def analyse(root: "Path | Dirs | None", since: float | None, until: float | None, now: float | None = None,
            companion_sha: str | None = None, brain_logs: list[Path] | None = None):
    d = Dirs.of(root)
    c = load(d, since, until, companion_sha=companion_sha, brain_logs=brain_logs)
    eps = build_episodes(c)
    anomalies = sorted(detect(c, eps, now=now) + spend_anomalies(d, since, until, now), key=lambda a: a["ts"])
    return c, eps, anomalies


def append_anomalies(path: Path, anomalies: list[dict]) -> list[dict]:
    seen = {d.get("key") for d in jsonl(path)} if path.exists() else set()
    new = [a for a in anomalies if a["key"] not in seen]
    for a in new:
        append_jsonl(path, a)
    return new


def follow_tick(root: "Path | Dirs | None", window: float, out: Path | None, shown: set[str], now: float | None = None) -> list[dict]:
    """One live re-scan of the last ``window`` seconds: the anomalies not seen before (appended to ``out``).
    A line still waiting counts as a stall once it is older than STALL_S (``now`` is the end of the data)."""
    now = time.time() if now is None else now
    _, _, anomalies = analyse(root, now - window, None, now=now)
    fresh = append_anomalies(out, anomalies) if out else anomalies
    fresh = [x for x in fresh if x["key"] not in shown]
    shown.update(x["key"] for x in fresh)
    return fresh


def _task_json(t: _tasks.TaskT) -> dict:
    return {"id": t.id, "text": t.text, "by": t.by, "status": t.status, "start": t.start, "end": t.end,
            "decisions": t.decisions, "lead_in": t.lead_in, "gaps": t.gaps, "idle": t.idle,
            "steps": [{"title": s.title, "step_id": s.step_id, "start": s.start, "end": s.end,
                       "seconds": round(s.end - s.start, 3) if s.end is not None else None, "runs": len(s.runs),
                       "outcome": s.outcome, "reason": s.reason,
                       "actions": [{k: x.get(k) for k in ("tool", "ok", "reason", "ts", "end")} for r in s.runs for x in r.actions]}
                      for s in t.steps]}


def _fmt_anom(a: dict) -> str:
    return f"{a['ts'][11:19]} {a['level']:<5} {a['kind']:<24} {('[' + a['episode'] + ']') if a['episode'] else '':<10} {a['text']}"


# ------------------------------------------------------------------ CLI
def _window(a, tz) -> tuple[float | None, float | None]:
    day = date.fromisoformat(a.date) if a.date else datetime.now(tz).date()
    since, until = parse_when(a.since, tz, day), parse_when(a.until, tz, day)
    if since is None and getattr(a, "last", None) and not getattr(a, "brain_log", None):
        since = time.time() - (24 if a.cmd == "task" else 6) * 3600
    return since, until


def _parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sp = sub.add_parser("spend", help="model API spend vs the daily cap (data/model_prices.json)")
    sp.add_argument("--today", action="store_true", help="this UTC day (the default)")
    sp.add_argument("--day", help="a UTC day YYYY-MM-DD")
    sp.add_argument("--json", action="store_true", help="the dw_obs_spend/1 object")
    sp.add_argument("--root", help=argparse.SUPPRESS)
    for name in ("episode", "metrics", "anomalies", "otel", "task"):
        p = sub.add_parser(name)
        p.add_argument("--since", help="HH:MM[:SS] (UTC unless --local), ISO, or 15m / 2h ago")
        p.add_argument("--until")
        p.add_argument("--date", help="day for bare HH:MM (YYYY-MM-DD)")
        p.add_argument("--local", action="store_true")
        p.add_argument("--root", help=argparse.SUPPRESS)
        p.add_argument("--now", type=float, help=argparse.SUPPRESS)
        p.add_argument("--brain-log", action="append", help="read these brain JSONL files instead of the live "
                       "brain-live-*.jsonl (path or glob, repeatable or comma-separated; e.g. a benchmark case's "
                       "logs/evals/<date>/<run>/work/<case>/brain.jsonl). Live chat/body/vitals files are then not read.")
        p.add_argument("--companion-sha", help="only brain sessions at these commits: comma-separated sha prefixes (any matches)")
        if name == "episode":
            p.add_argument("--last", type=int, help="only the last N episodes (default window: 6 h)")
            p.add_argument("--kind", help="comma list: chat,body,goal,director,ignored,ping")
            p.add_argument("-v", "--verbose", action="store_true", help="also body events and trigger notes")
        if name in ("metrics", "task"):
            p.add_argument("--goals", action="append", help="board goals.json file(s) (default: beside --brain-log, "
                           "else <state_dir>/worlds/*/goals.json)")
            p.add_argument("--json", action="store_true", help="metrics: dw_obs_metrics/1 (tools/goal_check.py); task: dw_obs_tasks/1")
        if name == "task":
            p.add_argument("--last", type=int, help="only the last N tasks (default window: 24 h)")
        if name == "anomalies":
            p.add_argument("--follow", action="store_true", help="live: re-scan every --interval s and print new ones")
            p.add_argument("--interval", type=float, default=5.0)
            p.add_argument("--window", type=float, default=900.0, help="follow mode: seconds of history re-scanned")
            p.add_argument("--out", default=None, help="anomaly file (default <log_dir>/anomalies.jsonl; '-' = don't write)")
            p.add_argument("--stall", type=float, default=STALL_S)
        if name == "otel":
            p.add_argument("--out", default=None, help="OTLP/JSON file (default <log_dir>/traces.otlp.json)")
            p.add_argument("--push", help="POST the OTLP/JSON to an OTLP/HTTP endpoint, e.g. http://127.0.0.1:6006/v1/traces")
    return ap


def _cmd_task(a, c: Corpus, d: Dirs, brain_logs, tz) -> int:
    tasks = long_tasks(c, goals_paths(d, brain_logs, a.goals))
    if a.last:
        tasks = tasks[-a.last:]
    sm = _tasks.summary(tasks)
    if a.json:
        print(json.dumps({"schema": "dw_obs_tasks/1", "summary": sm, "tasks": [_task_json(t) for t in tasks]},
                         ensure_ascii=False, default=str))
        return 0
    if not tasks:
        print("(no board tasks in this window; try --since HH:MM or --brain-log)")
    for t in tasks:
        print(redact(_tasks.render(t, lambda v: _hms(v, tz))))
        print()
    if tasks:
        print(f"all: {sm['tasks']} tasks, {sm['gaps']} gaps p50 {sm['task_gap_p50']} s p90 {sm['task_gap_p90']} s, "
              f"idle share {sm['idle_share']}, longest idle {sm['longest_idle_s']} s; gap time split {sm['gap_split_s']}")
    return 0


def _cmd_otel(a, eps: list[Episode], d: Dirs) -> int:
    doc = to_otlp(eps)
    out = Path(a.out) if a.out else d.logs / "traces.otlp.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
    print(f"{len(eps)} traces, {len(doc['resourceSpans'][0]['scopeSpans'][0]['spans'])} spans -> {out}")
    if a.push:
        req = urllib.request.Request(a.push, data=json.dumps(doc).encode(), headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                print(f"pushed: HTTP {r.status}")
        except Exception as exc:  # e.g. an endpoint that only takes protobuf: use the OTel Collector (see design note)
            print(f"push failed: {exc!r}")
            return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    a = _parser().parse_args(argv)
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    d = Dirs.of(a.root)
    if a.cmd == "spend":
        s = _spend.spend_day(date.fromisoformat(a.day) if a.day else datetime.now(timezone.utc).date(), d.logs)
        print(json.dumps(s, ensure_ascii=False) if a.json else _spend.render(s))
        return 0
    tz = datetime.now().astimezone().tzinfo if a.local else timezone.utc
    if a.cmd == "anomalies" and a.follow:
        out = d.logs / "anomalies.jsonl" if a.out in (None, "") else None if a.out == "-" else Path(a.out)
        print(f"following (window {a.window:.0f} s, every {a.interval:.0f} s) -> {out or 'stdout only'}", flush=True)
        shown: set[str] = set()
        while True:
            for x in follow_tick(d, a.window, out, shown):
                print(_fmt_anom(x), flush=True)
            time.sleep(a.interval)
    since, until = _window(a, tz)
    brain_logs = expand_logs(a.brain_log) if a.brain_log else None
    if brain_logs is not None and not brain_logs:
        print(f"no brain log matches {a.brain_log}")
        return 2
    c, eps, anomalies = analyse(d, since, until, now=a.now, companion_sha=a.companion_sha, brain_logs=brain_logs)
    if a.cmd == "task":
        return _cmd_task(a, c, d, brain_logs, tz)
    if a.cmd == "otel":
        return _cmd_otel(a, eps, d)
    if a.cmd == "episode":
        if a.kind:
            keep = {k.strip() for k in a.kind.split(",")}
            eps = [e for e in eps if e.kind in keep]
        eps = eps[-a.last:] if a.last else eps
        if not eps:
            print("(no episodes in this window; try --since HH:MM)")
        for i, ep in enumerate(eps, 1):
            print(redact(render_episode(ep, i, tz, a.verbose)))
            print()
    elif a.cmd == "metrics":
        m = metrics(c, eps, anomalies)
        if a.json:
            print(json.dumps(goal_metrics(c, eps, anomalies, m, long_tasks(c, goals_paths(d, brain_logs, a.goals))),
                             ensure_ascii=False, default=str))
        else:
            print(render_metrics(m))
    elif a.cmd == "anomalies":
        if a.stall != STALL_S:
            anomalies = detect(c, eps, now=a.now, stall_s=a.stall)
        out = d.logs / "anomalies.jsonl" if a.out is None else None if a.out == "-" else Path(a.out)
        n = len(append_anomalies(out, anomalies)) if out else 0
        for x in anomalies:
            print(_fmt_anom(x))
        print(f"({len(anomalies)} anomalies" + (f"; {n} new written to {out}" if out else "") + ")")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Per-run report of one live session: request latency, idle gaps and pickup fumbles, correlated
across the brain log, the client mod (UE4SS.log, logs/client/mod_*.jsonl, client_io/events) and the
dedicated server log.  Stdlib only; reuses tools/timeline.py's readers and helpers.

    .venv\\Scripts\\python.exe -m tools.session_report logs\\brain-live-20261101-115554-7128.jsonl
    .venv\\Scripts\\python.exe -m tools.session_report <brain log> --why 7728149ec5a8   # exact model context

Writes logs/reports/session-<log stem>.md (short summary), .steps.md (per-request step timelines, every
pickup) and .tables.jsonl (one row per request, tool call, model call, body action, idle gap and pickup; DuckDB:
    SELECT * FROM read_ndjson('logs/reports/*.tables.jsonl', union_by_name=true) WHERE "table"='gap').

Correlation chain (reconstructed, docs/research/2026-11-01-telemetry.md says what to stamp instead):
  chat_heard.episode_id -> llm_response (same episode) -> tool_call -> next bridge_send of the same tool
  (its msg.id is the BODY ACTION ID) -> mod client_action_start/end, trips.jsonl id, gather.jsonl
  task_id, late bridge_unmatched/event_dropped results -> UE4SS [DWClient] lines inside the action's
  time window (the arbiter runs one body skill at a time).

Definitions:
  request       an episode started by a player chat line; `note:` lines are Luis's annotations.
  done_at       the later of the episode's last brain row and the end of the body actions it started.
  productive    the body travelled (move sample spd >= 1 m/s, or a trip averaging >= 0.8 m/s over
                >= 2 m) or something changed in the world (item picked, eaten, crafted, built, a hit).
  idle gap      > IDLE_MIN_S of no productive evidence while a request is open; the cause is what was
                in flight (model call, state read, a body skill and its planner/stuck/aim lines, nothing).
"""
from __future__ import annotations

import argparse
import bisect
import json
import math
import os
import re
import statistics
import sys
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

from tools.timeline import ROOT, _pick_by_start, jsonl, parse_ts, redact, short

UE4SS_LOG = Path(os.environ.get(
    "DW_CLIENT_UE4SS_LOG",
    r"C:\Program Files (x86)\Steam\steamapps\common\RSDragonwilds\RSDragonwilds\Binaries\Win64\ue4ss\UE4SS.log"))
SERVER_LOG = Path(os.environ.get("DW_SERVER_LOG", r"C:\GameServers\Dragonwilds\RSDragonwilds\Saved\Logs\RSDragonwilds.log"))
IDLE_MIN_S = 5.0
BIN = 0.25  # seconds per bin of the activity grid
READ_TOOLS = {"get_state", "look", "inspect", "inventory", "spells", "buildables", "recipes", "craft_plan", "lodestones",
              "stations", "world_info", "combat_brief", "capabilities", "ping", "me", "census", "quests", "skills_status"}
PICKUP_TOOLS = {"interact", "gather", "fetch", "collect_water", "take", "recover_grave"}


def hms(ts: float | None) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%H:%M:%S") if ts else "--:--:--"


def secs(v: float | None, nd: int = 1) -> str:
    return "-" if v is None else f"{v:.{nd}f} s"


def med(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def esc(s) -> str:
    return str(s).replace("|", "\\|").replace("\n", " ")


# ------------------------------------------------------------------ records
@dataclass
class LLMCall:
    ts: float
    end: float | None
    component: str
    step: str
    episode: str | None
    line: int                      # 1-based line of the prompt row in the brain log (exact context)
    prompt_tok: int | None = None
    completion_tok: int | None = None
    cached_tok: int | None = None
    calls: list = field(default_factory=list)
    content: str | None = None
    finish: str | None = None

    @property
    def latency(self):
        return None if self.end is None else self.end - self.ts


@dataclass
class BodyAction:
    id: str
    kind: str
    start: float
    end: float | None = None
    ok: bool | None = None
    reason: str | None = None
    by: str | None = None
    data: dict = field(default_factory=dict)
    source: str = ""


@dataclass
class ToolCall:
    ts: float
    tool: str
    args: dict
    episode: str | None
    task_id: str | None
    read_only: bool
    line: int
    bridge_id: str | None = None                       # the first body leg
    legs: list = field(default_factory=list)          # every bridge id sent for this call (re-sends after resolving)
    result_ts: float | None = None
    ok: bool | None = None
    reason: str | None = None
    data: dict = field(default_factory=dict)
    llm: LLMCall | None = None
    body: BodyAction | None = None

    @property
    def latency(self):
        return None if self.result_ts is None else self.result_ts - self.ts


@dataclass
class Episode:
    id: str
    kind: str
    t0: float
    lines: list = field(default_factory=list)       # (ts, player, text, is_note)
    says: list = field(default_factory=list)        # (ts, text, verified)
    tools: list = field(default_factory=list)
    llm: list = field(default_factory=list)
    last_ts: float = 0.0
    stops: list = field(default_factory=list)       # (ts, why)
    waits_cut: list = field(default_factory=list)   # (ts, tool, why)
    notes: list = field(default_factory=list)       # controller_note / reply_silent / budget rows

    @property
    def is_note(self) -> bool:
        return bool(self.lines) and all(n for *_, n in self.lines)


@dataclass
class UELine:
    ts: float
    text: str


# ------------------------------------------------------------------ brain log
class Brain:
    def __init__(self, path: Path):
        self.path = path
        self.episodes: dict[str, Episode] = {}
        self.llm: list[LLMCall] = []
        self.tools: list[ToolCall] = []
        self.sends: dict[str, dict] = {}            # bridge id -> {ts, tool, episode, line}
        self.results: dict[str, dict] = {}          # bridge id -> {ts, ok, reason, data, how}
        self.positions: list[tuple[float, tuple, str]] = []
        self.player_dist: list[tuple[float, str, float]] = []
        self.reads: list[tuple[float, float, str]] = []   # (start, end, tool) bridge round trips of read tools
        self.says: list[tuple[float, float, str]] = []
        self.first = self.last = None
        self.session: dict = {}
        self._parse()

    def _ep(self, eid: str | None, ts: float) -> Episode | None:
        if not eid:
            return None
        ep = self.episodes.get(eid)
        if ep is None:
            ep = self.episodes[eid] = Episode(eid, eid.split("-")[0], ts)
        ep.last_ts = max(ep.last_ts, ts)
        return ep

    def _parse(self) -> None:
        open_prompts: dict[tuple, list[LLMCall]] = defaultdict(list)
        pending_sends: dict[str, list[ToolCall]] = defaultdict(list)   # tool -> tool calls waiting for their send
        by_task: dict[str, ToolCall] = {}
        open_reads: dict[str, ToolCall] = {}
        last_resp: dict[str, LLMCall] = {}
        say_open: list[float] = []
        with open(self.path, encoding="utf-8", errors="replace") as f:
            for n, raw in enumerate(f, 1):
                if not raw.strip():
                    continue
                try:
                    d = json.loads(raw)
                except ValueError:
                    continue
                ts, k, eid = d.get("ts"), d.get("kind"), d.get("episode_id")
                if not isinstance(ts, (int, float)):
                    continue
                self.first = ts if self.first is None else self.first
                self.last = ts
                ep = self._ep(eid, ts)
                if k == "session_start":
                    self.session = {x: d.get(x) for x in ("player", "name", "controller_model", "planner_model", "body")}
                elif k == "event":
                    e = d.get("event") or {}
                    if e.get("type") == "chat_heard" and ep:
                        txt = str(e.get("text", ""))
                        ep.lines.append((ts, e.get("player"), txt, txt.strip().lower().startswith("note")))
                        ep.t0 = min(ep.t0, ts)
                elif k == "prompt":
                    c = LLMCall(ts, None, str(d.get("component")), str(d.get("step")), eid, n)
                    open_prompts[(c.component, eid)].append(c)
                    self.llm.append(c)
                    if ep:
                        ep.llm.append(c)
                elif k == "llm_response":
                    q = open_prompts.get((str(d.get("component")), eid)) or []
                    c = q.pop(0) if q else None
                    if c is None:
                        continue
                    u = d.get("usage") or {}
                    c.end, c.content, c.finish = ts, d.get("content"), d.get("finish_reason")
                    c.prompt_tok, c.completion_tok, c.cached_tok = u.get("prompt"), u.get("completion"), u.get("cached")
                    c.calls = [(x.get("name"), x.get("arguments")) for x in d.get("tool_calls") or []]
                    last_resp[eid or ""] = c
                elif k == "tool_call":
                    t = ToolCall(ts, str(d.get("tool")), d.get("args") or {}, eid, d.get("task_id"), bool(d.get("read_only")), n)
                    lr = last_resp.get(eid or "")
                    if lr and any(name == t.tool for name, _ in lr.calls):
                        t.llm = lr
                    self.tools.append(t)
                    pending_sends[t.tool].append(t)
                    if t.task_id:
                        by_task[t.task_id] = t
                    if ep:
                        ep.tools.append(t)
                elif k == "tool_result":
                    r = d.get("result") or {}
                    t = by_task.get(d.get("task_id")) if d.get("task_id") else open_reads.pop(str(d.get("tool")), None)
                    if t is None or t.result_ts is not None:
                        continue
                    t.result_ts, t.ok, t.reason = ts, r.get("ok"), r.get("reason")
                    t.data = _lite(r.get("data") or {})
                elif k == "bridge_send":
                    m = d.get("msg") or {}
                    tool, bid = str(m.get("tool")), m.get("id")
                    self.sends[bid] = {"ts": ts, "tool": tool, "episode": eid, "line": n}
                    q = pending_sends.get(tool)
                    if q:
                        t = q.pop(0)
                        t.bridge_id = bid
                        t.legs.append(bid)
                        if t.read_only:
                            open_reads[tool] = t
                    else:  # a re-send by the bridge client (e.g. go_to after resolving a place name) joins its call
                        t = next((x for x in reversed(self.tools[-20:]) if x.tool == tool and not x.read_only
                                  and x.result_ts is None and x.legs), None)
                        if t:
                            t.legs.append(bid)
                    if tool == "say":
                        say_open.append(ts)
                elif k in ("bridge_recv", "bridge_unmatched"):
                    m = d.get("msg") or {}
                    bid = m.get("id")
                    s = self.sends.get(bid)
                    data = m.get("data") if isinstance(m.get("data"), dict) else {}
                    if s and s["tool"] in READ_TOOLS:
                        self.reads.append((s["ts"], ts, s["tool"]))
                    if s and s["tool"] == "get_state":
                        p = data.get("position")
                        if isinstance(p, list) and len(p) >= 3:
                            self.positions.append((ts, tuple(float(x) for x in p[:3]), "get_state"))
                        for pl in data.get("players") or []:
                            if isinstance(pl, dict) and pl.get("distance") is not None:
                                self.player_dist.append((ts, str(pl.get("name")), float(pl["distance"])))
                    if bid and (bid not in self.results or k == "bridge_unmatched"):
                        self.results[bid] = {"ts": ts, "ok": m.get("ok"), "reason": m.get("reason"), "data": _lite(data), "how": k}
                elif k == "event_dropped":
                    e = d.get("event") or {}
                    if e.get("type") in ("task_done", "task_failed") and e.get("task_id"):
                        bid = e["task_id"]
                        if bid not in self.results:
                            self.results[bid] = {"ts": ts, "ok": e["type"] == "task_done", "reason": e.get("reason"),
                                                 "data": _lite(e.get("data") or {}), "how": "event_dropped"}
                elif k == "say" and ep:
                    ep.says.append((ts, str(d.get("text", "")), None))
                elif k == "say_result":
                    if ep and ep.says and ep.says[-1][2] is None:
                        a, txt, _ = ep.says[-1]
                        ep.says[-1] = (ts, txt, bool(d.get("ok") and (d.get("data") or {}).get("verified")))
                    if say_open:
                        self.says.append((say_open.pop(0), ts, str(d.get("text") or (d.get("data") or {}).get("text") or "")))
                elif k == "chain_stopped" and ep:
                    ep.stops.append((ts, d.get("why")))
                elif k == "bridge_wait_interrupted" and ep:
                    ep.waits_cut.append((ts, d.get("tool"), d.get("why")))
                elif k in ("controller_note", "reply_silent", "controller_budget_exhausted", "no_progress") and ep:
                    ep.notes.append((ts, k, short(d.get("text") or d.get("args") or d.get("calls"), 120)))


def _lite(data: dict) -> dict:
    """Keep the small, telling fields of a result (drop census/state payloads)."""
    keep = {}
    for k, v in data.items():
        if k in ("things", "nearby_resources", "nearby_entities", "inventory", "inventory_items", "stations", "recipes",
                 "structures", "skills", "spells", "places", "manifest"):
            continue
        s = json.dumps(v, default=str)
        keep[k] = v if len(s) <= 600 else s[:600] + "..."
    return keep


# ------------------------------------------------------------------ client and server sources
_UE_RX = re.compile(r"^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)(\.\d+)?\] \[Lua\] \[DWClient\] (.*)$")


def read_ue4ss(path: Path, since: float, until: float, tz: timezone | None) -> list[UELine]:
    out = []
    try:
        f = open(path, encoding="utf-8-sig", errors="replace")
    except OSError:
        return out
    with f:
        for line in f:
            m = _UE_RX.match(line.rstrip("\n"))
            if not m:
                continue
            naive = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
            ts = (naive.replace(tzinfo=tz) if tz else naive.astimezone()).timestamp() + float(m.group(2) or 0)
            if since <= ts <= until:
                text = m.group(3).strip()
                if not text.startswith("ran wd_boot_probe"):
                    out.append(UELine(ts, redact(text)))
    return out


def read_mod_actions(root: Path, since: float, until: float) -> dict[str, BodyAction]:
    acts: dict[str, BodyAction] = {}
    for f in _pick_by_start(list((root / "logs" / "client").glob("mod_*.jsonl")), r"(\d{8})T(\d{6})Z", True, since, until):
        for d in jsonl(f):
            ts = parse_ts(d.get("ts"))
            if ts is None or not (since - 120 <= ts <= until):
                continue
            data = d.get("data") or {}
            bid = data.get("id")
            if d.get("event") == "client_action_start" and bid:
                if ts < since - 1:  # started by an earlier brain process
                    continue
                acts[bid] = BodyAction(bid, str(data.get("kind")), ts, source="mod")
            elif d.get("event") == "client_action_end" and bid in acts:
                a = acts[bid]
                a.end, a.ok, a.reason = ts, data.get("ok"), data.get("reason")
    return acts


def read_events(path: Path, since: float, until: float) -> list[dict]:
    out = []
    for d in jsonl(path):
        ts = parse_ts(d.get("ts") or d.get("iso"))
        if ts is not None and since <= ts <= until:
            d["_ts"] = ts
            out.append(d)
    return out


_SRV_TS = re.compile(r"^\[(\d{4})\.(\d\d)\.(\d\d)-(\d\d)\.(\d\d)\.(\d\d):(\d{3})\]\[\s*\d+\]([A-Za-z]+): (.*)$")


SERVER_CHARS: dict[str, str] = {}  # BP_PlayerCharacter_C_<n> -> character name, from the server's join lines


def read_server(path: Path, since: float, until: float) -> list[tuple[float, str, str]]:
    """(ts, category, text) from the dedicated server log (UTC stamps); only the window. Also fills SERVER_CHARS
    from 'PlayerChar entered world [... Character Name[X] ...]' followed by 'Character [id] possessed'."""
    out = []
    lo = datetime.fromtimestamp(since, timezone.utc).strftime("[%Y.%m.%d-%H")
    pending_name = None
    try:
        f = open(path, encoding="utf-8-sig", errors="replace")
    except OSError:
        return out
    with f:
        for line in f:
            if "PlayerChar entered world" in line:
                m = re.search(r"Character Name\[([^\]]+)\]", line)
                pending_name = m.group(1) if m else None
            elif pending_name and "possessed by controller" in line:
                m = re.search(r"Character \[(\S+?)\] possessed", line)
                if m:
                    SERVER_CHARS[m.group(1)] = pending_name
                pending_name = None
            if not line.startswith("[2"):
                continue
            if line[:14] < lo:
                continue
            m = _SRV_TS.match(line.rstrip("\n"))
            if not m:
                continue
            y, mo, dd, h, mi, s, ms, cat, rest = m.groups()
            ts = datetime(int(y), int(mo), int(dd), int(h), int(mi), int(s), int(ms) * 1000, tzinfo=timezone.utc).timestamp()
            if since <= ts <= until:
                out.append((ts, cat, rest))
    return out


# ------------------------------------------------------------------ UE4SS line classifiers
RX = {
    "speed": re.compile(r"^move: (go_to|follow) d=(\d+)cm src=(\w+).*?spd=(\d+)"),
    "trip": re.compile(r"^move: trip: (Walked|Moved) (\d+) m in (\d+) s \(([\d.]+) m/s\) from \[([-\d.,]+)\] to \[([-\d.,]+)\]"),
    "cm": re.compile(r"(?:me=|at )\((-?\d+),(-?\d+),(-?\d+)\)"),
    "stand": re.compile(r"^move: local path .*stand=([\d.]+)s"),
    "lplan": re.compile(r"^move: local plan #(\d+) \((\w+)\)"),
    "lfail": re.compile(r"^move: local plan failed: (\w+)"),
    "stuck": re.compile(r"^move: (stuck|self-stuck|no movement)"),
    "arb": re.compile(r"^arbiter: (granted|released|suspended|resumed) (\S+) \((.*)\)"),
    "gphase": re.compile(r"^gather: phase (\w+)"),
    "picked": re.compile(r"^gather: (\S+) picked"),
    "gaveup": re.compile(r"^gather: target (\S+) given up: (.*)"),
    "gend": re.compile(r"^gather: end ok=(\w+) reason=(\S+) gained=(\d+)/(\d+)"),
    "press": re.compile(r"^inventory: inject IA_Interact"),
    "use": re.compile(r"^inventory: use:"),
    "craft": re.compile(r"^crafting: .*(SendCraftRequest|ToggleProcessingStationStarted)"),
    "fight": re.compile(r"^combat: fight end ok=(\w+).*hits=(\d+)"),
    "cphase": re.compile(r"^combat: phase (\w+)"),
    "jumpfail": re.compile(r"^move: (double jump: first jump not airborne|jump landing missed)"),
    "water": re.compile(r"^move: entered water"),
}
PROGRESS_RX = ("picked", "use", "craft", "fight")


def ue_kind(text: str) -> tuple[str, re.Match] | tuple[None, None]:
    for k, rx in RX.items():
        if k == "cm":  # coordinates ride on many kinds of line: ue_pos() reads them separately
            continue
        m = rx.match(text)
        if m:
            return k, m
    return None, None


def ue_pos(text: str) -> tuple | None:
    """Body position in metres from a UE4SS line: cm 'me=(x,y,z)' / 'at (x,y,z)', or a trip's end point."""
    m = RX["trip"].match(text)
    if m:
        return tuple(float(v) for v in m.group(6).split(","))
    if text.startswith(("move: stuck", "move: local plan #", "move: entered water")):
        m = RX["cm"].search(text)
        if m:
            return tuple(int(v) / 100 for v in m.groups())
    return None


def pattern(text: str) -> str:
    """A line with its numbers and ids folded, for 'what was it doing' summaries."""
    t = re.sub(r"\b(BP|DAA|ATK|ITEM|RECIPE)_[A-Za-z0-9_]+", r"\1_*", text)
    t = re.sub(r"[-\d.]+", "N", t)
    return t[:90]


# ------------------------------------------------------------------ the report
class Session:
    def __init__(self, brain_path: Path, root: Path = ROOT, ue4ss: Path = UE4SS_LOG, server: Path = SERVER_LOG,
                 ue_tz: timezone | None = None, tail_s: float = 120.0):
        self.brain = Brain(brain_path)
        b = self.brain
        self.since, self.until = b.first, b.last + tail_s
        self.ue = read_ue4ss(ue4ss, self.since - 5, self.until, ue_tz)
        self.ue_ts = [x.ts for x in self.ue]
        self.ue4ss_path, self.server_path = ue4ss, server
        self.mod = read_mod_actions(root, self.since, self.until)
        ev = root / "client_io" / "events"
        self.trips = read_events(ev / "trips.jsonl", self.since - 120, self.until)
        self.gather_ev = read_events(ev / "gather.jsonl", self.since - 5, self.until)
        self.vitals = read_events(ev / "vitals.jsonl", self.since - 5, self.until)
        self.server = read_server(server, self.since, self.until)
        self.actions = self._actions()
        self._link()
        self.requests = sorted((e for e in b.episodes.values() if e.kind == "chat" and e.lines), key=lambda e: e.t0)
        self.self_eps = sorted((e for e in b.episodes.values() if e.kind != "chat"), key=lambda e: e.t0)
        self.done = {e.id: self._done_at(e) for e in b.episodes.values()}
        self.grid = self._grid()
        self.gaps = self._gaps()
        self.pickups = self._pickups()

    # ---- correlation
    def _actions(self) -> dict[str, BodyAction]:
        """Body actions by bridge id. The mod file stamps whole seconds; the brain's send and its receipt of the
        body's one final result (bridge_recv, or bridge_unmatched once the brain stopped waiting) are ms-exact,
        so they win when present. ok/reason come from the body's own result."""
        acts = dict(self.mod)
        for bid, s in self.brain.sends.items():
            if s["tool"] in READ_TOOLS or s["tool"] == "say":
                continue
            a = acts.get(bid)
            if a is None:
                a = acts[bid] = BodyAction(bid, s["tool"], s["ts"], source="brain")
            a.start = s["ts"]
            r = self.brain.results.get(bid)
            if r:
                a.end, a.ok, a.reason = r["ts"], r["ok"], r.get("reason")
                a.data = r.get("data") or {}
                a.by = a.data.get("by")
        for a in acts.values():
            if a.source == "mod" and a.end is not None and a.id not in self.brain.results:
                a.end += 0.5  # mid-second
        return acts

    def _link(self) -> None:
        """A tool call's body is its last leg (the final word); every leg stays in t.legs."""
        for t in self.brain.tools:
            bodies = [self.actions[b] for b in t.legs if b in self.actions]
            if bodies:
                t.body = bodies[-1]

    def _done_at(self, ep: Episode) -> float:
        end = ep.last_ts
        for t in ep.tools:
            if t.body and t.body.end:
                end = max(end, t.body.end)
            elif t.body:  # still running at the end of the logs
                end = max(end, self.until)
        return end

    def ue_between(self, a: float, b: float) -> list[UELine]:
        i, j = bisect.bisect_left(self.ue_ts, a), bisect.bisect_right(self.ue_ts, b)
        return self.ue[i:j]

    # ---- activity grid: per BIN, productive evidence + what was in flight
    def _grid(self) -> dict:
        n = int(math.ceil((self.until - self.since) / BIN)) + 1
        prod = [False] * n
        moving = [False] * n
        infl: dict[str, list[bool]] = defaultdict(lambda: [False] * n)

        def idx(t):
            return max(0, min(n - 1, int((t - self.since) / BIN)))

        def mark(arr, a, b):
            for i in range(idx(a), idx(b) + 1):
                arr[i] = True

        speeds = []
        arb_open: dict[str, float] = {}
        for x in self.ue:
            k, m = ue_kind(x.text)
            if k == "speed":
                speeds.append((x.ts, int(m.group(4))))
            elif k == "trip":
                walked, s, v = float(m.group(2)), float(m.group(3)), float(m.group(4))
                if walked >= 2 and v >= 0.8:
                    t0 = x.ts - max(s, walked / max(v, 0.1))
                    if not any(t0 <= st <= x.ts for st, _ in speeds[-12:]):
                        mark(moving, t0, x.ts)
            elif k in PROGRESS_RX:
                if k == "fight" and m.group(2) == "0":
                    continue
                mark(prod, x.ts - 1, x.ts + 1)
            elif k == "cphase" and m.group(1) in ("approach", "engage", "defend", "disengage", "chase"):
                mark(prod, x.ts - 1, x.ts + 2)
            elif k == "stand":
                mark(infl["planner standing"], x.ts - float(m.group(1)), x.ts)
            elif k == "stuck":
                mark(infl["stuck"], x.ts - 2, x.ts)
            elif k == "gphase" and m.group(1) in ("aim", "pick"):
                mark(infl["aiming"], x.ts - 0.5, x.ts + 2)
            elif k == "gaveup":
                mark(infl["pickup miss"], x.ts - 8, x.ts)
            elif k == "arb":
                verb, owner = m.group(1), m.group(2)
                if verb in ("granted", "resumed"):
                    arb_open[owner] = x.ts
                elif verb in ("released", "suspended") and owner in arb_open:
                    mark(infl["body " + owner], arb_open.pop(owner), x.ts)
        for owner, t0 in arb_open.items():
            mark(infl["body " + owner], t0, self.until)
        speeds.sort()
        for i, (t, spd) in enumerate(speeds):
            nxt = speeds[i + 1][0] if i + 1 < len(speeds) else t + 2.2
            if spd >= 100:
                mark(moving, t, min(nxt, t + 2.5))
        # body actions from the bridge (covers skills whose arbiter line is missing, e.g. go_to grants)
        for a in self.actions.values():
            if a.end:
                mark(infl["action " + a.kind], a.start, a.end)
        for c in self.brain.llm:
            if c.end:
                mark(infl["model call"], c.ts, c.end)
        for a, b, tool in self.brain.reads:
            mark(infl["state read"], a, b)
        for a, b, _ in self.brain.says:
            mark(infl["typing chat"], a, b)
        for g in self.gather_ev:
            if g.get("type") == "gather_progress":
                mark(prod, g["_ts"] - 0.5, g["_ts"] + 1.5)
        for t in self.brain.tools:
            if t.ok and t.result_ts and (t.data.get("gained") or t.tool in ("consume", "build", "craft", "teleport", "cast", "drop")):
                mark(prod, t.result_ts - 1, t.result_ts + 1)
        # position samples (get_state + UE4SS coordinates): coarse motion where no move samples exist
        pos = list(self.brain.positions)
        for x in self.ue:
            p = ue_pos(x.text)
            if p:
                pos.append((x.ts, p, "ue4ss"))
        pos.sort()
        self.pos_samples = pos
        covered = [False] * n
        for t, _ in speeds:
            mark(covered, t - 1, t + 2.5)
        for (t1, p1, _), (t2, p2, _) in zip(pos, pos[1:]):
            dt = t2 - t1
            if 0 < dt <= 15 and math.dist(p1[:2], p2[:2]) >= 2 and math.dist(p1[:2], p2[:2]) / dt >= 0.5:
                if not any(covered[i] for i in range(idx(t1), idx(t2) + 1)):
                    mark(moving, t1, t2)
        for i in range(n):
            prod[i] = prod[i] or moving[i]
        return {"n": n, "prod": prod, "moving": moving, "infl": dict(infl), "idx": idx}

    def open_windows(self) -> list[tuple[float, float, str]]:
        out = []
        for e in self.requests:
            if not e.is_note:
                out.append((e.t0, self.done[e.id], e.id))
        return out

    def _gaps(self) -> list[dict]:
        g, idx = self.grid, self.grid["idx"]
        n = g["n"]
        open_ = [None] * n
        for a, b, eid in self.open_windows():
            for i in range(idx(a), idx(b) + 1):
                open_[i] = eid  # the newest open request owns the bin
        t0 = {eid: a for a, _, eid in self.open_windows()}
        gaps, i = [], 0
        while i < n:
            if open_[i] and not g["prod"][i]:
                j = i
                while j + 1 < n and open_[j + 1] and not g["prod"][j + 1]:
                    j += 1
                a, b = max(self.since + i * BIN, t0[open_[i]]), self.since + (j + 1) * BIN
                if b - a > IDLE_MIN_S:
                    gaps.append(self._explain(a, b, open_[i], i, j))
                i = j + 1
            else:
                i += 1
        return gaps

    def _explain(self, a: float, b: float, eid: str, i: int, j: int) -> dict:
        infl = self.grid["infl"]
        share = {k: sum(v[i:j + 1]) * BIN for k, v in infl.items() if any(v[i:j + 1])}
        nothing = sum(1 for x in range(i, j + 1) if not any(v[x] for v in infl.values())) * BIN
        if nothing:
            share["nothing in flight"] = nothing
        lines = self.ue_between(a, b)
        pats = Counter(pattern(x.text) for x in lines if not x.text.startswith(("combat: ai action", "chat say")))
        brain_rows = []
        ep = self.brain.episodes.get(eid)
        for e in self.brain.episodes.values():
            for ts, why in e.stops:
                if a <= ts <= b:
                    brain_rows.append(f"chain stopped ({why})")
            for ts, tool, why in e.waits_cut:
                if a <= ts <= b:
                    brain_rows.append(f"stopped waiting for {tool} ({why})")
            for ts, k, txt in e.notes:
                if a <= ts <= b:
                    brain_rows.append(f"{k}: {txt}")
        says = [txt for ts, txt, _ in sum((e.says for e in self.brain.episodes.values()), []) if a <= ts <= b]
        heard = [txt for e in self.requests for ts, _, txt, _ in e.lines if a <= ts <= b]
        cause = self._cause(share, pats, b - a)
        return {"start": a, "end": b, "s": round(b - a, 1), "request": eid,
                "request_text": short(" / ".join(t for *_, t, n in (ep.lines if ep else []) if not n), 90),
                "cause": cause, "cause_kind": re.sub(r"\s*\(.*", "", cause).split(",")[0].strip(), "in_flight_s": {k: round(v, 1) for k, v in sorted(share.items(), key=lambda kv: -kv[1])},
                "evidence": [f"{p} (x{c})" if c > 1 else p for p, c in pats.most_common(5)],
                "brain": brain_rows[:4], "said": [short(s, 80) for s in says[:3]], "player_said": [short(h, 80) for h in heard[:3]]}

    @staticmethod
    def _cause(share: dict, pats: Counter, dur: float) -> str:
        def s(k):
            return share.get(k, 0.0)
        body = {k: v for k, v in share.items() if k.startswith(("body ", "action "))}
        top_body = max(body, key=body.get) if body else None
        ptxt = " ".join(pats)
        failed = Counter()
        for p, c in pats.items():
            m = re.match(r"move: (?:local plan )?failed:? (\w+)", p)
            if m:
                failed[m.group(1)] += c
        if s("model call") >= 0.5 * dur:
            return f"waiting on the model ({s('model call'):.0f} s of model calls)"
        if s("pickup miss") >= 0.3 * dur:
            return "pickup misses: aimed at a target the game never highlighted, then gave up"
        if failed:
            why, n = failed.most_common(1)[0]
            what = "local planner found no way" if why in ("unreachable_in_window", "no_progress_possible") else "move failed"
            return f"{what}: {why} (x{n}), then re-planned or re-issued"
        if s("planner standing") >= 0.3 * dur:
            return f"stood still while the local planner computed a path ({s('planner standing'):.0f} s)"
        if s("pickup miss") >= 1 or "given up" in ptxt:
            return "pickup misses: aimed at a target the game never highlighted, then gave up"
        if top_body and "interact" in top_body and body[top_body] >= 0.4 * dur:
            return "interact: re-aiming between spots, refused the highlighted item (not_interactable)"
        if s("stuck") >= 1 or "stuck" in ptxt or "no movement" in ptxt:
            return f"stuck: {(top_body or 'move').split(' ', 1)[-1]} not progressing (stuck/unstuck lines)"
        if s("aiming") >= 1:
            return "aligning on a pickup target (aim/pick phases, no pick)"
        if top_body and body[top_body] >= 0.5 * dur:
            return f"{top_body.split(' ', 1)[1]} running without travel or item progress"
        if s("model call") + s("state read") >= 0.5 * dur:
            return f"brain thinking (model {s('model call'):.0f} s + state reads {s('state read'):.0f} s)"
        if s("nothing in flight") >= 0.5 * dur:
            return "nothing in flight: the brain had stopped (chain ended or waiting on chat) while the request was open"
        top = max(share, key=share.get) if share else "nothing in flight"
        return f"mostly {top}"

    # ---- pickups
    def _pickups(self) -> list[dict]:
        out = []
        tools_by_bid = {t.bridge_id: t for t in self.brain.tools if t.bridge_id}
        for a in sorted(self.actions.values(), key=lambda x: x.start):
            if a.kind not in PICKUP_TOOLS:
                continue
            end = a.end or self.until
            lines = self.ue_between(a.start - 0.5, end + 0.5)
            c = Counter()
            moves_m = 0.0
            misses = []
            gend = None
            for x in lines:
                k, m = ue_kind(x.text)
                if k == "gphase":
                    c[m.group(1)] += 1
                elif k == "press":
                    c["press"] += 1
                elif k == "picked":
                    c["picked"] += 1
                elif k == "gaveup":
                    c["miss"] += 1
                    misses.append(m.group(2))
                elif k == "trip":
                    c["move"] += 1
                    moves_m += float(m.group(2))
                    if float(m.group(2)) < 3:
                        c["reaim"] += 1  # a nudge of under 3 m: re-positioning on the target, not travelling
                elif k == "stand":
                    c["plan_stand_s"] += float(m.group(1))
                elif k == "gend":
                    gend = (m.group(1), m.group(2), int(m.group(3)), int(m.group(4)))
            t = tools_by_bid.get(a.id)
            data = a.data or (t.data if t else {})
            if t and t.data and t.reason != "interrupted" and not data.get("phase_log"):
                data = {**t.data, **data}  # the brain's copy only when it is the body's own final word
            want = data.get("want") or (t.args.get("count") if t else None)
            got = data.get("gathered")
            if got is None and isinstance(data.get("gained"), dict):
                got = sum(v for v in data["gained"].values() if isinstance(v, (int, float)))
            if gend:
                got, want = gend[2], gend[3]
            refused = a.reason == "not_interactable"
            out.append({
                "id": a.id, "kind": a.kind, "start": a.start, "s": round(end - a.start, 1), "episode": t.episode if t else None,
                "args": short(t.args, 80) if t else "", "ok": a.ok, "reason": a.reason, "by": a.by,
                "approach": c["approach"], "aim": c["aim"], "pick": c["pick"], "press": c["press"], "picked": c["picked"],
                "miss": c["miss"] + (1 if refused else 0), "moves": c["move"], "reaim": c["reaim"], "moved_m": round(moves_m, 1),
                "plan_stand_s": round(c["plan_stand_s"], 1), "spots_tried": data.get("spots_tried"),
                "got": got, "want": want, "detail": short(data.get("detail") or (misses[0] if misses else ""), 110),
                "phase_log": data.get("phase_log")})
        return out

    # ---- per-request summaries
    def request_rows(self) -> list[dict]:
        rows = []
        reqs = [e for e in self.requests if not e.is_note]
        for e in self.requests:
            if e.is_note:
                continue
            nxt = next((r for r in reqs if r.t0 > e.t0), None)
            acts = [t for t in e.tools if not t.read_only]
            first_say = next((ts for ts, _, v in e.says), None)
            done = self.done[e.id]
            last = next((t for t in reversed(acts) if t.body), None)
            if not acts:
                outcome = "talk only" if e.says else "silent"
            elif last is None:
                outcome = "no body action"
            elif last.body.end is None:
                outcome = "still running"
            elif last.body.ok:
                outcome = "done"
            elif last.body.reason == "interrupted":
                outcome = f"cut ({'by ' + str(last.body.by) if last.body.by else 'interrupted'})"
            else:
                outcome = f"failed: {last.body.reason}"
            interrupted = []
            if nxt and nxt.t0 < done:
                interrupted.append(f"next request {hms(nxt.t0)} (+{nxt.t0 - e.t0:.0f} s) while open")
            interrupted += [f"chain stopped: {w}" for _, w in e.stops]
            interrupted += [f"stopped waiting for {tool}: {w}" for _, tool, w in e.waits_cut]
            dist = self._dist_at(e.t0, e.lines[0][1])
            idle = sum(max(0.0, min(g["end"], done) - max(g["start"], e.t0)) for g in self.gaps)  # overlap with [t0, done]
            rows.append({
                "id": e.id, "t0": e.t0, "text": " / ".join(t for *_, t, n in e.lines if not n),
                "notes": [t for *_, t, n in e.lines if n], "player": e.lines[0][1],
                "first_say_s": None if first_say is None else first_say - e.t0,
                "first_action_s": acts[0].ts - e.t0 if acts else None,
                "first_action": acts[0].tool if acts else None,
                "done_s": done - e.t0, "outcome": outcome, "interrupted": interrupted,
                "model_calls": len(e.llm), "model_s": sum(c.latency or 0 for c in e.llm),
                "tools": len(e.tools), "actions": len(acts), "idle_s": round(idle, 1),
                "next_line_s": (nxt.t0 - e.t0) if nxt else None, "dist_to_player_m": dist})
        return rows

    def _dist_at(self, ts: float, player: str | None):
        """Claude-to-speaker distance from the nearest get_state within 30 s; 'not seen' when get_state ran but the
        player was not in its players list (out of net relevancy, ~150 m), None when no get_state ran."""
        best, reads = None, False
        for t, name, d in self.brain.player_dist:
            if abs(t - ts) <= 30:
                reads = True
                if name == player and (best is None or abs(t - ts) < abs(best[0] - ts)):
                    best = (t, d)
        if best is None:
            near = any(abs(t - ts) <= 30 for t, _, _ in self.brain.positions)
            return "not seen" if (reads or near) else None
        return round(best[1], 1)

    def sampling(self) -> dict:
        """How dense the body's position/velocity evidence is while requests are open."""
        wins = self.open_windows()
        idx = self.grid["idx"]
        open_bins = set()
        for a, b, _ in wins:
            open_bins.update(range(idx(a), idx(b) + 1))
        pos_t = [t for t, _, _ in self.pos_samples]
        gaps = []
        for a, b, _ in wins:
            ts = [a] + [t for t in pos_t if a <= t <= b] + [b]
            gaps += [y - x for x, y in zip(ts, ts[1:])]
        speed_t = [x.ts for x in self.ue if RX["speed"].match(x.text)]
        sp_bins = set()
        for t in speed_t:
            sp_bins.update(range(idx(t - 1), idx(t + 2.5) + 1))
        open_s = len(open_bins) * BIN
        src = Counter(s for _, _, s in self.pos_samples)
        return {"open_s": round(open_s), "position_samples": len(self.pos_samples), "by_source": dict(src),
                "per_min_open": round(sum(1 for t in pos_t if idx(t) in open_bins) / max(open_s / 60, 1e-9), 1),
                "median_gap_s": round(med(gaps) or 0, 1), "p95_gap_s": round(sorted(gaps)[int(0.95 * (len(gaps) - 1))], 1) if gaps else None,
                "max_gap_s": round(max(gaps), 1) if gaps else None,
                "speed_coverage_pct": round(100 * len(sp_bins & open_bins) / max(len(open_bins), 1))}


# ------------------------------------------------------------------ rendering
def tool_line(t: ToolCall, t0: float) -> str:
    args = short(t.args, 70)
    res = "ok" if t.ok else f"{t.reason}"
    det = t.data.get("detail") or t.data.get("why") or ""
    body = ""
    if t.body:
        b = t.body
        dur = f"{b.end - b.start:.1f} s" if b.end else "running"
        if len(t.legs) > 1:
            dur = f"{len(t.legs)} legs, last {dur}"
        bo = "ok" if b.ok else (b.reason or "?")
        if b.by:
            bo += f" by {b.by}"
        if (t.ok, t.reason) != (b.ok, b.reason) or t.reason == "interrupted":
            body = f"; body {dur} -> {bo}"
        else:
            body = f"; body {dur}"
    who = ""
    if t.llm:
        who = f" ctx L{t.llm.line}"
    ro = " (read)" if t.read_only else ""
    return (f"| +{t.ts - t0:.1f} | `{t.tool}`{ro}({esc(args)}) `{t.bridge_id or '-'}` | {secs(t.latency)} | "
            f"{esc(res)}{(': ' + esc(short(det, 70))) if det else ''}{body}{who} |")


def render_md(s: Session) -> str:
    b = s.brain
    reqs = s.request_rows()
    L = []
    title = f"Session report: {b.path.name}"
    L.append(f"# {title}\n")
    L.append(f"Window {hms(b.first)}-{hms(b.last)} UTC ({(b.last - b.first) / 60:.0f} min). Player "
             f"`{b.session.get('player')}`, controller `{b.session.get('controller_model')}`, body `{b.session.get('body')}`.")
    L.append(f"Sources: brain log ({len(b.llm)} model calls, {len(b.tools)} tool calls), UE4SS.log ({len(s.ue)} [DWClient] lines), "
             f"mod actions ({len(s.mod)}), trips ({len(s.trips)}), gather events ({len(s.gather_ev)}), vitals ({len(s.vitals)}), "
             f"server log ({len(s.server)} lines). Generated by `tools/session_report.py`; all times UTC.\n")

    # headline numbers
    acts = [r for r in reqs if r["actions"]]
    done = [r["done_s"] for r in acts if r["outcome"] == "done"]
    lat = [c.latency for c in b.llm if c.latency is not None]
    idle = sum(g["s"] for g in s.gaps)
    pk = s.pickups
    L.append("## Headline\n")
    L.append("| measure | value |\n|---|---|")
    L.append(f"| requests (non-note chat episodes) | {len(reqs)} ({len(acts)} with body actions; notes: "
             f"{sum(1 for e in s.requests if e.is_note)} episodes, {sum(len(e.llm) for e in s.requests if e.is_note)} model calls spent on them) |")
    L.append(f"| outcomes | {', '.join(f'{k} {v}' for k, v in Counter(r['outcome'].split(':')[0].split(' (')[0] for r in reqs).most_common())} |")
    L.append(f"| time to first speech, median | {secs(med([r['first_say_s'] for r in reqs]))} |")
    L.append(f"| time to first action, median | {secs(med([r['first_action_s'] for r in acts]))} |")
    L.append(f"| time to done (requests whose last action ended ok), median / max | {secs(med(done))} / {secs(max(done) if done else None)} (n={len(done)}) |")
    L.append(f"| time to done or failure (all action requests), median | {secs(med([r['done_s'] for r in acts]))} |")
    L.append(f"| model calls: n, median / p95 latency, total | {len(lat)}, {secs(med(lat), 2)} / "
             f"{secs(sorted(lat)[int(0.95 * (len(lat) - 1))] if lat else None, 2)}, {sum(lat):.0f} s |")
    sm = s.sampling()
    L.append(f"| idle while a request was open (gaps > {IDLE_MIN_S:.0f} s) | {idle:.0f} s = {100 * idle / max(sm['open_s'], 1):.0f}% of "
             f"the {sm['open_s']} s a request was open, in {len(s.gaps)} gaps "
             f"({sum(1 for g in s.gaps if 10 <= g['s'] <= 20)} of 10-20 s, {sum(1 for g in s.gaps if g['s'] > 20)} over 20 s) |")
    L.append(f"| pickup actions (interact/gather/collect_water) | {len(pk)}: {sum(1 for p in pk if p['ok'])} ok, "
             f"{sum(1 for p in pk if p['reason'] == 'not_interactable')} refused (not_interactable), "
             f"{sum(1 for p in pk if p['reason'] == 'interrupted')} cut; {sum(p['press'] for p in pk)} presses, "
             f"{sum(p['picked'] for p in pk)} picked, {sum(p['miss'] for p in pk)} misses, {sum(p['moves'] for p in pk)} re-aim/approach moves, "
             f"{sum(p['s'] for p in pk):.0f} s |")
    sm = s.sampling()
    L.append(f"| body position samples while open | {sm['per_min_open']}/min (median gap {sm['median_gap_s']} s, p95 {sm['p95_gap_s']} s, "
             f"max {sm['max_gap_s']} s); move speed samples cover {sm['speed_coverage_pct']}% of open time |")
    L.append("")

    # idle causes
    L.append("## Idle gaps by cause\n")
    by = defaultdict(list)
    for g in s.gaps:
        by[g["cause_kind"]].append(g["s"])
    L.append("| cause | gaps | seconds |\n|---|---|---|")
    for k, v in sorted(by.items(), key=lambda kv: -sum(kv[1])):
        L.append(f"| {esc(k)} | {len(v)} | {sum(v):.0f} |")
    L.append("\n### Worst gaps\n")
    L.append("| start | s | request | cause | in flight (s) | evidence |\n|---|---|---|---|---|---|")
    for g in sorted(s.gaps, key=lambda g: -g["s"])[:15]:
        fl = ", ".join(f"{k} {v:g}" for k, v in list(g["in_flight_s"].items())[:4])
        ev = "; ".join(g["evidence"][:3] + g["brain"][:2])
        L.append(f"| {hms(g['start'])} | {g['s']:.0f} | {esc(g['request_text'])} | {esc(g['cause'])} | {esc(fl)} | {esc(short(ev, 220))} |")
    L.append("")

    # pickups
    L.append("## Pickup attempts\n")
    L.append("Counted from UE4SS lines inside each body action's window (approach/aim/pick phases, IA_Interact presses, "
             "`picked`, `given up`) plus the result data (`spots_tried`, `phase_log`).\n")
    fumble = [p for p in pk if not p["ok"] and p["reason"] in ("not_interactable", "path_blocked")]
    L.append(f"Refused or blocked attempts: {len(fumble)}, {sum(p['s'] for p in fumble):.0f} s; re-aim nudges (< 3 m) in all "
             f"pickups: {sum(p['reaim'] for p in pk)}; targets given up inside gathers: "
             f"{sum(p['miss'] for p in pk if p['kind'] == 'gather')}.\n")
    head = ("| start | action | s | approach | aim | press | picked | miss | re-aim | walked m | got/want | outcome | detail |\n"
            "|---|---|---|---|---|---|---|---|---|---|---|---|---|")

    def prow(p):
        out = "ok" if p["ok"] else f"{p['reason']}" + (f" by {p['by']}" if p["by"] else "")
        gw = (f"{p['got'] if p['got'] is not None else '?'}/{p['want']}" if p["want"] else
              (f"{p['got']:g}" if p["got"] is not None else "-"))
        spots = f" (spots {p['spots_tried']})" if p["spots_tried"] else ""
        return (f"| {hms(p['start'])} | `{p['kind']}` {esc(p['args'])} | {p['s']:.0f} | {p['approach']} | {p['aim']} | {p['press']} | "
                f"{p['picked']} | {p['miss']} | {p['reaim']}{spots} | {p['moved_m']:g} | {gw} | {esc(out)} | {esc(p['detail'])} |")
    worst = sorted((p for p in pk if p["miss"] or not p["ok"]), key=lambda p: -p["s"])[:10]
    L.append("Worst 10 (missed or not ok, by seconds); all attempts are in the steps file.\n")
    L.append(head)
    L += [prow(p) for p in worst]
    L.append("")
    S = [f"# Session steps: {b.path.name}\n", "Per-request step timelines and every pickup attempt; the summary is "
         f"`{'session-' + b.path.stem}.md`. Times UTC; `+t` is seconds after the line reached the brain.\n",
         "## Pickup attempts (all)\n", head] + [prow(p) for p in pk] + [""]

    # requests
    L.append("## Requests\n")
    L.append("Times are seconds after the line reached the brain; step-by-step timelines are in the steps file. "
             "`ctx Lnnn` there is the brain-log line of the prompt the model saw when it chose a call "
             "(`--why <bridge id>` prints the full rebuilt request).\n")
    L.append("| # | time | request | dist m | 1st say | 1st action | done | outcome | model calls (s) | idle s | next line |\n"
             "|---|---|---|---|---|---|---|---|---|---|---|")
    for i, r in enumerate(reqs, 1):
        L.append(f"| R{i} | {hms(r['t0'])} | {esc(short(r['text'], 70))} | {r['dist_to_player_m'] if r['dist_to_player_m'] is not None else '-'} | "
                 f"{secs(r['first_say_s'])} | {secs(r['first_action_s'])} | {secs(r['done_s'], 0)} | {esc(r['outcome'])} | "
                 f"{r['model_calls']} ({r['model_s']:.1f}) | {r['idle_s']:.0f} | {secs(r['next_line_s'], 0)} |")
    L.append("")
    S.append("## Requests\n")
    eps = {e.id: e for e in s.requests}
    for i, r in enumerate(reqs, 1):
        e = eps[r["id"]]
        S.append(f"### R{i} {hms(r['t0'])} `{e.id}`: \"{esc(short(r['text'], 160))}\"\n")
        bits = [f"first speech {secs(r['first_say_s'])}", f"first action {secs(r['first_action_s'])}"
                + (f" (`{r['first_action']}`)" if r["first_action"] else ""), f"done {secs(r['done_s'], 0)} -> **{esc(r['outcome'])}**",
                f"model {r['model_calls']} calls / {r['model_s']:.1f} s", f"idle {r['idle_s']:.0f} s"]
        if r["dist_to_player_m"] is not None:
            bits.append(f"{r['dist_to_player_m']} m from {r['player']}")
        S.append("- " + "; ".join(bits))
        if r["interrupted"]:
            S.append("- interrupted: " + "; ".join(esc(x) for x in r["interrupted"][:4]))
        if r["notes"]:
            S.append("- Luis's notes in this burst: " + " / ".join(f'"{esc(short(n, 120))}"' for n in r["notes"]))
        rows = []
        for c in e.llm:
            calls = ", ".join(f"{n}({short(a, 40)})" for n, a in c.calls) or ("says: " + short(c.content, 60) if c.content else "(nothing)")
            rows.append((c.ts, f"| +{c.ts - e.t0:.1f} | model {c.component} step {c.step} -> {esc(calls)} | {secs(c.latency, 2)} | "
                               f"{c.prompt_tok or '?'} tok ({c.cached_tok or 0} cached) L{c.line} |"))
        for t in e.tools:
            rows.append((t.ts, tool_line(t, e.t0)))
        for ts, txt, v in e.says:
            rows.append((ts, f"| +{ts - e.t0:.1f} | say \"{esc(short(txt, 90))}\" | | {'shown' if v else 'NOT verified'} |"))
        for ts, k, txt in e.notes:
            rows.append((ts, f"| +{ts - e.t0:.1f} | {k} {esc(txt)} | | |"))
        end = e.t0 + r["done_s"]
        for g in [g for g in s.gaps if g["end"] > e.t0 and g["start"] < end]:
            a = max(g["start"], e.t0)
            rows.append((a, f"| +{a - e.t0:.1f} | **idle {min(g['end'], end) - a:.0f} s** (gap {hms(g['start'])}, "
                            f"{g['s']:.0f} s): {esc(g['cause'])} | | |"))
        rows.sort(key=lambda x: x[0])
        S.append("\n| t | step | latency | result |\n|---|---|---|---|")
        S += [x for _, x in rows]
        S.append("")

    if s.self_eps:
        S.append("## Self-started episodes (situation reviews, goals)\n")
        S.append("| time | episode | model calls (s) | actions | says |\n|---|---|---|---|---|")
        for e in s.self_eps:
            S.append(f"| {hms(e.t0)} | `{e.id}` | {len(e.llm)} ({sum(c.latency or 0 for c in e.llm):.1f}) | "
                     f"{', '.join(t.tool for t in e.tools if not t.read_only) or '-'} | {esc(short(' / '.join(x for _, x, _ in e.says), 100)) or '-'} |")
        S.append("")

    # server
    L.append("## Server log (dedicated server, same window)\n")
    cats = Counter(c for _, c, _ in s.server)
    L.append(f"{len(s.server)} lines; top categories: " + ", ".join(f"{k} {v}" for k, v in cats.most_common(8)) + ".")
    chars = Counter(m.group(1) for _, c, t in s.server if c == "LogNetPlayerMovement" for m in [re.search(r"Character: (\S+)", t)] if m)
    if chars:
        L.append("ServerMove timestamp-expired warnings (net corrections) per character: "
                 + ", ".join(f"{SERVER_CHARS.get(k, k)} {v}" for k, v in chars.items()) + ".")
    L.append("Nothing in the default server log names Claude's actions, pickups or positions: server-side "
             "correlation is limited to joins, saves, spell validation and movement corrections.\n")

    # sampling
    L.append("## Is the position sampling dense enough?\n")
    L.append(f"- Open-request time {sm['open_s']} s; {sm['position_samples']} position samples in the whole run "
             f"({', '.join(f'{k} {v}' for k, v in sm['by_source'].items())}), {sm['per_min_open']}/min while a request was open.")
    L.append(f"- Gap between position samples while open: median {sm['median_gap_s']} s, p95 {sm['p95_gap_s']} s, max {sm['max_gap_s']} s.")
    L.append(f"- Move speed samples (`move: go_to/follow d= spd=`, every ~2 s, only while a move runs) cover {sm['speed_coverage_pct']}% of open time.")
    dense = (sm["p95_gap_s"] or 99) <= 2.0 and sm["speed_coverage_pct"] >= 80
    if dense:
        L.append("- Verdict: dense enough for idle detection at the 5 s threshold.\n")
    else:
        L.append(f"- Verdict: too sparse. Inside moves the speed samples find stalls, but outside them (interact/gather "
                 f"alignment, combat, eating, standing after a chain ends) position comes from `get_state` only when the "
                 f"brain asks (p95 gap {sm['p95_gap_s']} s, max {sm['max_gap_s']} s), so standing still and fumbling look "
                 "alike. Needed: a 1 Hz body sample from the client (pos, yaw, speed, action id, arbiter owner, "
                 "interact-prompt target); see docs/research/2026-11-01-telemetry.md.\n")
    return "\n".join(L) + "\n", "\n".join(S) + "\n"


def tables(s: Session) -> list[dict]:
    run = s.brain.path.stem
    out = []
    for r in s.request_rows():
        out.append({"table": "request", "run": run, **r})
    for t in s.brain.tools:
        out.append({"table": "tool", "run": run, "ts": t.ts, "tool": t.tool, "args": t.args, "episode": t.episode,
                    "task_id": t.task_id, "bridge_id": t.bridge_id, "read_only": t.read_only, "latency_s": t.latency,
                    "ok": t.ok, "reason": t.reason, "detail": t.data.get("detail"), "ctx_line": t.llm.line if t.llm else None,
                    "body_s": (t.body.end - t.body.start) if t.body and t.body.end else None,
                    "body_ok": t.body.ok if t.body else None, "body_reason": t.body.reason if t.body else None})
    for c in s.brain.llm:
        out.append({"table": "llm", "run": run, **{k: v for k, v in asdict(c).items()}, "latency_s": c.latency})
    for a in s.actions.values():
        out.append({"table": "action", "run": run, **{k: v for k, v in asdict(a).items() if k != "data"}})
    for g in s.gaps:
        out.append({"table": "gap", "run": run, **g})
    for p in s.pickups:
        out.append({"table": "pickup", "run": run, **p})
    return out


def why(s: Session, key: str) -> str:
    """The exact prompt (system + messages) the model saw when it chose the call with this bridge id / task id."""
    t = next((t for t in s.brain.tools if key in (t.bridge_id, t.task_id)), None)
    line = t.llm.line if t and t.llm else (int(key[1:]) if re.fullmatch(r"L\d+", key) else None)
    if not line:
        return f"no model call found for {key}\n"
    # A request's later calls log only the messages added after `messages_from` (brain/llm.py request_log_fields):
    # rebuild the full request from the last full prompt row of that component plus the deltas up to `line`.
    d, msgs, tools, base = None, [], [], None
    comp = next((c.component for c in s.brain.llm if c.line == line), None)
    with open(s.brain.path, encoding="utf-8", errors="replace") as f:
        for n, raw in enumerate(f, 1):
            if n > line:
                break
            if '"kind": "prompt"' not in raw[:80]:
                continue
            p = json.loads(raw)
            if p.get("component") != comp:
                continue
            if n == line:
                d = p
            if "messages_from" in p:
                msgs = msgs[:p["messages_from"]] + list(p.get("messages") or [])
            else:
                msgs, tools, base = list(p.get("messages") or []), p.get("tools") or [], n
    if d is None:
        return f"line {line} is not a prompt row\n"
    names = [(x.get("function") or x).get("name", "?") if isinstance(x, dict) else str(x) for x in tools]
    out = [f"# prompt at brain-log line {line} (full request rebuilt from line {base}), {hms(d['ts'])} UTC, "
           f"{d.get('component')} step {d.get('step')}, {d.get('model')}, settings {json.dumps(d.get('settings'))}"]
    if t:
        out.append(f"# chose: {t.tool}({json.dumps(t.args)}) -> {t.ok} {t.reason} {short(t.data.get('detail'), 120)}")
    out.append(f"# tools offered ({len(names)}): {', '.join(names)}")
    for m in msgs:
        c = m.get("content")
        if isinstance(c, list):
            c = "\n".join(x.get("text", json.dumps(x)) if isinstance(x, dict) else str(x) for x in c)
        out.append(f"\n----- {m.get('role')} -----\n{c}")
    return "\n".join(out) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("brain_log", type=Path)
    ap.add_argument("--ue4ss", type=Path, default=UE4SS_LOG, help="client UE4SS.log (local-time stamps)")
    ap.add_argument("--server-log", type=Path, default=SERVER_LOG)
    ap.add_argument("--ue4ss-utc-offset", type=float, help="hours; default: this machine's local zone")
    ap.add_argument("--root", type=Path, default=ROOT)
    ap.add_argument("--out", type=Path, help="report path (default logs/reports/session-<stem>.md)")
    ap.add_argument("--why", help="print the exact model context behind a tool call (bridge id, task id or Lnnn)")
    a = ap.parse_args(argv)
    tz = timezone(timedelta(hours=a.ue4ss_utc_offset)) if a.ue4ss_utc_offset is not None else None
    s = Session(a.brain_log, a.root, a.ue4ss, a.server_log, tz)
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    if a.why:
        sys.stdout.write(why(s, a.why))
        return 0
    out = a.out or (a.root / "logs" / "reports" / f"session-{a.brain_log.stem}.md")
    out.parent.mkdir(parents=True, exist_ok=True)
    summary, steps = render_md(s)
    out.write_text(summary, encoding="utf-8")
    st = out.with_suffix(".steps.md")
    st.write_text(steps, encoding="utf-8")
    tab = out.with_suffix(".tables.jsonl")
    tab.write_text("".join(json.dumps(r, default=str, ensure_ascii=False) + "\n" for r in tables(s)), encoding="utf-8")
    print(f"wrote {out}, {st.name}, {tab.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

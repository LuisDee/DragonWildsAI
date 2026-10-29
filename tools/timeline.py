"""One time-ordered, filterable timeline of everything Claude's client stack logs (streamline plan step 6).

Merges, each source optional:
  chat     client_io/events/chat.jsonl          what players and Claude said, joins, deaths
  brain    logs/brain-live-*.jsonl              decisions: events in, prompts, LLM replies, tool calls/results, speech
  move     client_io/events/move.jsonl          unreachable / reachable_again / stuck episodes
  vitals   client_io/events/vitals.jsonl        hp, water/food, damage, death, revive, stay-fed reflex
  activity client_io/events/activity.jsonl      completed body episodes (combat_end, fled, picked_up, consumed, death,
                                                respawned, trap_escaped, ...; the brain's episodic memory, interface.Activity)
  events   client_io/events/*.jsonl (others)    gather, traversal, savehook
  watchdog logs/client_watchdog.jsonl           crash / hang / disconnect / wrong_server / boot results
  boot     logs/client/boot.log                 boot_and_join steps
  client   logs/client/client.log               DWClient runner + module text log
  mod      logs/client/mod_*.jsonl              bridge events (module loads, service starts, errors)
  game     the client's RSDragonwilds*.log      only joins, travel, connection failures, async-load flushes, exits
  scenario logs/scenarios/*.json                scenario-suite steps (tools/scenario_run.py)

Times are shown in UTC by default (every event file is UTC; brain-live and boot.log carry their own zone).

  .venv\\Scripts\\python.exe -m tools.timeline --since 19:20 --until 19:30
  .venv\\Scripts\\python.exe -m tools.timeline --around 19:22:21 --window 90 --src chat,brain,move
  .venv\\Scripts\\python.exe -m tools.timeline --since 19:20 --grep "thirst|drink" --all
  .venv\\Scripts\\python.exe -m tools.timeline --since 19:20 --html logs\\timeline.html
  .venv\\Scripts\\python.exe -m tools.timeline --since 19:20 --jsonl logs\\timeline.jsonl   # then: lnav logs\\timeline.jsonl

Noise (pings, boot probes, raw bridge traffic, module loads) is hidden unless --all; runs of identical
lines collapse into one "(xN)" line. Passwords (client_io/secrets/server*.txt, ?p=...) are redacted.
Interactive browsing: lnav with tools/lnav/dw_timeline.json (see docs/RUNBOOK-patch.md section 10).
"""
from __future__ import annotations

# Timeline/format precedents from docs/design/streamline-plan.md; no dependency
# imported here. lnav consumes our normalized rows; logmerger informed the view:
# https://docs.lnav.org/en/latest/formats.html
# https://docs.lnav.org/en/latest/cli.html
# https://github.com/ptmcg/logmerger

import argparse
import html
import json
import os
import re
import sys
from dataclasses import asdict, dataclass, field
from datetime import date, datetime, time as dtime, timedelta, timezone
from pathlib import Path
from typing import Callable, Iterable, Iterator

ROOT = Path(__file__).resolve().parents[1]
CLIENT_GAME_LOG_DIR = Path(os.environ.get("LOCALAPPDATA", "")) / "RSDragonwilds" / "Saved" / "Logs"
SOURCES = ("chat", "brain", "move", "vitals", "activity", "events", "watchdog", "boot", "client", "mod", "game", "scenario")


@dataclass
class Row:
    ts: float
    src: str
    kind: str
    text: str
    level: str = "info"          # info | warn | error
    noise: bool = False          # hidden unless --all
    key: str | None = None       # adjacent rows with the same key collapse into one
    count: int = 1
    end_ts: float | None = None  # last ts of a collapsed run

    def line(self, tz: timezone, width: int = 0) -> str:
        t = datetime.fromtimestamp(self.ts, tz)
        stamp = t.strftime("%H:%M:%S.") + f"{t.microsecond // 100000}"
        mark = {"warn": "!", "error": "!!"}.get(self.level, " ")
        extra = ""
        if self.count > 1:
            extra = f"  (x{self.count}"
            if self.end_ts:
                extra += " until " + datetime.fromtimestamp(self.end_ts, tz).strftime("%H:%M:%S")
            extra += ")"
        text = self.text if not width or len(self.text) <= width else self.text[: width - 3] + "..."
        return f"{stamp} {mark:2}{self.src:<8} {self.kind:<18} {text}{extra}"


# ------------------------------------------------------------------ helpers
def _secrets(root: Path = ROOT) -> list[str]:
    out = []
    for f in (root / "client_io" / "secrets").glob("server*.txt"):
        try:
            lines = f.read_text(encoding="utf-8-sig").splitlines()
        except OSError:
            continue
        if len(lines) > 1 and len(lines[1].strip()) >= 3:
            out.append(lines[1].strip())
    return out


_SECRETS: list[str] | None = None


def redact(s: str) -> str:
    global _SECRETS
    if _SECRETS is None:
        _SECRETS = _secrets()
    s = re.sub(r"\?p=[^?\s\"]*", "?p=<redacted>", s)
    for pw in _SECRETS:
        s = s.replace(pw, "<redacted>")
    return s


def parse_ts(v) -> float | None:
    """unix seconds (int/float/str) or ISO-8601 (Z, +01:00, 7-digit fractions) -> unix seconds."""
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    s = str(v).strip().lstrip("\ufeff")
    if re.fullmatch(r"\d+(\.\d+)?", s):
        return float(s)
    s = re.sub(r"(\.\d{6})\d+", r"\1", s)  # .NET writes 7 fraction digits
    s = s.replace("Z", "+00:00")
    try:
        d = datetime.fromisoformat(s)
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=timezone.utc)
    return d.timestamp()


def short(v, n: int = 160) -> str:
    if v is None:
        return ""
    s = v if isinstance(v, str) else json.dumps(v, ensure_ascii=False, separators=(",", ":"), default=str)
    s = " ".join(s.split())
    return s if len(s) <= n else s[: n - 3] + "..."


def jsonl(path: Path) -> Iterator[dict]:
    try:
        with open(path, encoding="utf-8-sig", errors="replace") as f:
            for line in f:
                line = line.strip().lstrip("\ufeff")
                if not line:
                    continue
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if isinstance(d, dict):
                    yield d
    except OSError:
        return


def pos(p) -> str:
    if isinstance(p, (list, tuple)) and len(p) >= 2:
        return "(" + ",".join(f"{float(x):.1f}" for x in p[:3]) + ")"
    return str(p)


def _val(v) -> str:
    if isinstance(v, list):
        if v and all(isinstance(x, (int, float)) for x in v) and len(v) in (2, 3):
            return pos(v)
        return ",".join(_val(x) for x in v[:6]) or "none"
    if isinstance(v, dict):
        if v.get("name"):
            return str(v["name"]) + (f" x{v['count']}" if (v.get("count") or 1) > 1 else "")
        return short(v, 60)
    if isinstance(v, float):
        return f"{v:g}"
    return short(v, 60)


ACTIVITY_WARN = {"fled", "death", "trap_entered", "stuck", "failed", "gave_up"}
ACTIVITY_ERROR = {"death"}


def activity_text(d: dict) -> tuple[str, str, str]:
    """(kind, text, level) for an activity episode, from the body file or the brain's event."""
    k = str(d.get("kind") or "?")
    fields = {x: y for x, y in d.items() if x not in ("type", "kind", "by", "ts", "iso") and y not in (None, "", [], {})}
    text = "; ".join(f"{x}={_val(y)}" for x, y in fields.items())
    if d.get("by"):
        text += f"  (by {d['by']})"
    out = str(fields.get("outcome", ""))
    level = "error" if k in ACTIVITY_ERROR else "warn" if (k in ACTIVITY_WARN or out in ("failed", "fled", "died")) else "info"
    return k, text, level


def kv(d: dict, skip: Iterable[str] = ()) -> str:
    skip = set(skip) | {"ts", "iso", "type", "kind"}
    return " ".join(f"{k}={short(v, 60)}" for k, v in d.items() if k not in skip and v not in (None, "", [], {}))


# ------------------------------------------------------------------ readers (one per source)
def read_chat(path: Path) -> Iterator[Row]:
    for d in jsonl(path):
        ts = parse_ts(d.get("ts") or d.get("iso"))
        if ts is None:
            continue
        t = d.get("type")
        if t == "chat":
            who = d.get("from") or d.get("player_id")
            yield Row(ts, "chat", "said" if not d.get("self") else "said(self)", f"{who}: {d.get('text', '')}")
        elif t == "chat_event":
            tag = str(d.get("tag", "")).replace("UI.Notification.Server.", "")
            lvl = "warn" if "Death" in tag else "info"
            yield Row(ts, "chat", "notice", f"{tag} {d.get('from', '')}", lvl)
        else:
            yield Row(ts, "chat", t or "?", kv(d), "warn" if t == "chat_error" else "info")


def _brain_row(d: dict) -> Row | None:
    ts = parse_ts(d.get("ts"))
    if ts is None:
        return None
    k = d.get("kind", "?")
    B = lambda text, level="info", noise=False, key=None, kind=k: Row(ts, "brain", kind, text, level, noise, key)  # noqa: E731
    msg = d.get("msg") if isinstance(d.get("msg"), dict) else {}
    if k == "bridge_send":
        tool = msg.get("tool")
        return B(f"-> {tool} {short(msg.get('args'), 100)}", noise=True, key="send:" + str(tool) if tool == "ping" else None)
    if k == "bridge_recv":
        return B(f"<- {short(msg.get('data'), 100)}", noise=True)
    if k == "bridge_timeout":
        tool = d.get("tool")
        return B(f"{tool} got no reply in {d.get('timeout')} s (body silent?)", "warn", key=f"timeout:{tool}")
    if k in ("bridge_unmatched", "bridge_malformed"):
        return B(short(d.get("msg") or d.get("line"), 120), noise=True, key=k)
    if k == "bridge_bad_event":
        return B(short(d.get("error"), 140), "warn", key=k)
    if k == "bridge_unknown_event":
        return B(f"{d.get('event_type')} {short(d.get('sample'), 100)}", noise=True, key=k + str(d.get("event_type")))
    if k == "event":
        e = d.get("event") or {}
        et = e.get("type", "?")
        rest = kv(e)
        if et == "command_received":
            rest = f"{e.get('player')}: {e.get('text')}"
        elif et == "activity":
            ak, rest, alvl = activity_text(e)
            return B(rest, alvl, kind="ev:act:" + ak)
        if d.get("route"):
            rest += f"  [route {d['route']}]"
        return B(rest, "warn" if et in ("attacked", "vitals_low", "unreachable", "task_failed") else "info", kind="ev:" + et)
    if k == "prompt":
        msgs = d.get("messages") or []
        last = msgs[-1] if msgs else {}
        content = last.get("content") if isinstance(last, dict) else last
        if isinstance(content, list):
            content = " ".join(str(c.get("text", c)) if isinstance(c, dict) else str(c) for c in content)
        model = str(d.get("model", "")).split("/")[-1]
        return B(f"{d.get('component')} ({model}, {len(msgs)} msgs) last: {short(content, 140)}", kind="llm_prompt")
    if k == "llm_response":
        calls = d.get("tool_calls") or []
        parts = []
        if d.get("content"):
            parts.append(f"says: {short(d['content'], 160)}")
        for c in calls:
            parts.append(f"calls {c.get('name')}({short(c.get('arguments'), 80)})")
        u = d.get("usage") or {}
        tok = f"  [{u.get('prompt')}+{u.get('completion')} tok]" if u else ""
        return B(f"{d.get('component')}: " + ("; ".join(parts) or "(empty)") + tok, kind="llm_reply")
    if k == "say":
        return B(f'"{d.get("text")}"', kind="SAY")
    if k == "say_result":
        data = d.get("data") or {}
        if d.get("ok") and data.get("verified"):
            return B("echoed", noise=True)
        return B(f"ok={d.get('ok')} reason={d.get('reason')} verified={data.get('verified')}", "warn")
    if k == "tool_call":
        return B(f"{d.get('tool')}({short(d.get('args'), 120)}) task={d.get('task_id')} try={d.get('attempt')}")
    if k == "tool_result":
        r = d.get("result") or {}
        data = r.get("data") or {}
        lvl = "info" if r.get("ok") else "warn"
        detail = data.get("detail") or data.get("why") or ""
        bits = [f"{d.get('tool')} ok={r.get('ok')}"]
        if r.get("reason"):
            bits.append(f"reason={r['reason']}")
        if detail:
            bits.append(short(detail, 100))
        if data.get("position"):
            bits.append("at " + pos(data["position"]))
        if data.get("dist_m") is not None:
            bits.append(f"dist={short(data['dist_m'], 8)}m")
        return B(" ".join(bits), lvl)
    if k in ("task_done", "task_failed"):
        return B(f"{d.get('skill')} task={d.get('task_id')} reason={d.get('reason')} attempts={d.get('attempts')}",
                 "warn" if k == "task_failed" else "info")
    if k == "chat_decision":
        return B(f"{d.get('player')}: {short(d.get('text'), 80)} -> {d.get('decision')} ({short(d.get('reason'), 80)})")
    if k in ("help", "help_suppressed"):
        return B(f"{d.get('key')}: {short(d.get('text'), 140)}", noise=(k == "help_suppressed"))
    if k in ("capabilities", "session_start"):
        tools = d.get("tools") or d.get("skills")
        return B(f"tools={short(tools, 160)}" if k == "capabilities" else
                 f"body={d.get('body')} controller={d.get('controller_model')} dry_run={d.get('dry_run')}")
    if k in ("controller_not_perceived", "controller_invalid_call", "state_unavailable", "command_error",
             "skill_load_error", "progress_listener_error"):
        return B(short({x: y for x, y in d.items() if x not in ("ts", "kind", "traceback")}, 200), "warn")
    if k == "ping_reply":
        return B(f"{d.get('player')} ok={d.get('ok')} {d.get('say_round_trip_ms')} ms")
    return B(short({x: y for x, y in d.items() if x not in ("ts", "kind")}, 200))


def read_brain(path: Path) -> Iterator[Row]:
    for d in jsonl(path):
        r = _brain_row(d)
        if r:
            yield r


def read_move(path: Path) -> Iterator[Row]:
    """unreachable (once per episode) / reachable_again / stuck, from move.lua emit_move_event."""
    for d in jsonl(path):
        ts = parse_ts(d.get("ts") or d.get("iso"))
        if ts is None:
            continue
        t = d.get("type", "?")
        tgt = d.get("target")
        tgt = f" to {tgt}" + (f" ({d['target_kind']})" if d.get("target_kind") and d.get("target_kind") != tgt else "") if tgt else ""
        if t == "unreachable":
            text = (f"{d.get('mode', '')}{tgt} reason={d.get('reason')} me={pos(d.get('my_pos'))} "
                    f"goal={pos(d.get('leader_pos'))} {d.get('detail', '')}")
        elif t == "reachable_again":
            text = f"{tgt.strip()} after {d.get('after_s')} s me={pos(d.get('my_pos'))} goal={pos(d.get('leader_pos'))}"
        elif t == "stuck":
            text = f"{tgt.strip()} me={pos(d.get('my_pos'))} goal={pos(d.get('leader_pos'))} unstuck={d.get('unstuck')}"
        else:
            text = kv(d)
        yield Row(ts, "move", t, text.strip(), "warn" if t in ("unreachable", "stuck") else "info")


def read_activity(path: Path) -> Iterator[Row]:
    for d in jsonl(path):
        ts = parse_ts(d.get("ts") or d.get("iso"))
        if ts is None:
            continue
        k, text, level = activity_text(d)
        yield Row(ts, "activity", k, text, level)


def _stat(d: dict, name: str) -> str:
    v = d.get(name) or (d.get("survival") or {}).get(name)
    if isinstance(v, (list, tuple)) and v:
        return f"{float(v[0]):.1f}/{float(v[1]):.0f}" if len(v) > 1 else f"{float(v[0]):.1f}"
    return "?"


def read_vitals(path: Path) -> Iterator[Row]:
    for d in jsonl(path):
        ts = parse_ts(d.get("ts") or d.get("iso"))
        if ts is None:
            continue
        t = d.get("type", "?")
        if t in ("survival", "start", "death", "revive"):
            text = f"hp={d.get('hp')} water={_stat(d, 'hydration')} food={_stat(d, 'sustenance')} rest={_stat(d, 'endurance')}"
            lvl = "error" if t == "death" else "info"
            yield Row(ts, "vitals", t, text, lvl, key=("survival:" + text) if t == "survival" else None)
        elif t == "health":
            yield Row(ts, "vitals", "health", f"hp {d.get('prev')} -> {d.get('hp')} ({d.get('delta')})",
                      "warn" if (d.get("delta") or 0) < 0 else "info", key=None)
        elif t == "damage":
            inst = d.get("instigator") or {}
            who = inst.get("player") or inst.get("class") or "?"
            st = ",".join(d.get("status") or [])
            yield Row(ts, "vitals", "damage", f"{d.get('amount')} from {who}{' (' + st + ')' if st else ''} hp={d.get('hp')}",
                      "warn", key=f"dmg:{who}:{st}:{d.get('amount')}")
        elif t == "fatal":
            yield Row(ts, "vitals", "fatal", f"killed by {(d.get('killed_by') or {}).get('name') or d.get('text')}", "error")
        elif t == "reflex":
            yield Row(ts, "vitals", "reflex", f"{d.get('action')} {d.get('name')} ({d.get('kind')}) ok={d.get('ok')} via {d.get('via')}")
        else:
            yield Row(ts, "vitals", t, kv(d))


def read_events_generic(path: Path) -> Iterator[Row]:
    src_kind = path.stem
    for d in jsonl(path):
        ts = parse_ts(d.get("ts") or d.get("iso"))
        if ts is None:
            continue
        t = d.get("type") or d.get("fn") or src_kind
        yield Row(ts, "events", f"{src_kind}:{t}", kv(d))


def read_watchdog(path: Path) -> Iterator[Row]:
    lvl = {"client_hang": "error", "client_crash_dump": "error", "client_crash_reporter": "error", "client_gone": "error",
           "client_kill": "warn", "client_disconnected": "warn", "wrong_server": "warn", "memory_low": "warn",
           "memory_critical": "error", "restart_rate_limited": "error", "watchdog_error": "error"}
    for d in jsonl(path):
        ts = parse_ts(d.get("ts"))
        if ts is None:
            continue
        e = d.get("event", "?")
        level = lvl.get(e, "info")
        if e == "boot_result" and not d.get("ok"):
            level = "warn"
        yield Row(ts, "watchdog", e, redact(kv(d, skip=("event", "last_client_dump"))), level)


_TEXT_TS = re.compile(r"^(\d{4}-\d\d-\d\dT[\d:.]+(?:Z|[+-]\d\d:\d\d)?)\s+(.*)$")


def read_text_log(path: Path, src: str, noise_rx: re.Pattern | None = None, warn_rx: re.Pattern | None = None) -> Iterator[Row]:
    try:
        f = open(path, encoding="utf-8-sig", errors="replace")
    except OSError:
        return
    with f:
        for line in f:
            m = _TEXT_TS.match(line.rstrip("\n").lstrip("\ufeff"))
            if not m:
                continue
            ts = parse_ts(m.group(1))
            if ts is None:
                continue
            text = redact(m.group(2).strip())
            noise = bool(noise_rx and noise_rx.search(text))
            level = "warn" if warn_rx and warn_rx.search(text) else "info"
            kind = "line"
            mm = re.match(r"ran (\S+) ok=(\w+)", text)
            if mm:
                kind = "ran"
                if mm.group(2) != "true":
                    level = "warn"
            yield Row(ts, src, kind, text, level, noise, key=text if noise else None)


def read_mod(path: Path) -> Iterator[Row]:
    for d in jsonl(path):
        ts = parse_ts(d.get("ts"))
        if ts is None:
            continue
        e = str(d.get("event", "?"))
        data = d.get("data") or {}
        noisy = e in ("client_module_loaded",)
        lvl = "warn" if ("error" in e or data.get("ok") is False) else "info"
        yield Row(ts, "mod", e.replace("client_", ""), redact(short(data, 180)), lvl, noisy)


_GAME_TS = re.compile(r"^\[(\d{4})\.(\d\d)\.(\d\d)-(\d\d)\.(\d\d)\.(\d\d):(\d{3})\]\[\s*\d+\](.*)$")
GAME_RX = re.compile(r"LoadMap: |Browse: |Connection Failed|NetworkFailure|TravelFailure|PendingConnectionFailure|"
                     r"Join succeeded|Connection to server has completed|PlayerChar entered|FlushAsyncLoading|"
                     r"Fatal error|Unhandled Exception|LogExit|Exit requested|DuplicateChar|Missing user ID")


def read_game(path: Path) -> Iterator[Row]:
    try:
        f = open(path, encoding="utf-8-sig", errors="replace")
    except OSError:
        return
    with f:
        for line in f:
            if not GAME_RX.search(line):
                continue
            m = _GAME_TS.match(line.rstrip("\n"))
            if not m:
                continue
            y, mo, dd, h, mi, s, ms, rest = m.groups()
            ts = datetime(int(y), int(mo), int(dd), int(h), int(mi), int(s), int(ms) * 1000, tzinfo=timezone.utc).timestamp()
            text = redact(rest.strip())
            lvl = "error" if re.search(r"Fatal|Unhandled|Failure|Failed", text) else "info"
            key = "flush" if "FlushAsyncLoading" in text else None
            yield Row(ts, "game", text.split(":", 1)[0][:18], short(text, 220), lvl, key=key)


def read_scenario(path: Path) -> Iterator[Row]:
    try:
        rep = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return
    for st in rep.get("steps") or []:
        ts = parse_ts(st.get("ts"))
        if ts is None:
            continue
        res = st.get("result", "")
        lvl = {"fail": "warn", "error": "error"}.get(res, "info")
        yield Row(ts, "scenario", f"{st.get('scenario', '')}:{res}", short(st.get("detail", ""), 200), lvl)


# ------------------------------------------------------------------ source discovery
def _name_time(path: Path, rx: str, utc: bool) -> float | None:
    m = re.search(rx, path.name)
    if not m:
        return None
    d = datetime.strptime("".join(m.groups()), "%Y%m%d%H%M%S")
    return (d.replace(tzinfo=timezone.utc) if utc else d.astimezone()).timestamp()


def _pick_by_start(files: list[Path], rx: str, utc: bool, since: float | None, until: float | None) -> list[Path]:
    """Files named by their start time: keep those that can overlap [since, until]; newest only with no window."""
    stamped = sorted(((t, f) for f in files if (t := _name_time(f, rx, utc)) is not None), key=lambda x: x[0])
    if not stamped:
        return []
    if since is None and until is None:
        return [stamped[-1][1]]
    out = []
    for i, (start, f) in enumerate(stamped):
        nxt = stamped[i + 1][0] if i + 1 < len(stamped) else float("inf")
        if (until is None or start <= until) and (since is None or nxt >= since):
            out.append(f)
    return out


def discover(root: Path, since: float | None, until: float | None, game_dir: Path | None = None) -> dict[str, list[tuple[Path, Callable]]]:
    ev = root / "client_io" / "events"
    cl = root / "logs" / "client"
    srcs: dict[str, list[tuple[Path, Callable]]] = {s: [] for s in SOURCES}
    srcs["chat"].append((ev / "chat.jsonl", read_chat))
    srcs["move"].append((ev / "move.jsonl", read_move))
    srcs["vitals"].append((ev / "vitals.jsonl", read_vitals))
    srcs["activity"].append((ev / "activity.jsonl", read_activity))
    for f in sorted(ev.glob("*.jsonl")):
        if f.name not in ("chat.jsonl", "move.jsonl", "vitals.jsonl", "activity.jsonl"):
            srcs["events"].append((f, read_events_generic))
    for f in _pick_by_start(list((root / "logs").glob("brain-live-*.jsonl")), r"(\d{8})-(\d{6})", False, since, until):
        srcs["brain"].append((f, read_brain))
    srcs["watchdog"].append((root / "logs" / "client_watchdog.jsonl", read_watchdog))
    boot_noise = re.compile(r"^probe: ")
    srcs["boot"].append((cl / "boot.log", lambda p: read_text_log(p, "boot", boot_noise, re.compile(r"fail|error|timeout|wrong_server", re.I))))
    client_noise = re.compile(r"^ran (wd_boot_probe|boot_probe)\.lua ok=true")
    srcs["client"].append((cl / "client.log", lambda p: read_text_log(p, "client", client_noise, re.compile(r"error|fail|crash|stuck", re.I))))
    for f in _pick_by_start(list(cl.glob("mod_*.jsonl")), r"(\d{8})T(\d{6})Z", True, since, until):
        srcs["mod"].append((f, read_mod))
    gd = game_dir or CLIENT_GAME_LOG_DIR
    if gd.is_dir():
        for f in sorted(gd.glob("RSDragonwilds*.log")):
            mt = f.stat().st_mtime
            if since is None or mt >= since:
                srcs["game"].append((f, read_game))
    sc = root / "logs" / "scenarios"
    if sc.is_dir():
        for f in sorted(sc.glob("*.json")):
            if since is None or f.stat().st_mtime >= since:
                srcs["scenario"].append((f, read_scenario))
    return srcs


# ------------------------------------------------------------------ build + render
def collapse(rows: list[Row]) -> list[Row]:
    out: list[Row] = []
    last_by_src: dict[str, Row] = {}
    for r in rows:
        prev = last_by_src.get(r.src)
        if r.key and prev is not None and prev.key == r.key and out and out[-1] is prev:
            prev.count += 1
            prev.end_ts = r.ts
            continue
        out.append(r)
        last_by_src[r.src] = r
    return out


def build(root: Path, since: float | None, until: float | None, include: set[str], show_noise: bool = False,
          grep: re.Pattern | None = None, game_dir: Path | None = None) -> list[Row]:
    global _SECRETS
    _SECRETS = sorted(set(_secrets(root)) | set(_secrets(ROOT)), key=len, reverse=True)
    rows: list[Row] = []
    for src, files in discover(root, since, until, game_dir).items():
        if src not in include:
            continue
        for path, reader in files:
            if not path.exists():
                continue
            for r in reader(path):
                if since is not None and r.ts < since:
                    continue
                if until is not None and r.ts > until:
                    continue
                if r.noise and not show_noise:
                    continue
                r.text = redact(r.text)
                rows.append(r)
    rows.sort(key=lambda r: (r.ts, SOURCES.index(r.src) if r.src in SOURCES else 99))
    rows = collapse(rows)
    if grep:
        rows = [r for r in rows if grep.search(f"{r.src} {r.kind} {r.text}")]
    return rows


def parse_when(s: str | None, tz: timezone, day: date) -> float | None:
    """'19:20', '19:20:05', '2026-10-25 19:20', ISO, or relative '15m' / '2h' (ago)."""
    if not s:
        return None
    s = s.strip()
    m = re.fullmatch(r"(\d+)\s*([smhd])", s)
    if m:
        mult = {"s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)]
        return datetime.now(timezone.utc).timestamp() - int(m.group(1)) * mult
    if re.fullmatch(r"\d{1,2}:\d\d(:\d\d(\.\d+)?)?", s):
        parts = [float(x) for x in s.split(":")]
        sec = parts[2] if len(parts) > 2 else 0.0
        t = dtime(int(parts[0]), int(parts[1]), int(sec), int((sec % 1) * 1e6))
        return datetime.combine(day, t, tzinfo=tz).timestamp()
    v = parse_ts(s.replace(" ", "T"))
    if v is None:
        raise SystemExit(f"cannot parse time {s!r} (use HH:MM[:SS], an ISO time, or 15m / 2h)")
    if not re.search(r"(Z|[+-]\d\d:?\d\d)$", s):  # naive: in the display zone
        d = datetime.fromisoformat(s.replace(" ", "T")).replace(tzinfo=tz)
        v = d.timestamp()
    return v


def render_text(rows: list[Row], tz: timezone, width: int = 0) -> str:
    if not rows:
        return "(no rows in this window)\n"
    out, day = [], None
    for r in rows:
        d = datetime.fromtimestamp(r.ts, tz).date()
        if d != day:
            out.append(f"---- {d.isoformat()} ({'UTC' if tz == timezone.utc else 'local'}) ----")
            day = d
        out.append(r.line(tz, width))
    return "\n".join(out) + "\n"


def render_jsonl(rows: list[Row]) -> str:
    lines = []
    for r in rows:
        d = asdict(r)
        d["ts"] = datetime.fromtimestamp(r.ts, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
        d.pop("key", None)
        if r.count == 1:
            d.pop("count")  # lnav shows "(xN)" only for collapsed runs
        d["end_ts"] = (datetime.fromtimestamp(r.end_ts, timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
                       if r.end_ts else None)
        lines.append(json.dumps(d, ensure_ascii=False))
    return "\n".join(lines) + ("\n" if lines else "")


def render_html(rows: list[Row], tz: timezone, title: str) -> str:
    srcs = sorted({r.src for r in rows}, key=lambda s: SOURCES.index(s) if s in SOURCES else 99)
    body = []
    for r in rows:
        t = datetime.fromtimestamp(r.ts, tz).strftime("%H:%M:%S.") + str(datetime.fromtimestamp(r.ts, tz).microsecond // 100000)
        cnt = f" <span class=n>x{r.count}</span>" if r.count > 1 else ""
        body.append(f'<tr class="{r.level}" data-src="{r.src}"><td class=t>{t}</td><td class="s s-{r.src}">{r.src}</td>'
                    f"<td class=k>{html.escape(r.kind)}</td><td>{html.escape(r.text)}{cnt}</td></tr>")
    boxes = "".join(f'<label><input type=checkbox checked value="{s}"> {s}</label>' for s in srcs)
    return f"""<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>Claude Timeline</title><style>
:root{{--bg:#fbfbf9;--fg:#1d1d1b;--mut:#6b6b66;--line:#e4e3de;--warn:#fff4d6;--err:#fde2e0}}
@media (prefers-color-scheme:dark){{:root:not([data-theme=light]){{--bg:#161615;--fg:#e9e8e3;--mut:#9a9992;--line:#2d2d2b;--warn:#3a3218;--err:#43201d}}}}
:root[data-theme=dark]{{--bg:#161615;--fg:#e9e8e3;--mut:#9a9992;--line:#2d2d2b;--warn:#3a3218;--err:#43201d}}
body{{background:var(--bg);color:var(--fg);font:13px/1.45 ui-monospace,Consolas,monospace;margin:0;padding:12px 16px}}
h1{{font:600 15px system-ui,sans-serif;margin:0 0 8px}} .bar{{position:sticky;top:0;background:var(--bg);padding:6px 0;border-bottom:1px solid var(--line);display:flex;flex-wrap:wrap;gap:10px;align-items:center}}
input[type=search]{{flex:1 1 220px;padding:4px 6px;background:var(--bg);color:var(--fg);border:1px solid var(--line)}}
table{{border-collapse:collapse;width:100%}} td{{padding:2px 6px;border-bottom:1px solid var(--line);vertical-align:top;word-break:break-word}}
.t,.s,.k{{white-space:nowrap;color:var(--mut)}} tr.warn{{background:var(--warn)}} tr.error{{background:var(--err)}} .n{{color:var(--mut)}}
.wrap{{overflow-x:auto}}</style></head><body><h1>{html.escape(title)}</h1>
<div class=bar>{boxes}<input type=search id=q placeholder="filter (regex)"></div><div class=wrap><table id=tl>{''.join(body)}</table></div>
<script>
const q=document.getElementById('q'),boxes=[...document.querySelectorAll('.bar input[type=checkbox]')],rows=[...document.querySelectorAll('#tl tr')];
function apply(){{const on=new Set(boxes.filter(b=>b.checked).map(b=>b.value));let rx=null;try{{rx=q.value?new RegExp(q.value,'i'):null}}catch(e){{}}
rows.forEach(r=>{{r.style.display=(on.has(r.dataset.src)&&(!rx||rx.test(r.textContent)))?'':'none'}})}}
boxes.forEach(b=>b.addEventListener('change',apply));q.addEventListener('input',apply);
</script></body></html>
"""


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--since", help="start: HH:MM[:SS] (display zone, --date day), ISO, or 15m / 2h ago")
    ap.add_argument("--until", help="end, same forms")
    ap.add_argument("--around", help="centre time; with --window seconds either side")
    ap.add_argument("--window", type=float, default=60.0)
    ap.add_argument("--date", help="day for bare HH:MM times (YYYY-MM-DD; default today in the display zone)")
    ap.add_argument("--local", action="store_true", help="show and read bare times in local time (default UTC)")
    ap.add_argument("--src", help=f"comma list to include (default all): {','.join(SOURCES)}")
    ap.add_argument("--xsrc", help="comma list to exclude")
    ap.add_argument("--grep", help="regex over 'src kind text' (case-insensitive)")
    ap.add_argument("--all", action="store_true", help="include noise (pings, probes, raw bridge traffic, module loads)")
    ap.add_argument("--tail", type=int, help="only the last N rows")
    ap.add_argument("--width", type=int, default=240, help="cut each line's text at N characters (0 = never)")
    ap.add_argument("--root", default=str(ROOT), help=argparse.SUPPRESS)
    ap.add_argument("--game-dir", help=argparse.SUPPRESS)
    ap.add_argument("--jsonl", help="also write normalised rows (lnav: tools/lnav/dw_timeline.json)")
    ap.add_argument("--html", help="also write a filterable HTML page")
    ap.add_argument("-o", "--out", help="write the text timeline here instead of stdout")
    a = ap.parse_args(argv)

    tz = datetime.now().astimezone().tzinfo if a.local else timezone.utc
    day = date.fromisoformat(a.date) if a.date else datetime.now(tz).date()
    if a.around:
        c = parse_when(a.around, tz, day)
        since, until = c - a.window, c + a.window
    else:
        since, until = parse_when(a.since, tz, day), parse_when(a.until, tz, day)
    include = set(SOURCES)
    if a.src:
        include = {s.strip() for s in a.src.split(",") if s.strip()}
        bad = include - set(SOURCES)
        if bad:
            raise SystemExit(f"unknown source(s) {sorted(bad)}; known: {', '.join(SOURCES)}")
    if a.xsrc:
        include -= {s.strip() for s in a.xsrc.split(",")}
    grep = re.compile(a.grep, re.I) if a.grep else None
    rows = build(Path(a.root), since, until, include, a.all, grep, Path(a.game_dir) if a.game_dir else None)
    if a.tail:
        rows = rows[-a.tail:]
    text = render_text(rows, tz, a.width)
    if a.out:
        Path(a.out).write_text(text, encoding="utf-8")
    else:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stdout.write(text)
    if a.jsonl:
        Path(a.jsonl).write_text(render_jsonl(rows), encoding="utf-8")
    if a.html:
        fmt = lambda v: datetime.fromtimestamp(v, tz).strftime("%Y-%m-%d %H:%M:%S") if v else "..."  # noqa: E731
        Path(a.html).write_text(render_html(rows, tz, f"Claude timeline {fmt(since)} to {fmt(until)}"), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

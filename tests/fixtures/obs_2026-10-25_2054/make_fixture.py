"""Rebuild this fixture from the real logs of 2026-10-25 20:50-21:19 UTC (tests/test_obs.py).

    .venv\\Scripts\\python.exe tests\\fixtures\\obs_2026-10-25_2054\\make_fixture.py

Copies the brain-live, chat, vitals (death/fatal), mod and watchdog rows of that window into a mini repo root here,
trimming what the observability tool never reads (full prompts, big tool payloads). Refuses to write if a server
password or API-key-like string would end up in the fixture.

The repo .gitignore ignores every logs/ and client_io/ directory, so files are stored flat with their repo path joined
by "__" (logs__client__mod_...jsonl); tests/test_obs.py rebuilds the layout in a temp dir (unflatten()).
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
LO, HI = 1792961400.0, 1792963140.0   # 20:50:00 - 21:19:00 UTC
BRAIN = ["brain-live-20261025-214057-8860.jsonl", "brain-live-20261025-220403-6472.jsonl"]
MODS = ["mod_20261025T205330Z.jsonl", "mod_20261025T205550Z.jsonl", "mod_20261025T205939Z.jsonl", "mod_20261025T211138Z.jsonl"]
KEEP_DATA = ("detail", "why", "position", "dist_m", "gathered", "item", "started", "pong", "spell", "id", "remaining_s",
             "target", "verified", "text")


def rows(path: Path):
    for line in path.open(encoding="utf-8-sig", errors="replace"):
        line = line.strip().lstrip("﻿")
        if line:
            try:
                yield json.loads(line)
            except ValueError:
                pass


def ts_of(d: dict) -> float | None:
    v = d.get("ts")
    if isinstance(v, (int, float)):
        return float(v)
    from tools.timeline import parse_ts
    return parse_ts(v or d.get("iso"))


def slim_data(data):
    if not isinstance(data, dict):
        return data
    return {k: v for k, v in data.items() if k in KEEP_DATA and len(json.dumps(v, default=str)) < 400}


def slim_brain(d: dict) -> dict:
    k = d.get("kind")
    if k == "prompt":
        msgs = d.get("messages") or []
        last = dict(msgs[-1]) if msgs else {}
        content = last.get("content")
        if isinstance(content, str) and content.startswith("{"):
            try:
                ctx = json.loads(content)
                content = json.dumps({x: ctx[x] for x in ("command", "body_event") if x in ctx}, ensure_ascii=False)
            except ValueError:
                content = content[:300]
        elif isinstance(content, str):
            content = content[:300]
        d = {**d, "messages": ([{"role": "system", "content": "(trimmed)"}] if len(msgs) > 1 else []) +
             [{"role": last.get("role"), "content": content}]}
    elif k in ("bridge_send", "bridge_recv"):
        msg = dict(d.get("msg") or {})
        if "data" in msg:
            msg["data"] = slim_data(msg["data"])
        if isinstance(msg.get("args"), dict) and len(json.dumps(msg["args"])) > 400:
            msg["args"] = {}
        d = {**d, "msg": msg}
    elif k == "tool_result":
        r = dict(d.get("result") or {})
        r["data"] = slim_data(r.get("data") or {})
        d = {**d, "result": r}
    elif k in ("capabilities", "session_start"):
        d = {x: y for x, y in d.items() if x in ("ts", "kind", "world", "body", "controller_model", "planner_model", "dry_run")}
    elif k == "event_dropped":
        d = {**d, "event": {"type": (d.get("event") or {}).get("type")}}
    elif k == "say_result":
        d = {**d, "data": slim_data(d.get("data"))}
    return d


def secrets() -> list[str]:
    out = []
    for f in (REPO / "client_io" / "secrets").glob("server*.txt"):
        lines = f.read_text(encoding="utf-8-sig").splitlines()
        if len(lines) > 1 and len(lines[1].strip()) >= 3:
            out.append(lines[1].strip())
    return out


def main() -> int:
    sys.path.insert(0, str(REPO))
    out: dict[Path, list[str]] = {}
    for name in BRAIN:
        sel = [slim_brain(d) for d in rows(REPO / "logs" / name) if (t := ts_of(d)) is not None and LO <= t <= HI
               or d.get("kind") == "session_start"]
        out[HERE / "logs" / name] = [json.dumps(d, ensure_ascii=False, default=str) for d in sel]
    for name in MODS:
        out[HERE / "logs" / "client" / name] = [json.dumps(d, ensure_ascii=False) for d in rows(REPO / "logs" / "client" / name)
                                                if (t := ts_of(d)) is not None and LO - 600 <= t <= HI]
    ev = REPO / "client_io" / "events"
    out[HERE / "client_io" / "events" / "chat.jsonl"] = [json.dumps(d, ensure_ascii=False) for d in rows(ev / "chat.jsonl")
                                                        if (t := ts_of(d)) is not None and LO <= t <= HI]
    out[HERE / "client_io" / "events" / "vitals.jsonl"] = [json.dumps(d, ensure_ascii=False) for d in rows(ev / "vitals.jsonl")
                                                          if d.get("type") in ("death", "fatal") and (ts_of(d) or 0) <= 1792964400]  # deaths up to 21:40
    out[HERE / "logs" / "client_watchdog.jsonl"] = [json.dumps(d, ensure_ascii=False) for d in rows(REPO / "logs" / "client_watchdog.jsonl")]
    blob = "\n".join(line for lines in out.values() for line in lines)
    bad = [s for s in secrets() if s in blob] + re.findall(r"sk-ant-[\w-]{8,}|\?p=[^?\s\"]+|api[_-]?key\"?\s*[:=]\s*\"\w{8,}", blob, re.I)
    if bad:
        print(f"refusing: {len(bad)} secret-looking strings would be written")
        return 1
    for path, lines in out.items():
        flat = HERE / "__".join(path.relative_to(HERE).parts)
        flat.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"{flat.name}: {len(lines)} rows")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

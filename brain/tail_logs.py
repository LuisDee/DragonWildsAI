"""Pretty-print the brain's JSONL log, following it live.

  .venv\\Scripts\\python.exe -m brain.tail_logs            # newest live session, follow
  .venv\\Scripts\\python.exe -m brain.tail_logs -n 50 --no-follow
  .venv\\Scripts\\python.exe -m brain.tail_logs --bridge   # also raw bridge traffic
  .venv\\Scripts\\python.exe -m brain.tail_logs logs\\brain-live-20261025-140000-123.jsonl
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from collections import deque
from pathlib import Path

from . import paths

# Raw bridge traffic repeats tool_call/tool_result and every get_state; hidden unless --bridge.
BRIDGE_KINDS = {"bridge_send", "bridge_recv"}


def latest_log(directory: Path | None = None) -> Path | None:
    d = Path(directory) if directory else paths.log_dir()
    for pattern in ("brain-live-*.jsonl", "brain-*.jsonl", "*.jsonl"):
        files = sorted(d.glob(pattern), key=lambda p: p.stat().st_mtime)
        if files:
            return files[-1]
    return None


def _short(value, limit: int = 160) -> str:
    text = value if isinstance(value, str) else json.dumps(value, default=str, ensure_ascii=False)
    return text if len(text) <= limit else text[: limit - 3] + "..."


def _args(args: dict | None) -> str:
    return ", ".join(f"{k}={_short(v, 40)}" for k, v in (args or {}).items())


def summarise(rec: dict) -> str:
    kind = rec.get("kind", "?")
    if kind == "event":
        ev = rec.get("event") or {}
        if ev.get("type") == "command_received":
            route = f" [{rec['route']}]" if "route" in rec else ""
            return f"chat {ev.get('player')}: {ev.get('text')!r}{route}"
        return f"event {_short({k: v for k, v in ev.items()})}"
    if kind == "prompt":
        last = (rec.get("messages") or [{}])[-1].get("content", "")
        return f"prompt -> {rec.get('component')} ({rec.get('model')}): {_short(last, 120)}"
    if kind == "llm_response":
        calls = "; ".join(f"{c.get('name')}({_args(c.get('arguments'))})" for c in rec.get("tool_calls") or [])
        return f"llm <- {rec.get('component')}: {_short(rec.get('content') or '', 100)!r}" + (
            f" calls: {calls}" if calls else "")
    if kind == "tool_call":
        return f"call {rec.get('tool')}({_args(rec.get('args'))}) attempt {rec.get('attempt', 1)}"
    if kind == "tool_result":
        res = rec.get("result") or {}
        status = "ok" if res.get("ok") else f"FAIL {res.get('reason')}"
        return f"result {rec.get('tool')}: {status} {_short(res.get('data') or {}, 100)}"
    if kind == "say":
        return f"SAY {rec.get('text')!r}"
    if kind == "ping_reply":
        return f"!ping -> pong ok={rec.get('ok')} say round trip {rec.get('say_round_trip_ms')} ms"
    if kind in ("bridge_send", "bridge_recv"):
        return f"{kind} {_short(rec.get('msg'), 200)}"
    rest = {k: v for k, v in rec.items() if k not in ("ts", "kind", "traceback")}
    return f"{kind} {_short(rest)}"


def format_line(line: str, show_bridge: bool = False) -> str | None:
    line = line.strip()
    if not line:
        return None
    try:
        rec = json.loads(line)
    except json.JSONDecodeError:
        return f"???????? (unparsed) {_short(line)}"
    if not isinstance(rec, dict) or (rec.get("kind") in BRIDGE_KINDS and not show_bridge):
        return None
    ts = rec.get("ts")
    stamp = time.strftime("%H:%M:%S", time.localtime(ts)) if isinstance(ts, (int, float)) else "--:--:--"
    return f"{stamp} {summarise(rec)}"


def tail(path: Path, lines: int = 20, follow: bool = True, show_bridge: bool = False,
         out=print, poll: float = 0.5) -> None:
    with path.open(encoding="utf-8", errors="replace") as f:
        for raw in deque(f, maxlen=lines) if lines > 0 else []:
            if (s := format_line(raw, show_bridge)) is not None:
                out(s)
        if lines <= 0:
            f.seek(0, 2)
        partial = ""
        while follow:
            chunk = f.readline()
            if not chunk:
                time.sleep(poll)
                continue
            partial += chunk
            if partial.endswith("\n"):
                if (s := format_line(partial, show_bridge)) is not None:
                    out(s)
                partial = ""


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python -m brain.tail_logs", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path", nargs="?", type=Path, help="log file; default: newest in DW_LOG_DIR or logs/")
    ap.add_argument("-n", "--lines", type=int, default=20, help="show this many earlier lines first")
    ap.add_argument("--no-follow", action="store_true", help="print and exit")
    ap.add_argument("--bridge", action="store_true", help="also show raw bridge_send/bridge_recv")
    a = ap.parse_args(argv)
    if hasattr(sys.stdout, "reconfigure"):  # chat text may not fit a cp1252 console
        sys.stdout.reconfigure(errors="replace")
    path = a.path or latest_log()
    if path is None or not path.exists():
        print(f"no log file found in {paths.log_dir()}", file=sys.stderr)
        return 1
    print(f"== {path}")
    try:
        tail(path, a.lines, not a.no_follow, a.bridge)
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())

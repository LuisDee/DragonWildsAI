"""Turn latency from a brain log (BUGS.md L6): chat line heard -> first response (a line said, or a
non-read tool started), p50/p95, plus get_state reads per turn and prompt-cache hit share.

    .venv\\Scripts\\python.exe tools\\turn_latency.py logs\\brain-live-<...>.jsonl [--since HH:MM] [--until HH:MM]

The decision for unaddressed lines waits for the chat burst to go quiet (DW_CHAT_DEBOUNCE_S, 1.2 s) by
design; "addressed" rows show named lines only. Times are UTC.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import statistics
import sys
from pathlib import Path


def pct(xs: list[float], p: float) -> float | None:
    if not xs:
        return None
    xs = sorted(xs)
    k = max(0, min(len(xs) - 1, round(p / 100 * (len(xs) - 1))))
    return xs[k]


def analyse(path: Path, since: str | None = None, until: str | None = None) -> dict:
    recs = [json.loads(line) for line in path.open(encoding="utf-8") if line.strip()]

    def hhmm(r):
        return dt.datetime.fromtimestamp(r["ts"], dt.UTC).strftime("%H:%M")
    recs = [r for r in recs if (not since or hhmm(r) >= since) and (not until or hhmm(r) <= until)]
    sends: dict[str, str] = {}
    heard: list[tuple[float, str, bool]] = []  # (ts, text, addressed)
    responses: list[float] = []
    turn_reads: list[int] = []
    reads_now = 0
    cached = prompt = 0
    for r in recs:
        k = r["kind"]
        if k == "bridge_send":
            sends[r["msg"]["id"]] = r["msg"]["tool"]
            if r["msg"]["tool"] == "get_state":
                reads_now += 1
        elif k == "event" and (r.get("event") or {}).get("type") == "chat_heard":
            heard.append((r["ts"], r["event"].get("text", ""), False))
        elif k == "chat_decision" and r.get("decision") == "addressed" and heard:
            # mark the matching heard line addressed (named, or the model decided it was for him)
            for i in range(len(heard) - 1, -1, -1):
                if heard[i][1] == r.get("text"):
                    heard[i] = (heard[i][0], heard[i][1], True)
                    break
        elif k == "say" or (k == "tool_call" and not r.get("read_only")):
            responses.append(r["ts"])
            if k == "tool_call":
                turn_reads.append(reads_now)
            reads_now = 0
        elif k == "llm_response" and isinstance(r.get("usage"), dict):
            prompt += r["usage"].get("prompt") or 0
            cached += r["usage"].get("cached") or 0
    lat_all, lat_addr = [], []
    for ts, _, addressed in heard:
        nxt = next((t for t in responses if t >= ts), None)
        if nxt is not None and nxt - ts < 300:
            lat_all.append(nxt - ts)
            if addressed:
                lat_addr.append(nxt - ts)

    def row(xs, unit="_s"):
        return {"n": len(xs), f"p50{unit}": round(pct(xs, 50), 2) if xs else None,
                f"p95{unit}": round(pct(xs, 95), 2) if xs else None,
                f"mean{unit}": round(statistics.mean(xs), 2) if xs else None}
    return {"log": str(path), "all_lines": row(lat_all), "answered_lines": row(lat_addr),
            "get_state_reads_before_each_tool": row([float(x) for x in turn_reads], unit=""),
            "prompt_cache_share": round(cached / prompt, 2) if prompt else None}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log", type=Path)
    ap.add_argument("--since")
    ap.add_argument("--until")
    a = ap.parse_args(argv)
    print(json.dumps(analyse(a.log, a.since, a.until), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())

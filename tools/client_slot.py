"""Client slot lock: one live tester at a time on Claude's client (PRINCIPLES #9).

    python -m tools.client_slot status
    python -m tools.client_slot take <owner> <minutes> [--why TEXT]   # exit 1 if someone else holds it
    python -m tools.client_slot release <owner>
    python -m tools.client_slot queue                                 # print the queue
    python -m tools.client_slot enqueue <owner> [--why TEXT]

The lock is advisory: every agent checks it before a live action and takes it for a bounded time.
An expired lock is free. State: logs/state/client_slot.json.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

STATE = Path(__file__).resolve().parents[1] / "logs" / "state" / "client_slot.json"


def _load() -> dict:
    try:
        return json.loads(STATE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"holder": None, "queue": []}


def _save(d: dict) -> None:
    STATE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(d, indent=1), encoding="utf-8")
    tmp.replace(STATE)


RESERVE_S = 180   # a handed-off owner must `take` within this, else the slot moves on to the next in line


def _handoff(d: dict, now: float) -> None:
    """Give a free slot to the next queued owner as a short reservation (no one waits for attention)."""
    while d.get("queue"):
        nxt = d["queue"].pop(0)
        d["holder"] = {"owner": nxt["owner"], "since": now, "until": now + RESERVE_S,
                       "why": nxt.get("why", ""), "reserved": True}
        return
    d["holder"] = None


def tick(d: dict, now: float) -> bool:
    """Expired holder or unclaimed reservation -> hand off. Returns True if the holder changed."""
    h = d.get("holder")
    if h and h.get("until", 0) > now:
        return False
    before = (h or {}).get("owner")
    _handoff(d, now)
    return (d.get("holder") or {}).get("owner") != before


def holder(d: dict, now: float | None = None) -> dict | None:
    h = d.get("holder")
    if h and h.get("until", 0) > (now or time.time()):
        return h
    return None


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    t = sub.add_parser("take"); t.add_argument("owner"); t.add_argument("minutes", type=float); t.add_argument("--why", default="")
    r = sub.add_parser("release"); r.add_argument("owner")
    sub.add_parser("queue")
    sub.add_parser("tick")
    e = sub.add_parser("enqueue"); e.add_argument("owner"); e.add_argument("--why", default="")
    a = ap.parse_args(argv)
    d, now = _load(), time.time()
    if tick(d, now):
        _save(d)
    h = holder(d, now)
    if a.cmd == "status":
        print(json.dumps({"holder": h, "free": h is None, "queue": d.get("queue", [])}))
        return 0
    if a.cmd == "take":
        if h and h["owner"] != a.owner:
            print(json.dumps({"ok": False, "held_by": h["owner"], "until_s": round(h["until"] - now), "why": h.get("why")}))
            return 1
        d["holder"] = {"owner": a.owner, "since": now, "until": now + a.minutes * 60, "why": a.why}
        d["queue"] = [q for q in d.get("queue", []) if q["owner"] != a.owner]
        _save(d)
        print(json.dumps({"ok": True, "until_s": round(a.minutes * 60)}))
        return 0
    if a.cmd == "release":
        if h and h["owner"] == a.owner:
            d["holder"] = None
            _handoff(d, now)
            _save(d)
        print(json.dumps({"ok": True, "holder": d.get("holder")}))
        return 0
    if a.cmd == "enqueue":
        q = d.get("queue", [])
        pos = next((i for i, x in enumerate(q) if x["owner"] == a.owner), None)
        if pos is None:   # already queued: keep the place (re-enqueueing must not send you to the back)
            q.append({"owner": a.owner, "why": a.why, "at": now})
            pos = len(q) - 1
        d["queue"] = q
        _save(d)
        print(json.dumps({"ok": True, "position": pos + 1}))
        return 0
    if a.cmd == "tick":
        print(json.dumps({"holder": d.get("holder"), "queue": d.get("queue", [])}))
        return 0
    print(json.dumps(d.get("queue", [])))
    return 0


if __name__ == "__main__":
    sys.exit(main())

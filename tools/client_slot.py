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
    e = sub.add_parser("enqueue"); e.add_argument("owner"); e.add_argument("--why", default="")
    a = ap.parse_args(argv)
    d, now = _load(), time.time()
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
            _save(d)
        nxt = (d.get("queue") or [None])[0]
        print(json.dumps({"ok": True, "next": nxt}))
        return 0
    if a.cmd == "enqueue":
        q = [x for x in d.get("queue", []) if x["owner"] != a.owner] + [{"owner": a.owner, "why": a.why, "at": now}]
        d["queue"] = q
        _save(d)
        print(json.dumps({"ok": True, "position": len(q)}))
        return 0
    print(json.dumps(d.get("queue", [])))
    return 0


if __name__ == "__main__":
    sys.exit(main())

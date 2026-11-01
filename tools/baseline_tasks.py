"""Per-task metrics for one player from the server recorder, segmented by his chat markers ("start <task>" ... "done").

Luis's human-baseline run (2026-11-01 12:36-13:21Z) is the reference: run this over it to get the bars, and over a
Claude run (same markers, or task windows from a brain log) to compare. Metrics come from the dev server's read-only
recorder (tools/recorder_motion.py: 5 Hz pose, inventory deltas, action RPCs attributed to a player).

    .venv\\Scripts\\python.exe -m tools.baseline_tasks --player luisdeburnaybast \\
        --rec logs\\recorder\\rec_20261101T123634Z.jsonl --chat client_io\\events\\chat.jsonl \\
        --json evals\\baselines\\luis_20261101_tasks.json
"""
from __future__ import annotations

import argparse
import gzip
import json
import math
import re
from collections import Counter
from pathlib import Path

from tools import recorder_motion as rm

END_RX = re.compile(r"^\s*\(?\s*(done|sone|stop|wstop|wdstop)\b", re.I)
START_RX = re.compile(r"^\s*start\s+(.+?)\s*$", re.I)
TELEPORT_M = 15.0   # a jump this far between two 0.2 s samples is a teleport (lodestone, astral projection), not travel
# typos in the 2026-11-01 run's markers, and his own renames ("the above was start hunt"); the said text is kept too
NAMES = {"pickuip cabbage": "pick up cabbage", "make bowq": "make bow", "made thread": "make thread",
         "more farmign": "more farming", "get food": "hunt (kebbits)"}


def _open(path: Path):
    return gzip.open(path, "rt", encoding="utf-8") if path.suffix == ".gz" else open(path, encoding="utf-8")


def chat_lines(path: Path, player: str, lo: float, hi: float) -> list[dict]:
    out = []
    with _open(path) as f:
        for line in f:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("from") == player and r.get("text") and lo <= float(r.get("ts", 0)) <= hi:
                out.append({"ts": float(r["ts"]), "text": r["text"]})
    return sorted(out, key=lambda r: r["ts"])


def segment(lines: list[dict]) -> list[dict]:
    """start ... (first end marker | next start). Every other line inside a task is a note on it."""
    tasks, cur = [], None
    for ln in lines:
        m = START_RX.match(ln["text"])
        if m:
            if cur:
                cur.update(end=ln["ts"], ended_by="next start")
                tasks.append(cur)
            said = m.group(1).lower()
            cur = {"name": NAMES.get(said, said), "said": m.group(1), "start": ln["ts"], "notes": []}
        elif cur and END_RX.match(ln["text"]):
            cur.update(end=ln["ts"], ended_by=ln["text"])
            tasks.append(cur)
            cur = None
        elif cur:
            cur["notes"].append(ln["text"])
        elif tasks:  # a note after a task ended belongs to that task ("the above was start hunt")
            tasks[-1]["notes"].append(ln["text"])
    if cur:
        cur.update(end=lines[-1]["ts"], ended_by="end of log")
        tasks.append(cur)
    return tasks


def _item(k: str) -> str:
    return re.sub(r"^ITEM_(Resources_|Consumable_|Tools_|Ammo_)?", "", k)


def task_metrics(rec: rm.Recording, player: str, t: dict) -> dict:
    lo, hi = t["start"], t["end"]
    poses = [x for x, a, b in rec._samples(player, lo, hi)]
    travel = teleports = 0.0
    for p, q in zip(poses, poses[1:]):
        d = math.dist(p.p[:2], q.p[:2])
        if d > TELEPORT_M:
            teleports += 1
        else:
            travel += d
    mo = rec.motion(player, lo, hi)
    stands = rec.idle_segments(player, lo, hi, min_s=2.0)
    presses = rec.presses(player, lo, hi)
    moving_presses = 0
    for p in presses:
        pose = rec.pose_at(player, p.ts)
        if pose and pose.v >= rm.V_MIN:
            moving_presses += 1
    first_move = next((x.ts for x in poses if x.v >= rm.V_MIN), None)
    first_press = presses[0].ts if presses else None
    firsts = [x for x in (first_move, first_press) if x is not None]
    rpcs = Counter(r["rpc"] for r in rec.rpcs if r.get("player") == player and lo <= r["ts"] <= hi)
    gained, spent = Counter(), Counter()
    for ts, delta in rec.inv.get(player) or []:
        if lo <= ts <= hi:
            for k, n in delta.items():
                (gained if n > 0 else spent)[_item(k)] += abs(n)
    hps = [x.hp for x in poses if x.hp is not None]
    return {
        "name": t["name"], "said": t["said"], "start": round(lo, 2), "end": round(hi, 2), "duration_s": round(hi - lo, 1),
        "ended_by": t["ended_by"], "notes": t["notes"],
        "first_action_s": round(min(firsts) - lo, 1) if firsts else None,
        "travel_m": round(travel), "teleports": int(teleports),
        "moving_s": mo["moving_s"], "standing_s": mo["standing_s"],
        "longest_stand_s": max((s.s for s in stands), default=0.0),
        "stands_over_5s": [{"s": s.s, "presses": s.presses} for s in stands if s.s >= 5],
        "interact": {"presses": len(presses), "hit": sum(p.outcome == "hit" for p in presses),
                     "changed": sum(p.outcome == "changed" for p in presses),
                     "no_change": sum(p.outcome == "miss" for p in presses), "while_moving": moving_presses,
                     "targets": dict(Counter(re.sub(r"_C$", "", p.target_class or "?") for p in presses).most_common(8))},
        "rpcs": dict(rpcs),
        "gained": dict(gained.most_common()), "spent": dict(spent.most_common()),
        "hp": [min(hps), max(hps)] if hps else None,
    }


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--player", required=True)
    ap.add_argument("--rec", required=True, nargs="+", type=Path)
    ap.add_argument("--chat", required=True, type=Path)
    ap.add_argument("--json", type=Path)
    a = ap.parse_args(argv)
    rec = rm.load(*a.rec)
    lo = min(x.ts for tr in rec.tracks.values() for x in tr[:1])
    hi = max(x.ts for tr in rec.tracks.values() for x in tr[-1:])
    tasks = [task_metrics(rec, a.player, t) for t in segment(chat_lines(a.chat, a.player, lo, hi))]
    out = {"player": a.player, "recordings": [str(p) for p in a.rec], "chat": str(a.chat),
           "method": "tools/baseline_tasks.py: chat markers 'start X' .. first done/stop (or the next start); "
                     "server recorder 5 Hz pose (standing = v < 0.3 m/s), inventory deltas, attributed RPCs; an "
                     "interact with no inventory change in 1.5 s is no_change (opening a station or UI counts too)",
           "tasks": tasks}
    if a.json:
        a.json.parent.mkdir(parents=True, exist_ok=True)
        a.json.write_text(json.dumps(out, indent=1, ensure_ascii=False), encoding="utf-8")
    for t in tasks:
        i = t["interact"]
        print(f"{t['name'][:28]:28} {t['duration_s']:6.1f}s first {t['first_action_s']}s travel {t['travel_m']:4}m "
              f"tp {t['teleports']} move {t['moving_s']:5.1f} stand {t['standing_s']:5.1f} (max {t['longest_stand_s']}) "
              f"E {i['presses']}/{i['hit']}h/{i['no_change']}n mv{i['while_moving']} rpcs {t['rpcs']} "
              f"+{dict(list(t['gained'].items())[:4])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

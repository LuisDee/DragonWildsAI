"""Maintenance for evals/voice_cases.jsonl (Eval agent, 2026-10-26; main's voice-eval findings c and d).

  refresh-truncated: a case whose logged situation truncated the bag ("Carrying: ... +16 more") hid items the
      decision depends on (h5: a pickaxe). For each such case, the LAST full get_state the live brain received
      before the case's moment (bridge_recv in the case's source log) is replayed through the CURRENT perception
      (brain.situation.summary, which has the "Spare gear:" line) and served as the case's situation; the full
      inventory is also served as the replay's logged `inventory` read.
  redraw-heldout: a fresh held-out split (seeded, recorded in each case) excluding cases an agent has read.

  .venv\\Scripts\\python.exe -m evals.voice_fixtures refresh-truncated
  .venv\\Scripts\\python.exe -m evals.voice_fixtures redraw-heldout --exclude h4_overhead_chop_tip,h5_have_pickaxe_q --seed 20261026
"""
from __future__ import annotations

import argparse
import json
import random
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from brain import situation  # noqa: E402

CASES = ROOT / "evals" / "voice_cases.jsonl"
TRUNC = re.compile(r"\+\d+ more")


def read(path: Path = CASES) -> list[dict]:
    return [json.loads(ln) for ln in path.read_text(encoding="utf-8").splitlines() if ln.strip()]


def write(cases: list[dict], path: Path = CASES) -> None:
    path.write_text("".join(json.dumps(c, ensure_ascii=False) + "\n" for c in cases), encoding="utf-8")


def case_epoch(case: dict) -> float | None:
    m = re.search(r"(\d{8})-\d{6}", str(case.get("source") or ""))
    if not m or not case.get("at_utc"):
        return None
    d = datetime.strptime(m.group(1) + " " + case["at_utc"], "%Y%m%d %H:%M:%S").replace(tzinfo=timezone.utc)
    return d.timestamp()


def last_state(log: Path, before: float) -> dict | None:
    best = None
    for ln in log.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            e = json.loads(ln)
        except ValueError:
            continue
        if e.get("kind") != "bridge_recv" or float(e.get("ts") or 0) > before:
            continue
        data = ((e.get("msg") or {}).get("data")) if isinstance(e.get("msg"), dict) else None
        if isinstance(data, dict) and isinstance(data.get("inventory"), dict):
            best = data
    return best


def truncated(case: dict) -> bool:
    return any(isinstance(s, str) and s.startswith("Carrying:") and TRUNC.search(s)
               for s in case.get("context", {}).get("situation") or [])


def refresh_truncated(cases: list[dict], root: Path = ROOT) -> list[str]:
    done = []
    for c in cases:
        if not truncated(c):
            continue
        t = case_epoch(c)
        log = root / str(c.get("source") or "")
        st = last_state(log, t) if t and log.exists() else None
        if not st:
            done.append(f"{c['id']}: no logged state before {c.get('at_utc')} in {c.get('source')} (left as is)")
            continue
        ctx = c["context"]
        ctx["situation"] = situation.summary(st, active_goal=ctx.get("active_goal"), looks_supported=True)
        reads = [r for r in c.get("reads") or [] if r.get("tool") != "inventory"]
        reads.append({"tool": "inventory", "args": {}, "result": {"ok": True, "reason": None, "data": {
            "inventory": st["inventory"], "equipment": st.get("equipment") or st.get("gear"),
            "note": "replay: the full bag from the last get_state the live brain had (voice_fixtures.py)"}}})
        c["reads"] = reads
        c["fixture_refresh"] = {"what": "situation re-rendered by current perception from the logged state; full "
                                        "inventory served as the inventory read",
                                "state_from": c.get("source"), "date": "2026-10-26"}
        done.append(f"{c['id']}: situation re-rendered ({len(ctx['situation'])} lines), inventory read added")
    return done


def redraw_heldout(cases: list[dict], exclude: set[str], n: int, seed: int) -> list[str]:
    pool = sorted(c["id"] for c in cases if c["id"] not in exclude)
    pick = set(random.Random(seed).sample(pool, n))
    for c in cases:
        c["split"] = "held_out" if c["id"] in pick else "seen"
        c["split_drawn"] = {"seed": seed, "date": "2026-10-26", "excluded_as_read": sorted(exclude)}
    return sorted(pick)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("refresh-truncated")
    r = sub.add_parser("redraw-heldout")
    r.add_argument("--exclude", default="")
    r.add_argument("--n", type=int, default=6)
    r.add_argument("--seed", type=int, required=True)
    a = ap.parse_args(argv)
    cases = read()
    if a.cmd == "refresh-truncated":
        for line in refresh_truncated(cases):
            print(line)
    else:
        print("held out:", redraw_heldout(cases, {x for x in a.exclude.split(",") if x}, a.n, a.seed))
    write(cases)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""How true is the fight-odds line? Every reflex fight in the brain logs: what the odds said at its start
(combat_started: verdict, est_s_to_kill / est_s_to_die, and since 2026-11-18 the bands est_kill / est_die) against
what the fight did (combat_end: dur_s or fight_s, damage dealt / taken, pack, outcome).

  .venv\\Scripts\\python.exe -m tools.fight_odds_truth                 # logs of 16-18 Nov
  .venv\\Scripts\\python.exe -m tools.fight_odds_truth --glob "logs/brain-live-20261119-*.jsonl"
  .venv\\Scripts\\python.exe -m tools.fight_odds_truth --replay         # also the calibrated model on the same fights

Truth per fight: engaged seconds = fight_s when the body sent it, else dur_s - 0.6 s reaction - 6.2 s loot when it
killed (median loot phase of 90 attack results); time to die = dur_s when he died, else his HP / intake when he took
at least 24 (two hits), else unknown; time to kill = engaged seconds when every hostile died, else extrapolated from
his damage rate. Error = median |ln(estimate / real)|, said as a factor. --replay applies combat.assess's calibrated
formula (constants read from client_mod/scripts/combat.lua cfg.odds_*) with the end-of-fight pack as the hostiles
counted (the body counts those within aggro range at the start).
"""
from __future__ import annotations

import argparse
import glob
import json
import math
import re
import statistics as st
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
LOOT_S, REACT_S = 6.2, 0.6
# his hit / press cadence per weapon as the logs show it (learned hits: 48/hit sword one-shots a 50 HP rat; club 5
# presses, dagger ~5, a punch 8.2 of 11 presses), for --replay only
NOMINAL = {"Bronze Sword": 50 / 0.86, "Stone Club": 10 / 1.045, "Stone Dagger": 10 / 0.772, "bare hands": 8.2 / 0.9}


def fights(pattern: str) -> list[dict]:
    out = []
    for f in sorted(glob.glob(str(REPO / pattern) if not Path(pattern).is_absolute() else pattern)):
        starts, ends = {}, {}
        for line in open(f, encoding="utf-8", errors="replace"):
            if '"combat_' not in line:
                continue
            try:
                r = json.loads(line)
            except ValueError:
                continue
            e = r.get("event") if r.get("kind") == "event" else None
            if not isinstance(e, dict):
                continue
            if e.get("kind") == "combat_started":
                starts.setdefault(e.get("act") or e.get("target_id"), e)
            elif e.get("kind") == "combat_end":
                ends.setdefault(e.get("act") or (e.get("target_id"), e.get("ts")), e)
        for k, e in ends.items():
            out.append({"file": Path(f).name, "start": starts.get(k), "end": e})
    return out


def bestiary():
    b = json.loads((REPO / "data/bestiary.json").read_text(encoding="utf-8"))["creatures"]
    hp, dmg = {}, {}
    for k, v in b.items():
        rows = [x for x in v.get("variants") or [] if str(x.get("health", "")).isdigit()]
        if rows:
            hp[k] = int(rows[0]["health"])
        ds = [x for a in v.get("game_attacks") or [] for x in a.get("damage") or [] if x]
        if ds:
            dmg[k] = sum(ds) / len(ds)
    return hp, dmg


def truth(f: dict, hp_of: dict) -> dict | None:
    s, e = f["start"] or {}, f["end"]
    if e.get("outcome") == "interrupted" or (e.get("dur_s") or 0) < 2:
        return None
    out, dur = e.get("outcome"), e.get("dur_s") or 0
    eng = e.get("fight_s") or max(dur - REACT_S - (LOOT_S if out == "killed" else 0), 1.0)
    pack, taken, dealt, kills = e.get("pack") or 1, e.get("damage_taken") or 0, e.get("damage_dealt") or 0, e.get("kills") or 0
    name = e.get("target")
    one = hp_of.get(name, 60)
    total = (s.get("target_hp") or one) + (pack - 1) * one
    hp0 = s.get("hp") or 100
    die = dur if out == "died" else (hp0 * eng / taken if taken >= 24 else None)
    if out == "killed" and (kills >= pack or pack == 1):
        kill = eng
    elif dealt > 0:
        kill = total * eng / max(kills * one if kills else dealt, dealt)
    else:
        kill = None
    return {"file": f["file"], "target": name, "weapon": s.get("weapon"), "verdict": s.get("verdict"), "out": out,
            "eK": s.get("est_s_to_kill"), "eD": s.get("est_s_to_die"), "bK": s.get("est_kill"), "bD": s.get("est_die"),
            "kill": kill, "die": die, "pack": pack, "hp0": hp0, "total": total, "taken": taken, "eng": eng}


def cfg_constants() -> dict:
    src = (REPO / "client_mod/scripts/combat.lua").read_text(encoding="utf-8")
    c = {k: float(v) for k, v in re.findall(r"(odds_[a-z0-9_]+) = ([\d.]+)", src)}
    for k in ("odds_kill_band", "odds_die_band"):
        m = re.search(k + r" = \{ ([\d.]+), ([\d.]+) \}", src)
        c[k] = (float(m.group(1)), float(m.group(2)))
    return c


def replay(t: dict, c: dict, dmg: dict):
    nom = NOMINAL.get(t["weapon"])
    rate = nom * (c["odds_uptime_hands"] if t["weapon"] == "bare hands" else c["odds_uptime"]) if nom else None
    kill = c["odds_t0_s"] + t["total"] * t["pack"] ** c["odds_pack_slow"] / rate if rate else None
    d = dmg.get(t["target"])
    die = t["hp0"] / (t["pack"] * d * c["odds_landed_per_s"]) if d else None
    verdict = None
    if kill and die:
        kb, db = c["odds_kill_band"], c["odds_die_band"]
        verdict = ("likely_win" if kill * kb[1] < die * db[0] else "likely_lose" if kill * kb[0] > die * db[1] else "uncertain")
    elif kill:
        verdict = "unknown"
    return kill, die, verdict


def err(pairs) -> tuple[float, int]:
    v = [abs(math.log(p / a)) for p, a in pairs if p and a and p > 0 and a > 0]
    return (math.exp(st.median(v)), len(v)) if v else (float("nan"), 0)


def med(v):
    v = [x for x in v if x]
    return f"{st.median(v):7.0f}" if v else "      -"


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--glob", default="logs/brain-live-2026111[678]-*.jsonl")
    ap.add_argument("--replay", action="store_true")
    a = ap.parse_args(argv)
    hp_of, dmg = bestiary()
    rows = [t for f in fights(a.glob) if f["start"] for t in [truth(f, hp_of)] if t]
    c = cfg_constants() if a.replay else None
    print(f"{len(rows)} reflex fights with the odds said at their start ({a.glob})")
    print(f"{'weapon':14} {'n':>3} {'said kill':>9} {'real kill':>9} {'said die':>8} {'real die':>8} {'n die':>5} deaths"
          + ("   new kill  new die" if c else ""))
    by = defaultdict(list)
    for t in rows:
        by[t["weapon"]].append(t)
    for w, rs in sorted(by.items(), key=lambda x: -len(x[1])):
        dk = [t for t in rs if t["die"]]
        line = (f"{str(w)[:14]:14} {len(rs):3} {med([t['eK'] for t in rs if t['kill']]):>9} {med([t['kill'] for t in rs]):>9}"
                f" {med([t['eD'] for t in dk]):>8} {med([t['die'] for t in dk]):>8} {len(dk):5} {sum(t['out'] == 'died' for t in rs):6}")
        if c:
            line += f" {med([replay(t, c, dmg)[0] for t in rs if t['kill']]):>9} {med([replay(t, c, dmg)[1] for t in dk]):>8}"
        print(line)
    ek, ed = err((t["eK"], t["kill"]) for t in rows), err((t["eD"], t["die"]) for t in rows)
    print(f"said line error: kill x{ek[0]:.2f} (n={ek[1]}), die x{ed[0]:.2f} (n={ed[1]})")
    banded = [t for t in rows if t["bD"] or t["bK"]]
    if banded:  # fights since the calibrated odds: does the truth fall inside the band said?
        def inside(band, real):
            m = re.match(r"(?:about )?(\d+)(?:-(\d+))? s", band or "")
            if not (m and real):
                return None
            lo, hi = float(m.group(1)), float(m.group(2) or m.group(1))
            return lo <= real <= hi or (band.endswith("over 10 min") and real >= lo)
        bk = [x for x in (inside(t["bK"], t["kill"]) for t in banded) if x is not None]
        bd = [x for x in (inside(t["bD"], t["die"]) for t in banded) if x is not None]
        print(f"banded lines: {len(banded)}; real kill inside the band {sum(bk)}/{len(bk)}, real die inside {sum(bd)}/{len(bd)}")
    vt = defaultdict(int)
    for t in rows:
        vt[(t["verdict"], t["out"])] += 1
    print("said verdict x outcome:", ", ".join(f"{v}/{o}: {n}" for (v, o), n in sorted(vt.items(), key=str)))
    if c:
        nk = err((replay(t, c, dmg)[0], t["kill"]) for t in rows)
        nd = err((replay(t, c, dmg)[1], t["die"]) for t in rows)
        print(f"calibrated model on the same fights: kill x{nk[0]:.2f} (n={nk[1]}), die x{nd[0]:.2f} (n={nd[1]})")
        nv = defaultdict(int)
        for t in rows:
            nv[(replay(t, c, dmg)[2], t["out"])] += 1
        print("calibrated verdict x outcome:", ", ".join(f"{v}/{o}: {n}" for (v, o), n in sorted(nv.items(), key=str)))


if __name__ == "__main__":
    main()

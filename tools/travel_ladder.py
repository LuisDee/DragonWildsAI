"""Rung-1 travel ladder (docs/PLAN-2026-10-31.md): fixed dev-world journeys, body only, no model calls.

  .venv\\Scripts\\python.exe -m tools.travel_ladder                     # all journeys, label "run"
  .venv\\Scripts\\python.exe -m tools.travel_ladder --label baseline
  .venv\\Scripts\\python.exe -m tools.travel_ladder --only ramp_up,ramp_down --repeat 2
  .venv\\Scripts\\python.exe -m tools.travel_ladder --list

Each journey: the dev `teleport` fixture puts Claude at a fixed start (server K2_TeleportTo, mod/bench/fixtures.lua),
he settles, then ONE bridge go_to (debug channel) to the goal, exactly as the brain would send it. A second
bridge client samples `me` every SAMPLE_S for the path. Success = the body answered ok AND the fresh end position
is within 3 m (2D) and 1.8 m (height) of the goal. Metrics follow the embodied-navigation convention (Anderson et
al. 2018, arXiv 1807.06757): success rate, SPL (success x straight / max(straight, walked)) and distance to goal
at the end, plus seconds and metres walked. If the body wrote a trip record (client_io/events/trips.jsonl) for the
command, its sentence is printed too.

Refuses unless the client is on the local dev server and the live brain is not running (DevTarget.guard).
Rows are appended to logs/evals/travel_ladder.jsonl (one per journey, then one summary row per run).
Starts/goals are capsule-centre positions where Claude has stood (logs 2026-10-31) or landmark spots
(data/places_26161880.json).
"""
import argparse
import json
import math
import subprocess
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "logs" / "evals" / "travel_ladder.jsonl"
TRIPS = ROOT / "client_io" / "events" / "trips.jsonl"
SAMPLE_S = 1.0
GO_TO_WAIT_S = 420.0  # the body's own deadline decides; this only catches a hung bridge
ARRIVE_M, ARRIVE_DZ = 3.0, 1.8

# capsule-centre metres [x, y, z]. Landmark goals are data/places_26161880.json positions (ground) + 0.88 m.
P = {
    "lodestone": [50.65, 1890.26, -34.92],   # church lodestone / respawn, lower floor (inside)
    "doorway": [88.77, 1852.10, -31.46],     # church doorway level
    "east_stone": [181.73, 1815.94, -28.99], # built lodestone EDDE
    "zanik": [265.48, 1824.27, -41.21],      # Zanik, Temple Woods (landmark; stood there at boot)
    "southeast": [249.91, 1790.78, -39.79],  # open ground SE (stood there 20:10)
    "plateau": [442.55, 1836.54, -14.70],    # grave plateau (seed route grave_hill_up end, feet -15.62)
    "doric": [109.08, 1846.32, -31.31],      # landmark
    "vannaka": [151.83, 1788.53, -26.34],    # landmark
    "pond_south": [155.18, 1914.83, -30.47], # learned water stand (feet -31.37), pond NE of the church
    "astral_vent": [277.44, 1814.37, -41.25],  # landmark Astral Anima Vent (Temple Woods), 36 m from southeast
    "earth_vent": [449.69, 1838.51, -15.52],   # landmark Earth Anima Vent on the plateau, 7 m from plateau
    "water_vent": [161.90, 1927.94, -30.47],   # landmark Water Anima Vent by the pond, 15 m past pond_south
}
# What a player would say for each goal (chat_ladder asks for it in chat). Every goal is a named landmark or the
# temple's lodestone/entrance, so both halves of rung 1 run the same 10 journeys.
PLACE = {"lodestone": "the temple lodestone", "doorway": "the temple entrance", "zanik": "Zanik", "doric": "Doric",
         "vannaka": "Vannaka", "astral_vent": "the Astral Anima Vent", "earth_vent": "the Earth Anima Vent",
         "water_vent": "the Water Anima Vent"}


def _j(name, a, b, note):
    return {"id": name, "from": a, "to": b, "start": P[a], "goal": P[b], "place": PLACE.get(b, ""), "kind": note,
            "tol_m": ARRIVE_M}


# journeys v2 (21:55Z): far_doorway_se, uphill_plateau and around_water end on named landmarks (were open ground
# 7-36 m away) so they can be asked for in chat; rows before that carry the old goals.
JOURNEYS = [
    _j("near_doric", "doorway", "doric", "near, flat"),
    _j("near_vannaka", "east_stone", "vannaka", "near, slight rise"),
    _j("far_zanik_doorway", "zanik", "doorway", "far, to the church"),
    _j("far_doorway_se", "doorway", "astral_vent", "far, out of the church area"),
    _j("uphill_plateau", "zanik", "earth_vent", "far, uphill +26 m"),
    _j("downhill_plateau", "plateau", "zanik", "far, downhill"),
    _j("ramp_up", "lodestone", "doorway", "temple ramp up"),
    _j("ramp_down", "doorway", "lodestone", "temple ramp down"),
    _j("far_to_temple", "southeast", "lodestone", "far, into the church and down the ramp"),
    _j("around_water", "doorway", "water_vent", "straight line crosses the pond"),
]


def arrived(pos, goal, tol: float = ARRIVE_M) -> bool:
    """The ladder's success test on a fresh position: within tol (2D) and ARRIVE_DZ (height) of the goal."""
    return d2(pos, goal) <= tol and abs(pos[2] - goal[2]) <= ARRIVE_DZ


def d2(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1])


def d3(a, b):
    return math.sqrt((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2)


SEND_LOCK = threading.Lock()


def client():
    """A bridge client on the debug channel. The go_to client and the sampler append to ONE file: on Windows two
    handles appending at once clobber each other (live 20:19: the go_to line was overwritten by a `me`), so every
    send in this process holds SEND_LOCK."""
    from brain.bridge_client import BridgeClient
    from brain.transport import file_transport_pair
    tr = file_transport_pair(body="client", channel="debug")[0]
    raw = tr.send

    def send(msg):
        with SEND_LOCK:
            raw(msg)
    tr.send = send
    return BridgeClient(tr)


def position(c):
    r = c.request("me", {}, timeout=10)
    p = ((r or {}).get("data") or {}).get("position") if isinstance(r, dict) and r.get("ok") else None
    return [float(x) for x in p] if p and len(p) == 3 else None


def head() -> str:
    try:
        return subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    except OSError:
        return ""


def trip_for(t0: float, t1: float) -> dict | None:
    """The body's trip record for this go_to, if it wrote one (fix 2)."""
    if not TRIPS.exists():
        return None
    best = None
    for line in TRIPS.read_text(encoding="utf-8", errors="replace").splitlines()[-50:]:
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        ts = r.get("ts")
        if isinstance(ts, (int, float)) and t0 - 2 <= ts <= t1 + 5 and r.get("mode") == "go_to":
            best = r
    return best


def place(dev, c, start, tries=3, harness_brain=False):
    """Teleport (dev fixture) to start and wait until he stands still there. harness_brain=True: the caller runs the
    brain itself (chat_ladder --start-brain), so a running run_live is expected; the dev-server checks still apply."""
    if harness_brain:
        saved, dev.brain_running = dev.brain_running, (lambda: False)
        try:
            return place(dev, c, start, tries)
        finally:
            dev.brain_running = saved
    last = None
    for _ in range(tries):
        res = dev.setup("teleport", purpose="travel ladder start", at=start)
        if not res.get("ok"):
            raise RuntimeError(f"teleport fixture failed: {res}")
        t_end = time.monotonic() + 10
        last = None
        while time.monotonic() < t_end:
            time.sleep(1.0)
            p = position(c)
            if p and d2(p, start) < 3 and last and d3(p, last) < 0.1:
                time.sleep(1.0)  # settle: grounded, the move state sees the new spot
                return p
            last = p
    raise RuntimeError(f"could not place Claude at {start} (last {last})")


def run_journey(dev, j):
    name, a, b, note, start, goal = j["id"], j["from"], j["to"], j["kind"], j["start"], j["goal"]
    c, sampler = client(), client()
    c.request("stop", {}, timeout=10)
    s = place(dev, c, start)
    samples, stop = [(time.time(), s)], threading.Event()

    def sample():
        while not stop.is_set():
            p = position(sampler)
            if p:
                samples.append((time.time(), p))
            stop.wait(SAMPLE_S)

    th = threading.Thread(target=sample, daemon=True)
    t0 = time.time()
    th.start()
    r = c.request("go_to", {"target": goal}, timeout=GO_TO_WAIT_S)
    t1 = time.time()
    stop.set()
    th.join(5)
    if (r or {}).get("reason") in ("lost_by_body", "body_restarted"):
        raise RuntimeError(f"bridge: {(r or {}).get('reason')}")  # the wire, not the walk
    end = position(c) or samples[-1][1]
    walked = sum(d3(samples[k - 1][1], samples[k][1]) for k in range(1, len(samples))
                 if d3(samples[k - 1][1], samples[k][1]) < 40)  # a respawn/teleport jump is not walking
    closest = min(d2(p, goal) for _, p in samples + [(t1, end)])
    straight = d3(s, goal)
    data = (r or {}).get("data") or {}
    reached = arrived(end, goal)
    ok = bool(r and r.get("ok")) and reached
    trip = trip_for(t0, t1)
    return {
        "journey": name, "note": note, "from": a, "to": b, "ok": ok, "body_ok": bool(r and r.get("ok")),
        "reason": (r or {}).get("reason"), "detail": data.get("detail"), "why": data.get("why"),
        "s": round(t1 - t0, 1), "straight_m": round(straight, 1), "walked_m": round(walked, 1),
        "end_dist_m": round(d2(end, goal), 1), "end_dz_m": round(end[2] - goal[2], 1), "closest_m": round(closest, 1),
        "spl": round(straight / max(straight, walked), 3) if ok else 0.0,
        "start": [round(x, 2) for x in s], "end": [round(x, 2) for x in end], "goal": goal,
        "trip": trip.get("sentence") if trip else None, "ts": round(t0, 1),
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", default="", help="comma-separated journey names")
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--label", default="run")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    js = [j for j in JOURNEYS if not a.only or j["id"] in a.only.split(",")]
    if a.list:
        for j in js:
            print(f"{j['id']:20s} {j['from']:>11s} -> {j['to']:<11s} {d3(j['start'], j['goal']):6.0f} m  {j['kind']}"
                  f"  ({j['place'] or 'no chat name'})")
        return
    from evals.bench.devrun import default_dev
    dev = default_dev()
    dev.guard()
    run_id = time.strftime("%Y%m%d-%H%M%S")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    rows = []
    for rep in range(a.repeat):
        for j in js:
            n = j["id"]
            try:
                row = run_journey(dev, j)
            except Exception as x:  # infra failure: recorded, not counted as a body failure
                row = {"journey": n, "from": j["from"], "to": j["to"], "ok": None, "error": repr(x), "ts": round(time.time(), 1)}
            row.update(run=run_id, label=a.label, head=head(), rep=rep)
            rows.append(row)
            with OUT.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(row) + "\n")
            mark = "ERR " if row.get("ok") is None else ("PASS" if row["ok"] else "FAIL")
            print(f"{mark} {n:20s} {row.get('s', 0):6.1f}s walked {row.get('walked_m', 0):6.1f}/{row.get('straight_m', 0):5.1f} m "
                  f"end {row.get('end_dist_m', '-')} m dz {row.get('end_dz_m', '-')}  {row.get('reason') or ''} "
                  f"{row.get('detail') or row.get('error') or ''}"[:220], flush=True)
            if row.get("trip"):
                print(f"     trip: {row['trip']}", flush=True)
    done = [r for r in rows if r.get("ok") is not None]
    n_ok = sum(1 for r in done if r["ok"])
    summary = {"summary": True, "run": run_id, "label": a.label, "head": head(), "n": len(done), "ok": n_ok,
               "success_rate": round(n_ok / len(done), 3) if done else None,
               "spl": round(sum(r["spl"] for r in done) / len(done), 3) if done else None,
               "s_total": round(sum(r["s"] for r in done), 1),
               "mean_end_dist_m": round(sum(r["end_dist_m"] for r in done) / len(done), 1) if done else None,
               "errors": len(rows) - len(done), "ts": round(time.time(), 1)}
    with OUT.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(summary) + "\n")
    print(f"\n{a.label}: {n_ok}/{len(done)} reached ({summary['success_rate']}), SPL {summary['spl']}, "
          f"{summary['s_total']} s, mean end distance {summary['mean_end_dist_m']} m, {summary['errors']} errors")


if __name__ == "__main__":
    main()

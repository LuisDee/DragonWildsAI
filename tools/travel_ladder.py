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

MOVEMENT LADDER (2026-11-01, co-play B5/B6/B7/B15/C2), judged against a human:
  * obstacle legs (kind "obstacle"): short go_tos past the log / rock / structure spots where co-play session 1 stuck
    him. Human time T_h = REACT_S + human_m / V_TRAVEL (Luis's measured baselines, data/baselines/luis-2026-11-01.json:
    reaction 1.5 s, travel 6.25 m/s); pass = reached and s <= 1.5 x T_h.
  * follow legs (`--follow`, ids follow_*): a GHOST LEADER replays a recorded human track (the dev recorder's 5 Hz
    positions of Luis, stored in data/ladder/ghost_tracks.json by `--extract-ghost`), capped at a sprinting player's
    6.8 m/s (Windstep bursts stretched in time) and followed with move.follow at 3 m (client_mod/scripts/ghost_leader.lua,
    commands move_ghost_follow / move_ghost_status). The ghost samples both positions at 10 Hz on one clock. Scores:
    share of samples within 6 m (bar 90 %), the longest stand (< 0.5 m/s while the leader moves or is > 6 m away; bar
    3 s), catch-up after the leader stops; the human bar is a model follower that walks the leader's own path 3 m behind
    with a 0.5 s reaction at <= 6.8 m/s, scored the same way.
    .venv\\Scripts\\python.exe -m tools.travel_ladder --extract-ghost follow_church_loop 13:01:23 13:02:12
    .venv\\Scripts\\python.exe -m tools.travel_ladder --follow [--only follow_church_loop]
"""
import argparse
import atexit
import contextlib
import json
import os
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
    "water_vent": [160.97, 1926.83, -30.72],   # beside the Water Anima Vent (landmark 161.90,1927.94 is inside the
    #   vent object: he climbed onto it, 21:58); this stand arrived twice (21:01, 21:51), 1.3 m from its centre
}
# What a player would say for each goal (chat_ladder asks for it in chat). Every goal is a named landmark or the
# temple's lodestone/entrance, so both halves of rung 1 run the same 10 journeys.
PLACE = {"lodestone": "the temple lodestone", "doorway": "the temple entrance", "zanik": "Zanik", "doric": "Doric",
         "vannaka": "Vannaka", "astral_vent": "the Astral Anima Vent", "earth_vent": "the Earth Anima Vent",
         "water_vent": "the Water Anima Vent"}


def _j(name, a, b, note, human_m=None):
    return {"id": name, "from": a, "to": b, "start": P[a], "goal": P[b], "place": PLACE.get(b, ""), "kind": note,
            "tol_m": ARRIVE_M, "human_m": human_m}


# the human standard (data/baselines/luis-2026-11-01.json constants and its travel family)
REACT_S, V_TRAVEL, H_RATIO = 1.5, 6.25, 1.5
V_SPRINT = 6.8          # a sprinting player (Luis's recorder: the steady top speed)
FOLLOW_M, FOLLOW_SHARE, STAND_S = 6.0, 0.9, 3.0
GHOSTS = ROOT / "data" / "ladder" / "ghost_tracks.json"
RECORDER = ROOT / "logs" / "recorder"


def human_s(j) -> float | None:
    return round(REACT_S + j["human_m"] / V_TRAVEL, 1) if j.get("human_m") else None


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
# Obstacle legs: where co-play session 1 (2026-11-01, logs/brain-live-20261101-115554-7128.jsonl) stuck him.
P.update({
    "log_east": [60.13, 1834.99, -30.44],    # 11:38:43 "you are walking into a log" (go_to Luis, 44 s for 59 m)
    "log_west": [9.03, 1805.8, -29.45],      # where he reached Luis at 11:39:30 (Luis's grave spot)
    "doric_tent": [111.19, 1842.91, -31.05], # 11:01:35 interact the Summon Shelter -> wedged 2 m short for 25 s
    "doric_ne": [116.5, 1850.5, -31.0],      # past the Doric structures (11:04-11:05 "jumped onto the tent")
    "wise_old_man": [62.56, 1873.66, -35.45],  # where he stood talking to the Wise Old Man (quests 17:20Z), temple pit
    # beside the Bramblemead Wise Old Man, on his platform 6 m above the ground (capsule centre; the floor is -35.3):
    # the way up is a switchback of two ramps east of the house (trace grid 18:16Z), not on the dev navmesh
    "bramblemead": [484.0, 1775.0, -34.4],
})
OBSTACLES = [
    _j("obstacle_log", "log_east", "log_west", "obstacle: a log on the floor, 59 m (co-play 11:38)", human_m=62),
    _j("obstacle_log_back", "log_west", "log_east", "obstacle: the same log, the other way", human_m=62),
    _j("obstacle_doric", "doric_tent", "doric_ne", "obstacle: round the Doric structures (co-play 11:02/11:05)", human_m=11),
    _j("obstacle_doric_back", "doric_ne", "doric_tent", "obstacle: the same, the other way", human_m=11),
    # quests 17:20Z: from the temple pit (a navmesh island on the dev oracle) out of the doorway and 400 m east; he
    # gave up "the walkable map ends 414 m short". human_m: pit -> doorway 34 m + doorway -> marker 403 m straight, +2 %
    _j("quest_bramblemead", "wise_old_man", "bramblemead", "obstacle: out of the temple pit, 434 m east, then up the ramps onto his platform (quests 17:20)", human_m=470),
]  # kept out of JOURNEYS: tools/chat_ladder.py asks JOURNEYS' goals in chat (Rung 1)


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
        try:
            res = dev.setup("teleport", purpose="travel ladder start", at=start)
        except Exception as x:  # the fixture refuses while another player is on the server: walk there instead
            if "other_players_connected" not in repr(x):
                raise
            res = {"ok": False, "walk": repr(x)}
        if not res.get("ok") and res.get("walk"):
            r = c.request("go_to", {"target": start, "tolerance": 1.0}, timeout=GO_TO_WAIT_S)
            p = position(c)
            if not (p and d2(p, start) < 3 and abs(p[2] - start[2]) < 1.8):
                raise RuntimeError(f"could not walk to the start {start} (teleport refused: a player is on): {r}")
            time.sleep(1.0)
            return position(c) or p
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


def reflex_busy(c, max_s=45.0) -> bool:
    """True if a reflex (a fight) held the pawn; waits up to max_s for it to let go. The ladder measures travel,
    so a fight in progress is waited out rather than counted as a walk refused."""
    held, t_end = False, time.monotonic() + max_s
    while time.monotonic() < t_end:
        o = (((c.request("arbiter_status", {}, timeout=10) or {}).get("data") or {}).get("owner")) or {}
        if o.get("level") != "reflex":
            return held
        held = True
        time.sleep(1.0)
    return held


def rested(dev, c, below: float = 0.5) -> float | None:
    """A rested start (dev fixture set_stat, like tools.supply's food and water): at endurance 0 he can't sprint and
    his jumps fail (live 17:26Z: follow_doric_pond 46 % within 6 m, stuck where the track hops), which measures
    exhaustion, not movement. Returns the endurance share found, after topping it up when under `below`."""
    st = (c.request("get_state", {}, timeout=30) or {}).get("data") or {}
    e = (st.get("survival") or {}).get("endurance")
    cur, mx = (e[0], e[1]) if isinstance(e, list) and len(e) >= 2 else (st.get("endurance"), st.get("endurance_max"))
    if not (isinstance(cur, (int, float)) and isinstance(mx, (int, float)) and mx > 0):
        return None
    if cur / mx < below:
        dev.setup("set_stat", purpose="travel ladder: a rested start", stat="endurance", value=float(mx))
    return round(cur / mx, 2)


def run_journey(dev, j):
    name, a, b, note, start, goal = j["id"], j["from"], j["to"], j["kind"], j["start"], j["goal"]
    c, sampler = client(), client()
    c.request("stop", {}, timeout=10)
    s = place(dev, c, start)
    if reflex_busy(c):  # a fight from the last journey (live 21:20: "busy: combat:reflex"): let it end, start again
        s = place(dev, c, start)
    rest0 = rested(dev, c)
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
    hs = human_s(j)
    return {
        "human_s": hs, "vs_human": round((t1 - t0) / hs, 2) if hs else None,
        "human_ok": (ok and (t1 - t0) <= H_RATIO * hs) if hs else None,
        "journey": name, "note": note, "from": a, "to": b, "ok": ok, "body_ok": bool(r and r.get("ok")), "endurance_at_start": rest0,
        "reason": (r or {}).get("reason"), "detail": data.get("detail"), "why": data.get("why"),
        "s": round(t1 - t0, 1), "straight_m": round(straight, 1), "walked_m": round(walked, 1),
        "end_dist_m": round(d2(end, goal), 1), "end_dz_m": round(end[2] - goal[2], 1), "closest_m": round(closest, 1),
        "spl": round(straight / max(straight, walked), 3) if ok else 0.0,
        "stand_s": longest_stand([(t, p) for t, p in samples] + [(t1, end)]),
        "start": [round(x, 2) for x in s], "end": [round(x, 2) for x in end], "goal": goal,
        "trip": trip.get("sentence") if trip else None, "ts": round(t0, 1),
    }


def longest_stand(samples, still_m: float = 0.3) -> float:
    """Longest stretch (s) of consecutive position samples that moved less than still_m each (standing still)."""
    best, run_t0 = 0.0, None
    for k in range(1, len(samples)):
        (ta, pa), (tb, pb) = samples[k - 1], samples[k]
        if d2(pa, pb) < still_m * max(tb - ta, 0.1):
            run_t0 = ta if run_t0 is None else run_t0
            best = max(best, tb - run_t0)
        else:
            run_t0 = None
    return round(best, 1)


# ------------------------------------------------------------------ follow legs: a ghost leader on a human track
def extract_ghost(name: str, t_from: str, t_to: str, who: str = "luisdeburnaybast", rec: str | None = None,
                  claude_back_m: float = 3.5) -> dict:
    """Cut a recorded human track (HH:MM:SS UTC window; the newest recorder file that has it) into a ghost track: seconds from
    0, centimetres, an air flag where he was falling (mode 3), re-timed so no step is faster than V_SPRINT (Windstep /
    dash bursts are stretched, not dropped). Claude's start is where the human stood claude_back_m before the window
    (on his own path, so it is walkable). Stored in data/ladder/ghost_tracks.json under `name`."""
    import datetime as dt
    hms = lambda ts: dt.datetime.fromtimestamp(ts, dt.UTC).strftime("%H:%M:%S")  # noqa: E731
    # the recorder rotates files (rec_<start>.jsonl): the newest file holding the window, not just the newest file
    for path in ([Path(rec)] if rec else sorted(RECORDER.glob("rec_*.jsonl"), reverse=True)):
        rows = []
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            if r.get("kind") == "pos" and r.get("who") == who:
                rows.append(r)
        sel = [r for r in rows if t_from <= hms(r["ts"]) <= t_to]
        if len(sel) >= 10:
            break
    else:
        raise SystemExit(f"fewer than 10 samples of {who} in {t_from}-{t_to} in any recorder file")
    before = [r for r in rows if r["ts"] < sel[0]["ts"]]
    start, acc = sel[0]["p"], 0.0
    for k in range(len(before) - 1, 0, -1):
        acc += d3(before[k]["p"], before[k - 1]["p"]) if d3(before[k]["p"], before[k - 1]["p"]) < 20 else 0
        if acc >= claude_back_m:
            start = before[k - 1]["p"]
            break
    track, t = [], 0.0
    for k, r in enumerate(sel):
        if k:
            step = d3(sel[k - 1]["p"], r["p"])
            t += max(r["ts"] - sel[k - 1]["ts"], step / V_SPRINT)
        track.append([round(t, 2), round(r["p"][0] * 100), round(r["p"][1] * 100), round(r["p"][2] * 100),
                      1 if r.get("mode") == 3 else 0])
    length = sum(d3(sel[k - 1]["p"], sel[k]["p"]) for k in range(1, len(sel)))
    g = {"name": name, "who": who, "window": [t_from, t_to], "recording": path.name, "claude_start": start,
         "duration_s": round(t, 1), "length_m": round(length, 1), "real_s": round(sel[-1]["ts"] - sel[0]["ts"], 1),
         "track": track}
    GHOSTS.parent.mkdir(parents=True, exist_ok=True)
    allg = json.loads(GHOSTS.read_text(encoding="utf-8")) if GHOSTS.exists() else {}
    allg[name] = g
    GHOSTS.write_text(json.dumps(allg, indent=0), encoding="utf-8")
    return g


def ghosts() -> dict:
    return json.loads(GHOSTS.read_text(encoding="utf-8")) if GHOSTS.exists() else {}


# The house-exit leg (main 2026-11-01 16:5xZ): Claude stands inside his own house on the dev base (two foundation cells,
# walls round, the door on the west edge of the south cell) and the leader walks out through the door and on along
# Luis's own recorded path past the base (follow_church_loop's tail, reversed). The door is a real door: when it is
# shut, Claude opens it as a player would. The human model walks the same path and spends DOOR_S at the door (a press
# on the way up to it and the swing; an assumption: Luis's baseline has no door). Positions: get_state.structures
# 16:50Z (door BP_T1_Door_C at 94.71, 1853.14; floor top -31.81 = centre -30.93). Speeds: 4.5 m/s inside the house
# (two 3 m rooms and a doorway), then V_TRAVEL.
DOOR_S = 1.0
HOUSE_EXIT = {"door": [94.71, 1853.14, -30.31], "claude_start": [96.21, 1850.2, -30.93],
              "path": [([96.21, 1851.6, -30.93], 4.5), ([96.21, 1853.14, -30.93], 4.5), ([94.71, 1853.14, -30.93], 4.5),
                       ([92.9, 1853.14, -30.91], 4.5), ([89.52, 1858.33, -30.89], V_TRAVEL),
                       ([92.62, 1861.62, -30.45], V_TRAVEL), ([96.96, 1863.28, -30.73], V_TRAVEL),
                       ([100.68, 1865.55, -30.69], V_TRAVEL)]}


def make_ghost(name: str, spec: dict, dt_s: float = 0.2) -> dict:
    """A ghost track along spec["path"] ([(xyz m, speed m/s to reach it)], the first point is the leader's start),
    sampled every dt_s like the recorder's tracks. spec["door"] marks a door on the way: the human model pauses
    DOOR_S where the path passes it, and the run first checks the door is still there."""
    pts = [p for p, _ in spec["path"]]
    track, t = [[0.0, round(pts[0][0] * 100), round(pts[0][1] * 100), round(pts[0][2] * 100), 0]], 0.0
    for k in range(1, len(pts)):
        a, b, v = pts[k - 1], pts[k], spec["path"][k][1]
        n = max(1, round(d3(a, b) / v / dt_s))
        for i in range(1, n + 1):
            u = i / n
            t += d3(a, b) / v / n
            track.append([round(t, 2)] + [round((a[j] + (b[j] - a[j]) * u) * 100) for j in range(3)] + [0])
    length = sum(d3(pts[k - 1], pts[k]) for k in range(1, len(pts)))
    g = {"name": name, "who": "synthetic", "window": ["-", "-"], "recording": None, "claude_start": spec["claude_start"],
         "duration_s": round(t, 1), "length_m": round(length, 1), "real_s": round(t, 1), "track": track}
    if spec.get("door"):
        g["door"] = spec["door"]
        s_door = min(range(len(pts)), key=lambda k: d2(pts[k], spec["door"]))
        g["pauses"] = [[round(sum(d3(pts[k - 1], pts[k]) for k in range(1, s_door + 1)), 2), DOOR_S]]
    GHOSTS.parent.mkdir(parents=True, exist_ok=True)
    allg = ghosts()
    allg[name] = g
    GHOSTS.write_text(json.dumps(allg, indent=0), encoding="utf-8")
    return g


def _pts(track):
    return [(p[0], (p[1] / 100, p[2] / 100, p[3] / 100)) for p in track]


def human_follower(track, delay_s: float, hold_s: float, dist_m: float = 3.0, react_s: float = 0.5,
                   dt_s: float = 0.1, start=None, pauses=None):
    """A model human follower: walks the leader's own path (the track), dist_m behind along it, reacting react_s late,
    at most V_SPRINT, waiting wait_s where the path passes each pause [(metres along the path, wait_s)] (a door).
    Returns rows like the ghost's samples: (el_s, ghost xyz, follower xyz) in metres."""
    todo, wait_end = sorted(pauses or []), None
    pts = _pts(track)
    cum = [0.0]
    for k in range(1, len(pts)):
        cum.append(cum[-1] + d3(pts[k - 1][1], pts[k][1]))

    def ghost_at(tt):
        tt = min(max(tt, 0.0), pts[-1][0])
        k = 0
        while k < len(pts) - 2 and pts[k + 1][0] < tt:
            k += 1
        (ta, a), (tb, b) = pts[k], pts[k + 1]
        u = (tt - ta) / (tb - ta) if tb > ta else 0.0
        return tuple(a[i] + (b[i] - a[i]) * u for i in range(3)), cum[k] + (cum[k + 1] - cum[k]) * u

    def along(s):
        k = 0
        while k < len(cum) - 2 and cum[k + 1] < s:
            k += 1
        seg = cum[k + 1] - cum[k]
        u = (s - cum[k]) / seg if seg > 0 else 0.0
        a, b = pts[k][1], pts[k + 1][1]
        return tuple(a[i] + (b[i] - a[i]) * u for i in range(3))

    lead0 = d3(start, pts[0][1]) if start else dist_m
    s_f, rows, el = -lead0, [], 0.0
    while el <= delay_s + pts[-1][0] + hold_s:
        g, _ = ghost_at(el - delay_s)
        _, s_seen = ghost_at(el - delay_s - react_s)
        want = s_seen - dist_m
        if wait_end is not None and el < wait_end:
            want = s_f
        if want > s_f:
            s_f = min(want, s_f + V_SPRINT * dt_s)
            if todo and s_f >= todo[0][0]:
                s_f, wait_end = todo[0][0], el + todo[0][1]
                todo.pop(0)
        f = along(max(s_f, 0.0)) if s_f >= 0 else (start or pts[0][1])
        rows.append((round(el, 2), g, f))
        el += dt_s
    return rows


def score_follow(rows, delay_s: float, dur_s: float, hold_s: float) -> dict:
    """rows = (el_s, ghost (x,y,z) m, claude (x,y,z) m). Within-6 m share over the leader's walk and hold; the longest
    stand while he should be moving (< 0.5 m/s while the leader moves > 1 m/s or is > 6 m away); catch-up after the
    leader stopped (s until within 4 m); max gap."""
    win = [r for r in rows if delay_s <= r[0] <= delay_s + dur_s + hold_s]
    if len(win) < 5:
        return {"samples": len(win)}
    within = sum(1 for _, g, c in win if d3(g, c) <= FOLLOW_M) / len(win)

    def speed(k, idx):
        j = max(0, k - 5)  # ~0.5 s window at 10 Hz
        dtt = win[k][0] - win[j][0]
        return d2(win[k][idx], win[j][idx]) / dtt if dtt > 0 else 0.0
    stand, run0 = 0.0, None
    for k in range(len(win)):
        el, g, c = win[k]
        should = speed(k, 1) > 1.0 or d3(g, c) > FOLLOW_M
        if should and speed(k, 2) < 0.5:
            run0 = el if run0 is None else run0
            stand = max(stand, el - run0)
        else:
            run0 = None
    t_end = delay_s + dur_s
    catch = next((el - t_end for el, g, c in win if el >= t_end and d3(g, c) <= 4.0), None)
    return {"samples": len(win), "within_6m": round(within, 3), "longest_stand_s": round(stand, 1),
            "catch_up_s": round(catch, 1) if catch is not None else None,
            "max_gap_m": round(max(d3(g, c) for _, g, c in win), 1),
            "end_gap_m": round(d3(win[-1][1], win[-1][2]), 1)}


def within_human(rows, h_rows, delay_s: float, dur_s: float, hold_s: float) -> float | None:
    """Share of Claude's samples (leader's walk and hold) no further behind than max(FOLLOW_M, the human model's gap at
    that moment + 1 m): the 6 m bar where a human could keep it, the human's own gap where he could not (at equal
    sprint speed a perfect follower's gap peaks at 6.4 m after each of the leader's starts)."""
    win = [r for r in rows if delay_s <= r[0] <= delay_s + dur_s + hold_s]
    if not win or not h_rows:
        return None
    hs, k, ok = sorted(h_rows, key=lambda r: r[0]), 0, 0
    for el, gpos, cpos in win:
        while k < len(hs) - 1 and abs(hs[k + 1][0] - el) <= abs(hs[k][0] - el):
            k += 1
        ok += d3(gpos, cpos) <= max(FOLLOW_M, d3(hs[k][1], hs[k][2]) + 1.0)
    return round(ok / len(win), 3)


def run_follow(dev, name: str, g: dict, delay_s: float = 2.0, hold_s: float = 10.0) -> dict:
    from tools.scenario_run import run_client_cmd
    cmds = ROOT / "client_mod" / "commands"
    c = client()
    c.request("stop", {}, timeout=10)
    s = place(dev, c, g["claude_start"])
    if reflex_busy(c):
        s = place(dev, c, g["claude_start"])
    rest0 = rested(dev, c)
    if g.get("door"):  # the house may have grown or changed: the leg holds only while its door is where it was. Read
        # from inside (the door streams out of his census far away); an open door's leaf stands ~0.9 m off its frame
        st0 = c.request("get_state", {}, timeout=30)
        rows0 = ((st0 or {}).get("data") or {}).get("structures") or []
        if not any(str(r.get("name")).upper() in ("DOOR", "WALL WITH DOOR FRAME") and d2(r.get("position") or [0, 0], g["door"]) < 1.2
                   for r in rows0):
            raise RuntimeError(f"no door at {g['door']} any more: re-make the leg (--make-house-exit) for the house as built")
        door = next((r for r in ((st0 or {}).get("data") or {}).get("interactables") or []
                     if r.get("class") == "BP_T1_Door_C" and d2(r.get("position") or [0, 0], g["door"]) < 1.2), None)
        if door and str(door.get("prompt", "")).lower().startswith("close"):
            # left open (the last leg, or the builder): the leg is about a SHUT door, so shut it as a player would (the
            # interact skill: walk up, press), then start inside again (live 17:1xZ: "door already open", nothing tested)
            shut = c.request("interact", {"target": door["id"]}, timeout=60)
            print(f"  door was open: shut it ({'ok' if (shut or {}).get('ok') else (shut or {}).get('reason')})", flush=True)
            s = place(dev, c, g["claude_start"])
            st0 = c.request("get_state", {}, timeout=30)
            door = next((r for r in ((st0 or {}).get("data") or {}).get("interactables") or []
                         if r.get("class") == "BP_T1_Door_C" and d2(r.get("position") or [0, 0], g["door"]) < 1.2), door)
        g = dict(g, door_open=str(door.get("prompt")) if door else None)
    r = run_client_cmd(cmds / "move_ghost_follow.lua", "move_ghost_follow",
                       {"track": g["track"], "delay_s": delay_s, "hold_s": hold_s, "distance_m": 3}, timeout=20)
    res = (r or {}).get("result") or {}
    if not res.get("ok"):
        raise RuntimeError(f"ghost follow did not start: {r}")
    t0 = time.time()
    rows, from_i, last = [], 1, {}
    deadline = t0 + delay_s + g["duration_s"] + hold_s + 30
    while time.time() < deadline:
        time.sleep(2.0)
        st = run_client_cmd(cmds / "move_ghost_status.lua", "move_ghost_status", {"from_i": from_i}, timeout=15)
        st = (st or {}).get("result") or {}
        if not st.get("ok"):
            break
        last = st
        rows += st.get("rows") or []
        from_i = (st.get("n") or 0) + 1
        if st.get("phase") == "done":
            break
    end = run_client_cmd(cmds / "move_ghost_status.lua", "move_ghost_status", {"from_i": from_i, "stop": True}, timeout=15)
    rows += (((end or {}).get("result") or {}).get("rows")) or []
    m_rows = [(r[0], (r[1] / 100, r[2] / 100, r[3] / 100), (r[4] / 100, r[5] / 100, r[6] / 100)) for r in rows
              if r[4] or r[5]]
    me = score_follow(m_rows, delay_s, g["duration_s"], hold_s)
    h_rows = human_follower(g["track"], delay_s, hold_s, start=s, pauses=g.get("pauses"))
    hu = score_follow(h_rows, delay_s, g["duration_s"], hold_s)
    me["within_human"] = within_human(m_rows, h_rows, delay_s, g["duration_s"], hold_s)
    srcs: dict[str, int] = {}
    for r in rows:
        srcs[r[8]] = srcs.get(r[8], 0) + 1
    ok = bool(me.get("within_6m") is not None and me["within_6m"] >= FOLLOW_SHARE and me["longest_stand_s"] <= STAND_S)
    return {"journey": name, "kind": "follow", "note": f"ghost {g['who']} {g['window'][0]}-{g['window'][1]}, "
            f"{g['length_m']} m in {g['duration_s']} s", "ok": ok, "s": round(time.time() - t0, 1),
            "claude": me, "human": hu, "sources": srcs, "stuck_total": last.get("stuck_total"),
            "lp_runs": last.get("lp_runs"), "trail_entries": last.get("trail_entries"), "backtracks": last.get("backtracks"),
            "sprint_presses": last.get("sprint_presses"), "trail_skips": last.get("trail_skips"),
            "double_jumps": last.get("double_jumps"), "trail_jumps": last.get("trail_jumps"), "result": last.get("result"),
            "start": [round(x, 2) for x in s], "door_prompt_at_start": g.get("door_open"), "endurance_at_start": rest0, "ts": round(t0, 1), "rows": rows}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", default="", help="comma-separated journey names")
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--label", default="run")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--obstacles", action="store_true", help="the obstacle legs (human-timed)")
    ap.add_argument("--follow", action="store_true", help="the ghost-leader follow legs")
    ap.add_argument("--extract-ghost", nargs=3, metavar=("NAME", "FROM", "TO"), help="cut a ghost track from the recorder")
    ap.add_argument("--who", default="luisdeburnaybast")
    ap.add_argument("--make-house-exit", action="store_true", help="(re)make follow_house_exit from HOUSE_EXIT")
    a = ap.parse_args()
    if a.make_house_exit:
        g = make_ghost("follow_house_exit", HOUSE_EXIT)
        hu = score_follow(human_follower(g["track"], 2.0, 10.0, start=g["claude_start"], pauses=g.get("pauses")),
                          2.0, g["duration_s"], 10.0)
        print(f"{g['name']}: {g['length_m']} m, {g['duration_s']} s, door pause {g.get('pauses')}, human model {hu}")
        return
    if a.extract_ghost:
        g = extract_ghost(*a.extract_ghost, who=a.who)
        print(f"{g['name']}: {g['length_m']} m, {g['duration_s']} s as a ghost ({g['real_s']} s recorded), "
              f"{len(g['track'])} points, Claude starts at {g['claude_start']}")
        return
    only = set(filter(None, a.only.split(",")))
    pool = (OBSTACLES if a.obstacles else []) + ([] if (a.obstacles or a.follow) else JOURNEYS)
    if only:
        pool = [j for j in JOURNEYS + OBSTACLES if j["id"] in only]
    js = [j for j in pool if not only or j["id"] in only]
    fs = {n: g for n, g in ghosts().items() if (a.follow and not only) or n in only}
    if a.list:
        for j in js:
            print(f"{j['id']:20s} {j['from']:>11s} -> {j['to']:<11s} {d3(j['start'], j['goal']):6.0f} m  {j['kind']}"
                  f"  ({j['place'] or 'no chat name'}){'  human ' + str(human_s(j)) + ' s' if j.get('human_m') else ''}")
        for n, g in fs.items():
            print(f"{n:20s} ghost {g['who']} {g['window']}: {g['length_m']} m in {g['duration_s']} s")
        return
    from evals.bench.devrun import default_dev
    from tools import live_lock
    # every command that drives the body (the stop before each leg, the teleports) goes out inside the live lock: a
    # caller's window (tools.live_lock run / held, which sets DW_LIVE_OWNER) or this run's own (main 2026-11-01)
    cur, lock = live_lock.read(), contextlib.ExitStack()
    atexit.register(lock.close)
    if not (cur and not cur["stale"] and cur["owner"] == os.environ.get("DW_LIVE_OWNER")):
        lock.enter_context(live_lock.held("movement", wait_s=3000))
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
            hum =(f" human {row['human_s']} s x{row['vs_human']} {'OK' if row['human_ok'] else 'SLOW'}"
                   if row.get("human_s") else "")
            print(f"{mark} {n:20s} {row.get('s', 0):6.1f}s walked {row.get('walked_m', 0):6.1f}/{row.get('straight_m', 0):5.1f} m "
                  f"end {row.get('end_dist_m', '-')} m dz {row.get('end_dz_m', '-')} stand {row.get('stand_s', '-')} s{hum}  "
                  f"{row.get('reason') or ''} {row.get('detail') or row.get('error') or ''}"[:260], flush=True)
            if row.get("trip"):
                print(f"     trip: {row['trip']}", flush=True)
        for n, g in fs.items():
            try:
                row = run_follow(dev, n, g)
            except Exception as x:
                row = {"journey": n, "kind": "follow", "ok": None, "error": repr(x), "ts": round(time.time(), 1)}
            row.update(run=run_id, label=a.label, head=head(), rep=rep)
            samples = row.pop("rows", None)
            if samples:
                fd = OUT.parent / "travel_ladder_follow"
                fd.mkdir(exist_ok=True)
                (fd / f"{run_id}_{n}_{rep}.json").write_text(json.dumps(samples), encoding="utf-8")
                row["samples_file"] = f"logs/evals/travel_ladder_follow/{run_id}_{n}_{rep}.json"
            rows.append(row)
            with OUT.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(row) + "\n")
            mark = "ERR " if row.get("ok") is None else ("PASS" if row["ok"] else "FAIL")
            print(f"{mark} {n:20s} claude {row.get('claude')}  human {row.get('human')}  src {row.get('sources')} "
                  f"stuck {row.get('stuck_total')} lp {row.get('lp_runs')} trail {row.get('trail_entries')} "
                  f"bt {row.get('backtracks')} skip {row.get('trail_skips')} tj {row.get('trail_jumps')} "
                  f"dj {row.get('double_jumps')} {row.get('error') or ''}"[:400], flush=True)
    walks = [r for r in rows if r.get("ok") is not None and r.get("kind") != "follow"]
    folls = [r for r in rows if r.get("ok") is not None and r.get("kind") == "follow"]
    n_ok = sum(1 for r in walks if r["ok"])
    summary = {"summary": True, "run": run_id, "label": a.label, "head": head(), "n": len(walks), "ok": n_ok,
               "success_rate": round(n_ok / len(walks), 3) if walks else None,
               "spl": round(sum(r["spl"] for r in walks) / len(walks), 3) if walks else None,
               "s_total": round(sum(r["s"] for r in walks), 1),
               "mean_end_dist_m": round(sum(r["end_dist_m"] for r in walks) / len(walks), 1) if walks else None,
               "human_ok": sum(1 for r in walks if r.get("human_ok")), "human_n": sum(1 for r in walks if r.get("human_s")),
               "follow_ok": sum(1 for r in folls if r["ok"]), "follow_n": len(folls),
               "errors": len(rows) - len(walks) - len(folls), "ts": round(time.time(), 1)}
    with OUT.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(summary) + "\n")
    print(f"\n{a.label}:{n_ok}/{len(walks)} reached ({summary['success_rate']}), SPL {summary['spl']}, "
          f"{summary['s_total']} s, within 1.5x human {summary['human_ok']}/{summary['human_n']}, "
          f"follow {summary['follow_ok']}/{summary['follow_n']}, {summary['errors']} errors")


if __name__ == "__main__":
    main()

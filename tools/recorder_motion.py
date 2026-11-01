"""Reader for the dev server's read-only player recorder (mod/experiments/player_recorder.lua).

logs/recorder/rec_<UTC start>.jsonl, ts = epoch seconds (ms; the recorder anchors os.clock to os.time at arm, so
the whole file may run up to 1 s early against the brain's clock):
  pos        {who, p:[x,y,z] m, v (horizontal m/s), vz, yaw, mode (EMovementMode: 1 walk, 3 falling, ...), hp} at 5 Hz
  inv_start  {who, counts}            inv {who, delta:{item: +/-n}} (every change, polled at the same 5 Hz)
  rpc        {rpc, who, params, target?, target_class?, target_p?}   (pre-hooks on the player-action server RPCs)

Used by tools/session_report.py (Claude's server-truth motion, idle and presses per request). The evals tooling has its
own reader, tools/recorder_io.py (tools/standard_score.py); merge onto that one once both settle. Stdlib only.

    rec = load_overlapping(ROOT / "logs" / "recorder", lo, hi)
    rec.motion("ClaudeDev", lo, hi)          -> {moving_s, standing_s, absent_s, samples}
    rec.idle_segments("ClaudeDev", lo, hi)   -> [Idle(start, end, s, p, presses, hp0, hp1)]
    rec.presses("ClaudeDev", lo, hi)         -> [Press(ts, player, target_class, dist_m, delta, outcome, ...)]

rpc attribution: rows recorded before the server restart that activates the class fix name a component
("BP_Components_InteractionManager") in `who`. Such a row is given to the player whose pose at that time is nearest
the interact target (`who_src="nearest_target"`), else to the player whose inventory changed within the outcome
window after it (`"inv_follow"`), else none (`"unknown"`). A `who` that names a recorded player is kept (`"recorded"`).
"""
from __future__ import annotations

import bisect
import json
import math
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

V_MIN = 0.3        # m/s: below this the pawn is standing (server-reported horizontal speed)
MAX_DT = 1.0       # s: a longer hole between pose samples is "absent" (left, loading), never idle or moving
PERIOD = 0.2       # s: the recorder's pose period (period_ms=200); a sample before a hole stands for this long
OUTCOME_S = 1.5    # s: an interact with no inventory change of that player within this is a miss
NAME_RX = re.compile(r"rec_(\d{8})T(\d{6})Z")


@dataclass
class Pose:
    ts: float
    p: tuple
    v: float
    vz: float | None = None
    yaw: float | None = None
    mode: object = None
    hp: float | None = None


@dataclass
class Press:
    ts: float
    player: str | None
    who_src: str
    rpc: str
    target: str | None
    target_class: str | None
    target_p: tuple | None
    dist_m: float | None          # player pose -> target actor
    delta: dict = field(default_factory=dict)   # the inventory change this press is credited with
    delta_s: float | None = None
    outcome: str = "miss"         # hit (gained items) | changed (only lost items) | miss (no change in OUTCOME_S)


@dataclass
class Idle:
    start: float
    end: float
    s: float
    p: tuple
    presses: int = 0              # interact presses while standing (fumbling) vs 0 (idle)
    hp0: float | None = None
    hp1: float | None = None


def _d3(a, b) -> float:
    return math.dist(a[:3], b[:3])


class Recording:
    def __init__(self, rows: list[dict], paths: list[Path]):
        self.paths = paths
        rows = [r for r in rows if isinstance(r.get("ts"), (int, float))]
        rows.sort(key=lambda r: r["ts"])
        self.first = rows[0]["ts"] if rows else None
        self.last = rows[-1]["ts"] if rows else None
        self.tracks: dict[str, list[Pose]] = {}
        self.inv: dict[str, list[tuple[float, dict]]] = {}
        self.inv_start: dict[str, dict] = {}
        self.rpcs: list[dict] = []
        for r in rows:
            k, who = r.get("kind"), r.get("who")
            if k == "pos" and who and isinstance(r.get("p"), list):
                self.tracks.setdefault(who, []).append(Pose(r["ts"], tuple(r["p"]), float(r.get("v") or 0.0), r.get("vz"),
                                                            r.get("yaw"), r.get("mode"), r.get("hp")))
            elif k == "inv" and who and isinstance(r.get("delta"), dict):
                self.inv.setdefault(who, []).append((r["ts"], r["delta"]))
            elif k == "inv_start" and who:
                self.inv_start.setdefault(who, r.get("counts") or {})
            elif k == "rpc":
                self.rpcs.append(dict(r))
        self._t = {w: [x.ts for x in tr] for w, tr in self.tracks.items()}
        self._it = {w: [t for t, _ in d] for w, d in self.inv.items()}
        for r in self.rpcs:
            r["player"], r["who_src"], r["dist_m"] = self._attribute(r)

    # ---- lookups
    def players(self) -> list[str]:
        return sorted(self.tracks)

    def pose_at(self, player: str, ts: float, max_dt: float = MAX_DT) -> Pose | None:
        ts_list = self._t.get(player) or []
        i = bisect.bisect_left(ts_list, ts)
        best = None
        for j in (i - 1, i):
            if 0 <= j < len(ts_list) and abs(ts_list[j] - ts) <= max_dt and (best is None or abs(ts_list[j] - ts) < abs(ts_list[best] - ts)):
                best = j
        return self.tracks[player][best] if best is not None else None

    def _inv_after(self, player: str, ts: float, window: float) -> list[tuple[float, dict]]:
        tl = self._it.get(player) or []
        i, j = bisect.bisect_left(tl, ts - 0.05), bisect.bisect_right(tl, ts + window)
        return self.inv[player][i:j]

    def _attribute(self, r: dict) -> tuple[str | None, str, float | None]:
        who, tp = r.get("who"), r.get("target_p")
        if who in self.tracks:
            pose = self.pose_at(who, r["ts"])
            return who, "recorded", round(_d3(pose.p, tp), 2) if pose and isinstance(tp, list) else None
        if isinstance(tp, list):
            near = [(_d3(pose.p, tp), w) for w in self.tracks for pose in [self.pose_at(w, r["ts"])] if pose]
            if near:
                d, w = min(near)
                return w, "nearest_target", round(d, 2)
        after = [(d[0][0], w) for w in self.inv for d in [self._inv_after(w, r["ts"], OUTCOME_S)] if d]
        if after:
            return min(after)[1], "inv_follow", None
        return None, "unknown", None

    # ---- per-player metrics over [lo, hi]
    def _samples(self, player: str, lo: float | None, hi: float | None):
        """(pose, a, b): each sample stands for [its ts, next ts) clipped to [lo, hi]; across a hole > MAX_DT it stands
        for one PERIOD and the rest is absent."""
        tr = self.tracks.get(player) or []
        lo = tr[0].ts if lo is None and tr else lo
        hi = tr[-1].ts if hi is None and tr else hi
        if not tr or lo is None or hi is None:
            return
        i = max(0, bisect.bisect_right(self._t[player], lo) - 1)
        for k in range(i, len(tr)):
            x = tr[k]
            if x.ts > hi:
                break
            nxt = tr[k + 1].ts if k + 1 < len(tr) else x.ts + PERIOD
            a, b = max(x.ts, lo), min(nxt if nxt - x.ts <= MAX_DT else x.ts + PERIOD, hi)
            if b > a:
                yield x, a, b

    def motion(self, player: str, lo: float | None = None, hi: float | None = None, v_min: float = V_MIN) -> dict:
        moving = standing = 0.0
        n = 0
        for x, a, b in self._samples(player, lo, hi):
            n += 1
            if x.v >= v_min:
                moving += b - a
            else:
                standing += b - a
        span = (hi - lo) if lo is not None and hi is not None else moving + standing
        return {"moving_s": round(moving, 1), "standing_s": round(standing, 1),
                "absent_s": round(max(0.0, span - moving - standing), 1), "samples": n}

    def idle_segments(self, player: str, lo: float | None = None, hi: float | None = None, v_min: float = V_MIN,
                      min_s: float = 5.0) -> list[Idle]:
        """Runs of standing samples (v < v_min, no sampling hole) of at least min_s, with the presses inside."""
        out, cur = [], None

        def close():
            if cur and cur[1] - cur[0] >= min_s:
                n = sum(1 for p in self.presses(player, cur[0], cur[1]))
                out.append(Idle(cur[0], cur[1], round(cur[1] - cur[0], 1), cur[2].p, n, cur[2].hp, cur[3].hp))

        for x, a, b in self._samples(player, lo, hi):
            if x.v < v_min and cur is not None and a <= cur[1] + 1e-6:
                cur = (cur[0], b, cur[2], x)
            elif x.v < v_min:
                close()
                cur = (a, b, x, x)
            else:
                close()
                cur = None
        close()
        return out

    def presses(self, player: str | None = None, lo: float | None = None, hi: float | None = None,
                window_s: float = OUTCOME_S, rpc: str = "interact") -> list[Press]:
        """Interact presses with their outcome. Each inventory change is credited to the latest press before it
        (two presses half a second apart and one pick = one hit and one miss)."""
        cache = self.__dict__.setdefault("_press_cache", {})
        key = (rpc, window_s)
        if key not in cache:
            cache[key] = self._all_presses(rpc, window_s)
        return [p for p in cache[key] if (player is None or p.player == player)
                and (lo is None or p.ts >= lo) and (hi is None or p.ts <= hi)]

    def _all_presses(self, rpc: str, window_s: float) -> list[Press]:
        out: list[Press] = []
        by_player: dict[str | None, list[Press]] = {}
        for r in self.rpcs:
            if r.get("rpc") != rpc:
                continue
            tp = r.get("target_p")
            p = Press(r["ts"], r["player"], r["who_src"], rpc, r.get("target"), r.get("target_class"),
                      tuple(tp) if isinstance(tp, list) else None, r.get("dist_m"))
            out.append(p)
            by_player.setdefault(p.player, []).append(p)
        for player, ps in by_player.items():
            if player is None:
                continue
            for t, delta in self.inv.get(player) or []:
                cands = [p for p in ps if p.ts - 0.05 <= t <= p.ts + window_s]
                if not cands:
                    continue
                p = max(cands, key=lambda x: x.ts)
                for k, n in delta.items():
                    p.delta[k] = p.delta.get(k, 0) + n
                p.delta_s = round(t - p.ts, 2) if p.delta_s is None else p.delta_s
        for p in out:
            if p.delta:
                p.outcome = "hit" if any(n > 0 for n in p.delta.values()) else "changed"
        return out


# ---- files
def _bounds(path: Path) -> tuple[float | None, float | None]:
    """First and last ts of a recorder file (reads the head and the last 64 KB only)."""
    first = last = None
    with open(path, "rb") as f:
        for raw in f:
            try:
                first = json.loads(raw).get("ts")
                break
            except (ValueError, AttributeError):
                continue
        f.seek(0, 2)
        size = f.tell()
        f.seek(max(0, size - 65536))
        for raw in reversed(f.read().splitlines()):
            try:
                last = json.loads(raw).get("ts")
                break
            except (ValueError, AttributeError):
                continue
    if first is None:
        m = NAME_RX.search(path.name)
        if m:
            first = datetime.strptime("".join(m.groups()), "%Y%m%d%H%M%S").replace(tzinfo=timezone.utc).timestamp()
    return first, last


def find(rec_dir: Path, lo: float, hi: float) -> list[Path]:
    """Recorder files whose [first, last] overlaps [lo, hi], oldest first."""
    out = []
    for p in sorted(Path(rec_dir).glob("rec_*.jsonl")):
        a, b = _bounds(p)
        if a is not None and a <= hi and (b is None or b >= lo):
            out.append(p)
    return out


def load(*paths: Path) -> Recording:
    rows = []
    for path in paths:
        with open(path, encoding="utf-8", errors="replace") as f:
            for raw in f:
                try:
                    d = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(d, dict):
                    rows.append(d)
    return Recording(rows, list(paths))


def load_overlapping(rec_dir: Path, lo: float, hi: float) -> Recording | None:
    paths = find(rec_dir, lo, hi)
    return load(*paths) if paths else None


def pick_player(rec: Recording, name: str | None) -> str | None:
    """The recorded player whose name starts with ``name`` (case-insensitive: "Claude" -> "ClaudeDev")."""
    if not rec or not name:
        return None
    exact = [w for w in rec.players() if w.lower() == name.lower()]
    pref = [w for w in rec.players() if w.lower().startswith(name.lower())]
    return (exact or pref or [None])[0]

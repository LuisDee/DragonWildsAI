"""One reader for the dedicated server's read-only player recorder (mod/experiments/player_recorder.lua), used by
tools/standard_score.py (tools/recorder_motion.py is the telemetry agent's reader for tools/session_report.py; to be
merged). Files: logs/recorder/rec_*.jsonl. Stdlib only.

Rows (one JSON object per line; ts = epoch seconds, server clock = this VM's clock; positions in metres):
  armed {players, hooks, period_ms} / stopped
  pos   {who, p:[x,y,z], v (speed m/s), vz, yaw (deg), mode (movement mode), hp}, about 4-5 Hz per player
  inv   {who, delta:{item: +-n}};  inv_start {who, counts}
  rpc   {rpc, who, params, target, target_class, target_p}: interact (Server_RequestInteraction), the inventory
        controller (use_item, drop, split, split_put, move, move_all, craft, toggle), build_spawn, build_interact,
        harvest_plot, ability (ServerTryActivateAbility; fired no rows in the first run, so swings and casts are invisible)

Attribution. In rec_20261101T123634Z, rpc.who is the hooked COMPONENT ("BP_Components_InteractionManager",
"BP_Components_InventoryController", "BuildModeComponent"), not the player: the recorder's who_of() matches the
component's outer path. pos and inv rows are attributed correctly. So every rpc gets a `player` and `by` here:
  interact  the player nearest target_p at the press (by "near", within PRESS_M); when nobody is that close (a
            water volume's origin is far from its shore), the one player whose inventory gained within GAIN_S
            (by "inv"), else the nearest anyway (by "nearest_far")
  other     the player whose inventory changes within INV_WIN of the rpc (by "inv"); else the player whose last
            interact was within AFTER_S before (by "after_interact": a station or chest UI); else the only player
            present (by "only"); else None
  An rpc whose own `who` is a player name (a fixed recorder) keeps it (by "recorder").

Press outcome (interact): gain (an inventory gain within GAIN_S), changed (only a loss in that time: fuel,
a deposit), opened (an inventory-controller rpc by the same player within OPEN_S: a UI opened), else no_effect
(a miss: nothing the recorder can see happened).

    from tools import recorder_io as rio
    rec = rio.load(since=t0, until=t1)            # all rec_*.jsonl overlapping the window
    who = rec.canon("luisdeburnaybastos")         # chat/brain name -> recorder name (prefix match)
    rec.presses(who, t0, t1); rec.still_segments(who, t0, t1); rec.path(who, t0, t1)
"""
from __future__ import annotations

import bisect
import json
import math
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REC_DIR = ROOT / "logs" / "recorder"

IDLE_V = 0.3          # m/s: below this the player stands
IDLE_MIN_S = 2.0      # a still stretch longer than this is a candidate idle
GAIN_S = 1.5          # an interact's inventory gain lands within this (measured 0.1-0.25 s on Luis's sticks)
OPEN_S = 4.0          # an inventory-controller rpc this soon after an interact: the interact opened a UI
PRESS_M = 8.0         # an interact's target is within this of the player who pressed
INV_WIN = (-0.3, 2.5)  # an inventory-controller rpc's own inventory change lands in this window
AFTER_S = 30.0        # a UI rpc this long after the player's last interact still belongs to him
TELEPORT_M = 25.0     # one sample-to-sample step longer than this is a teleport, not walking
UI_RPCS = {"use_item", "drop", "split", "split_put", "move", "move_all", "craft", "toggle"}


@dataclass
class Sample:
    ts: float
    p: tuple
    v: float
    vz: float
    yaw: float | None
    mode: int | None
    hp: float | None


@dataclass
class Press:
    ts: float
    player: str | None
    target: str | None
    target_class: str | None
    target_p: tuple | None
    dist_m: float | None
    by: str
    outcome: str = "no_effect"
    gain: dict = field(default_factory=dict)
    latency_s: float | None = None


def hdist(a, b) -> float:
    return math.hypot(a[0] - b[0], a[1] - b[1])


def same_player(a: str | None, b: str | None) -> bool:
    """Names are truncated in places ("luisdeburnaybast" vs "luisdeburnaybastos"): one is a prefix of the other."""
    if not a or not b:
        return False
    a, b = a.lower(), b.lower()
    return a.startswith(b) or b.startswith(a)


def files(since: float | None = None, until: float | None = None, rec_dir: Path = REC_DIR) -> list[Path]:
    """rec_*.jsonl that may overlap [since, until]: started before `until` and written to after `since`."""
    out = []
    for f in sorted(rec_dir.glob("rec_*.jsonl")):
        try:
            mtime = f.stat().st_mtime
            with open(f, encoding="utf-8") as fh:
                first = json.loads(fh.readline() or "{}")
        except (OSError, ValueError):
            continue
        t_first = first.get("ts") or 0
        if (until is None or t_first <= until) and (since is None or mtime >= since):
            out.append(f)
    return out


class Recording:
    def __init__(self, rows: list[dict], paths: list[Path]):
        self.paths = paths
        self.tracks: dict[str, list[Sample]] = defaultdict(list)
        self.inv: list[tuple[float, str, dict]] = []
        self.start: dict[str, dict] = {}
        self.rpc: list[dict] = []
        self.armed: list[dict] = []
        for r in sorted(rows, key=lambda r: r.get("ts") or 0):
            k, ts = r.get("kind"), r.get("ts")
            if ts is None:
                continue
            if k == "pos" and r.get("p"):
                self.tracks[r["who"]].append(Sample(ts, tuple(r["p"]), r.get("v") or 0.0, r.get("vz") or 0.0,
                                                    r.get("yaw"), r.get("mode"), r.get("hp")))
            elif k == "inv" and r.get("delta"):
                self.inv.append((ts, r.get("who"), r["delta"]))
            elif k == "inv_start":
                self.start.setdefault(r.get("who"), r.get("counts") or {})
            elif k == "rpc":
                self.rpc.append(dict(r))
            elif k in ("armed", "stopped"):
                self.armed.append(r)
        self.players = sorted(self.tracks)
        self._ts = {w: [s.ts for s in t] for w, t in self.tracks.items()}
        self._inv_ts = [x[0] for x in self.inv]
        self._attribute()

    # ---- lookups
    def canon(self, name: str | None) -> str | None:
        """The recorder's name for a chat/brain player name."""
        return next((p for p in self.players if same_player(p, name)), None)

    def track(self, who: str, a: float | None = None, b: float | None = None) -> list[Sample]:
        t, ts = self.tracks.get(who) or [], self._ts.get(who) or []
        i = 0 if a is None else bisect.bisect_left(ts, a)
        j = len(t) if b is None else bisect.bisect_right(ts, b)
        return t[i:j]

    def at(self, who: str, ts: float, within: float = 2.0) -> Sample | None:
        t, xs = self.tracks.get(who) or [], self._ts.get(who) or []
        i = bisect.bisect_left(xs, ts)
        best = min((t[k] for k in (i - 1, i) if 0 <= k < len(t)), key=lambda s: abs(s.ts - ts), default=None)
        return best if best is not None and abs(best.ts - ts) <= within else None

    def inv_rows(self, who: str | None, a: float, b: float) -> list[tuple[float, dict]]:
        i, j = bisect.bisect_left(self._inv_ts, a), bisect.bisect_right(self._inv_ts, b)
        return [(ts, d) for ts, w, d in self.inv[i:j] if who is None or w == who]

    def rpcs(self, who: str | None = None, a: float | None = None, b: float | None = None, kinds=None) -> list[dict]:
        return [r for r in self.rpc if (who is None or r.get("player") == who) and (a is None or r["ts"] >= a)
                and (b is None or r["ts"] <= b) and (kinds is None or r.get("rpc") in kinds)]

    def events(self, who: str, a: float, b: float) -> list[float]:
        """Times of everything the player did that the recorder saw besides walking: rpcs and inventory changes."""
        return sorted([r["ts"] for r in self.rpcs(who, a, b)] + [ts for ts, _ in self.inv_rows(who, a, b)])

    def _inv_slice(self, a: float, b: float) -> list[tuple[float, str, dict]]:
        return self.inv[bisect.bisect_left(self._inv_ts, a):bisect.bisect_right(self._inv_ts, b)]

    # ---- attribution of rpcs to players (see the module docstring)
    def _attribute(self) -> None:
        last_interact: dict[str, float] = {}
        for r in self.rpc:
            ts, own = r["ts"], r.get("who")
            if own in self.tracks:
                r["player"], r["by"] = own, "recorder"
            elif r.get("rpc") == "interact" and r.get("target_p"):
                near = sorted((hdist(s.p, r["target_p"]), w) for w in self.players if (s := self.at(w, ts)))
                if near:
                    r["player"], r["press_dist_m"] = near[0][1], round(near[0][0], 2)
                    r["by"] = "near" if near[0][0] <= PRESS_M else "nearest_far"
                    if near[0][0] > PRESS_M:  # a big actor (water volume): its origin is far; whoever gained pressed it
                        got = {w for t, w, d in self._inv_slice(ts - 0.05, ts + GAIN_S) if any(v > 0 for v in d.values())}
                        if len(got) == 1:
                            r["player"], r["by"] = got.pop(), "inv"
            else:
                rows = [(abs(t - ts), w) for t, w, _ in self._inv_slice(ts + INV_WIN[0], ts + INV_WIN[1])]
                if rows:
                    r["player"], r["by"] = min(rows)[1], "inv"
                else:
                    recent = [(ts - t, w) for w, t in last_interact.items() if 0 <= ts - t <= AFTER_S]
                    present = [w for w in self.players if self.at(w, ts, 5.0)]
                    if recent:
                        r["player"], r["by"] = min(recent)[1], "after_interact"
                    elif len(present) == 1:
                        r["player"], r["by"] = present[0], "only"
            r.setdefault("player", None)
            r.setdefault("by", "none")
            if r.get("rpc") == "interact" and r["player"]:
                last_interact[r["player"]] = ts

    # ---- derived measures
    def presses(self, who: str, a: float, b: float) -> list[Press]:
        """His interacts with their outcome. Each inventory change goes to the latest still-unmatched press before it
        within GAIN_S (else the latest press), so two quick presses each get their own item and a fumbled press is not
        credited with the next one's. A press that matched nothing is a miss unless it opened a UI."""
        out = [Press(r["ts"], who, r.get("target"), r.get("target_class"), tuple(r["target_p"]) if r.get("target_p") else None,
                     r.get("press_dist_m"), r.get("by")) for r in self.rpcs(who, a, b, {"interact"})]
        starts = [p.ts for p in out]
        for ts, d in self.inv_rows(who, a, b + GAIN_S):
            j = bisect.bisect_right(starts, ts + 0.02) - 1
            cands = [k for k in range(j, -1, -1) if ts - out[k].ts <= GAIN_S]
            if not cands:
                continue
            p = out[next((k for k in cands if out[k].outcome == "no_effect"), cands[0])]
            gain = {k: v for k, v in d.items() if v > 0}
            if gain:
                if p.outcome != "gain":
                    p.latency_s = round(ts - p.ts, 2)
                p.outcome = "gain"
                for k, v in gain.items():
                    p.gain[k] = p.gain.get(k, 0) + v
            elif p.outcome == "no_effect":
                p.outcome, p.latency_s = "changed", round(ts - p.ts, 2)
        for p in out:
            if p.outcome == "no_effect" and self.rpcs(who, p.ts + 0.01, p.ts + OPEN_S, UI_RPCS):
                p.outcome = "opened"
        return out

    def path(self, who: str, a: float, b: float) -> dict:
        t = self.track(who, a, b)
        path_m, tele = 0.0, 0
        for s0, s1 in zip(t, t[1:]):
            d = hdist(s0.p, s1.p)
            if d > TELEPORT_M:
                tele += 1
            elif d >= 0.05:  # standing jitter of the position read
                path_m += d
        return {"path_m": round(path_m, 1), "teleports": tele,
                "straight_m": round(hdist(t[0].p, t[-1].p), 1) if len(t) >= 2 else 0.0,
                "reach_m": round(max((hdist(t[0].p, s.p) for s in t), default=0.0), 1),
                "climb_m": round(max((s.p[2] for s in t), default=0) - min((s.p[2] for s in t), default=0), 1)}

    def _runs(self, who: str, a: float, b: float, moving: bool) -> list[tuple[float, float, list[Sample]]]:
        t = self.track(who, a, b)
        out, cur = [], []
        for s in t + [None]:
            if s is not None and (s.v >= IDLE_V) == moving:
                cur.append(s)
                continue
            if cur:
                end = s.ts if s is not None else min(b, cur[-1].ts + 0.2)
                out.append((cur[0].ts, end, cur))
            cur = []
        return out

    def still_segments(self, who: str, a: float, b: float, min_s: float = IDLE_MIN_S) -> list[dict]:
        """Still stretches longer than min_s; explained = an rpc or inventory change of his within it (or GAIN_S after)."""
        out = []
        for s, e, _ in self._runs(who, a, b, moving=False):
            if e - s > min_s:
                ev = [x for x in self.events(who, s, e + GAIN_S)]
                out.append({"start": s, "end": e, "s": round(e - s, 2), "explained": bool(ev), "events": len(ev)})
        return out

    def bursts(self, who: str, a: float, b: float) -> list[dict]:
        """Moving stretches: duration, net displacement, path; productive = an rpc/inventory change by the end + 2 s."""
        out = []
        for s, e, xs in self._runs(who, a, b, moving=True):
            pm = sum(hdist(x.p, y.p) for x, y in zip(xs, xs[1:]) if hdist(x.p, y.p) <= TELEPORT_M)
            out.append({"start": s, "end": e, "s": round(e - s, 2), "net_m": round(hdist(xs[0].p, xs[-1].p), 2),
                        "path_m": round(pm, 2), "productive": bool(self.events(who, s, e + 2.0))})
        return out

    def heading_reversals(self, who: str, a: float, b: float, deg: float = 120.0, within: float = 1.0) -> int:
        """Turns of more than `deg` within `within` seconds while moving (dithering)."""
        t = [s for s in self.track(who, a, b) if s.v >= IDLE_V and s.yaw is not None]
        n, last = 0, -1e9
        for i, s in enumerate(t):
            for u in t[i + 1:]:
                if u.ts - s.ts > within:
                    break
                d = abs((u.yaw - s.yaw + 180) % 360 - 180)
                if d >= deg and s.ts - last > within:
                    n, last = n + 1, s.ts
                    break
        return n

    def vitals(self, who: str, a: float, b: float) -> dict:
        t = [s for s in self.track(who, a, b) if s.hp is not None]
        lost = sum(max(0.0, x.hp - y.hp) for x, y in zip(t, t[1:]))
        deaths = sum(1 for x, y in zip(t, t[1:]) if x.hp > 0 >= y.hp)
        return {"hp_lost": round(lost, 1), "deaths": deaths, "min_hp": min((s.hp for s in t), default=None),
                "min_vz": round(min((s.vz for s in self.track(who, a, b)), default=0.0), 1)}


def read_rows(paths: list[Path], since: float | None = None, until: float | None = None) -> list[dict]:
    rows = []
    for f in paths:
        with open(f, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue  # the live file's last line may be half-written
                ts = r.get("ts")
                if ts is None or (since is not None and ts < since) or (until is not None and ts > until):
                    if r.get("kind") not in ("armed", "inv_start"):
                        continue
                rows.append(r)
    return rows


def load(paths: list[Path] | None = None, since: float | None = None, until: float | None = None,
         pad_s: float = 30.0) -> Recording:
    """The recording(s) overlapping [since, until], with pad_s of context on each side for attribution."""
    paths = files(since, until) if paths is None else [Path(p) for p in paths]
    a = None if since is None else since - pad_s
    b = None if until is None else until + pad_s
    return Recording(read_rows(paths, a, b), paths)

"""Per-world map / resource memory: ONE store, fed from every census (BUGS L21; Director MapMemory).

Writer: the brain's census path (`BridgeClient.get_state` hook, see `observe`). Readers: the needs digest
(`annotate` -> state["remembered"]) and the Director (`load(path)` / `snapshot()` / `query`).

A sighting = one thing the body perceived, keyed by (kind, class, 2 m cell) or by its stable id:
  {kind, id?, name, item?, class?, prompt?, position [x,y,z], count_seen, first_seen, last_seen,
   extra: {owner?, station?, power_level?, attitude?}}
kind / name / class / prompt / item come from the census rows (game data), never from lists here.
Negative evidence (Director review L5): {kind: "depleted"|"empty", item?, position, at, why} via
`note_negative`, so a spot can be ranked down ("both coal spots I know were mined out").

File: <world state dir>/map_memory.json, written atomically (unique temp + os.replace, retried on a Windows
PermissionError), debounced (DEBOUNCE_S or on `flush`). Precedent: Voyager/Mindcraft "memory of places",
Generative Agents observation memory; MINDcraft keeps a `memory.json` of positions (search notes in
docs/ARCHITECTURE.md 8.4b). Decision: build (a 200-line JSON store; no library fits the census shape).
"""
from __future__ import annotations

import json
import math
import os
import time
import uuid
from pathlib import Path
from typing import Any, Callable, Iterable

# STABLE record fields (the Director reads them): kind, name, item, position, last_seen, extra.power_level.
# Renaming any of them is a schema change: bump SCHEMA and tell the Director's owner first.
SCHEMA = "dw_map_memory/1"
DEBOUNCE_S = 30.0
CELL_M = 2.0
MAX_RECORDS = 5000
# census buckets of get_state that describe the world (players and the companion himself are not places)
BUCKETS = (("interactables", None), ("nearby_resources", "resource"), ("nearby_items", "item"),
           ("nearby_entities", "creature"))
TRANSIENT = {"item": 1800.0, "creature": 900.0}  # world items / creatures move or vanish: shorter memory


def load(path: str | Path) -> dict:
    """Pure: the file as a plain dict ({schema, sightings: [...], negative: [...]}), {} when absent/bad."""
    try:
        d = json.loads(Path(path).read_text(encoding="utf-8"))
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def _dist(a, b) -> float | None:
    if not (isinstance(a, (list, tuple)) and isinstance(b, (list, tuple)) and len(a) >= 2 and len(b) >= 2):
        return None
    return math.hypot(a[0] - b[0], a[1] - b[1])


def direction(frm, to) -> str:
    """Compass words from one position to another, ASSUMING +X = north and +Y = east (Unreal's usual map
    convention; UNVERIFIED for Dragonwilds' in-game map)."""
    dx, dy = to[0] - frm[0], to[1] - frm[1]
    ang = (math.degrees(math.atan2(dy, dx)) + 360) % 360  # 0 = +X
    return ("N", "NE", "E", "SE", "S", "SW", "W", "NW")[int(((ang + 22.5) % 360) // 45)]


class MapMemory:
    def __init__(self, path: str | Path, clock: Callable[[], float] = time.time, debounce_s: float = DEBOUNCE_S):
        self.path = Path(path)
        self.clock = clock
        self.debounce_s = debounce_s
        d = load(self.path)
        self.sightings: dict[str, dict] = {self._key(r): r for r in d.get("sightings") or [] if isinstance(r, dict)}
        self.negative: list[dict] = [r for r in d.get("negative") or [] if isinstance(r, dict)]
        self._dirty = False
        self._saved_at = self.clock()

    # ------------------------------------------------------------ writing
    @staticmethod
    def _key(r: dict) -> str:
        p = r.get("position") or [0, 0, 0]
        cell = f"{round(p[0] / CELL_M)}:{round(p[1] / CELL_M)}"
        return f"{r.get('kind')}|{r.get('class') or r.get('name')}|{cell}"

    def observe(self, state: dict) -> None:
        """Fold one get_state census into the store (cheap; the file is written at most every debounce_s)."""
        if not isinstance(state, dict) or state.get("unavailable"):
            return
        now = self.clock()
        for bucket, default_kind in BUCKETS:
            for row in state.get(bucket) or []:
                if not isinstance(row, dict) or not isinstance(row.get("position"), list):
                    continue
                if bucket == "nearby_entities" and row.get("alive") is False:
                    continue
                rec = {"kind": row.get("kind") if bucket == "interactables" else (row.get("kind") or default_kind),
                       "name": row.get("name"), "class": row.get("class"), "position": [round(float(v), 2) for v in row["position"][:3]]}
                if bucket == "nearby_resources":
                    rec["kind"] = "resource"
                    rec["resource_kind"] = row.get("kind")
                if bucket == "nearby_items":
                    rec["kind"] = "item"
                if bucket == "nearby_entities":
                    rec["kind"] = "creature"
                for f in ("id", "item", "prompt"):
                    if row.get(f) is not None:
                        rec[f] = row[f]
                extra = {k: row[k] for k in ("owner", "claimed_by", "power_level", "attitude", "station", "consumable")
                         if row.get(k) is not None}
                if extra:
                    rec["extra"] = extra
                k = self._key(rec)
                old = self.sightings.get(k)
                if old:
                    old.update({x: y for x, y in rec.items() if x != "extra"})
                    if extra:
                        old["extra"] = {**(old.get("extra") or {}), **extra}
                    old["count_seen"] = int(old.get("count_seen") or 1) + 1
                    old["last_seen"] = now
                else:
                    rec.update(count_seen=1, first_seen=now, last_seen=now)
                    self.sightings[k] = rec
                self._dirty = True
        self._prune(now)
        if self._dirty and now - self._saved_at >= self.debounce_s:
            self.flush()

    def note_negative(self, item: str | None, position, why: str, kind: str = "depleted") -> None:
        """A spot found empty / depleted (gather nothing_in_range, a mined-out node)."""
        self.negative.append({"kind": kind, "item": item, "position": list(position) if position else None,
                              "at": self.clock(), "why": why})
        self.negative = self.negative[-500:]
        self._dirty = True

    def _prune(self, now: float) -> None:
        for k in [k for k, r in self.sightings.items() if r.get("kind") in TRANSIENT and now - float(r.get("last_seen") or 0) > TRANSIENT[r["kind"]]]:
            del self.sightings[k]
        if len(self.sightings) > MAX_RECORDS:
            for k, _ in sorted(self.sightings.items(), key=lambda kv: kv[1].get("last_seen") or 0)[: len(self.sightings) - MAX_RECORDS]:
                del self.sightings[k]

    def flush(self) -> None:
        if not self._dirty:
            return
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_name(f"{self.path.name}.{uuid.uuid4().hex[:8]}.tmp")
        tmp.write_text(json.dumps(self.snapshot(), ensure_ascii=False), encoding="utf-8")
        for attempt in range(5):
            try:
                os.replace(tmp, self.path)
                break
            except PermissionError:  # a reader has it open on Windows: retry briefly
                time.sleep(0.05 * (attempt + 1))
        else:
            tmp.unlink(missing_ok=True)
            return
        self._dirty, self._saved_at = False, self.clock()

    # ------------------------------------------------------------ reading (pure over the records)
    def snapshot(self) -> dict:
        return {"schema": SCHEMA, "saved_at": self.clock(), "sightings": [dict(r) for r in self.sightings.values()],
                "negative": [dict(r) for r in self.negative]}

    def query(self, kind: str | None = None, name: str | None = None, item: str | None = None, near=None,
              max_age_s: float | None = None, limit: int = 10, where: Callable[[dict], bool] | None = None) -> list[dict]:
        return query(self.snapshot(), kind=kind, name=name, item=item, near=near, max_age_s=max_age_s, limit=limit,
                     where=where, now=self.clock())


def query(snap: dict, kind=None, name=None, item=None, near=None, max_age_s=None, limit=10, where=None,
          now: float | None = None) -> list[dict]:
    """Pure: matching sightings (+distance when near is given), nearest first (else newest first)."""
    now = time.time() if now is None else now
    out = []
    for r in snap.get("sightings") or []:
        if kind and r.get("kind") != kind:
            continue
        if item and r.get("item") != item:
            continue
        if name and str(name).lower() not in str(r.get("name") or "").lower():
            continue
        if max_age_s is not None and now - float(r.get("last_seen") or 0) > max_age_s:
            continue
        if where and not where(r):
            continue
        rec = dict(r)
        if near is not None:
            rec["distance"] = _dist(near, r.get("position"))
        out.append(rec)
    if near is not None:
        out.sort(key=lambda r: r["distance"] if r.get("distance") is not None else 1e12)
    else:
        out.sort(key=lambda r: -(r.get("last_seen") or 0))
    return out[:limit]


def words(text) -> set[str]:
    return {w for w in "".join(c.lower() if c.isalpha() else " " for c in str(text or "")).split() if len(w) > 3}


def need_matchers(cat: dict) -> dict[str, Callable[[dict], bool]]:
    """For each consumable kind, a test 'does this remembered thing give it?', from GAME DATA only:
    resources/items whose item data class is that kind, and interactables whose prompt shares a word
    with the names of that kind's items (e.g. a "Collect Water" prompt vs the "Dirty Water" drink)."""
    from .needs import item_kind
    vocab: dict[str, set[str]] = {"food": set(), "drink": set(), "potion": set()}
    for iid, e in (cat.get("items") or {}).items():
        k = item_kind(iid, cat)
        if k:
            vocab[k] |= words(e.get("name"))
    # a word that names items of several kinds says nothing about one of them
    common = (vocab["food"] & vocab["drink"]) | (vocab["food"] & vocab["potion"]) | (vocab["drink"] & vocab["potion"])
    out = {}
    for k in vocab:
        v = vocab[k] - common

        def test(r, k=k, v=v):
            if r.get("item") and item_kind(r["item"], cat) == k:
                return True
            return r.get("kind") not in ("item", "resource", "creature") and bool(words(r.get("prompt")) & v)
        out[k] = test
    return out


def annotate(state: dict, mem: MapMemory | dict, cat: dict | None = None, beyond_m: float = 40.0, per_kind: int = 2) -> dict:
    """state["remembered"] = {food|drink|potion|bed|station: [{name, position, distance, direction, age_min}]}:
    the nearest remembered options BEYOND sight (the needs digest shows them). Returns the state."""
    from .needs import catalog
    cat = cat if cat is not None else catalog()
    snap = mem.snapshot() if isinstance(mem, MapMemory) else mem
    me = state.get("position")
    if not isinstance(me, list):
        return state
    now = mem.clock() if isinstance(mem, MapMemory) else time.time()
    rem = {}
    tests = need_matchers(cat)
    tests["bed"] = lambda r: r.get("kind") in ("bed", "resting_area")
    tests["station"] = lambda r: r.get("kind") in ("crafting_station", "processing_station")
    for k, test in tests.items():
        rows = [r for r in query(snap, near=me, limit=200, where=test, now=now) if (r.get("distance") or 0) > beyond_m]
        if rows:
            rem[k] = [{"name": r.get("name"), "id": r.get("id"), "prompt": r.get("prompt"), "position": r.get("position"),
                       "distance": round(r["distance"]), "direction": direction(me, r["position"]),
                       "age_min": round((now - float(r.get("last_seen") or now)) / 60)} for r in rows[:per_kind]]
    if rem:
        state["remembered"] = rem
    return state


def lines_for(state: dict, kinds: Iterable[str]) -> list[str]:
    """Digest fragments for the given need kinds from state["remembered"] (set by annotate)."""
    rem = state.get("remembered") if isinstance(state.get("remembered"), dict) else {}
    out = []
    for k in kinds:
        for r in rem.get(k) or []:
            out.append(f"{r.get('name')}" + (f" ('{r['prompt']}')" if r.get("prompt") else "")
                       + f" seen {r.get('age_min')} min ago, {r.get('distance')} m {r.get('direction')} at {r.get('position')}")
    return out

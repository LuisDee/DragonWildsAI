"""Where is a named place? Region / NPC / point-of-interest names -> world positions, with honest provenance
(BUGS A5: the Director planned ``go_to "Bramblemead Valley"`` and nothing could resolve it).

Sources, in trust order (every answer says which one it came from and how exact it is):
  1. **Game data** ``data/places_<build>.json`` (tools/build_places.py): the map's 31 regions (``BP_MapRegion_C``:
     name, power level, boundary polygon, or only a bounding box until the polygon dump has run) and ~500
     landmarks (``AGameplayObjectRegistry.Landmarks``: NPC spots such as "Zanik", shrines, anima vents, courses),
     and the PROVINCES (the big areas players name: Brynmoor, Ghornfell, Fellhollow, Dowdun Reach, Umbral Sands,
     Scorned Wilderness = the game's EQuestRegion) with the sub-region -> province mapping (tools/build_places.py;
     each region says where its mapping came from). Same in every world of a build.
     An NPC such as Zanik or Vannaka exists as several copies, one in each province (Luis, 2026-10-26): every
     spot is listed with its province, and the copy in the province he is in comes first.
  2. **What he knows himself**, passed in by the caller: saved places (StateStore.places), map memory sightings
     (map_memory.snapshot), the world's lodestones (the body's ``lodestones`` read).
  3. **The wiki**, only to connect a name the game data lacks to names it has ("Goblin Diplomacy starts: Speak to
     Zanik on the ridge in Bramblemead Valley" -> the Zanik spots inside Bramblemead Valley). Positions always come
     from 1-2; the wiki never supplies coordinates.

Nothing is guessed silently: a region gives the best KNOWN point inside it (a place he saw, a lodestone, a game
landmark) or, failing those, its centre marked ``approximate`` with the reason; an unknown name answers
``found: false`` with the regions and lodestones that are known. Names are matched against the data's own names
(word coverage, like knowledge.lookup's title re-rank): no phrase table, no task names.

Decision (search-before-building, 2026-10-26):
- Need: a wiki region / NPC location -> a world position for go_to / teleport.
- Searched: the wiki mirror (``{{Map|...|center=160000,80000}}`` uses the wiki's own map-tile space, which would
  need a calibration against world points), the wiki API (Map / "Map of Ashenfall" pages), third-party datamined
  maps (metabot.gg 11,755 points, dragonwildsmap.com, mapgenie: no licence for reuse), and our own reflection
  reads (DISCOVERIES "Lodestones, map regions and travel": MapRegion polygons, registry Landmarks, lodestones).
- Decision: **adapt** the game's own data (authoritative, same build, no licence issue) with the legacy
  ``travel.region_at`` rule (smallest polygon wins). Build only the small resolver around it.
"""
from __future__ import annotations

import json
import re
from functools import lru_cache
from pathlib import Path
from typing import Any, Iterable

from .geom import dist
from .knowledge import STOP, _stem, _terms, data_dir, words

SPOTS = 6  # spots listed per landmark name
AT_CACHE = 20000  # points kept by Places.region_at
NOTE = ("Positions are game data or what you saw yourself; a point marked approximate is not checked for ground or "
        "a path. Say how you know, and say so when you don't.")


# ------------------------------------------------------------------------------ data


def newest_file(directory: Path | None = None) -> Path | None:
    files = sorted(Path(directory or data_dir()).glob("places_*.json"))
    return files[-1] if files else None


@lru_cache(maxsize=4)
def _load(path: str) -> dict:
    try:
        d = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return d if isinstance(d, dict) else {}


def _bbox_poly(b) -> list[list[float]] | None:
    if not (isinstance(b, list) and len(b) == 4):
        return None
    x0, y0, x1, y1 = b
    return [[x0, y0], [x1, y0], [x1, y1], [x0, y1]]


def area(poly) -> float:
    n = len(poly)
    return abs(sum(poly[i][0] * poly[(i + 1) % n][1] - poly[(i + 1) % n][0] * poly[i][1] for i in range(n))) / 2


def inside(poly, x: float, y: float) -> bool:
    """Even-odd ray cast (the same rule as client_mod/scripts/places.lua)."""
    n, hit, j = len(poly), False, len(poly) - 1
    if n < 3:
        return False
    for i in range(n):
        xi, yi, xj, yj = poly[i][0], poly[i][1], poly[j][0], poly[j][1]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            hit = not hit
        j = i
    return hit


def centroid(poly) -> list[float]:
    a = 0.0
    cx = cy = 0.0
    n = len(poly)
    for i in range(n):
        x0, y0, x1, y1 = poly[i][0], poly[i][1], poly[(i + 1) % n][0], poly[(i + 1) % n][1]
        c = x0 * y1 - x1 * y0
        a += c
        cx += (x0 + x1) * c
        cy += (y0 + y1) * c
    if abs(a) < 1e-9:
        return [sum(p[0] for p in poly) / n, sum(p[1] for p in poly) / n]
    return [cx / (3 * a), cy / (3 * a)]


def _match(name: str, q: set[str]) -> str | None:
    """'exact' (same words), 'named' (every word of the name is in the query), 'leading' (the query is the name's
    first words: "Bramblemead" for "Bramblemead Valley"), 'part' (the query is elsewhere in the name: "Valley"),
    else None."""
    t = _terms(name)
    if not t or not q:
        return None
    if t == q:
        return "exact"
    if t <= q:
        return "named"
    if q <= t:
        lead = [w for w in (_stem(x) for x in words(name) if x not in STOP)][:len(q)]
        return "leading" if set(lead) == q else "part"
    return None


_RANK = {"exact": 0, "named": 1, "leading": 2, "part": 3}
_NEAR_WORDS = {"lodestone", "near", "by", "next", "beside", "at", "closest", "nearest"}  # "<place> lodestone" -> the place


def _pos(p) -> list[float] | None:
    if isinstance(p, (list, tuple)) and len(p) >= 2 and all(isinstance(x, (int, float)) for x in p[:3]):
        return [round(float(x), 2) for x in p[:3]]
    return None


def _d(a, b) -> float | None:
    v = dist(a, b, planar=True)
    return round(v) if v is not None else None


def _bestiary_vaults() -> dict:
    try:
        from .plan_sources import bestiary
        return bestiary().get("vaults") or {}
    except Exception:  # the bestiary is optional data
        return {}


def _intish(v) -> int | None:
    m = re.match(r"\s*(\d+)", str(v)) if v is not None else None
    return int(m.group(1)) if m else None


def _vault_rows(vaults: dict) -> dict[str, dict]:
    """bestiary vaults -> {name: {kind, aliases, area, power_level, position, approximate, basis}}: the door the game
    read when there is one, else the wiki map centre (approximate, within its stated metres), else no position."""
    out: dict[str, dict] = {}
    for key, v in (vaults or {}).items():
        if not isinstance(v, dict):
            continue
        name = v.get("name") or key
        door, centre = _pos((v.get("door") or {}).get("position")), _pos((v.get("map_centre") or {}).get("position"))
        if door:
            pos, approx = door, False
            basis = f"the vault's door, read by the game (build {(v.get('door') or {}).get('build')})"
        elif centre:
            acc = (v.get("map_centre") or {}).get("accuracy_m")
            pos, approx = centre, True
            basis = "the wiki map's centre for it" + (f" (within about {acc} m)" if acc else "") + "; its door is not read yet"
        else:
            pos, approx = None, True
            basis = "no position in the data" + (f"; the wiki puts it in {v['area']}" if v.get("area") else "")
        out[name] = {"name": name, "kind": str(v.get("kind") or "vault"), "aliases": [a for a in v.get("aliases") or [] if a],
                     "area": v.get("area"), "province": v.get("province"), "power_level": _intish(v.get("power_level")),
                     "position": pos, "approximate": approx, "basis": basis}
    return out


# ------------------------------------------------------------------------------ the resolver


class Places:
    def __init__(self, data: dict | str | Path | None = None, knowledge=None, vaults: dict | None = None):
        if data is None:
            f = newest_file()
            data = _load(str(f)) if f else {}
        elif not isinstance(data, dict):
            data = _load(str(data))
        self.data = data
        self.build = data.get("build")
        self.knowledge = knowledge
        self.regions: list[dict] = []
        for r in data.get("regions") or []:
            poly = r.get("polygon") if isinstance(r.get("polygon"), list) and len(r["polygon"]) >= 3 else None
            shape = poly or _bbox_poly(r.get("bbox"))
            if r.get("name") and shape:
                xs, ys = [q[0] for q in shape], [q[1] for q in shape]
                self.regions.append({**r, "_shape": shape, "_exact": poly is not None, "_area": area(shape),
                                     "_box": (min(xs), min(ys), max(xs), max(ys))})
        # region_at by point: the map is fixed for this object (its file is read once), so a point's region is too.
        # The job tree's map lines asked it ~4000 times a build (every landmark, per region and province), 1.6 s of
        # a 2.8 s build (profile 2026-11-19); bounded, cleared when full
        self._at: dict[tuple[float, float], dict | None] = {}
        self.provinces: list[dict] = [dict(p) for p in data.get("provinces") or [] if p.get("name")]
        if not self.provinces:  # older files: provinces only on the regions
            names = dict.fromkeys(r["province"] for r in self.regions if r.get("province"))
            self.provinces = [{"name": n} for n in names]
        for p in self.provinces:
            p.setdefault("regions", [r["name"] for r in self.regions if r.get("province") == p["name"]])
        self.landmarks: dict[str, list[dict]] = {}
        for lm in data.get("landmarks") or []:
            if lm.get("name") and _pos(lm.get("position")):
                self.landmarks.setdefault(lm["name"], []).append(lm)
        # the vaults and dungeons of data/bestiary.json (tools/build_vaults.py): name, aliases, kind, power level, and
        # the door the game read, else the wiki's map centre. The game's landmark registry has no vault doors: L3
        # 2026-11-19 read "the vault" as the Vault Guardian landmarks 3.5 km off while Crasorak Kara's door was 223 m
        self.vaults: dict[str, dict] = _vault_rows(_bestiary_vaults() if vaults is None else vaults)

    @property
    def source(self) -> str:
        return f"game data (build {self.build})"

    # ---------------------------------------------------------------- geometry over regions

    def region_at(self, pos) -> dict | None:
        """The smallest region containing ``pos`` (polygons when read, else bounding boxes), or None."""
        p = _pos(pos)
        if p is None:
            return None
        key = (p[0], p[1])
        if key in self._at:
            return self._at[key]
        x, y = key
        hits = [r for r in self.regions if r["_box"][0] <= x <= r["_box"][2] and r["_box"][1] <= y <= r["_box"][3]
                and inside(r["_shape"], x, y)]
        best = min(hits, key=lambda r: r["_area"]) if hits else None
        if len(self._at) >= AT_CACHE:
            self._at.clear()
        self._at[key] = best
        return best

    def region_name(self, pos) -> str | None:
        r = self.region_at(pos)
        return r["name"] if r else None

    def province_name(self, pos) -> str | None:
        """The province of the region at ``pos`` (data/places_<build>.json mapping), or None."""
        r = self.region_at(pos)
        return r.get("province") if r else None

    def _in_province(self, pos, province: str) -> bool:
        return self.province_name(pos) == province

    def _in_region(self, pos, region: dict) -> bool:
        r = self.region_at(pos)
        return r is not None and r["name"] == region["name"]

    # ---------------------------------------------------------------- answers

    def _spot(self, pos, here, lodestones) -> dict:
        r = self.region_at(pos)
        out: dict[str, Any] = {"position": pos, "region": r["name"] if r else None,
                               "province": r.get("province") if r else None}
        if here is not None:
            out["distance_m"] = _d(here, pos)
        if lodestones:
            ln = min(lodestones, key=lambda l: _d(l["position"], pos) or 1e12)
            out["nearest_lodestone"] = {k: v for k, v in {
                "id": ln.get("id"), "name": ln.get("name"), "distance_from_it_m": _d(ln["position"], pos),
                "can_teleport_now": ln.get("can_teleport_now"), "cost": ln.get("cost")}.items() if v is not None}
        return out

    def _landmark_answer(self, name: str, how: str, here, lodestones, within: list[dict] | None = None) -> dict:
        rows = self.landmarks[name]
        spots = [self._spot(_pos(r["position"]), here, lodestones) for r in rows]
        if within:
            names = {w["name"] for w in within}
            keep = [s for s in spots if s["region"] in names or s["province"] in names]
            spots = keep or spots
        spots.sort(key=lambda s: s.get("distance_m") if s.get("distance_m") is not None else 1e12)
        mine = self.province_name(here) if here is not None else None
        first = next((s for s in spots if mine and s["province"] == mine), spots[0])
        ans = {"name": name, "kind": "landmark", "match": how, "source": self.source, "approximate": False,
               **first, "basis": "a named point in the game's map registry"}
        if mine:
            ans["your_province"] = mine
        if len(spots) > 1:
            by: dict[str, int] = {}
            for s in spots:
                k = s["province"] or "no province"
                by[k] = by.get(k, 0) + 1
            ans["spots"] = spots[:SPOTS]
            ans["spots_by_province"] = by
            if len(by) > 1:
                ans["other_provinces"] = [p for p in by if p != first["province"]]
                at = lambda s: (f"{s['region']}" + (f", {s['distance_m']} m" if s.get("distance_m") is not None  # noqa: E731
                                                    else ""))
                others = [next(s for s in spots if (s["province"] or "no province") == p) for p in ans["other_provinces"]]
                lead = (f"copy in {mine} (your province) at {at(first)}" if mine and first["province"] == mine
                        else (f"no copy in {mine} (your province); nearest " if mine
                              else "nearest " if here is not None else "a ")
                        + f"copy in {first['province']} at {at(first)}")
                ans["summary"] = (f"{name}: {lead}; other copies in "
                                  + ", ".join(f"{s['province'] or 'no province'} ({at(s)})" for s in others))
                same = by.get(first["province"] or "no province", 0)
                ans["basis"] += (f"; the registry has {len(rows)} spots with this name across {len(by)} provinces "
                                 f"({', '.join(f'{p}: {n}' for p, n in by.items())}). An NPC like this exists as "
                                 "several copies in different provinces: the copy that matters is normally the one "
                                 "in the province you are in or progressing through"
                                 + (f"; {same} spots in {first['province']}: which one he is at is unknown until "
                                    "you see it" if same > 1 else "")
                                 + ". Spots are listed nearest first, each with its province")
            else:
                ans["basis"] += (f"; the registry has {len(rows)} spots with this name, all in {next(iter(by))}: "
                                 "nearest first, which one is the one you want is unknown until you see it")
        return ans

    def _region_answer(self, r: dict, how: str, here, lodestones, known: list[dict]) -> dict:
        ans: dict[str, Any] = {"name": r["name"], "kind": "region", "match": how, "source": self.source,
                               "power_level": r.get("power"), "province": r.get("province")}
        if not r["_exact"]:
            ans["shape"] = "bounding box only (the boundary polygon has not been read yet): 'inside' is approximate"
        if here is not None and self._in_region(here, r):
            ans.update({"you_are_inside": True, "position": _pos(here), "region": r["name"],
                        "province": r.get("province"), "distance_m": 0,
                        "approximate": False,
                        "basis": "you are in it now (by the game's region boundary)" if r["_exact"]
                        else "you are probably in it (by its bounding box)"})
            return ans
        # the best known point inside it: what he knows himself, then game landmarks, else its centre
        cands = [(k, p) for k, p in known if self._in_region(p, r)]
        for lname, rows in self.landmarks.items():
            cands += [(f"landmark {lname}", _pos(x["position"])) for x in rows if self._in_region(x["position"], r)]
        if cands:
            if here is not None:
                cands.sort(key=lambda c: _d(here, c[1]) or 1e12)
            label, p = cands[0]
            ans.update(self._spot(p, here, lodestones))
            ans["region"], ans["province"] = r["name"], r.get("province")
            ans.update({"approximate": not r["_exact"], "via": label,
                        "basis": f"the nearest known point inside the region ({label})"})
        else:
            c = centroid(r["_shape"])
            z = r.get("z")
            ans.update(self._spot([round(c[0], 2), round(c[1], 2), z if isinstance(z, (int, float)) else 0.0],
                                  here, lodestones))
            ans.update({"approximate": True, "basis": "the centre of the region's shape: no known point inside it, "
                        "height unknown, not checked for ground or a path"})
        return ans

    def _province_answer(self, prov: dict, how: str, here, lodestones, known: list) -> dict:
        """A province (the big area): its sub-regions, the lodestones and points he knows in it, and its nearest
        known point (else the game landmark nearest him in it, else a region centre marked approximate)."""
        name = prov["name"]
        regions = [r for r in self.regions if r.get("province") == name]
        ans: dict[str, Any] = {"name": name, "kind": "province", "match": how, "source": self.source,
                               "regions": [{"name": r["name"], "power_level": r.get("power")} for r in regions]}
        powers = [r["power"] for r in regions if isinstance(r.get("power"), int) and r["power"] >= 0]
        if powers:
            ans["power_levels"] = [min(powers), max(powers)]
        far = lambda p: (_d(here, p) or 1e12) if here is not None else 0  # noqa: E731
        lodes_in = sorted((l for l in lodestones if self._in_province(l["position"], name)),
                          key=lambda l: far(l["position"]))
        if lodes_in:
            ans["lodestones"] = [{k: v for k, v in {
                "id": l.get("id"), "name": l.get("name"), "region": self.region_name(l["position"]),
                "distance_m": _d(here, l["position"]) if here is not None else None,
                "can_teleport_now": l.get("can_teleport_now")}.items() if v is not None} for l in lodes_in[:5]]
        mine = sorted(((k, p) for k, p in known if self._in_province(p, name) and not k.startswith("lodestone")),
                      key=lambda c: far(c[1]))
        if mine:
            ans["known_points"] = [{"what": k, "position": p, "region": self.region_name(p),
                                    **({"distance_m": _d(here, p)} if here is not None else {})} for k, p in mine[:5]]
        if here is not None and self._in_province(here, name):
            ans.update({"you_are_inside": True, "position": _pos(here), "region": self.region_name(here),
                        "province": name, "distance_m": 0, "approximate": False,
                        "basis": "you are in it now (by the game's region boundaries and the province mapping)"})
            return ans
        cands, what = sorted(((k, p) for k, p in known if self._in_province(p, name)), key=lambda c: far(c[1])), \
            "point you know"
        if not cands:
            what = "game landmark"
            cands = sorted(((f"landmark {n}", _pos(x["position"])) for n, rows in self.landmarks.items()
                            for x in rows if self._in_province(x["position"], name)), key=lambda c: far(c[1]))
        if cands:
            label, p = cands[0]
            ans.update(self._spot(p, here, lodestones))
            ans.update({"approximate": False, "via": label,
                        "basis": f"the nearest {what} inside the province ({label})"})
        elif regions:
            r = max(regions, key=lambda r: r["_area"])
            c = centroid(r["_shape"])
            ans.update(self._spot([round(c[0], 2), round(c[1], 2), 0.0], here, lodestones))
            ans.update({"approximate": True, "basis": f"the centre of its biggest region {r['name']}: no known point "
                        "inside the province, height unknown, not checked for ground or a path"})
        return ans

    def _vault_match(self, v: dict, q: set[str]) -> str | None:
        """Its name; an alias said in full ("Temple Woods vault"; its first words "Temple" are the region's, not the
        vault's); the bare kind word ("vault") as a part match."""
        how = _match(v["name"], q)
        for a in v["aliases"]:
            h = _match(a, q)
            if h in ("exact", "named") and (how is None or _RANK[h] < _RANK[how]):
                how = h
        if how is None and q == _terms(v["kind"]):
            how = "part"
        return how

    def _vault_answer(self, v: dict, how: str, here, lodestones) -> dict:
        ans: dict[str, Any] = {"name": v["name"], "kind": v["kind"], "match": how,
                               "source": "data/bestiary.json (wiki vault pages + the game's door reads)",
                               "approximate": v["approximate"], "power_level": v["power_level"], "basis": v["basis"]}
        if v["position"]:
            ans.update(self._spot(v["position"], here, lodestones))
        else:
            ans.update({"position": None, "region": v.get("area"), "province": v.get("province")})
        return ans

    def vault_label(self, v: dict, here) -> str:
        """'Crasorak Kara (a vault in Temple Woods, PL 2, 223 m)'."""
        d = _d(here, v["position"]) if _pos(here) and v["position"] else None
        bits = [f"a {v['kind']}" + (f" in {v['area']}" if v.get("area") else "")]
        if v.get("power_level") is not None:
            bits.append(f"PL {v['power_level']}")
        bits.append((f"{d:.0f} m" + (" (approximate)" if v["approximate"] else "")) if d is not None
                    else "position not known" if not v["position"] else "")
        return f"{v['name']} ({', '.join(b for b in bits if b)})"

    def _lodestone_by(self, rest: set[str], here, lodes: list[dict]) -> list[dict]:
        """"the lodestone by the Wise Old Man" / "Zanik lodestone": the lodestone nearest the map place of that name
        (its spot nearest to him). Lodestones carry no names in the game, so a player names one by what stands by it."""
        out = []
        for name, rows in self.landmarks.items():
            how = _match(name, rest)
            if how not in ("exact", "named"):
                continue
            pts = [p for p in (_pos(r.get("position")) for r in rows) if p]
            if not pts:
                continue
            at = min(pts, key=lambda p: _d(here, p) or 0.0) if here else pts[0]
            ln = min(lodes, key=lambda l: _d(l["position"], at) or 1e12)
            gap = _d(ln["position"], at)
            out.append({"name": f"lodestone by {name}", "kind": "lodestone", "match": how, "approximate": False,
                        "source": "lodestones (live) + game map", "id": ln.get("id"),
                        "basis": f"the lodestone nearest {name}" + (f" ({gap:.0f} m from it)" if gap is not None else ""),
                        **self._spot(ln["position"], here, None)})
        return out

    def name_at(self, pos, max_m: float = 4.0) -> str | None:
        """The game-map landmark name standing at ``pos`` (within ``max_m`` horizontally, 5 m vertically), else None.
        Lets a seen thing carry the map's name: the census calls every vent "Anima Vent", the map knows it's the Law one."""
        p = _pos(pos)
        if not p:
            return None
        best, best_d = None, max_m
        for name, rows in self.landmarks.items():
            for lm in rows:
                q = _pos(lm.get("position"))
                if not q:
                    continue
                d = ((p[0] - q[0]) ** 2 + (p[1] - q[1]) ** 2) ** 0.5
                if d <= best_d and (len(p) < 3 or len(q) < 3 or abs(p[2] - q[2]) <= 5.0):
                    best, best_d = name, d
        return best

    def name_for(self, thing: str | None, pos, max_m: float = 4.0) -> str | None:
        """The game map's name for a seen thing: the nearest landmark at its spot whose name holds every word of the
        thing's own name ("Law Anima Vent" for the census's "Anima Vent"). A landmark of something else that stands
        there is not its name: brain logs of 2026-11-15 to 17 showed ash-log piles within 4 m of Vannaka's map spot
        as "Vannaka" (121 of 123 renamed look rows carried another thing's name)."""
        q, p = _terms(thing or ""), _pos(pos)
        if not (q and p):
            return None
        best, best_d = None, max_m
        for name, rows in self.landmarks.items():
            if not q <= _terms(name):
                continue
            for lm in rows:
                at = _pos(lm.get("position"))
                if not at:
                    continue
                d = ((p[0] - at[0]) ** 2 + (p[1] - at[1]) ** 2) ** 0.5
                if d <= best_d and (len(p) < 3 or len(at) < 3 or abs(p[2] - at[2]) <= 5.0):
                    best, best_d = name, d
        return best

    def similar(self, query: str, here=None, k: int = 3) -> list[str]:
        """Map names (landmarks, regions) sharing a word with ``query``, most shared words first, then nearest:
        "temple entrance" -> "Forgotten Temple (landmark, 180 m)". Information for the model, never a choice."""
        q = _terms(query)
        here = _pos(here)
        cands: list[tuple[int, float, str]] = []
        for name, rows in self.landmarks.items():
            shared = len(_terms(name) & q)
            if shared:
                ds = [dist(here, _pos(r.get("position"))) for r in rows if here and _pos(r.get("position"))]
                d = min(ds) if ds else float("inf")
                cands.append((shared, d, f"{name} (landmark" + (f", {d:.0f} m)" if d != float("inf") else ")")))
        for r in self.regions:
            shared = len(_terms(r["name"]) & q)
            if shared:
                inside_r = bool(here) and self.region_at(here) is r
                shape = r.get("_shape") or r.get("polygon")
                c = centroid(shape) if shape and len(shape) >= 3 and not inside_r else None
                d = 0.0 if inside_r else (dist(here, c) if here and c else float("inf"))
                where = "you are in it" if inside_r else (f"centre ~{d:.0f} m" if d != float("inf") else "")
                cands.append((shared, d, f"{r['name']} (region" + (f", {where})" if where else ")")))
        cands.sort(key=lambda c: (-c[0], c[1]))
        out: list[str] = []
        for _, _, label in cands:
            if label not in out:
                out.append(label)
        return out[:k]

    def _said(self, q: set[str]) -> tuple[list[tuple[str, str]], dict[str, str]]:
        """The map names whose every word is in ``q`` ([(name, kind)]; a name inside a longer one said is not its own)
        and {a vault's name or alias: the vault's name}. Landmarks of one word ("Statue", "Cow") are too common."""
        names = [(n, "landmark") for n in self.landmarks if len(_terms(n)) >= 2]
        names += [(r["name"], "region") for r in self.regions] + [(p["name"], "province") for p in self.provinces]
        alias_of: dict[str, str] = {}  # a vault's name or alias said in full ("the Temple Woods vault") names it
        for v in self.vaults.values():
            for n in [v["name"], *v["aliases"]]:
                if len(_terms(n)) >= 2:
                    names.append((n, "vault"))
                    alias_of[n] = v["name"]
        hits = [(n, kind) for n, kind in names if _terms(n) and _terms(n) <= q]
        hits = [(n, kind) for n, kind in hits if not any(_terms(n) < _terms(m) for m, _ in hits)]
        return hits, alias_of

    def named(self, text: str, here=None, k: int = 2) -> list[dict]:
        """The places said in ``text`` that the data gives a power level, as data: [{name, kind, power_level, said,
        distance_m?}]. A vault or region by its full name or alias (the longest name first); the data's own kind word
        of the vaults ("vault", from the bestiary rows) with no vault named: the vault nearest ``here``, as mentioned()
        lists it first in his situation."""
        q = _terms(text or "")
        if not q:
            return []
        hits, alias_of = self._said(q)
        here_p = _pos(here)
        out: list[dict] = []

        def add(name: str, kind: str, pl, said: str, pos=None) -> None:
            if pl is None or len(out) >= k or any(r["name"] == name for r in out):
                return
            r = {"name": name, "kind": kind, "power_level": pl, "said": said}
            if here_p and pos and (d := _d(here_p, pos)) is not None:
                r["distance_m"] = d
            out.append(r)
        for n, kind in sorted(hits, key=lambda h: -len(_terms(h[0]))):
            if kind == "vault":
                v = self.vaults[alias_of[n]]
                add(v["name"], v["kind"], v["power_level"], n, v["position"])
            elif kind == "region":
                add(n, "region", next(r for r in self.regions if r["name"] == n).get("power"), n)
        if here_p and not any(kind == "vault" for _, kind in hits):
            near = sorted((v for v in self.vaults.values() if v["position"] and _terms(v["kind"]) & q),
                          key=lambda v: _d(here_p, v["position"]) or 0)
            for v in near[:1]:
                add(v["name"], v["kind"], v["power_level"], f"{v['kind']} (the nearest)", v["position"])
        return out

    def mentioned(self, text: str, here=None, k: int = 2) -> list[str]:
        """Map names said in ``text`` (every word of the name is in it): regions, provinces and landmarks of two or
        more words ("Statue", "Cow" are too common to mean the map's one). The longest name wins over a name inside
        it. For the model: "the Astral Anima Vent" is a place go_to can take, not something to look for first."""
        q = _terms(text or "")
        if not q:
            return []
        hits, alias_of = self._said(q)
        out: list[str] = []
        said_vaults: set[str] = set()
        for n, kind in sorted(hits, key=lambda h: -len(_terms(h[0])))[:k]:
            here_p = _pos(here)
            if kind == "vault":
                v = self.vaults[alias_of[n]]
                if v["name"] not in said_vaults:
                    said_vaults.add(v["name"])
                    out.append((f"\"{n}\" is " if n != v["name"] else "") + self.vault_label(v, here)
                               + (f"; go_to \"{v['name']}\" walks to it" if v["position"] else
                                  "; its position is not in the data"))
                continue
            if kind != "landmark" and here_p and n in (self.region_name(here_p), self.province_name(here_p)):
                out.append(f"{n}: a {kind} on the game map; you are in it")
                continue
            best = next((o for o in self.where(n, here, limit=1)["data"].get("results") or []
                         if o.get("name") == n), None) or {}
            d = best.get("distance_m")
            go = f"the lodestone by {n}" if "lodestone" in q and kind == "landmark" else n
            out.append(f"{n}: a {kind} on the game map" + (f", nearest {d:.0f} m away" if isinstance(d, (int, float)) else "")
                       + (f" in {best['region']}" if best.get("region") and best["region"] != n else "")
                       + f"; go_to \"{go}\" walks " + ("to the lodestone nearest it" if go != n else "there"))
        # one word of a few map names ("the temple": Forgotten Temple or Temple Woods; live 2026-11-01 11:29 he
        # answered "the temple route won't path"): the candidates, for the model to pick or ask. A word in more than
        # 3 names ("vent") says nothing.
        everything = [(n, "landmark") for n in self.landmarks] + [(r["name"], "region") for r in self.regions] \
            + [(p["name"], "province") for p in self.provinces]
        covered = set().union(*(_terms(n) for n, _ in hits)) if hits else set()
        # a word that is the data's own kind of place ("vault": the bestiary's vaults), nearest first. The vaults'
        # names hold no such word ("Crasorak Kara"), so the map-name words below never reach them
        kinds: dict[str, list[dict]] = {}
        for v in self.vaults.values():
            for t in _terms(v["kind"]):
                kinds.setdefault(t, []).append(v)
        here_p = _pos(here)
        for w in sorted(t for t in q - covered if t in kinds):
            vs = sorted(kinds[w], key=lambda v: (v["position"] is None,
                                                  (_d(here_p, v["position"]) or 0) if here_p and v["position"] else 0))
            out.append(f"\"{w}\": the game's data has {len(vs)} {vs[0]['kind']}s; "
                       + ("nearest: " if here_p else "") + ", ".join(self.vault_label(v, here) for v in vs[:3])
                       + "; go_to takes the full name")
        for w in sorted(t for t in q - covered if len(t) >= 4):
            cands = [(n, kind) for n, kind in everything if w in _terms(n) and len(_terms(n)) >= 2]
            if not 1 <= len(cands) <= 3:
                continue
            bits = []
            for n, kind in cands:
                if kind != "landmark" and _pos(here) and n in (self.region_name(_pos(here)), self.province_name(_pos(here))):
                    bits.append(f"{n} (a {kind}; you are in it)")
                    continue
                best = next((o for o in self.where(n, here, limit=1)["data"].get("results") or []
                             if o.get("name") == n), None) or {}
                d = best.get("distance_m")
                bits.append(f"{n} (a {kind}" + (f", {d:.0f} m" if isinstance(d, (int, float)) else "") + ")")
            out.append(f"\"{w}\" is a word of the map names " + ", ".join(bits) + "; go_to takes the full name")
        return out

    def where(self, query: str, here=None, *, lodestones: Iterable[dict] | None = None,
              remembered: Iterable[dict] | None = None, saved: dict | None = None, limit: int = 4) -> dict:
        """Honest facts about where ``query`` is. ``remembered``: map memory sightings ({name, position, kind,
        last_seen}); ``saved``: StateStore.places() ({name: {position, note}}); ``lodestones``: the body's
        lodestones read ({id, name?, position, can_teleport_now?, cost?})."""
        q = _terms(query)
        if not q:
            return {"ok": False, "reason": "invalid_args", "data": {"error": "empty place name"}}
        here = _pos(here)
        lodes = [dict(l, position=_pos(l.get("position"))) for l in lodestones or [] if _pos(l.get("position"))]
        known: list[tuple[str, list[float]]] = []
        out: list[dict] = []
        for name, rec in (saved or {}).items():
            p = _pos((rec or {}).get("position"))
            if not p:
                continue
            known.append((f"saved place {name}", p))
            how = _match(name, q)
            if how:
                out.append({"name": name, "kind": "saved", "match": how, "source": "your saved places",
                            "approximate": False, "basis": "a place you saved" + (f": {rec['note']}" if rec.get("note") else ""),
                            **self._spot(p, here, lodes)})
        for s in remembered or []:
            p = _pos(s.get("position"))
            if not p or not s.get("name"):
                continue
            known.append((f"{s.get('kind') or 'thing'} {s['name']} you saw", p))
            how = _match(s["name"], q)
            if how:
                out.append({"name": s["name"], "kind": "remembered", "match": how, "source": "map memory",
                            "approximate": False, "seen_at": s.get("last_seen"),
                            "basis": f"you saw a {s.get('kind') or 'thing'} there", **self._spot(p, here, lodes)})
        for l in lodes:
            known.append((f"lodestone {l.get('name') or l.get('id')}", l["position"]))
            how = _match(str(l.get("name") or ""), q)
            if how:
                out.append({"name": l.get("name"), "kind": "lodestone", "match": how, "source": "lodestones (live)",
                            "approximate": False, "id": l.get("id"), "basis": "a lodestone in this world",
                            **self._spot(l["position"], here, None)})
        if lodes and "lodestone" in q and (rest := q - _NEAR_WORDS):
            out += self._lodestone_by(rest, here, lodes)
        for name in self.landmarks:
            how = _match(name, q)
            if how:
                out.append(self._landmark_answer(name, how, here, lodes))
        for r in self.regions:
            how = _match(r["name"], q)
            if how:
                out.append(self._region_answer(r, how, here, lodes, known))
        for pv in self.provinces:
            how = _match(pv["name"], q)
            if how:
                out.append(self._province_answer(pv, how, here, lodes, known))
        for v in self.vaults.values():  # data/bestiary.json: the game's map registry holds no vault doors
            how = self._vault_match(v, q)
            if how:
                out.append(self._vault_answer(v, how, here, lodes))
        wiki = None
        if not any(o["match"] in ("exact", "named") for o in out):
            wiki = self._via_wiki(query, q, here, lodes, known)
            out += wiki.get("results", [])
        out.sort(key=lambda o: (_RANK.get(o["match"], 3), o.get("approximate", True),
                                o.get("distance_m") if o.get("distance_m") is not None else 1e12))
        seen: set = set()
        out = [o for o in out if not ((o["kind"], o["name"]) in seen or seen.add((o["kind"], o["name"])))]
        data: dict[str, Any] = {"query": query, "found": bool(out), "results": out[:limit], "note": NOTE}
        if here is not None:
            data["you_are_in"] = self.region_name(here)
            data["you_are_in_province"] = self.province_name(here)
        if wiki and wiki.get("said"):
            data["wiki_said"] = wiki["said"]
        if not out:
            data["note"] = ("No place by that name in the game's map data, your saved places, your map memory or "
                            "the lodestones. Don't go_to it: say you don't know where it is, look it up, or ask.")
            data["regions_known"] = [r["name"] for r in self.regions]
            data["provinces_known"] = {p["name"]: p.get("regions") or [] for p in self.provinces}
            if lodes:
                data["lodestones"] = sorted(({"id": l.get("id"), "name": l.get("name"), "region": self.region_name(l["position"]),
                                              "province": self.province_name(l["position"]),
                                              "distance_m": _d(here, l["position"]) if here else None} for l in lodes),
                                            key=lambda l: l["distance_m"] if l["distance_m"] is not None else 1e12)[:5]
        return {"ok": True, "reason": None, "data": data}

    def _via_wiki(self, query: str, q: set[str], here, lodes, known) -> dict:
        """The wiki page NAMED by the query -> the game's region / landmark names it mentions -> their positions."""
        if self.knowledge is None:
            return {}
        try:
            res = self.knowledge.lookup(query)
        except Exception:  # knowledge is optional
            return {}
        pages = [r for r in (res.get("data") or {}).get("results") or []
                 if r.get("source") == "wiki" and _match(r.get("title") or "", q) in ("exact", "named")]
        if not pages:
            return {}
        text = "\n".join(p.get("text") or "" for p in pages)
        regions = [r for r in self.regions if re.search(rf"(?<!\w){re.escape(r['name'])}(?!\w)", text)]
        provs = [p for p in self.provinces if re.search(rf"(?<!\w){re.escape(p['name'])}(?!\w)", text)]
        marks = [n for n in self.landmarks if len(n) > 2 and re.search(rf"(?<!\w){re.escape(n)}(?!\w)", text)]
        said = {"page": pages[0].get("title"), "url": pages[0].get("url"),
                "mentions": [r["name"] for r in regions] + marks}
        title = pages[0].get("title")
        named = ", ".join(said["mentions"])
        results = []
        for n in marks:
            a = self._landmark_answer(n, "wiki", here, lodes, within=regions + provs)
            inr = f" inside {a['region']}" if a.get("region") in {r["name"] for r in regions} else ""
            a.update({"for": query, "source": f"wiki page {title!r} (community) + {self.source}",
                      "basis": f"not {query!r} itself: the wiki page {title!r} names {named}; this is the game's "
                               f"{n} spot{inr}. " + a["basis"]})
            results.append(a)
        if not results:
            for r in regions:
                a = self._region_answer(r, "wiki", here, lodes, known)
                a.update({"for": query, "source": f"wiki page {title!r} (community) + {self.source}",
                          "basis": f"not {query!r} itself: the wiki page {title!r} names the region {r['name']}; "
                                   f"its exact spot there is unknown. " + a["basis"]})
                results.append(a)
        return {"results": results, "said": said if (regions or marks) else None}


# ------------------------------------------------------------------------------ tool doc + handler


WHERE_TOOL = {"type": "function", "function": {
    "name": "where",
    "description": ("Where a named place, province, region, NPC or landmark is in the world: its position (from game "
                    "data, your saved places, map memory or lodestones), how exact it is, its region and province, "
                    "your distance, and the lodestone nearest it; an NPC with copies in several provinces lists each "
                    "copy with its province. Use before go_to / teleport to a name; unknown names say so."),
    "parameters": {"type": "object", "properties": {"place": {"type": "string"}}, "required": ["place"]}}}


@lru_cache(maxsize=1)
def default_places() -> Places:
    from .knowledge import open_knowledge
    return Places(knowledge=open_knowledge())


def where_from_snapshot(places: Places, args: dict, state: dict | None = None, map_snapshot: dict | None = None,
                        saved: dict | None = None, lodestones: list[dict] | None = None) -> dict:
    """The research-tool handler: ``where {place}`` over the brain's own snapshot (state.position, map memory
    sightings incl. lodestones he saw, saved places)."""
    state = state or {}
    sightings = list((map_snapshot or {}).get("sightings") or [])
    lodes = list(lodestones or [])
    if not lodes:  # lodestones he perceived (map memory) when the body's lodestones read was not passed
        lodes = [{"id": s.get("id"), "name": s.get("name"), "position": s.get("position")}
                 for s in sightings if "lodestone" in str(s.get("class") or s.get("name") or "").lower()]
    return places.where(str(args.get("place") or args.get("query") or ""), state.get("position"),
                        lodestones=lodes, remembered=sightings, saved=saved)

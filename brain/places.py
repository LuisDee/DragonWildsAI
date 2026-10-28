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
from .knowledge import _terms, data_dir

SPOTS = 6  # spots listed per landmark name
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
    """'exact' (same words), 'named' (every word of the name is in the query), 'part' (the query is part of the
    name, e.g. "Bramblemead" for "Bramblemead Valley"), else None."""
    t = _terms(name)
    if not t or not q:
        return None
    if t == q:
        return "exact"
    if t <= q:
        return "named"
    if q <= t:
        return "part"
    return None


_RANK = {"exact": 0, "named": 1, "part": 2}


def _pos(p) -> list[float] | None:
    if isinstance(p, (list, tuple)) and len(p) >= 2 and all(isinstance(x, (int, float)) for x in p[:3]):
        return [round(float(x), 2) for x in p[:3]]
    return None


def _d(a, b) -> float | None:
    v = dist(a, b, planar=True)
    return round(v) if v is not None else None


# ------------------------------------------------------------------------------ the resolver


class Places:
    def __init__(self, data: dict | str | Path | None = None, knowledge=None):
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
                self.regions.append({**r, "_shape": shape, "_exact": poly is not None, "_area": area(shape)})
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

    @property
    def source(self) -> str:
        return f"game data (build {self.build})"

    # ---------------------------------------------------------------- geometry over regions

    def region_at(self, pos) -> dict | None:
        """The smallest region containing ``pos`` (polygons when read, else bounding boxes), or None."""
        p = _pos(pos)
        if p is None:
            return None
        hits = [r for r in self.regions if inside(r["_shape"], p[0], p[1])]
        return min(hits, key=lambda r: r["_area"]) if hits else None

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

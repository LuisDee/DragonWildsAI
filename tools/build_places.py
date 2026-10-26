"""Normalise the game's place data into data/places_<build>.json for brain/places.py (BUGS A5).

Sources (game data read by reflection; no wiki text, so the file is committed like items_<build>.json):
  * preferred: logs/places_raw_latest.json, written by client_mod/commands/places_dump.lua (live check
    tools/live_checks/places_dump.json): region boundary POLYGONS, landmarks, and whether our point-in-polygon
    agreed with the game's own CurrentMapRegion at his position;
  * fallback: the 2026-10-25 server probe dumps logs/regions.json + logs/landmarks.json
    (mod/experiments/travel_probe.lua): region bounding boxes only (no polygon), the same landmarks.

    .venv/Scripts/python.exe -m tools.build_places                 # raw dump if present, else the legacy probe files
    .venv/Scripts/python.exe -m tools.build_places --legacy        # force the legacy files
    .venv/Scripts/python.exe -m tools.build_places --raw <file> --build 26161880

Map regions and landmarks are placed in the map (L_World), so they are the same in every world of a build;
lodestones are per world and are NOT in this file (the body's `lodestones` read / map memory give them).

Provinces: the big areas players name (Brynmoor, Ghornfell, Fellhollow, Dowdun Reach, Umbral Sands, Scorned
Wilderness). The 31 map regions are their SUB-regions; AMapRegion has no parent/province field (dump 26161880).
  * province NAMES: the game's own ``EQuestRegion`` enum (dumps/<build>/luatypes/Dominion_enums.lua), kept in the
    output so the brain never needs the dump;
  * region -> province, in trust order: a ``MapRegionTag`` whose hierarchy names a province (game; needs the
    region tags in the raw dump, live check tools/live_checks/places_region_tags.json); the region's own wiki
    infobox ``location:``; the wiki Ashenfall page's per-province lists (``Ashenfall#<Province>``); a region named
    like a province is that province; a region lying inside another region's bounds takes that region's province.
    Only NAMES come from the wiki (the local mirror data/wiki/knowledge.sqlite), never positions. Without the
    mirror the previous file's mapping is kept. Every region records ``province_source``.
"""
from __future__ import annotations

import argparse
import json
import re
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = "dw_places/1"


def _payload(d: dict) -> dict:
    """A probe reply ({ok, data: {result: {...}}}) or a bare dump -> the dump."""
    while isinstance(d, dict) and ("data" in d or "result" in d) and not ("regions" in d or "landmarks" in d):
        d = d.get("data") or d.get("result") or {}
    return d if isinstance(d, dict) else {}


def _num(v):
    return float(v) if isinstance(v, (int, float)) else None


def _region(r: dict) -> dict | None:
    name = (r.get("name") or "").strip()
    if not name:
        return None
    poly = [[round(float(p[0]), 2), round(float(p[1]), 2)] for p in r.get("polygon") or []
            if isinstance(p, (list, tuple)) and len(p) >= 2]
    bbox = r.get("bbox") or (r.get("spline") or {}).get("bbox_m")
    if poly and not bbox:
        xs, ys = [p[0] for p in poly], [p[1] for p in poly]
        bbox = [min(xs), min(ys), max(xs), max(ys)]
    out = {"name": name, "region_id": r.get("region_id"), "power": r.get("power"),
           "polygon": poly if len(poly) >= 3 else None,
           "bbox": [round(float(x), 2) for x in bbox] if bbox and len(bbox) == 4 else None}
    tag = r.get("tag")
    if isinstance(tag, str) and tag and tag != "None":
        out["tag"] = tag
    return out


def _landmark(l: dict) -> dict | None:
    name = (l.get("desc") or "").strip()
    pos = l.get("position") or l.get("loc")
    if not name or not (isinstance(pos, list) and len(pos) == 3 and all(_num(x) is not None for x in pos)):
        return None
    out = {"name": name, "position": [round(float(x), 2) for x in pos]}
    cat = l.get("category", l.get("cat"))
    if cat is not None:
        out["category"] = cat
    if l.get("discover") is not None:
        out["needs_discovery"] = bool(l.get("discover"))
    return out


# ------------------------------------------------------------------------------ provinces


def _words(s: str) -> tuple[str, ...]:
    return tuple(re.findall(r"[a-z0-9]+", (s or "").lower().replace("'", "")))


def _same(a: str, b: str) -> bool:
    """Same name ignoring case, punctuation and spaces ("SandReach" in a tag == "Sand Reach")."""
    return bool(_words(a)) and "".join(_words(a)) == "".join(_words(b))


def game_provinces(build: str, dumps: Path | None = None) -> list[dict]:
    """The game's own province list: ``EQuestRegion`` (None/MAX dropped, '_' -> ' ')."""
    f = Path(dumps or ROOT / "dumps") / build / "luatypes" / "Dominion_enums.lua"
    try:
        text = f.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    m = re.search(r"local EQuestRegion = \{(.*?)\}", text, re.S)
    return [{"name": n.replace("_", " "), "quest_region_id": int(v)}
            for n, v in re.findall(r"(\w+)\s*=\s*(\d+)", m.group(1) if m else "") if n not in ("None", "MAX")]


def wiki_province_facts(names: list[str], provinces: list[str], db: Path | None = None) -> dict[str, tuple[str, str]]:
    """{region name: (province, source)} from the wiki mirror: the region page's infobox ``location:`` first, then
    the Ashenfall page's per-province lists. Only game province names count."""
    db = Path(db or ROOT / "data" / "wiki" / "knowledge.sqlite")
    if not db.exists() or not provinces:
        return {}
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        rows = con.execute("SELECT title, url, body FROM docs").fetchall()
        con.close()
    except sqlite3.Error:
        return {}
    prov = {_words(p): p for p in provinces}
    infobox: dict[str, tuple[str, str]] = {}
    lists: dict[str, tuple[str, str]] = {}
    for title, url, body in rows:
        url, body = url or "", body or ""
        if title == "Ashenfall" and "#" in url:
            p = prov.get(_words(url.split("#", 1)[1].replace("_", " ")))
            for item in re.findall(r"^- (.+)$", body, re.M) if p else []:
                lists.setdefault(_words(item), (p, url))
        elif "#" not in url:
            m = re.search(r"^location: (.+)$", body, re.M)
            p = prov.get(_words(m.group(1))) if m else None
            if p:
                infobox.setdefault(_words(title), (p, f"wiki infobox location: {url}"))
    out = {}
    for n in names:
        hit = infobox.get(_words(n)) or (lambda h: (h[0], f"wiki list: {h[1]}") if h else None)(lists.get(_words(n)))
        if hit:
            out[n] = hit
    return out


def _shape(r: dict):
    from brain.places import _bbox_poly
    return r.get("polygon") or _bbox_poly(r.get("bbox"))


def assign_provinces(regs: list[dict], provinces: list[dict], *, wiki: dict | None = None,
                     previous: dict | None = None) -> None:
    """Set ``province`` + ``province_source`` on each region, in the trust order of the module doc."""
    names = [p["name"] for p in provinces]
    wiki, previous = wiki or {}, previous or {}
    for r in regs:
        tag_hit = next((p for seg in (r.get("tag") or "").split(".") for p in names if _same(seg, p)), None)
        own = next((p for p in names if _same(r["name"], p)), None)
        if tag_hit:
            r["province"], r["province_source"] = tag_hit, f"game MapRegionTag {r['tag']}"
        elif r["name"] in wiki:
            r["province"], r["province_source"] = wiki[r["name"]]
        elif own:
            r["province"], r["province_source"] = own, "the region has the province's name (game EQuestRegion)"
        elif (previous.get(r["name"]) or {}).get("province"):
            r["province"] = previous[r["name"]]["province"]
            r["province_source"] = previous[r["name"]].get("province_source")
    from brain.places import area, centroid, inside
    for r in regs:  # a region lying inside a bigger one (e.g. a raid hub inside its raid area)
        s = _shape(r)
        if not r.get("province") and s:
            c, a = centroid(s), area(s)
            outer = [(area(_shape(o)), o) for o in regs if o is not r and o.get("province") and _shape(o)
                     and area(_shape(o)) > a and inside(_shape(o), c[0], c[1])]
            if outer:
                o = min(outer, key=lambda t: t[0])[1]
                r["province"] = o["province"]
                r["province_source"] = f"geometry: its centre lies inside the bigger region {o['name']}"
                continue
            # else: it overlaps regions of exactly one province (some of its boundary points lie inside them)
            touch = [o for o in regs if o is not r and o.get("province") and _shape(o)
                     and any(inside(_shape(o), p[0], p[1]) for p in s)]
            if len({o["province"] for o in touch}) == 1:
                r["province"] = touch[0]["province"]
                r["province_source"] = (f"geometry (inferred): it overlaps only {touch[0]['province']} regions "
                                        f"({', '.join(o['name'] for o in touch)})")
    for r in regs:
        r.setdefault("province", None)
        r.setdefault("province_source", None)


def _locate_landmarks(regs: list[dict], lms: list[dict]) -> None:
    from brain.places import Places  # the same smallest-region rule the resolver uses
    p = Places({"regions": regs, "landmarks": []})
    for l in lms:
        r = p.region_at(l["position"])
        l["region"] = r["name"] if r else None
        l["province"] = r.get("province") if r else None


def normalise(regions: list, landmarks: list, *, build: str, source: dict, provinces: list[dict] | None = None,
              wiki: dict | None = None, previous: dict | None = None) -> dict:
    regs = sorted(filter(None, map(_region, regions)), key=lambda r: (r["region_id"] is None, r["region_id"] or 0))
    lms = sorted(filter(None, map(_landmark, landmarks)), key=lambda l: (l["name"].lower(), l["position"]))
    provinces = [dict(p) for p in provinces or []]
    assign_provinces(regs, provinces, wiki=wiki, previous=previous)
    _locate_landmarks(regs, lms)
    for p in provinces:
        p["regions"] = [r["name"] for r in regs if r["province"] == p["name"]]
    return {"schema": SCHEMA, "build": build, "map": "L_World",
            "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "source": source,
            "note": "Game data read by reflection. Positions are metres [x, y, z]. A region without a polygon has only "
                    "its bounding box (approximate). Landmark names come from the game's map registry "
                    "(UserVisibleDescription); a name can have several spots: an NPC such as Zanik or Vannaka has a "
                    "separate copy in each province (Luis, 2026-10-26). 'provinces' are the big areas players name "
                    "(game EQuestRegion); the regions are their sub-regions, each with its 'province_source'.",
            "provinces": provinces, "regions": regs, "landmarks": lms}


def newest_build(data: Path) -> str:
    files = sorted(data.glob("items_*.json"))
    return files[-1].stem.split("_", 1)[1] if files else "unknown"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--raw", type=Path, default=ROOT / "logs" / "places_raw_latest.json")
    ap.add_argument("--legacy", action="store_true", help="use logs/regions.json + logs/landmarks.json")
    ap.add_argument("--build", default=None)
    ap.add_argument("--out", type=Path, default=None)
    a = ap.parse_args(argv)
    build = a.build or newest_build(ROOT / "data")
    if not a.legacy and a.raw.exists():
        raw = _payload(json.loads(a.raw.read_text(encoding="utf-8-sig")))
        src = {"kind": "live_client_dump", "file": str(a.raw.relative_to(ROOT)) if a.raw.is_relative_to(ROOT) else str(a.raw),
               "wall": raw.get("wall"), "self_check": {"game_region": (raw.get("me") or {}).get("game_region"),
                                                       "computed_region": raw.get("computed_region"),
                                                       "agrees": raw.get("agrees")}}
        raw_regions, raw_lms = raw.get("regions") or [], raw.get("landmarks") or []
    else:
        regs = _payload(json.loads((ROOT / "logs" / "regions.json").read_text(encoding="utf-8-sig")))
        lms = _payload(json.loads((ROOT / "logs" / "landmarks.json").read_text(encoding="utf-8-sig")))
        raw_regions, raw_lms = regs.get("regions") or [], lms.get("landmarks") or []
        src = {"kind": "legacy_server_probe", "files": ["logs/regions.json", "logs/landmarks.json"],
               "read": "2026-10-25 dev server, mod/experiments/travel_probe.lua (bounding boxes only)"}
    out = a.out or ROOT / "data" / f"places_{build}.json"
    try:
        previous = {r["name"]: r for r in json.loads(out.read_text(encoding="utf-8")).get("regions") or []}
    except (OSError, ValueError):
        previous = {}
    provinces = game_provinces(build)
    names = [str(r.get("name")).strip() for r in raw_regions if r.get("name")]
    doc = normalise(raw_regions, raw_lms, build=build, source=src, provinces=provinces,
                    wiki=wiki_province_facts(names, [p["name"] for p in provinces]), previous=previous)
    out.write_text(json.dumps(doc, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    polys = sum(1 for r in doc["regions"] if r["polygon"])
    print(f"{out.relative_to(ROOT) if out.is_relative_to(ROOT) else out}: {len(doc['regions'])} regions "
          f"({polys} with polygons, {sum(1 for r in doc['regions'] if r['province'])} with a province), "
          f"{len(doc['landmarks'])} landmarks, {len(doc['provinces'])} provinces, source {doc['source']['kind']}")
    for r in doc["regions"]:
        if not r["province"]:
            print(f"  no province: {r['name']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

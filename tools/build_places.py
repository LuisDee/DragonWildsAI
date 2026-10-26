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
"""
from __future__ import annotations

import argparse
import json
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
    return {"name": name, "region_id": r.get("region_id"), "power": r.get("power"),
            "polygon": poly if len(poly) >= 3 else None,
            "bbox": [round(float(x), 2) for x in bbox] if bbox and len(bbox) == 4 else None}


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


def normalise(regions: list, landmarks: list, *, build: str, source: dict) -> dict:
    regs = sorted(filter(None, map(_region, regions)), key=lambda r: (r["region_id"] is None, r["region_id"] or 0))
    lms = sorted(filter(None, map(_landmark, landmarks)), key=lambda l: (l["name"].lower(), l["position"]))
    return {"schema": SCHEMA, "build": build, "map": "L_World",
            "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "source": source,
            "note": "Game data read by reflection. Positions are metres [x, y, z]. A region without a polygon has only "
                    "its bounding box (approximate). Landmark names come from the game's map registry "
                    "(UserVisibleDescription); an NPC can have several spots (it moves with quest stages).",
            "regions": regs, "landmarks": lms}


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
        doc = normalise(raw.get("regions") or [], raw.get("landmarks") or [], build=build, source=src)
    else:
        regs = _payload(json.loads((ROOT / "logs" / "regions.json").read_text(encoding="utf-8-sig")))
        lms = _payload(json.loads((ROOT / "logs" / "landmarks.json").read_text(encoding="utf-8-sig")))
        doc = normalise(regs.get("regions") or [], lms.get("landmarks") or [], build=build,
                        source={"kind": "legacy_server_probe", "files": ["logs/regions.json", "logs/landmarks.json"],
                                "read": "2026-10-25 dev server, mod/experiments/travel_probe.lua (bounding boxes only)"})
    out = a.out or ROOT / "data" / f"places_{build}.json"
    out.write_text(json.dumps(doc, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    polys = sum(1 for r in doc["regions"] if r["polygon"])
    print(f"{out.relative_to(ROOT) if out.is_relative_to(ROOT) else out}: {len(doc['regions'])} regions "
          f"({polys} with polygons), {len(doc['landmarks'])} landmarks, source {doc['source']['kind']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

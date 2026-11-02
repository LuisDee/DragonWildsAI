r"""Farming data profile from the game's own loaded data assets (no hand-written facts).

    .venv\Scripts\python.exe -m tools.build_farming [--src logs/farm/farm_data_probe-<ts>.json]

Input: client_mod/commands/farm_data_probe.lua's output (run on the live client: tools/farm_window.sh), i.e. every
FarmPlantDataAsset (crop: tier, plot tags, base yield, disease, harvest item, stages with CyclesToGrow), the seeds
(SeedHeldEquipmentData -> plant), FarmCompostData / FarmWaterData, the FarmingSettings CDO (cycle period, water and
compost needed per plot, digging charges, weed cycles), composters seen and every ItemData with CompostAmount > 0.
Output: data/farming_<build>.json, which brain/knowledge.py turns into authoritative lookup cards
("<Crop> (crop)", "Farming mechanics", "Compost"). Item names come from the item catalogs when the probe lacks them.
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _asset_id(path: str | None) -> str | None:
    """'/Game/.../FPD_Potato.FPD_Potato' -> 'FPD_Potato'."""
    if not path:
        return None
    return str(path).rsplit(".", 1)[-1].rsplit("/", 1)[-1]


def _names() -> dict[str, str]:
    out: dict[str, str] = {}
    for prefix in ("items", "recipes"):
        files = sorted((ROOT / "data").glob(f"{prefix}_*.json"))
        if not files:
            continue
        d = json.loads(files[-1].read_text(encoding="utf-8"))
        items = d.get("items") or {}
        for k, v in (items.items() if isinstance(items, dict) else ((x.get("id"), x) for x in items)):
            if isinstance(v, dict) and v.get("name") and k:
                out.setdefault(k, v["name"])
    return out


def _tier_words(tags: list[str]) -> list[str]:
    """Plot tags as the game names them: 'Farming.PlotTier.Ash' -> 'Ash' (the last tag segment)."""
    return [t.rsplit(".", 1)[-1] for t in tags or []]


COMPOST_TIERS = {"Item.Farming.Compostable": "regular", "Item.Farming.CompostableSuper": "super",
                 "Item.Farming.CompostableUltra": "ultra"}


def _reports() -> list[dict]:
    """data/farm_reports.json: game facts players reported, each with its source and how far it is checked."""
    f = ROOT / "data" / "farm_reports.json"
    if not f.exists():
        return []
    return [x for x in json.loads(f.read_text(encoding="utf-8")).get("reports") or [] if x.get("fact")]


def clock_of(src: Path | None) -> dict:
    """The game clock from client_mod/commands/farm_time_probe.lua: real minutes per in-game day, dawn, dusk, and
    one growth cycle (FarmingSettings.CyclePeriod real seconds) in in-game hours (ConvertRealTimeSecondsToInGameTime)."""
    if not src or not src.exists():
        return {}
    raw = json.loads(src.read_text(encoding="utf-8"))
    r = raw.get("r") or (raw.get("result") or {}).get("r") or raw
    c = (r.get("clock") or [{}])[0]
    out = {"real_minutes_per_game_day": c.get("real_min_per_day"), "dawn_hour": r.get("dawn", c.get("dawn")),
           "dusk_hour": r.get("dusk", c.get("dusk")), "cycle_game_hours": r.get("cycle720_game_hours"),
           "source": src.name}
    if isinstance(out["cycle_game_hours"], float):
        out["cycle_game_hours"] = round(out["cycle_game_hours"], 2)
    return {k: v for k, v in out.items() if v is not None}


def build(src: Path, build_id: str, clock: dict | None = None) -> dict:
    raw = json.loads(src.read_text(encoding="utf-8"))
    r = raw.get("r") or (raw.get("result") or {}).get("r") or raw
    names = _names()
    seed_of: dict[str, dict] = {}
    for s in r.get("seeds") or []:
        pid = _asset_id(s.get("plant"))
        sid = _asset_id(s.get("path"))
        if pid and sid:
            seed_of[pid] = {"id": sid, "name": s.get("name") or names.get(sid) or sid}
    settings = r.get("settings") or {}
    period = settings.get("CyclePeriod")
    crops = []
    for p in r.get("plants") or []:
        pid = _asset_id(p.get("path"))
        if not pid:
            continue
        hid = _asset_id(p.get("harvest_item"))
        stages = [s.get("cycles") for s in p.get("stages") or []]
        grow = [c for c in stages if isinstance(c, (int, float))]
        crops.append({
            "id": pid, "name": p.get("name") or (names.get(hid) if hid else None) or pid,
            "seed": seed_of.get(pid), "tier": p.get("tier"), "plot_tags": p.get("plantable_in") or [],
            "plots": _tier_words(p.get("plantable_in") or []),
            "base_yield": p.get("base_yield"), "harvest_item": hid, "harvest_name": names.get(hid or "", hid),
            "disease": p.get("disease"), "disease_not_preferred": p.get("disease_not_preferred"),
            "berry_bush": bool(p.get("berry_bush")), "harvest_xp_factor": p.get("harvest_xp_factor"),
            "stage_texts": p.get("stage_texts") or [],
            "stages": [{**{k: s.get(k) for k in ("cycles", "cycles_not_preferred", "disease", "disease_not_preferred")},
                        **{k: _asset_id(s.get(k)) for k in ("mesh", "mesh_diseased", "mesh_dead") if s.get(k)}}
                       for s in p.get("stages") or []],
            "cycles_to_harvest": sum(grow) if grow else None,
            "minutes_to_harvest": round(sum(grow) * period / 60, 1) if grow and isinstance(period, (int, float)) else None,
            "seed_drop": p.get("seed_drop") or None,
        })
    crops.sort(key=lambda c: (c["tier"] if isinstance(c["tier"], (int, float)) else 99, c["name"]))
    compostable = []
    for c in r.get("compostable") or []:
        iid = _asset_id(c.get("path"))
        tier = next((COMPOST_TIERS[f] for f in c.get("filters") or [] if f in COMPOST_TIERS), None)
        if tier is None and (c.get("compost") or 0) <= 1:
            continue  # every item defaults to CompostAmount 1; only the tagged ones go in a composter
        compostable.append({"item": iid, "name": c.get("name") or names.get(iid or "", iid), "compost": c.get("compost"),
                            "tier": tier, "category": c.get("category")})
    compostable.sort(key=lambda c: (c["tier"] or "~", -(c["compost"] or 0), c["name"] or ""))
    return {
        "schema": 1, "build": build_id, "source": f"live client data assets ({src.name})",
        "settings": settings,
        "crops": crops,
        "compost": [{"id": _asset_id(c.get("path")), **{k: c.get(k) for k in ("disease", "yield", "status")}}
                    for c in r.get("compost") or []],
        "water": [{"id": _asset_id(c.get("path")), **{k: c.get(k) for k in ("disease", "yield", "status")}}
                  for c in r.get("water") or []],
        "composters": r.get("composters") or [],
        "compostable": compostable,
        "clock": clock or {},
        "player_reports": _reports(),
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", type=Path, default=None, help="probe output (default: newest logs/farm/farm_data_probe-*.json)")
    ap.add_argument("--build", default=None, help="game build id (default: the newest items_<build>.json)")
    a = ap.parse_args(argv)
    src = a.src or sorted((ROOT / "logs" / "farm").glob("farm_data_probe-*.json"))[-1]
    build_id = a.build or re.sub(r"\D", "", sorted((ROOT / "data").glob("items_*.json"))[-1].stem)
    tp = sorted((ROOT / "logs" / "farm").glob("farm_time_probe-*.json"))
    out = build(src, build_id, clock_of(tp[-1] if tp else None))
    dst = ROOT / "data" / f"farming_{build_id}.json"
    dst.write_text(json.dumps(out, indent=1, ensure_ascii=False), encoding="utf-8")
    print(f"{dst}: {len(out['crops'])} crops, {len(out['compost'])} compost tiers, {len(out['composters'])} composters, "
          f"{len(out['compostable'])} compostable items")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

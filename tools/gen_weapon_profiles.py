"""Generate client_mod/scripts/weapons_data.lua, the compact weapon profile table Claude's CLIENT
combat module (client_mod/scripts/combat.lua) uses to pick the best weapon he owns and to pace his
button presses, from the item catalog data/items_<build>.json (tools/build_catalog.py).

Same idea as tools/gen_attack_data.py (the legacy server body's table): the client never parses the
big catalog JSON at runtime. Unlike attack_data.lua it is keyed by item id (what inventory.list
returns as `item`) and keeps what a *player* decides with: role, power level, damage types, block
value, slot, and per-press timing of the primary chain and the special.

  .venv\\Scripts\\python.exe -m tools.gen_weapon_profiles                 # newest data/items_*.json
  .venv\\Scripts\\python.exe -m tools.gen_weapon_profiles --catalog data\\items_26161880.json

Per item: {name, cat, role, pl (catalog power level), tier, types = {DamageType tags}, mult
(damage_multiplier), block (blocking_damage_negation), slot, kind (primary attack kind: melee |
ranged | magic | ...), prim = {name, dmg = mean chain damage, n, stam = mean stamina cost,
next_ms = mean "press again" time (input window end, >= damage point + 0.2 s), dmg_ms},
spec = {name, dmg, cost (special charge), next_ms}, can_block}.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from brain.paths import REPO_ROOT

OUT = REPO_ROOT / "client_mod" / "scripts" / "weapons_data.lua"
DAMAGE_MARGIN_S = 0.2
FALLBACK_NEXT_MS = 900


def lua(v, ind=""):
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(round(v, 3)) if isinstance(v, float) else str(v)
    if isinstance(v, str):
        return json.dumps(v)
    if isinstance(v, list):
        return "{ " + ", ".join(lua(x) for x in v) + " }"
    if isinstance(v, dict):
        parts = [f"{k} = {lua(x)}" for k, x in v.items() if x is not None]
        return "{ " + ", ".join(parts) + " }"
    raise TypeError(type(v))


def step_timing(attacks: dict, cls: str) -> tuple[int, int | None, float, float]:
    rec = attacks.get(cls) or {}
    t = rec.get("timing") or {}
    dmg_pts = t.get("damage_points") or []
    win = t.get("input_window") or []
    dmg_s = dmg_pts[0] if dmg_pts else None
    nxt = None
    if len(win) == 2:
        nxt = win[1]
    if dmg_pts:
        nxt = max(nxt or 0, dmg_pts[-1] + DAMAGE_MARGIN_S)
    next_ms = int(nxt * 1000) if nxt else FALLBACK_NEXT_MS
    return next_ms, (int(dmg_s * 1000) if dmg_s is not None else None), \
        float(rec.get("stamina_cost") or 0.0), float(rec.get("special_charge_cost") or 0.0)


def attack_profile(atk: dict | None, attacks: dict) -> dict | None:
    if not atk or atk.get("kind") not in ("melee", "ranged", "magic"):
        return None
    chain = atk.get("chain") or []
    dmg = [d for d in (atk.get("damage") or []) if isinstance(d, (int, float))]
    times = [step_timing(attacks, c) for c in chain] or [(FALLBACK_NEXT_MS, None, 0.0, 0.0)]
    n = len(times)
    return {
        "name": atk.get("name"),
        "kind": atk.get("kind"),
        "dmg": round(sum(dmg) / len(dmg), 2) if dmg else None,
        "n": len(chain),
        "stam": round(sum(t[2] for t in times) / n, 2),
        "cost": round(max(t[3] for t in times), 2) or None,
        "next_ms": int(sum(t[0] for t in times) / n),
        "dmg_ms": times[0][1],
    }


def build(catalog: dict) -> dict:
    attacks = catalog.get("attacks") or {}
    out = {}
    for item in catalog["items"].values():
        if item.get("kind") != "held" or item.get("category") in (None, "test", "seed"):
            continue
        a = item.get("attacks") or {}
        prim = attack_profile(a.get("primary"), attacks)
        spec = attack_profile(a.get("special"), attacks)
        sec = a.get("secondary") or {}
        stats = item.get("stats") or {}
        out[item["id"]] = {
            "name": item.get("name"),
            "cat": item.get("category"),
            "role": item.get("role"),
            "pl": item.get("power_level"),
            "tier": item.get("tier"),
            "types": item.get("damage_types") or [],
            "mult": stats.get("damage_multiplier"),
            "block": stats.get("blocking_damage_negation"),
            "slot": item.get("slot"),
            "kind": prim and prim["kind"],
            "prim": prim and {k: v for k, v in prim.items() if k != "kind"},
            "spec": spec and {k: v for k, v in spec.items() if k not in ("kind", "n", "stam")},
            "can_block": sec.get("kind") == "block",
        }
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", type=Path)
    ap.add_argument("--out", type=Path, default=OUT)
    args = ap.parse_args()
    cat_path = args.catalog or sorted((REPO_ROOT / "data").glob("items_*.json"))[-1]
    catalog = json.loads(cat_path.read_text(encoding="utf-8"))
    items = build(catalog)
    lines = [
        f"-- GENERATED by tools/gen_weapon_profiles.py from {cat_path.name}. Do not edit; regenerate after a game patch.",
        "-- Weapon profiles for client_mod/scripts/combat.lua, keyed by item id (inventory.list `item`).",
        "-- Fields: see the generator's docstring. Times in ms from the press.",
        "return {",
        f'  build = "{catalog.get("build")}",',
        "  items = {",
    ]
    for iid in sorted(items):
        lines.append(f"    [{json.dumps(iid)}] = {lua(items[iid])},")
    lines += ["  },", "}", ""]
    args.out.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {args.out} ({len(items)} items)")


if __name__ == "__main__":
    main()

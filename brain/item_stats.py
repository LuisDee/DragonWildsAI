"""Item stats from game data, for perception (PRINCIPLES #2/#3: the model judges, code only reports).

Source: the generated item catalog ``data/items_<build>.json`` (tools/build_items.py from the game's
own data assets: power level, weight, slot, role, tool tier, damage multiplier, attack names,
durability, requirements). No "best item" rule lives here: ``compare`` returns numeric deltas only,
and the model decides what to equip, keep or drop.

Consumable effects (heal, hydration, sustenance) are not in this catalog; the client's inventory rows
carry them live from the item data (client_mod/scripts/inventory.lua describe_item).
"""
from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Any

from . import paths

DATA_DIR = paths.REPO_ROOT / "data"


@lru_cache(maxsize=4)
def catalog(path: str | None = None) -> dict[str, dict]:
    """item id -> catalog entry ({} when no catalog is present). Newest build file by default."""
    if path is None:
        files = sorted(DATA_DIR.glob("items_*.json"))
        if not files:
            return {}
        path = str(files[-1])
    try:
        return json.loads(Path(path).read_text(encoding="utf-8")).get("items") or {}
    except (OSError, ValueError):
        return {}


def _round(v: Any) -> Any:
    return round(v, 2) if isinstance(v, float) else v


def stats(item: str | None, cat: dict[str, dict] | None = None) -> dict | None:
    """Compact facts for one item id, or None when the catalog does not know it."""
    if not item:
        return None
    e = (cat if cat is not None else catalog()).get(item)
    if not e:
        return None
    s = e.get("stats") or {}
    out: dict[str, Any] = {"name": e.get("name"), "slot": e.get("slot"), "role": e.get("role"), "power_level": e.get("power_level"),
                           "weight": _round(e.get("weight")), "max_durability": e.get("durability")}
    if e.get("tier"):
        out["tool_tier"] = e["tier"]
    if e.get("category"):
        out["category"] = e["category"]
    if s.get("armor_weight"):
        out["armour"] = s["armor_weight"]
    if isinstance(s.get("damage_multiplier"), (int, float)) and e.get("role") == "weapon":
        out["damage_multiplier"] = _round(s["damage_multiplier"])
    attacks = e.get("attacks") or {}
    names = [f"{a.get('name')}" + (f" {a['damage'][0]:g}" if isinstance(a.get("damage"), list) and a["damage"] else "")
             for a in attacks.values() if isinstance(a, dict) and a.get("name")]
    if names:
        out["actions"] = names
    if e.get("requirements"):
        out["requirements"] = e["requirements"]
    return {k: v for k, v in out.items() if v not in (None, "", [], {})}


def compare(new: dict | None, current: dict | None) -> dict | None:
    """Numeric deltas new - current for the same slot (power level, weight, damage multiplier, tool tier).
    Numbers only: no verdict."""
    if not new or not current:
        return None
    out = {}
    for k in ("power_level", "weight", "damage_multiplier", "tool_tier", "max_durability"):
        a, b = new.get(k), current.get(k)
        if isinstance(a, (int, float)) and isinstance(b, (int, float)):
            out[f"{k}_delta"] = _round(a - b)
    return out or None


def _slot_key(slot: str | None) -> str | None:
    if not slot:
        return None
    s = slot.lower()
    if s in ("right_hand", "left_hand", "two_handed"):
        return "held"
    return s


def equipped_by_slot(state: dict, cat: dict | None = None) -> dict[str, tuple[str, dict]]:
    """slot key -> (item id, stats) for what he wears or holds now."""
    out: dict[str, tuple[str, dict]] = {}
    gear = state.get("gear") if isinstance(state.get("gear"), dict) else {}
    for item in list(gear.values()):
        st = stats(item if isinstance(item, str) else None, cat)
        if st and _slot_key(st.get("slot")) and _slot_key(st.get("slot")) not in out:
            out[_slot_key(st["slot"])] = (item, st)
    return out


def describe_carried(state: dict, cat: dict | None = None) -> list[str]:
    """Carried equipment with its stats and the delta to what is equipped in the same slot."""
    eq = equipped_by_slot(state, cat)
    worn_items = {i for i, _ in eq.values()}
    out = []
    seen = set()
    for r in state.get("inventory_items") or []:
        if not isinstance(r, dict) or r.get("equipped") or r.get("item") in worn_items or r.get("item") in seen:
            continue
        st = stats(r.get("item"), cat)
        if not st or st.get("role") not in ("armour", "weapon", "tool"):
            continue
        seen.add(r.get("item"))
        facts = [f"{st.get('slot')}", f"PL {st.get('power_level')}"]
        if st.get("tool_tier"):
            facts.append(f"tier {st['tool_tier']}")
        if st.get("armour"):
            facts.append(str(st["armour"]))
        if st.get("weight") is not None:
            facts.append(f"{st['weight']:g} kg")
        cur = eq.get(_slot_key(st.get("slot")) or "")
        if cur:
            delta = compare(st, cur[1]) or {}
            d = ", ".join(f"{k.replace('_delta', '')} {v:+g}" for k, v in delta.items() if v)
            facts.append(f"vs {cur[1].get('name') or cur[0]}: {d or 'same'}")
        out.append(f"{r.get('name') or r.get('item')} ({'; '.join(facts)})")
    return out


def enrich_inventory(data: dict, state: dict | None = None, cat: dict | None = None) -> dict:
    """Add ``stats`` (and ``vs_equipped`` deltas) to the rows of the body's compact inventory answer."""
    cat = cat if cat is not None else catalog()
    eq = equipped_by_slot(state or {}, cat)
    out = dict(data)
    for key in ("hotbar", "bag"):
        rows = []
        for r in data.get(key) or []:
            if isinstance(r, dict):
                r = dict(r)
                st = stats(r.get("item"), cat)
                if st:
                    r["stats"] = st
                    cur = eq.get(_slot_key(st.get("slot")) or "")
                    if cur and cur[0] != r.get("item"):
                        r["vs_equipped"] = {"item": cur[0], **(compare(st, cur[1]) or {})}
            rows.append(r)
        out[key] = rows
    return out

"""Gear for his region and level, from the game's own data (items + recipes) and what he can see.

A data profile, not a hand table:

- **His power level** is the mean power level of his worn armour (head, body, legs), rounded down. An empty
  slot counts as 0. Source: the wiki "Power level" page. It matches the live reading: PL 0 in T1 Adventurer's
  body and legs with no head (2/3, rounded down).
  Weapons and shields do not count toward PL, but they are part of the kit: the best weapon and shield are
  planned too.
- **The enemies here** are the power levels of the creatures he perceives.
- **For each slot,** every item the game has for it, with the best power level he can reach. An item is
  reachable when one of these holds:
  - he owns it: worn, carried, in a grave he remembers, or in a container he has seen;
  - its recipe is unlocked;
  - its recipe unlocks by itself once he holds its trigger items (the game's progression query
    "ALL ITEMS[ Leather, Animal Bone ]");
  - its recipe unlocks once he holds those items next to a station ("... AND ALL ACTORS[ BP_Station_Tanner_C ]").
- **For each reachable item,** what it costs, what he is short of, and how to get the short inputs:
  one level of recipes, e.g. Leather <- Animal Hide at a Tannery.

The model decides what to make, wear and fetch. This only says what the data says. ``plan(state)`` returns
a dict, and ``lines(plan)`` turns it into short perception lines.
"""
from __future__ import annotations

import json
import math
import os
import re
from functools import lru_cache
from pathlib import Path
from typing import Any

from brain import item_stats

REPO = Path(__file__).resolve().parents[1]
RECIPES = REPO / "data" / "recipes_26574459.json"
ARMOUR_SLOTS = ("head", "body", "legs")  # these set his power level
KIT_SLOTS = ("right_hand", "left_hand")  # weapon, shield: not in PL, still his kit
WORN_KEYS = {"head": ("Head",), "body": ("Body",), "legs": ("Legs",), "right_hand": ("HeldRight", "held_right"),
             "left_hand": ("HeldLeft", "held_left")}
_QUERY_ITEMS = re.compile(r"ALL ITEMS\[([^\]]*)\]")
_QUERY_ACTORS = re.compile(r"ALL ACTORS\[([^\]]*)\]")


@lru_cache(maxsize=1)
def _recipes() -> dict[str, dict]:
    try:
        return json.loads(RECIPES.read_text(encoding="utf-8")).get("recipes") or {}
    except (OSError, ValueError):
        return {}


@lru_cache(maxsize=1)
def _station_rules() -> dict[str, dict]:
    try:
        return json.loads((REPO / "data" / "station_rules.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def _at(station: str) -> str:
    """'Spinning Wheel' -> 'Spinning Wheel (needs a roof over it, ...)': a station's own rule next to its name (live
    2026-11-02 gear_up: 400 s building and roofing a wheel in the open; the plan never said it needs a roof)."""
    r = _station_rules().get(station)
    return f"{station} ({r['note']})" if isinstance(r, dict) and r.get("note") else station


@lru_cache(maxsize=1)
def _by_output() -> dict[str, list[dict]]:
    out: dict[str, list[dict]] = {}
    for r in _recipes().values():
        if "Vendor" in (r.get("id") or ""):
            continue  # a shop purchase, not a craft
        for o in r.get("outputs") or []:
            out.setdefault(o.get("item"), []).append(r)
    return out


@lru_cache(maxsize=1)
def _names() -> dict[str, str]:
    """lower-case item name -> item id, from every recipe's inputs and outputs (resources are not in the items catalog)."""
    out: dict[str, str] = {}
    for r in _recipes().values():
        for x in (r.get("inputs") or []) + (r.get("outputs") or []):
            if x.get("name") and x.get("item"):
                out.setdefault(str(x["name"]).lower(), x["item"])
    return out


def _id_of(name: str, cat: dict) -> str | None:
    n = str(name).lower()
    return _names().get(n) or next((i for i, c in cat.items() if str(c.get("name") or "").lower() == n), None)


def _unlock_needs(r: dict) -> tuple[list[str], list[str]] | None:
    """Item names and station actor classes whose presence unlocks this recipe; None = no automatic unlock."""
    if (r.get("unlock") or {}).get("ignore_automatic_unlocks"):
        return None
    for b in (r.get("unlock") or {}).get("bundles") or []:
        q = b.get("query") or ""
        if b.get("manual") or b.get("milestone") or "ALL ITEMS" not in q:
            continue
        items = [x.strip() for m in _QUERY_ITEMS.findall(q) for x in m.split(",") if x.strip()]
        actors = [x.strip() for m in _QUERY_ACTORS.findall(q) for x in m.split(",") if x.strip()]
        if not items:
            return None  # unlocked by something else (a masterwork's blueprint): not by holding items
        return items, actors
    return None


def _station_word(actor_class: str) -> str:
    """BP_Station_Tanner_C -> "a Tanner" (the actor's own class word; the recipe's station list names it properly)."""
    w = re.sub(r"^BP_(Station|Crafting)_", "", actor_class)
    w = re.sub(r"_C$", "", w)
    return "a " + re.sub(r"(?<=[a-z])(?=[A-Z])", " ", w)


def _owned(state: dict, cat: dict, stash: dict | None) -> dict[str, list[str]]:
    """item id -> where he has one ("worn", "carried", "grave at (x,y)", "<container> at (x,y)")."""
    where: dict[str, list[str]] = {}
    for k, v in (state.get("gear") or {}).items():
        if isinstance(v, str) and k[:1].isupper():
            where.setdefault(v, []).append("worn")
    for item, n in (state.get("inventory") or {}).items():
        if n:
            where.setdefault(item, []).append("carried")
    for g in state.get("graves_remembered") or []:
        pos = g.get("position") or []
        at = f"your grave at ({pos[0]:.0f},{pos[1]:.0f})" if len(pos) >= 2 else "your grave"
        for s in g.get("lost") or []:
            name = re.sub(r"\s+x\d+$", "", str(s)).lower()
            iid = _id_of(name, cat)
            if iid:
                where.setdefault(iid, []).append(at)
    for label, items in (stash or {}).items():
        for item in items or []:
            where.setdefault(item, []).append(label)
    return where


def _counts(state: dict) -> dict[str, int]:
    return {k: int(v) for k, v in (state.get("inventory") or {}).items() if isinstance(v, (int, float))}


def _cost(r: dict, have: dict[str, int], unlocked: set[str]) -> dict:
    need, short, via = [], [], []
    for i in r.get("inputs") or []:
        n, item = int(i.get("count") or 0), i.get("item")
        need.append(f"{i.get('name')} x{n}")
        lack = n - have.get(item, 0)
        if lack > 0:
            short.append(f"{i.get('name')} x{lack}")
            sub = (_by_output().get(item) or [None])[0]
            if sub:
                ins = ", ".join(f"{x.get('name')} x{int(x.get('count') or 0) * math.ceil(lack / max(1, int((sub.get('outputs') or [{}])[0].get('count') or 1)))}"
                                for x in sub.get("inputs") or [])
                st = "/".join(_at(x) for x in sub.get("stations") or []) or "by hand"
                lock = "" if sub.get("id") in unlocked else " (unlocks when you hold its inputs" + (
                    " at " + " ".join(_station_word(a) for a in (_unlock_needs(sub) or ([], []))[1]) if (_unlock_needs(sub) or ([], []))[1] else "") + ")"
                via.append(f"{i.get('name')} <- {ins} at {st}{lock}")
    return {"needs": need, "short": short, "via": via, "station": "/".join(r.get("stations") or []) or None,
            "inputs": [(i.get("item"), i.get("name"), int(i.get("count") or 0)) for i in r.get("inputs") or []]}


_QUALIFIED = re.compile(r"^\s*([^()]+?)\s*(?:\((?:level|power level)\s*([\d,\s]+)\))?\s*$", re.I)


def _types(words: Any, pl: int | None) -> list[str]:
    """['Crush (level 5)', 'None'] at power level 2 -> []: a damage type that holds for the creature at this power level
    (the wiki writes 'Crush (level 5)' when only that variant has it; 'None' and empty rows are no type)."""
    out = []
    for w in words if isinstance(words, list) else [words] if words else []:
        m = _QUALIFIED.match(str(w))
        if not m or m.group(1).strip().lower() in ("none", ""):
            continue
        lv = [int(x) for x in re.findall(r"\d+", m.group(2) or "")]
        if lv and pl not in lv:
            continue
        out.append(m.group(1).strip())
    return out


def _int(v: Any) -> int | None:
    m = re.match(r"\s*(-?\d+)", str(v)) if v is not None else None
    return int(m.group(1)) if m else None


def vault_need(vault: str, bestiary: dict | None = None) -> dict:
    """What a vault's enemies ask of his gear, from data/bestiary.json (tools/build_vaults.py: the wiki's vault page
    enemy table with each enemy's power level there, and each creature's weak/resist rows). Data only: no recipe.

    Returns {"vault", "pl": the highest power level among its enemies (the vault's own level when no enemy states one),
    "enemies": ["Giant Rat x9 PL 2", ...], "weak"/"resist": {damage type: enemies}, "damage_pref": damage types the
    enemies are weak to, most enemies first, after those that resist them, "rows": the data rows used, with sources}.
    Raises KeyError for a vault the data does not hold."""
    if bestiary is None:
        from brain.plan_sources import bestiary as _bestiary
        bestiary = _bestiary()
    vaults = bestiary.get("vaults") or {}
    key = next((k for k, v in vaults.items() if k.lower() == str(vault).lower()
                or str(vault).lower() in [str(a).lower() for a in (v or {}).get("aliases") or []]), None)
    if key is None:
        raise KeyError(f"vault {vault!r} is not in data/bestiary.json vaults")
    v = vaults[key]
    src = v.get("src") or {}
    rows = []
    vpl = _int(v.get("power_level"))
    enemies, weak, resist = [], {}, {}
    pls = []
    for e in v.get("enemies") or []:
        name, n, pl = e.get("name"), _int(e.get("amount")), _int(e.get("power_level"))
        pl = vpl if pl is None else pl
        if pl is not None:
            pls.append(pl)
        enemies.append(f"{name}" + (f" x{n}" if n else "") + (f" PL {pl}" if pl is not None else ""))
        c = (bestiary.get("creatures") or {}).get(name) or {}
        w, r = _types(c.get("weak"), pl), _types(c.get("resist"), pl)
        for t in w:
            weak.setdefault(t, []).append((name, n or 1))
        for t in r:
            resist.setdefault(t, []).append((name, n or 1))
        if c:
            csrc = c.get("src") or {}
            pages = sorted({p for k in ("weak", "resist") for p in csrc.get(k) or []}, key=str)
            rows.append(f"creatures/{name}: weak {', '.join(c.get('weak') or []) or '-'}, resist "
                        f"{', '.join(c.get('resist') or []) or '-'}" + (f" (wiki {', '.join(map(str, pages))})" if pages else ""))
    for b in v.get("boss") or []:  # the boss row's weakness when the enemy table did not carry the creature's own
        name = b.get("creature")
        if name and not any(name == x[0] for xs in weak.values() for x in xs):
            pl = next((_int(e.get("power_level")) for e in v.get("enemies") or [] if e.get("name") == name), vpl)
            for t in _types([s.strip() for s in str(b.get("weakness") or "").split(";")], pl):
                weak.setdefault(t, []).append((name, 1))
            rows.append(f"vaults/{key}/boss: {name} weakness {b.get('weakness') or '-'}"
                        + (f" (wiki {', '.join(map(str, src.get('boss') or []))})" if src.get("boss") else ""))
    rows.insert(0, f"vaults/{key}/enemies: {', '.join(enemies) or 'none listed'}"
                + (f" (wiki {', '.join(map(str, src.get('enemies') or []))})" if src.get("enemies") else ""))
    if not pls and vpl is not None:
        rows.insert(1, f"vaults/{key}/power_level: {vpl}" + (f" (wiki {', '.join(map(str, src.get('power_level') or []))})"
                                                             if src.get("power_level") else ""))
    count = lambda xs: sum(n for _, n in xs)  # noqa: E731
    score = {t: count(weak[t]) - count(resist.get(t, [])) for t in weak}
    pref = sorted((t for t in score if score[t] > 0), key=lambda t: (-score[t], t))
    words = lambda d: {t: [f"{nm} x{n}" for nm, n in xs] for t, xs in d.items()}  # noqa: E731
    return {"vault": key, "pl": max(pls) if pls else vpl, "enemies": enemies, "weak": words(weak), "resist": words(resist),
            "damage_pref": pref, "rows": rows}


def _dtypes(c: dict) -> list[str]:
    """['DamageType.Physical.Crush'] -> ['Crush']: a weapon's damage types from the item catalog."""
    return [str(t).rsplit(".", 1)[-1] for t in c.get("damage_types") or [] if t]


def plan(state: dict, cat: dict | None = None, stash: dict | None = None, vault: str | None = None) -> dict:
    """vault: a vault's name ('Crasorak Kara'): the enemies are that vault's (vault_need) instead of those in sight, the
    cap is their power level, and the best weapons at the top level are ordered by the damage types they are weak to.
    None: the region in sight, as before."""
    cat = cat or item_stats.catalog()
    unlocked = set(state.get("recipes_unlocked") or [])
    have = _counts(state)
    owned = _owned(state, cat, stash)
    gear = state.get("gear") or {}
    need = vault_need(vault) if vault else None
    enemies = [e for e in state.get("nearby_entities") or [] if e.get("alive", True) and e.get("power_level") is not None]
    enemy_pl = max((int(e["power_level"]) for e in enemies), default=None)
    if need:
        enemy_pl = need["pl"]
    slots: dict[str, dict] = {}
    for slot in ARMOUR_SLOTS + KIT_SLOTS:
        worn_id = next((gear[k] for k in WORN_KEYS[slot] if gear.get(k)), None)
        worn = cat.get(worn_id) or {}
        opts = []
        for iid, c in cat.items():
            role = c.get("role")
            if c.get("slot") != slot or role not in ("armour", "weapon", "shield"):
                continue
            if slot == "right_hand" and role != "weapon":
                continue
            pl = c.get("power_level")
            if pl is None:
                continue
            o = {"item": iid, "name": c.get("name"), "pl": int(pl), "weight": (c.get("stats") or {}).get("armor_weight"),
                 "dmg_mult": (c.get("stats") or {}).get("damage_multiplier") if role == "weapon" else None,
                 "kind": c.get("category") if role == "weapon" else None}
            if need and role == "weapon":
                o["dtypes"] = _dtypes(c)
            if owned.get(iid):
                o["status"], o["where"] = "owned", owned[iid]
            else:
                rec = next((r for r in _by_output().get(iid) or []), None)
                if not rec:
                    continue
                o["recipe"] = rec.get("id")
                if rec.get("id") in unlocked:
                    o["status"] = "craftable"
                else:
                    un = _unlock_needs(rec)
                    if un is None:
                        continue  # a manual/milestone unlock he has not got
                    o["status"], o["unlocks_with"] = "unlocks", {"hold": un[0], "near": [_station_word(a) for a in un[1]]}
                o.update(_cost(rec, have, unlocked))
                if o["status"] == "craftable" and not o["short"]:
                    o["status"] = "craftable_now"
            opts.append(o)
        # the best power level he can reach, and every way to it (the model picks by style: heavy/medium/light)
        reach = [o for o in opts if o["status"] in ("owned", "craftable_now", "craftable")
                 or (o["status"] == "unlocks" and all(_reachable_item(n, cat, have, unlocked) for n in o["unlocks_with"]["hold"]))]
        # for this region: crafted gear up to the enemies' PL here (matching them closes the gap; the next tier's
        # materials come from the next region: bronze is Ghornfell's). Gear he already owns counts at any PL.
        # (at least one tier above the best piece he wears: kebbits alone in sight must not cap him at his T1 starter)
        worn_top = max((int((cat.get(v) or {}).get("power_level") or 0) for k, v in gear.items()
                        if isinstance(v, str) and k in ("Head", "Body", "Legs")), default=0)
        # a vault: its enemies' level is the cap (what the vault asks), not one tier above what he wears
        cap = need["pl"] if need and need.get("pl") is not None else max(enemy_pl or 0, worn_top + 1)
        reach = [o for o in reach if cap is None or o["pl"] <= cap or o["status"] == "owned"]
        top = max((o["pl"] for o in reach), default=None)
        pref = need["damage_pref"] if need else []
        best = sorted([o for o in reach if o["pl"] == top],
                      key=lambda o: ((min((pref.index(t) for t in o.get("dtypes") or [] if t in pref), default=len(pref)),) if pref else ())
                      + (o["status"] != "owned", o["status"] != "craftable_now", o["name"] or ""))
        slots[slot] = {"worn": worn.get("name"), "worn_pl": worn.get("power_level"), "best_pl": top, "best": best}
    worn_pls = [int(slots[s]["worn_pl"] or 0) if slots[s]["worn"] else 0 for s in ARMOUR_SLOTS]
    best_pls = [max(int(slots[s]["best_pl"] or 0), worn_pls[i]) for i, s in enumerate(ARMOUR_SLOTS)]
    out = {"pl_now": math.floor(sum(worn_pls) / len(ARMOUR_SLOTS)), "pl_full_set": math.floor(sum(best_pls) / len(ARMOUR_SLOTS)),
           "enemy_pl": enemy_pl, "enemies": sorted({f"{e.get('name')} PL {e.get('power_level')}" for e in enemies}), "slots": slots}
    if need:
        out["enemies"], out["vault"] = need["enemies"], need
    return out


def _reachable_item(name: str, cat: dict, have: dict[str, int], unlocked: set[str]) -> bool:
    """Can he come to hold this item at all: carried, or made by a recipe that is unlocked or unlocks by itself."""
    iid = _id_of(name, cat)
    if not iid:
        return False
    if have.get(iid):
        return True
    for r in _by_output().get(iid) or []:
        if r.get("id") in unlocked or _unlock_needs(r) is not None:
            return True
    return not _by_output().get(iid)  # a raw resource (gathered, dropped): no recipe at all


def pl_with(p: dict, slot: str, pl: int) -> int:
    """His power level with a piece of power level pl worn in this armour slot (the rest as worn now)."""
    vals = [pl if s == slot else (int((p["slots"].get(s) or {}).get("worn_pl") or 0) if (p["slots"].get(s) or {}).get("worn") else 0)
            for s in ARMOUR_SLOTS]
    return math.floor(sum(vals) / len(ARMOUR_SLOTS))


def lines(p: dict, max_opts: int = 3, compact: bool = False) -> list[str]:
    """Short perception lines (one for the summary, one per slot that can improve). compact: what he is short of but not
    the full cost or where the short inputs come from, and the slots with gear he already owns first (the one-line
    summary is cut at its length: the crate's shield came last and was cut, 2026-11-02)."""
    if not p:
        return []
    why = ("mean of worn head, body, legs, rounded down" if compact else
           "your armour's power level: mean of head, body, legs, rounded down; weapons don't count")
    out = [f"Gear vs this area: you are PL {p['pl_now']} ({why}); enemies here: {', '.join(p['enemies']) or 'none seen'}. Best armour you can reach makes you"
           f" PL {p['pl_full_set']}."]
    for slot, s in p["slots"].items():
        worn_pl = int(s["worn_pl"] or 0) if s["worn"] else (0 if slot in ARMOUR_SLOTS else None)
        if s["best_pl"] is None or (worn_pl is not None and s["best_pl"] <= worn_pl):
            continue
        parts = []
        for o in s["best"][:max_opts]:
            if o["status"] == "owned":
                # "not on you" + what wearing it does now: live 2026-11-02 gear_up run 5 crafted a Leather Cowl and carried
                # it 400 s unworn, waiting for the whole set
                d = "you have one, not on you: " + "; ".join(o["where"][:2])
                if slot in ARMOUR_SLOTS and o.get("pl") is not None:
                    d += f"; wearing it now: PL {p['pl_now']} -> {pl_with(p, slot, int(o['pl']))}"
            elif o["status"] == "craftable_now":
                d = f"craftable now at {o.get('station')} ({', '.join(o['needs'])})"
            else:
                d = ("recipe unlocked" if o["status"] == "craftable" else
                     ("unlocks holding " if compact else "recipe unlocks when you hold ") + " + ".join(o["unlocks_with"]["hold"]) +
                     (" near " + " ".join(o["unlocks_with"]["near"]) if o["unlocks_with"]["near"] else ""))
                if not compact:
                    d += f"; needs {', '.join(o['needs'])}"
                if o.get("short"):
                    d += f"; short {', '.join(o['short'])}"
                if o.get("via") and not compact:
                    d += f" ({'; '.join(o['via'])})"
            extra = f", {o['weight'].lower()}" if o.get("weight") and o["weight"] != "None" else ""
            extra += f", {o['kind']}" if o.get("kind") else ""
            extra += f", x{o['dmg_mult']:.1f} damage" if o.get("dmg_mult") else ""
            parts.append(f"{o['name']} (PL {o['pl']}{extra}): {d}")
        if compact and s["best"][max_opts:]:  # the other ways to the same PL, by name and style: the model picks
            parts[-1] += "; or " + ", ".join(f"{o['name']}" + (f" ({o['weight'].lower()})" if o.get("weight") and o["weight"] != "None" else "")
                                             for o in s["best"][max_opts:max_opts + 2])
        label = {"right_hand": "weapon", "left_hand": "off-hand"}.get(slot, slot)
        now = f"{s['worn'] or 'nothing'}{f' (PL {worn_pl})' if worn_pl is not None and s['worn'] else ''}"
        out.append(f"  {label}: {'' if compact else 'wearing '}{now} -> " + " | ".join(parts))
    if compact:
        out[1:] = sorted(out[1:], key=lambda x: "you have one" not in x)
    return out


def sets(p: dict, state: dict) -> list[dict]:
    """The whole job per armour style (light / medium / heavy): one best-PL piece of that style for every armour slot
    that can improve, the bill for all of them together against what he carries, and how each short input is made
    (one recipe level: every recipe for it and its station). Live 2026-11-02: per-slot lines led him to stop at the
    first piece's blocker (one thread short, the wheels under open sky); the style that needs no thread went untried."""
    have = _counts(state)
    out: dict[str, dict] = {}
    for slot in ARMOUR_SLOTS:
        s = p["slots"].get(slot) or {}
        worn_pl = int(s.get("worn_pl") or 0) if s.get("worn") else 0
        if s.get("best_pl") is None or s["best_pl"] <= worn_pl:
            continue
        for o in s.get("best") or []:
            style = str(o.get("weight") or "").lower()
            if not style or style == "none" or slot in out.get(style, {}).get("slots", {}):
                continue
            st = out.setdefault(style, {"style": style, "pl": o["pl"], "slots": {}, "bill": {}, "owned": [], "unlock": []})
            st["slots"][slot] = o["name"]
            if o["status"] == "owned":
                st["owned"].append(o["name"])
                continue
            if o["status"] == "unlocks":
                st["unlock"] += [x for x in o["unlocks_with"]["hold"] if x not in st["unlock"]]
            for item, name, n in o.get("inputs") or []:
                st["bill"].setdefault(item, {"name": name, "need": 0})["need"] += n
    for st in out.values():
        st["short"] = []
        for item, b in st["bill"].items():
            lack = b["need"] - have.get(item, 0)
            if lack <= 0:
                continue
            ways, carried = [], []
            for r in _by_output().get(item) or []:
                ins = r.get("inputs") or []
                if not ins:
                    continue
                per = max(1, int((r.get("outputs") or [{}])[0].get("count") or 1))
                ways.append(" + ".join(f"{x.get('name')} x{int(x.get('count') or 0)}" for x in ins)
                            + (f" per {per}" if per > 1 else "") + f" at a {_at((r.get('stations') or ['by hand'])[-1])}")
                carried += [f"{x.get('name')} x{have[x['item']]}" for x in ins if have.get(x.get("item"))]
            st["short"].append({"name": b["name"], "count": lack, "ways": ways, "carried": list(dict.fromkeys(carried))})
    # a set whose shortfall only comes through a station with a placement rule (the roofed Spinning Wheel) after one that
    # doesn't, then by how much is short (live 2026-11-02 gear_up run 5: the leather set's thread sent him 400 s into
    # roofing a wheel while the Reinforced set lacked only bones)
    rules = _station_rules()

    def ruled(x: dict) -> bool:
        return bool(x["ways"]) and all(any(f"at a {k} (" in w for k in rules if not k.startswith("_")) for w in x["ways"])
    for st in out.values():
        st["ruled"] = [x["name"] for x in st["short"] if ruled(x)]
    return sorted(out.values(), key=lambda s: (bool(s["ruled"]), sum(x["count"] for x in s["short"])))


def set_line(p: dict, state: dict) -> str | None:
    """One line, every style's whole bill: 'Whole armour set per style ...: light PL 2 (Apprentice Hat/Robe/Leggings):
    short Coarse Thread x19 (<- Coarse Animal Fur x3 or Flax x1 at a Spinning Wheel; you carry ...) | heavy ...'."""
    parts = []
    for st in sets(p, state):
        names = list(st["slots"].values())
        pre = os.path.commonprefix(names) if len(names) > 1 else ""
        stem = pre[:pre.rfind(" ")] if " " in pre else ""
        pieces = stem + " " + "/".join(n[len(stem):].strip() for n in names) if stem else ", ".join(names)
        bill = "short " + "; ".join(
            f"{x['name']} x{x['count']}" + (f" (<- {' or '.join(x['ways'])}"
                                            + (f"; you carry {', '.join(x['carried'])}" if x["carried"] else "") + ")"
                                            if x["ways"] else "")
            for x in st["short"]) if st["short"] else "you have everything for it"
        if st["owned"]:
            bill += f"; you own {', '.join(st['owned'])}"
        if st["unlock"]:
            bill += f"; its recipes unlock once you hold {' + '.join(st['unlock'])}"
        parts.append(f"{st['style']} PL {st['pl']} ({pieces}): {bill}")
    return ("Whole armour set per style, all pieces together: " + " | ".join(parts)) if parts else None


def worn_armour(state: dict, cat: dict | None = None) -> dict:
    """His power level from what he wears: {"pl": mean of head, body, legs PL rounded down (an empty slot is 0),
    "pieces": ["Leather Cowl PL 2", ...]}. The same rule as plan()'s pl_now, without the recipe search."""
    cat = cat or item_stats.catalog()
    gear = state.get("gear") if isinstance(state.get("gear"), dict) else {}
    pls, pieces = [], []
    for slot in ARMOUR_SLOTS:
        iid = next((gear[k] for k in WORN_KEYS[slot] if gear.get(k)), None)
        c = cat.get(iid) or {}
        pl = int(c.get("power_level") or 0) if iid else 0
        pls.append(pl)
        if iid:
            pieces.append(f"{c.get('name') or iid} PL {pl}")
    return {"pl": math.floor(sum(pls) / len(ARMOUR_SLOTS)), "pieces": pieces}


def for_vault(state: dict, vault: str, stash: dict | None = None) -> dict:
    """A vault's enemies against his armour, facts only: the enemies' power level, his own (from worn armour, and the
    game's reading beside it when the state has one), and every armour style's whole bill at the vault's level
    (set_line over plan(vault=...)). L3 2026-11-19: the vault's PL 2 and the Reinforced set it allows were never shown
    together; he chased a PL 3 bronze set for 30 min. Raises KeyError for a vault the data does not hold."""
    p = plan(state, stash=stash, vault=vault)
    need = p["vault"]
    out: dict[str, Any] = {"vault": need["vault"], "enemies_pl": need["pl"], "enemies": need["enemies"],
                           "you_pl_from_worn_armour": p["pl_now"],
                           "you_wear": [f"{s['worn']} PL {int(s['worn_pl'] or 0)}" for s in
                                        (p["slots"][x] for x in ARMOUR_SLOTS) if s.get("worn")]}
    if isinstance(state.get("power_level"), (int, float)):
        out["you_pl_game_reads"] = state["power_level"]
    if need.get("weak"):
        out["enemies_weak_to"] = need["weak"]
    line = set_line(p, state)
    if need["pl"] is not None and p["pl_now"] >= need["pl"]:
        out["armour"] = f"your worn armour is PL {p['pl_now']}, at or above this vault's enemies (PL {need['pl']})"
    elif line:
        out["armour"] = (f"armour up to this vault's PL {need['pl']} you can reach; best whole set makes you PL "
                         f"{p['pl_full_set']}. {line}")
    else:
        out["armour"] = (f"no armour piece above what you wear is reachable up to PL {need['pl']} "
                         f"(best whole set makes you PL {p['pl_full_set']})")
    return out


def describe(state: dict, stash: dict | None = None) -> list[str]:
    try:
        return lines(plan(state, stash=stash))
    except Exception as e:  # perception must never break the turn
        return [f"Gear vs this area: unavailable ({type(e).__name__})"]

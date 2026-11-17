"""Needs -> options digest (companion-quality workstream N): perception, not a mapping.

For each PRESSING need (food, drink, health, rest, a tool the current task lacks) list the ways
the game itself offers to meet it, computed from game data and live state only:
  carried    hotbar/bag rows of that kind (where, use verb, what it restores);
  nearby     ground items and gatherable/foliage pickups whose item is of that kind (id, distance);
  craft      unlocked recipes whose output is of that kind: inputs carried vs missing, the station
             type it needs and whether one is near (or that it is a building piece), the cheapest
             missing ingredient and whether it lies nearby;
  people     players nearby who could help (the model decides whether to ask).
Item kinds come from the item data class (data/recipes_<build>.json items: BP_Consumables_Food_C /
_Drink_C / _Potion_C), never from names. The model reads the options and decides (PRINCIPLES #2):
nothing here picks one.

Live 21:17 (BUGS L16): hungry at 14 %, "I'll look for a fire to cook raw meat", never considered
the Redberry Bush 9 m away, cooking or crafting from his menu, or asking Zezima.
"""
from __future__ import annotations

import json
import re
from functools import lru_cache
from pathlib import Path

from . import knowledge
from . import situation as sit
from .map_memory import lines_for
from .situation import consumable_facts, consumable_rows, item_names, num as _num
from .spells import effects as _spell_effects

MAX_OPTIONS = 4  # per source, per need (craft: 3)
NEAR_M = 40.0
LINE_CHARS = 560


@lru_cache(maxsize=2)
def catalog(path: str | None = None) -> dict:
    """The newest data/recipes_<build>.json (honours DW_DATA_DIR via knowledge.data_dir), {} when absent."""
    if path is None:
        newest = knowledge.newest(knowledge.data_dir(), "recipes")
        if newest is None:
            return {}
        path = str(newest)
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def _kind_from_class(e: dict) -> str | None:
    cls = str(e.get("class") or "")
    for kind, word in (("food", "Food"), ("drink", "Drink"), ("potion", "Potion")):
        if f"Consumables_{word}" in cls:
            return kind
    return None


_INDEX: dict[int, tuple[dict, dict]] = {}  # id(catalog) -> (catalog, index); a few catalogs at most


def _index(cat: dict) -> dict:
    """Per catalog, built once: item -> kind, and the recipes with a consumable output in catalog order
    as (rid, recipe, [(output, kind), ...]). The needs digest runs on every prompt (it used to scan all
    1,232 recipes with item_kind per output, per pressing need)."""
    hit = _INDEX.get(id(cat))
    if hit is not None and hit[0] is cat:
        return hit[1]
    kinds = {}
    for iid, e in (cat.get("items") or {}).items():
        k = _kind_from_class(e) if isinstance(e, dict) else None
        if k:
            kinds[iid] = k
    recipes = []
    for rid, r in (cat.get("recipes") or {}).items():
        outs = [(o, kinds.get(o.get("item"))) for o in r.get("outputs") or []]
        if any(k for _, k in outs):
            recipes.append((rid, r, outs))
    idx = {"kinds": kinds, "recipes": recipes}
    if len(_INDEX) > 4:
        _INDEX.clear()
    _INDEX[id(cat)] = (cat, idx)
    return idx


def item_kind(item: str | None, cat: dict | None = None) -> str | None:
    """'food' | 'drink' | 'potion' | None from the item data CLASS (game data), never the name."""
    if not item:
        return None
    return _index(cat if cat is not None else catalog())["kinds"].get(item)


def _pct(cur, mx) -> float | None:
    c, m = _num(cur), _num(mx)
    if c is None:
        return None
    return 100.0 * c / m if m else c


def pressing(state: dict) -> list[dict]:
    """The needs that are pressing now: below the model's own policy (or the default), worst first."""
    pol = state.get("vitals_policy") if isinstance(state.get("vitals_policy"), dict) else {}
    out = []
    rate = state.get("vitals_rate") if isinstance(state.get("vitals_rate"), dict) else {}

    def to_zero(stat, per_min_key):
        cur, r = _num(state.get(stat)), _num(rate.get(per_min_key))
        return round(cur / r) if cur is not None and r and r > 0 else None

    for need, stat, policy in (("food", "sustenance", "eat_below_pct"), ("drink", "hydration", "drink_below_pct")):
        pct = _pct(state.get(stat), state.get(f"{stat}_max"))
        if pct is not None and pct < float(pol.get(policy) or 40) + 10:
            out.append({"need": need, "kinds": [need], "pct": pct, "zero_min": to_zero(stat, f"{stat}_per_min")})
    hp = _pct(state.get("health"), state.get("max_health"))
    if hp is not None and hp < float(pol.get("heal_below_pct") or 50):
        out.append({"need": "health", "kinds": ["potion", "food"], "pct": hp, "heal": True})
    rest = _pct(state.get("endurance"), state.get("endurance_max"))
    if rest is not None and rest < 30:
        out.append({"need": "rest", "kinds": [], "pct": rest})
    tool = state.get("tool_need") if isinstance(state.get("tool_need"), dict) else None
    if tool:
        out.append({"need": "tool", "kinds": [], "tool": tool})
    bag = state.get("bag") if isinstance(state.get("bag"), dict) else {}
    if bag.get("encumbered") is True:  # over the game's carry weight: walk only (UPlayerEncumbranceComponent)
        out.append({"need": "load", "kinds": [], "weight": _num(bag.get("weight")), "max": _num(bag.get("max_weight"))})
    return sorted(out, key=lambda n: n.get("pct", 0) if n.get("pct") is not None else 0)


def _carried(state: dict, kinds: list[str], cat: dict, heal: bool = False) -> list[str]:
    out = []
    for _, r in consumable_rows(state, kinds, kind_of=lambda item: item_kind(item, cat), heal_only=heal):
        facts = [r["where"], *consumable_facts(r, (("heal", "heals"), ("hydration", "water"), ("sustenance", "food")))]
        if r.get("use_verb"):
            facts.append(str(r["use_verb"]))
        out.append(f"{r.get('name') or r.get('item')} x{r.get('count') or 1} ({', '.join(facts)})")
    return out[:MAX_OPTIONS]


def _nearby(state: dict, kinds: list[str], cat: dict) -> list[str]:
    rows = []
    for g in state.get("nearby_items") or []:
        if isinstance(g, dict) and (g.get("consumable") or item_kind(g.get("item"), cat)) in kinds:
            rows.append((g.get("distance") or 1e9, f"{g.get('name')} x{g.get('count') or 1} on the ground"
                         + (f", dropped by {g['dropped_by']}" if g.get("dropped_by") else ""), g.get("id")))
    for r in state.get("nearby_resources") or []:
        if isinstance(r, dict) and item_kind(r.get("item"), cat) in kinds:
            what = r.get("name") or r.get("item")
            rows.append((r.get("distance") or 1e9, f"{what} (gives {cat.get('items', {}).get(r['item'], {}).get('name') or r['item']})",
                         r.get("id")))
    if "drink" in kinds:  # a pond or river is a drink source too (live 2026-11-01 13:0x: thirsty with water 17 m off)
        for t in (state.get("interactables") or []) + (state.get("nearby_resources") or []):
            if isinstance(t, dict) and "WaterVolume" in str(t.get("class") or ""):
                rows.append((t.get("distance") or 1e9, WATER_SOURCE.format(name=t.get("name") or "Water"), t.get("id")))
                break
    rows.sort(key=lambda x: x[0])
    return [f"{t} ({d:.0f} m, id {i})" if d < 1e8 else f"{t} (id {i})" for d, t, i in rows[:MAX_OPTIONS]]


# Dirty Water facts: game data (consumable_wiki: +10 water, +20 Soulscourge; a full toxicity bar at 100 deals 50 damage,
# wiki Soulscourge) and the live boil (2026-11-01 13:10: 6 Dirty Water + 1 Ash Log at a Campfire -> 6 Clean Water in 33 s).
WATER_SOURCE = ("{name} (collect_water: Dirty Water, +10 water and +20 Soulscourge each, about 6 from empty fill the bar "
                "for 50 damage; boil at a Campfire with 1 log: Clean Water +25)")


def _station_names(sids: list[str], cat: dict) -> str:
    st = cat.get("stations") or {}
    return " or ".join(dict.fromkeys(str((st.get(s) or {}).get("display_name") or (st.get(s) or {}).get("name") or s)
                                     for s in sids))


def _station_near(sids: list[str], state: dict, cat: dict) -> dict | None:
    for row in state.get("stations_nearby") or []:
        if isinstance(row, dict) and row.get("station") in sids:
            return row
    classes = {c for s in sids for c in ((cat.get("stations") or {}).get(s) or {}).get("class_names") or []}
    for t in state.get("interactables") or []:
        if isinstance(t, dict) and t.get("class") in classes:
            return {"id": t.get("id"), "name": t.get("name"), "distance": t.get("distance")}
    return None


FUELS_SHOWN = 3


def _fuel_words(r: dict, have: dict, state: dict, cat: dict) -> str:
    """For a recipe made at a station that burns fuel: what he carries of what it burns ('' when none of its
    stations burns any). A recipe's inputs are not all a craft takes at a fire.

    Chain sitting 2 (run 103436) and window s29 (log 125956), 2026-11-17: Rat Roast crafted beside a Campfire with no
    fuel in it while carrying none (missing_materials, a miss; 2 of the 6 Ratcatcher trials from the chain's own
    state). The row read "takes 1 Raw Rat Meat (you have 2)". The turn replayed 12 times each way: a craft first 5 of
    12 as logged, 0 of 12 with these words."""
    stations, items = cat.get("stations") or {}, cat.get("items") or {}
    burners = [s for s in r.get("stations") or [] if (stations.get(s) or {}).get("accepted_fuels")]
    if not burners:
        return ""
    fuels = list(dict.fromkeys(f for s in burners for f in stations[s]["accepted_fuels"]))
    name = lambda f: (items.get(f) or {}).get("name") or f
    head = f"; a {_station_names(burners, cat)} burns fuel"
    carried = [f"{name(f)} x{have[f]}" for f in fuels if have.get(f)]
    if carried:
        return f"{head} (you carry {', '.join(carried[:FUELS_SHOWN])})"
    for row in state.get("stations_nearby") or []:  # a fire in sight that holds fuel needs none of his
        lit = isinstance(row, dict) and row.get("station") in burners and row.get("fuel") is True
        if lit and isinstance(row.get("distance"), (int, float)):
            return f"{head}, and the one {row['distance']:.0f} m off has fuel in it"
    more = len(fuels) - FUELS_SHOWN
    return (f"{head}, and you carry none (it burns {', '.join(name(f) for f in fuels[:FUELS_SHOWN])}"
            + (f" and {more} others" if more > 0 else "") + ")")


_NAMED: dict[int, tuple] = {}
NAMED_LIMIT = 3


def _named_index(cat: dict) -> tuple:
    """Per catalog, built once: a pattern over the names of everything a station recipe makes, and
    name -> [(recipe id, recipe, output)]. Vendor and test recipes are left out (he cannot trade yet)."""
    hit = _NAMED.get(id(cat))
    if hit is not None and hit[0] is cat:
        return hit[1], hit[2]
    stations = cat.get("stations") or {}
    by: dict[str, list] = {}
    for rid, r in (cat.get("recipes") or {}).items():
        sids = r.get("stations") or []
        if (r.get("test") or r.get("vendor_reputation") or not sids
                or any((stations.get(s) or {}).get("is_vendor") for s in sids)):
            continue
        for o in r.get("outputs") or []:
            name = str(o.get("name") or "").strip().lower()
            if len(name) >= 3 and not name.startswith("<"):
                by.setdefault(name, []).append((rid, r, o))
    rx = (re.compile(r"\b(" + "|".join(re.escape(n) for n in sorted(by, key=len, reverse=True)) + r")s?\b", re.I)
          if by else None)
    if len(_NAMED) > 4:
        _NAMED.clear()
    _NAMED[id(cat)] = (cat, rx, by)
    return rx, by


def named_recipes(state: dict, texts, cat: dict | None = None, limit: int = NAMED_LIMIT) -> list[str]:
    """What the crafting menu shows a player for each thing these texts name: 'Stone Club at a Crafting Table takes
    8 Stone (you have 4) and 6 Ash Logs (you have 4)'. The texts are his quest steps and his job; a thing is matched
    by its whole in-game name, and only things a station makes are shown. It says what a recipe takes, never what
    to do.

    Chain sitting of 2026-11-17, run 090028: he tried the Stone Club with 4 of 6 Ash Logs and 4 of 8 Stone, and the
    Planner had written "The exact recipe amounts are a guess". 21 of the 46 logs of 16 and 17 Nov with a Stone
    Club craft held such a try; none read the recipe first. The turn replayed 10 times each way: a craft first 6 of
    10 as logged, 0 of 10 with this line (docs/research/2026-11-17-recipe-of-a-named-thing.md)."""
    cat = cat if cat is not None else catalog()
    rx, by = _named_index(cat)
    if rx is None or not isinstance(state, dict):
        return []
    named: list[str] = []
    for text in texts:
        for m in rx.finditer(str(text or "")):
            if m.group(1).lower() not in named:
                named.append(m.group(1).lower())
    if not named:
        return []
    inv = state.get("inventory") if isinstance(state.get("inventory"), dict) else {}
    have = {k: int(v) for k, v in inv.items() if isinstance(v, (int, float))}
    unlocked = set(state["recipes_unlocked"]) if isinstance(state.get("recipes_unlocked"), list) else None
    stations = cat.get("stations") or {}

    def short(entry) -> tuple:  # an unlocked recipe first, then the one he is least short for
        rid, r, _ = entry
        miss = [max(0, int(i.get("count") or 1) - have.get(i.get("item"), 0)) for i in r.get("inputs") or []]
        return (unlocked is not None and rid not in unlocked, sum(1 for n in miss if n), sum(miss))

    out = []
    for name in named[:limit]:
        rid, r, o = min(by[name], key=short)
        at = _station_names(r.get("stations") or [], cat)
        takes = " and ".join(f"{int(i.get('count') or 1)} {i.get('name') or i.get('item')} "
                             f"(you have {have.get(i.get('item'), 0)})" for i in r.get("inputs") or [])
        carried = have.get(o.get("item"), 0)
        out.append(f"{o.get('name')}" + (f" (you carry {carried})" if carried else "") + f" at a {at} takes {takes}"
                   + (", not among your unlocked recipes yet" if unlocked is not None and rid not in unlocked else "")
                   + _fuel_words(r, have, state, cat))
    return out


def named_recipes_line(state: dict, texts, cat: dict | None = None) -> str | None:
    rows = named_recipes(state, texts, cat)
    return ("Recipes of things your quests and job name: " + " | ".join(rows))[:LINE_CHARS] if rows else None


def _craft(state: dict, kinds: list[str], cat: dict, heal: bool = False) -> list[str]:
    unlocked = state.get("recipes_unlocked")
    unlocked = set(unlocked) if isinstance(unlocked, list) else None
    have = {k: v for k, v in (state.get("inventory") or {}).items() if isinstance(v, (int, float))}
    around = {}
    for g in (state.get("nearby_items") or []) + (state.get("nearby_resources") or []):
        if isinstance(g, dict) and g.get("item"):
            around.setdefault(g["item"], g)
    options = []
    for rid, r, kinded in _index(cat)["recipes"]:  # only recipes with a consumable output, catalog order
        sids = r.get("stations") or []
        if not sids or (unlocked is not None and rid not in unlocked):
            continue
        outs = [o for o, k in kinded if k in kinds]
        if not outs:
            continue
        st = (cat.get("stations") or {})
        if any((st.get(s) or {}).get("is_vendor") for s in sids):  # the station row's key (no trade is food today)
            continue
        missing = [(i, max(0, int(i.get("count") or 1) - int(have.get(i.get("item"), 0)))) for i in r.get("inputs") or []]
        missing = [(i, n) for i, n in missing if n > 0]
        near = _station_near(sids, state, cat)
        score = (len(missing), sum(n for _, n in missing), 0 if near else 1)
        options.append((score, rid, r, outs[0], missing, near, sids))
    options.sort(key=lambda o: o[0])
    lines = []
    seen = set()
    for score, rid, r, out, missing, near, sids in options:
        if out.get("item") in seen:
            continue
        seen.add(out.get("item"))
        need_station = _station_names(sids, cat)
        where = (f"at {near.get('name') or need_station} ({near['distance']:.0f} m, id {near.get('id')})"
                 if near and isinstance(near.get("distance"), (int, float))
                 else f"at a {need_station}: none near" + (" (it is a building piece; you have no build tool)" if any((cat.get('stations') or {}).get(s, {}).get('building') for s in sids) else ""))
        if not missing:
            what = "craftable now"
        else:
            i, n = min(missing, key=lambda m: m[1])
            lying = around.get(i.get("item"))
            what = f"missing {n} {i.get('name') or i.get('item')}" + (
                f" (lying {lying['distance']:.0f} m away, id {lying.get('id')})"
                if lying and isinstance(lying.get("distance"), (int, float)) else "") + (
                f" +{len(missing) - 1} more" if len(missing) > 1 else "")
        lines.append(f"{out.get('name') or out.get('item')} ({what}; {where}; recipe {rid})")
        if len(lines) >= MAX_OPTIONS - 1:
            break
    return lines


def _people(state: dict) -> list[str]:
    out = []
    for p in state.get("players") or []:
        if isinstance(p, dict) and p.get("name") and (_num(p.get("distance")) or 0) <= NEAR_M:
            out.append(f"{p['name']} ({p['distance']:.0f} m)" if _num(p.get("distance")) is not None else str(p["name"]))
    return out


# Endurance 0: the game scales his stamina down (BODY live 2026-10-31: sprint 0 s on every trip, jumps that never left
# the ground; a Summon Shelter rest took it 0 -> 100 in about 30 s).
REST_AT_ZERO = "; at 0 you can't sprint and your jumps fail until you rest in a bed or a Summon Shelter"
# What rest (the game's endurance) does, from game data: the wiki's Rest page (dragonwilds.runescape.wiki/w/Rest) and the
# live read of his BP_EnduranceComponent (2026-11-01, client_mod/commands/survival_probe.lua: levels 0/25/50/75/100,
# 0.15 per spell cast, 15 lost on death; at 14.8 rest his max stamina read 60 and his food/water maxes 75).
REST_FACTS = ("a nap in a bed or your Summon Shelter by day: +1 rest/s (empty to full ~100 s; a hit stops it); a night's "
              "sleep refills it and clears poison and Soulscourge; each spell costs 0.15 rest")


def _rest_effects(state: dict) -> str | None:
    """What low rest is doing to him right now, from his own maxes (the game applies the caps): max stamina (sprint
    and jumps), food/water caps. None when nothing is capped."""
    bits = []
    ms, ms_max = _num(state.get("max_stamina")), 100.0
    if ms is not None and ms < ms_max:
        bits.append(f"max stamina {ms:g}/100: less sprint and jump (80 under 50 rest, 60 under 25, 40 at 0)")
    caps = [f"{w} {_num(state.get(f'{s}_max')):g}" for s, w in (("sustenance", "food"), ("hydration", "water"))
            if _num(state.get(f"{s}_max")) is not None and _num(state.get(f"{s}_max")) < 100]
    if caps:
        bits.append("max " + ", ".join(caps) + " (capped under 25 rest, draining faster)")
    return "; ".join(bits) or None


def _rest(state: dict) -> list[str]:
    out = [sit.sleep_timeframe(state)]
    for s in state.get("spells") or []:  # a shelter he can summon is a place to rest (spell list, castable as read)
        if isinstance(s, dict) and s.get("id") == "USD_SummonShelter":
            out.append("Summon Shelter (your spell" + (", castable now)" if s.get("castable") else ", not castable now)"))
    for t in state.get("interactables") or []:
        if isinstance(t, dict) and t.get("kind") in ("bed", "resting_area"):
            bits = [f"{t['distance']:.0f} m" if _num(t.get("distance")) is not None else "", f"id {t.get('id')}",
                    f"prompt {t.get('prompt')}" if t.get("prompt") else "",
                    f"owner {t['owner']}" if t.get("owner") else "", f"claimed by {t['claimed_by']}" if t.get("claimed_by") else ""]
            out.append(f"{t.get('name')} ({', '.join(b for b in bits if b)})")
    return out[:MAX_OPTIONS]


def _load(state: dict, cat: dict) -> list[str]:
    """What weighs most in his bag (game data weight x count) and where it could go: storage in sight, chests he
    remembers (live 2026-11-02 02:44Z: 423/400 at a flax hunt; every trip at walking pace and nothing said it)."""
    items = cat.get("items") or {}
    heavy = []
    for r in state.get("inventory_items") or []:
        w = _num((items.get(r.get("item")) or {}).get("weight")) if isinstance(r, dict) else None
        if w and w > 0 and r.get("where") != "equipped":
            heavy.append((w * (_num(r.get("count")) or 1), f"{r.get('name') or r.get('item')} x{r.get('count') or 1} ({w * (_num(r.get('count')) or 1):.0f})"))
    heavy.sort(key=lambda x: -x[0])
    out = ["heaviest: " + ("; ".join(t for _, t in heavy[:MAX_OPTIONS]) if heavy else "unknown")]
    store = [f"{t.get('name')} ({t['distance']:.0f} m, id {t.get('id')})" for t in state.get("interactables") or []
             if isinstance(t, dict) and t.get("kind") == "storage" and "Gravestone" not in str(t.get("name"))
             and _num(t.get("distance")) is not None]
    rem = state.get("containers_remembered")
    if isinstance(rem, list):
        store += [str(x) for x in rem[:2]]
    out.append("store: " + ("; ".join(store[:MAX_OPTIONS]) if store else "no chest in sight or remembered (you can build one)"))
    out.append("or drop/give what you don't need")
    return out


def _tool(state: dict, need: dict, cat: dict) -> list[str]:
    want = str(need.get("category") or need.get("need_category") or "").lower()
    if not want:
        return []
    items = cat.get("items") or {}
    carried = [f"{r.get('name')} ({r.get('where')})" for r in state.get("inventory_items") or []
               if isinstance(r, dict) and want in str((items.get(r.get("item")) or {}).get("category") or "").lower()]
    craft = []
    for rid, r in (cat.get("recipes") or {}).items():
        sids = r.get("stations") or []
        if sids and any(want in str((items.get(o.get("item")) or {}).get("category") or "").lower() for o in r.get("outputs") or []):
            craft.append(f"{r['outputs'][0].get('name')} (recipe {rid}, at a {_station_names(sids, cat)})")
        if len(craft) >= MAX_OPTIONS:
            break
    return [f"carried: {'; '.join(carried)}" if carried else "carried: none"] + ([f"craft: {'; '.join(craft)}"] if craft else [])


def lines(state: dict, cat: dict | None = None) -> list[str]:
    """One line per pressing need, with its options (empty when nothing is pressing)."""
    if not state or state.get("unavailable") or state.get("dead") is True:  # dead: no need can be met until respawn
        return []
    cat = cat if cat is not None else catalog()
    people = _people(state)
    out = []
    for n in pressing(state):
        if n["need"] in ("food", "drink"):  # options with value, time and risk, bounded (brain/needs_options.py)
            from . import needs_options  # lazy: needs_options imports helpers from situation
            out.append(needs_options.digest(state, n, cat))
            continue
        word = sit.feel(n["need"], n.get("pct"))  # the words to relay; the numbers are for decisions
        head = f"Need {n['need']}" + (f" ({word + ', ' if word else ''}[{n['pct']:.0f}%]"
                                      + (f", empty in ~{n['zero_min']} min at the current drain; at 0 you lose 1 HP a second down to 1 HP, where any hit kills you"
                                         if n.get("zero_min") is not None else "")
                                      + (REST_AT_ZERO if n["need"] == "rest" and n["pct"] < 1 else "") + ")"
                                      if n.get("pct") is not None else "")
        parts = []
        if n["need"] == "rest":
            eff = _rest_effects(state)
            if eff:
                parts.append("effect now: " + eff)
            parts.append("rest: " + "; ".join(_rest(state) + lines_for(state, ["bed"])[:1]))
            parts.append("restores: " + REST_FACTS)
        elif n["need"] == "tool":
            parts.extend(_tool(state, n["tool"], cat))
        elif n["need"] == "load":
            head = "Need load (" + (f"OVERLOADED {n['weight']:.0f}/{n['max']:.0f}, " if n.get("weight") and n.get("max") else
                                    "OVERLOADED, ") + "walk only: no sprint or jumps until you're under)"
            parts.extend(_load(state, cat))
        else:
            c = _carried(state, n["kinds"], cat, n.get("heal", False))
            parts.append("carried: " + ("; ".join(c) if c else "none"))
            near = _nearby(state, n["kinds"], cat)
            if near:
                parts.append("nearby: " + "; ".join(near))
            rem = lines_for(state, [k for k in n["kinds"] if k != "food" or not n.get("heal")])
            if rem:  # remembered beyond sight (per-world map memory, BUGS L21)
                parts.append("remembered: " + "; ".join(rem[:2]))
        if people:
            parts.append("players who could help: " + ", ".join(people))
        if n["need"] not in ("rest", "tool", "load"):
            craft = _craft(state, n["kinds"], cat, n.get("heal", False))
            if craft:
                known = isinstance(state.get("recipes_unlocked"), list)
                # an estimate from game data; the body's craft_plan {item} has the authoritative live status
                parts.append(("craft/cook (estimate; craft_plan confirms): " if known
                              else "craft/cook (estimate, unlocks unknown; craft_plan confirms): ") + "; ".join(craft))
        out.append((head + " -> " + " | ".join(parts))[:LINE_CHARS])
    return out


# --------------------------------------------------------------------------- activity: abilities + rate feedback
# Luis: "use spells where he can, e.g. Rocksplosion for mining". For the current activity (the skill gaining
# XP fastest, from the body's get_state.activity) list the spells that game data ties to that skill
# (data/spell_effects.json: unlock.skill, cost, cooldown, requirement, target) and the held item's actions,
# plus the item/XP rate now vs the best seen. Information only: the model decides whether a spell helps.


def spell_catalog(path: str | None = None) -> dict:
    """data/spell_effects.json spells (the one loader: brain.spells.effects)."""
    return _spell_effects(path)


def _item_name(item: str, state: dict, cat: dict) -> str:
    return str(item_names(state).get(item) or ((cat.get("items") or {}).get(item) or {}).get("name") or item)


def activity_lines(state: dict, cat: dict | None = None, spells: dict | None = None) -> list[str]:
    act = state.get("activity") if isinstance(state.get("activity"), dict) else None
    if not act:
        return []
    cat = cat if cat is not None else catalog()
    spells = spells if spells is not None else spell_catalog()
    skill = act.get("skill")
    parts = []
    rate = []
    if skill and isinstance(act.get("xp_per_min"), (int, float)):
        rate.append(f"{act['xp_per_min']} XP/min" + (f" (best {act['best_xp_per_min']})" if act.get("best_xp_per_min") else ""))
    for it in act.get("items") or []:
        if isinstance(it, dict) and it.get("item"):
            rate.append(f"{_item_name(it['item'], state, cat)} {it.get('per_min')}/min (best {it.get('best_per_min')})")
    if rate:
        parts.append("rate over the last " + str(act.get("window_min") or "?") + " min: " + ", ".join(rate))
    if skill:
        own = []
        for sid, sp in spells.items():
            if (sp.get("unlock") or {}).get("skill") != skill or sp.get("status") not in (None, "unlocked"):
                continue
            cost = " ".join(f"{k} {v}" for k, v in (sp.get("cost") or {}).items())
            req = (sp.get("requirement") or {}).get("text")
            own.append(f"{sp.get('name')} ({sp.get('cast_type')}, {cost}, cooldown {sp.get('cooldown_s'):g} s"
                       + (f", needs {req}" if req else "") + ")")
        if own:
            parts.append(f"your {skill} spells: " + "; ".join(own[:4]))
    held = state.get("held_actions") if isinstance(state.get("held_actions"), dict) else None
    acts = [a.get("name") for a in (held or {}).get("actions") or [] if isinstance(a, dict) and a.get("name")]
    if acts:
        parts.append(f"{held.get('item_name') or 'held item'}: " + ", ".join(acts))
    if not parts:
        return []
    return [(f"Activity {skill or '(no XP gain)'} -> " + " | ".join(parts))[:LINE_CHARS]]

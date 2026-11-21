"""His food and water against the job, for the Planner (and the Controller's Food/drink line): perception, no advice.

L3 "gear up for a vault", 21 Nov: 10 of 44 failed runs died first; he ate in 7 of them, but what he carried healed 20
a bite (Dried Redberries, max HP 100), and 0 of 48 runs carried food healing 80 or more (Meat Sandwich 80, Fish Fry
180 exist). He cooked Rat Roast (heals 20) in 10 runs, stored food in a chest 8 times in 173 job runs and took it back
out 0 times. The heal values reached him only once HP was low (needs.pressing -> needs_options.digest); the Planner,
where a job's supplies are decided, saw his inventory as item ids. So this block puts beside each plan:

  carried   each food and drink he carries with what one restores (HP healed, food, water, Soulscourge), and totals;
  lasts     how long his food and water bars last at his drain, and with all he carries eaten as needed;
  fights    against the creatures in sight (the body's own odds, fight_odds) and the vault the job names: how many of
            their hits his carried healing covers (the game's attack damage, data/bestiary.json game_attacks);
  home      food and drink in the containers he has opened, as he saw them then (brain/stash.py);
  cook      the food and drink recipes he has unlocked, each with its value, and how many he has not;
  sources   the food and water he has seen on the map (brain/map_memory.py, nearest first) and what each yields.

Values come only from the game's data: data/food_values_<build>.json (needs_options.values(): the live
DT_FoodSustenance / DT_DrinkHydration rows and AmountToHealOnConsume, the wiki as fallback), the recipe catalog and the
bestiary. No line says what to do; nothing is ranked by value. The model judges whether to cook, store or carry more.
"""
from __future__ import annotations

import math
import re
import time
from typing import Any, Iterable

from .geom import direction, dist

KINDS = ("food", "drink")
# The game's decay rates, for when the body has not measured his drain yet (DISCOVERIES l. 1040-1042: HydrationComponent
# DecayRatePerHour 5.5, SustenanceComponent 4.15; l. 3214: one in-game hour per real minute on this world's clock). The
# body's vitals_rate (skills.lua, the median fall per real minute) wins when present: needs.pressing reads the same.
DECAY_PER_MIN = {"sustenance": 4.15, "hydration": 5.5}
EAT_S = 6.0  # one eat or drink, one at a time (needs_options.EAT_S; DISCOVERIES l. 2244 / 2525, measured live)
# The game's eating limits, WIKI-SOURCED (dragonwilds.runescape.wiki/w/Food rev 72760, data/wiki/pages/1397.json, first
# section): "there is a 2 second delay between eating food, and consuming more than 100 sustenance will start to build
# Over Eating - eating 200 sustenance over the cap will trigger the effect, preventing the player from eating any
# additional food for 15 seconds". The dump (dumps/26670300) names the mechanism (USustenanceComponent.OverEatenGE,
# GE_OverEaten, STATUS_EFFECT_OverEating, the OverEatingDecay attribute, UConsumableItemData.ConsumeCooldownEffectToApply)
# but holds no numbers, and none has been read live yet: these stay the wiki's until a probe reads the GE.
WIKI_EAT_GAP_S = 2.0
WIKI_OVEREAT_OVER_CAP = 200.0  # sustenance over the cap that triggers Over Eating (the cap: his max food, 100)
WIKI_OVEREAT_LOCK_S = 15.0
FIGHT_WINDOW_S = 30.0  # the window the fight line counts healing over
# What collect_water puts in his bag (DISCOVERIES l. 2422, needs_options._water / needs.WATER_SOURCE: the same fact).
COLLECT_WATER_GIVES = "dirty water"
CARRIED_SHOWN = 5
HOME_SHOWN = 3  # containers
HOME_ITEMS = 4  # food and drink rows per container
FOES_SHOWN = 4
SOURCES_SHOWN = 5
LINE_CHARS = 800  # one line of the block, bounded


def _num(v) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def _fv() -> dict:
    from .needs_options import values  # lazy: needs_options imports situation, which imports this module lazily
    return values()


def _cat() -> dict:
    from .needs import catalog
    return catalog()


def value(iid: str | None, row: dict | None = None, fv: dict | None = None) -> dict:
    """{kind, heal, sustenance, hydration, soulscourge, weight, duration, max_stack} of one item from the food data
    (weight and stack size from the recipe catalog's item rows when the food data lacks them); the body's own row
    numbers fill what the data lacks (inventory.lua describe_item reads the same item data live). {} when neither knows
    it."""
    v = dict(((fv if fv is not None else _fv()).get("items") or {}).get(iid) or {}) if iid else {}
    item = ((_cat().get("items") or {}).get(iid) or {}) if iid else {}
    for k in ("weight", "max_stack"):
        if _num(v.get(k)) is None and _num(item.get(k)) is not None:
            v[k] = _num(item[k])
    for k in ("heal", "sustenance", "hydration", "soulscourge", "max_stack"):
        if _num(v.get(k)) is None and row is not None and _num(row.get(k)) is not None:
            v[k] = _num(row[k])
    if not v.get("kind") and row is not None and isinstance(row.get("consumable"), str):
        v["kind"] = row["consumable"]
    out = {k: v[k] for k in ("kind", "name", "heal", "sustenance", "hydration", "soulscourge", "weight", "duration",
                             "max_stack") if v.get(k) is not None}
    return out if any(_num(out.get(k)) for k in ("heal", "sustenance", "hydration", "soulscourge")) or out.get("kind") else {}


def words(v: dict, ratios: bool = False) -> str:
    """'heals 20, +15 food' / '+25 water' / '+10 water, +20 Soulscourge' from one item's values. ``ratios``: with HP per
    food point and HP per kg (the wiki's Food page: Over Eating caps food taken, the bag caps weight) and the item's
    Duration when it has one."""
    bits = []
    if _num(v.get("heal")):
        bits.append(f"heals {v['heal']:g}")
    if _num(v.get("sustenance")):
        bits.append(f"+{v['sustenance']:g} food")
    if _num(v.get("hydration")):
        bits.append(f"+{v['hydration']:g} water")
    if _num(v.get("soulscourge")):
        bits.append(f"+{v['soulscourge']:g} Soulscourge")
    if ratios and _num(v.get("heal")):
        if _num(v.get("sustenance")):
            bits.append(f"{v['heal'] / v['sustenance']:.2g} HP per food")
        if _num(v.get("weight")):
            bits.append(f"{v['heal'] / v['weight']:.0f} HP/kg")
    if ratios and _num(v.get("duration")):
        bits.append(f"Duration {v['duration']:g} s")
    return ", ".join(bits) or "restores nothing in the data"


def _total(v: dict, n: int, key: str) -> float:
    return (_num(v.get(key)) or 0.0) * n


# ---------------------------------------------------------------------------------------------------- carried


def carried(state: dict, fv: dict | None = None) -> tuple[list[tuple[dict, dict]], dict[str, float]]:
    """([(inventory row, values)], totals {heal, sustenance, hydration}) for the food and drink on his hotbar and in his
    bag (a potion counts when the data gives it a value)."""
    rows, tot = [], {"heal": 0.0, "sustenance": 0.0, "hydration": 0.0}
    for r in state.get("inventory_items") or []:
        if not isinstance(r, dict) or r.get("where") not in ("hotbar", "bag"):
            continue
        v = value(r.get("item"), r, fv)
        if not v or (v.get("kind") not in KINDS and not _num(v.get("heal"))):
            continue
        n = int(_num(r.get("count")) or 1)
        rows.append((r, v))
        for k in tot:
            tot[k] += _total(v, n, k)
    return rows, tot


def carried_line(state: dict, fv: dict | None = None) -> str:
    rows, tot = carried(state, fv)
    if not rows:
        return "carried: no food or drink"
    shown, kg, slots = [], 0.0, 0
    for r, v in rows:
        n = int(_num(r.get("count")) or 1)
        kg += (_num(v.get("weight")) or 0.0) * n
        slots += math.ceil(n / v["max_stack"]) if _num(v.get("max_stack")) else 1
        if len(shown) < CARRIED_SHOWN:
            shown.append(f"{r.get('name') or v.get('name') or r.get('item')} x{n} on the {r['where']} "
                         f"(each: {words(v, ratios=True)})")
    more = len(rows) - len(shown)
    total = [f"{tot['heal']:g} HP of healing" if tot["heal"] else "no healing",
             f"+{tot['sustenance']:g} food" if tot["sustenance"] else "no food",
             f"+{tot['hydration']:g} water" if tot["hydration"] else "no water"]
    return ("carried: " + "; ".join(shown) + (f"; +{more} more" if more > 0 else "")
            + " = " + ", ".join(total) + f" in all, {kg:.1f} kg in {slots} slot{'s' if slots != 1 else ''}")


# ------------------------------------------------------------------------------------------------------ lasts


def _rate(state: dict, stat: str) -> tuple[float | None, str]:
    rates = state.get("vitals_rate") if isinstance(state.get("vitals_rate"), dict) else {}
    r = _num(rates.get(f"{stat}_per_min"))
    if r and r > 0:
        return r, "your drain now"
    return DECAY_PER_MIN.get(stat), "the game's decay rate"


def lasts_line(state: dict, fv: dict | None = None) -> str | None:
    """'lasts: food 76/100, empty in ~17 min (~31 min with what you carry); water ... at your drain now (food 4.4/min,
    water 5.6/min); at 0 you lose 1 HP a second'. The same arithmetic as needs.pressing (current / drain)."""
    _, tot = carried(state, fv)
    parts, src, per = [], set(), []
    for stat, word in (("sustenance", "food"), ("hydration", "water")):
        cur, mx = _num(state.get(stat)), _num(state.get(f"{stat}_max"))
        rate, where = _rate(state, stat)
        if cur is None or not rate:
            continue
        src.add(where)
        per.append(f"{word} {rate:g}/min")
        now = round(cur / rate)
        more = round((cur + tot[stat]) / rate)
        parts.append(f"{word} {cur:.0f}/{mx:.0f}, empty in ~{now} min"
                     + (f" (~{more} min with all you carry eaten as needed)" if more > now else " (you carry none)"))
    if not parts:
        return None
    return ("lasts: " + "; ".join(parts) + f", at {' / '.join(sorted(src))} ({', '.join(per)}); "
            "at 0 you lose 1 HP a second")


# ----------------------------------------------------------------------------------------------------- fights


def hit_damage(name: str | None) -> tuple[float, float] | None:
    """(mean, max) damage of one hit from the game's attack rows (data/bestiary.json game_attacks, the same rows
    tools/gen_creature_attacks.py gives the body's odds), None when the data has none."""
    if not name:
        return None
    from .plan_sources import _creature  # lazy: the bestiary loads on first use
    dmg = [float(x) for a in (_creature(str(name)).get("game_attacks") or []) if isinstance(a, dict)
           for x in (a.get("damage") or []) if _num(x) and x > 0]
    return (sum(dmg) / len(dmg), max(dmg)) if dmg else None


def fight_window(state: dict, gap_s: float, fv: dict | None = None, window_s: float = FIGHT_WINDOW_S) -> dict:
    """The HP his carried healing food gives in the first ``window_s`` of a fight at one use per ``gap_s``, eaten hotbar
    first by slot (the reflex's order), then the bag: each eat adds its food points, and once the food over his cap
    reaches the wiki's 200, Over Eating locks eating for 15 s (wiki Food rev 72760) and nothing after it is counted.
    -> {hp, eats, room (food points before Over Eating), locked (s into the window, or None)}"""
    rows, _ = carried(state, fv)
    rows = [(r, v) for r, v in rows if _num(v.get("heal"))]
    rows.sort(key=lambda rv: (rv[0].get("where") != "hotbar", _num(rv[0].get("slot")) or 99))
    cur = _num(state.get("sustenance")) or 0.0
    cap = _num(state.get("sustenance_max")) or 100.0
    room = max(0.0, cap + WIKI_OVEREAT_OVER_CAP - cur)
    queue = [v for r, v in rows for _ in range(int(_num(r.get("count")) or 1))]
    t, hp, eats, eaten, locked = 0.0, 0.0, 0, 0.0, None
    while queue and t < window_s:
        v = queue.pop(0)
        hp += v["heal"]
        eats += 1
        eaten += _num(v.get("sustenance")) or 0.0
        if eaten >= room:  # Over Eating: nothing after it is counted (how far it has decayed when the lock ends is unknown)
            locked = t
            break
        t += gap_s
    return {"hp": hp, "eats": eats, "room": room, "locked": locked, "cur": cur, "cap": cap}


def window_words(state: dict, fv: dict | None = None) -> str | None:
    """'in the first 30 s of a fight your carried healing gives 80 HP (4 eats at your ~6 s per use, hotbar first by
    slot; the wiki gives 2 s between foods: 80 HP); Over Eating (wiki: 200 food over your 100 cap locks eating 15 s)
    after 224 more food points from your food 76'."""
    slow, fast = fight_window(state, EAT_S, fv), fight_window(state, WIKI_EAT_GAP_S, fv)
    if not slow["eats"]:
        return None
    lock = (f", Over Eating locked you at {slow['locked']:.0f} s" if slow["locked"] is not None else "")
    return (f"in the first {FIGHT_WINDOW_S:g} s of a fight your carried healing gives {slow['hp']:g} HP ({slow['eats']} "
            f"eats at your measured ~{EAT_S:g} s per use, hotbar first by slot{lock}; at the wiki's {WIKI_EAT_GAP_S:g} s "
            f"between foods: {fast['hp']:g} HP); Over Eating (wiki: {WIKI_OVEREAT_OVER_CAP:g} food over your "
            f"{slow['cap']:g} cap locks eating {WIKI_OVEREAT_LOCK_S:g} s) comes after {slow['room']:.0f} more food points "
            f"from your food {slow['cur']:.0f}")


def fight_line(state: dict, enemies: Iterable[str] = (), fv: dict | None = None) -> str | None:
    """Against the creatures in sight (the body's odds: its time to kill him from his HP now) and the enemies the job's
    vault holds: how many of their hits his carried healing covers, and the seconds it adds at their rate."""
    _, tot = carried(state, fv)
    heal = tot["heal"]
    hp = _num(state.get("health"))
    odds = state.get("fight_odds") if isinstance(state.get("fight_odds"), dict) else {}
    seen, parts = set(), []
    near = sorted((e for e in state.get("nearby_entities") or [] if isinstance(e, dict) and e.get("alive", True)
                   and isinstance(odds.get(str(e.get("id"))), dict)),
                  key=lambda e: (not e.get("hostile"), _num(e.get("distance")) or 1e9))
    for e in near:
        name = str(e.get("name") or "")
        if not name or name in seen or len(seen) >= 2:
            continue
        seen.add(name)
        die = _num(odds[str(e["id"])].get("die_s"))  # its time to kill him from his HP now (combat.assess)
        h = hit_damage(name)
        bits = []
        if heal and h:
            bits.append(f"~{heal / h[0]:.0f} of its hits ({h[0]:.0f} each, up to {h[1]:g})")
        if heal and die and hp:
            bits.append(f"~{heal * die / hp:.0f} s more at its rate (the body's odds)")
        if bits:
            parts.append(f"{name} {_num(e.get('distance')) or 0:.0f} m: " + ", ".join(bits))
    foes, none = [], []
    for name in dict.fromkeys(str(n) for n in enemies if n):
        if name in seen or len(foes) >= FOES_SHOWN:
            continue
        h = hit_damage(name)
        if h is None:
            if len(none) < FOES_SHOWN:
                none.append(name)
        elif heal:
            foes.append(f"{name} ~{heal / h[0]:.0f} ({h[0]:.0f} each, up to {h[1]:g})")
        else:
            foes.append(f"{name} {h[0]:.0f} each, up to {h[1]:g}")
    if foes:
        parts.append(("in the vault: " if heal else "the vault's enemies hit for: ") + ", ".join(foes))
    if none:
        parts.append("no attack data for " + ", ".join(none))
    if heal and (w := window_words(state, fv)):
        parts.append(w)
    if not parts:
        return None
    return ("fights: what your carried healing covers: " if heal else "fights: you carry no healing; ") + "; ".join(parts)


# ------------------------------------------------------------------------------------------------------- home


def _ago(s: float | None) -> str:
    if s is None:
        return "some time ago"
    m = int(s // 60)
    return f"{m} min ago" if m < 120 else f"{m // 60} h ago"


def home_line(state: dict, fv: dict | None = None) -> str | None:
    """'home stock (what you saw when you last opened them): your Crate at (112,1850), 26 min ago: 26 Fillet (520 HP of
    healing), 29 Clean Water (+725 water)'. From containers_stock (brain/stash.py Stash.stock)."""
    stock = state.get("containers_stock")
    if not isinstance(stock, dict):
        return None
    vals = (fv if fv is not None else _fv()).get("items") or {}
    rows = []
    for label, rec in stock.items():
        items = rec.get("items") if isinstance(rec, dict) else None
        if not isinstance(items, dict):
            continue
        food = []
        for iid, n in items.items():
            v = value(iid, None, fv)
            if v.get("kind") in KINDS and _num(n):
                food.append((iid, int(n), v))
        if not food:
            continue
        food.sort(key=lambda x: -x[1])
        txt = []
        for iid, n, v in food[:HOME_ITEMS]:
            tot = [f"{_total(v, n, 'heal'):g} HP of healing" if _num(v.get("heal")) else "",
                   f"+{_total(v, n, 'hydration'):g} water" if _num(v.get("hydration")) else "",
                   f"+{_total(v, n, 'sustenance'):g} food" if not _num(v.get("heal")) and _num(v.get("sustenance")) else ""]
            txt.append(f"{n} {v.get('name') or (vals.get(iid) or {}).get('name') or iid} ({', '.join(t for t in tot if t)})")
        more = len(food) - HOME_ITEMS
        rows.append((_num(rec.get("ago_s")), f"{label}, {_ago(_num(rec.get('ago_s')))}: " + ", ".join(txt)
                     + (f", +{more} more" if more > 0 else "")))
    if not rows:
        return ("home stock: none of the " + str(len(stock)) + " containers you have opened held food or drink"
                if stock else None)
    rows.sort(key=lambda x: x[0] if x[0] is not None else 1e12)
    return "home stock (what you saw when you last opened them): " + " | ".join(t for _, t in rows[:HOME_SHOWN])


# ------------------------------------------------------------------------------------------------------- cook


def _vendor(r: dict, stations: dict) -> bool:
    from .knowledge import vendor_station
    return bool(r.get("vendor_reputation")) or any(vendor_station(s, stations) for s in r.get("stations") or [])


def _sum(v: dict) -> float:
    return sum(_num(v.get(k)) or 0.0 for k in ("heal", "sustenance", "hydration"))


def _lesser(r: dict, v: dict, fv: dict | None) -> bool:
    """A recipe whose output restores less than an input (burning food on purpose): not a way to get food."""
    return any(_sum(value(i.get("item"), None, fv)) >= _sum(v) for i in r.get("inputs") or [])


def recipes_line(state: dict, cat: dict | None = None, fv: dict | None = None) -> str | None:
    """The food and drink recipes he has unlocked (get_state.recipes_unlocked), one per output, each with its value
    and inputs, by station; those whose inputs he carries now are marked; then how many he has not unlocked and the
    most any of them heals. Without the unlock list, only what he can make from what he carries."""
    cat = cat if cat is not None else _cat()
    stations = cat.get("stations") or {}
    unlocked = set(state["recipes_unlocked"]) if isinstance(state.get("recipes_unlocked"), list) else None
    inv = {k: int(v) for k, v in (state.get("inventory") or {}).items() if _num(v)}
    by_station: dict[str, dict[str, list[str]]] = {}  # station words -> value words -> items (same value: one group)
    seen, locked, locked_heal = set(), set(), 0.0
    for rid, r in (cat.get("recipes") or {}).items():
        outs, ins = r.get("outputs") or [], r.get("inputs") or []
        if not outs or not ins or not r.get("stations") or r.get("test") or _vendor(r, stations):
            continue
        out = outs[0].get("item")
        v = value(out, None, fv)
        if v.get("kind") not in KINDS or not _sum(v) or _lesser(r, v, fv):
            continue
        have = all(inv.get(i.get("item"), 0) >= int(i.get("count") or 1) for i in ins)
        if unlocked is not None and rid not in unlocked:
            if out not in seen:
                locked.add(out)
                locked_heal = max(locked_heal, _num(v.get("heal")) or 0.0)
            continue
        if out in seen or (unlocked is None and not have):
            continue
        seen.add(out)
        locked.discard(out)
        from .needs import _station_names
        at = _station_names(r.get("stations") or [], cat)
        src = ", ".join(f"{int(i.get('count') or 1)} {i.get('name') or i.get('item')}" if int(i.get("count") or 1) > 1
                        else str(i.get("name") or i.get("item")) for i in ins)
        by_station.setdefault(at, {}).setdefault(words(v, ratios=True), []).append(
            f"{outs[0].get('name') or v.get('name') or out} ({src}" + ("; inputs on you" if have else "") + ")")
    if not by_station and not locked:
        return None
    head = "you can cook (your unlocked recipes" if unlocked is not None else \
        "you can make now from what you carry (unlocks unknown"
    # the locked count first: a cut at LINE_CHARS takes the last recipes, never the fact that more exist
    head += ((f"; {len(locked)} other food and drink recipes not unlocked yet"
              + (f", healing up to {locked_heal:g}" if locked_heal else "")) if locked else "")
    head += "; value each: item (inputs))"
    body = " | ".join(f"at a {at}: " + "; ".join(f"{w}: {', '.join(items)}" for w, items in groups.items())
                      for at, groups in by_station.items()) or "none"
    return f"{head}: {body}"


# ---------------------------------------------------------------------------------------------------- sources

_INDEX: dict[tuple[int, int], tuple[dict, dict, dict]] = {}


def _index(cat: dict, fv: dict) -> dict:
    """Per (catalog, food data), built once: item -> the food or drink it is or cooks into at a fire (a cook that burns
    food on purpose left out), and lower-case creature name -> its drops that are or cook into food."""
    hit = _INDEX.get((id(cat), id(fv)))
    if hit is not None and hit[0] is cat and hit[1] is fv:
        return hit[2]
    vals = fv.get("items") or {}

    def yields(iid: str | None) -> list[tuple[str, dict | None]]:
        out = []
        v = vals.get(iid) or {}
        if v.get("kind") in KINDS and _sum(v):
            out.append((iid, None))
        for rec in (fv.get("cooks") or {}).get(iid) or []:
            ov = vals.get(rec.get("output")) or {}
            if ov.get("kind") in KINDS and _sum(ov) > _sum(v):
                out.append((rec["output"], rec))
        return out

    items = {iid: y for iid in set(vals) | set(fv.get("cooks") or {}) if (y := yields(iid))}
    creatures = {}
    for name, c in (fv.get("creatures") or {}).items():
        drops = [(d["item"], d.get("qty"), d.get("chance")) for d in c.get("drops") or []
                 if isinstance(d, dict) and d.get("item") in items and (_num(d.get("chance")) or 0) > 0]
        if drops:
            creatures[name.lower()] = drops
    idx = {"items": items, "creatures": creatures}
    if len(_INDEX) > 4:
        _INDEX.clear()
    _INDEX[(id(cat), id(fv))] = (cat, fv, idx)
    return idx


def sources(records: list[dict], me, now: float | None = None, cat: dict | None = None, fv: dict | None = None,
            n: int = SOURCES_SHOWN) -> list[dict]:
    """The food and water sources among map-memory sightings (in sight or remembered), one row per name, nearest
    first: [{name, kind: resource|item|creature|water, item?, n, distance, direction, age_min}]. A sighting is a source
    when the game data says so: its item is or cooks into food or drink, its creature drops such an item, or (a place)
    its prompt shares a word with drink names (map_memory._gives: "Collect Water"). The nearest water source is kept
    even when nearer food fills the rows."""
    if not isinstance(me, (list, tuple)) or len(me) < 2:
        return []
    cat = cat if cat is not None else _cat()
    fv = fv if fv is not None else _fv()
    now = time.time() if now is None else now
    idx = _index(cat, fv)
    from .map_memory import NOT_PLACES, _gives, _item_kinds, need_vocab
    kinds, vocab = _item_kinds(cat), need_vocab(cat)
    groups: dict[tuple[str, str], dict] = {}
    for r in records:
        if not isinstance(r, dict):
            continue
        k = r.get("kind")
        if k in ("resource", "item") and r.get("item") in idx["items"]:
            kind = k
        elif k == "creature" and str(r.get("name") or "").lower() in idx["creatures"]:
            kind = "creature"
        elif k not in NOT_PLACES and r.get("prompt") and "drink" in _gives(r, cat, kinds, vocab):
            kind = "water"
        else:
            continue
        d = dist(me, r.get("position"), planar=True)
        if d is None:
            continue
        key = (kind, "" if kind == "water" else str(r.get("name") or r.get("item")))  # water: one row, the nearest's name
        g = groups.get(key)
        if g is None or d < g["distance"]:
            groups[key] = {"name": str(r.get("name") or r.get("item")), "kind": kind, **({"item": r["item"]} if r.get("item") else {}),
                           "n": (g or {}).get("n", 0), "distance": round(d), "direction": direction(me, r["position"]),
                           "age_min": max(0, round((now - float(r.get("last_seen") or now)) / 60))}
        groups[key]["n"] += 1
    rows = sorted(groups.values(), key=lambda g: g["distance"])
    out = rows[:n]
    water = next((g for g in rows if g["kind"] == "water"), None)
    if water is not None and water not in out:
        out = out[:max(0, n - 1)] + [water]
    return out


def _yield_words(row: dict, c: Any) -> str:
    """What one source gives, from data: 'Redberries heals 10, +5 food; at a fire: Dried Redberries heals 20, +15
    food' / 'Raw Farm Meat x2 -> at a fire: Steak heals 30, +20 food' / 'collect_water: Dirty Water ...'."""
    from .needs_options import _cook_of
    idx = _index(c.cat, c.fv)

    def item_words(iid: str) -> str:
        bits = []
        for out, rec in idx["items"].get(iid) or []:
            v = c.val(out)
            if rec is None:
                bits.append(f"{c.name(out)} {words(v)}")
            else:
                usable = _cook_of(c, iid, v.get("kind") or "food") is not None
                bits.append(f"at a fire: {c.name(out)} {words(v)}" + ("" if usable else " (recipe not unlocked)"))
        return "; ".join(bits)

    if row["kind"] == "water":
        dirty = c.names.get(COLLECT_WATER_GIVES)
        return f"collect_water: {item_words(dirty)}" if dirty else "water"
    if row["kind"] == "creature":
        drops = idx["creatures"].get(str(row["name"]).lower()) or []
        out = []
        for iid, q, ch in drops[:2]:
            qty = f" x{q:g}" if _num(q) and q != 1 else (f" x{q[0]}-{q[-1]}" if isinstance(q, list) and q else "")
            out.append(f"{c.name(iid)}{qty}" + (f" ({ch:.0%})" if _num(ch) and ch < 1 else "") + f" -> {item_words(iid)}")
        return "; ".join(out)
    return item_words(row.get("item"))


def sources_line(state: dict, cat: dict | None = None, fv: dict | None = None) -> str | None:
    """'food and water you have seen (nearest first, as seen then): Redberry Bush x3 45 m NE 5 min ago (...); ...'
    from food_sources (map_memory.annotate -> sources)."""
    rows = state.get("food_sources")
    if not isinstance(rows, list) or not rows:
        return None
    from .needs_options import _Ctx, pace
    c = _Ctx(state, cat if cat is not None else _cat(), fv if fv is not None else _fv(), pace())
    parts = []
    for r in rows:
        if not isinstance(r, dict):
            continue
        many = f" x{r['n']}" if r.get("kind") in ("resource", "item") and (r.get("n") or 0) > 1 else ""
        when = "seen just now" if not r.get("age_min") else f"seen {r['age_min']} min ago"
        parts.append(f"{r.get('name')}{many} {r.get('distance')} m {r.get('direction')}, {when} ({_yield_words(r, c)})")
    return "food and water you have seen (nearest first, as seen then): " + " | ".join(parts) if parts else None


# ------------------------------------------------------------------------------------------------------ block


def lines(state: dict, enemies: Iterable[str] = ()) -> list[str]:
    """The supplies block: a few bounded lines (empty when the state is unreadable). Each part is best effort: a gap in
    one never hides the others."""
    if not isinstance(state, dict) or state.get("unavailable") or not isinstance(state.get("inventory_items"), list):
        return []
    fv, cat = _fv(), _cat()
    out = []
    for part in (lambda: carried_line(state, fv), lambda: lasts_line(state, fv),
                 lambda: fight_line(state, enemies, fv), lambda: home_line(state, fv),
                 lambda: recipes_line(state, cat, fv), lambda: sources_line(state, cat, fv)):
        try:
            ln = part()
        except Exception as exc:  # perception is best effort
            ln = f"(a supplies line is unavailable: {type(exc).__name__})"
        if ln:
            out.append(ln if len(ln) <= LINE_CHARS else ln[:LINE_CHARS - 1] + "…")
    if any("Duration " in ln for ln in out):
        out.append(DURATION_NOTE)
    if not fv.get("items"):
        out.append("(no food value data loaded: values unknown)")
    return out


# What a food's Duration is, as far as it is known. UConsumableItemData.Duration (dumps/26670300) is read from the wiki
# into the food data; the wiki gives it as the time its perks last (Meat Sandwich rev 76606: "Meaty Meal and Grounded
# ... for 600 seconds"), and lists one on foods with no perk (Fish Fry rev 62694). DISCOVERIES l. 2455 reads it as HP
# over time, but l. 2427 saw a Forager's Sandwich (70 HP, Duration 600 s) take him from 0.5 to 100 HP at +1.5/s.
DURATION_NOTE = ("(Duration: the item data's own; the wiki gives it as how long the food's perks last. Whether a food's "
                 "HP comes at once or over its Duration has not been read live)")


_ENEMY = re.compile(r"^(.*?)(?:\s+x\d+)?(?:\s+PL\s+[\d.]+)?$")


def vault_enemies(where: dict) -> list[str]:
    """The creature names of the vaults the Planner's input names (planner._where gear_for_vault: 'Giant Rat x9 PL 2')."""
    out = []
    for v in where.get("gear_for_vault") or []:
        for e in (v.get("enemies") or []) if isinstance(v, dict) else []:
            m = _ENEMY.match(str(e).strip())
            if m and m.group(1):
                out.append(m.group(1))
    return list(dict.fromkeys(out))


def controller_words(state: dict) -> list[str]:
    """For the Controller's Food/drink line: what he carries in all (healing, food, water) and his home stock, short."""
    out = []
    rows, tot = carried(state)
    if rows:
        out.append("in all " + ", ".join(x for x in (f"{tot['heal']:g} HP of healing" if tot["heal"] else "no healing",
                                                     f"+{tot['sustenance']:g} food" if tot["sustenance"] else "",
                                                     f"+{tot['hydration']:g} water" if tot["hydration"] else "no water")
                                      if x))
    home = home_line(state)
    if home and home.startswith("home stock ("):
        out.append("home stock as last seen: " + home.split(": ", 1)[1])
    return out

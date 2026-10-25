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
from functools import lru_cache
from pathlib import Path
from typing import Any

from . import paths

DATA_DIR = paths.REPO_ROOT / "data"
MAX_OPTIONS = 4  # per source, per need (craft: 3)
NEAR_M = 40.0
LINE_CHARS = 560


@lru_cache(maxsize=2)
def catalog(path: str | None = None) -> dict:
    if path is None:
        files = sorted(DATA_DIR.glob("recipes_*.json"))
        if not files:
            return {}
        path = str(files[-1])
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def item_kind(item: str | None, cat: dict | None = None) -> str | None:
    """'food' | 'drink' | 'potion' | None from the item data CLASS (game data), never the name."""
    if not item:
        return None
    e = ((cat if cat is not None else catalog()).get("items") or {}).get(item) or {}
    cls = str(e.get("class") or "")
    for kind, word in (("food", "Food"), ("drink", "Drink"), ("potion", "Potion")):
        if f"Consumables_{word}" in cls:
            return kind
    return None


def _num(v) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


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

    food = _pct(state.get("sustenance"), state.get("sustenance_max"))
    if food is not None and food < float(pol.get("eat_below_pct") or 40) + 10:
        out.append({"need": "food", "kinds": ["food"], "pct": food, "zero_min": to_zero("sustenance", "sustenance_per_min")})
    drink = _pct(state.get("hydration"), state.get("hydration_max"))
    if drink is not None and drink < float(pol.get("drink_below_pct") or 40) + 10:
        out.append({"need": "drink", "kinds": ["drink"], "pct": drink, "zero_min": to_zero("hydration", "hydration_per_min")})
    hp = _pct(state.get("health"), state.get("max_health"))
    if hp is not None and hp < float(pol.get("heal_below_pct") or 50):
        out.append({"need": "health", "kinds": ["potion", "food"], "pct": hp, "heal": True})
    rest = _pct(state.get("endurance"), state.get("endurance_max"))
    if rest is not None and rest < 30:
        out.append({"need": "rest", "kinds": [], "pct": rest})
    tool = state.get("tool_need") if isinstance(state.get("tool_need"), dict) else None
    if tool:
        out.append({"need": "tool", "kinds": [], "tool": tool})
    return sorted(out, key=lambda n: n.get("pct", 0) if n.get("pct") is not None else 0)


def _carried(state: dict, kinds: list[str], cat: dict, heal: bool = False) -> list[str]:
    out = []
    for r in state.get("inventory_items") or []:
        if not isinstance(r, dict) or r.get("where") not in ("hotbar", "bag"):
            continue
        k = r.get("consumable") or item_kind(r.get("item"), cat)
        if k not in kinds or (heal and k == "food" and not r.get("heal")):
            continue
        facts = [r["where"]]
        for key, label in (("heal", "heals"), ("hydration", "water"), ("sustenance", "food")):
            if r.get(key) not in (None, "", "None"):
                facts.append(f"{label} {r[key]}")
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
    rows.sort(key=lambda x: x[0])
    return [f"{t} ({d:.0f} m, id {i})" if d < 1e8 else f"{t} (id {i})" for d, t, i in rows[:MAX_OPTIONS]]


def _station_names(sids: list[str], cat: dict) -> str:
    st = cat.get("stations") or {}
    return " or ".join(dict.fromkeys(str((st.get(s) or {}).get("name") or s) for s in sids))


def _station_near(sids: list[str], state: dict, cat: dict) -> dict | None:
    for row in state.get("stations_nearby") or []:
        if isinstance(row, dict) and row.get("station") in sids:
            return row
    classes = {c for s in sids for c in ((cat.get("stations") or {}).get(s) or {}).get("class_names") or []}
    for t in state.get("interactables") or []:
        if isinstance(t, dict) and t.get("class") in classes:
            return {"id": t.get("id"), "name": t.get("name"), "distance": t.get("distance")}
    return None


def _craft(state: dict, kinds: list[str], cat: dict, heal: bool = False) -> list[str]:
    unlocked = state.get("recipes_unlocked")
    unlocked = set(unlocked) if isinstance(unlocked, list) else None
    have = {k: v for k, v in (state.get("inventory") or {}).items() if isinstance(v, (int, float))}
    around = {}
    for g in (state.get("nearby_items") or []) + (state.get("nearby_resources") or []):
        if isinstance(g, dict) and g.get("item"):
            around.setdefault(g["item"], g)
    options = []
    for rid, r in (cat.get("recipes") or {}).items():
        sids = r.get("stations") or []
        if not sids or (unlocked is not None and rid not in unlocked):
            continue
        outs = [o for o in r.get("outputs") or [] if item_kind(o.get("item"), cat) in kinds]
        if not outs:
            continue
        st = (cat.get("stations") or {})
        if any((st.get(s) or {}).get("vendor") for s in sids):
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


def _rest(state: dict) -> list[str]:
    out = []
    for t in state.get("interactables") or []:
        if isinstance(t, dict) and t.get("kind") in ("bed", "resting_area"):
            bits = [f"{t['distance']:.0f} m" if _num(t.get("distance")) is not None else "", f"id {t.get('id')}",
                    f"prompt {t.get('prompt')}" if t.get("prompt") else "",
                    f"owner {t['owner']}" if t.get("owner") else "", f"claimed by {t['claimed_by']}" if t.get("claimed_by") else ""]
            out.append(f"{t.get('name')} ({', '.join(b for b in bits if b)})")
    tod = state.get("time_of_day") if isinstance(state.get("time_of_day"), dict) else {}
    if isinstance(tod.get("sleep_allowed"), bool):
        out.append("sleeping is possible now" if tod["sleep_allowed"] else "too early to sleep (resting still restores)")
    return out[:MAX_OPTIONS]


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
    if not state or state.get("unavailable"):
        return []
    cat = cat if cat is not None else catalog()
    people = _people(state)
    out = []
    for n in pressing(state):
        head = f"Need {n['need']}" + (f" ({n['pct']:.0f}%" + (f", empty in ~{n['zero_min']} min at the current drain; at 0 it hurts until you die"
                                                           if n.get("zero_min") is not None else "") + ")"
                                      if n.get("pct") is not None else "")
        parts = []
        if n["need"] == "rest":
            from .map_memory import lines_for
            parts.append("rest: " + ("; ".join(_rest(state) + lines_for(state, ["bed"])[:1]) or "no bed or shelter near"))
        elif n["need"] == "tool":
            parts.extend(_tool(state, n["tool"], cat))
        else:
            c = _carried(state, n["kinds"], cat, n.get("heal", False))
            parts.append("carried: " + ("; ".join(c) if c else "none"))
            near = _nearby(state, n["kinds"], cat)
            if near:
                parts.append("nearby: " + "; ".join(near))
            from .map_memory import lines_for
            rem = lines_for(state, [k for k in n["kinds"] if k != "food" or not n.get("heal")])
            if rem:  # remembered beyond sight (per-world map memory, BUGS L21)
                parts.append("remembered: " + "; ".join(rem[:2]))
        if people:
            parts.append("players who could help: " + ", ".join(people))
        if n["need"] not in ("rest", "tool"):
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


@lru_cache(maxsize=2)
def spell_catalog(path: str | None = None) -> dict:
    p = Path(path) if path else DATA_DIR / "spell_effects.json"
    try:
        return json.loads(p.read_text(encoding="utf-8")).get("spells") or {}
    except (OSError, ValueError):
        return {}


def _item_name(item: str, state: dict, cat: dict) -> str:
    for r in state.get("inventory_items") or []:
        if isinstance(r, dict) and r.get("item") == item and r.get("name"):
            return str(r["name"])
    return str(((cat.get("items") or {}).get(item) or {}).get("name") or item)


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

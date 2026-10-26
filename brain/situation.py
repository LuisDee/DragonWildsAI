"""The Controller's view of the world: a <=10-line situation digest plus the list of perceived things.

Research 2026-10-25 section 6.1: ``get_state`` stays the executor's verification source; the
models get a slim view instead of the raw state (no puppet internals, no class paths except the
ids an action needs). Everything is named by its in-game name where the body gives one
(``inventory_items[].name``, ``nearby_items[].name``, ``surroundings[].name``, look ``things[].name``),
else by the item catalog, else by a readable form of the id.

``perceived(state, looks)`` is the grounding source (section 6.2): the Controller refuses an action
on something that is not in it ("I can't see any sticks"), in code, not only in the prompt.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Iterable

from . import item_stats

REPO = Path(__file__).resolve().parents[1]
MAX_LINES = 18  # +skills, +module extras (2026-10-26)
MAX_GROUPS = 6  # per line
LINE_CHARS = 240
CREATURE_LINE_CHARS = 640  # with the body's fight odds per creature (prep eval 2026-10-26: 240 cut the second one)

# Words that never identify a thing on their own ("pick up the sticks" -> "sticks").
STOP_WORDS = {"the", "a", "an", "some", "any", "all", "of", "my", "your", "me", "you", "it", "that", "this",
              "those", "these", "them", "there", "here", "up", "pick", "get", "grab", "item", "items", "thing",
              "things", "stuff", "resource", "resources", "bp", "c", "ai", "character", "spawner", "world", "and",
              "please", "to", "for", "from", "on", "in", "with", "near", "nearest", "closest"}


def tokens(text: str | None) -> set[str]:
    """Lower-case word stems: 'Oak Logs' -> {'oak', 'log'}; 'BP_Spawner_AshBranch_C' -> {'ash', 'branch'}."""
    if not text:
        return set()
    s = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", str(text))  # CamelCase -> words
    out = set()
    for w in re.split(r"[^A-Za-z]+", s.lower()):
        if len(w) < 2 or w in STOP_WORDS:
            continue
        for suffix in ("ies", "es", "s"):
            if w.endswith(suffix) and len(w) > len(suffix) + 2 and not w.endswith("ss"):
                w = w[: -len(suffix)] + ("y" if suffix == "ies" else "")
                break
        out.add(w)
    return out


def pretty_id(raw: str | None) -> str:
    """'ITEM_Resources_Wood_Oak' -> 'Wood Oak'; 'kebbit_character_02' -> 'Kebbit'; 'log' -> 'log'."""
    if not raw:
        return "?"
    s = str(raw).rsplit("/", 1)[-1].split(".")[0]
    s = re.sub(r"^(ITEM|BP_AI|BP|USD)_", "", s)
    s = re.sub(r"_C(_\d+)?$", "", s)
    words = [w for w in re.split(r"[_\s]+", re.sub(r"(?<=[a-z])(?=[A-Z])", " ", s))
             if w and not w.isdigit() and w.lower() not in {"character", "resources", "spawner", "c"}]
    if not words:
        return str(raw)
    if raw == raw.lower() and "_" not in str(raw):
        return str(raw)  # plain mock ids like "log" stay as they are
    return " ".join(w if w[:1].isupper() else w.capitalize() for w in words)


@lru_cache(maxsize=4)
def catalog_names(path: str | None = None) -> dict[str, str]:
    """Item id -> display name from the newest data/items_<build>.json (equipment today)."""
    files = [Path(path)] if path else sorted((REPO / "data").glob("items_*.json"))
    if not files or not files[-1].exists():
        return {}
    try:
        items = json.loads(files[-1].read_text(encoding="utf-8")).get("items") or {}
    except (OSError, ValueError):
        return {}
    return {k: v.get("name") for k, v in items.items() if isinstance(v, dict) and v.get("name")
            and "MISSING" not in v.get("name", "")}


def item_names(state: dict) -> dict[str, str]:
    """Item id -> name for everything the body named in this state."""
    names: dict[str, str] = {}
    for row in (state.get("inventory_items") or []) + (state.get("nearby_items") or []):
        if isinstance(row, dict) and row.get("item") and row.get("name"):
            names.setdefault(str(row["item"]), str(row["name"]))
    return names


def name_of_item(item: str, names: dict[str, str]) -> str:
    return names.get(item) or catalog_names().get(item) or pretty_id(item)


@dataclass
class Thing:
    """One perceived thing (or a group of same-named things)."""
    name: str
    kind: str  # item | creature | player | gatherable | tree | rock | station | resource | ...
    id: str | None = None
    distance: float | None = None
    count: int = 1
    gives: list[str] = field(default_factory=list)
    actions: list[str] = field(default_factory=list)
    hostile: bool | None = None
    extra: set[str] = field(default_factory=set)  # more words that identify it (item id, class word)
    note: str | None = None  # short facts for the digest: "HP 40/60", "chop, needs Hatchet T1", "Craft"
    group: str = "thing"  # digest line: creature | item | player | around | usable

    def words(self) -> set[str]:
        return tokens(self.name) | tokens(self.kind) | {w for g in self.gives for w in tokens(g)} | \
            {w for e in self.extra for w in tokens(e)}

    def label(self) -> str:
        d = f"{self.distance:.0f} m" if isinstance(self.distance, (int, float)) else ""
        n = f"{self.name} x{self.count}" if self.count > 1 else self.name
        bits = [b for b in (d, f"id {self.id}" if self.id else "", self.note or "") if b]
        return f"{n} ({', '.join(bits)})" if bits else n


def _item_note(g: dict) -> str | None:
    """A ground item's facts: its kind (food/drink, item data), who dropped it and how long ago."""
    bits = []
    if isinstance(g.get("consumable"), str):
        bits.append(g["consumable"])
    if g.get("dropped_by"):
        age = g.get("seen_s")
        bits.append(f"dropped by {g['dropped_by']}" + (f" {int(age)} s ago" if isinstance(age, (int, float)) and age < 600 else ""))
    return ", ".join(bits) or None


def num(v) -> float | None:
    """A real number (not a bool), else None."""
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def _num(v) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def _hp(row: dict) -> str | None:
    hp, mx = _num(row.get("hp", row.get("health"))), _num(row.get("max_hp", row.get("max_health")))
    if hp is None:
        return None
    return f"HP {hp:g}/{mx:g}" if mx else f"HP {hp:g}"


def _resource_note(row: dict) -> str | None:
    """'chop, needs Hatchet T1, HP 220/220' for a gated destructible; None for plain things."""
    bits = []
    if row.get("tool"):
        tier = row.get("tool_tier")
        bits.append(f"{row.get('verb') or 'hit'}, needs {row['tool']}" + (f" T{tier}" if tier is not None else ""))
    if row.get("kind") == "destructible" and (hp := _hp(row)):
        bits.append(hp)
    if row.get("stump"):
        bits.append("stump")
    return ", ".join(bits) or None


# The body's estimate (combat.assess) uses only what he holds right now: no shield, buff spell, enchant, food
# or other weapon is counted. Said so, because "too strong" read as final (prep eval 2026-10-26: Haiku
# declined 4/4 hard fights without looking at combat_brief or his options).
ODDS_WORDS = {"likely_win": "likely win", "likely_lose": "likely lose", "too_strong": "much stronger",
              "outnumbered": "outnumbered", "boss": "a boss"}


def _odds_times(o: dict) -> list[str]:
    """'kills you ~20 s', 'you it ~75 s' from one odds row (now or prepared)."""
    return [t for t in (f"kills you ~{o['die_s']:g} s" if _num(o.get("die_s")) is not None else "",
                        f"you it ~{o['kill_s']:g} s" if _num(o.get("kill_s")) is not None else "") if t]


def _creature_note(e: dict, odds: dict) -> str | None:
    """'HP 900/900, PL 6, boss, fighting, odds: too strong for you (it kills you in ~20 s, you it in ~75 s)'.
    The odds are the body's own estimate (combat.fight_odds, the same as combat_brief): information, not advice."""
    bits = [b for b in (_hp(e),) if b]
    pl = _num(e.get("power_level", e.get("pl")))
    if pl is not None:
        bits.append(f"PL {pl:g}")
    if e.get("boss"):
        bits.append("boss")
    if e.get("in_combat"):
        bits.append("fighting")
    o = odds.get(str(e.get("id"))) if isinstance(odds, dict) else None
    if isinstance(o, dict) and o.get("verdict"):
        t = _odds_times(o) if o["verdict"] != "likely_win" else []  # times matter in a hard fight (line budget)
        if _num(o.get("pl_gap")) and o["verdict"] != "likely_win":
            t.insert(0, f"PL +{o['pl_gap']:g}")
        bits.append(f"odds now: {ODDS_WORDS.get(o['verdict'], o['verdict'])}" + (f" ({'; '.join(t)})" if t else ""))
        known = o.get("known") if isinstance(o.get("known"), dict) else {}
        if known:  # what he knows of its damage-type affinities, each with its source (learned/journal/prior)
            bits.append("known: " + ", ".join(f"{v.get('v')} to {str(k).rsplit('.', 1)[-1]} ({v.get('src')})" for k, v in sorted(known.items())
                                             if isinstance(v, dict)))
        imm = o.get("immune_effects")
        if isinstance(imm, list) and imm:  # status effects it ignores (wiki): e.g. weapon poison, burning
            bits.append(f"immune to {', '.join(str(x) for x in imm)} effects (wiki)")
        p = o.get("prepared") if isinstance(o.get("prepared"), dict) else None
        if p and p.get("verdict"):
            uses = ", ".join(str(u) for u in (p.get("uses") or []))
            bits.append(f"odds prepared: {ODDS_WORDS.get(p['verdict'], p['verdict'])} ({'; '.join(_odds_times(p))})"
                        + (f" with {uses}" if uses else " (nothing you own or can cast changes it)"))
    return ", ".join(bits) or None


def perceived(state: dict, looks: Iterable[dict] = ()) -> list[Thing]:
    """Everything the companion can currently perceive: get_state lists, the body's surroundings
    digest, and the things returned by look calls this turn."""
    out: list[Thing] = []
    names = item_names(state)
    odds = state.get("fight_odds") if isinstance(state.get("fight_odds"), dict) else {}
    for e in state.get("nearby_entities") or []:
        if isinstance(e, dict) and e.get("alive", True):
            out.append(Thing(e.get("name") or pretty_id(e.get("kind") or e.get("id")), "creature", e.get("id"),
                             _num(e.get("distance")), actions=["attack"], hostile=e.get("hostile"),
                             extra={str(e.get("kind") or "")}, note=_creature_note(e, odds), group="creature"))
    for g in state.get("nearby_items") or []:
        if isinstance(g, dict):
            item = str(g.get("item") or g.get("id") or "")
            out.append(Thing(g.get("name") or name_of_item(item, names), "item", g.get("id"), _num(g.get("distance")),
                             count=int(g.get("count") or 1), gives=[g.get("name") or name_of_item(item, names)],
                             actions=["pickup", "interact"], extra={item}, group="item",
                             note=_item_note(g)))
    for p in state.get("players") or []:
        if isinstance(p, dict) and p.get("name"):
            out.append(Thing(str(p["name"]), "player", str(p["name"]), _num(p.get("distance")), actions=["follow", "give"],
                             group="player"))
    for r in state.get("nearby_resources") or []:
        if not isinstance(r, dict):
            continue
        if r.get("name"):  # the real body (body/gather.lua extender, from sense.look; client sense.census)
            t = _look_thing(r)
            t.note, t.group = _resource_note(r), "around"
            out.append(t)
        else:  # the mock's trees and rocks
            res = str(r.get("resource") or "")
            kind = {"log": "tree", "stone": "rock"}.get(res, "resource")
            out.append(Thing(f"{kind} ({res})", kind, r.get("id"), _num(r.get("distance")), gives=[res],
                             actions=["gather"], extra={res}))
    for r in state.get("interactables") or []:  # stations, chests, beds, graves (client body)
        if isinstance(r, dict) and r.get("name"):
            t = _look_thing({"verb": "interact", **r})
            t.note, t.group = (str(r["prompt"]) if r.get("prompt") else None), "usable"
            out.append(t)
    for s in state.get("surroundings") or []:  # body digest groups (no ids)
        if isinstance(s, dict) and s.get("name"):
            out.append(Thing(str(s["name"]), str(s.get("kind") or "thing"), s.get("id"),
                             _num(s.get("nearest_m", s.get("distance_m"))), count=int(s.get("count") or 1),
                             gives=[str(x) for x in s.get("gives") or []], actions=list(s.get("actions") or [])))
        elif isinstance(s, str):
            out.append(Thing(s, "thing"))
    for look in looks:
        for t in (look or {}).get("things") or []:
            if isinstance(t, dict) and t.get("name"):
                out.append(_look_thing(t))
    return out


def _look_thing(t: dict) -> Thing:
    """One entry of a body look (body/sense.lua M.describe): {id, name, kind, verb, distance, count,
    item | drops, prompt, class, ...}. The design-doc shape (gives, actions, distance_m) works too."""
    acts = [a.get("a") if isinstance(a, dict) else str(a) for a in t.get("actions") or []]
    if t.get("verb"):
        acts.append(str(t["verb"]))
    gives = [str(x) for x in t.get("gives") or []]
    if t.get("drops"):
        gives.append(str(t["drops"]))
    if t.get("item"):
        gives.append(pretty_id(str(t["item"])))
    kind = str(t.get("kind") or "thing")
    return Thing(str(t["name"]), kind, t.get("id"), _num(t.get("distance", t.get("distance_m"))),
                 count=int(t.get("count") or 1), gives=gives, actions=[a for a in acts if a],
                 hostile=True if kind == "creature" and t.get("hostile") else None,
                 extra={str(t.get("class") or ""), str(t.get("item") or ""), str(t.get("prompt") or "")})


def look_matched(look: dict) -> bool | None:
    """Did a look about=X find X? The body ranks by a per-thing ``match`` score (0 = no match)."""
    if not (look.get("_about") or look.get("about")):
        return None
    if isinstance(look.get("matched"), bool):
        return look["matched"]
    return any((t.get("match") or 0) > 0 for t in look.get("things") or [] if isinstance(t, dict))


def match(query: str | None, things: Iterable[Thing]) -> list[Thing]:
    """Things whose name, kind or 'gives' share a word with the query ('sticks' ~ 'Stick')."""
    want = tokens(query)
    if not want:
        return []
    return [t for t in things if want & t.words()]


def by_id(target: str | None, things: Iterable[Thing]) -> Thing | None:
    if not target:
        return None
    low = str(target).lower()
    return next((t for t in things if t.id and str(t.id).lower() == low), None)


def describe_seen(things: Iterable[Thing], limit: int = 5, kinds: set[str] | None = None) -> str:
    """'Oak Logs, Oak Tree, Kebbit' (distinct names, nearest first)."""
    seen: list[str] = []
    for t in sorted(things, key=lambda t: t.distance if t.distance is not None else 1e9):
        if t.kind == "player" or (kinds and t.kind not in kinds) or t.name in seen:
            continue
        seen.append(t.name)
    more = len(seen) - limit
    return ", ".join(seen[:limit]) + (f" and {more} more" if more > 0 else "")


# --------------------------------------------------------------------------- digest


def _group(things: list[Thing]) -> list[Thing]:
    groups: dict[str, Thing] = {}
    for t in sorted(things, key=lambda t: t.distance if t.distance is not None else 1e9):
        g = groups.get(t.name)
        if g is None:
            groups[t.name] = Thing(t.name, t.kind, t.id, t.distance, t.count, list(t.gives), list(t.actions), t.hostile,
                                   note=t.note, group=t.group)
        else:
            g.count += t.count
    return list(groups.values())


def _line(label: str, items: list[str], cap: int = LINE_CHARS) -> str | None:
    if not items:
        return None
    more = len(items) - MAX_GROUPS
    text = f"{label}: " + "; ".join(items[:MAX_GROUPS]) + (f"; +{more} more" if more > 0 else "")
    return text[:cap]


def _health(state: dict) -> str | None:
    hp, mx = _num(state.get("health")), _num(state.get("max_health"))
    if hp is None:
        return None
    if mx and mx > 0:
        return f"HP {round(100 * hp / mx)}%"
    return f"HP {round(100 * hp)}%" if hp <= 1 else f"HP {hp:g}"


HELD_SLOTS = {"right", "left", "held_right", "held_left", "heldright", "heldleft"}


def wearing(state: dict, names: dict[str, str] | None = None) -> list[str]:
    """What the companion wears, by in-game name ('Hard Leather Cowl'), from ``gear`` (slot -> item id
    or path; held slots excluded) and the names in ``inventory_items``."""
    gear = state.get("gear") if isinstance(state.get("gear"), dict) else {}
    names = names if names is not None else item_names(state)
    out: list[str] = []
    for slot, item in gear.items():
        if not item or str(slot).lower() in HELD_SLOTS:
            continue
        key = str(item).rsplit("/", 1)[-1].rsplit(".", 1)[-1]
        name = name_of_item(key, names)
        if name not in out:
            out.append(name)
    return out


def recent_life(state: dict) -> list[str]:
    """Own gravestone(s) and the last death, from the client body's get_state: one "Recent:" line, then
    one "Grave:" line per unrecovered grave not in sight, most valuable first (BUGS L19/L22)."""
    bits, grave_lines = [], []
    d = state.get("last_death") if isinstance(state.get("last_death"), dict) else None
    if d and isinstance(d.get("ago_s"), (int, float)):
        ago = int(d["ago_s"])
        when = f"{ago // 60} min ago" if ago >= 120 else f"{ago} s ago"
        bits.append(f"you died {when}" + (" and respawned" if d.get("respawned") else ""))
    graves = state.get("graves_remembered") if isinstance(state.get("graves_remembered"), list) else None
    if graves is None and isinstance(state.get("death_memory"), dict):
        graves = [{**state["death_memory"], "go_to": "my_grave"}]
    seen_id = (state.get("my_grave") or {}).get("id") if isinstance(state.get("my_grave"), dict) else None
    for gv in item_stats.rank_graves(graves or []):  # most valuable first, from item data (BUGS L22)
        if seen_id and gv.get("grave_id") == seen_id:
            continue  # the one in sight is described below
        dist = f"{gv['distance']} m away" if isinstance(gv.get("distance"), (int, float)) else "somewhere"
        lost = ", ".join(str(x) for x in (gv.get("lost") or [])[:6])
        grave_lines.append((f"Grave: an unrecovered grave of yours (not in sight) from {gv.get('iso') or '?'}, {dist} "
                            f"(go_to target '{gv.get('go_to') or 'my_grave'}')"
                            + (f", holding about {gv.get('lost_items')} items: {lost}" if lost else ""))[:LINE_CHARS])
    g = state.get("my_grave") if isinstance(state.get("my_grave"), dict) else None
    if g:
        dist = f"{g['distance']:.0f} m away" if isinstance(g.get("distance"), (int, float)) else "nearby"
        what = ", ".join(str(c) for c in (g.get("contents") or [])[:8])
        bits.append(f"YOUR gravestone is {dist} (id {g.get('id')}) holding {g.get('items', '?')} of your items"
                    + (f": {what}" if what else ""))
    if isinstance(state.get("other_graves"), int) and state["other_graves"] > 0:
        bits.append(f"{state['other_graves']} other gravestone(s) here are not yours")
    out = [("Recent: " + "; ".join(bits))[:LINE_CHARS]] if bits else []
    return out + grave_lines[:3]


def world_line(state: dict) -> str | None:
    """In-game clock, the sleep window and bag space (client get_state time_of_day / bag)."""
    bits = []
    t = state.get("time_of_day") if isinstance(state.get("time_of_day"), dict) else {}
    if isinstance(t.get("hour"), (int, float)):
        h = float(t["hour"])
        bits.append(f"in-game {int(h):02d}:{int(round((h % 1) * 60)) % 60:02d}")
    if t.get("phase"):
        bits.append(str(t["phase"]))
    if t.get("resting_in"):
        bits.append(f"you are lying in {t['resting_in']} (movement is disabled while resting)")
    if isinstance(t.get("sleep_allowed"), bool):
        bits.append("sleeping is possible now" if t["sleep_allowed"] else "too early to sleep")
    b = state.get("bag") if isinstance(state.get("bag"), dict) else {}
    if isinstance(b.get("used"), int) and isinstance(b.get("capacity"), int):
        bits.append(f"bag {b['used']}/{b['capacity']} slots")
    end, mx = state.get("endurance"), state.get("endurance_max")
    if isinstance(end, (int, float)) and isinstance(mx, (int, float)) and mx:
        bits.append(f"rested {round(100 * end / mx)}% (endurance, restored by sleep)")
    return ("World: " + ", ".join(bits)) if bits else None


def hands(state: dict) -> str | None:
    """What the held item can do, from the game's own action data (combat.lua held_actions)."""
    h = state.get("held_actions") if isinstance(state.get("held_actions"), dict) else None
    acts = [a for a in (h or {}).get("actions") or [] if isinstance(a, dict)]
    if not acts:
        return None
    out = []
    for a in acts:
        bits = [str(a.get("style") or "")]
        if a.get("needs"):
            bits.append(f"needs {a['needs']}")
        bits.append("ready" if a.get("unlocked", True) else f"locked: {a.get('perk') or 'perk'}")
        out.append(f"{a.get('name') or a.get('style')} ({', '.join(b for b in bits if b)})")
    who = h.get("item_name") or h.get("item") or "held item"
    return (f"Hands: {who}: " + "; ".join(out))[:LINE_CHARS]


def vitals_policy(state: dict) -> str | None:
    """When the stay-fed reflex eats/drinks/heals by itself (the model sets it: set_vitals_policy)."""
    p = state.get("vitals_policy") if isinstance(state.get("vitals_policy"), dict) else None
    if not p:
        return None
    heal = p.get("heal_below_pct")
    return (f"Reflex policy: drink below {p.get('drink_below_pct')}%, eat below {p.get('eat_below_pct')}%, "
            f"eat to heal {'below ' + str(heal) + '% HP' if heal else 'off'} (always below {p.get('safety_floor_pct')}%)")


def stations(state: dict) -> list[str]:
    """Crafting/processing stations nearby with what they are doing (crafting.lua stations_nearby)."""
    out = []
    for st in state.get("stations_nearby") or []:
        if not isinstance(st, dict):
            continue
        bits = [f"{st['distance']:.0f} m" if isinstance(st.get("distance"), (int, float)) else "", f"id {st.get('id')}"]
        if st.get("running"):
            bits.append(f"making {st.get('making') or '?'}")
        if st.get("contents"):
            bits.append(", ".join(str(c) for c in st["contents"][:4]))
        out.append(f"{st.get('name') or st.get('station')} ({'; '.join(b for b in bits if b)})")
    return out


def consumable_rows(state: dict, kinds: Iterable[str] | None = None, kind_of=None,
                    heal_only: bool = False) -> list[tuple[str, dict]]:
    """(kind, row) for every carried hotbar/bag item that is a consumable: the body's own ``consumable``
    field first, else ``kind_of(item)`` (game data, e.g. needs.item_kind). ``kinds`` filters; ``heal_only``
    keeps food only when it heals. Shared by the digest's Food/drink line and the needs digest."""
    want = set(kinds) if kinds is not None else None
    out = []
    for r in state.get("inventory_items") or []:
        if not isinstance(r, dict) or r.get("where") not in ("hotbar", "bag"):
            continue
        k = r.get("consumable") if isinstance(r.get("consumable"), str) else (kind_of(r.get("item")) if kind_of else None)
        if not k or (want is not None and k not in want) or (heal_only and k == "food" and not r.get("heal")):
            continue
        out.append((k, r))
    return out


def consumable_facts(r: dict, order=(("hydration", "water"), ("sustenance", "food"), ("heal", "heals"))) -> list[str]:
    return [f"{label} {r[k]}" for k, label in order if r.get(k) not in (None, "", "None")]


def consumables(state: dict) -> list[str]:
    """Food and drink he carries, with where it is (only hotbar items can be used), from item data."""
    return [f"{r.get('name') or r.get('item')} x{r.get('count') or 1} ({', '.join([k, r['where'], *consumable_facts(r)])})"
            for k, r in consumable_rows(state)]


QUEST_FIELDS = ("quest", "step", "detail", "hint", "counters")  # what of a quest row the brain shows


def quest_rows(state: dict, limit: int = 8) -> list[dict]:
    """The active quest rows of get_state.quests, each cut to QUEST_FIELDS (the digest and the Director share it)."""
    q = state.get("quests") if isinstance(state.get("quests"), dict) else {}
    return [{k: a[k] for k in QUEST_FIELDS if a.get(k)} for a in (q.get("active") or [])[:limit] if isinstance(a, dict)]


def quests_line(state: dict, limit: int = 3) -> str | None:
    """'Quests: Rune Mysteries: <the current step in the game's words> (hint ...); 2 done' from get_state.quests
    (client_mod/scripts/quests.lua: {active: [{quest, step, detail, hint, counters}], complete, counts})."""
    q = state.get("quests") if isinstance(state.get("quests"), dict) else None
    if not q:
        return None
    parts = []
    for a in quest_rows(state, limit):
        step = a.get("step") or "?"
        extra = [f"hint: {a['hint']}" if a.get("hint") else "",
                 ", ".join(f"{k} {v}" for k, v in list((a.get("counters") or {}).items())[:3])]
        extra = [e for e in extra if e]
        parts.append(f"{a.get('quest')}: {step}" + (f" ({'; '.join(extra)})" if extra else ""))
    more = len(q.get("active") or []) - len(parts)
    done = len(q.get("complete") or [])
    tail = [f"{more} more active" if more > 0 else "", f"{done} done" if done else ""]
    tail = [t for t in tail if t]
    if not parts and not tail:
        return None
    return ("Quests: " + ("; ".join(parts) or "none active") + (f"; {', '.join(tail)}" if tail else ""))[:LINE_CHARS]


def skills_line(state: dict) -> str | None:
    """'Skills (lowest first): Artisan 1, Cooking 1 (40 xp to next), ..., Attack 3' from get_state.skills
    (a list of {skill, level, xp, xp_to_next?} or a {name: {level, xp}} dict). Lowest first, so "level up
    whatever's lowest" can be answered from the digest (skills-coverage eval 2026-10-26)."""
    raw = state.get("skills")
    if isinstance(raw, dict):
        rows = [{"skill": k, **v} for k, v in raw.items() if isinstance(v, dict)]
    elif isinstance(raw, list):
        rows = [r for r in raw if isinstance(r, dict)]
    else:
        return None
    rows = [r for r in rows if (r.get("skill") or r.get("name")) and num(r.get("level")) is not None]
    if not rows:
        return None
    rows.sort(key=lambda r: (num(r.get("level")), str(r.get("skill") or r.get("name"))))
    parts = []
    for r in rows:
        nxt = num(r.get("xp_to_next"))
        parts.append(f"{r.get('skill') or r.get('name')} {num(r['level']):g}" + (f" ({nxt:g} xp to next)" if nxt else ""))
    return ("Skills (lowest first): " + ", ".join(parts))[:LINE_CHARS]


# get_state keys the digest (or the needs digest) already renders, or the body's internals. Every OTHER
# key a client module adds through state_extras (fishing_spots_nearby, ...) is rendered generically by
# extras_lines, so a new module shows up without a brain edit.
COVERED_KEYS = frozenset({
    "action", "activity", "bag", "body", "dead", "death_memory", "endurance", "endurance_max", "exhausted", "fight",
    "following", "gear", "graves_remembered", "health", "held", "held_actions", "held_item", "hydration",
    "hydration_max", "interactables", "inventory", "inventory_items", "last_death", "last_held", "max_health",
    "max_stamina", "my_grave", "name", "nearby_entities", "nearby_items", "nearby_resources", "not_implemented",
    "other_graves", "pawn", "places", "players", "players_online", "position", "recipes_unlocked", "remembered",
    "skills", "sleeping", "stamina", "stations_nearby", "structures", "surroundings", "survival", "sustenance",
    "sustenance_max", "time_of_day", "tool_need", "total_level", "unavailable", "vitals_policy", "vitals_rate", "yaw",
    "spells", "spells_locked_n", "extras_keys", "world_guid", "puppet", "spell_cooldowns", "time",
    "power_level", "fight_odds", "quests",
})
EXTRAS_LINES, EXTRAS_ITEMS = 3, 4


def _extra_item(v) -> str:
    if isinstance(v, dict):
        name = v.get("name") or v.get("kind") or v.get("id") or "?"
        d = num(v.get("distance_m", v.get("distance")))
        bits = [f"{d:.0f} m" if d is not None else "", f"id {v['id']}" if v.get("id") and v.get("name") else ""]
        bits += [f"{k} {v[k]}" for k in ("level", "method", "kind", "count") if v.get(k) not in (None, "") and k != "name"
                 and not (k == "kind" and name == v.get("kind"))][:2]
        return f"{name} ({', '.join(b for b in bits if b)})" if any(bits) else str(name)
    return str(v)


def extras_lines(state: dict) -> list[str]:
    """Generic lines for module state_extras (keys not in COVERED_KEYS, or the body's own extras_keys list):
    'Fishing spots nearby: Net Fishing Spot (4 m, id ..., level 2, method net); ...' top-N, nearest first."""
    keys = state.get("extras_keys") if isinstance(state.get("extras_keys"), list) else \
        sorted(k for k in state if k not in COVERED_KEYS)
    out = []
    for k in keys:
        v = state.get(k)
        if isinstance(v, list) and v:
            items = sorted(v, key=lambda x: num(x.get("distance_m", x.get("distance"))) if isinstance(x, dict) and
                           num(x.get("distance_m", x.get("distance"))) is not None else 1e9)
            text = "; ".join(_extra_item(x) for x in items[:EXTRAS_ITEMS]) + (
                f"; +{len(v) - EXTRAS_ITEMS} more" if len(v) > EXTRAS_ITEMS else "")
        elif isinstance(v, dict) and v:
            text = ", ".join(f"{a} {_extra_item(b)}" for a, b in list(v.items())[:EXTRAS_ITEMS])
        elif isinstance(v, (str, int, float)) and not isinstance(v, bool) and v != "":
            text = str(v)
        else:
            continue
        out.append(f"{k.replace('_', ' ').capitalize()}: {text}"[:LINE_CHARS])
        if len(out) >= EXTRAS_LINES:
            break
    return out


def summary(state: dict, *, active_goal: str | None = None, tasks: list[dict] | None = None,
            places: Iterable[str] = (), looks_supported: bool = False) -> list[str]:
    """At most 10 short lines describing the companion's situation, by in-game names."""
    if not state or state.get("unavailable"):
        return [f"(game state unavailable: {state.get('unavailable') if state else 'no state'})"]
    names = item_names(state)
    things = perceived(state)
    lines: list[str | None] = []

    me = [b for b in (_health(state),) if b]
    if _num(state.get("power_level")) is not None:  # his own power level (combat state_extras), beside the creatures' PL
        me.append(f"PL {_num(state.get('power_level')):g}")
    for stat, word in (("hydration", "water"), ("sustenance", "food")):  # survival needs (client body)
        cur, mx = _num(state.get(stat)), _num(state.get(f"{stat}_max"))
        if cur is not None:
            pct = round(100 * cur / mx) if mx else round(cur)
            me.append(f"{word} {pct}%" + (" (LOW)" if pct < 15 else ""))
    gear = state.get("gear") if isinstance(state.get("gear"), dict) else {}
    if state.get("held"):  # the client body names it already
        me.append(f"holding {state['held']}")
    elif held := gear.get("right") or gear.get("held_right"):
        item = str(held).rsplit("/", 1)[-1].rsplit(".", 1)[-1]  # /Root/.../ITEM_X.ITEM_X -> ITEM_X
        me.append(f"holding {name_of_item(item, names)}")
    if state.get("following"):
        me.append(f"following {state['following']}")
    elif state.get("action"):
        me.append(f"doing {state['action']}")
    if state.get("sleeping"):
        me.append("asleep")
    lines.append("You: " + (", ".join(me) or "ok"))
    from . import needs  # lazy: needs imports helpers from this module
    lines.extend(needs.lines(state))  # pressing needs -> the options the game offers (brain/needs.py)
    lines.extend(needs.activity_lines(state))  # current activity: spells/actions for it + rate vs best
    lines.extend(recent_life(state))

    worn = wearing(state, names)
    if worn:
        lines.append(_line("Wearing", worn))
    inv = state.get("inventory") or {}
    carry = [f"{name_of_item(k, names)} x{v}" for k, v in sorted(inv.items(), key=lambda kv: -kv[1]) if v]
    lines.append(_line("Carrying", carry) or "Carrying: nothing")
    lines.append(_line("Food/drink", consumables(state)))
    lines.append(_line("Spare gear", item_stats.describe_carried(state)))
    lines.append(skills_line(state))
    lines.append(quests_line(state))
    lines.append(hands(state))
    lines.append(world_line(state))
    lines.append(vitals_policy(state))

    pl = [t for t in things if t.kind == "player"]
    lines.append(_line("Players", [f"{t.name} {t.distance:.0f} m" if t.distance is not None else t.name for t in pl]))

    # hostiles first, then by distance (the nearest threat leads the line)
    # (a creature the body rates hard counts as a threat for the order: it must not be cut off the line)
    odds = state.get("fight_odds") if isinstance(state.get("fight_odds"), dict) else {}

    def _hard(g):  # the body's own verdict for the group's nearest creature: anything but an easy win
        o = odds.get(str(g.id))
        return isinstance(o, dict) and bool(o.get("verdict")) and o["verdict"] != "likely_win"
    creatures = sorted(_group([t for t in things if t.kind == "creature"]),
                       key=lambda g: (not (g.hostile or _hard(g)), g.distance if g.distance is not None else 1e9))
    odds_note = (" (the body's odds, you alone: 'now' = as equipped; 'prepared' = with what you own and can cast;"
                 " blocking, dodging and armour not counted)") if state.get("fight_odds") else ""
    lines.append(_line("Creatures" + odds_note, [("hostile " if g.hostile else "") + g.label() for g in creatures],
                       CREATURE_LINE_CHARS if odds_note else LINE_CHARS))

    ground = _group([t for t in things if t.kind == "item"])
    lines.append(_line("On the ground", [g.label() for g in ground]))

    around = _group([t for t in things if t.kind not in ("player", "creature", "item") and t.group != "usable"])
    lines.append(_line("Around", [g.label() for g in around]))
    usable = _group([t for t in things if t.group == "usable"])
    lines.append(_line("Usable", [g.label() for g in usable]))
    lines.append(_line("Stations", stations(state)))
    if not looks_supported and not state.get("surroundings") and \
            "nearby_resources" in (state.get("not_implemented") or []):
        lines.append("You cannot perceive trees, rocks, plants or ground gatherables (sticks, stones) yet: "
                     "only creatures, players and items lying on the ground.")

    if active_goal:
        tasks = tasks or []
        done = sum(1 for t in tasks if t.get("status") == "done")
        cur = next((t for t in tasks if t.get("status") in ("running", "pending")), None)
        step = f"; step {done + 1}/{len(tasks)}: {cur['skill']}" if cur and tasks else ""
        lines.append(f"Job: {active_goal}{step}"[:LINE_CHARS])

    known = sorted(set(state.get("places") or []) | set(places))
    lines.append(_line("Places", known))
    lines.extend(extras_lines(state))  # what client modules add (state_extras): last, lowest priority
    return [line for line in lines if line][:MAX_LINES]

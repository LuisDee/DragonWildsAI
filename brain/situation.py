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
import math
import re
import time
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Iterable

from . import item_stats

REPO = Path(__file__).resolve().parents[1]
MAX_LINES = 26  # 18 cut every line after Creatures: On the ground, Stations, Places, Your bases, module extras such as
                # your_farm (live 2026-11-02 05:33Z: "where's the farm?" with his own plot 7.5 m away)
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
    group: str = "thing"  # digest line: creature | item | player | around | usable | built | further
    up_m: float | None = None  # height above his feet (body census up_m; negative = below)

    def words(self) -> set[str]:
        return tokens(self.name) | tokens(self.kind) | {w for g in self.gives for w in tokens(g)} | \
            {w for e in self.extra for w in tokens(e)}

    def label(self) -> str:
        d = f"{self.distance:.0f} m" if isinstance(self.distance, (int, float)) else ""
        n = f"{self.name} x{self.count}" if self.count > 1 else self.name
        bits = [b for b in (d, height_words(self.up_m), f"id {self.id}" if self.id else "", self.note or "") if b]
        return f"{n} ({', '.join(bits)})" if bits else n


# Heights in the digest (building / climbing perception, docs/research/2026-11-01-autonomous-building.md §4.1):
# only when it matters, i.e. beyond a step he walks up (his single jump is 1.64 m, DISCOVERIES move_calib).
UP_SHOW_M = 1.5


def height_words(up_m: float | None) -> str:
    """'15 m up' / '4 m down' when the height is beyond a step, else ''."""
    if not isinstance(up_m, (int, float)) or abs(up_m) < UP_SHOW_M:
        return ""
    return f"{abs(up_m):.0f} m {'up' if up_m > 0 else 'down'}"


def up_of(row: dict, state: dict | None = None) -> float | None:
    """A row's height above his feet, as the body measured it (sense.census / build.lua structures up_m). Never
    computed here: placeholder positions in old rows and mocks would invent heights."""
    return num(row.get("up_m"))


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


def _owner_words(s: dict) -> str:
    """Whose a built piece is: the game keeps no owner per piece (dump 26161880), so his own record of what he
    placed (deconstruct.lua my_pieces.json) says it: mine True/False; nothing when it wasn't checked (brain run
    2026-11-01 19:42Z took other crates and tables for his: "we already got most of it up here")."""
    return {True: "yours", False: "not placed by you"}.get(s.get("mine"), "")


FAR_KINDS = {"creatures": "creature", "items": "item"}  # further_off category -> Thing.kind (others keep the row's own)
FAR_SHOWN = 10
FAR_LINE_CHARS = 520


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
                             extra={str(e.get("kind") or "")}, note=_creature_note(e, odds), group="creature",
                             up_m=up_of(e, state)))
    for g in state.get("nearby_items") or []:
        if isinstance(g, dict):
            item = str(g.get("item") or g.get("id") or "")
            out.append(Thing(g.get("name") or name_of_item(item, names), "item", g.get("id"), _num(g.get("distance")),
                             count=int(g.get("count") or 1), gives=[g.get("name") or name_of_item(item, names)],
                             actions=["pickup", "interact"], extra={item}, group="item",
                             note=_item_note(g), up_m=up_of(g, state)))
    for p in state.get("players") or []:
        if isinstance(p, dict) and p.get("name"):
            out.append(Thing(str(p["name"]), "player", str(p["name"]), _num(p.get("distance")), actions=["follow", "give"],
                             group="player", up_m=up_of(p, state)))
    for r in state.get("nearby_resources") or []:
        if not isinstance(r, dict):
            continue
        if r.get("name"):  # the real body (body/gather.lua extender, from sense.look; client sense.census)
            t = _look_thing(r, state)
            t.note, t.group = _resource_note(r), "around"
            out.append(t)
        else:  # the mock's trees and rocks
            res = str(r.get("resource") or "")
            kind = {"log": "tree", "stone": "rock"}.get(res, "resource")
            out.append(Thing(f"{kind} ({res})", kind, r.get("id"), _num(r.get("distance")), gives=[res],
                             actions=["gather"], extra={res}))
    # building pieces (build.lua get_state.structures): by the name buildables uses, so a crate he built reads
    # "Crate" everywhere (co-play 2026-11-01: "Base Building Crate x2" beside a build reply about a "Crate")
    pieces = {str(s["id"]): s for s in state.get("structures") or [] if isinstance(s, dict) and s.get("id")}
    usable_ids = set()
    for r in state.get("interactables") or []:  # stations, chests, beds, graves (client body)
        if isinstance(r, dict) and r.get("name"):
            s = pieces.get(str(r.get("id")))
            row = {**r, "name": s["name"]} if s and s.get("name") else r
            t = _look_thing({"verb": "interact", **row}, state)
            t.note, t.group = (str(r["prompt"]) if r.get("prompt") else None), "usable"
            if s:
                t.note = ", ".join(b for b in ("ghost piece" if s.get("ghosted") else "", _owner_words(s), t.note) if b) or None
            usable_ids.add(str(r.get("id")))
            out.append(t)
    for sid, s in pieces.items():  # pieces with no use (foundation, wall, stairs): their own line
        if sid not in usable_ids and s.get("name"):
            note = ", ".join(b for b in ("ghost piece" if s.get("ghosted") else "", _owner_words(s)) if b) or None
            out.append(Thing(str(s["name"]), "structure", sid, _num(s.get("distance")), actions=[],
                             extra={str(s.get("piece") or "")}, note=note, group="built", up_m=up_of(s, state)))
    for s in state.get("surroundings") or []:  # body digest groups (no ids)
        if isinstance(s, dict) and s.get("name"):
            out.append(Thing(str(s["name"]), str(s.get("kind") or "thing"), s.get("id"),
                             _num(s.get("nearest_m", s.get("distance_m"))), count=int(s.get("count") or 1),
                             gives=[str(x) for x in s.get("gives") or []], actions=list(s.get("actions") or [])))
        elif isinstance(s, str):
            out.append(Thing(s, "thing"))
    # kinds in sight that the lists above have no row of: each list is the N nearest of its category, so in a busy
    # place a whole kind is cut off (client sense.digest_cut -> get_state.further_off; no ids, the nearest one's distance)
    for r in state.get("further_off") or []:
        if isinstance(r, dict) and r.get("name"):
            t = _look_thing({**r, "kind": FAR_KINDS.get(str(r.get("category")), r.get("kind"))}, state)
            t.id, t.note, t.group = None, _resource_note(r), "further"
            out.append(t)
    for look in looks:
        for t in (look or {}).get("things") or []:
            if isinstance(t, dict) and t.get("name"):
                out.append(_look_thing(t, state))
    return out


def _look_thing(t: dict, state: dict | None = None) -> Thing:
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
                 extra={str(t.get("class") or ""), str(t.get("item") or ""), str(t.get("prompt") or "")},
                 up_m=up_of(t, state))


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
        # built pieces: his and others' (the note says whose) are never counted as one group
        key = t.name + ("\0" + (t.note or "") if t.group in ("usable", "built") else "")
        g = groups.get(key)
        if g is None:
            groups[key] = Thing(t.name, t.kind, t.id, t.distance, t.count, list(t.gives), list(t.actions), t.hostile,
                                   note=t.note, group=t.group, up_m=t.up_m)
        else:
            g.count += t.count
    return list(groups.values())


def _line(label: str, items: list[str], cap: int = LINE_CHARS) -> str | None:
    if not items:
        return None
    more = len(items) - MAX_GROUPS
    text = f"{label}: " + "; ".join(items[:MAX_GROUPS]) + (f"; +{more} more" if more > 0 else "")
    return text[:cap]


# How a stat feels, as the words a player would use (M1 2026-10-26: given "HP 2%, water 0%" the model said
# "I'm at 2% HP"; it relays what it is given, so it is given words first). Perception, not phrasing: the
# model still chooses whether and how to say it. Bands: (below %, word), checked in order.
FEEL = {
    "health": ((1, "dying"), (15, "nearly dead"), (35, "badly hurt"), (65, "hurt"), (90, "a bit hurt"),
               (101, "healthy")),
    "water": ((1, "out of water, parched and losing health"), (15, "parched"), (35, "thirsty"),
              (60, "a bit thirsty"), (101, "not thirsty")),
    "food": ((1, "out of food, starving and losing health"), (15, "starving"), (35, "hungry"),
             (60, "a bit peckish"), (101, "fed")),
    "rest": ((15, "exhausted"), (35, "tired"), (101, "rested")),
}
FEEL_ALIASES = {"hp": "health", "hydration": "water", "drink": "water", "sustenance": "food", "endurance": "rest"}


def feel(stat: str, pct: float | None) -> str | None:
    """The word for a stat at ``pct`` % of its max ("nearly dead", "thirsty"), None when unknown."""
    bands = FEEL.get(FEEL_ALIASES.get(str(stat).lower(), str(stat).lower()))
    if pct is None or not bands:
        return None
    return next((word for cut, word in bands if pct < cut), bands[-1][1])


def _stat(word: str, pct: float) -> str:
    """"health: nearly dead [2%]": the words to relay first, the number (decisions only) in brackets."""
    return f"{word}: {feel(word, pct) or 'ok'} [{pct:.0f}%]"


def _health(state: dict) -> str | None:
    hp, mx = _num(state.get("health")), _num(state.get("max_health"))
    if hp is None:
        return None
    if mx and mx > 0:
        return _stat("health", 100 * hp / mx)
    return _stat("health", 100 * hp) if hp <= 1 else f"health {hp:g} HP"


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
        # the loadout's ammo slots are what a weapon spends, not clothes ("Wearing: Air Rune" read as nothing a
        # staff casts with: live rung 4, 22:10Z, "no proper attack spells at Magic 1", and he clubbed the goblin)
        sl = str(slot).lower()
        if sl.startswith("magicammo"):
            name += " (magic ammo: a staff or wand casts with it)"
        elif sl == "ammo":
            name += " (arrows: a bow shoots it)"
        elif sl == "crossbowbolts":
            # live rung 4, 08:27Z: "a bow or crossbow shoots it" on his 2 Bone Bolts read as arrows for his new bow;
            # he planned Bone Bolts, made no arrows and found out at the equip
            name += " (crossbow bolts: only a crossbow shoots them, a bow can't)"
        if name not in out:
            out.append(name)
    return out


KILL_ZONE_WORDS = "falling into a kill zone (a drop the game kills anything in)"


def death_cause(d: dict) -> str:
    """What the body's vitals rows say killed him (fatal/death: killed_by, fell_m, bars, at), in a few words:
    "killed by Giant Rat; fell 12 m; bars then food 12%, water 61%, rest 87% (...); at Temple Woods". Nothing the
    game said reads "cause unknown", never a blank he fills in (live 16:37Z: a fall into the kill zone at 12 % food,
    and he said "starving got me")."""
    bits = []
    kb = d.get("killed_by")
    if isinstance(kb, dict):  # the raw fatal row: {self, name, player, class}
        kb = "my own condition" if kb.get("self") else kb.get("name") or kb.get("player") or kb.get("class")
    if kb == "KillZVolume" or d.get("killed_by_class") == "KillZVolume" and not kb:  # an older body's raw class
        kb = KILL_ZONE_WORDS
    bits.append(f"killed by {kb.strip()}" if isinstance(kb, str) and kb.strip() else "cause unknown (the game didn't say)")
    if isinstance(d.get("fell_m"), (int, float)) and d["fell_m"] > 0:
        bits.append(f"fell {d['fell_m']:.0f} m")
    bars = d.get("bars") if isinstance(d.get("bars"), dict) else {}
    shown = [(w, bars.get(k)) for k, w in (("food", "food"), ("water", "water"), ("rest", "rest"))
             if isinstance(bars.get(k), (int, float))]
    if shown:
        empty = [w for w, v in shown if w in ("food", "water") and v <= 0]
        why = (f": {' and '.join(empty)} empty" if empty else
               ": food and water above 0, so not hunger or thirst" if len([1 for w, _ in shown if w != "rest"]) == 2 else "")
        bits.append("bars then " + ", ".join(f"{w} {v:.0f}%" for w, v in shown) + why)
    at = d.get("at")
    if isinstance(at, (list, tuple)) and len(at) >= 2 and all(isinstance(c, (int, float)) for c in at[:3]):
        region = _region_name(tuple(at[:3]))
        bits.append(f"at {region}" if region else "at [" + ", ".join(f"{c:.0f}" for c in at[:3]) + "]")
    return "; ".join(bits)


@lru_cache(maxsize=64)
def _region_name(pos: tuple) -> str | None:
    """The game map's region at ``pos`` (brain.places, data/places_<build>.json); None without map data."""
    try:
        return _map_places().region_name(list(pos))
    except Exception:
        return None


@lru_cache(maxsize=1)
def _map_places():
    from .places import Places  # lazy: only a death with a place needs the map
    return Places()


def _grave_age(gv: dict, now: float | None = None) -> str | None:
    """'a death 41 min ago' from a remembered grave's time (its ts, or the my_grave:<ts> target), so an older death in the
    grave list is not read as the one just now (live gear_up 2026-11-02: "died twice" after one death in the window)."""
    ts = gv.get("ts") if isinstance(gv.get("ts"), (int, float)) else None
    if ts is None:
        m = re.search(r"my_grave:(\d+(?:\.\d+)?)", str(gv.get("go_to") or ""))
        ts = float(m.group(1)) if m else None
    if ts is None:
        return None
    ago = max(0, int((now if now is not None else time.time()) - ts))
    words = (f"{ago} s" if ago < 120 else f"{ago // 60} min" if ago < 7200 else f"{ago // 3600} h" if ago < 172800
             else f"{ago // 86400} days")
    return f"a death {words} ago"


def recent_life(state: dict) -> list[str]:
    """Own gravestone(s) and the last death, from the client body's get_state: one "Recent:" line, then
    one "Graves ..." line with up to 3 unrecovered graves not in sight, newest first (BUGS L19/L22)."""
    bits, grave_lines = [], []
    d = state.get("last_death") if isinstance(state.get("last_death"), dict) else None
    if d and isinstance(d.get("ago_s"), (int, float)):
        ago = int(d["ago_s"])
        when = f"{ago // 60} min ago" if ago >= 120 else f"{ago} s ago"
        how = death_cause(d)
        bits.append(f"you died {when}" + (f" ({how})" if how else "") + (" and respawned" if d.get("respawned") else ""))
    graves = state.get("graves_remembered") if isinstance(state.get("graves_remembered"), list) else None
    if graves is None and isinstance(state.get("death_memory"), dict):
        graves = [{**state["death_memory"], "go_to": "my_grave"}]
    seen_id = (state.get("my_grave") or {}).get("id") if isinstance(state.get("my_grave"), dict) else None
    shown = [g for g in (graves or []) if not (seen_id and isinstance(g, dict) and g.get("grave_id") == seen_id)]
    newest = item_stats.newest_grave(shown)
    for gv in item_stats.graves_for_line(shown):  # the newest first, then the most valuable (BUGS L22, D2)
        dist = f"{gv['distance']:.0f} m away" if isinstance(gv.get("distance"), (int, float)) else "somewhere"
        dist = ("your newest, " + dist) if gv is newest and len(shown) > 1 else dist
        lost = ", ".join(str(x) for x in (gv.get("lost") or [])[:3])
        age = _grave_age(gv)
        grave_lines.append(f"{dist}, from {gv.get('iso') or '?'}{', ' + age if age else ''} (go_to target '{gv.get('go_to') or 'my_grave'}')"
                           + (f", about {gv.get('lost_items')} items: {lost}" if lost else "")
                           + (f"; DANGER: {gv['danger']}" if gv.get("danger") else ""))  # skills.lua death-spot hazard
    g = state.get("my_grave") if isinstance(state.get("my_grave"), dict) else None
    if g:
        dist = f"{g['distance']:.0f} m away" if isinstance(g.get("distance"), (int, float)) else "nearby"
        what = ", ".join(str(c) for c in (g.get("contents") or [])[:8])
        bits.append(f"YOUR gravestone is {dist} (id {g.get('id')}) holding {g.get('items', '?')} of your items"
                    + (f": {what}" if what else ""))
    if isinstance(state.get("other_graves"), int) and state["other_graves"] > 0:
        bits.append(f"{state['other_graves']} other gravestone(s) here are not yours")
    # a death's cause and bars take ~150 chars: room for them AND the gravestone after (was cut at LINE_CHARS)
    out = [("Recent: " + "; ".join(bits))[:2 * LINE_CHARS if d else LINE_CHARS]] if bits else []
    if grave_lines:  # one line for every grave not in sight (prompt diet 2026-10-31: was a line each)
        out.append(("Graves of yours not in sight, newest first: " + " | ".join(grave_lines[:3]))[:2 * LINE_CHARS])
    if d or grave_lines:  # the game's rule (UItemData.bDropOnDeath; Luis 2026-11-01), so he says true things about a grave
        out.append("On death you keep runes, ammo and worn armour; weapons and your bag/hotbar go into the grave.")
    return out


def sleep_timeframe(state: dict) -> str:
    """Report only the game's sleep-timeframe signal, not whether rest is usable."""
    t = state.get("time_of_day") if isinstance(state.get("time_of_day"), dict) else {}
    v = t.get("sleep_allowed")
    return "sleep timeframe " + ("open" if v is True else "closed" if v is False else "unknown")


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
    bits.append(sleep_timeframe(state))
    b = state.get("bag") if isinstance(state.get("bag"), dict) else {}
    if isinstance(b.get("used"), int) and isinstance(b.get("capacity"), int):
        bits.append(f"bag {b['used']}/{b['capacity']} slots")
    return ("World: " + ", ".join(bits)) if bits else None  # endurance is on the You: line (rest)


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
    # what the reflex does, so a plan doesn't double up on it (live 15:49Z: he moved a drink to the hotbar and drank
    # it; the reflex had drunk one in between, so his was wasted). Off = nothing is used by itself.
    floor = p.get("safety_floor_pct")
    if p.get("reflex_on") is False:
        how = ". The reflex is OFF: nothing is eaten or drunk by itself"
    else:
        every = p.get("reflex_every_s")
        how = (". Below a line your body uses food/drink from your hotbar by itself, one per kind every "
               f"~{every if isinstance(every, (int, float)) else 6:g} s (from the bag only under {floor}%)")
    return (f"Reflex policy: drink below {p.get('drink_below_pct')}%, eat below {p.get('eat_below_pct')}%, "
            f"eat to heal {'below ' + str(heal) + '% HP' if heal else 'off'} (always below {floor}%){how}")


HOUSE_LINE_CHARS = 960


def house_line(state: dict) -> str | None:
    """His own foundations with what stands on each edge and over each (build.lua get_state.structures edges /
    ceiling / inside, measured from the census): what a house of his still lacks (an open edge has no wall, a door
    frame with no door in it is an open doorway, nothing over it = no ceiling yet; live 20:29Z: 4 door-frame walls
    and 1 door). Perception only: which edge gets what is the model's call."""
    rows = [s for s in state.get("structures") or [] if isinstance(s, dict) and s.get("mine")
            and isinstance(s.get("edges"), dict)]
    if not rows:
        return None

    def what(v) -> str:
        v = str(v)
        return "next to " + v.split()[-1] if v.startswith("beside:") else v

    parts = []
    for s in sorted(rows, key=lambda r: _num(r.get("distance")) or 1e9)[:4]:
        e = s["edges"]
        ins = s.get("inside") if isinstance(s.get("inside"), dict) else {}
        d = _num(s.get("distance"))
        def inner(k) -> str:  # a door in that frame ("Door <id>") or what the frame leaves ("an open doorway, ...")
            v = str(ins.get(k) or "")
            return "" if not v else f" ({v})" if v.startswith(("a ", "an ")) else f" (with {v} in it)"
        edges = ", ".join(f"{k} {what(e.get(k, 'open'))}{inner(k)}" for k in ("N", "E", "S", "W"))
        parts.append(f"{s['id']}{f' ({d:.0f} m)' if d is not None else ''}: {edges}; over it: {s.get('ceiling') or 'nothing'}")
    return ("Your foundations, what is on each edge: " + " | ".join(parts))[:HOUSE_LINE_CHARS]


def station_state(st: dict) -> list[str]:
    """What a player sees at one station (a crafting.lua stations_nearby row): what it is making, what is in it,
    whether it has fuel, and what in it someone else left (craft will not load a station that holds that)."""
    bits = []
    if st.get("running"):
        bits.append(f"making {st.get('making') or '?'}")
    if isinstance(st.get("contents"), list) and st["contents"]:
        bits.append(", ".join(str(c)[:40] for c in st["contents"][:4]))
    if st.get("fuel") is False:
        bits.append("no fuel in it")
    if isinstance(st.get("others_left"), str) and st["others_left"]:
        bits.append(f"holds {st['others_left'][:60]} that someone else left, so I can't load it")
    return bits


def stations(state: dict) -> list[str]:
    """Crafting/processing stations nearby with what they are doing (crafting.lua stations_nearby)."""
    out = []
    for st in state.get("stations_nearby") or []:
        if not isinstance(st, dict):
            continue
        bits = [f"{st['distance']:.0f} m" if isinstance(st.get("distance"), (int, float)) else "", f"id {st.get('id')}"]
        bits += station_state(st)
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


# every carried item, most first, up to this many characters: crafting reads its inputs here (rung 3, live 16:56Z: 6
# rune stacks hid his logs and stone; 19:33Z: a 12-item cut hid the 4 Dirty Water a boil needed, so he read inventory
# first and stood 5.8 s saying nothing)
CARRY_CHARS = 900


def carrying(state: dict, names: dict[str, str]) -> str:
    """Carried items, most first; runes (thousands of spell ammo) go last in one compact group so they never hide the
    materials (live 2026-11-01 16:56Z: "Carrying: Nature Rune x2040; ... +16 more", so the model read craft_plan to
    learn whether he had 6 Ash Logs and 8 Stone before a craft)."""
    inv = state.get("inventory") or {}
    rows = sorted(((k, v) for k, v in inv.items() if v), key=lambda kv: -kv[1])
    carry = [f"{name_of_item(k, names)} x{v}" for k, v in rows if not str(k).startswith("ITEM_Rune_")]
    runes = [f"{name_of_item(k, names).removesuffix(' Rune')} {v}" for k, v in rows if str(k).startswith("ITEM_Rune_")]
    shown, used = [], 0
    for row in carry:
        if used + len(row) > CARRY_CHARS:
            break
        shown.append(row)
        used += len(row) + 2
    more = len(carry) - len(shown)
    text = "Carrying: " + "; ".join(shown) + (f"; +{more} more" if more > 0 else "") if carry else ""
    if runes:
        text += ("; " if text else "Carrying: ") + "runes " + ", ".join(runes)
    return text[:CARRY_CHARS + 240] or "Carrying: nothing"


def consumables(state: dict) -> list[str]:
    """Food and drink he carries, with where it is (only hotbar items can be used), from item data."""
    return [f"{r.get('name') or r.get('item')} x{r.get('count') or 1} ({', '.join([k, r['where'], *consumable_facts(r)])})"
            for k, r in consumable_rows(state)]


QUEST_FIELDS = ("quest", "step", "detail", "hint", "counters", "where")  # what of a quest row the brain shows


def _marker(m: dict) -> str:
    """One quest map marker (quests.lua `where`): 'Windmill Area (area 80 m across... you are inside), 75 m, at [x, y, z]'."""
    kind = m.get("kind") or "marker"
    what = f"{kind} {m['radius_m']:.0f} m radius" if kind == "area" and m.get("radius_m") else kind
    at = m.get("position") or m.get("xy")
    return (f"{m.get('name')} ({what}" + ("; you are inside it" if m.get("inside") else "") + ")"
            + (f", {m['distance_m']} m away" if m.get("distance_m") is not None else "")
            + (f" at {at}" if at else ""))


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
                 ", ".join(f"{k} {v}" for k, v in list((a.get("counters") or {}).items())[:3]),
                 ("on the map: " + "; ".join(_marker(m) for m in a["where"][:2] if isinstance(m, dict)))
                 if isinstance(a.get("where"), list) and a["where"] else ""]
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
    "power_level", "fight_odds", "quests", "map_players", "near_players", "asked_at", "weapons_known", "held_enchant",
    "containers_remembered", "my_bases", "burn_odds", "further_off",
})


def asked_at(state: dict, player: str | None, text: str | None) -> dict | None:
    """Where he stood (and the player, when in sight) when a request was asked: "here" / "by me" name that place,
    and he may walk away from it (live 2026-11-01 21:13Z: he gathered, then built 31 m from where he was asked)."""
    pos = state.get("position") if isinstance(state, dict) else None
    if not (text and isinstance(pos, (list, tuple)) and len(pos) >= 3 and all(num(v) is not None for v in pos[:3])):
        return None
    them = next((p for p in state.get("players") or [] if isinstance(p, dict) and player and p.get("name")
                 and same_player(str(p["name"]), player) and isinstance(p.get("position"), (list, tuple))), None)
    return {"position": [round(float(v), 1) for v in pos[:3]], "request": str(text)[:80], "player": player,
            "player_at": [round(float(v), 1) for v in them["position"][:3]] if them else None}


def with_asked(state: dict, asked: dict | None) -> dict:
    """The state with the open request's asked_at (rendered by asked_line), unchanged when there is none."""
    return {**state, "asked_at": asked} if asked and isinstance(state, dict) and not state.get("unavailable") else state


def bases_line(state: dict) -> str | None:
    """'Your bases (what you built): 100 m NE, roofed, 14 pieces (Spinning Wheel, Crafting Table) | ...' from the body's
    my_bases (deconstruct.lua: his placement ledger, clustered): his memory of what he built, at any distance (live
    2026-11-02 01:29Z: he walled in a new wheel 100 m from his own roofed house, which nothing in state named)."""
    bases = state.get("my_bases")
    if not isinstance(bases, list) or not bases:
        return None
    parts = []
    for b in bases[:4]:
        if not isinstance(b, dict):
            continue
        where = (f"{b['distance_m']:.0f} m {b.get('direction') or ''}".strip() if num(b.get("distance_m")) is not None
                 else "at ({:.0f}, {:.0f})".format(*b.get("centre", [0, 0])[:2]))
        st = ", ".join(str(x) for x in (b.get("stations") or [])[:5])
        parts.append(f"{where}, {'roofed' if b.get('covered') else 'no roof'}, {b.get('pieces')} piece{'' if b.get('pieces') == 1 else 's'}" +(f" ({st})" if st else ""))
    return ("Your bases (what you built): " + " | ".join(parts))[:LINE_CHARS] if parts else None


def asked_line(state: dict) -> str | None:
    """'Asked: "build ... here" at (121, 1809, -31), 31 m from where you are now; Zezima was at (...)'."""
    a = state.get("asked_at")
    pos = state.get("position")
    if not (isinstance(a, dict) and isinstance(a.get("position"), list)):
        return None
    x, y, z = a["position"][:3]
    d = math.dist(a["position"][:2], pos[:2]) if isinstance(pos, (list, tuple)) and len(pos) >= 2 else None
    who = a.get("player_at")
    return (f'Asked: "{a.get("request")}" when you stood at ({x:.0f}, {y:.0f}, {z:.0f})'
            + (f", {d:.0f} m from where you are now" if d is not None else "")
            + (f"; {a.get('player')} was at ({who[0]:.0f}, {who[1]:.0f}, {who[2]:.0f})" if isinstance(who, list) else ""))[:LINE_CHARS]


def same_player(a: str, b: str) -> bool:
    """One player name for another: equal ignoring case, or a long name cut short (the in-game character
    'luisdeburnaybast' of the account 'luisdeburnaybastos'): one a prefix of the other, the shorter >= 8 chars
    (client_mod/scripts/mapplayers.lua same_name)."""
    a, b = str(a or "").lower(), str(b or "").lower()
    if not a or not b:
        return False
    if a == b:
        return True
    if "*" in a or "*" in b:  # the game's name filter masked one ('luisdeburnayb***t' on the map, live 2026-11-01)
        m, p = (a, b) if "*" in a else (b, a)
        if "*" in p:
            return False
        pat = re.sub(r"(?:\\\*)+", ".+", re.escape(m))
        if re.fullmatch(pat, p) or (len(m.replace("*", "")) >= 8 and re.match(pat, p)):
            return True
        head = m.split("*", 1)[0]
        return 8 <= len(p) <= len(head) and head.startswith(p)
    short, long_ = sorted((a, b), key=len)
    return len(short) >= 8 and long_.startswith(short)


def map_players(state: dict, shown: Iterable[str] = ()) -> list[str]:
    """Players the census doesn't list, from the game map's markers (the compass shows them at any distance):
    'luisdeburnaybast 320 m NE (out of sight; go_to/follow go by his map marker)'. Retro 2026-11-01 root cause 3."""
    out = []
    for r in state.get("map_players") or []:
        if not isinstance(r, dict) or not r.get("name") or any(same_player(r["name"], s) for s in shown):
            continue
        d = num(r.get("distance"))
        where = " ".join(b for b in (f"{d:.0f} m" if d is not None else "", str(r.get("direction") or "")) if b)
        out.append(f"{r['name']} {where}".strip() + ("" if r.get("in_sight") else " (out of sight; go_to/follow go by his map marker)"))
    return out


SIDE_WORDS = {"in front": "in front of him", "behind": "behind him", "to the left": "to his left", "to the right": "to his right"}
NEAR_GROUPS = 5


def near_speaker(state: dict, player: str | None) -> str | None:
    """One line: what lies within ~15 m of the player who spoke, when his pawn is in sight (body get_state
    near_players: a census around HIM), so "the 2 stone in front of me" can be his stones and not the nearest to
    you. Information only (PRINCIPLES #2; retro 2026-11-01 root cause 4): the model decides what he meant."""
    if not player:
        return None
    for row in state.get("near_players") or []:
        if not (isinstance(row, dict) and same_player(row.get("player"), player)):
            continue
        r = num(row.get("radius_m")) or 15
        groups: dict[str, list[dict]] = {}
        for t in row.get("things") or []:
            if isinstance(t, dict) and t.get("name"):
                groups.setdefault(str(t["name"]), []).append(t)
        head = f"Within {r:g} m of {row['player']} (who spoke)"
        if not groups:
            return f"{head}: nothing lying there to pick up or gather."
        parts = []
        for name, ts in sorted(groups.items(), key=lambda kv: min(num(t.get("distance")) or 0 for t in kv[1]))[:NEAR_GROUPS]:
            ts.sort(key=lambda t: num(t.get("distance")) or 0)
            first, n = ts[0], sum(int(num(t.get("count")) or 1) for t in ts)
            d, mine = num(first.get("distance")), num(first.get("from_me"))
            where = ", ".join(b for b in (
                f"nearest {d:.1f} m{(' ' + SIDE_WORDS[first['side']]) if first.get('side') in SIDE_WORDS else ''}" if d is not None else "",
                f"{mine:.0f} m from you" if mine is not None else "", f"id {first['id']}" if first.get("id") else "") if b)
            parts.append(f"{n} {name} ({first.get('kind') or 'thing'}; {where})")
        more = len(groups) - NEAR_GROUPS
        return f"{head}: " + "; ".join(parts) + (f"; +{more} more kinds" if more > 0 else "")
    return None


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


@lru_cache(maxsize=64)
def ammo_facts(name: str) -> str | None:
    """'PL 2, 10-24 dmg' for an arrow or bolt from its wiki page (power, basedmg), or None."""
    try:
        from .knowledge import wiki_dir
        root = wiki_dir()
        page = ((json.loads((root / "manifest.json").read_text(encoding="utf-8")).get("pages") or {}).get(name) or {}).get("file")
        doc = json.loads((root / page).read_text(encoding="utf-8")) if page else {}
    except (OSError, ValueError):
        return None
    text = " ".join(str(x.get("text") or "") for x in doc.get("sections") or [] if x.get("heading") in (None, "Stats"))
    pl, dmg = re.search(r"power: *(\d+)", text), re.search(r"basedmg: *([\d-]+)", text)
    bits = ([f"PL {pl.group(1)}"] if pl else []) + ([f"{dmg.group(1)} dmg"] if dmg else [])
    return ", ".join(bits) or None


def weapons_line(state: dict) -> str | None:
    """'Your weapons: Stone Club (melee) ~16.8/hit, 16/s (learned) | Ash Shortbow (ranged) ~4/hit (learned), ammo slot
    EMPTY: can't shoot' from combat's weapons_known: each weapon's real damage beside the others (live 22:05Z he took
    the bow, ~4/hit with no arrows loaded, over a club doing ~14, with nothing showing either number)."""
    wk = state.get("weapons_known") if isinstance(state.get("weapons_known"), dict) else {}
    parts = []
    for name, w in wk.items():
        if not isinstance(w, dict):
            continue
        dmg = [f"~{_num(w['per_hit']):g}/hit" if _num(w.get("per_hit")) is not None else "",
               f"{_num(w['per_s']):g}/s" if _num(w.get("per_s")) is not None else ""]
        bit = f"{name} ({w.get('kind') or '?'}) " + ", ".join(d for d in dmg if d) + (f" ({w['from']})" if w.get("from") else "")
        if w.get("types"):
            bit += f", {'/'.join(str(t).rsplit('.', 1)[-1] for t in w['types'])} damage"
        if w.get("ammo_slot"):
            # which arrows are slotted and which others he carries, with the wiki's power and damage (live 2026-11-02
            # 03:47 he crafted Fang Arrows and shot his 2 Stone ones without seeing either)
            an = w.get("ammo_name")
            af = ammo_facts(an) if an else None
            bit += ((f", {w['ammo']:g} {an or ''}".rstrip() + (f" ({af})" if af else "") + " in its ammo slot")
                    if _num(w.get("ammo")) else ", ammo slot EMPTY: can't use it")
            more = [f"{_num(a.get('count')) or 0:g} {a.get('name')}" + (f" ({ammo_facts(a['name'])})" if ammo_facts(str(a.get("name"))) else "")
                    for a in (w.get("ammo_carried") or []) if isinstance(a, dict) and a.get("name")]
            if more:
                bit += "; also carried: " + ", ".join(more)
        parts.append(bit.strip())
    if not parts and "weapons_known" in state and state["weapons_known"] in ({}, []):  # an empty Lua table may come as []
        return no_weapon_line(state)
    return ("Your weapons: " + " | ".join(parts))[:LINE_CHARS] if parts else None


def no_weapon_line(state: dict) -> str:
    """'Your weapons: NONE in hand or bag (bare hands); lying loose nearby (not yours, free to take): Stone Dagger 21 m; in your graves: Ash Shortbow
    (214 m)'. Live 2026-11-02 06:05: respawned with nothing, he walked to a vent and punched a PL2 rat to death
    (his), with a dagger and staffs lying 16-21 m off and his bow in his grave, and no line said he had no weapon."""
    weapon_names = {str(e.get("name")) for e in item_stats.catalog().values() if isinstance(e, dict) and e.get("role") == "weapon"}

    def is_weapon(label: str) -> str | None:
        name = re.sub(r" x\d+$", "", str(label)).strip()
        return name if name in weapon_names else None
    ground = []
    for t in perceived(state):
        if t.kind == "item" and is_weapon(t.name):
            ground.append(f"{t.name} {t.distance:.0f} m" if isinstance(t.distance, (int, float)) else t.name)
    graves = []
    g = state.get("my_grave") if isinstance(state.get("my_grave"), dict) else None
    for c in (g or {}).get("contents") or []:
        if is_weapon(c):
            graves.append(f"{is_weapon(c)} ({g['distance']:.0f} m)" if isinstance(g.get("distance"), (int, float)) else str(is_weapon(c)))
    for gv in state.get("graves_remembered") or []:
        if isinstance(gv, dict):
            for c in gv.get("lost") or []:
                if is_weapon(c):
                    graves.append(f"{is_weapon(c)} ({gv['distance']:.0f} m)" if isinstance(gv.get("distance"), (int, float)) else str(is_weapon(c)))
    out = "Your weapons: NONE in hand or bag (bare hands)"
    if ground:
        # loose items are anyone's: "on the ground" under "Your weapons" read as his own (live 2026-11-15: 12 of 12
        # back from the grave, then "my club and spades are still lying back at the spot", fixture leftovers)
        out += "; lying loose nearby (not yours, free to take): " + ", ".join(ground[:4])
    if graves:
        out += "; in your graves: " + ", ".join(graves[:4])
    return out[:LINE_CHARS]


def load_words(state: dict) -> str | None:
    """'OVERLOADED 403/400 carry weight: walk only, no sprint or jumps' from the bag's encumbrance (skills.lua, the
    game's PlayerEncumbranceComponent). Live 2026-11-02 00:2xZ he was 3 over after a grave run and never knew it."""
    bag = state.get("bag") if isinstance(state.get("bag"), dict) else {}
    if bag.get("encumbered") is not True:
        return None
    cur, mx = _num(bag.get("weight")), _num(bag.get("max_weight"))
    amount = f" {cur:.0f}/{mx:.0f} carry weight" if cur is not None and mx is not None else ""
    return f"OVERLOADED{amount}: walk only, no sprint or jumps"


def enchant_words(state: dict) -> str | None:
    """'Fire enchant on your weapon, 212 s left' from combat's held_enchant (nil = none, so nothing is said)."""
    e = state.get("held_enchant") if isinstance(state.get("held_enchant"), dict) else None
    if not e or not e.get("effect"):
        return None
    el = str(e.get("adds") or e["effect"]).rsplit(".", 1)[-1].replace("HEED_EnchantWeapon", "")
    left = _num(e.get("left_s"))
    return f"{el} enchant on your weapon" + (f", {left:g} s left" if left is not None else "")


def gear_line(state: dict) -> str | None:
    """brain/gear_plan.py's 'Gear vs this area' as ONE line (the best option per slot), only while what he wears is
    below the enemies here: a full block was 6 lines and pushed the stations and places off the summary."""
    from . import gear_plan  # lazy: item and recipe data load on first use
    try:
        p = gear_plan.plan(state, stash=state.get("containers_remembered") or None)  # brain/stash.py
        if p.get("enemy_pl") is None or p.get("pl_now", 0) >= p["enemy_pl"]:
            return None
        ls = gear_plan.lines(p, max_opts=1, compact=True)
        whole = gear_plan.set_line(p, state)  # the whole job per style (live 2026-11-02: he stopped at one piece)
    except Exception:  # perception is best effort; never block a decision on it
        return None
    if not ls:
        return None
    # with the whole-set bill, per slot only what it doesn't cover: a weapon / off-hand, or a piece he already owns
    rest = [x.strip() for x in ls[1:] if not whole or not x.strip().startswith(("head:", "body:", "legs:"))
            or "you have one" in x]
    return (ls[0] + (f" {whole}." if whole else "") + (" Per slot: " + " | ".join(rest) if rest else ""))[:6 * LINE_CHARS]


def summary(state: dict, *, active_goal: str | None = None, tasks: list[dict] | None = None,
            places: Iterable[str] = (), looks_supported: bool = False, queued_goal: str | None = None) -> list[str]:
    """At most 10 short lines describing the companion's situation, by in-game names."""
    if not state or state.get("unavailable"):
        return [f"(game state unavailable: {state.get('unavailable') if state else 'no state'})"]
    names = item_names(state)
    things = perceived(state)
    far = [t for t in things if t.group == "further"]  # their own line: not creatures or items within the lists' reach
    things = [t for t in things if t.group != "further"]
    lines: list[str | None] = []

    # dead: the respawn comes by itself, so nothing he eats or drinks now helps (chat ladder 2026-11-02 01:17:08Z: a
    # read at the moment of death offered "Need health (dying [0%]) -> Fillet heals 20" and he ate into the respawn)
    me = ["DEAD: respawning, nothing to do until you're back"] if state.get("dead") is True else \
        [b for b in (_health(state),) if b]
    if _num(state.get("power_level")) is not None:  # his own power level (combat state_extras), beside the creatures' PL
        me.append(f"PL {_num(state.get('power_level')):g}")
    for stat, word in (("hydration", "water"), ("sustenance", "food"), ("endurance", "rest")):  # survival (client body)
        cur, mx = _num(state.get(stat)), _num(state.get(f"{stat}_max"))
        if cur is not None:
            me.append(_stat(word, 100 * cur / mx if mx else cur))
    gear = state.get("gear") if isinstance(state.get("gear"), dict) else {}
    if state.get("held"):  # the client body names it already
        me.append(f"holding {state['held']}")
    elif held := gear.get("right") or gear.get("held_right"):
        item = str(held).rsplit("/", 1)[-1].rsplit(".", 1)[-1]  # /Root/.../ITEM_X.ITEM_X -> ITEM_X
        me.append(f"holding {name_of_item(item, names)}")
    elif isinstance(state.get("held_actions"), dict) and (state["held_actions"].get("item_name") or state["held_actions"].get("item")):
        me.append(f"holding {state['held_actions'].get('item_name') or state['held_actions']['item']}")
    if ench := enchant_words(state):
        me.append(ench)
    if load := load_words(state):
        me.append(load)
    if state.get("following"):
        me.append(f"following {state['following']}")
    elif state.get("action"):
        me.append(f"doing {state['action']}")
    if state.get("sleeping"):
        me.append("asleep")
    # words first; the [n%] are for decisions (persona: never read numbers out)
    lines.append("You: " + (", ".join(me) or "ok"))
    from . import needs  # lazy: needs imports helpers from this module
    lines.extend(needs.lines(state))  # pressing needs -> the options the game offers (brain/needs.py)
    lines.extend(needs.activity_lines(state))  # current activity: spells/actions for it + rate vs best
    lines.extend(recent_life(state))

    worn = wearing(state, names)
    if worn:
        lines.append(_line("Wearing", worn))
    lines.append(carrying(state, names))
    lines.append(_line("Food/drink", consumables(state)))
    lines.append(_line("Spare gear", item_stats.describe_carried(state)))
    lines.append(weapons_line(state))
    lines.append(gear_line(state))
    lines.append(skills_line(state))
    lines.append(quests_line(state))
    lines.append(hands(state))
    lines.append(world_line(state))
    lines.append(vitals_policy(state))

    pl = [t for t in things if t.kind == "player"]
    lines.append(_line("Players", [(f"{t.name} {t.distance:.0f} m" if t.distance is not None else t.name)
                                   + (f" {height_words(t.up_m)}" if height_words(t.up_m) else "") for t in pl]
                       + map_players(state, [t.name for t in pl])))

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

    around = _group([t for t in things if t.kind not in ("player", "creature", "item") and t.group not in ("usable", "built")])
    lines.append(_line("Around", [g.label() for g in around]))
    usable = _group([t for t in things if t.group == "usable"])
    lines.append(_line("Usable", [g.label() for g in usable]))
    if far:  # chain 20261116-184351: essence rocks 41 m off, behind 20 rows of logs and stones, were in no line
        lines.append(("Further off, also in sight (nearer things filled the lists above): "
                      + "; ".join(g.label() for g in _group(far)[:FAR_SHOWN]))[:FAR_LINE_CHARS])
    built = _group([t for t in things if t.group == "built"])  # building pieces with no use: foundations, walls
    lines.append(_line("Built pieces", [g.label() for g in built]))
    lines.append(house_line(state))
    lines.append(bases_line(state))
    lines.append(asked_line(state))
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
    elif queued_goal:  # a goal he handed over that has not begun: its work is not this run's to do (agent.py)
        lines.append(f"Job queued (it starts by itself when this turn ends): {queued_goal}"[:LINE_CHARS])

    known = sorted(set(state.get("places") or []) | set(places))
    lines.append(_line("Places", known))
    lines.extend(extras_lines(state))  # what client modules add (state_extras): last, lowest priority
    available = [line for line in lines if line]
    chosen = available[:MAX_LINES]
    # Preserve a threat and active job by displacing explicitly optional context,
    # never by blindly replacing the last line (which may be the active job).
    optional = ("Places:", "Reflex policy:", "Skills ", "Quests:", "Stations:",
                "Spare gear:", "Food/drink:", "Players:", "Wearing:", "World:",
                "On the ground:", "Around:", "Usable:", "Built pieces:", "Gear vs this area:", "Further off")
    for prefix in ("Creatures", "Job:", "Job queued", "Asked:", "Your bases", "Your farm"):
        required = next((line for line in available if line.startswith(prefix)), None)
        if required and required not in chosen:
            index = next((i for i in range(len(chosen)-1, -1, -1)
                          if chosen[i].startswith(optional)), None)
            if index is not None:
                chosen[index] = required
    return chosen

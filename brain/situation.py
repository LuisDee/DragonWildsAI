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

REPO = Path(__file__).resolve().parents[1]
MAX_LINES = 10
MAX_GROUPS = 6  # per line
LINE_CHARS = 240

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

    def words(self) -> set[str]:
        return tokens(self.name) | tokens(self.kind) | {w for g in self.gives for w in tokens(g)} | \
            {w for e in self.extra for w in tokens(e)}

    def label(self) -> str:
        d = f"{self.distance:.0f} m" if isinstance(self.distance, (int, float)) else ""
        n = f"{self.name} x{self.count}" if self.count > 1 else self.name
        bits = [b for b in (d, f"id {self.id}" if self.id else "") if b]
        return f"{n} ({', '.join(bits)})" if bits else n


def _num(v) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def perceived(state: dict, looks: Iterable[dict] = ()) -> list[Thing]:
    """Everything the companion can currently perceive: get_state lists, the body's surroundings
    digest, and the things returned by look calls this turn."""
    out: list[Thing] = []
    names = item_names(state)
    for e in state.get("nearby_entities") or []:
        if isinstance(e, dict) and e.get("alive", True):
            out.append(Thing(pretty_id(e.get("kind") or e.get("id")), "creature", e.get("id"), _num(e.get("distance")),
                             actions=["attack"], hostile=e.get("hostile"), extra={str(e.get("kind") or "")}))
    for g in state.get("nearby_items") or []:
        if isinstance(g, dict):
            item = str(g.get("item") or g.get("id") or "")
            out.append(Thing(g.get("name") or name_of_item(item, names), "item", g.get("id"), _num(g.get("distance")),
                             count=int(g.get("count") or 1), gives=[g.get("name") or name_of_item(item, names)],
                             actions=["pickup"], extra={item}))
    for p in state.get("players") or []:
        if isinstance(p, dict) and p.get("name"):
            out.append(Thing(str(p["name"]), "player", str(p["name"]), _num(p.get("distance")), actions=["follow", "give"]))
    for r in state.get("nearby_resources") or []:  # the mock's trees and rocks
        if isinstance(r, dict):
            res = str(r.get("resource") or "")
            kind = {"log": "tree", "stone": "rock"}.get(res, "resource")
            out.append(Thing(f"{kind} ({res})", kind, r.get("id"), _num(r.get("distance")), gives=[res],
                             actions=["gather"], extra={res}))
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
                acts = [a.get("a") if isinstance(a, dict) else str(a) for a in t.get("actions") or []]
                out.append(Thing(str(t["name"]), str(t.get("kind") or "thing"), t.get("id"), _num(t.get("distance_m")),
                                 count=int(t.get("count") or 1), gives=[str(x) for x in t.get("gives") or []],
                                 actions=[a for a in acts if a], extra={str(t.get("class") or "")}))
    return out


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
            groups[t.name] = Thing(t.name, t.kind, t.id, t.distance, t.count, list(t.gives), list(t.actions), t.hostile)
        else:
            g.count += t.count
    return list(groups.values())


def _line(label: str, items: list[str]) -> str | None:
    if not items:
        return None
    more = len(items) - MAX_GROUPS
    text = f"{label}: " + "; ".join(items[:MAX_GROUPS]) + (f"; +{more} more" if more > 0 else "")
    return text[:LINE_CHARS]


def _health(state: dict) -> str | None:
    hp, mx = _num(state.get("health")), _num(state.get("max_health"))
    if hp is None:
        return None
    if mx and mx > 0:
        return f"HP {round(100 * hp / mx)}%"
    return f"HP {round(100 * hp)}%" if hp <= 1 else f"HP {hp:g}"


def summary(state: dict, *, active_goal: str | None = None, tasks: list[dict] | None = None,
            places: Iterable[str] = (), looks_supported: bool = False) -> list[str]:
    """At most 10 short lines describing the companion's situation, by in-game names."""
    if not state or state.get("unavailable"):
        return [f"(game state unavailable: {state.get('unavailable') if state else 'no state'})"]
    names = item_names(state)
    things = perceived(state)
    lines: list[str | None] = []

    me = [b for b in (_health(state),) if b]
    held = (state.get("gear") or {}).get("right") if isinstance(state.get("gear"), dict) else None
    if held:
        item = str(held).rsplit("/", 1)[-1].rsplit(".", 1)[-1]  # /Root/.../ITEM_X.ITEM_X -> ITEM_X
        me.append(f"holding {name_of_item(item, names)}")
    if state.get("following"):
        me.append(f"following {state['following']}")
    elif state.get("action"):
        me.append(f"doing {state['action']}")
    if state.get("sleeping"):
        me.append("asleep")
    lines.append("You: " + (", ".join(me) or "ok"))

    inv = state.get("inventory") or {}
    carry = [f"{name_of_item(k, names)} x{v}" for k, v in sorted(inv.items(), key=lambda kv: -kv[1]) if v]
    lines.append(_line("Carrying", carry) or "Carrying: nothing")

    pl = [t for t in things if t.kind == "player"]
    lines.append(_line("Players", [f"{t.name} {t.distance:.0f} m" if t.distance is not None else t.name for t in pl]))

    creatures = _group([t for t in things if t.kind == "creature"])
    lines.append(_line("Creatures", [("hostile " if g.hostile else "") + g.label() for g in creatures]))

    ground = _group([t for t in things if t.kind == "item"])
    lines.append(_line("On the ground", [g.label() for g in ground]))

    around = _group([t for t in things if t.kind not in ("player", "creature", "item")])
    lines.append(_line("Around", [g.label() for g in around]))
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
    return [line for line in lines if line][:MAX_LINES]

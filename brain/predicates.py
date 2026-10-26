"""Success predicates: a small JSON format for "is this done?", checked ONLY against fresh game state.

Shared by the task board (brain/director.py: each step's and task's success test) and the Eval
benchmark's success predicates (docs/design/director.md section 2.2; docs/design/eval-benchmark.md).
PRINCIPLES #5: a step is done when the game state confirms it; the model's claim never is. Pure functions,
no bridge calls, no model calls.

Format: a predicate is a dict with exactly ONE key, a leaf or a combinator.

  leaves (args)                                                         reads
  have        {item, at_least=1}                                        state.inventory
  gained      {item, at_least=1}         since ctx.baseline             state.inventory, baseline.inventory
  tally       {item, at_least=1}         ctx.tallies (verified gains summed over a task's steps / trips)
  skill       {name, at_least}                                          state.skills [{skill, level, xp}]
  skill_gain  {name, levels=1}           since ctx.baseline             state.skills, baseline.skills
  equipped    {item}                                                    state.gear (slot -> item id)
  gear_better {category | slot, stat, where=equipped|carried, than="start"|number, op=">"|">="|"<"|"<="}
                                         best item's catalog stat (brain/item_stats.stats); "start" = the
                                         best he had HELD OR CARRIED at ctx.baseline (review H2: switching to
                                         an item he already had is never better)   state.gear (+ inventory)
  bag         {used_pct_at_least | free_at_least}                       state.bag {used, capacity}
  vital       {stat, below_pct | at_least_pct}   a flat state stat vs its max: <stat> and max_<stat> or <stat>_max
                                         (health/max_health, hydration/hydration_max, stamina/max_stamina, ...)
  near        {place | player | position | thing, within_m=5}           state.position, players, nearby_*;
                                                                        ctx.places for place names
  lost        {item, at_least=1}         left the inventory since ctx.baseline (with on_ground: a delivery)
  on_ground   {item, at_least=1, player | place | position (default: me), within_m=5}   state.nearby_items;
                                         with player, stacks flying to him (magnet_target) count too
  elapsed     {seconds}                  ctx.now - ctx.baseline.t
  station     {station, running?}        a station in sight by type, name or id: state.stations_nearby
  moved       {min_m}                    own position vs ctx.baseline.position
  killed      {kind | kind_id | target_id, at_least=1}   combat_end episodes with outcome=killed since the baseline
                                         (ctx.episodes); kind matches whole words of the target's name
  quest       {name, stage? | completed?}                               state.quests [{name, stage, completed}]
  combinators: all [..], any [..], not {..}   (three-valued: see below)
  more leaves: ``register_leaf(name, evaluate_fn, validate_fn=None)`` (the Eval benchmark's spell_effect,
  station_used, hit_rate live in evals/bench/leaves.py); an unknown leaf is a validation error.

ctx (a plain dict, every key optional): baseline (``snapshot(state)`` when the step/case started),
tallies {item id: verified gain}, places {name: [x, y, z] | {position}}, episodes [activity events since the
baseline: combat_end, picked_up, consumed, ...] ("events" is accepted as an alias), results [tool calls since
the baseline: {t, tool, args, ok, reason, data}]. Leaves read only body-reported data, never model words.

Items are given by item id or in-game name; ``validate`` resolves names to ids from the game catalogs
(data/items_*.json, data/recipes_*.json) and returns candidates when it can't. One in-game name may
cover several ids (a quest copy of a fish): counts are summed over all of them.

Result: ``Result(passed, detail, progress, missing, measures)``.
  passed  True | False | None. None = "can't be checked from what the body reports" (e.g. no quest
          state, no baseline for gained): never treated as done; ``missing`` names what is absent
          (a perception gap, docs/design/director.md section 2.7).
  detail  words for the model and the player: "Copper Ore 4/9; Tin Ore 9/9".
  progress 0..1 (numeric leaves: value/target; all = mean; any = max): no-progress detection.
  measures {key: raw amount} (counts, XP, kills; never distances): grew(before, after) says whether the
          work moved at all between two checks (XP grows long before a level does; review H8).
Combinators use Kleene logic: all = False if any False, True if all True, else None; any = True if any
True, False if all False, else None; not None = None.

No item, skill, creature or place names in this file: everything comes from data and state.
"""
from __future__ import annotations

import difflib
import json
import math
import re
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Any, Callable

from . import item_stats, paths
from .situation import tokens

COMBINATORS = ("all", "any", "not")
STATS = ("power_level", "tool_tier", "weight", "damage_multiplier", "max_durability")
OPS: dict[str, Callable[[float, float], bool]] = {
    ">": lambda a, b: a > b, ">=": lambda a, b: a >= b, "<": lambda a, b: a < b, "<=": lambda a, b: a <= b}
DEFAULT_NEAR_M = 5.0
# fields a predicate may report missing that are board bookkeeping, not body perception (capability_gaps.py and
# director.py read this; Director agent 2026-10-26)
BOOKKEEPING_FIELDS = ("baseline", "clock", "tallies", "stored")

# One line per leaf, for model prompts (the Director, eval authors): the format in the model's words.
SCHEMA_DOC = """Success predicates (JSON, one key per object; checked by code on fresh game state):
- {"have": {"item": <name or id>, "at_least": n}}       carried now
- {"gained": {"item": ..., "at_least": n}}               gained since this step started
- {"lost": {"item": ..., "at_least": n}}                 left your inventory since this step started
  (gained and lost of the SAME item in one "all" can never both hold: they read one net delta. Use tally + on_ground)
- {"on_ground": {"item": ..., "at_least": n, "player"|"place"|"position": ..., "within_m": m}}  lying near there now
- {"tally": {"item": ..., "at_least": n}}                verified total gained over this task (all trips)
- {"skill": {"name": <skill>, "at_least": level}} / {"skill_gain": {"name": ..., "levels": n}} (or "xp": n instead
   of levels: XP gained since this step started)
- {"equipped": {"item": ...}}                            worn, or held IN HAND right now (tools flicker: see gear_better)
- {"gear_better": {"category" or "slot": ..., "stat": power_level|tool_tier|damage_multiplier|max_durability|weight,
   "where": "equipped"|"carried", "than": "start" or a number, "op": ">"}}   best matching item's catalog stat vs
   the best you had (held or carried) when the step started; for tools and weapons use "where": "carried"
- {"bag": {"used_pct_at_least": pct}} or {"bag": {"free_at_least": slots}}   bag SLOTS in use (a partial stack
   still takes more; a gather that answers inventory_full is the real "full")
- {"station": {"station": <type, name or id>, "running": true|false}}       a station in sight (and its state)
- {"structure": {"name": <piece words or id>, "at_least": n, "new": true, "within_m": m}}   building pieces
   near you (new = placed since this step started)
- {"stored": {"item": ..., "at_least": n, "container": <id or name>, "trips_at_least": k}}   put into a
   container by your own verified store actions (in a step's test: by that step; in the job's: the whole job,
   all trips; k = separate trips that stored some)
- {"elapsed": {"seconds": s}}                            time since this step started
- {"vital": {"stat": "health"|"hydration"|"sustenance"|"endurance"|"stamina", "below_pct": p}} (or "at_least_pct")
- {"near": {"place"|"player"|"thing": name or id, or "position": [x,y,z], "within_m": m}}
- {"moved": {"min_m": m}}                                moved at least m from where this step started
- {"killed": {"kind": <creature>, "at_least": n}}        kills since this step started
- {"quest": {"name": ..., "completed": true}}            (not checkable yet: the body reports no quest state)
- {"all": [...]}, {"any": [...]}, {"not": {...}}
A test that can't be checked from what the body reports evaluates to null and never counts as done; "any" is
still true when one branch is true. Choose a test that measures the work: one already true now is trivial."""


class PredicateError(ValueError):
    """An invalid predicate; ``candidates`` lists item names it might have meant."""

    def __init__(self, message: str, candidates: list[str] | None = None):
        super().__init__(message)
        self.candidates = candidates or []


@dataclass
class Result:
    passed: bool | None
    detail: str
    progress: float = 0.0
    missing: list[str] = field(default_factory=list)
    # Raw monotonic amounts behind the result ({"have:<id>": 4, "xp:mining": 1200}): a no-progress check
    # compares these between runs ("did anything grow?"), which a level ratio or a jittery distance can't.
    measures: dict[str, float] = field(default_factory=dict)

    def to_dict(self) -> dict:
        return {"passed": self.passed, "detail": self.detail, "progress": round(self.progress, 3),
                "missing": list(self.missing), "measures": dict(self.measures)}


def grew(before: dict[str, float] | None, after: dict[str, float] | None, eps: float = 1e-9) -> bool:
    """Did any measure increase between two results (a new key counts when it is above zero)?"""
    before, after = before or {}, after or {}
    return any(v > before.get(k, 0.0) + eps for k, v in after.items())


# ------------------------------------------------------------------------------ item names (game data)


@lru_cache(maxsize=4)
def _name_index(data_dir: str | None = None) -> tuple[dict[str, tuple[str, ...]], dict[str, str]]:
    """(lower-case name -> item ids, item id -> name) from the newest items and recipes catalogs."""
    root = Path(data_dir) if data_dir else paths.REPO_ROOT / "data"
    by_name: dict[str, set[str]] = {}
    name_of: dict[str, str] = {}
    for prefix in ("items", "recipes"):
        files = sorted(root.glob(f"{prefix}_*.json"))
        if not files:
            continue
        try:
            items = json.loads(files[-1].read_text(encoding="utf-8")).get("items") or {}
        except (OSError, ValueError):
            continue
        for iid, rec in items.items():
            name = (rec or {}).get("name")
            if not isinstance(name, str) or not name or name.startswith("<"):
                continue
            name_of.setdefault(iid, name)
            by_name.setdefault(name.strip().lower(), set()).add(iid)
    return {k: tuple(sorted(v)) for k, v in by_name.items()}, name_of


class Items:
    """Item id/name resolution over the game catalogs (or a given {id: name} map, for tests)."""

    def __init__(self, names: dict[str, str] | None = None, data_dir: str | None = None):
        if names is not None:
            self.name_of = dict(names)
            idx: dict[str, set[str]] = {}
            for iid, n in names.items():
                idx.setdefault(n.strip().lower(), set()).add(iid)
            self.by_name = {k: tuple(sorted(v)) for k, v in idx.items()}
        else:
            self.by_name, self.name_of = _name_index(data_dir)

    def resolve(self, item: Any) -> tuple[str, ...]:
        """The item ids an id or in-game name stands for; PredicateError with candidates if none."""
        if isinstance(item, (list, tuple)) and item and all(isinstance(i, str) for i in item):
            return tuple(item)
        if not isinstance(item, str) or not item.strip():
            raise PredicateError("item must be an item name or id")
        s = item.strip()
        if s in self.name_of:
            return (s,)
        ids = self.by_name.get(s.lower())
        if ids:
            return ids
        if not self.name_of:  # no catalog at all: take it as an id (the state decides)
            return (s,)
        close = difflib.get_close_matches(s.lower(), list(self.by_name), n=6, cutoff=0.6)
        raise PredicateError(f"unknown item {item!r}", [self.name_of[self.by_name[c][0]] for c in close])

    def name(self, ids: tuple[str, ...] | str) -> str:
        first = ids if isinstance(ids, str) else ids[0]
        return self.name_of.get(first, first)


# ------------------------------------------------------------------------------ validation


def _num(v: Any, what: str, minimum: float | None = None) -> float:
    if isinstance(v, bool) or not isinstance(v, (int, float)) or (isinstance(v, float) and math.isnan(v)):
        raise PredicateError(f"{what} must be a number")
    if minimum is not None and v < minimum:
        raise PredicateError(f"{what} must be >= {minimum:g}")
    return v


def _str(v: Any, what: str) -> str:
    if not isinstance(v, str) or not v.strip():
        raise PredicateError(f"{what} must be a non-empty string")
    return v.strip()


def _one(p: Any) -> tuple[str, Any]:
    names = ", ".join([*LEAVES, *COMBINATORS])
    if not isinstance(p, dict) or len(p) != 1:
        raise PredicateError("a predicate is an object with exactly one key: " + names)
    (k, v), = p.items()
    if k not in LEAVES and k not in COMBINATORS:
        raise PredicateError(f"unknown predicate {k!r}; use one of: " + names)
    return k, v


def validate(p: Any, items: Items | None = None, depth: int = 0) -> dict:
    """A normalised copy (item names -> ``ids``, defaults filled), or PredicateError with the reason."""
    if depth > 8:
        raise PredicateError("predicate nested too deeply")
    k, v = _one(p)
    if k in ("all", "any"):
        if not isinstance(v, list) or not v:
            raise PredicateError(f"{k} needs a non-empty list of predicates")
        return {k: [validate(x, items, depth + 1) for x in v]}
    if k == "not":
        return {k: validate(v, items, depth + 1)}
    if not isinstance(v, dict):
        raise PredicateError(f"{k} needs an object of arguments")
    leaf = LEAVES[k]
    a = dict(v)
    if leaf.validate is not None:
        a = leaf.validate(a, items or Items())
    return {k: a}


def net_conflicts(p: Any) -> list[str]:
    """Items that one 'all' tests both as gained and as lost (unsatisfiable: both read one net delta; Director live
    smoke 2026-10-26, "chop 5 logs then drop them"). Shared by the Director's Validator and the benchmark lint."""
    if not isinstance(p, dict) or len(p) != 1:
        return []
    k, v = next(iter(p.items()))
    out: list[str] = []
    if k in ("all", "any") and isinstance(v, list):
        if k == "all":
            seen: dict[str, dict[str, str]] = {"gained": {}, "lost": {}}
            for sub in v:
                if isinstance(sub, dict) and len(sub) == 1 and next(iter(sub)) in seen:
                    kk, a = next(iter(sub.items()))
                    if isinstance(a, dict):
                        for i in (a.get("ids") or [a.get("item")]):
                            seen[kk][str(i)] = str(a.get("item"))
            out += [seen["gained"][i] for i in seen["gained"] if i in seen["lost"]]
        for sub in v:
            out += net_conflicts(sub)
    elif k == "not":
        out += net_conflicts(v)
    return list(dict.fromkeys(out))


def errors(p: Any, items: Items | None = None) -> list[dict]:
    """Every problem in a predicate, as [{path, error, candidates}] (empty = valid): for generators that
    send all problems back to the model in one repair round."""
    out: list[dict] = []

    def walk(node: Any, path: str) -> None:
        try:
            k, v = _one(node)
        except PredicateError as exc:
            out.append({"path": path, "error": str(exc), "candidates": exc.candidates})
            return
        if k in ("all", "any") and isinstance(v, list) and v:
            for i, sub in enumerate(v):
                walk(sub, f"{path}.{k}[{i}]")
            return
        if k == "not":
            walk(v, f"{path}.not")
            return
        try:
            validate(node, items)
        except PredicateError as exc:
            out.append({"path": f"{path}.{k}", "error": str(exc), "candidates": exc.candidates})

    walk(p, "$")
    return out


def _validate_builtin(k: str, a: dict, items: Items) -> dict:
    if k in ("have", "gained", "lost", "tally", "equipped", "on_ground"):
        a["ids"] = list(items.resolve(a.get("ids") or a.get("item")))
        a["item"] = items.name(tuple(a["ids"]))
        if k != "equipped":
            a["at_least"] = _num(a.get("at_least", 1), f"{k}.at_least", 1)
        if k == "on_ground":
            if sum(a.get(x) is not None for x in ("place", "player", "position")) > 1:
                raise PredicateError("on_ground takes at most one of place, player, position")
            a["within_m"] = _num(a.get("within_m", DEFAULT_NEAR_M), "on_ground.within_m", 0)
    elif k == "skill":
        a["name"] = _str(a.get("name"), "skill.name")
        a["at_least"] = _num(a.get("at_least"), "skill.at_least", 1)
    elif k == "skill_gain":
        a["name"] = _str(a.get("name"), "skill_gain.name")
        if a.get("xp") is not None:
            a["xp"] = _num(a["xp"], "skill_gain.xp", 1)
        else:
            a["levels"] = _num(a.get("levels", 1), "skill_gain.levels", 1)
    elif k == "gear_better":
        if not (a.get("category") or a.get("slot")):
            raise PredicateError("gear_better needs category or slot")
        for key in ("category", "slot"):
            if a.get(key) is not None:
                a[key] = _str(a[key], f"gear_better.{key}").lower()
        if a.get("stat") not in STATS:
            raise PredicateError(f"gear_better.stat must be one of {', '.join(STATS)}")
        a["where"] = a.get("where", "equipped")
        if a["where"] not in ("equipped", "carried"):
            raise PredicateError("gear_better.where must be equipped or carried")
        a["than"] = a.get("than", "start")
        if a["than"] != "start":
            _num(a["than"], "gear_better.than")
        a["op"] = a.get("op", ">")
        if a["op"] not in OPS:
            raise PredicateError(f"gear_better.op must be one of {', '.join(OPS)}")
    elif k == "bag":
        if ("used_pct_at_least" in a) == ("free_at_least" in a):
            raise PredicateError("bag needs exactly one of used_pct_at_least, free_at_least")
        if "used_pct_at_least" in a:
            _num(a["used_pct_at_least"], "bag.used_pct_at_least", 0)
        else:
            _num(a["free_at_least"], "bag.free_at_least", 0)
    elif k == "vital":
        if not isinstance(a.get("stat"), str) or not re.fullmatch(r"[a-z][a-z_]*", a["stat"]):
            raise PredicateError("vital.stat must be a state field name, e.g. health")
        if ("below_pct" in a) == ("at_least_pct" in a):
            raise PredicateError("vital needs exactly one of below_pct, at_least_pct")
        _num(a.get("below_pct", a.get("at_least_pct")), "vital percentage", 0)
    elif k == "near":
        keys = [x for x in ("place", "player", "position", "thing") if a.get(x) is not None]
        if len(keys) != 1:
            raise PredicateError("near needs exactly one of place, player, position, thing")
        if keys[0] == "position":
            pos = a["position"]
            if not (isinstance(pos, list) and len(pos) in (2, 3) and all(isinstance(c, (int, float)) for c in pos)):
                raise PredicateError("near.position must be [x, y, z]")
        else:
            a[keys[0]] = _str(a[keys[0]], f"near.{keys[0]}")
        a["within_m"] = _num(a.get("within_m", DEFAULT_NEAR_M), "near.within_m", 0)
    elif k == "moved":
        a["min_m"] = _num(a.get("min_m"), "moved.min_m", 0)
    elif k == "elapsed":
        a["seconds"] = _num(a.get("seconds"), "elapsed.seconds", 0)
    elif k == "structure":
        a["name"] = _str(a.get("name"), "structure.name")
        a["at_least"] = _num(a.get("at_least", 1), "structure.at_least", 1)
        if "new" in a and not isinstance(a["new"], bool):
            raise PredicateError("structure.new must be true or false")
        if a.get("within_m") is not None:
            a["within_m"] = _num(a["within_m"], "structure.within_m", 0)
    elif k == "stored":
        a["ids"] = list(items.resolve(a.get("ids") or a.get("item")))
        a["item"] = items.name(tuple(a["ids"]))
        a["at_least"] = _num(a.get("at_least", 1), "stored.at_least", 1)
        if a.get("trips_at_least") is not None:
            a["trips_at_least"] = _num(a["trips_at_least"], "stored.trips_at_least", 1)
        if a.get("container") is not None:
            a["container"] = _str(a["container"], "stored.container")
    elif k == "station":
        a["station"] = _str(a.get("station"), "station.station")
        if "running" in a and not isinstance(a["running"], bool):
            raise PredicateError("station.running must be true or false")
    elif k == "killed":
        ids = [x for x in ("kind_id", "target_id") if a.get(x) is not None]
        if len(ids) > 1:
            raise PredicateError("killed takes at most one of kind_id, target_id")
        for x in ids:
            a[x] = _str(str(a[x]), f"killed.{x}")
        if ids and a.get("kind") is None:
            a["kind"] = a[ids[0]]  # a label for details
        a["kind"] = _str(a.get("kind"), "killed.kind (or kind_id / target_id)")
        a["at_least"] = _num(a.get("at_least", 1), "killed.at_least", 1)
    elif k == "quest":
        a["name"] = _str(a.get("name"), "quest.name")
        if a.get("stage") is None and a.get("completed") is None:
            a["completed"] = True
    return a


def leaves(p: dict) -> list[tuple[str, dict]]:
    """Every (leaf, args) in a predicate, for callers that want to inspect what it reads."""
    k, v = _one(p)
    if k in ("all", "any"):
        return [x for sub in v for x in leaves(sub)]
    if k == "not":
        return leaves(v)
    return [(k, v)]


# ------------------------------------------------------------------------------ state readers


def _count(inv: Any, ids: list[str] | tuple[str, ...]) -> int:
    if not isinstance(inv, dict):
        return 0
    return sum(int(inv.get(i) or 0) for i in ids)


def _skill_key(name: Any) -> str:
    """'SKILL_Mining' / 'Mining' / 'mining' -> 'mining' (spelling only, no skill list)."""
    s = re.sub(r"[^a-z0-9]", "", str(name or "").lower())
    return s[5:] if s.startswith("skill") and len(s) > 5 else s


def _skill_rows(state: dict | None) -> dict[str, tuple[float, float | None]] | None:
    """skill key -> (level, xp or None) from state.skills [{skill, level, xp}]."""
    rows = state.get("skills") if isinstance(state, dict) else None
    if not isinstance(rows, list):
        return None
    out = {}
    for r in rows:
        if isinstance(r, dict) and isinstance(r.get("level"), (int, float)):
            xp = r.get("xp")
            out[_skill_key(r.get("skill") or r.get("name"))] = (
                float(r["level"]), float(xp) if isinstance(xp, (int, float)) and not isinstance(xp, bool) else None)
    return out


def _skills(state: dict | None) -> dict[str, float] | None:
    rows = _skill_rows(state)
    return None if rows is None else {k: lvl for k, (lvl, _) in rows.items()}


def _xp_measure(key: str, row: tuple[float, float | None]) -> dict[str, float]:
    """XP when the body reports it (a level takes many runs; XP grows with every swing), else the level."""
    return {f"xp:{key}": row[1]} if row[1] is not None else {f"level:{key}": row[0]}


def _gear_items(state: dict) -> list[str]:
    gear = state.get("gear")
    return [v for v in (gear.values() if isinstance(gear, dict) else []) if isinstance(v, str) and v]


def _held_or_carried(state: dict) -> set[str]:
    inv = state.get("inventory")
    ids = set(_gear_items(state))
    ids |= {i for i, n in (inv.items() if isinstance(inv, dict) else []) if (n or 0) > 0}
    ids |= {r.get("item") for r in state.get("inventory_items") or [] if isinstance(r, dict) and r.get("item")}
    return ids


def _best(state: dict, a: dict, cat: dict | None, where: str | None = None) -> tuple[float | None, str | None]:
    """(best stat value, item id) among matching items he has (equipped, or also carried)."""
    pool = list(_gear_items(state))
    if (where or a["where"]) == "carried":
        inv = state.get("inventory")
        pool += [i for i, n in (inv.items() if isinstance(inv, dict) else []) if (n or 0) > 0]
        pool += [r.get("item") for r in state.get("inventory_items") or [] if isinstance(r, dict) and r.get("item")]
    best: tuple[float | None, str | None] = (None, None)
    lower = a["op"] in ("<", "<=")
    for iid in dict.fromkeys(pool):
        st = item_stats.stats(iid, cat)
        if not st:
            continue
        if a.get("category") and str((cat or item_stats.catalog()).get(iid, {}).get("category") or "").lower() != a["category"]:
            continue
        if a.get("slot") and item_stats._slot_key(st.get("slot")) != item_stats._slot_key(a["slot"]):
            continue
        val = st.get(a["stat"])
        if isinstance(val, (int, float)) and (best[0] is None or (val < best[0] if lower else val > best[0])):
            best = (float(val), iid)
    return best


from .geom import dist  # noqa: E402 (re-exported: the one distance helper lives in brain/geom.py)

_dist = dist


def _place_pos(places: dict, name: str) -> Any:
    rec = places.get(name) or places.get(name.strip().lower())
    return rec.get("position") if isinstance(rec, dict) else rec


def _event_fields(e: Any) -> dict:
    if hasattr(e, "model_dump"):
        e = e.model_dump()
    return e if isinstance(e, dict) else {}


# ------------------------------------------------------------------------------ evaluation


def evaluate(p: dict, state: dict, ctx: dict | None = None,
             cat: dict | None = None) -> Result:
    """Check a VALIDATED predicate against fresh state.

    ctx (all optional): baseline (a get_state snapshot from when the step started), tallies {item id: n},
    places {name: [x, y, z] | {position}}, episodes [activity dicts since the baseline], results [tool calls]."""
    ctx = ctx or {}
    k, a = _one(p)
    if k in ("all", "any"):
        subs = [evaluate(x, state, ctx, cat) for x in a]
        vals = [s.passed for s in subs]
        if k == "all":
            passed = False if False in vals else (True if all(v is True for v in vals) else None)
            prog = sum(s.progress for s in subs) / len(subs)
        else:
            passed = True if True in vals else (False if all(v is False for v in vals) else None)
            prog = max(s.progress for s in subs)
        sep = "; " if k == "all" else " | "
        meas = {mk: mv for sub in subs for mk, mv in sub.measures.items()}
        return Result(passed, sep.join(s.detail for s in subs), prog, sorted({m for s in subs for m in s.missing}),
                      meas)
    if k == "not":
        s = evaluate(a, state, ctx, cat)
        return Result(None if s.passed is None else not s.passed, f"not ({s.detail})",
                      1.0 if s.passed is False else 0.0, s.missing)
    return LEAVES[k].evaluate(a, state or {}, ctx, cat)


def _ratio(have: float, want: float) -> float:
    return max(0.0, min(1.0, have / want)) if want > 0 else 1.0


def _have(a, state, ctx, cat):
    if not isinstance(state.get("inventory"), dict):
        return Result(None, f"{a['item']}: inventory unknown", 0.0, ["inventory"])
    n = _count(state["inventory"], a["ids"])
    return Result(n >= a["at_least"], f"{a['item']} {n}/{a['at_least']:g}", _ratio(n, a["at_least"]),
                  measures={f"have:{a['ids'][0]}": float(n)})


def _gained(a, state, ctx, cat):
    base = ctx.get("baseline")
    if not isinstance(base, dict) or not isinstance(base.get("inventory"), dict):
        return Result(None, f"{a['item']}: no baseline to count from", 0.0, ["baseline"])
    if not isinstance(state.get("inventory"), dict):
        return Result(None, f"{a['item']}: inventory unknown", 0.0, ["inventory"])
    n = _count(state["inventory"], a["ids"]) - _count(base["inventory"], a["ids"])
    return Result(n >= a["at_least"], f"{a['item']} +{max(n, 0)}/{a['at_least']:g}", _ratio(n, a["at_least"]),
                  measures={f"gained:{a['ids'][0]}": float(n)})


def _lost(a, state, ctx, cat):
    base = ctx.get("baseline")
    if not isinstance(base, dict) or not isinstance(base.get("inventory"), dict):
        return Result(None, f"{a['item']}: no baseline to count from", 0.0, ["baseline"])
    if not isinstance(state.get("inventory"), dict):
        return Result(None, f"{a['item']}: inventory unknown", 0.0, ["inventory"])
    n = _count(base["inventory"], a["ids"]) - _count(state["inventory"], a["ids"])
    return Result(n >= a["at_least"], f"{a['item']} -{max(n, 0)}/{a['at_least']:g} left the inventory",
                  _ratio(n, a["at_least"]), measures={f"lost:{a['ids'][0]}": float(n)})


def _tally(a, state, ctx, cat):
    t = ctx.get("tallies")
    if not isinstance(t, dict):
        return Result(None, f"{a['item']}: no tally kept", 0.0, ["tallies"])
    n = sum(float(t.get(i) or 0) for i in a["ids"])
    return Result(n >= a["at_least"], f"{a['item']} total {n:g}/{a['at_least']:g}", _ratio(n, a["at_least"]),
                  measures={f"tally:{a['ids'][0]}": n})


def _skill(a, state, ctx, cat):
    sk = _skills(state)
    if sk is None:
        return Result(None, f"{a['name']}: skills unknown", 0.0, ["skills"])
    key = _skill_key(a["name"])
    lvl = sk.get(key)
    if lvl is None:
        return Result(None, f"no skill called {a['name']} (have: {', '.join(sorted(sk)) or 'none'})", 0.0,
                      [f"skill:{a['name']}"])
    row = _skill_rows(state)[key]
    xp = f", {row[1]:g} xp" if row[1] is not None else ""
    return Result(lvl >= a["at_least"], f"{a['name']} {lvl:g}/{a['at_least']:g}{xp}", _ratio(lvl, a["at_least"]),
                  measures=_xp_measure(key, row))


def _skill_gain(a, state, ctx, cat):
    base = ctx.get("baseline")
    now, then = _skills(state), _skills(base) if isinstance(base, dict) else None
    if now is None:
        return Result(None, f"{a['name']}: skills unknown", 0.0, ["skills"])
    if then is None:
        return Result(None, f"{a['name']}: no baseline to count from", 0.0, ["baseline"])
    key = _skill_key(a["name"])
    if key not in now or key not in then:
        return Result(None, f"no skill called {a['name']}", 0.0, [f"skill:{a['name']}"])
    d = now[key] - then[key]
    row, row0 = _skill_rows(state)[key], _skill_rows(base)[key]
    xp = f", +{row[1] - row0[1]:g} xp" if row[1] is not None and row0[1] is not None else ""
    if a.get("xp") is not None:  # an XP amount instead of levels (a level can take hours)
        if row[1] is None or row0[1] is None:
            return Result(None, f"{a['name']}: the body reports no xp", 0.0, [f"skills.xp:{a['name']}"])
        dx = row[1] - row0[1]
        return Result(dx >= a["xp"], f"{a['name']} +{dx:g}/{a['xp']:g} xp", _ratio(dx, a["xp"]),
                      measures=_xp_measure(key, row))
    return Result(d >= a["levels"], f"{a['name']} {then[key]:g} -> {now[key]:g} (+{d:g}/{a['levels']:g}{xp})",
                  _ratio(d, a["levels"]), measures=_xp_measure(key, row))


def _equipped(a, state, ctx, cat):
    if not isinstance(state.get("gear"), dict):
        return Result(None, f"{a['item']}: gear unknown", 0.0, ["gear"])
    on = any(i in a["ids"] for i in _gear_items(state))
    return Result(on, f"{a['item']} {'equipped' if on else 'not equipped'}", 1.0 if on else 0.0)


def _gear_better(a, state, ctx, cat):
    what = a.get("category") or a.get("slot")
    if not isinstance(state.get("gear"), dict):
        return Result(None, f"{what}: gear unknown", 0.0, ["gear"])
    now, now_id = _best(state, a, cat)
    if a["than"] == "start":
        # Review H2: the reference is ALWAYS the best he had, held OR carried, so taking out a pickaxe he
        # already carried (e.g. holding a sword at the start) is never "better".
        base = ctx.get("baseline")
        if not isinstance(base, dict) or not isinstance(base.get("inventory"), dict):
            return Result(None, f"{what}: no baseline inventory to compare with", 0.0, ["baseline"])
        ref, ref_id = _best(base, a, cat, where="carried")
    else:
        ref, ref_id = float(a["than"]), None
    def label(v, iid):
        if v is None:
            return "none"
        name = (item_stats.stats(iid, cat) or {}).get("name") if iid else None
        return f"{name} {v:g}" if name else f"{v:g}"
    detail = f"best {what} {a['stat']} ({a['where']}): {label(now, now_id)} vs {label(ref, ref_id)}"
    if now is None:
        return Result(False, detail, 0.0)
    if ref is None:  # nothing matching at the start: a NEW matching item beats nothing
        new = a["than"] != "start" or now_id not in _held_or_carried(ctx["baseline"])
        return Result(new, detail, 1.0 if new else 0.0)
    ok = OPS[a["op"]](now, ref)
    return Result(ok, detail, 1.0 if ok else 0.0)


def _bag(a, state, ctx, cat):
    b = state.get("bag")
    used, cap = (b.get("used"), b.get("capacity")) if isinstance(b, dict) else (None, None)
    if not isinstance(used, (int, float)) or not isinstance(cap, (int, float)) or cap <= 0:
        return Result(None, "bag size unknown", 0.0, ["bag"])
    if "used_pct_at_least" in a:
        pct, want = 100.0 * used / cap, float(a["used_pct_at_least"])
        return Result(pct >= want, f"bag {used:g}/{cap:g} ({pct:.0f}%, want {want:g}%)", _ratio(pct, want))
    free, want = cap - used, float(a["free_at_least"])
    return Result(free >= want, f"bag {free:g} free (want {want:g})", _ratio(free, want))


def _vital(a, state, ctx, cat):
    stat = a["stat"]
    cur = state.get(stat)
    mx = next((state[k] for k in (f"max_{stat}", f"{stat}_max") if isinstance(state.get(k), (int, float))), None)
    if not isinstance(cur, (int, float)) or not mx:
        return Result(None, f"{stat} unknown", 0.0, [stat])
    pct = 100.0 * cur / mx
    if "below_pct" in a:
        want = float(a["below_pct"])
        return Result(pct < want, f"{stat} {pct:.0f}% (below {want:g}%?)", 1.0 if pct < want else 0.0)
    want = float(a["at_least_pct"])
    return Result(pct >= want, f"{stat} {pct:.0f}%/{want:g}%", _ratio(pct, want))


def _near(a, state, ctx, cat):
    me = state.get("position")
    if not isinstance(me, (list, tuple)):
        return Result(None, "own position unknown", 0.0, ["position"])
    target, label, d = None, None, None
    if a.get("position") is not None:
        target, label = a["position"], str(a["position"])
    elif a.get("place"):
        target, label = _place_pos(ctx.get("places") or {}, a["place"]), a["place"]
        if target is None:
            return Result(None, f"no known position for place {a['place']}", 0.0, [f"place:{a['place']}"])
    elif a.get("player"):
        label = a["player"]
        if not isinstance(state.get("players"), list):
            return Result(None, "players unknown", 0.0, ["players"])
        row = next((p for p in state["players"] if isinstance(p, dict)
                    and str(p.get("name", "")).lower() == a["player"].lower()), None)
        if row is None:
            return Result(False, f"{a['player']} not in sight", 0.0)
        target, d = row.get("position"), row.get("distance")
    else:
        label = a["thing"]
        for key in ("nearby_entities", "nearby_resources", "nearby_items", "interactables"):
            row = next((t for t in state.get(key) or [] if isinstance(t, dict) and str(t.get("id")) == a["thing"]), None)
            if row:
                target, d = row.get("position"), row.get("distance")
                break
        else:
            return Result(False, f"{a['thing']} not in sight", 0.0)
    if target is not None and _dist(me, target) is not None:
        d = _dist(me, target)
    if not isinstance(d, (int, float)):
        return Result(None, f"distance to {label} unknown", 0.0, ["position"])
    w = a["within_m"]
    return Result(d <= w, f"{d:.1f} m from {label} (want <= {w:g})", 1.0 if d <= w else _ratio(w, d))


def _moved(a, state, ctx, cat):
    base = ctx.get("baseline")
    then = base.get("position") if isinstance(base, dict) else None
    d = _dist(state.get("position"), then)
    if d is None:
        return Result(None, "no start or current position to compare", 0.0, ["position" if then else "baseline"])
    return Result(d >= a["min_m"], f"moved {d:.1f} m (want >= {a['min_m']:g})", _ratio(d, a["min_m"]))


def _episodes(ctx: dict) -> list | None:
    ev = ctx.get("episodes", ctx.get("events"))
    return ev if isinstance(ev, list) else None


def _killed(a, state, ctx, cat):
    events = _episodes(ctx)
    if events is None:
        return Result(None, f"{a['kind']}: no fight record since the step started", 0.0, ["episodes"])
    want = tokens(a["kind"])  # whole words, plurals folded (review L2: "goblin" is not "Hobgoblin")
    kills = [f for f in map(_event_fields, events) if f.get("kind") == "combat_end" and f.get("outcome") == "killed"]
    if a.get("kind_id") is not None:
        # an exact creature class / kind id: only checkable when the episodes carry one
        keyed = [f for f in kills if f.get("target_class") is not None or f.get("target_kind") is not None]
        if kills and not keyed:
            return Result(None, f"{a['kind']}: the fight records carry no creature class", 0.0,
                          ["episodes.target_class"])
        n = sum(a["kind_id"] in (str(f.get("target_class")), str(f.get("target_kind"))) for f in keyed)
    elif a.get("target_id") is not None:
        n = sum(str(f.get("target_id")) == a["target_id"] for f in kills)
    else:
        n = sum(bool(want) and want <= tokens(f.get("target")) for f in kills)
    return Result(n >= a["at_least"], f"{a['kind']} killed {n}/{a['at_least']:g}", _ratio(n, a["at_least"]),
                  measures={f"killed:{a['kind'].lower()}": float(n)})


def _on_ground(a, state, ctx, cat):
    rows = state.get("nearby_items")
    if not isinstance(rows, list):
        return Result(None, f"{a['item']}: ground items unknown", 0.0, ["nearby_items"])
    spot = {k: a[k] for k in ("place", "player", "position") if a.get(k) is not None}
    if "position" in spot:
        anchor = spot["position"]
    elif "place" in spot:
        anchor = _place_pos(ctx.get("places") or {}, spot["place"])
    elif "player" in spot:
        anchor = next((p.get("position") for p in state.get("players") or [] if isinstance(p, dict)
                       and str(p.get("name", "")).lower() == spot["player"].lower()), None)
    else:
        anchor = state.get("position")
    where = next(iter(spot.values()), "me")
    if anchor is None:
        return Result(None, f"can't see where {where} is", 0.0, [f"position:{where}"])
    n = 0
    taker = spot.get("player", "").lower()  # re-check 8: a stack flying to that player is delivered too
    for r in rows:
        if isinstance(r, dict) and r.get("item") in a["ids"]:
            d = _dist(r.get("position"), anchor)
            to = str(r.get("magnet_target") or r.get("collecting") or "").lower()
            if (d is not None and d <= a["within_m"]) or (taker and to == taker):
                n += int(r.get("count") or 1)
    return Result(n >= a["at_least"], f"{a['item']} on the ground near {where}: {n}/{a['at_least']:g}",
                  _ratio(n, a["at_least"]), measures={f"on_ground:{a['ids'][0]}": float(n)})


def _elapsed(a, state, ctx, cat):
    base = ctx.get("baseline")
    t0 = base.get("t") if isinstance(base, dict) else None
    now = ctx.get("now")
    if not isinstance(t0, (int, float)) or not isinstance(now, (int, float)):
        return Result(None, "no clock for this step", 0.0, ["clock"])
    s = now - t0
    # for a step whose work is waiting, time passing is the progress (measures feed the no-progress rule)
    return Result(s >= a["seconds"], f"{s:.0f}/{a['seconds']:g} s", _ratio(s, a["seconds"]),
                  measures={"elapsed": float(max(0.0, s))})


def _station(a, state, ctx, cat):
    rows = state.get("stations_nearby")
    if not isinstance(rows, list):
        return Result(None, f"{a['station']}: no station perception", 0.0, ["stations_nearby"])
    want = a["station"].lower()
    row = next((r for r in rows if isinstance(r, dict)
                and want in {str(r.get(k) or "").lower() for k in ("id", "station", "name")}), None)
    if row is None:
        return Result(False, f"no {a['station']} in sight", 0.0)
    name = row.get("name") or a["station"]
    if "running" not in a:
        return Result(True, f"{name} in sight", 1.0)
    if not isinstance(row.get("running"), bool):
        return Result(None, f"{name}: running state unknown", 0.0, ["stations_nearby.running"])
    ok = row["running"] is a["running"]
    return Result(ok, f"{name} {'running' if row['running'] else 'idle'}", 1.0 if ok else 0.0)


def _structure(a, state, ctx, cat):
    rows = state.get("structures")
    if not isinstance(rows, list):
        return Result(None, f"{a['name']}: the body reports no building pieces", 0.0, ["structures"])
    want = tokens(a["name"])
    hits = [r for r in rows if isinstance(r, dict) and not r.get("ghosted")
            and (a["name"] == r.get("id") or (want and want <= (tokens(r.get("name")) | tokens(r.get("piece")))))]
    if a.get("within_m") is not None:
        hits = [r for r in hits if isinstance(r.get("distance"), (int, float)) and r["distance"] <= a["within_m"]]
    if a.get("new"):
        base = ctx.get("baseline")
        if not isinstance(base, dict) or not isinstance(base.get("structure_ids"), list):
            return Result(None, f"{a['name']}: no record of the pieces there before", 0.0, ["baseline"])
        hits = [r for r in hits if r.get("id") not in set(base["structure_ids"])]
    n = len(hits)
    what = f"{a['name']} {'built ' if a.get('new') else ''}{n}/{a['at_least']:g}"
    return Result(n >= a["at_least"], what, _ratio(n, a["at_least"]),
                  measures={f"structure:{a['name'].lower()}": float(n)})


def _stored(a, state, ctx, cat):
    rec = ctx.get("stored")
    if not isinstance(rec, list):
        return Result(None, f"{a['item']}: no record of stored items", 0.0, ["stored"])
    want = tokens(a.get("container") or "")
    rows = [r for r in rec if isinstance(r, dict) and r.get("item") in a["ids"]
            and (not a.get("container") or a["container"] == r.get("container")
                 or (want and want <= tokens(r.get("container_name"))))]
    n = sum(float(r.get("count") or 0) for r in rows)
    trips = len({r.get("run") for r in rows if r.get("run") is not None})
    ok = n >= a["at_least"] and trips >= (a.get("trips_at_least") or 0)
    detail = f"{a['item']} stored {n:g}/{a['at_least']:g}" + (
        f", {trips}/{a['trips_at_least']:g} trips" if a.get("trips_at_least") else "")
    parts = [_ratio(n, a["at_least"])] + ([_ratio(trips, a["trips_at_least"])] if a.get("trips_at_least") else [])
    return Result(ok, detail, min(parts), measures={f"stored:{a['ids'][0]}": n, f"trips:{a['ids'][0]}": float(trips)})


def _quest(a, state, ctx, cat):
    rows = state.get("quests")
    if not isinstance(rows, list):
        return Result(None, f"quest {a['name']}: the body reports no quest state", 0.0, ["quests"])
    row = next((q for q in rows if isinstance(q, dict) and str(q.get("name", "")).lower() == a["name"].lower()), None)
    if row is None:
        return Result(False, f"quest {a['name']} not started", 0.0)
    if a.get("stage") is not None:
        ok = str(row.get("stage")) == str(a["stage"])
        return Result(ok, f"quest {a['name']} at stage {row.get('stage')} (want {a['stage']})", 1.0 if ok else 0.0)
    done = bool(row.get("completed"))
    ok = done == bool(a.get("completed", True))
    return Result(ok, f"quest {a['name']} {'completed' if done else 'not completed'}", 1.0 if ok else 0.0)


@dataclass(frozen=True)
class Leaf:
    """evaluate(args, state, ctx, cat) -> Result; validate(args, items) -> normalised args (or raise
    PredicateError), None = taken as given."""
    evaluate: Callable[[dict, dict, dict, dict | None], Result]
    validate: Callable[[dict, Items], dict] | None = None


# The leaf registry. Built-ins first; others join through register_leaf (no edits here).
LEAVES: dict[str, Leaf] = {}


def register_leaf(name: str, evaluate_fn: Callable[[dict, dict, dict, dict | None], Result],
                  validate_fn: Callable[[dict, Items], dict] | None = None, replace: bool = False) -> None:
    if not re.fullmatch(r"[a-z][a-z0-9_]*", name or "") or name in COMBINATORS:
        raise ValueError(f"bad leaf name {name!r}")
    if name in LEAVES and not replace:
        raise ValueError(f"leaf {name!r} is already registered")
    LEAVES[name] = Leaf(evaluate_fn, validate_fn)


for _name, _fn in (("have", _have), ("gained", _gained), ("lost", _lost), ("tally", _tally), ("skill", _skill),
                   ("skill_gain", _skill_gain), ("equipped", _equipped), ("gear_better", _gear_better),
                   ("bag", _bag), ("vital", _vital), ("near", _near), ("moved", _moved), ("killed", _killed),
                   ("on_ground", _on_ground), ("elapsed", _elapsed), ("station", _station), ("quest", _quest),
                   ("structure", _structure), ("stored", _stored)):
    register_leaf(_name, _fn, lambda a, items, _k=_name: _validate_builtin(_k, a, items))
BUILTIN_LEAVES = tuple(LEAVES)
register = register_leaf  # short name for callers (the Eval benchmark)


# ------------------------------------------------------------------------------ helpers for callers


def snapshot(state: dict, t: float | None = None) -> dict:
    """The parts of a get_state a baseline needs (small enough to persist with a step); ``t`` = wall-clock
    seconds when it was taken (for ``elapsed``, with ctx["now"])."""
    keep = ("inventory", "inventory_items", "gear", "skills", "position", "bag", "total_level")
    out = {k: state[k] for k in keep if k in state}
    if t is not None:
        out["t"] = float(t)
    if isinstance(state.get("structures"), list):  # piece ids only: enough for structure(new)
        out["structure_ids"] = [r.get("id") for r in state["structures"] if isinstance(r, dict) and r.get("id")]
    if isinstance(out.get("inventory_items"), list):  # item ids only: enough for gear_better(carried)
        out["inventory_items"] = [{"item": r.get("item")} for r in out["inventory_items"]
                                  if isinstance(r, dict) and r.get("item")]
    return out


def describe(p: dict) -> str:
    """The predicate in words, for prompts and speech ("have 9 Copper Ore and have 9 Tin Ore")."""
    k, a = _one(p)
    if k in ("all", "any"):
        return f" {'and' if k == 'all' else 'or'} ".join(describe(x) for x in a)
    if k == "not":
        return f"not ({describe(a)})"
    if k not in BUILTIN_LEAVES:
        return f"{k} {json.dumps(a, default=str, ensure_ascii=False)}"
    item = a.get("item")
    return {
        "have": lambda: f"carry {a.get('at_least', 1):g} {item}",
        "gained": lambda: f"gain {a.get('at_least', 1):g} {item}",
        "tally": lambda: f"collect {a.get('at_least', 1):g} {item} in total",
        "skill": lambda: f"{a['name']} level {a['at_least']:g}",
        "skill_gain": lambda: (f"+{a['xp']:g} {a['name']} xp" if a.get("xp") is not None
                               else f"+{a.get('levels', 1):g} {a['name']} level(s)"),
        "equipped": lambda: f"{item} equipped",
        "gear_better": lambda: f"a {a.get('category') or a.get('slot')} with {a['stat']} {a.get('op', '>')} "
                               f"{'what you had at the start' if a.get('than', 'start') == 'start' else a['than']}"
                               f" ({a.get('where', 'equipped')})",
        "bag": lambda: (f"bag at least {a['used_pct_at_least']:g}% full" if "used_pct_at_least" in a
                        else f"at least {a['free_at_least']:g} free bag slots"),
        "vital": lambda: (f"{a['stat']} below {a['below_pct']:g}%" if "below_pct" in a
                          else f"{a['stat']} at least {a['at_least_pct']:g}%"),
        "near": lambda: f"within {a.get('within_m', DEFAULT_NEAR_M):g} m of "
                        f"{a.get('place') or a.get('player') or a.get('thing') or a.get('position')}",
        "moved": lambda: f"move at least {a['min_m']:g} m",
        "lost": lambda: f"{a.get('at_least', 1):g} {item} leave your inventory",
        "on_ground": lambda: f"{a.get('at_least', 1):g} {item} on the ground near "
                             f"{a.get('player') or a.get('place') or a.get('position') or 'you'}",
        "elapsed": lambda: f"{a['seconds']:g} s pass",
        "station": lambda: f"{a['station']} " + ("in sight" if "running" not in a
                                                 else ("running" if a["running"] else "idle")),
        "killed": lambda: f"kill {a.get('at_least', 1):g} {a['kind']}",
        "quest": lambda: f"quest {a['name']} " + (f"at stage {a['stage']}" if a.get("stage") is not None else "completed"),
        "structure": lambda: f"{a.get('at_least', 1):g} {a['name']} " + ("built" if a.get("new") else "nearby"),
        "stored": lambda: f"store {a.get('at_least', 1):g} {a['item']}" + (
            f" in {a['container']}" if a.get("container") else "") + (
            f" over {a['trips_at_least']:g} trips" if a.get("trips_at_least") else ""),
    }[k]()

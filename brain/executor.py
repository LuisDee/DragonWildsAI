"""Deterministic executor: runs one task at a time and verifies it against fresh state.

A task is done only when a fresh ``get_state()`` confirms the effect (design
principle 2); the body's own ``ok`` is necessary but not sufficient. Transient
failures are retried up to ``max_attempts``; deterministic ones (nothing in
range, missing materials, ...) go straight back to the planner; interrupts
(player command, attack) are handed to the agent without using up a retry.

``still_running`` (the player spoke mid-action; the body keeps doing it) is an interrupt too. The executor remembers
that request: the SAME call again (same skill, same arguments) re-attaches to it (``GameInterface.reattach``) and is
verified against the first call's baseline, instead of sending it again (a re-sent go_to restarts the trip: co-play
retro 2026-11-01, root cause 2). Any other call is sent as usual (the body's action slot replaces the running one).
"""
from __future__ import annotations

import math
import time
from dataclasses import dataclass, field
from typing import Any, Callable

from .interface import GameInterface, Reason
from .jsonl_log import JsonlLogger
from .state_store import StateStore, Task
from .knowledge import _terms

class StateUnavailable(RuntimeError):
    """get_state failed. Without fresh state no step can be verified (principle 2)."""


@dataclass
class Outcome:
    ok: bool
    reason: str | None = None
    attempts: int = 0
    data: dict[str, Any] = field(default_factory=dict)
    interrupt: bool = False


SAME_POINT_M = 1.0  # two [x, y, z] targets this close are the same target


def _same_value(a, b) -> bool:
    if isinstance(a, dict) and isinstance(b, dict):
        return same_args(a, b)
    if isinstance(a, (list, tuple)) and isinstance(b, (list, tuple)):
        nums = all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in (*a, *b))
        if nums and 2 <= len(a) == len(b) <= 3:
            return math.dist(a, b) <= SAME_POINT_M
        return len(a) == len(b) and all(_same_value(x, y) for x, y in zip(a, b))
    if isinstance(a, str) and isinstance(b, str):
        return a.strip().lower() == b.strip().lower()
    return a == b


def same_args(a: dict | None, b: dict | None) -> bool:
    """Is this the same call? Equal arguments (absent = None), a point within SAME_POINT_M, names in any case."""
    a = {k: v for k, v in (a or {}).items() if v is not None}
    b = {k: v for k, v in (b or {}).items() if v is not None}
    return a.keys() == b.keys() and all(_same_value(a[k], b[k]) for k in a)


def _inv(state: dict, item: str) -> int:
    # Exact keys only. Item skills (give/drop/pickup) verify against the id the body resolved and
    # reports in data["item"] ("oak" -> "ITEM_Resources_Wood_Oak"), never a fuzzy match.
    return int((state.get("inventory") or {}).get(item, 0))


# Count-based skills: skill -> (arg naming the item, +1 if it enters the inventory, -1 if it leaves).
_COUNTED = {"gather": ("resource", 1), "craft": ("item", 1), "give": ("item", -1)}


def _delta(skill: str, args: dict, base: dict, now: dict) -> int:
    """How many of the skill's item it has moved so far, in the skill's direction."""
    key, sign = _COUNTED[skill]
    return sign * (_inv(now, args[key]) - _inv(base, args[key]))


# ------------------------------------------------------------------ verifiers
# (args, baseline_state, post_state, result_data) -> failure reason or None


# A go_to target can sit below the walkable ground (a water volume's surface point, a resource's root):
# arrival is judged on the ground plane, like the body's own dist_m and _v_come_to, with a separate
# vertical bound so a target on another level still fails truthfully. Live 22:19:34 (episode 221904b):
# the body arrived 0.77 m away on the ground, 3.1 m above the water point; the 3D distance said "still
# 3.2m from target", a false failure the model retried 4 x and a template read out in metres.
ARRIVE_VERTICAL_M = 4.0


def _v_go_to(args, base, post, data):
    target = data.get("target_position")
    if target is None:
        return None
    pos = post["position"]
    flat = math.dist(pos[:2], target[:2])
    if flat > data.get("arrive_tolerance", 3.0):
        return f"still {flat:.1f}m from target"
    dz = (pos[2] - target[2]) if len(pos) > 2 and len(target) > 2 else 0.0
    if abs(dz) > ARRIVE_VERTICAL_M:
        return f"next to it but {abs(dz):.1f}m {'above' if dz > 0 else 'below'} it"
    return None


def _v_follow(args, base, post, data):
    return None if post.get("following") == args["player"] else "not following"


def _v_stop(args, base, post, data):
    return None if post.get("following") is None else "still following"


def _v_attack(args, base, post, data):
    alive = [e for e in post.get("nearby_entities", []) if e["id"] == args["target"] and e["alive"]]
    return "target still alive" if alive else None


def _v_gain(skill):
    key = _COUNTED[skill][0]

    def check(args, base, post, data):
        # gather: the body reports the item id it resolved ("oak" -> ITEM_Resources_Wood_Oak); count that key.
        item = (data or {}).get("item") or args.get(key)
        if not item:  # craft {input} / {recipe} with no output named: the body verified it from his bag
            return None
        want = args.get("count") or 1
        gained = _inv(post, item) - _inv(base, item)
        # what the stay-fed reflex ate or drank of the output as it came out was made too (the body's own count,
        # crafting.lua "reflex_used"). Run 20261117-044508: 3 Clean Water boiled, the reflex drank 1, "+2, wanted +3"
        # failed the craft and he stopped on the failure note with the quest open (7 such false failures in 4 days).
        used = (data or {}).get("reflex_used")
        gained += sum(int(r.get("count") or 0) for r in used if isinstance(r, dict) and r.get("item") == item)             if isinstance(used, list) else 0
        return None if gained >= want else f"inventory {item} +{gained}, wanted +{want}"
    return check


def _v_give(args, base, post, data):
    # The body reports the item id it resolved ("oak" -> ITEM_Resources_Wood_Oak); count that key.
    item = data.get("item") or args["item"]
    given = _inv(base, item) - _inv(post, item)
    return None if given >= args["count"] else f"only {given} {item} left inventory"


def _v_drop(args, base, post, data):
    problem = _v_give(args, base, post, data)
    if problem:
        return problem
    nearby = post.get("nearby_items")
    if nearby is None:  # a body without nearby_items: the store change is all we can check
        return None
    ids = {i.get("id") for i in nearby}
    missing = [w for w in data.get("world_items", []) if w not in ids]
    return f"dropped items not on the ground: {missing}" if missing else None


def _v_pickup(args, base, post, data):
    item, count = data.get("item"), int(data.get("count") or 0)
    if not item or count < 1:
        return "nothing picked up"
    gained = _inv(post, item) - _inv(base, item)
    if gained < count:
        return f"inventory {item} +{gained}, body said +{count}"
    still = {i.get("id") for i in post.get("nearby_items", [])}
    left = [p.get("world_item") for p in data.get("picked", []) if p.get("world_item") in still]
    return f"world items still on the ground: {left}" if left else None


def _v_interact(args, base, post, data):
    # A grant (sticks, berries, a chest item) must show up in the bot's inventory under the item id
    # the body reports (data.item, data.count). An interaction that grants nothing (a door, a
    # station) is verified by the body from game state (research 2026-10-25 section 7.1 step 6).
    item = data.get("item")
    if not item:
        return None
    want = max(1, int(data.get("count") or 1))
    gained = _inv(post, item) - _inv(base, item)
    return None if gained >= want else f"inventory {item} +{gained}, body said +{want}"


def _v_place(args, base, post, data):
    ids = {s["id"] for s in post.get("structures", [])}
    return None if data.get("structure_id") in ids else "structure not found"


def _v_cast(args, base, post, data):
    # The body verifies the effect from game state where it can (a new gameplay-effect instance for
    # self effects, the held actor's effect read back for enchants) and otherwise answers
    # verification_failed itself; a retry would double-cast, so nothing more is demanded here
    # except, when the state exposes spell cooldowns (the mock does), that the cooldown started.
    cds = post.get("spell_cooldowns")
    if not isinstance(cds, dict):
        return None
    spell = data.get("spell")
    if not spell:
        return "the body did not say which spell it cast"
    if data.get("cooldown_s", 0) > 1 and not cds.get(spell):
        return f"{spell} cooldown did not start"
    return None


def _v_fetch(args, base, post, data):
    # the body reports the inventory key it picked up (data.item) and how many (data.count)
    item, count = data.get("item"), int(data.get("count") or 0)
    if not item or count < 1:
        return "nothing picked up"
    gained = _inv(post, item) - _inv(base, item)
    return None if gained >= count else f"inventory {item} +{gained}, body said +{count}"


def _v_consume(args, base, post, data):
    # The body verified the stat rose (or the item was used up at a full stat); check the carried count fell.
    item = data.get("item")
    if not item:
        return "the body did not say what it used"
    if data.get("fetched"):  # picked up first, then used: net change can be zero
        return None
    return None if _inv(post, item) < _inv(base, item) else f"{item} still carried ({_inv(post, item)})"


def _v_come_to(args, base, post, data):
    me = post.get("position")
    for p in post.get("players") or []:
        if p.get("name") == args["player"] and me and p.get("position"):
            d = math.dist(me[:2], p["position"][:2])
            tol = float(data.get("arrive_tolerance") or (args.get("distance", 2.0) + 1.5))
            return None if d <= tol + 1.0 else f"still {d:.1f}m from {args['player']}"
    return None  # he is not in the fresh census (moved out of relevancy): trust the body's own check


def _v_recover_grave(args, base, post, data):
    before = sum((base.get("inventory") or {}).values())
    after = sum((post.get("inventory") or {}).values())
    return None if after > before else "nothing came back into the inventory"


VERIFIERS: dict[str, Callable] = {
    "fetch": _v_fetch,
    "consume": _v_consume,
    "come_to": _v_come_to,
    "recover_grave": _v_recover_grave,
    "go_to": _v_go_to,
    "follow": _v_follow,
    "stop": _v_stop,
    "attack": _v_attack,
    "gather": _v_gain("gather"),
    "craft": _v_gain("craft"),
    "give": _v_give,
    "drop": _v_drop,
    "pickup": _v_pickup,
    "place": _v_place,
    "interact": _v_interact,
    "cast": _v_cast,
    "sleep": lambda args, base, post, data: None if post.get("sleeping") is not False else "not sleeping",
    "wake": lambda args, base, post, data: None if not post.get("sleeping") else "still sleeping",
}


# a get_state this recent is reused before an action (L6): the read the model decided on (one Controller call old,
# ~2-3 s) is the action's baseline; reading again cost 0.5 s before every first action (rung 3 mine 2026-11-16)
STATE_REUSE_S = 4.0


def _bag(state: dict | None) -> dict[str, int]:
    from .plan_sources import counts
    return counts(state)


def craft_shortfall(args: dict, bag: dict[str, int], recipes: dict) -> dict | None:
    """A craft step against the game's recipe data (data/recipes_<build>.json, what crafting.lua and craft_plan read)
    and his bag: None when a recipe for it is covered by the bag, or when the data names no recipe for it (the body
    answers then); otherwise {item, name, count, recipe, missing: [{item, name, need, have}], recipes, can_make}, the
    closest recipe first. Facts only: what he chose to make is never changed."""
    item = args.get("item")
    if not isinstance(item, str) or not item.strip():
        return None
    want = item.strip().lower()
    rid_named = args.get("recipe") if isinstance(args.get("recipe"), str) else None
    try:
        count = max(1, int(args.get("count") or 1))
    except (TypeError, ValueError):
        return None
    cands = []
    for rid, r in sorted((recipes or {}).items()):
        if not isinstance(r, dict) or r.get("test") or (rid_named and rid.lower() != rid_named.strip().lower()):
            continue
        out = next((o for o in r.get("outputs") or [] if isinstance(o, dict) and o.get("item") and
                    want in (str(o["item"]).lower(), str(o.get("name") or "").lower(), rid.lower())), None)
        ins = [i for i in r.get("inputs") or [] if isinstance(i, dict) and i.get("item")]
        if out is None or not ins:
            continue
        per = max(1, int(out.get("count") or 1))
        crafts = math.ceil(count / per)
        rows = [{"item": i["item"], "name": i.get("name") or i["item"], "per": max(1, int(i.get("count") or 1)),
                 "need": max(1, int(i.get("count") or 1)) * crafts, "have": int(bag.get(i["item"], 0))} for i in ins]
        missing = [{k: x[k] for k in ("item", "name", "need", "have")} for x in rows if x["have"] < x["need"]]
        if not missing:
            return None  # a recipe the bag covers: sent as he chose
        can = min(x["have"] // x["per"] for x in rows) * per
        cands.append({"item": out["item"], "name": out.get("name") or out["item"], "count": count, "recipe": rid,
                      "missing": missing, "can_make": can, "short": sum(m["need"] - m["have"] for m in missing)})
    if not cands:
        return None
    cands.sort(key=lambda c: (c["short"], c["recipe"]))
    best = dict(cands[0])
    best["recipes"] = len(cands)
    best["can_make"] = max(c["can_make"] for c in cands)
    best.pop("short")
    return best


def held_detail(short: dict, plan_bag: dict[str, int] | None) -> str:
    """The words of a held craft step: the numbers, what the bag gained since the plan, what he can make now."""
    needs = ", ".join(f"{m['need']} {m['name']} and you hold {m['have']}" for m in short["missing"])
    text = f"Not sent: {short['name']} x{short['count']} needs {needs}"
    if short.get("recipes", 1) > 1:
        text += f" (the closest of {short['recipes']} recipes for it)"
    if plan_bag is not None:
        moved = [f"{m['name']} {int(plan_bag.get(m['item'], 0))} -> {m['have']}" for m in short["missing"]]
        gains = [m["have"] - int(plan_bag.get(m["item"], 0)) for m in short["missing"]]
        text += ("; since the plan your bag went " + ", ".join(f"{s} ({g:+d})" for s, g in zip(moved, gains)))
    text += f". With what you hold you can make {short['can_make']} {short['name']}."
    return text


def _place_basis(best: dict) -> str:
    """How sure the go_to point is, in a few words (brain.places explains landmarks at length)."""
    if best.get("kind") != "landmark":
        return str(best.get("basis") or "")
    n = sum((best.get("spots_by_province") or {}).values())
    mine = " in your province" if best.get("your_province") and best.get("province") == best["your_province"] else ""
    return (f"the nearest{mine} of {n} spots with that name in the game's map data (the one you meet may be another)"
            if n > 1 else "its spot in the game's map data")


class Executor:
    """``sleep`` waits out a short spell cooldown (on_cooldown with data.remaining_s up to
    ``max_cooldown_wait`` seconds) before the retry; longer cooldowns fail at once."""

    def __init__(self, game: GameInterface, store: StateStore, logger: JsonlLogger, max_attempts: int = 3,
                 sleep: Callable[[float], None] = time.sleep, max_cooldown_wait: float = 5.0):
        self.game = game
        self.store = store
        self.log = logger
        self.max_attempts = max_attempts
        self.sleep = sleep
        self.max_cooldown_wait = max_cooldown_wait
        self._baselines: dict[str, dict] = {}  # task id -> state when the task first started
        self._cache: tuple[float, dict] | None = None  # (time, data) of the last get_state
        self._resolved_items: dict[str, str] = {}  # task id -> inventory key the body reported (data.item)
        self.places = None  # brain.places.Places (LiveSession): game-data place names go_to falls back to
        # the call the body is still doing after the player spoke (still_running): {skill, args, id, base, since}
        self.running: dict | None = None
        # a Planner-queued step (agent._run_goal sets its task id): decided before the steps ahead of it reported, so a
        # craft is checked against the fresh bag before it is sent (craft misses study 2026-11-19: 11 of 13 craft
        # missing_materials were queued crafts sent on what the kills before them did not drop)
        self.queued: str | None = None
        self.plan_bag: dict[str, int] | None = None  # his bag when the plan running now was made (None: unknown)
        self.recipes: dict | None = None  # the game's recipe data (needs.catalog), read on first use

    def _recipes(self) -> dict:
        if self.recipes is None:
            from .needs import catalog
            self.recipes = catalog().get("recipes") or {}
        return self.recipes

    def _held_craft(self, task: Task, args: dict, now: dict) -> dict | None:
        """A queued craft the fresh bag does not cover: the result that goes back instead of sending it, or None."""
        if task.skill != "craft" or self.queued != task.id:
            return None
        try:
            short = craft_shortfall(args, _bag(now), self._recipes())
        except Exception as exc:  # the check is a read: on any error the step is sent as before
            self.log.log("craft_check_error", task_id=task.id, error=repr(exc)[:200])
            return None
        if short is None:
            return None
        self.log.log("craft_step_held", task_id=task.id, item=short["name"], count=short["count"],
                     recipe=short["recipe"], need={m["name"]: m["need"] for m in short["missing"]},
                     have={m["name"]: m["have"] for m in short["missing"]}, can_make=short["can_make"])
        return {"ok": False, "reason": Reason.MISSING_MATERIALS,
                "data": {"item": short["item"], "recipe": short["recipe"], "missing": short["missing"],
                         "can_make": short["can_make"], "held_before_send": True,
                         "detail": held_detail(short, self.plan_bag)}}

    def state(self, max_age: float | None = None) -> dict:
        """Fresh get_state, or (``max_age``) the last one if it is that recent and no action ran since
        (L6: one state read per turn instead of three; verification after an action is always fresh)."""
        now = time.monotonic()
        if max_age is not None and self._cache is not None and now - self._cache[0] <= max_age:
            return self._cache[1]
        res = self.game.get_state()
        if not res["ok"]:
            raise StateUnavailable(f"get_state failed: {res['reason']}")
        self._cache = (time.monotonic(), res["data"])
        return res["data"]

    def _remaining_args(self, task: Task, base: dict, now: dict) -> dict | None:
        """Resume count-based skills where they left off; None means already satisfied."""
        if task.skill not in _COUNTED:
            return dict(task.args)
        args = task.args
        key = _COUNTED[task.skill][0]
        if task.id in self._resolved_items:  # the body told us the real inventory key on an earlier try
            args = {**args, key: self._resolved_items[task.id]}
        if not args.get(key) or "count" not in task.args:
            # craft by recipe id alone has no item to count (live 18:22Z: KeyError 'item' ended the request with
            # "my head glitched"): run it as asked, the body verifies it
            return dict(task.args)
        remaining = task.args["count"] - _delta(task.skill, args, base, now)
        return {**task.args, "count": remaining} if remaining > 0 else None

    def _resolve_place(self, skill: str, args: dict, now: dict) -> dict:
        """go_to(<a place Luis named>) -> its stored coordinates, unless the body knows that place
        itself (state places) or the name is a player or entity (per-world places, design 15)."""
        target = args.get("target")
        if skill != "go_to" or not isinstance(target, str) or target in (now.get("places") or []):
            return args
        if any(p.get("name") == target for p in now.get("players") or []):
            return args
        places = getattr(self.store, "place_position", None)
        pos = places(target) if places else None
        if pos is None:
            return args
        self.log.log("place_resolved", place=target, position=pos)
        return {**args, "target": pos}

    def _go_to_lodestone_id(self, args: dict, target: str, failed: dict) -> dict:
        """go_to(<an id from the lodestones tool>): its position from the same tool (chat ladder cl-20261101T234144Z:
        go_to "lodestone:5E74..." came back unknown_target "not in sight" from the very list that named it)."""
        lr = self.game.call("lodestones", {})
        rows = ((lr.get("data") or {}).get("lodestones") or []) if lr.get("ok") else []
        row = next((x for x in rows if isinstance(x, dict) and str(x.get("id")) == target and x.get("position")), None)
        if row is None:
            return failed
        self.log.log("place_resolved", place=target, position=row["position"], source="lodestones")
        result = self.game.call("go_to", {**args, "target": row["position"]})
        data = result.get("data") if isinstance(result.get("data"), dict) else {}
        took = f"{target} is the lodestone at {row['position']}" + (f", {row['distance']:.0f} m away"
                                                                    if isinstance(row.get("distance"), (int, float)) else "")
        return {**result, "data": {**data, "resolved": took}}

    def _go_to_game_place(self, task: Task, args: dict, now: dict, failed: dict) -> dict:
        """go_to(<a name the body can't see>) -> the place of that name in the game's map data (a landmark spot, or
        a region / province's best known point), walked to at once; the result says what the name was taken to be.
        The body's own answer stands when the name isn't in the data or matches only part of a name (the leading words
        of exactly one map name count as naming it)."""
        target = args.get("target")
        if task.skill == "go_to" and isinstance(target, str) and target.strip().lower().startswith("lodestone:"):
            return self._go_to_lodestone_id(args, target.strip(), failed)
        if task.skill not in ("go_to", "talk") or self.places is None or not isinstance(target, str):
            return failed
        try:
            lodes = None
            if "lodestone" in _terms(target):  # "the lodestone by Zanik": the body lists the world's lodestones
                lr = self.game.call("lodestones", {})
                lodes = ((lr.get("data") or {}).get("lodestones") or []) if lr.get("ok") else None
            res = self.places.where(target, now.get("position"), lodestones=lodes)
        except Exception as exc:  # map data is best effort: the body's answer stands
            self.log.log("place_lookup_error", place=target, error=repr(exc)[:200])
            return failed
        results = (res.get("data") or {}).get("results") or []
        best = next(iter(results), None)
        # a name's leading words name it when only one map name starts that way ("Bramblemead": the region Bramblemead
        # Valley, live 17:2xZ); several ("Bramble": Valley and Village) stay the model's call (map_names_like_it)
        leading = best is not None and best.get("match") == "leading" and             len({o.get("name") for o in results if o.get("match") == "leading"}) == 1
        if not best or (best.get("match") not in ("exact", "named") and not leading) or not best.get("position"):
            best = self._quest_marker(target)
        if best is None:
            try:  # no exact map name: say which map names share a word with it (the model decides)
                like = self.places.similar(target, now.get("position"))
            except Exception:
                like = []
            if like:
                return {**failed, "data": {**(failed.get("data") or {}), "map_names_like_it": like}}
            return failed
        if best.get("you_are_inside") and best.get("source") == "quest_marker" and task.skill == "go_to":
            # inside a quest step's area (live ClaudeQ7 22:28Z: go_to "the windmill" at Vannaka, inside the 80 m
            # Windmill Area, came back unknown_target "you are in it now" and he then walked to its centre himself):
            # the marker's spot is the area's centre, where the game puts the step's work
            took = (f"{target!r} is the game map's {best['kind']} {best['name']}: you were already inside it "
                    f"({_place_basis(best)}); walking to its centre"
                    + (f", {best['distance_m']:.0f} m away" if isinstance(best.get("distance_m"), (int, float)) else ""))
            self.log.log("place_resolved", place=target, position=best["position"], source="quest_marker", inside=True)
            result = self.game.call("go_to", {**args, "target": best["position"]})
            data = result.get("data") if isinstance(result.get("data"), dict) else {}
            return {**result, "data": {**data, "resolved": took}}
        if best.get("you_are_inside"):
            return {**failed, "data": {**(failed.get("data") or {}),
                                       "resolved": f"{target!r} is the game map's {best['kind']} {best['name']}: "
                                                   "you are in it now"}}
        where = ", ".join(x for x in (best.get("region"), best.get("province")) if x and x != best["name"])
        what = best["name"] if str(best["name"]).lower().startswith(best["kind"]) else f"{best['kind']} {best['name']}"
        took = (f"{target!r} is not in sight; walking to the game map's {what}"
                + (f" in {where}" if where else "")
                + (f", {best['distance_m']:.0f} m away" if isinstance(best.get("distance_m"), (int, float)) else "")
                + (f": {how}" if (how := _place_basis(best)) else "")
                + (" (approximate)" if best.get("approximate") else ""))
        self.log.log("place_resolved", place=target, position=best["position"], source=best.get("source"),
                     place_kind=best["kind"], approximate=bool(best.get("approximate")))
        if task.skill == "talk":  # an NPC out of sight (quest steps name them): walk to its map spot, then talk there
            walk = self.game.call("go_to", {"target": best["position"]})
            if not walk.get("ok"):
                wd = walk.get("data") if isinstance(walk.get("data"), dict) else {}
                return {**walk, "data": {**wd, "resolved": took + "; I didn't get there"}}
            result = self.game.call("talk", args)
            data = result.get("data") if isinstance(result.get("data"), dict) else {}
            return {**result, "data": {**data, "resolved": took}}
        result = self.game.call(task.skill, {**args, "target": best["position"]})
        data = result.get("data") if isinstance(result.get("data"), dict) else {}
        if result.get("ok") and best["kind"] == "landmark" and (seen := self._seen_at_spot(best["name"])):
            data = {**data, "target": best["name"], "on_arrival": seen}  # chat run 4: he looked to check (1 call)
            if not seen.startswith("no "):  # seen there: the "may be another" caveat is answered (chat run 5: he
                took = (f"{target!r} was not in sight; walked to the game map's {what}"  # still
                        + (f" in {where}" if where else ""))                                       # looked to check)
        return {**result, "data": {**data, "resolved": took}}

    def _quest_marker(self, target: str) -> dict | None:
        """The map marker of an active quest that the name names, as a map place, from the body's quests read: the
        markers the game's map and compass show for the step ("Windmill Area" for "windmill": live 19:1xZ, Ratcatcher's
        step says "near the windmill" and go_to windmill was unknown_target). Matched like a map name (every word,
        or the leading words of exactly one marker); None when none or several markers fit."""
        from .places import _RANK, _match
        try:
            r = self.game.call("quests", {})
        except Exception:
            return None
        q, hits = _terms(target), []
        for a in ((r.get("data") or {}).get("active") or []) if r.get("ok") else []:
            for m in a.get("where") or []:
                kind = _match(str(m.get("name") or ""), q)
                if kind in ("exact", "named", "leading") and m.get("position"):
                    hits.append((_RANK[kind], a.get("quest"), m))
        top = [h for h in hits if h[0] == min((h[0] for h in hits), default=None)]
        if len({h[2]["name"] for h in top}) != 1:
            return None
        _, quest, m = top[0]
        area = m.get("kind") == "area" and m.get("radius_m")
        return {"name": m["name"], "kind": f"{quest} quest marker" if quest else "quest marker", "position": m["position"],
                "distance_m": m.get("distance_m"), "you_are_inside": bool(m.get("inside")), "source": "quest_marker",
                "basis": f"an area of {area:.0f} m radius on the quest map" if area else "its spot on the quest map"}

    def _seen_at_spot(self, name: str, radius: float = 15.0) -> str | None:
        """After walking to a map spot: is a thing of that name in sight there? (a body read, no model call)"""
        try:
            r = self.game.call("look", {"about": name, "radius": radius, "max": 8})
        except Exception:
            return None
        if not r.get("ok"):
            return None
        q = _terms(name)
        for t in (r.get("data") or {}).get("things") or []:
            seen = self.places.name_for(t.get("name"), t.get("actor_position") or t.get("position")) or t.get("name")
            if q and q <= _terms(str(seen or "")):
                d = t.get("distance")
                return f"{seen} is here" + (f", {d:.0f} m away" if isinstance(d, (int, float)) else "")
        return f"no {name} in sight within {radius:.0f} m of the map's spot"

    def run_task(self, task: Task) -> Outcome:
        if task.skill not in self.store.skills:
            return self._finish(task, Outcome(False, Reason.UNKNOWN_SKILL))
        try:
            return self._run(task)
        except StateUnavailable as exc:
            self.log.log("state_unavailable", task_id=task.id, tool=task.skill, error=str(exc))
            return self._finish(task, Outcome(False, Reason.STATE_UNAVAILABLE, task.attempts))

    def continues(self, task: Task) -> bool:
        """Is this task the same call as the one the body is still doing since the player spoke (still_running)?"""
        r = self.running
        return r is not None and r["skill"] == task.skill and same_args(r["args"], task.args)

    def _run(self, task: Task) -> Outcome:
        run = self.running if self.continues(task) else None
        if run is not None:
            self.running = None
            self._baselines.setdefault(task.id, run["base"])  # verified from the first call's start
        base = self._baselines.setdefault(task.id, self.state(max_age=STATE_REUSE_S))
        reason = None
        last_data: dict = {}
        while task.attempts < self.max_attempts:
            now = self.state(max_age=STATE_REUSE_S)  # the read just before is reused (L6)
            args = self._remaining_args(task, base, now)
            if args is None:
                return self._finish(task, Outcome(True, attempts=task.attempts))
            args = self._resolve_place(task.skill, args, now)
            held = self._held_craft(task, args, now) if run is None else None
            if held is not None:  # not sent: back to the Planner like any failed step, with the bag's numbers
                self.log.log("tool_result", task_id=task.id, tool=task.skill, result=held)
                return self._finish(task, Outcome(False, held["reason"], task.attempts, held["data"]))
            task.attempts += 1
            task.status = "running"
            self.store.save_tree()
            self.log.log("tool_call", task_id=task.id, tool=task.skill, args=args, attempt=task.attempts,
                         **({"reattach": run["id"]} if run is not None else {}))
            result = None
            if run is not None:  # the same call while the body still does it: watch that one, don't restart it
                reattach = getattr(self.game, "reattach", None)
                result = reattach(run["id"]) if reattach is not None else None
                if result is None:
                    self.log.log("reattach_missed", task_id=task.id, tool=task.skill, id=run["id"],
                                 why="it ended meanwhile: sent again")
                run = None
            if result is None:
                result = self.game.call(task.skill, args)
            if not result["ok"] and result["reason"] == Reason.UNKNOWN_TARGET:
                result = self._go_to_game_place(task, args, now, result)
            self._cache = None  # the world changed: verification reads fresh state
            self.log.log("tool_result", task_id=task.id, tool=task.skill, result=result)
            if task.skill in _COUNTED and isinstance(result.get("data"), dict) and result["data"].get("item"):
                self._resolved_items[task.id] = result["data"]["item"]

            if not result["ok"]:
                reason = result["reason"]
                last_data = result["data"]
                if reason in Reason.INTERRUPTS:
                    if reason == Reason.STILL_RUNNING and isinstance(last_data, dict) and last_data.get("id"):
                        self.running = {"skill": task.skill, "args": dict(task.args), "id": last_data["id"],
                                        "base": base, "since": time.monotonic()}
                    task.attempts -= 1  # an interrupt is not the skill's fault
                    task.status = "pending"
                    self.store.save_tree()
                    return Outcome(False, reason, task.attempts, result["data"], interrupt=True)
                if reason in Reason.DETERMINISTIC:
                    break
                if reason == Reason.ON_COOLDOWN:
                    wait = float(result["data"].get("remaining_s") or 0)
                    if not 0 < wait <= self.max_cooldown_wait:
                        break  # a long cooldown: report it rather than block the agent
                    self.log.log("cooldown_wait", task_id=task.id, tool=task.skill, seconds=wait)
                    self.sleep(wait + 0.1)
                continue

            verifier = VERIFIERS.get(task.skill)
            problem = verifier(task.args, base, self.state(), result["data"]) if verifier else None
            if problem is None:
                return self._finish(task, Outcome(True, attempts=task.attempts, data=result["data"]))
            reason = f"{Reason.VERIFICATION_FAILED}: {problem}"
            last_data = result["data"]
            self.log.log("verification_failed", task_id=task.id, tool=task.skill, problem=problem)

        return self._finish(task, Outcome(False, reason, task.attempts, last_data))

    def _finish(self, task: Task, outcome: Outcome) -> Outcome:
        task.status = "done" if outcome.ok else "failed"
        task.last_reason = outcome.reason
        self._baselines.pop(task.id, None)
        self.store.save_tree()
        self.store.progress(
            f"task {task.skill} {'done' if outcome.ok else 'failed'}",
            task_id=task.id, args=task.args, reason=outcome.reason, attempts=outcome.attempts,
        )
        self.log.log("task_" + ("done" if outcome.ok else "failed"), task_id=task.id, skill=task.skill,
                     reason=outcome.reason, attempts=outcome.attempts)
        return outcome

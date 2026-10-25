"""Deterministic executor: runs one task at a time and verifies it against fresh state.

A task is done only when a fresh ``get_state()`` confirms the effect (design
principle 2); the body's own ``ok`` is necessary but not sufficient. Transient
failures are retried up to ``max_attempts``; deterministic ones (nothing in
range, missing materials, ...) go straight back to the planner; interrupts
(player command, attack) are handed to the agent without using up a retry.
"""
from __future__ import annotations

import math
import time
from dataclasses import dataclass, field
from typing import Any, Callable

from .interface import GameInterface, Reason
from .jsonl_log import JsonlLogger
from .state_store import StateStore, Task

class StateUnavailable(RuntimeError):
    """get_state failed. Without fresh state no step can be verified (principle 2)."""


@dataclass
class Outcome:
    ok: bool
    reason: str | None = None
    attempts: int = 0
    data: dict[str, Any] = field(default_factory=dict)
    interrupt: bool = False


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


def _v_go_to(args, base, post, data):
    target = data.get("target_position")
    if target is None:
        return None
    d = math.dist(post["position"], target)
    return None if d <= data.get("arrive_tolerance", 3.0) else f"still {d:.1f}m from target"


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
        item = (data or {}).get("item") or args[key]
        gained = _inv(post, item) - _inv(base, item)
        return None if gained >= args["count"] else f"inventory {item} +{gained}, wanted +{args['count']}"
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


STATE_REUSE_S = 1.0  # a get_state this recent is reused before an action (L6)


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

    def run_task(self, task: Task) -> Outcome:
        if task.skill not in self.store.skills:
            return self._finish(task, Outcome(False, Reason.UNKNOWN_SKILL))
        try:
            return self._run(task)
        except StateUnavailable as exc:
            self.log.log("state_unavailable", task_id=task.id, tool=task.skill, error=str(exc))
            return self._finish(task, Outcome(False, Reason.STATE_UNAVAILABLE, task.attempts))

    def _run(self, task: Task) -> Outcome:
        base = self._baselines.setdefault(task.id, self.state(max_age=STATE_REUSE_S))
        reason = None
        last_data: dict = {}
        while task.attempts < self.max_attempts:
            now = self.state(max_age=STATE_REUSE_S)  # the read just before is reused (L6)
            args = self._remaining_args(task, base, now)
            if args is None:
                return self._finish(task, Outcome(True, attempts=task.attempts))
            args = self._resolve_place(task.skill, args, now)
            task.attempts += 1
            task.status = "running"
            self.store.save_tree()
            self.log.log("tool_call", task_id=task.id, tool=task.skill, args=args, attempt=task.attempts)
            result = self.game.call(task.skill, args)
            self._cache = None  # the world changed: verification reads fresh state
            self.log.log("tool_result", task_id=task.id, tool=task.skill, result=result)
            if task.skill in _COUNTED and isinstance(result.get("data"), dict) and result["data"].get("item"):
                self._resolved_items[task.id] = result["data"]["item"]

            if not result["ok"]:
                reason = result["reason"]
                last_data = result["data"]
                if reason in Reason.INTERRUPTS:
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

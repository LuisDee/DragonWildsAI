"""Deterministic executor: runs one task at a time and verifies it against fresh state.

A task is done only when a fresh ``get_state()`` confirms the effect (design
principle 2); the body's own ``ok`` is necessary but not sufficient. Transient
failures are retried up to ``max_attempts``; deterministic ones (nothing in
range, missing materials, ...) go straight back to the planner; interrupts
(player command, attack) are handed to the agent without using up a retry.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any, Callable

from .interface import GameInterface, Reason
from .jsonl_log import JsonlLogger
from .state_store import StateStore, Task

@dataclass
class Outcome:
    ok: bool
    reason: str | None = None
    attempts: int = 0
    data: dict[str, Any] = field(default_factory=dict)
    interrupt: bool = False


def _inv(state: dict, item: str) -> int:
    return int(state.get("inventory", {}).get(item, 0))


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
        gained = _delta(skill, args, base, post)
        return None if gained >= args["count"] else f"inventory {args[key]} +{gained}, wanted +{args['count']}"
    return check


def _v_give(args, base, post, data):
    given = _delta("give", args, base, post)
    return None if given >= args["count"] else f"only {given} {args['item']} left inventory"


def _v_place(args, base, post, data):
    ids = {s["id"] for s in post.get("structures", [])}
    return None if data.get("structure_id") in ids else "structure not found"


VERIFIERS: dict[str, Callable] = {
    "go_to": _v_go_to,
    "follow": _v_follow,
    "stop": _v_stop,
    "attack": _v_attack,
    "gather": _v_gain("gather"),
    "craft": _v_gain("craft"),
    "give": _v_give,
    "place": _v_place,
}


class Executor:
    def __init__(self, game: GameInterface, store: StateStore, logger: JsonlLogger, max_attempts: int = 3):
        self.game = game
        self.store = store
        self.log = logger
        self.max_attempts = max_attempts
        self._baselines: dict[str, dict] = {}  # task id -> state when the task first started

    def state(self) -> dict:
        res = self.game.get_state()
        if not res["ok"]:
            raise RuntimeError(f"get_state failed: {res['reason']}")
        return res["data"]

    def _remaining_args(self, task: Task, base: dict, now: dict) -> dict | None:
        """Resume count-based skills where they left off; None means already satisfied."""
        if task.skill not in _COUNTED:
            return dict(task.args)
        remaining = task.args["count"] - _delta(task.skill, task.args, base, now)
        return {**task.args, "count": remaining} if remaining > 0 else None

    def run_task(self, task: Task) -> Outcome:
        if task.skill not in self.store.skills:
            return self._finish(task, Outcome(False, Reason.UNKNOWN_SKILL))
        base = self._baselines.setdefault(task.id, self.state())
        reason = None
        while task.attempts < self.max_attempts:
            args = self._remaining_args(task, base, self.state())
            if args is None:
                return self._finish(task, Outcome(True, attempts=task.attempts))
            task.attempts += 1
            task.status = "running"
            self.store.save_tree()
            self.log.log("tool_call", task_id=task.id, tool=task.skill, args=args, attempt=task.attempts)
            result = self.game.call(task.skill, args)
            self.log.log("tool_result", task_id=task.id, tool=task.skill, result=result)

            if not result["ok"]:
                reason = result["reason"]
                if reason in Reason.INTERRUPTS:
                    task.attempts -= 1  # an interrupt is not the skill's fault
                    task.status = "pending"
                    self.store.save_tree()
                    return Outcome(False, reason, task.attempts, result["data"], interrupt=True)
                if reason in Reason.DETERMINISTIC:
                    break
                continue

            verifier = VERIFIERS.get(task.skill)
            problem = verifier(task.args, base, self.state(), result["data"]) if verifier else None
            if problem is None:
                return self._finish(task, Outcome(True, attempts=task.attempts, data=result["data"]))
            reason = f"{Reason.VERIFICATION_FAILED}: {problem}"
            self.log.log("verification_failed", task_id=task.id, tool=task.skill, problem=problem)

        return self._finish(task, Outcome(False, reason, task.attempts))

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

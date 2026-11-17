"""The Planner call in the background while the Controller keeps acting (DW_ASYNC_PLAN=1; default off).

Goal item 1 (docs/GOAL-2026-11-17-long-jobs.md): "the thinking model plans and revises while the fast model keeps
acting; neither waits for the other". Baseline (docs/research/2026-11-17-think-act-baseline.md): the whole gap
around a plan, median 7.84 s, over the 5 s bar in 92 of 93.

What is reused (docs/research/2026-11-17-long-jobs-planner-actor.md, patterns 1, 2 and 7):
  - HLA / DPT-Agent / AgileThinker: the slow model writes a plan, the fast one keeps acting on the freshest
    observation and reads the latest plan when it lands; until then it works from the ask itself.
  - Steering queues: a plan lands at a model boundary (the next Controller turn), never by stopping a tool.
  - PlanFence (arXiv 2609.03340): fresh state alone does not say a plan is still valid; check only what the
    plan's next action depends on. Here: its first step's own effect, and a death since the plan's state.
  - The Director's worker (brain/director.py): a ThreadPoolExecutor, the main loop the only writer of agent
    state.

Code only holds the record and reports it. The model decides what to do while the plan is made, and what to do
with a plan that arrives stale (it is shown, never started by itself).
"""
from __future__ import annotations

import concurrent.futures as cf
import math
import os
import time
from dataclasses import dataclass, field
from typing import Any, Callable

ENV = "DW_ASYNC_PLAN"
AT_TARGET_M = 3.0  # a go_to whose target is this close was done (tools/think_act.py AT_TARGET_M)


def enabled() -> bool:
    return os.environ.get(ENV, "0").strip() == "1"


def _num(v: Any) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def _pos(state: dict | None) -> list[float] | None:
    p = (state or {}).get("position")
    if isinstance(p, (list, tuple)) and len(p) >= 2 and all(_num(x) is not None for x in p[:3]):
        return [float(x) for x in p[:3]]
    return None


def _bag(state: dict | None) -> dict[str, float]:
    inv = (state or {}).get("inventory")
    if isinstance(inv, dict):
        return {str(k): float(v) for k, v in inv.items() if _num(v) is not None}
    if isinstance(inv, list):  # rows {id|name, count}
        out: dict[str, float] = {}
        for r in inv:
            if isinstance(r, dict) and (k := r.get("id") or r.get("name")):
                out[str(k)] = out.get(str(k), 0.0) + float(_num(r.get("count")) or 1)
        return out
    return {}


def _norm(name: str) -> str:
    n = str(name).strip().lower().replace("_", " ")
    return n[:-1] if n.endswith("s") else n


def _count(bag: dict[str, float], item: str) -> float:
    want = _norm(item)
    return sum(v for k, v in bag.items() if _norm(k) == want)


def digest(state: dict | None) -> dict:
    """The state a plan is made on (or lands on), for the log row: position, bag counts, fight, dead."""
    return {"position": _pos(state), "bag": _bag(state), "fight": bool((state or {}).get("fight")),
            "dead": (state or {}).get("dead") is True}


def drift(basis: dict | None, now: dict | None) -> dict:
    """What changed between the plan's state and now, as facts (not a verdict): metres moved, bag changes, a fight."""
    a, b = _pos(basis), _pos(now)
    out: dict = {}
    if a and b:
        out["moved_m"] = round(math.dist(a[:3], b[:3]), 1)
    ba, bb = _bag(basis), _bag(now)
    bag = {k: round(bb.get(k, 0) - ba.get(k, 0), 2) for k in sorted(set(ba) | set(bb)) if bb.get(k, 0) != ba.get(k, 0)}
    if bag:
        out["bag"] = bag
    if (now or {}).get("fight") and not (basis or {}).get("fight"):
        out["fight"] = True
    return out


def _first_done(task, basis: dict | None, now: dict | None) -> str | None:
    """The plan's first step's own effect became true after the plan's state was read (PlanFence: check what the next
    action depends on). A go_to to [x, y, z] he now stands at; a gather / pickup / craft whose item count has grown by
    the step's count. None when it cannot tell or it was already so when the plan was asked for."""
    skill, args = getattr(task, "skill", None), getattr(task, "args", None) or {}
    if skill == "go_to":
        t = args.get("target")
        if isinstance(t, (list, tuple)) and len(t) >= 2 and all(_num(x) is not None for x in t[:2]):
            here, then = _pos(now), _pos(basis)
            d_now = math.dist(here[:2], [float(x) for x in t[:2]]) if here else None
            d_then = math.dist(then[:2], [float(x) for x in t[:2]]) if then else None
            if d_now is not None and d_now <= AT_TARGET_M and (d_then is None or d_then > AT_TARGET_M):
                return f"its first step (go_to {list(t)[:3]}) is done: you stand {d_now:.1f} m from it"
        return None
    if skill in ("gather", "pickup", "craft"):
        item = args.get("resource") or args.get("item") or args.get("recipe")
        n = _num(args.get("count")) or 1.0
        if item:
            grew = _count(_bag(now), str(item)) - _count(_bag(basis), str(item))
            if grew >= n:
                return f"its first step ({skill} {n:g} {item}) is done: you got {grew:g} since it was asked for"
    return None


def stale_reasons(basis: dict | None, now: dict | None, tasks: list, died: bool = False) -> list[str]:
    """Why a plan is too far behind the game to start by itself (empty: it is not). Only two things count: he died
    since its state was read (the plan's position, bag and gear are gone), or its first step's effect is already
    true. Moving, a bag change and a fight are reported as drift, not as staleness."""
    out = []
    if died or ((now or {}).get("dead") is True and (basis or {}).get("dead") is not True):
        out.append("you died after it was asked for")
    if tasks and (why := _first_done(tasks[0], basis, now)):
        out.append(why)
    return out


def step_label(task) -> str:
    args = getattr(task, "args", None) or {}
    bits = ", ".join(f"{k}={v}" for k, v in args.items())
    return f"{getattr(task, 'skill', '?')}({bits})"


@dataclass
class PendingPlan:
    """One Planner call in flight. The worker thread writes only ``future``; the agent loop owns the rest."""
    kind: str  # "plan" | "replan"
    goal: str
    basis: dict
    started: float  # monotonic (agent clock)
    started_wall: float = field(default_factory=time.time)
    future: cf.Future | None = None
    composed_wall: float | None = None  # time.time() when the worker finished (set by the worker)
    acts: list[tuple[float, str]] = field(default_factory=list)  # (wall time, tool) of his body acts meanwhile
    died: bool = False
    shown: str | None = None  # "fresh" | "stale": what the next Controller turn was told when it landed

    def done(self) -> bool:
        return self.future is not None and self.future.done()

    def acted(self, tool: str) -> None:
        self.acts.append((time.time(), tool))

    def acts_while_composed(self) -> list[str]:
        end = self.composed_wall if self.composed_wall is not None else time.time()
        return [t for ts, t in self.acts if ts <= end]


_POOL: cf.ThreadPoolExecutor | None = None


def submit(p: PendingPlan, fn: Callable[[], Any], logger, episode_id: str | None) -> None:
    """Run ``fn`` (the Planner call) on the planner worker. Its rows carry the goal's episode id."""
    global _POOL
    if _POOL is None:
        # two: a call left behind by a replaced job never queues the next job's plan behind it
        _POOL = cf.ThreadPoolExecutor(max_workers=2, thread_name_prefix="planner")

    def work():
        try:
            with logger.episode(episode_id):
                return fn()
        finally:
            p.composed_wall = time.time()

    p.future = _POOL.submit(work)

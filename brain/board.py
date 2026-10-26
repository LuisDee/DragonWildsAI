"""The task board: tasks, steps, segments, tallies and loops, persisted per world in goals.json.

Design: docs/design/director.md sections 2.1, 2.6 and 12 (review docs/reviews/2026-10-25-director-review.md).
The agent loop is the ONLY writer (principle 9): the Director's worker thread never touches this object or the
file; tools/board.py appends to the inbox file, which ``BoardStore.ingest_inbox`` reads.

What "done" means is a predicate (brain/predicates.py) checked by code on fresh state. This module keeps the
bookkeeping those predicates need and that must survive restarts:

* **Segments (review H3, re-check 1).** A step's work is measured only inside board runs: a segment opens right
  before each run and closes right after it. Between runs (chat commands, situation runs) nothing counts. A
  segment's per-item and per-skill deltas are folded into the step's ``accumulated`` deltas; items a nested chat
  command touched during the run are left out (``tainted``).
* **Effective baseline.** Predicates compare fresh state with a baseline. For a step the board hands them a
  synthetic baseline: current inventory / skills minus the step's accumulated deltas, so ``gained`` is exactly
  what board runs gained, whatever happened in between. Gear, position and time come from the activation snapshot.
* **Tallies.** Positive per-segment deltas of the items the task's predicates name, minus re-pickups of his own
  drops (``repicked``), summed over every step and trip.
* **Loops.** A step group with an ``until`` predicate is re-queued by code while ``until`` fails (no model call).
* **One progress budget per task** (simplify item 5). Work that moves nothing spends it (a run without progress,
  a failed attempt, a decision that moved nothing, a loop pass with no gain); real progress on the task (its done
  test's progress or measures, its tallies, a step whose own work grew) refills it. When it is spent the Director
  asks for help. That one rule replaces the per-step attempt and run caps, the replan cap, the loop caps and the
  "3 decisions" rule; the model sees every failure and decides what to try (no step is ever refused).
* **Prerequisite caps:** depth 2, 3 live self-added tasks per parent, duplicates of a stuck one refused with the
  reason (information for the model).
* **Writes:** one compact atomic write per flush (``autoflush=False`` for the Director, which flushes once per tick
  and before each run); the plan key (``plan_key``) is what a pending decision is checked against, not every write.

Nothing here knows any item, creature, place or skill name: items come from predicates, which come from the
model and the game catalogs.
"""
from __future__ import annotations

import copy
import hashlib
import json
import os
import time
import uuid
from pathlib import Path
from typing import Any, Callable, Literal

from pydantic import BaseModel, Field, ValidationError

from . import predicates as P
from .fileio import append_jsonl, atomic_write, read_json, read_new_lines

SCHEMA_V = 1
INBOX_NAME = "board_inbox.jsonl"
GOALS_NAME = "goals.json"
WINDOW_NAME = "director_window.json"
TaskStatus = Literal["queued", "active", "preempted", "paused", "parked", "waiting_help", "waiting_budget",
                     "done", "stuck", "cancelled"]
StepStatus = Literal["pending", "active", "done", "failed", "aborted", "parked", "dropped"]
RUNNABLE = ("active", "preempted", "queued", "waiting_budget")
LIVE = RUNNABLE + ("paused", "parked", "waiting_help")
ENDED = ("done", "stuck", "cancelled")
ITEM_LEAVES = ("have", "gained", "lost", "tally", "on_ground", "equipped")

MAX_PREREQ_DEPTH = 2
MAX_LIVE_CHILDREN = 3
PROGRESS_BUDGET = 8.0  # units of work that moved nothing before the Director asks for help


class BoardError(ValueError):
    """A board operation that can't be done, with a reason the model or the CLI hears."""


def _id() -> str:
    return uuid.uuid4().hex[:8]


# ------------------------------------------------------------------------------ models


class Segment(BaseModel):
    start: float
    end: float | None = None
    baseline: dict = {}  # predicates.snapshot at the segment start (dropped once the segment is closed)
    delta: dict[str, float] = {}  # item id -> signed change, after taint (closed segments only)
    skill_delta: dict[str, list[float]] = {}  # skill key -> [level change, xp change]
    tainted: list[str] = []  # item ids a nested chat command touched (left out)


# The fields a plan gives a step (the Validator's output, a loop pass's copy, a re-planned pending step's update):
# one list, so a new step field is threaded through every place at once.
PLAN_FIELDS = ("title", "why", "hints", "success", "abort_if", "escape", "risk", "needs", "group", "wait",
               "first_call")


class Step(BaseModel):
    id: str = Field(default_factory=_id)
    title: str
    why: str = ""
    hints: str = ""
    success: dict  # a validated predicate
    abort_if: dict | None = None
    escape: str | None = None
    risk: str | None = None
    prepared: bool = False  # a prepare decision covered this risky step (section 2.9)
    needs: list[str] = []
    group: str | None = None
    loop_iter: int = 0  # which pass of its loop group this copy belongs to
    tally_gain: float = 0.0  # tally gains this step's segments added
    trivial: bool = False
    wait: bool = False  # nothing to do but let time pass: re-checked each tick, no Controller run
    first_call: dict | None = None  # {tool, args} the plan starts the step with (run before the Controller)
    status: StepStatus = "pending"
    attempts: int = 0
    runs: int = 0  # counted runs
    uncounted_runs: int = 0  # runs ended by chat / interrupts (re-check 3)
    activation: dict = {}  # snapshot when the step first activated (gear, position, t)
    segments: list[Segment] = []
    accumulated: dict[str, float] = {}  # item id -> signed change over closed segments
    skill_accumulated: dict[str, list[float]] = {}  # skill key -> [levels, xp]
    kills: list[dict] = []  # combat_end episodes seen during this step's board segments
    last_measures: dict[str, float] = {}
    no_progress_runs: int = 0
    failures: list[dict] = []
    actions: list[dict] = []  # board-origin action records of the current attempt
    started: float | None = None
    ended: float | None = None

    @property
    def open_segment(self) -> Segment | None:
        return self.segments[-1] if self.segments and self.segments[-1].end is None else None


class Loop(BaseModel):
    until: dict
    done: int = 0
    last_measures: dict[str, float] = {}


class Help(BaseModel):
    question: str
    asked_at: float | None = None
    asked_player: str | None = None
    revoice_pending: bool = False


class Task(BaseModel):
    id: str = Field(default_factory=_id)
    text: str
    by: str  # player:<name> | cli | self
    parent: str | None = None
    depth: int = 0
    because: str | None = None
    kind: Literal["specific", "open"] = "specific"
    status: TaskStatus = "queued"
    paused_by: str | None = None
    success: dict | None = None  # {predicate, set_at, set_by, trivial}
    tallies: dict[str, float] = {}
    my_drops: list[dict] = []  # [{world_item, item, count}] from his own drop results in this task
    stored: list[dict] = []  # [{item, count, container, container_name, step, run}] his verified store results
    steps: list[Step] = []
    loops: dict[str, Loop] = {}
    spent: float = 0.0  # of the progress budget
    mark: dict = {}  # {progress, measures, tallies} at the last progress (what "moved" is measured against)
    history: list[dict] = []
    notes_from_player: list[str] = []
    help: Help | None = None
    created: float = Field(default_factory=time.time)
    ended: float | None = None
    end_reason: str | None = None

    def pending(self) -> list[Step]:
        return [s for s in self.steps if s.status == "pending"]

    def active_step(self) -> Step | None:
        return next((s for s in self.steps if s.status == "active"), None)

    def next_step(self) -> Step | None:
        return self.active_step() or next(iter(self.pending()), None)


class Board(BaseModel):
    v: int = SCHEMA_V
    current: str | None = None
    paused: dict | None = None  # {by, reason, at}: pause_board until resume_board
    inbox_offset: int = 0
    awaiting_decision: dict | None = None  # {task_id, kind, since, detail}
    tasks: list[Task] = []

    def task(self, task_id: str | None) -> Task | None:
        return next((t for t in self.tasks if t.id == task_id), None) if task_id else None

    def current_task(self) -> Task | None:
        return self.task(self.current)

    def live(self) -> list[Task]:
        return [t for t in self.tasks if t.status in LIVE]


# ------------------------------------------------------------------------------ store


class BoardStore:
    """goals.json + the CLI inbox for one world. ``save`` marks the board dirty and writes at once unless
    ``autoflush`` is off (the Director then calls ``flush`` once per tick). A failed write keeps the in-memory board
    (``save_failed``, logged). ``readonly`` (tools/board.py) never writes, quarantines or creates anything."""

    def __init__(self, directory: Path, log=None, clock: Callable[[], float] = time.time, autoflush: bool = True,
                 readonly: bool = False):
        self.dir = Path(directory)
        self.readonly = readonly
        if not readonly:
            self.dir.mkdir(parents=True, exist_ok=True)
        self.path = self.dir / GOALS_NAME
        self.inbox = self.dir / INBOX_NAME
        self.log = log
        self.clock = clock
        self.autoflush = autoflush
        self.quarantined: Path | None = None
        self.save_failed = False
        self.dirty = False
        self.board = self._load()
        self._status: dict[str, str] = {t.id: t.status for t in self.board.tasks}  # last logged status per task

    def _log(self, kind: str, **data: Any) -> None:
        if self.log is not None:
            self.log.log(kind, **data)

    def _log_transitions(self) -> None:
        """board_task_status {task, from, to, why} for every task whose status changed since the last write (the
        observability agent's gap/idle metrics: waiting_budget, preempted, paused, parked, ... and the ends)."""
        for t in self.board.tasks:
            before = self._status.get(t.id)
            if before != t.status:
                self._status[t.id] = t.status
                self._log("board_task_status", task=t.id, **{"from": before, "to": t.status},
                          why=t.end_reason if t.status in ("parked", "waiting_help", "done", "stuck", "cancelled")
                          else (t.paused_by if t.status == "paused" else None))

    def _load(self) -> Board:
        raw = read_json(self.path, default=None) if self.path.exists() else {}
        try:
            if not isinstance(raw, dict) or int(raw.get("v", SCHEMA_V)) > SCHEMA_V:
                raise ValueError(f"unknown schema v={raw.get('v') if isinstance(raw, dict) else '?'}")
            return Board.model_validate(raw)
        except (ValueError, ValidationError) as exc:  # review M2a: never stop the brain over it
            if self.readonly:
                return Board()
            bad = self.path.with_name(f"{GOALS_NAME}.bad-{int(self.clock())}")
            try:
                os.replace(self.path, bad)
                self.quarantined = bad
            except OSError:
                pass
            self._log("board_quarantined", error=str(exc)[:300], moved_to=str(bad))
            return Board()

    def save(self) -> bool:
        self.dirty = True
        return self.flush() if self.autoflush else True

    def flush(self) -> bool:
        if not self.dirty or self.readonly:
            return True
        self._log_transitions()
        try:
            atomic_write(self.path, self.board.model_dump_json())
            self.dirty = self.save_failed = False
            return True
        except OSError as exc:
            self.save_failed = True
            self._log("board_save_failed", error=repr(exc))
            return False

    # ---------------------------------------------------------------- the CLI inbox (review M2d)

    def ingest_inbox(self, add: Callable[[dict], Any]) -> int:
        """Apply new complete lines of the inbox through ``add(record)``; the new offset is written in the same
        atomic write as the tasks they created, so a crash never ingests a line twice."""
        rows, offset, bad = read_new_lines(self.inbox, self.board.inbox_offset)
        if offset == self.board.inbox_offset and not rows:
            return 0
        for line in bad:
            self._log("board_inbox_bad_line", line=line[:200])
        n = 0
        for rec in rows:
            try:
                add(rec)
                n += 1
            except BoardError as exc:
                self._log("board_inbox_refused", record=rec, why=str(exc))
        self.board.inbox_offset = offset
        self.dirty = True
        self.flush()
        return n


def append_inbox(directory: Path, record: dict) -> None:
    """For tools/board.py: one line per command, appended (the brain is the only writer of goals.json)."""
    append_jsonl(Path(directory) / INBOX_NAME, {"ts": round(time.time(), 3), **record})


# ------------------------------------------------------------------------------ predicate helpers


def predicate_items(p: dict | None) -> set[str]:
    """Item ids a predicate names (the tally counts only these)."""
    if not p:
        return set()
    out: set[str] = set()
    for k, a in P.leaves(p):
        if k in ITEM_LEAVES or (k not in P.BUILTIN_LEAVES and isinstance(a, dict)):  # registered leaves too
            out.update(a.get("ids") or [])
    return out


def task_items(task: Task) -> set[str]:
    items = predicate_items((task.success or {}).get("predicate"))
    for lp in task.loops.values():
        items |= predicate_items(lp.until)
    for s in task.steps:
        items |= predicate_items(s.success)
    return items


def _inventory(state: dict) -> dict[str, float]:
    inv = state.get("inventory") if isinstance(state, dict) else None
    return {k: float(v or 0) for k, v in inv.items()} if isinstance(inv, dict) else {}


def _skill_map(state: dict) -> dict[str, tuple[float, float | None]]:
    return P._skill_rows(state) or {}


# ------------------------------------------------------------------------------ board operations


class BoardOps:
    """Board operations for the agent loop (the Director's tick, the board tools, the CLI ingest)."""

    def __init__(self, store: BoardStore, clock: Callable[[], float] = time.time):
        self.store = store
        self.clock = clock

    @property
    def b(self) -> Board:
        return self.store.board

    def save(self) -> None:
        self.store.save()

    # ---------------------------------------------------------------- tasks

    def add_task(self, text: str, by: str, when: str = "later", parent: str | None = None,
                 because: str | None = None, kind: str = "specific") -> Task:
        text = (text or "").strip()
        if not text:
            raise BoardError("a task needs text")
        if when not in ("now", "next", "later"):
            raise BoardError("when must be now, next or later")
        depth = 0
        if by == "self":
            par = self.b.task(parent) if parent else self.b.current_task()
            if par is None:
                raise BoardError("a prerequisite needs the task it is for (parent)")
            parent, depth = par.id, par.depth + 1
            if depth > MAX_PREREQ_DEPTH:
                raise BoardError(f"prerequisites can only be {MAX_PREREQ_DEPTH} deep; ask for help instead")
            kids = [t for t in self.b.tasks if t.parent == par.id]
            if sum(1 for t in kids if t.status in LIVE) >= MAX_LIVE_CHILDREN:
                raise BoardError(f"'{par.text}' already has {MAX_LIVE_CHILDREN} open prerequisites")
            same = [t for t in kids if t.text.strip().lower() == text.lower()]
            if any(t.status in ("stuck", "waiting_help", "parked") for t in same):
                raise BoardError(f"the same prerequisite is already stuck: {same[0].end_reason or same[0].status}")
            if any(t.status in LIVE for t in same):
                raise BoardError("that prerequisite is already on the board")
        task = Task(text=text, by=by, parent=parent, depth=depth, because=because,
                    kind="open" if kind == "open" else "specific")
        live = self.b.live()
        others = [t for t in self.b.tasks if t.status not in LIVE]
        cur = self.b.current_task()
        if when == "now":
            if cur is not None and cur.status == "active":
                cur.status = "preempted"
            live.insert(0, task)
            self.b.current = task.id
            task.status = "active"
        elif when == "next" or by == "self":  # a prerequisite runs before the task it serves
            i = live.index(cur) + (0 if by == "self" else 1) if cur in live else 0
            live.insert(i, task)
            if by == "self" and cur is not None:
                if cur.status == "active":
                    cur.status = "preempted"
                self.b.current, task.status = task.id, "active"
        else:
            live.append(task)
        self.b.tasks = live + others
        self.save()
        return task

    def cancel(self, task_id: str | None, reason: str = "") -> Task:
        t = self.b.task(task_id) if task_id else self.b.current_task()
        if t is None:
            raise BoardError(f"no task {task_id!r} on the board" if task_id else "no current task")
        if t.status in ENDED:
            raise BoardError(f"'{t.text}' has already ended ({t.status})")
        self.end_task(t, "cancelled", reason or "cancelled")
        for kid in [k for k in self.b.tasks if k.parent == t.id and k.status in LIVE]:
            self.end_task(kid, "cancelled", f"its task '{t.text}' was cancelled")
        self.save()
        return t

    def end_task(self, t: Task, status: str, reason: str) -> None:
        t.status, t.ended, t.end_reason = status, self.clock(), reason
        step = t.active_step()
        if step is not None:
            step.status, step.ended = "dropped", self.clock()
            self._step_end(t, step, reason)
        if self.b.current == t.id:
            self.b.current = None
        self.save()

    def pick_current(self) -> Task | None:
        """The task to work on now: the current one if it can run, else the first runnable queued task.
        Parked / waiting_help tasks are skipped (review M1) and keep their place."""
        cur = self.b.current_task()
        if cur is not None and cur.status in RUNNABLE:
            return cur
        nxt = next((t for t in self.b.tasks if t.status in RUNNABLE), None)
        if nxt is not None and nxt.id != self.b.current:
            self.b.current = nxt.id
            if nxt.status == "queued":
                nxt.status = "active"
            self.save()
        elif nxt is None and self.b.current is not None and (cur is None or cur.status in ENDED):
            self.b.current = None
            self.save()
        return nxt

    def yield_open(self) -> bool:
        """At a curriculum boundary an open task yields to a queued specific one (review M1)."""
        cur = self.b.current_task()
        if cur is None or cur.kind != "open":
            return False
        other = next((t for t in self.b.tasks if t.status == "queued" and t.kind == "specific"), None)
        if other is None:
            return False
        cur.status = "queued"
        self.b.tasks.remove(other)
        self.b.tasks.insert(0, other)
        self.b.current, other.status = other.id, "active"
        self.save()
        return True

    def park(self, t: Task, reason: str, question: str | None = None, player: str | None = None) -> None:
        t.status, t.end_reason = ("waiting_help" if question else "parked"), reason
        if question:
            t.help = Help(question=question, asked_player=player, asked_at=self.clock())
        if self.b.current == t.id:
            self.b.current = None
        self.save()

    def pause(self, by: str, reason: str) -> None:
        self.b.paused = {"by": by, "reason": reason, "at": self.clock()}
        cur = self.b.current_task()
        if cur is not None and cur.status in ("active", "preempted"):
            cur.status, cur.paused_by = "paused", by
        self.save()

    def resume(self, note: str | None = None) -> Task | None:
        """Lift a pause; a note (a player's answer) goes to the task it answers: the newest waiting_help task,
        else the current one. That task becomes current again, with a fresh progress budget."""
        self.b.paused = None
        target = next((t for t in sorted(self.b.tasks, key=lambda t: (t.help.asked_at or 0) if t.help else 0,
                                         reverse=True) if t.status == "waiting_help"), None)
        target = target or self.b.current_task() or next(iter(self.b.live()), None)
        for t in self.b.tasks:
            if t.status == "paused":
                t.status, t.paused_by = "queued", None
        if target is not None:
            if note:
                target.notes_from_player.append(note.strip()[:500])
            if target.status in ("waiting_help", "parked", "paused", "queued", "preempted"):
                target.status = "active"
                target.spent = 0.0
            self.b.tasks.remove(target)
            self.b.tasks.insert(0, target)
            self.b.current = target.id
        self.save()
        return target

    def preempt(self) -> None:
        cur = self.b.current_task()
        if cur is not None and cur.status == "active":
            cur.status = "preempted"
            self.save()

    def plan_key(self, t: Task | None) -> str | None:
        """What a pending decision about ``t`` depends on: whether it still runs, its done test, its steps and the
        player's notes. Preemption, segments, tallies and window writes don't change it (simplify item 1)."""
        if t is None:
            return None
        bucket = t.status if t.status in ENDED or t.status in ("paused", "parked", "waiting_help") else "live"
        blob = json.dumps({"s": bucket, "ok": t.success, "steps": [(s.id, s.status) for s in t.steps],
                           "notes": len(t.notes_from_player), "paused": bool(self.b.paused)}, sort_keys=True,
                          default=str)
        return hashlib.sha1(blob.encode("utf-8")).hexdigest()

    # ---------------------------------------------------------------- success and steps

    def set_success(self, t: Task, predicate: dict, by: str, state: dict | None = None) -> bool:
        """The task's definition of done is set once (review H1); only a player may change it. Returns
        whether it was set. A predicate already true now is stored as trivial (information, not a veto)."""
        if t.success is not None and by != "player":
            return False
        trivial = bool(state is not None and P.evaluate(predicate, state, self.task_ctx(t, state)).passed is True)
        t.success = {"predicate": predicate, "set_at": self.clock(), "set_by": by, "trivial": trivial}
        self.save()
        return True

    def set_steps(self, t: Task, steps: list[Step], loops: dict[str, Loop] | None = None,
                  replace_active: bool = True) -> None:
        """Replace the pending steps (done/failed ones stay). A review may not replace the active one."""
        active = t.active_step()
        if active is not None and replace_active:
            active.status, active.ended = "dropped", self.clock()
        t.steps = [s for s in t.steps if s.status != "pending"] + steps
        for g, lp in (loops or {}).items():
            old = t.loops.get(g)
            t.loops[g] = old if old is not None and old.until == lp.until else lp
        self.save()

    def activate(self, step: Step, state: dict) -> None:
        step.status = "active"
        step.attempts += 1
        step.runs = step.uncounted_runs = step.no_progress_runs = 0
        step.actions = []
        if not step.activation:
            step.activation = P.snapshot(state, t=self.clock())
            step.started = self.clock()
        self.save()

    # ---------------------------------------------------------------- segments (re-check 1)

    def open_segment(self, step: Step, state: dict) -> Segment:
        if step.open_segment is not None:
            return step.open_segment
        seg = Segment(start=self.clock(), baseline=P.snapshot(state, t=self.clock()))
        step.segments.append(seg)
        return seg

    def close_segment(self, t: Task, step: Step, state: dict, tainted: set[str] | None = None,
                      repicked: dict[str, float] | None = None) -> dict[str, float]:
        """Fold the open segment's deltas into the step and its positive gains into the task's tallies.
        ``tainted`` = item ids a nested chat command touched (dropped from the delta); ``repicked`` = counts of
        his own earlier drops picked up again (not new gains)."""
        seg = step.open_segment
        if seg is None:
            return {}
        seg.end = self.clock()
        before, after = _inventory(seg.baseline), _inventory(state)
        delta = {i: after.get(i, 0.0) - before.get(i, 0.0) for i in set(before) | set(after)}
        delta = {i: d for i, d in delta.items() if d and i not in (tainted or set())}
        seg.delta, seg.tainted = delta, sorted(tainted or [])
        for i, d in delta.items():
            step.accumulated[i] = step.accumulated.get(i, 0.0) + d
        s0, s1 = _skill_map(seg.baseline), _skill_map(state)
        for k in set(s0) & set(s1):
            dl = s1[k][0] - s0[k][0]
            dx = (s1[k][1] - s0[k][1]) if s1[k][1] is not None and s0[k][1] is not None else 0.0
            if dl or dx:
                seg.skill_delta[k] = [dl, dx]
                acc = step.skill_accumulated.setdefault(k, [0.0, 0.0])
                acc[0] += dl
                acc[1] += dx
        seg.baseline = {}  # its deltas are folded in; the snapshot is no longer needed (simplify item 15)
        named = task_items(t)
        gains = {}
        for i, d in delta.items():
            if d > 0 and i in named:
                g = max(0.0, d - float((repicked or {}).get(i, 0.0)))
                if g:
                    t.tallies[i] = t.tallies.get(i, 0.0) + g
                    gains[i] = g
        step.tally_gain += sum(gains.values())
        self.save()
        return gains

    def effective_baseline(self, step: Step, state: dict, include_open: bool = False) -> dict:
        """The baseline predicates see for a step: now minus what board runs changed (inventory and skills), with
        gear / position / time from the activation snapshot (docs/design/director.md section 2.1). With
        ``include_open`` the run in progress counts too (its segment's start stands in for now)."""
        base = copy.deepcopy(step.activation) if step.activation else P.snapshot(state)
        seg = step.open_segment if include_open else None
        if seg is not None and seg.baseline:
            state = {**state, "inventory": seg.baseline.get("inventory") or {},
                     **({"skills": seg.baseline["skills"]} if isinstance(seg.baseline.get("skills"), list) else {})}
        inv = _inventory(state)
        base["inventory"] = {i: inv.get(i, 0.0) - step.accumulated.get(i, 0.0)
                             for i in set(inv) | set(step.accumulated)}
        rows = state.get("skills") if isinstance(state.get("skills"), list) else None
        if rows is not None:
            out = []
            for r in rows:
                if not isinstance(r, dict):
                    continue
                acc = step.skill_accumulated.get(P._skill_key(r.get("skill") or r.get("name")), [0.0, 0.0])
                row = dict(r)
                if isinstance(r.get("level"), (int, float)):
                    row["level"] = r["level"] - acc[0]
                if isinstance(r.get("xp"), (int, float)):
                    row["xp"] = r["xp"] - acc[1]
                out.append(row)
            base["skills"] = out
        return base

    def step_ctx(self, t: Task, step: Step, state: dict, places: dict | None = None, include_open: bool = False) -> dict:
        return {"baseline": self.effective_baseline(step, state, include_open), "tallies": dict(t.tallies), "places": places or {},
                "episodes": list(step.kills), "now": self.clock(),
                "stored": [r for r in t.stored if r.get("step") == step.id]}

    def task_ctx(self, t: Task, state: dict, places: dict | None = None) -> dict:
        first = next((s for s in t.steps if s.activation), None)
        return {"baseline": copy.deepcopy(first.activation) if first else P.snapshot(state, t=t.created),
                "tallies": dict(t.tallies), "places": places or {},
                "episodes": [k for s in t.steps for k in s.kills], "now": self.clock(), "stored": list(t.stored)}

    def note_kill(self, step: Step, episode: dict) -> None:
        if step.open_segment is not None:
            step.kills.append({k: episode.get(k) for k in ("kind", "target", "target_id", "target_class",
                                                           "target_kind", "outcome") if k in episode})

    def note_stored(self, t: Task, step: Step, rows: list[dict]) -> None:
        """Items his own store actions put into a container during this run (the tool verified the container's
        contents itself). One run = one trip for ``stored.trips_at_least``."""
        run = f"{step.id}:{len(step.segments)}"
        for r in rows:
            if r.get("item") and r.get("count"):
                t.stored.append({"item": r["item"], "count": float(r["count"]), "container": r.get("container"),
                                 "container_name": r.get("container_name"), "step": step.id, "run": run})
        if rows:
            self.save()

    def note_drop(self, t: Task, world_items: list, item: str | None, count: int | None) -> None:
        for w in world_items or []:
            t.my_drops.append({"world_item": str(w), "item": item, "count": count})

    def repicked(self, t: Task, picked_world_items: list[str]) -> dict[str, float]:
        """Counts per item of his OWN earlier drops among picked-up world items."""
        mine = {d["world_item"]: d for d in t.my_drops}
        out: dict[str, float] = {}
        for w in picked_world_items or []:
            d = mine.get(str(w))
            if d and d.get("item"):
                out[d["item"]] = out.get(d["item"], 0.0) + float(d.get("count") or 1)
        return out

    # ---------------------------------------------------------------- steps and loops

    def _step_end(self, t: Task, step: Step, reason: str | None) -> None:
        self.store._log("board_step_end", task=t.id, step_id=step.id, step=step.title, status=step.status,
                        reason=reason, runs=step.runs,
                        seconds=round((step.ended or self.clock()) - (step.started or self.clock()), 1))

    def finish_step(self, t: Task, step: Step, status: str, reason: str | None = None) -> None:
        step.status, step.ended = status, self.clock()
        self._step_end(t, step, reason)
        if reason:
            step.failures.append({"reason": reason, "at": self.clock(), "attempt": step.attempts})
        t.history.append({"title": step.title, "outcome": status, "reason": reason,
                          "seconds": round(self.clock() - (step.started or self.clock()), 1)})
        t.history = t.history[-30:]
        self.save()

    def requeue_loop(self, t: Task, step: Step, state: dict, places: dict | None = None) -> tuple[str, bool]:
        """After a step of a loop group is done: ('continue', -) when more steps of the group are left,
        ('ended', -) when ``until`` passed, else ('requeued', gained): the group is queued again, and ``gained``
        says whether this pass moved anything (the Director spends the progress budget on a pass that didn't)."""
        g = step.group
        if not g or g not in t.loops:
            return "continue", True
        group = [s for s in t.steps if s.group == g]
        if any(s.status in ("pending", "active") for s in group):
            return "continue", True
        lp = t.loops[g]
        res = P.evaluate(lp.until, state, self.task_ctx(t, state, places))
        if res.passed is True:
            return "ended", True
        it = max(s.loop_iter for s in group)
        gained = sum(s.tally_gain for s in group if s.loop_iter == it) > 0 or P.grew(lp.last_measures, res.measures)
        lp.last_measures = dict(res.measures)
        lp.done += 1
        t.steps.extend(Step(**{f: copy.deepcopy(getattr(s, f)) for f in PLAN_FIELDS}, loop_iter=it + 1)
                       for s in group if s.loop_iter == it)  # one pass of the group, in order (fresh runtime state)
        self.save()
        return "requeued", gained

    # ---------------------------------------------------------------- the progress budget (simplify item 5)

    def progressed(self, t: Task, state: dict, places: dict | None = None, step_grew: bool = False) -> bool:
        """Did the task move since the last mark (its done test's progress or measures, its tallies, or a step
        whose own work grew)? A move refills the budget and sets a new mark."""
        pred = (t.success or {}).get("predicate")
        r = P.evaluate(pred, state, self.task_ctx(t, state, places)) if pred else None
        now = {"progress": r.progress if r else None, "measures": dict(r.measures) if r else {},
               "tallies": dict(t.tallies)}
        m = t.mark
        moved = step_grew or (not m) or P.grew(m.get("measures"), now["measures"]) or \
            P.grew(m.get("tallies"), now["tallies"]) or (
                now["progress"] is not None and m.get("progress") is not None and now["progress"] > m["progress"] + 1e-6)
        if moved:
            t.mark, t.spent = now, 0.0
            self.save()
        return moved

    def spend(self, t: Task, units: float, why: str) -> bool:
        """Spend the task's progress budget on work that moved nothing; True when it is used up."""
        t.spent = round(t.spent + units, 3)
        t.history = (t.history + [{"title": "no progress", "outcome": f"spent {units:g}", "reason": why}])[-30:]
        self.save()
        return t.spent >= PROGRESS_BUDGET

    # ---------------------------------------------------------------- views

    def brief(self, state: dict | None = None, places: dict | None = None, limit: int = 6) -> dict:
        """What the Controller sees about the board (and what `board()` / the CLI show)."""
        out: dict[str, Any] = {"paused": self.b.paused, "tasks": []}
        for t in self.b.live()[:limit]:
            row: dict[str, Any] = {"id": t.id, "task": t.text, "by": t.by, "status": t.status}
            if t.because:
                row["because"] = t.because
            if t.success:
                row["done_when"] = P.describe(t.success["predicate"])
                if t.success.get("trivial"):
                    row["done_when_trivial"] = True
                if state is not None:
                    row["progress"] = P.evaluate(t.success["predicate"], state, self.task_ctx(t, state, places)).detail
            step = t.next_step()
            if step is not None:
                row["step"] = step.title
                if state is not None and step.status == "active":
                    row["step_progress"] = P.evaluate(step.success, state, self.step_ctx(t, step, state, places)).detail
            if t.tallies:
                row["collected"] = dict(t.tallies)
            if t.help:
                row["asked"] = t.help.question
            if t.end_reason and t.status in ("parked", "waiting_help", "paused"):
                row["why"] = t.end_reason
            out["tasks"].append(row)
        if self.b.current:
            out["current"] = self.b.current
        return out


# ------------------------------------------------------------------------------ the Director's hourly window


class HourlyWindow:
    """At most ``per_hour`` model requests in any sliding hour, in its own small file next to the board
    (``director_window.json``; simplify item 1: not part of the plan). The daily dollar cap is brain/budget.py's."""

    def __init__(self, path: Path, per_hour: int | None = None, clock: Callable[[], float] = time.time):
        self.path = Path(path)
        self.per_hour = int(per_hour if per_hour is not None else os.environ.get("DW_DIRECTOR_CALLS_PER_HOUR", "20"))
        self.clock = clock
        raw = read_json(self.path, default={}) or {}
        self.calls: list[float] = [float(c) for c in raw.get("calls") or [] if isinstance(c, (int, float))]

    def _prune(self) -> list[float]:
        now = self.clock()
        self.calls = [c for c in self.calls if now - c < 3600.0]
        return self.calls

    def left(self) -> int:
        return max(0, self.per_hour - len(self._prune()))

    def allows(self, n: int = 1) -> bool:
        return self.left() >= n

    def spend(self, n: int = 1) -> None:
        self._prune()
        self.calls.extend([self.clock()] * n)
        atomic_write(self.path, json.dumps({"schema": "dw_director_window/1", "calls": self.calls}))

    def wait_s(self) -> float:
        """Seconds until one more request is allowed (0 when one is allowed now)."""
        calls = sorted(self._prune())
        if len(calls) < self.per_hour:
            return 0.0
        return max(0.0, calls[len(calls) - self.per_hour] + 3600.0 - self.clock())


def apply_inbox_record(ops: BoardOps, rec: dict) -> Task | None:
    """One tools/board.py command: {"op": "add", "text", "when"?, "kind"?} | {"op": "cancel", "id", "reason"?}."""
    op = rec.get("op")
    if op == "add":
        return ops.add_task(str(rec.get("text") or ""), by="cli", when=str(rec.get("when") or "later"),
                            kind=str(rec.get("kind") or "specific"))
    if op == "cancel":
        return ops.cancel(str(rec.get("id") or "") or None, str(rec.get("reason") or "cancelled from the CLI"))
    raise BoardError(f"unknown inbox op {op!r}")

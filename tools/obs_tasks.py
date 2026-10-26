"""Long-task timelines: per-step runs, gaps between steps and idle time for board jobs (Director) and benchmark
T2/T3 cases. Used by ``tools/obs.py task`` and ``obs metrics --json`` (docs/design/observability.md, "Long tasks").

Vocabulary (adapted from process mining: cycle time = processing + waiting + idle):
  step     one board step (subtask): its runs (board_run_start/Controller board_step prompt -> board_run), outcome.
  gap      from a step's predicate passing (board_run passed / board_step_end done) to the NEXT step's first
           world-changing body action (an executor tool call other than stop/say/remember), split into
             thinking  this job's own model time: Director decisions (dispatch -> decision), board-run model calls
                       and their read tools
             waiting   queue: another episode's work (chat, situation reviews) / budget: the task waiting for the
                       Director's call window (board_task_status waiting_budget, or a budget notice until the next
                       dispatch) / decision pickup / step wait: a wait step (board_wait_start -> board_step_end, e.g.
                       a crop growing) that the board re-checks each tick
             body      this job's own body actions that don't count as a first action (stop, say, ...)
             dead      nothing at all happening
  idle     share of the task's wall time with no body action in progress and no model call in flight (any episode),
           plus the longest idle stretch and the rows around it.

Sources: brain JSONL rows only, optional goals.json for step outcomes/titles. Rows the Director agent may add
(board_run_start, board_step_end, board_task_status, step_id/run on board_run, episode ids "board-") are used when
present; without them the run start is the Controller prompt whose body_event is the board_step.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

TRIVIAL_ACTIONS = {"stop", "say", "remember", "forget_skill"}
DECISION_END = ("director_decision", "director_decision_failed", "director_discarded", "director_timeout")
ENDED = ("done", "stuck", "cancelled")


# ------------------------------------------------------------------ interval arithmetic
def union(iv: list[tuple[float, float]]) -> list[tuple[float, float]]:
    out: list[list[float]] = []
    for a, b in sorted((a, b) for a, b in iv if b > a):
        if out and a <= out[-1][1]:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return [(a, b) for a, b in out]


def clip(iv: list[tuple[float, float]], a: float, b: float) -> list[tuple[float, float]]:
    return [(max(x, a), min(y, b)) for x, y in iv if min(y, b) > max(x, a)]


def minus(iv: list[tuple[float, float]], cut: list[tuple[float, float]]) -> list[tuple[float, float]]:
    out = []
    cut = union(cut)
    for a, b in union(iv):
        cur = a
        for x, y in cut:
            if y <= cur or x >= b:
                continue
            if x > cur:
                out.append((cur, x))
            cur = max(cur, y)
        if cur < b:
            out.append((cur, b))
    return out


def length(iv: list[tuple[float, float]]) -> float:
    return sum(b - a for a, b in union(iv))


# ------------------------------------------------------------------ model
@dataclass
class Run:
    start: float
    end: float | None = None
    run: int | None = None
    passed: bool | None = None
    ended: str | None = None
    actions: list[dict] = field(default_factory=list)   # [{tool, ok, reason, ts, end}]


@dataclass
class StepT:
    title: str
    step_id: str | None
    runs: list[Run] = field(default_factory=list)
    outcome: str | None = None          # done | failed | aborted | parked | dropped | unfinished
    reason: str | None = None
    end: float | None = None            # predicate done (or the step's end row / last run end)
    wait_from: float | None = None      # a wait step (board_wait_start): no runs, the board re-checks its test each tick

    @property
    def start(self) -> float:
        if self.runs:
            return min(self.runs[0].start, self.wait_from or self.runs[0].start)
        return self.wait_from if self.wait_from is not None else (self.end or 0.0)

    def first_world_action(self) -> float | None:
        return next((a["ts"] for r in self.runs for a in r.actions if a["tool"] not in TRIVIAL_ACTIONS), None)


@dataclass
class TaskT:
    id: str
    text: str | None = None
    by: str | None = None
    status: str | None = None
    start: float | None = None
    end: float | None = None
    steps: list[StepT] = field(default_factory=list)
    decisions: list[dict] = field(default_factory=list)   # [{kind, start, end, outcome, steps}]
    budget: list[tuple[float, float]] = field(default_factory=list)
    waits: list[tuple[float, float]] = field(default_factory=list)  # wait steps: board_wait_start -> board_step_end
    gaps: list[dict] = field(default_factory=list)
    lead_in: dict | None = None
    idle: dict | None = None
    file: str | None = None


def _ctx(rec: dict) -> dict | None:
    msgs = rec.get("messages") or []
    last = msgs[-1] if msgs else {}
    content = last.get("content") if isinstance(last, dict) else None
    if not isinstance(content, str) or not content.startswith("{"):
        return None
    try:
        d = json.loads(content)
    except ValueError:
        return None
    return d if isinstance(d, dict) else None


def _owner_of_id(rec: dict) -> str | None:
    """Owner from the brain's episode id prefix (board-/director-/goal- = this job; chat- = a player; others = body)."""
    eid = str(rec.get("episode_id") or "")
    if not eid:
        return None
    pre = eid.split("-", 1)[0]
    return {"board": "board", "director": "director", "goal": "board", "chat": "chat"}.get(pre, "body")


def _owner_of_prompt(rec: dict, ctx: dict | None) -> str | None:
    """board | director | chat | body for a decide prompt; None for a continuation prompt (keeps the owner)."""
    eid = str(rec.get("episode_id") or "")
    if rec.get("component") == "director" or eid.startswith("director"):
        return "director"
    if ctx is None or not isinstance(ctx.get("command"), dict):
        return None
    be = ctx.get("body_event") or {}
    if isinstance(be, dict) and be.get("type") in ("board_step", "board_notice"):
        return "board"
    if eid.startswith("board"):
        return "board"
    return "chat" if (ctx["command"].get("text") or "") else "body"


def build(rows: list[dict], goals: dict | None = None) -> tuple[list[TaskT], dict]:
    """Tasks plus the activity intervals: {"think_own", "queue", "actions", "busy"} (lists of (a, b))."""
    tasks: dict[str, TaskT] = {}
    order: list[str] = []
    text_to_id: dict[str, str] = {}
    pending_runs: list[dict] = []          # run starts not yet closed by a board_run
    open_prompt: dict[str, tuple[float, str | None]] = {}
    director_open: dict[str, tuple[float, str]] = {}  # director episode -> (last prompt/response ts, task)
    open_read: tuple[float, str | None] | None = None
    open_actions: dict[str, tuple[float, dict, str | None, Run | None]] = {}
    open_dispatch: dict[str, tuple[float, str]] = {}
    budget_open: dict[str, float] = {}
    notice_budget: dict[str, float] = {}
    owner: str | None = None
    iv: dict = {"think_own": [], "queue": [], "actions": [], "busy": [], "director_model": {}, "director_window": {}}

    def task(tid: str, ts: float, file: str | None = None) -> TaskT:
        if tid not in tasks:
            tasks[tid] = TaskT(tid, start=ts, file=file)
            order.append(tid)
        t = tasks[tid]
        t.start = min(t.start or ts, ts)
        return t

    def add_iv(a: float, b: float, who: str | None, kind: str) -> None:
        iv["busy"].append((a, b))
        if kind == "action":
            iv["actions"].append((a, b))
        if who in ("chat", "body"):
            iv["queue"].append((a, b))
        elif kind != "action":
            iv["think_own"].append((a, b))

    def step_of(t: TaskT, title: str, step_id: str | None, any_outcome: bool = False) -> StepT:
        """The step a row is about: by step_id; else the latest open step with that title (a finished one starts a new
        loop copy), or for an end row (``any_outcome``) the latest step with that title."""
        for s in reversed(t.steps):
            if step_id and s.step_id == step_id:
                return s
            if not step_id and s.title == title and (any_outcome or s.outcome is None):
                return s
        s = StepT(title, step_id)
        t.steps.append(s)
        return s

    for r in rows:
        ts, k = float(r["ts"]), r.get("kind")
        if k == "prompt":
            ctx = _ctx(r)
            who = _owner_of_prompt(r, ctx)
            if who is not None:
                owner = who
            comp = r.get("component") or "?"
            if comp == "director":  # one prompt row, then one llm_response per research round
                director_open[str(r.get("episode_id") or "director")] = (ts, str(r.get("task")))
                continue
            open_prompt[comp] = (ts, owner)
            be = (ctx or {}).get("body_event") or {}
            if owner == "board" and isinstance(be, dict) and be.get("type") == "board_step" and who == "board":
                st = be.get("step") or {}
                key = (be.get("task"), st.get("title"), be.get("run"))
                dup = pending_runs and (pending_runs[-1].get("task_text"), pending_runs[-1].get("step"), pending_runs[-1].get("run")) == key
                if not dup and not any(p.get("explicit") for p in pending_runs):  # a re-decided prompt is the same run
                    pending_runs.append({"ts": ts, "task_text": be.get("task"), "step": st.get("title"), "run": be.get("run")})
            if who == "board" and isinstance(be, dict) and be.get("type") == "board_notice":
                facts = be.get("facts") or {}
                tid = text_to_id.get(str(be.get("task")))
                if tid and isinstance(facts, dict) and facts.get("budget_wait_min") is not None:
                    notice_budget.setdefault(tid, ts)
            continue
        if k == "llm_response":
            comp = r.get("component") or "?"
            if comp == "director":
                key = str(r.get("episode_id") or "director")
                if key in director_open:  # every round, and the research tools between rounds, is this task's thinking
                    t0, tid = director_open[key]
                    iv["busy"].append((t0, ts))
                    iv["director_model"].setdefault(tid, []).append((t0, ts))
                    director_open[key] = (ts, tid)
            elif comp in open_prompt:
                t0, who = open_prompt.pop(comp)
                add_iv(t0, ts, who, "model")
            continue
        if k == "board_run_start":
            pending_runs.append({"ts": ts, "task": r.get("task"), "step": r.get("step"), "step_id": r.get("step_id"),
                                 "run": r.get("run"), "explicit": True})
            continue
        if k == "tool_call":
            if r.get("read_only"):
                open_read = (ts, _owner_of_id(r) or owner)
                continue
            tid = str(r.get("task_id") or ts)
            who_now = _owner_of_id(r) or owner
            rec = {"tool": r.get("tool"), "ok": None, "reason": None, "ts": ts, "end": None, "attempt": r.get("attempt")}
            open_actions[tid] = (ts, rec, who_now, None)  # attached to its run at board_run time (the run's window)
            continue
        if k == "tool_result":
            if r.get("read_only"):
                if open_read:
                    add_iv(open_read[0], ts, open_read[1], "read")
                    open_read = None
                continue
            tid = str(r.get("task_id") or "")
            if tid not in open_actions and open_actions:
                tid = next(reversed(open_actions))
            if tid in open_actions:
                t0, rec, who, _ = open_actions.pop(tid)
                res = r.get("result") or {}
                rec.update(ok=bool(res.get("ok")), reason=res.get("reason"), end=ts, owner=who)
                add_iv(t0, ts, who, "action")
                iv.setdefault("action_rows", []).append(rec)
            continue
        if k == "director_dispatch":
            t = task(str(r.get("task")), ts, r.get("_file"))
            open_dispatch[t.id] = (ts, str(r.get("decision")))
            if t.id in notice_budget:
                t.budget.append((notice_budget.pop(t.id), ts))
            continue
        if k in DECISION_END:
            tid = str(r.get("task"))
            if tid in open_dispatch:
                t0, kind = open_dispatch.pop(tid)
                iv["director_window"].setdefault(tid, []).append((t0, ts))  # dispatch -> decision applied
                t = task(tid, t0, r.get("_file"))
                t.end = max(t.end or ts, ts)
                t.decisions.append({"kind": r.get("decision") or kind, "start": t0, "end": ts,
                                    "outcome": k.replace("director_", ""), "steps": r.get("steps"),
                                    "why": r.get("why") or r.get("explanation")})
            continue
        if k == "board_run":
            t = task(str(r.get("task")), ts, r.get("_file"))
            title, sid = str(r.get("step")), r.get("step_id")
            cands = [p for p in pending_runs if p.get("step") == title and p.get("task") in (None, t.id)]
            pr = cands[0] if cands else (pending_runs[0] if pending_runs else None)
            if pr is not None:
                pending_runs.remove(pr)
                if pr.get("task_text"):
                    text_to_id[str(pr["task_text"])] = t.id
                    t.text = t.text or pr["task_text"]
            start = pr["ts"] if pr else ts
            run = Run(start=start, end=ts, run=r.get("run") or (pr or {}).get("run"), passed=r.get("passed"), ended=r.get("ended"))
            run.actions = [a for a in iv.get("action_rows", []) if start - 0.5 <= a["ts"] <= ts and a.get("owner") == "board"]
            s = step_of(t, title, sid)
            s.runs.append(run)
            if r.get("passed") is True:
                s.outcome, s.end = "done", ts
            t.end = max(t.end or ts, ts)
            continue
        if k == "board_wait_start":
            t = task(str(r.get("task")), ts, r.get("_file"))
            s = step_of(t, str(r.get("step")), r.get("step_id"))
            s.wait_from = s.wait_from or ts
            s.reason = s.reason or (f"waiting: {r.get('until')}" if r.get("until") else None)
            continue
        if k == "board_step_end":
            t = task(str(r.get("task")), ts, r.get("_file"))
            s = step_of(t, str(r.get("step")), r.get("step_id"), any_outcome=True)
            if s.wait_from is not None:
                t.waits.append((s.wait_from, ts))
            s.outcome = s.outcome if s.outcome == "done" else str(r.get("status"))
            s.reason, s.end = r.get("reason"), s.end or ts
            t.end = max(t.end or ts, ts)
            continue
        if k == "board_task_status":
            t = task(str(r.get("task")), ts, r.get("_file"))
            to = str(r.get("to"))
            if to == "waiting_budget":
                budget_open[t.id] = ts
            elif t.id in budget_open:
                t.budget.append((budget_open.pop(t.id), ts))
            t.status = to
            if to in ENDED:
                t.end = max(t.end or ts, ts)
            continue

    _enrich(tasks, goals)
    for t in tasks.values():
        for s in t.steps:
            if s.outcome is None:
                s.outcome = "unfinished"
            if s.end is None and s.runs:
                s.end = s.runs[-1].end
        if t.id in budget_open and t.end:
            t.budget.append((budget_open[t.id], t.end))
        for s in t.steps:  # a wait still open when the log ends
            if s.wait_from is not None and not any(a == s.wait_from for a, _ in t.waits):
                t.waits.append((s.wait_from, max(t.end or s.wait_from, s.end or s.wait_from)))
    return [tasks[i] for i in order], iv


def _enrich(tasks: dict[str, TaskT], goals: dict | None) -> None:
    if not goals:
        return
    for g in goals.get("tasks") or []:
        t = tasks.get(str(g.get("id")))
        if t is None:
            continue
        t.text = t.text or g.get("text")
        t.by = g.get("by")
        t.status = g.get("status") or t.status
        by_title: dict[str, list[dict]] = {}
        for gs in g.get("steps") or []:
            by_title.setdefault(str(gs.get("title")), []).append(gs)
        for s in t.steps:
            gs = (by_title.get(s.title) or [None]).pop(0) if by_title.get(s.title) else None
            if gs and s.outcome is None:
                s.outcome = str(gs.get("status"))
                fails = gs.get("failures") or []
                s.reason = s.reason or (fails[-1].get("reason") if fails and isinstance(fails[-1], dict) else None)


def analyse(rows: list[dict], goals: dict | None = None) -> list[TaskT]:
    tasks, iv = build(rows, goals)
    board_think, queue, busy, acts = union(iv["think_own"]), union(iv["queue"]), union(iv["busy"]), union(iv["actions"])
    for t in tasks:
        if t.start is None or t.end is None:
            continue
        budget = union(t.budget)
        waits = union(t.waits)
        own_dir = union(iv["director_model"].get(t.id, []))
        others_dir = union([x for k, v in iv["director_model"].items() if k != t.id for x in v] +
                           [x for k, v in iv["director_window"].items() if k != t.id for x in v])
        think = union(board_think + own_dir)
        pickup = minus(union(iv["director_window"].get(t.id, [])), own_dir)  # decided, not yet applied (next tick)
        que = union(queue + others_dir)

        def split(a: float, b: float) -> dict:
            th = clip(think, a, b)
            qu = minus(clip(que, a, b), th)
            bu = minus(minus(clip(budget, a, b), th), qu)
            de = minus(minus(minus(clip(pickup, a, b), th), qu), bu)
            wa = minus(minus(minus(minus(clip(waits, a, b), th), qu), bu), de)
            bo = minus(minus(minus(minus(minus(clip(acts, a, b), th), qu), bu), de), wa)
            total = max(0.0, b - a)
            parts = {"thinking_s": length(th), "waiting_queue_s": length(qu), "waiting_budget_s": length(bu),
                     "waiting_decision_s": length(de), "waiting_step_s": length(wa), "body_s": length(bo)}
            parts["dead_s"] = max(0.0, total - sum(parts.values()))
            return {"seconds": round(total, 3), **{k: round(v, 3) for k, v in parts.items()},
                    "waiting_s": round(parts["waiting_queue_s"] + parts["waiting_budget_s"] + parts["waiting_decision_s"]
                                       + parts["waiting_step_s"], 3)}
        if t.steps:
            first = t.steps[0].first_world_action() or t.steps[0].start
            t.lead_in = {"from": t.start, "to": first, **split(t.start, max(t.start, first))}
        for a, b in zip(t.steps, t.steps[1:]):
            t0 = a.end if a.end is not None else a.start
            nxt = b.first_world_action()
            t1 = nxt if nxt is not None else b.start
            t1 = max(t0, t1)
            t.gaps.append({"from_step": a.title, "to_step": b.title, "from": t0, "to": t1, "first_action": nxt is not None,
                           "from_outcome": a.outcome, **split(t0, t1)})
        wall = max(0.0, t.end - t.start)
        idle_iv = minus([(t.start, t.end)], busy)
        # a wait step (crop growing) is idle by design: reported as step_wait_s, never the "longest idle" stretch
        longest = max(minus(idle_iv, waits), key=lambda x: x[1] - x[0], default=None)
        t.idle = {"wall_s": round(wall, 3), "idle_s": round(length(idle_iv), 3),
                  "step_wait_s": round(length(clip(union(t.waits), t.start, t.end)), 3),  # idle by design (a wait step)
                  "share": round(length(idle_iv) / wall, 3) if wall > 0 else None,
                  "longest_s": round(longest[1] - longest[0], 3) if longest else 0.0,
                  "longest_from": longest[0] if longest else None, "longest_to": longest[1] if longest else None,
                  "longest_where": _where(rows, longest) if longest else None}
    return tasks


def _row_label(r: dict) -> str:
    k = r.get("kind")
    if k == "board_run":
        return f"board_run '{r.get('step')}' {'passed' if r.get('passed') else 'not passed'}"
    if k in ("tool_call", "tool_result"):
        res = r.get("result") or {}
        return f"{k} {r.get('tool')}" + (f" ok={res.get('ok')}" if k == "tool_result" else "")
    if k == "prompt":
        ctx = _ctx(r) or {}
        be = ctx.get("body_event") or {}
        if isinstance(be, dict) and be.get("type") == "board_step":
            return f"prompt board_step '{(be.get('step') or {}).get('title')}' run {be.get('run')}"
        return f"prompt {r.get('component')}"
    if k in ("director_dispatch",) + DECISION_END:
        return f"{k} {r.get('decision') or ''}".strip()
    return str(k)


def _where(rows: list[dict], span: tuple[float, float]) -> str:
    before = [r for r in rows if r["ts"] <= span[0] + 1e-6]
    after = [r for r in rows if r["ts"] >= span[1] - 1e-6]
    a = _row_label(before[-1]) if before else "start"
    b = _row_label(after[0]) if after else "end"
    return f"after {a}, before {b}"


# ------------------------------------------------------------------ summaries
def pct(xs: list[float], p: float) -> float | None:
    if not xs:
        return None
    xs = sorted(xs)
    return round(xs[max(0, min(len(xs) - 1, round(p / 100 * (len(xs) - 1))))], 2)


def summary(tasks: list[TaskT]) -> dict:
    gaps = [g for t in tasks for g in t.gaps]
    walls = [t.idle for t in tasks if t.idle and t.idle["wall_s"] > 0]
    wall = sum(i["wall_s"] for i in walls)
    longest = max(((t, t.idle) for t in tasks if t.idle), key=lambda x: x[1]["longest_s"], default=(None, None))
    split = {k: round(sum(g[k] for g in gaps), 2) for k in ("thinking_s", "waiting_queue_s", "waiting_budget_s",
                                                             "waiting_decision_s", "waiting_step_s", "body_s", "dead_s")}
    return {"tasks": len(tasks), "steps": sum(len(t.steps) for t in tasks), "gaps": len(gaps),
            "task_gap_p50": pct([g["seconds"] for g in gaps], 50), "task_gap_p90": pct([g["seconds"] for g in gaps], 90),
            "gap_split_s": split,
            "idle_share": round(sum(i["idle_s"] for i in walls) / wall, 3) if wall > 0 else None,
            "longest_idle_s": longest[1]["longest_s"] if longest[1] else None,
            "longest_idle": ({"task": longest[0].id, "text": longest[0].text, "seconds": longest[1]["longest_s"],
                              "where": longest[1]["longest_where"]} if longest[1] else None)}


def load_goals(paths: list[Path]) -> dict:
    merged: dict = {"tasks": []}
    for p in paths:
        try:
            g = json.loads(Path(p).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        merged["tasks"] += g.get("tasks") or []
    return merged


def render(t: TaskT, hms) -> str:
    i = t.idle or {}
    head = f"TASK {t.id} \"{t.text or '?'}\"" + (f" by {t.by}" if t.by else "") + f"  status {t.status or '?'}"
    out = [head, f"  {hms(t.start)}-{hms(t.end)}  wall {i.get('wall_s', 0):.1f} s, idle {i.get('idle_s', 0):.1f} s "
                 f"({(i.get('share') or 0):.0%}), longest idle {i.get('longest_s', 0):.1f} s"
                 + (f" at {hms(i['longest_from'])}-{hms(i['longest_to'])} ({i['longest_where']})" if i.get("longest_from") else "")]
    for d in t.decisions:
        out.append(f"  director {d['kind']} {hms(d['start'])}-{hms(d['end'])} ({d['outcome']})"
                   + (f" -> {len(d['steps'])} steps" if d.get("steps") else "") + (f": {d['why']}" if d.get("why") else ""))
    if t.lead_in:
        out.append("  lead-in to the first action: " + _split_text(t.lead_in))
    gaps = {g["from_step"] + "->" + g["to_step"]: g for g in t.gaps}
    for n, s in enumerate(t.steps, 1):
        dur = (s.end - s.start) if s.end is not None else None
        acts = ", ".join(f"{a['tool']} {'ok' if a['ok'] else a['reason']}" for r in s.runs for a in r.actions) or "no body action"
        out.append(f"  {n:>2}. {s.title[:34]:<34} {hms(s.start)}  {dur if dur is not None else 0:6.1f} s  runs {len(s.runs)}"
                   f"  {s.outcome}{' (' + str(s.reason) + ')' if s.reason else ''}  [{acts}]")
        if n < len(t.steps):
            g = gaps.get(s.title + "->" + t.steps[n].title)
            if g:
                out.append(f"      gap -> {n + 1}: " + _split_text(g) + ("" if g["first_action"] else " (next step had no body action)"))
    if t.gaps:
        xs = [g["seconds"] for g in t.gaps]
        out.append(f"  gaps: n={len(xs)} p50 {pct(xs, 50)} s, p90 {pct(xs, 90)} s, max {max(xs):.1f} s")
    return "\n".join(out)


def _split_text(g: dict) -> str:
    bits = [f"{g['seconds']:.1f} s ="]
    for k, label in (("thinking_s", "thinking"), ("waiting_queue_s", "waiting(queue)"), ("waiting_budget_s", "waiting(budget)"),
                     ("waiting_decision_s", "waiting(decision pickup)"), ("waiting_step_s", "waiting(step wait)"),
                     ("body_s", "body"), ("dead_s", "dead")):
        if g.get(k):
            bits.append(f"{label} {g[k]:.1f}")
    return " ".join(bits) if len(bits) > 1 else f"{g['seconds']:.1f} s"

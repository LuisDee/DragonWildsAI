"""How a player's ask ended in recorded live play, and whether it was done (docs/research/2026-11-17-ask-ends.md).

An ask is a line a player addressed to him (a `chat_decision` row with decision "addressed"). The brain holds it as
`Agent._open_request` (brain/agent.py:524) from commit c019a6f (2026-11-16 12:11Z) on, and closes it on a turn in
which the model calls nothing (`request_closed`, brain/agent.py:668-671). Before that commit the ask lived only as
long as the run it started (and the goal that run queued). Nothing in either era checks the game.
From commit 3ec85ff (2026-11-17 18:29Z) a stop on the open ask first gets one more turn that shows it as data and
offers request_done / park_request (`open_ask_turn` rows, outcome world|park|done_claim|say|silent|refused|error);
the ask then ends on `request_done_claimed`, `request_parked`, or `request_closed` with `after_open_ask_turn` (a
second silent turn) or `no_open_ask_turn` (why the turn could not run). Older logs read as before.

    .venv\\Scripts\\python.exe -m tools.ask_ends report [--since 2026-11-01] [--until 2026-11-18] [--json]
    .venv\\Scripts\\python.exe -m tools.ask_ends show ASK_ID        # e.g. 20261117-151932-23576#1

Endings (one per ask):
  closed_silent   the model stopped on it: a turn with no call (era 2: the `request_closed` row; era 1: the run's
                  last decision had no body action, or the model chose silence after a failure)
  claimed_done    he closed it with request_done(evidence) on the open-ask turn (a claim: never checked here)
  parked_by_him   he closed it with park_request(reason) on the open-ask turn (not the breaker's `parked`)
  goal_done       era 1 only: the goal the run queued ended done, and with it the run
  goal_stuck      era 1 only: the goal ended stuck (max_replans, max_interrupts, no plan)
  turn_budget     the run hit MAX_TURNS and the hand-ons were used up (`chain_stopped` why=budget)
  deadline        REQUEST_SECONDS passed (`chain_stopped` why=deadline)
  parked          the no-progress breaker parked a step (`chain_stopped` why=parked)
  run_ended       era 1 only: the run's rows stop after a body call and no row says why
  replaced        a new addressed line came while it was open
  brain_ended     the log ends with it open (the harness stopped the brain, a crash, a restart)

Was it done (no model): the quest runner's verdict (logs/evals/quest_runs.jsonl, joined by brain_log), a gate's
leg (logs/evals/rung*_gate.jsonl, farm_gate.jsonl), the travel ladder (chat_ladder.jsonl); otherwise "not_done" only
when the same player said the same line again within 2 minutes of the end, his last line said he could not, or he
parked it himself (park_request: by his own word it is not finished).
Everything else is "unknown". "done_later" = done, but after the ask had ended (it was not done when it ended).
Read only: logs/ is never written. Files modified in the last 30 minutes are skipped (a live brain writes them).
"""
from __future__ import annotations

import argparse
import datetime as _dt
import glob
import json
import os
import re
import sys
import time
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOGS = ROOT / "logs"
EVALS = LOGS / "evals"
UTC = _dt.timezone.utc
# brain/agent.py c019a6f: "a player's request stays open across later body runs until the model stops on it"
ERA2_TS = _dt.datetime(2026, 11, 16, 12, 11, 6, tzinfo=UTC).timestamp()
FRESH_S = 1800  # skip logs modified this recently: a live brain may be writing them
REPEAT_S = 120.0  # the same line again within this long after the end: it was not done
DONE_GRACE_S = 30.0  # a verdict's done time this close after the end still counts as done by the end
CHUNK = 300

KIND_RE = re.compile(r'"kind":\s*"([a-z_]+)"')
KEEP = {"session_start", "chat_decision", "request_closed", "tool_call", "task_failed", "llm_response", "chain_turn",
        "chain_stopped", "chain_handed_on", "say", "event", "situation_review", "failure_unspoken", "reply_silent",
        "goal_dropped", "controller_budget_exhausted", "stop_for_check", "open_job_check", "failure_unreported",
        "board_run", "next_turn_error", "situation_error", "talk_only_check", "open_ask_turn",
        "request_done_claimed", "request_parked"}
# brain/agent.py 3ec85ff: the rows that end an open ask, and the ending each gives
CLOSE_ROWS = {"request_closed": "closed_silent", "request_done_claimed": "claimed_done", "request_parked": "parked_by_him"}
EVENT_TYPES = {"chat_heard", "vitals_low"}
ACTIVITY_KINDS = {"combat_started"}
DEATH = "companion_down"
BAG = {"inventory_full", "encumbered"}
# his own last line says he could not (strict: inability words only, not "blocked" or "stuck" which he also says
# while still trying another way)
COULD_NOT = re.compile(r"\b(can't|cannot|can not|couldn't|could not|unable to|not able to|no way to|give up|"
                       r"gave up|won't be able|don't have a way|isn't possible|not possible)\b", re.I)
GOAL_MSGS = {"goal started", "goal done", "stuck", "goal interrupted", "replanned"}


def _cut(x, n: int = CHUNK) -> str:
    s = x if isinstance(x, str) else json.dumps(x, ensure_ascii=False, default=str)
    return s if len(s) <= n else s[: n - 3] + "..."


def _utc(ts: float | None) -> str:
    return _dt.datetime.fromtimestamp(ts, UTC).strftime("%Y-%m-%d %H:%M:%SZ") if ts else "?"


def norm_line(text: str | None) -> str:
    """A line as the player meant it: case, punctuation and the leading 'claude' do not matter."""
    s = re.sub(r"[^a-z0-9 ]+", " ", (text or "").lower())
    s = re.sub(r"\s+", " ", s).strip()
    return re.sub(r"^(claude|companion)\s+", "", s)


# ------------------------------------------------------------------ reading

def read_rows(path: Path | str):
    """Stream the rows of one brain log that this tool needs (bridge traffic and prompts are skipped unparsed)."""
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = KIND_RE.search(line, 0, 200)
            if not m or m.group(1) not in KEEP:
                continue
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("kind") == "event":
                e = r.get("event") or {}
                if e.get("type") not in EVENT_TYPES and not (
                        e.get("type") == "activity" and e.get("kind") in ACTIVITY_KINDS):
                    continue
            yield r


def last_ts(path: Path | str) -> float | None:
    """The last row's ts (the brain's last word in this file), read from the file's tail."""
    with open(path, "rb") as fh:
        fh.seek(0, 2)
        size = fh.tell()
        fh.seek(max(0, size - 65536))
        tail = fh.read().decode("utf-8", errors="replace").splitlines()
    for line in reversed(tail):
        m = re.match(r'\{"ts":\s*([0-9.]+)', line)
        if m:
            return float(m.group(1))
    return None


def load_progress(root: Path = LOGS) -> list[dict]:
    """Goal rows from every world's progress.jsonl (brain/state_store.py:145): goal started, done, stuck, replanned,
    interrupted. The live body is one, so time alone joins them to a brain log."""
    out = []
    for p in glob.glob(str(root / "state" / "**" / "progress.jsonl"), recursive=True):
        with open(p, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if '"msg": "activity"' in line or '"msg": "task ' in line:
                    continue
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if r.get("msg") in GOAL_MSGS and isinstance(r.get("ts"), (int, float)):
                    out.append(r)
    out.sort(key=lambda r: r["ts"])
    return out


def _jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    out = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if isinstance(r, dict):
            out.append(r)
    return out


def _truthy(v) -> bool | None:
    if v is None:
        return None
    if isinstance(v, bool):
        return v
    return str(v).lower() == "true"


def load_verdicts(evals: Path = EVALS) -> dict:
    """{brain_log: [verdict rows]} from the quest runner, the gates and the travel ladder, plus the sets of lines each
    harness sends (to tell a harness line from a typed one when a run left no verdict row)."""
    by_log: dict[str, list[dict]] = defaultdict(list)
    lines: dict[str, set[str]] = defaultdict(set)
    for r in _jsonl(evals / "quest_runs.jsonl"):
        for ln in r.get("lines") or []:
            if isinstance(ln, dict) and ln.get("line"):
                lines["quest"].add(norm_line(ln["line"]))
        if not r.get("brain_log"):
            continue
        done_at = None
        try:
            start = _dt.datetime.strptime(r["run"], "%Y%m%d-%H%M%S").replace(tzinfo=UTC).timestamp()
        except (KeyError, ValueError):
            start = None
        if start is not None and r.get("done"):
            comp = [s.get("t") for s in r.get("steps") or [] if isinstance(s, dict) and s.get("state") == "complete"]
            if comp and isinstance(comp[-1], (int, float)):
                done_at = start + comp[-1]
            elif isinstance(r.get("wall_s"), (int, float)):
                done_at = start + r["wall_s"]
        for ln in r.get("lines") or [{"line": None}]:
            by_log[r["brain_log"]].append({
                "source": "quest", "line": norm_line(ln.get("line")), "done": bool(r.get("done")), "done_at": done_at,
                "detail": f"quest_run {r.get('run')} {r.get('quest')} until={r.get('until_step') or r.get('until')}"
                          f" ended={r.get('ended')}", "ended": r.get("ended")})
    for name in sorted(glob.glob(str(evals / "rung*_gate.jsonl"))) + [str(evals / "farm_gate.jsonl")]:
        for r in _jsonl(Path(name)):
            for leg in r.get("legs") or []:
                if not isinstance(leg, dict) or not leg.get("line"):
                    continue
                lines["gate"].add(norm_line(leg["line"]))
                if r.get("brain_log"):
                    by_log[r["brain_log"]].append({
                        "source": "gate", "line": norm_line(leg["line"]), "done": bool(_truthy(leg.get("done"))),
                        "done_s": leg.get("done_s"), "ended": leg.get("ended"),
                        "detail": f"{Path(name).stem} {r.get('item')} pass={r.get('pass')} how={_cut(leg.get('how'), 160)}"})
    for r in _jsonl(evals / "chat_ladder.jsonl"):
        if not r.get("line"):
            continue
        lines["ladder"].add(norm_line(r["line"]))
        if r.get("brain_log"):
            by_log[r["brain_log"]].append({
                "source": "ladder", "line": norm_line(r["line"]), "done": bool(_truthy(r.get("success"))),
                "ended": r.get("ended"), "detail": f"chat_ladder {r.get('kind')} outcome={r.get('outcome')}"})
    for r in _jsonl(evals / "build_runs.jsonl"):
        if r.get("line"):
            lines["build"].add(norm_line(r["line"]))
    return {"by_log": dict(by_log), "lines": {k: sorted(v) for k, v in lines.items()}}


# ------------------------------------------------------------------ reconstruction

@dataclass
class Ask:
    id: str
    file: str
    player: str
    line: str
    start: float
    episode: str | None
    era: int
    end: float = 0.0
    ending: str = ""
    ending_row: str = ""
    cause: str = ""
    source: str = "player"
    group: str = "free"
    verdict: str = "unknown"
    verdict_by: str = ""
    verdict_detail: str = ""
    life_s: float = 0.0
    body_calls: int = 0
    read_calls: int = 0
    failed_calls: int = 0
    controller_calls: int = 0
    planner_calls: int = 0
    goals: list = field(default_factory=list)  # [{start, end, outcome, reason, goal}]
    replans: int = 0
    deaths: int = 0
    bag_full: int = 0
    fights: int = 0
    vitals_low: int = 0
    hand_ons: int = 0
    chain_stops: dict = field(default_factory=dict)
    talk_only: bool = False
    last_calls: list = field(default_factory=list)  # [tool ok/reason] of the last three body calls
    last_say: str = ""
    idle_at_end_s: float | None = None
    after_s: float = 0.0  # from the end to the next addressed line or the log's end
    calls_after: int = 0  # body calls in that span (work he did with no ask open)
    # the open-ask turn (3ec85ff): its outcomes in order; on a request_closed row, whether the open-ask turn came just
    # before it (None: an older log, or another ending) and, if none could run, why not; the done evidence or park reason
    open_ask: list = field(default_factory=list)
    closed_after_open_ask: bool | None = None
    no_open_ask_turn: str = ""
    closed_words: str = ""


def _calls_of(r: dict) -> list[str]:
    return [c.get("name") for c in r.get("tool_calls") or [] if isinstance(c, dict)]


def reconstruct(rows: list[dict], progress: list[dict] | None = None, name: str = "", end_ts: float | None = None,
                era: int | None = None) -> list[Ask]:
    """Every ask in one brain log and how it ended. ``rows``: the file's rows (read_rows); ``progress``: goal rows
    (load_progress), any span; ``end_ts``: the file's last row ts (default: the last row given); ``era``: 1 or 2
    (default: 2 when the brain started after ERA2_TS or the log has a request_closed row)."""
    stem = Path(name).stem.replace("brain-live-", "") if name else "log"
    rows = [r for r in rows if isinstance(r.get("ts"), (int, float))]
    if not rows:
        return []
    file_end = max(end_ts or 0.0, rows[-1]["ts"])
    session = next((r["ts"] for r in rows if r.get("kind") == "session_start"), rows[0]["ts"])
    if era is None:
        era = 2 if session >= ERA2_TS or any(r.get("kind") == "request_closed" for r in rows) else 1
    heard_at: dict[str, float] = {}
    ep_first: dict[str, float] = {}
    ep_last: dict[str, float] = {}
    asks: list[Ask] = []
    seen_eps: set = set()
    for r in rows:
        ep = r.get("episode_id")
        if ep:
            ep_first.setdefault(ep, r["ts"])
            ep_last[ep] = r["ts"]
        k = r.get("kind")
        if k == "event" and (r.get("event") or {}).get("type") == "chat_heard" and ep:
            heard_at.setdefault(ep, float((r["event"].get("ts") or r["ts"])))
        if k == "chat_decision" and r.get("decision") == "addressed":
            key = (ep, r.get("text"))
            if key in seen_eps:
                continue
            seen_eps.add(key)
            start = heard_at.get(ep, r["ts"]) if ep else r["ts"]
            asks.append(Ask(id=f"{stem}#{len(asks) + 1}", file=name, player=str(r.get("player")),
                            line=str(r.get("text") or ""), start=start, episode=ep, era=era))
    goals = _goal_spans(progress or [], session, file_end)
    for i, a in enumerate(asks):
        nxt = asks[i + 1].start if i + 1 < len(asks) else None
        if era == 2:
            _end_era2(a, rows, nxt, file_end)
        else:
            _end_era1(a, rows, nxt, file_end, goals, ep_first, ep_last)
        _measure(a, rows, goals, progress or [])
        _cause(a)
        upto = nxt if nxt is not None else file_end
        a.after_s = round(max(0.0, upto - a.end), 1)
        a.calls_after = sum(1 for r in rows if r.get("kind") == "tool_call" and not r.get("read_only")
                            and a.end + 0.5 < r["ts"] < upto)
    return asks


def _goal_spans(progress: list[dict], t0: float, t1: float) -> list[dict]:
    spans, cur = [], None
    for r in progress:
        if r["ts"] < t0 - 1 or r["ts"] > t1 + 1:
            continue
        m = r.get("msg")
        if m == "goal started":
            if cur:  # a start with no end: the brain ended under it
                spans.append(cur)
            cur = {"start": r["ts"], "end": None, "outcome": "open", "reason": None, "goal": _cut(r.get("goal"), 160),
                   "replans": 0}
        elif cur and m == "replanned":
            cur["replans"] += 1
        elif cur and m in ("goal done", "stuck", "goal interrupted"):
            cur.update(end=r["ts"], outcome={"goal done": "done", "stuck": "stuck"}.get(m, "interrupted"),
                       reason=r.get("reason"))
            spans.append(cur)
            cur = None
    if cur:
        spans.append(cur)
    return spans


def _end_era2(a: Ask, rows: list[dict], nxt: float | None, file_end: float) -> None:
    stop = nxt if nxt is not None else file_end + 1
    for r in rows:
        if r["ts"] < a.start or r["ts"] >= stop:
            continue
        k = r.get("kind")
        # request_done / park_request log the ask that was open; None only if none was (then it is this one's)
        if k in CLOSE_ROWS and (r.get("request") == a.line or (k != "request_closed" and r.get("request") is None)):
            a.end, a.ending, a.ending_row = r["ts"], CLOSE_ROWS[k], _cut(r, 200)
            if k == "request_closed":
                if "after_open_ask_turn" in r:
                    a.closed_after_open_ask = bool(r["after_open_ask_turn"])
                a.no_open_ask_turn = str(r.get("no_open_ask_turn") or "")
            else:
                a.closed_words = _cut((r.get("evidence") if k == "request_done_claimed" else r.get("reason")) or "", 240)
            return
    if nxt is not None:
        a.end, a.ending, a.ending_row = nxt, "replaced", "the next addressed line"
    else:
        a.end, a.ending, a.ending_row = file_end, "brain_ended", "the log ends with the ask open"


def _end_era1(a: Ask, rows, nxt, file_end, goals, ep_first, ep_last) -> None:
    stop = nxt if nxt is not None else file_end + 1
    eps = {a.episode} if a.episode else set()
    # hand-ons: the run handed on as a body situation; the next situation episode carries it on
    for r in rows:
        if r["ts"] < a.start or r["ts"] >= stop:
            continue
        if r.get("kind") == "chain_handed_on" and r.get("episode_id") in eps:
            later = sorted((t, e) for e, t in ep_first.items() if t > r["ts"] and e.startswith("situation"))
            if later:
                eps.add(later[0][1])
    run_end = max((ep_last.get(e, a.start) for e in eps), default=a.start)
    goal = next((g for g in goals if a.start <= g["start"] < min(stop, run_end + 5)), None)
    if goal and goal["end"] is not None and goal["end"] < stop:
        a.end = goal["end"]
        a.ending = {"done": "goal_done", "stuck": "goal_stuck"}.get(goal["outcome"], "replaced")
        a.ending_row = _cut({"progress": goal["outcome"], "reason": goal["reason"], "goal": goal["goal"]}, 200)
        return
    if goal or run_end >= stop - 0.5:
        if nxt is not None:
            a.end, a.ending, a.ending_row = nxt, "replaced", "the next addressed line"
        else:
            a.end, a.ending, a.ending_row = file_end, "brain_ended", "the log ends inside its run or goal"
        return
    mine = [r for r in rows if r.get("episode_id") in eps and a.start <= r["ts"] <= run_end]
    last_body = max((r["ts"] for r in mine if r.get("kind") == "tool_call" and not r.get("read_only")), default=None)
    stops = [r for r in mine if r.get("kind") == "chain_stopped"]
    silent_turn = [r for r in mine if r.get("kind") == "chain_turn" and not r.get("actions")
                   and (last_body is None or r["ts"] >= last_body)]
    chosen = [r for r in mine if r.get("kind") in ("failure_unspoken", "reply_silent")]
    a.end = run_end
    if stops and stops[-1]["ts"] >= run_end - 5:
        why = stops[-1].get("why")
        a.ending = {"the player spoke": "replaced", "budget": "turn_budget", "deadline": "deadline",
                    "parked": "parked"}.get(why, "closed_silent")
        a.ending_row = _cut(stops[-1], 200)
    elif silent_turn or chosen or last_body is None:
        a.ending = "closed_silent"
        a.ending_row = _cut((silent_turn or chosen or mine or [{"note": "talk-only run"}])[-1], 200)
    elif file_end - run_end < 5:
        a.end, a.ending, a.ending_row = file_end, "brain_ended", "the log ends inside its run"
    else:  # the run's rows stop after a body call with no row saying why (seen in the Nov 1 code)
        a.ending, a.ending_row = "run_ended", _cut(mine[-1] if mine else {}, 200)


def _measure(a: Ask, rows: list[dict], goals: list[dict], progress: list[dict]) -> None:
    a.life_s = round(max(0.0, a.end - a.start), 1)
    lo, hi = a.start, a.end + 0.5
    body, deaths, last_act = [], [], None
    stops: Counter = Counter()
    for r in rows:
        t = r["ts"]
        if t < lo or t > hi:
            continue
        k = r.get("kind")
        if k == "tool_call":
            if r.get("read_only"):
                a.read_calls += 1
            else:
                body.append({"ts": t, "tool": r.get("tool"), "args": r.get("args"), "task": r.get("task_id"),
                             "ok": True, "reason": None})
                last_act = t
        elif k == "task_failed":
            a.failed_calls += 1
            for b in reversed(body):
                if b["task"] == r.get("task_id"):
                    b["ok"], b["reason"] = False, r.get("reason")
                    break
            reason = str(r.get("reason") or "")
            if reason == DEATH:
                deaths.append(t)
            elif reason in BAG:
                a.bag_full += 1
            last_act = t
        elif k == "llm_response":
            if r.get("component") == "planner":
                a.planner_calls += 1
            elif r.get("component") == "controller":
                a.controller_calls += 1
        elif k == "event":
            e = r.get("event") or {}
            if e.get("type") == "vitals_low":
                a.vitals_low += 1
            elif e.get("type") == "activity" and e.get("kind") == "combat_started":
                a.fights += 1
        elif k == "situation_review":
            for c in r.get("changes") or []:
                if not isinstance(c, dict):
                    continue
                if c.get("what") == "health" and c.get("to_pct") == 0:
                    deaths.append(t)
                if c.get("what") == "bag" and isinstance(c.get("used"), int) and c.get("used") >= (c.get("capacity") or 1e9):
                    a.bag_full += 1
        elif k == "chain_stopped":
            stops[str(r.get("why"))] += 1
        elif k == "chain_handed_on":
            a.hand_ons += 1
        elif k == "say" and r.get("text"):
            a.last_say = _cut(r["text"], 240)
        elif k == "open_ask_turn" and r.get("request") in (a.line, None):
            a.open_ask.append(str(r.get("outcome") or "?"))
    # one death per minute at most (a death fails every call until the respawn)
    a.deaths = sum(1 for i, t in enumerate(sorted(deaths)) if i == 0 or t - sorted(deaths)[i - 1] > 60)
    a.body_calls = len(body)
    a.chain_stops = dict(stops)
    a.goals = [dict(g) for g in goals if lo - 5 <= g["start"] <= hi]
    a.replans = sum(g.get("replans", 0) for g in a.goals)
    a.last_calls = [f"{b['tool']} " + ("ok" if b["ok"] else f"failed {b['reason']}") for b in body[-3:]]
    a.talk_only = not body and not a.goals and a.planner_calls == 0
    a.idle_at_end_s = round(a.end - last_act, 1) if last_act else None


def _cause(a: Ask) -> None:
    """The ending with what came just before it (the label the doc groups not-done asks by)."""
    g = a.goals[-1] if a.goals else None
    if a.ending == "closed_silent":
        if g and g["outcome"] == "stuck":
            a.cause = f"closed silent after a goal ended stuck ({_stuck_class(g.get('reason'))})"
        elif a.last_calls and "failed" in a.last_calls[-1]:
            a.cause = "closed silent after his last call failed"
        elif a.talk_only:
            a.cause = "closed silent, talk only (no call at all)"
        else:
            a.cause = "closed silent after his last call worked"
    elif a.ending == "goal_stuck":
        a.cause = f"goal ended stuck ({_stuck_class(g.get('reason') if g else None)})"
    elif a.ending == "brain_ended":
        a.cause = "brain ended" + (" while a goal ran" if g and g["outcome"] == "open" else
                                   " after a goal ended stuck" if g and g["outcome"] == "stuck" else "")
    else:
        a.cause = a.ending


def _stuck_class(reason) -> str:
    s = str(reason or "")
    if s == DEATH:
        return "death"
    if s in BAG:
        return "full bag or weight"
    if "interrupted too often" in s:
        return "interrupted too often"
    if s in ("no plan",) or "plan" in s.lower():
        return "no plan / planner error"
    return s[:40] or "no reason"


# ------------------------------------------------------------------ verdicts

def judge(asks: list[Ask], verdicts: dict) -> None:
    """Fill source, group and verdict on every ask (strict: unknown unless a harness row or the log shows it)."""
    by_log, lines = verdicts.get("by_log", {}), {k: set(v) for k, v in verdicts.get("lines", {}).items()}
    used: dict[str, set] = defaultdict(set)
    for a in asks:
        n = norm_line(a.line)
        base = Path(a.file).name
        if a.player == "Tester":
            rows = [(i, v) for i, v in enumerate(by_log.get(base, [])) if v["line"] == n and i not in used[base]]
            if rows:
                i, v = rows[0]
                used[base].add(i)
                a.source = v["source"]
                a.verdict_by, a.verdict_detail = v["source"], _cut(v.get("detail"), 200)
                done_at = v.get("done_at")
                if done_at is None and v.get("done_s") is not None:
                    try:
                        done_at = a.start + float(v["done_s"])
                    except (TypeError, ValueError):
                        done_at = None
                if not v["done"]:
                    a.verdict = "not_done"
                elif done_at is not None and done_at > a.end + DONE_GRACE_S:
                    a.verdict = "done_later"
                else:
                    a.verdict = "done"
            else:
                a.source = next((s for s in ("quest", "gate", "ladder", "build") if n in lines.get(s, set())),
                                "tester_other")
        a.group = "harness" if a.source == "quest" else "free"
    for i, a in enumerate(asks):
        if a.verdict != "unknown" or a.verdict_by:
            continue
        rep = next((b for b in asks[i + 1:] if b.file == a.file and b.player == a.player
                    and norm_line(b.line) == norm_line(a.line) and 0 <= b.start - a.end <= REPEAT_S), None)
        if rep:
            a.verdict, a.verdict_by = "not_done", "repeated"
            a.verdict_detail = f"same line again {rep.start - a.end:.0f} s after the end ({rep.id})"
        elif a.last_say and COULD_NOT.search(a.last_say):
            a.verdict, a.verdict_by = "not_done", "said_could_not"
            a.verdict_detail = a.last_say
        elif a.ending == "parked_by_him":
            a.verdict, a.verdict_by = "not_done", "parked_by_him"
            a.verdict_detail = a.closed_words


# ------------------------------------------------------------------ scanning

def _day(s: str) -> float:
    return _dt.datetime.strptime(s.replace("-", ""), "%Y%m%d").replace(tzinfo=UTC).timestamp()


def scan(since: str = "2026-11-01", until: str | None = None, root: Path = LOGS) -> list[Ask]:
    t0 = _day(since)
    t1 = _day(until) if until else 1e12
    now = time.time()
    progress = load_progress(root)
    verdicts = load_verdicts(root / "evals")
    asks: list[Ask] = []
    for f in sorted(glob.glob(str(root / "brain-live-*.jsonl"))):
        if now - os.path.getmtime(f) < FRESH_S:
            continue
        m = re.search(r"brain-live-(\d{8})", f)
        if m and (_day(m.group(1)) < t0 - 86400 or _day(m.group(1)) > t1 + 86400):
            continue
        rows = list(read_rows(f))
        found = [a for a in reconstruct(rows, progress, name=Path(f).name, end_ts=last_ts(f)) if t0 <= a.start < t1]
        asks.extend(found)
    judge(asks, verdicts)
    return asks


# ------------------------------------------------------------------ report

def _pct(n: int, d: int) -> str:
    return f"{n} of {d} ({100 * n / d:.0f} %)" if d else "0 of 0"


def summarize(asks: list[Ask]) -> dict:
    out: dict = {"asks": len(asks), "by_group": {}}
    for grp in ("all", "harness", "free"):
        sel = [a for a in asks if grp == "all" or a.group == grp]
        work = [a for a in sel if not a.talk_only]
        out["by_group"][grp] = {
            "asks": len(sel), "work_asks": len(work),
            "endings": dict(Counter(a.ending for a in sel).most_common()),
            "endings_work": dict(Counter(a.ending for a in work).most_common()),
            "verdicts": dict(Counter(a.verdict for a in sel).most_common()),
            "ending_x_verdict": {e: dict(Counter(a.verdict for a in sel if a.ending == e)) for e in
                                 sorted({a.ending for a in sel})},
            "not_done_causes": dict(Counter(a.cause for a in sel if a.verdict in ("not_done", "done_later")).most_common()),
            "eras": dict(Counter(a.era for a in sel)),
            "sources": dict(Counter(a.source for a in sel)),
            "open_ask": open_ask_summary(sel),
        }
    return out


def open_ask_summary(asks: list[Ask]) -> dict:
    """The open-ask turn (3ec85ff) over these asks. ``asks_seen``: asks whose log carries its rows (an open-ask turn,
    request_done_claimed / request_parked, or a request_closed saying whether the turn ran); ``turned``: those that got
    at least one open-ask turn; ``went_on``: one of its turns called something in the world (outcome world);
    ``closed_silent_after``: a second silent turn closed it (request_closed after_open_ask_turn); ``no_turn``: closed
    silent with no turn just before, by why (turn budget, deadline, the player spoke, had one this run, ...)."""
    seen = [a for a in asks if a.open_ask or a.ending in ("claimed_done", "parked_by_him")
            or a.closed_after_open_ask is not None]
    turned = [a for a in seen if a.open_ask]
    return {
        "asks_seen": len(seen), "turned": len(turned),
        "outcomes": dict(Counter(o for a in turned for o in a.open_ask).most_common()),
        "went_on": sum(1 for a in turned if "world" in a.open_ask),
        "closed_silent_after": sum(1 for a in seen if a.ending == "closed_silent" and a.closed_after_open_ask),
        "claimed_done": sum(1 for a in seen if a.ending == "claimed_done"),
        "parked_by_him": sum(1 for a in seen if a.ending == "parked_by_him"),
        "no_turn": dict(Counter(a.no_open_ask_turn or "?" for a in seen
                                if a.ending == "closed_silent" and a.closed_after_open_ask is False).most_common()),
        "endings_after_turn": dict(Counter(a.ending for a in turned).most_common()),
    }


def report(asks: list[Ask], as_json: bool = False) -> str:
    s = summarize(asks)
    if as_json:
        return json.dumps({"summary": s, "asks": [asdict(a) for a in asks]}, ensure_ascii=False, default=str)
    lines = [f"asks: {len(asks)} (era 1 before c019a6f: {sum(a.era == 1 for a in asks)}, era 2: "
             f"{sum(a.era == 2 for a in asks)})"]
    for grp, g in s["by_group"].items():
        n = g["asks"]
        lines.append(f"\n== {grp}: {n} asks ({g['work_asks']} with work), sources {g['sources']}")
        lines.append("ending                 all             verdicts (done / done_later / not_done / unknown)")
        for e, c in g["endings"].items():
            v = g["ending_x_verdict"].get(e, {})
            lines.append(f"  {e:20} {_pct(c, n):16} {v.get('done', 0)} / {v.get('done_later', 0)} / "
                         f"{v.get('not_done', 0)} / {v.get('unknown', 0)}")
        lines.append(f"  verdicts: {g['verdicts']}")
        nd = sum(g["not_done_causes"].values())
        for c, k in list(g["not_done_causes"].items())[:8]:
            lines.append(f"  not done: {_pct(k, nd):14} {c}")
        o = g["open_ask"]
        if o["asks_seen"]:
            lines.append(f"  open-ask turn (3ec85ff): {_pct(o['turned'], o['asks_seen'])} asks got one; went on "
                         f"{_pct(o['went_on'], o['turned'])}; closed silent after it {o['closed_silent_after']}; "
                         f"claimed done {o['claimed_done']}; parked by him {o['parked_by_him']}")
            lines.append(f"    turn outcomes {o['outcomes']}; closed silent with no turn {o['no_turn']}; "
                         f"endings after a turn {o['endings_after_turn']}")
    return "\n".join(lines)


def show(asks: list[Ask], ask_id: str, root: Path = LOGS) -> str:
    a = next((x for x in asks if x.id == ask_id), None)
    if a is None:
        return f"no ask {ask_id}"
    out = [_cut(json.dumps({k: v for k, v in asdict(a).items() if k not in ("goals",)}, default=str), 2000),
           *(f"goal: {_cut(g, 300)}" for g in a.goals), "--- rows in its life (bridge and prompts left out)"]
    for r in read_rows(root / a.file):
        if a.start - 1 <= r["ts"] <= a.end + 1:
            k = r.get("kind")
            if k == "llm_response":
                body = f"{r.get('component')} calls={_calls_of(r)}"
            else:
                body = _cut({x: y for x, y in r.items() if x not in ("ts", "kind", "episode_id", "call")}, 220)
            out.append(f"{_utc(r['ts'])[11:]} {str(r.get('episode_id'))[:16]:16} {k:18} {body}")
    return "\n".join(o[:CHUNK] for o in out)


def _load(args) -> list[Ask]:
    if getattr(args, "cache", None) and Path(args.cache).exists():
        return [Ask(**d) for d in json.loads(Path(args.cache).read_text(encoding="utf-8"))]
    asks = scan(args.since, args.until)
    if getattr(args, "cache", None):
        Path(args.cache).write_text(json.dumps([asdict(a) for a in asks], default=str), encoding="utf-8")
    return asks


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("report", "show"):
        p = sub.add_parser(name)
        p.add_argument("--since", default="2026-11-01")
        p.add_argument("--until", default=None)
        p.add_argument("--cache", default=None, help="a JSON file to keep the scan in (outside logs/)")
        if name == "report":
            p.add_argument("--json", action="store_true")
        else:
            p.add_argument("ask_id")
    args = ap.parse_args(argv)
    asks = _load(args)
    if args.cmd == "report":
        print(report(asks, args.json))
    else:
        print(show(asks, args.ask_id))
    return 0


if __name__ == "__main__":
    sys.exit(main())

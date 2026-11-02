r"""Score task windows to a human standard (docs/research/2026-11-01-evals-human-standard.md, sections 2 and 5).

  luis        Luis's "start <task>" ... "done" chat markers (client_io/events/chat.jsonl, every player's lines)
              x the server recorder (tools/recorder_io.py): per window the wall time, reaction, work time, path,
              straight line, speed, time-weighted travel score, idle, jitter, presses per gain, misses, the rpc
              sequence, hp lost and deaths. Writes logs/reports/standard-luis-<date>.md / .json.
  baselines   the same windows -> medians per task family -> data/baselines/luis-<date>.json (T_h for everything else)
  claude      Claude's request episodes from a brain log (tools/session_report.Session) x the recorder (ClaudeDev)
  coplay      the co-play fixture (evals/fixtures/coplay-2026-11-01-tasks.json: 17 tasks Luis asked for, each with
              a game-evidence check and its steps) scored from the brain + client logs alone (no recorder that day),
              then compared with the retro's verdict (docs/RETRO-2026-11-01-coplay.md), which the scorer never reads.

    .venv\Scripts\python.exe -m tools.standard_score luis [--since 2026-11-01T12:36Z]
    .venv\Scripts\python.exe -m tools.standard_score baselines
    .venv\Scripts\python.exe -m tools.standard_score claude --brain logs\brain-live-....jsonl [--who ClaudeDev]
    .venv\Scripts\python.exe -m tools.standard_score coplay

Markers: "start X" opens a window (a new start closes an open one as unclosed); "done" closes it; "the above was
start Y" renames the last window; "scrap that ..." / "actually scrap ..." scraps the open one (kept, flagged, not used
for baselines). Every other line of his is kept as a note on the open window or the session (knowledge, e.g.
"kebbits dont drop meat"). Chat ts are whole seconds, so window edges are +-1 s.

Standard levels (one task; T_h = REACT_S + the human's work time for the same steps, from the baselines file, else
provisional per-unit times marked as such):
  H  done, wall <= H_RATIO * T_h, 0 corrections, 0 fumbles, no death, told, no false claim
  A  done, wall <= max(A_RATIO * T_h, T_h + SLACK_S), <= 1 correction, <= max(1, items // 5) fumbles, no death,
     told, no false claim
  -  not to standard; every reason is listed
  corrections = the requester's lines after the request (later than BURST_S) and before done, other than another
  task's own request line; fumbles = failed body actions that were not cut by an interruption (logs), or presses
  with no effect (recorder); told = he said something between the request and DONE_TELL_S after done; false claim =
  a failure claim about a task the evidence shows done.
"""
from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

from tools import recorder_io as rio
from tools.timeline import parse_ts, short

ROOT = rio.ROOT
CHAT = ROOT / "client_io" / "events" / "chat.jsonl"
REPORTS = ROOT / "logs" / "reports"
BASELINES = ROOT / "data" / "baselines"
FIXTURE = ROOT / "evals" / "fixtures" / "coplay-2026-11-01-tasks.json"
COPLAY_LOG = ROOT / "logs" / "brain-live-20261101-115554-7128.jsonl"
LUIS = "luisdeburnaybastos"

REACT_S = 1.5          # a person hears a request and starts moving (the allowance in T_h)
V_RUN = 6.7            # m/s sprint: the travel part of T_h (Luis walks 4.5 m/s when he doesn't need to run)
V_SPRINT_MIN = 5.6     # a sample at least this fast is sprinting
H_RATIO, A_RATIO, SLACK_S = 1.5, 2.5, 10.0   # SLACK_S: two model round trips and a line, for tasks of a few seconds
BURST_S = 3.0          # lines this soon after the request are part of it
DONE_TELL_S = 20.0
JITTER_NET_M, JITTER_MAX_S = 2.5, 4.0   # a micro-move: under 2.5 m net in under 4 s
# Per-unit times until Luis's baselines cover a family (seconds; marked provisional in every report).
PROVISIONAL = {"pickup": 0.7, "drop": 1.0, "build": 5.5, "craft": 5.0, "cook": 12.0, "eat_drink": 1.5, "spell": 11.0,
               "kill": 10.0, "sleep": 3.0, "interact": 1.0, "collect_water": 8.0, "chop": 30.0, "mine": 12.0,
               "split": 3.0, "deconstruct": 3.0}
UNIT = {"pickup": "press with a gain", "drop": "drop rpc", "build": "build_spawn rpc", "craft": "craft rpc",
        "eat_drink": "use_item rpc"}   # every other family: one unit per task
FAMILIES = [  # first match wins (a marker's words -> family); eval-side labelling, not used by the brain
    ("travel", r"^(?:return|go|come|travel|run|walk|head)\b"),
    ("farm", r"\b(?:farm\w*|plant\w*|harvest\w*|compost\w*)\b"),
    ("collect_water", r"\b(?:gather|collect|get|fill)\b.*\bwater\b"),
    ("cook", r"\b(?:boil|cook)\b"),
    ("split", r"\bsplit\b"),
    ("drop", r"\b(?:pile|drop)\b"),
    ("kill", r"\b(?:use|shoot) (?:a |the |my )?(?:bow|crossbow)\b"),
    ("build", r"\b(?:build|foundation|table|fire ?pit|campfire|crate|wall|base|plot|tannery|spinning wheel|furnace)\b"),
    ("craft", r"\b(?:craft|make|made)\b|\bthread\b|^(?:stone )?(?:club|axe|pickaxe|hatchet)$"),
    ("spell", r"\b(?:splinter|rocksplosion|astral|totem|cast|spell|shelter)\b"),
    ("chop", r"\b(?:chop|fell)\b"),
    ("mine", r"\b(?:mine|mining)\b"),
    ("kill", r"\b(?:hunt|kill|attack|fight)\b"),
    ("sleep", r"\b(?:sleep|rest)\b"),
    ("eat_drink", r"\b(?:eat|drink)\b"),
    ("pickup", r"\b(?:sticks?|stones?|rocks?|flax|cabbage|berr\w*|pick\w*|loot|grab|food|gather\w*)\b"),
]
START_RX = re.compile(r"^\s*start\s+(.+?)\s*$", re.I)
# "done", "done make base", "stop farm", and his typos "sone", "wstop use bow", "wdstop"
DONE_RX = re.compile(r"^\W*(?:all )?(?:[a-z]{0,2}stop|done|sone|finished|end(?:ed)?)\b", re.I)
AFTER_NOTE_S = 60.0    # a line this soon after a window closed (before the next start) annotates that window
RENAME_RX = re.compile(r"^\s*(?:the )?(?:above|last one|previous one|that) was (?:start )?(.+?)\s*$", re.I)
SCRAP_RX = re.compile(r"^\s*(?:actually\s+)?(?:scrap|cancel|ignore|forget)\b(?:\s+(?:that|this|it))?[\s,.:;-]*(.*)$", re.I)
FAIL_CLAIM_RX = re.compile(r"\b(?:fail(?:ed|ing|s)?|didn'?t (?:work|place|go|land)|couldn'?t|can'?t|won'?t|not valid|invalid|"
                           r"no luck|isn'?t working)\b", re.I)


def iso(ts: float | None) -> str | None:
    return None if ts is None else datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def hms(ts: float | None) -> str:
    return "-" if ts is None else datetime.fromtimestamp(ts, timezone.utc).strftime("%H:%M:%S")


def med(xs):
    xs = [x for x in xs if isinstance(x, (int, float))]
    return round(statistics.median(xs), 2) if xs else None


def family(task: str) -> str:
    t = task.lower().strip()
    return next((f for f, rx in FAMILIES if re.search(rx, t)), "other")


# ------------------------------------------------------------------ chat markers
def chat_lines(since: float | None = None, until: float | None = None, path: Path = CHAT) -> list[dict]:
    out = []
    for line in open(path, encoding="utf-8", errors="replace"):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        ts = d.get("ts") if isinstance(d.get("ts"), (int, float)) else parse_ts(d.get("iso"))
        if ts is None or (since is not None and ts < since) or (until is not None and ts > until):
            continue
        out.append({"ts": float(ts), "player": d.get("from") or d.get("player"), "text": str(d.get("text") or "")})
    return out


def marker_windows(lines: list[dict], player: str = LUIS) -> tuple[list[dict], list[dict]]:
    """(windows, session notes) from one player's start/done lines; see the module docstring for the rules."""
    wins, notes, cur = [], [], None

    def close(ts: float, how: str) -> None:
        nonlocal cur
        if cur:
            cur.update(t1=ts, closed=how)
            wins.append(cur)
        cur = None

    for ln in lines:
        if not rio.same_player(ln["player"], player):
            continue
        text, ts = ln["text"].strip(), ln["ts"]
        if not text:
            continue
        if m := START_RX.match(text):
            close(ts, "unclosed")
            cur = {"task": m.group(1), "t0": ts, "t1": None, "closed": None, "notes": [], "renamed_from": None, "scrapped": None}
        elif DONE_RX.match(text):
            close(ts, "done")
        elif (m := RENAME_RX.match(text)) and (cur or wins):
            w = cur or wins[-1]
            w["renamed_from"], w["task"] = w["task"], m.group(1)
            notes.append({"ts": ts, "text": text, "kind": "rename"})
        elif (m := SCRAP_RX.match(text)) and cur:
            cur["scrapped"] = m.group(1) or text
            if m.group(1):
                notes.append({"ts": ts, "text": m.group(1), "kind": "knowledge", "task": cur["task"]})
            close(ts, "scrapped")
        elif cur:
            cur["notes"].append({"ts": ts, "text": text})
        elif wins and ts - wins[-1]["t1"] <= AFTER_NOTE_S:  # "(note this needed string ...)" right after a done
            wins[-1]["notes"].append({"ts": ts, "text": text, "after": True})
            notes.append({"ts": ts, "text": text, "kind": "note", "task": wins[-1]["task"]})
        else:
            notes.append({"ts": ts, "text": text, "kind": "note"})
    if cur:
        cur["closed"] = "open"
        wins.append(cur)
    for w in wins:
        w["family"] = family(w["task"])
    return wins, notes


# ------------------------------------------------------------------ one window from the recorder
def rle(names: list[str]) -> str:
    out: list[list] = []
    for n in names:
        if out and out[-1][0] == n:
            out[-1][1] += 1
        else:
            out.append([n, 1])
    return " > ".join(f"{n}x{c}" if c > 1 else n for n, c in out)


def score_window(rec: rio.Recording, who: str, t0: float, t1: float, fam: str = "other") -> dict:
    """What the recorder saw of one player in [t0, t1]: the human-standard measures (no verdict)."""
    ev = rec.events(who, t0, t1)
    moving = [s.ts for s in rec.track(who, t0, t1) if s.v >= rio.IDLE_V]
    marks = sorted(ev + moving)
    first, last = (marks[0], marks[-1]) if marks else (None, None)
    a, b = first or t0, max(last or t1, ev[-1] if ev else 0)
    tr = rec.track(who, a, b)
    path = rec.path(who, a, b)
    mv = [(s0, s1) for s0, s1 in zip(tr, tr[1:]) if s0.v >= rio.IDLE_V]
    moving_s = sum(min(s1.ts - s0.ts, 1.0) for s0, s1 in mv)
    still = rec.still_segments(who, a, b)
    bursts = rec.bursts(who, a, b)
    micro = [x for x in bursts if x["net_m"] < JITTER_NET_M and x["s"] < JITTER_MAX_S]
    presses = rec.presses(who, t0, t1)
    outs = Counter(p.outcome for p in presses)
    gained, lost = Counter(), Counter()
    for _, d in rec.inv_rows(who, t0, t1):
        for k, v in d.items():
            (gained if v > 0 else lost)[k] += abs(v)
    rpcs = rec.rpcs(who, t0, t1)
    kinds = Counter(r["rpc"] for r in rpcs)
    units = {"pickup": outs["gain"], "drop": kinds["drop"], "build": kinds["build_spawn"], "craft": kinds["craft"],
             "eat_drink": kinds["use_item"]}.get(fam) or 1
    # His own reaction to his own marker is at most REACT_S; a longer "reaction" is work the recorder can't see (a
    # spellbook, a crafting or inventory UI), so the work time is start-to-last-evidence less at most REACT_S.
    react = (first - t0) if first is not None else None
    work = ((last or t0) - t0) - min(react or 0.0, REACT_S)
    # unit_s leaves out the unavoidable straight-line travel (start to finish at V_RUN): T_h adds travel separately,
    # so a hunt's 300 m run to the chicken is not charged to every kill. Walking between items stays in the unit.
    unit = max(0.0, work - path["straight_m"] / V_RUN) / units
    t_opt = REACT_S + path["straight_m"] / V_RUN
    v = rec.vitals(who, t0, t1)
    return {
        "who": who, "t0": t0, "t1": t1, "wall_s": round(t1 - t0, 1),
        "reaction_s": round(react, 1) if react is not None else None,
        "work_s": round(work, 1), "seen_work_s": round(last - first, 1) if first is not None else 0.0,
        "active_s": round((last or t0) - t0, 1), "units": units, "unit_s": round(unit, 2),
        "path_m": path["path_m"], "straight_m": path["straight_m"], "reach_m": path["reach_m"], "teleports": path["teleports"],
        "spl": round(path["straight_m"] / path["path_m"], 2) if path["path_m"] >= 1 else None,
        "moving_s": round(moving_s, 1), "move_speed": round(path["path_m"] / moving_s, 2) if moving_s > 0.5 else None,
        "max_speed": round(max((s.v for s in tr), default=0.0), 2),
        "sprint_share": round(sum(1 for s in tr if s.v >= V_SPRINT_MIN) / max(1, sum(1 for s in tr if s.v >= rio.IDLE_V)), 2),
        "travel_sct": round(min(1.0, t_opt / max((last or t0) - t0, t_opt)), 2),
        "still_s": round(sum(x["s"] for x in still), 1), "idle_s": round(sum(x["s"] for x in still if not x["explained"]), 1),
        "idle_runs": [round(x["s"], 1) for x in still if not x["explained"]],
        "micro_moves": len(micro), "jitter_moves": sum(1 for x in micro if not x["productive"]),
        "jitter_s": round(sum(x["s"] for x in micro if not x["productive"]), 1),
        "heading_reversals": rec.heading_reversals(who, a, b),
        "presses": len(presses), "press_outcomes": dict(outs), "misses": outs["no_effect"],
        "presses_per_gain": round(len(presses) / outs["gain"], 2) if outs["gain"] else None,
        "press_latency_s": med([p.latency_s for p in presses if p.outcome == "gain"]),
        "far_presses": sum(1 for p in presses if p.by == "nearest_far"),
        "press_classes": dict(Counter(p.target_class for p in presses)),
        "gained": dict(gained), "lost": dict(lost), "items_gained": sum(gained.values()),
        "rpc_seq": rle([r["rpc"] for r in rpcs]), "rpc_attribution": dict(Counter(r["by"] for r in rpcs)),
        "hp_lost": v["hp_lost"], "deaths": v["deaths"], "min_vz": v["min_vz"],
        # ranged: the ability hook never fires, so a shot is one unit of ammo leaving the bag (ammo_gained: arrows
        # picked back up, or crafted)
        "shots": sum(-n for _, d in rec.inv_rows(who, t0, t1) for k, n in d.items() if "_Ammo_" in k and n < 0),
        "ammo_gained": sum(n for _, d in rec.inv_rows(who, t0, t1) for k, n in d.items() if "_Ammo_" in k and n > 0),
    }


def luis_windows(since: float | None = None, until: float | None = None, player: str = LUIS) -> tuple[list[dict], list[dict], rio.Recording]:
    lines = chat_lines(since, until)
    wins, notes = marker_windows(lines, player)
    if not wins:
        return [], notes, rio.Recording([], [])
    rec = rio.load(since=wins[0]["t0"], until=max((w["t1"] or w["t0"]) for w in wins) + 5)
    who = rec.canon(player)
    rows = []
    for w in wins:
        t1 = w["t1"] or (rec.track(who)[-1].ts if who and rec.track(who) else w["t0"])
        m = score_window(rec, who, w["t0"], t1, w["family"]) if who else {}
        rows.append({**{k: w[k] for k in ("task", "family", "closed", "renamed_from", "scrapped", "notes")},
                     "start": iso(w["t0"]), **m})
    return rows, notes, rec


def usable(r: dict) -> bool:
    return r.get("closed") == "done" and not r.get("scrapped") and r.get("work_s") is not None


def baselines(rows: list[dict]) -> dict:
    fams: dict[str, list[dict]] = {}
    for r in rows:
        if usable(r):
            fams.setdefault(r["family"], []).append(r)
    out = {}
    for f, xs in sorted(fams.items()):
        out[f] = {"n": len(xs), "tasks": [x["task"] for x in xs], "unit": UNIT.get(f, "task"),
                  "unit_s": med([x["unit_s"] for x in xs]), "work_s": med([x["work_s"] for x in xs]),
                  "wall_s": med([x["wall_s"] for x in xs]), "reaction_s": med([x["reaction_s"] for x in xs]),
                  "units": med([x["units"] for x in xs]), "path_m": med([x["path_m"] for x in xs]),
                  "move_speed": med([x["move_speed"] for x in xs]), "max_speed": med([x["max_speed"] for x in xs]),
                  "idle_s": med([x["idle_s"] for x in xs]), "jitter_moves": med([x["jitter_moves"] for x in xs]),
                  "presses_per_gain": med([x["presses_per_gain"] for x in xs]),
                  "misses": sum(x["misses"] for x in xs), "presses": sum(x["presses"] for x in xs),
                  "hp_lost": med([x["hp_lost"] for x in xs])}
    return out


def latest_baselines() -> dict:
    files = sorted(BASELINES.glob("luis-*.json"))
    return json.loads(files[-1].read_text(encoding="utf-8")) if files else {}


HUMAN_TASKS = ROOT / "evals" / "baselines" / "luis_20261101_tasks.json"   # the coordinator's per-task rows


def human_task(name: str, path: Path = HUMAN_TASKS) -> dict | None:
    """Luis's own row for a task, by name (case- and space-insensitive): the coordinator's per-task file (one row per
    marker task: name, start/end ts, duration_s, travel_m, moving_s, standing_s, longest_stand_s, presses, misses,
    crafts, builds, inventory in/out, order, notes). A list of rows or {"tasks": [...]}."""
    if not path.exists():
        return None
    data = json.loads(path.read_text(encoding="utf-8"))
    rows = data.get("tasks") if isinstance(data, dict) else data
    key = " ".join(name.lower().split())
    return next((r for r in rows or [] if " ".join(str(r.get("name") or r.get("task") or "").lower().split()) == key), None)


def t_human_task(name: str) -> float | None:
    """T_h for a task Luis did himself: his marker-to-marker duration (it includes his own reaction and typing
    "done", so it is a little lenient), None when he never did it."""
    r = human_task(name)
    d = (r or {}).get("duration_s")
    return float(d) if isinstance(d, (int, float)) and d > 0 else None


def unit_s(fam: str, base: dict | None = None) -> tuple[float, str]:
    """(seconds per unit, source) for a family: Luis's baseline when it has one, else the provisional table."""
    b = ((base if base is not None else latest_baselines()).get("families") or {}).get(fam) or {}
    if b.get("unit_s"):
        return float(b["unit_s"]), "luis"
    return PROVISIONAL.get(fam, 5.0), "provisional"


def t_human(steps: list, base: dict | None = None, travel_m: float = 0.0) -> tuple[float, list[str], bool]:
    """T_h for a list of [family, units] steps (["travel", metres]); (seconds, the parts, any part provisional)."""
    base = latest_baselines() if base is None else base
    v = base.get("travel_speed_mps") or V_RUN   # his measured speed over ground on runs of >= 50 m, else sprint speed
    total, parts, prov = REACT_S, [f"react {REACT_S}"], False
    for fam, n in steps:
        if fam == "travel":
            m = travel_m if n == "auto" else float(n)
            total += m / v
            parts.append(f"travel {m:.0f} m/{v:g}")
            continue
        u, src = unit_s(fam, base)
        prov |= src == "provisional"
        total += u * n
        parts.append(f"{fam} {n}x{u:g}{'*' if src == 'provisional' else ''}")
    return round(total, 1), parts, prov


# Read-only lookups change nothing in the world and their time is already in the time bar: an ambiguous or not-found
# answer from one is no miss (main 2026-11-02). World actions that failed, and action collisions (still_running), are.
READ_ONLY_TOOLS = frozenset({"craft_plan", "recipes", "inventory", "look", "inspect", "stations", "buildables", "where",
                             "world_info", "quests", "lodestones", "spells", "get_state", "my_places", "recall"})
NO_MISS_REASONS = frozenset({"interrupted"})


def count_fumbles(brain: list[dict]) -> int:
    """The misses of a leg from its brain-log tool results: failed calls, less interruptions (the player spoke or
    another command took over) and read-only lookups (READ_ONLY_TOOLS). One rule for every gate (rung1/3/4, farm, coplay)."""
    n = 0
    for r in brain:
        res = r.get("result") or {}
        if r.get("kind") != "tool_result" or res.get("ok") is not False:
            continue
        if res.get("reason") in NO_MISS_REASONS or r.get("tool") in READ_ONLY_TOOLS:
            continue
        n += 1
    return n


def level(done: bool, wall_s: float | None, t_h: float, corrections: int, fumbles: int, items: int, deaths: int,
          told: bool, false_claims: int, timed: bool = True) -> tuple[str | None, list[str]]:
    """(H | A | None, the reasons it is not H / not A). timed=False leaves the time test out (the "clean" reading:
    done without babysitting, whatever it took)."""
    if not done:
        return None, ["not done"]
    why_h, why_a = [], []
    ratio = wall_s / t_h if t_h else 99.0
    if timed and wall_s > max(A_RATIO * t_h, t_h + SLACK_S):
        why_a.append(f"{wall_s:.0f} s = {ratio:.1f}x T_h {t_h:.0f} s")
    elif timed and ratio > H_RATIO:
        why_h.append(f"{ratio:.1f}x T_h")
    if corrections:
        (why_a if corrections > 1 else why_h).append(f"{corrections} corrections")
    if fumbles:
        (why_a if fumbles > max(1, items // 5) else why_h).append(f"{fumbles} fumbles")
    for bad, txt in ((deaths, f"{deaths} deaths"), (not told, "never told"), (false_claims, f"{false_claims} false claims")):
        if bad:
            why_a.append(txt)
    if why_a:
        return None, why_a + why_h
    return ("A", why_h) if why_h else ("H", [])


# ------------------------------------------------------------------ co-play fixture (logs only, no recorder)
def _get(d: dict, dotted: str):
    for k in dotted.split("."):
        d = d.get(k) if isinstance(d, dict) else None
    return d


def _results(sess) -> list[dict]:
    out = []
    for t in sess.brain.tools:
        if t.read_only or t.tool == "say":
            continue
        b = t.body
        end = (b.end if b and b.end else None) or t.result_ts
        ok = b.ok if b and b.ok is not None else t.ok
        out.append({"ts": t.ts, "end": end, "tool": t.tool, "args": t.args or {}, "ok": ok,
                    "reason": (b.reason if b and b.reason else t.reason),
                    "data": (b.data if b and b.data else t.data) or {}})
    return [r for r in out if r["end"] is not None]


def _match(r: dict, c: dict) -> bool:
    if c.get("tool") and not re.fullmatch(c["tool"], r["tool"]):
        return False
    if "ok" in c and bool(r["ok"]) != c["ok"]:
        return False
    if c.get("item"):
        hay = " ".join(str(x) for x in (r["args"].get("item"), r["args"].get("piece"), r["args"].get("target"),
                                         r["args"].get("resource"), r["args"].get("to"), r["data"].get("item"),
                                         r["data"].get("piece"), r["data"].get("target"), r["data"].get("source"),
                                         r["data"].get("detail")))
        if not re.search(c["item"], hay, re.I):
            return False
    for k, v in (c.get("data") or {}).items():
        if not re.fullmatch(str(v), str(_get(r["data"], k)), re.I):
            return False
    for k, v in (c.get("args") or {}).items():
        if str(r["args"].get(k)) != str(v):
            return False
    return True


def check_at(c: dict, results: list[dict], stats: list[tuple[float, str, float]], t0: float, t1: float) -> float | None:
    """When the check became true in [t0, t1] (None: never)."""
    if "all" in c:
        ts = [check_at(x, results, stats, t0, t1) for x in c["all"]]
        return None if any(t is None for t in ts) else max(ts)
    if "any" in c:
        ts = [t for x in c["any"] if (t := check_at(x, results, stats, t0, t1)) is not None]
        return min(ts) if ts else None
    if c.get("never"):
        return None
    if "stat_ge" in c:
        need, have, when = c["stat_ge"], {}, None
        for ts, stat, val in stats:
            if ts < t0 or ts > t1:
                continue
            have[stat] = val
            if all(have.get(k, -1) >= v for k, v in need.items()):
                return ts
        return when
    hits = [r["end"] for r in results if t0 <= r["ts"] and r["end"] <= t1 and _match(r, c)]
    if c.get("last"):
        return hits[-1] if hits else None
    n = c.get("n", 1)
    return hits[n - 1] if len(hits) >= n else None


def coplay(fixture: Path = FIXTURE, brain: Path | None = None, base: dict | None = None) -> dict:
    from tools.session_report import Session  # the telemetry agent's correlator: requests, tools, says, trips, vitals
    fx = json.loads(fixture.read_text(encoding="utf-8"))
    sess = Session(Path(brain or ROOT / fx["brain_log"]))
    base = latest_baselines() if base is None else base
    day = fx["date"]
    T = lambda s: parse_ts(f"{day}T{s}Z")  # noqa: E731
    results = _results(sess)
    stats = sorted([(r["end"], r["data"]["stat"], float(r["data"]["after"])) for r in results
                    if r["tool"] == "consume" and r["ok"] and r["data"].get("stat") and r["data"].get("after") is not None]
                   + [(float(v["_ts"] if "_ts" in v else v["ts"]), k, float(v[k][0])) for v in sess.vitals
                      if v.get("type") == "survival" for k in ("sustenance", "hydration") if isinstance(v.get(k), list)])
    deaths = [float(v.get("_ts") or v.get("ts")) for v in sess.vitals if v.get("type") == "death"]
    lines = sorted((ts, p, txt) for e in sess.requests for ts, p, txt, note in e.lines if not note)
    says = sess.brain.says
    req_ts = [T(t["t0"]) for t in fx["tasks"]]
    rows = []
    for t in fx["tasks"]:
        t0, t1 = T(t["t0"]), T(t["t1"])
        done_at = check_at(t["check"], results, stats, t0, t1)
        end = done_at or t1
        trips = [x for x in sess.trips if t0 <= float(x.get("_ts") or x["ts"]) - float(x.get("s") or 0) + 1 and
                 float(x.get("_ts") or x["ts"]) <= end + 1]
        travel = float(trips[0].get("d0_m") or 0) if trips else 0.0
        th, parts, prov = t_human(t["steps"], base, travel)
        if t.get("human_task") and (own := t_human_task(t["human_task"])):  # he did this very task himself
            th, parts, prov = own, [f"Luis's own '{t['human_task']}' {own:g} s"], False
        mine = [(ts, txt) for ts, p, txt in lines if rio.same_player(p, fx["player"]) and t0 + BURST_S < ts < end - 0.5
                and not any(abs(ts - r) < BURST_S for r in req_ts if r != t0)]
        corr = []  # one correction per burst: "come to me now / stop / claude come to me now" is one intervention
        for ts, txt in mine:
            if corr and ts - corr[-1][2] <= BURST_S:
                corr[-1] = (corr[-1][0], corr[-1][1] + " / " + txt, ts)
            else:
                corr.append((ts, txt, ts))
        fails = [r for r in results if t0 <= r["ts"] < end and r["ok"] is False and r["reason"] not in ("interrupted",)]
        dead = [d for d in deaths if t0 <= d <= end]
        told = any(t0 <= s0 <= end + DONE_TELL_S for s0, _, _ in says)
        false = [txt for s0, _, txt in says if done_at and done_at <= s0 <= t1 + 10 and FAIL_CLAIM_RX.search(txt)
                 and re.search(t.get("subject") or r"\w", txt, re.I)]
        items = sum(n for f, n in t["steps"] if f != "travel" and isinstance(n, (int, float)))
        wall = round(end - t0, 1)
        args = (done_at is not None, wall, th, len(corr), len(fails), items, len(dead), told, len(false))
        lv, why = level(*args)
        clean, _ = level(*args, timed=False)
        rows.append({"id": t["id"], "request": t["request"], "start": t["t0"], "done": done_at is not None,
                     "done_at": hms(done_at), "wall_s": wall, "t_h": th, "t_h_parts": parts, "t_h_provisional": prov,
                     "ratio": round(wall / th, 1), "clean": bool(clean),
                     "corrections": len(corr), "correction_lines": [short(x, 70) for _, x, _ in corr][:6],
                     "fumbles": len(fails), "fumble_reasons": dict(Counter(r["reason"] for r in fails)),
                     "deaths": len(dead), "told": told, "false_claims": [short(x, 90) for x in false][:3],
                     "level": lv, "why": why, "retro": t.get("retro", {})})
    n = len(rows)
    std = [r for r in rows if r["level"]]
    agree = sum(1 for r in rows if bool(r["level"]) == bool(r["retro"].get("clean")))
    agree_clean = sum(1 for r in rows if r["clean"] == bool(r["retro"].get("clean")))
    return {"fixture": str(fixture.relative_to(ROOT)), "brain_log": fx["brain_log"], "tasks": rows, "n": n,
            "to_standard": len(std), "H": sum(1 for r in rows if r["level"] == "H"),
            "clean": sum(1 for r in rows if r["clean"]), "done": sum(1 for r in rows if r["done"]),
            "retro_clean": sum(1 for r in rows if r["retro"].get("clean")),
            "agreement": f"{agree}/{n}", "agreement_clean": f"{agree_clean}/{n}",
            "disagree": [r["id"] for r in rows if r["clean"] != bool(r["retro"].get("clean"))],
            "baselines": base.get("generated"), "distinct": fx.get("distinct")}


# ------------------------------------------------------------------ Claude's requests x the recorder
def claude_windows(brain: Path, who: str = "ClaudeDev") -> list[dict]:
    from tools.session_report import Session
    sess = Session(brain)
    reqs = sess.request_rows()
    if not reqs:
        return []
    rec = rio.load(since=reqs[0]["t0"], until=reqs[-1]["t0"] + reqs[-1]["done_s"])
    w = rec.canon(who)
    out = []
    for r in reqs:
        t0, t1 = r["t0"], r["t0"] + r["done_s"]
        m = score_window(rec, w, t0, t1, family(r["text"])) if w and rec.track(w, t0, t1) else {}
        out.append({"request": short(r["text"], 70), "family": family(r["text"]), "outcome": r["outcome"],
                    "start": iso(t0), "corrections_next_line_s": r["next_line_s"], **m})
    return out


# ------------------------------------------------------------------ output
COLS = [("task", 26), ("family", 13), ("closed", 8), ("wall_s", 6), ("reaction_s", 5), ("work_s", 6), ("units", 5),
        ("unit_s", 6), ("path_m", 6), ("straight_m", 6), ("move_speed", 5), ("sprint_share", 5), ("idle_s", 5),
        ("jitter_moves", 4), ("presses", 4), ("misses", 4), ("presses_per_gain", 5), ("hp_lost", 5), ("deaths", 3)]


def table(rows: list[dict], cols=COLS) -> str:
    head = "| " + " | ".join(c for c, _ in cols) + " |\n|" + "---|" * len(cols) + "\n"
    return head + "".join("| " + " | ".join(short(r.get(c), w + 20) if r.get(c) is not None else "-" for c, w in cols) + " |\n"
                          for r in rows)


def write(name: str, md: str, data: dict) -> tuple[Path, Path]:
    REPORTS.mkdir(parents=True, exist_ok=True)
    pm, pj = REPORTS / f"standard-{name}.md", REPORTS / f"standard-{name}.json"
    pm.write_text(md, encoding="utf-8")
    pj.write_text(json.dumps(data, indent=1, ensure_ascii=False, default=str), encoding="utf-8")
    return pm, pj


def cmd_luis(a) -> int:
    rows, notes, rec = luis_windows(parse_ts(a.since) if a.since else None, parse_ts(a.until) if a.until else None)
    if not rows:
        print("no start/done markers")
        return 1
    day = (rows[0]["start"] or "")[:10]
    md = (f"# Luis's task windows, {day} (tools/standard_score.py)\n\nRecorder: {', '.join(p.name for p in rec.paths)}; "
          f"chat: client_io/events/chat.jsonl. Windows {len(rows)}, usable {sum(map(usable, rows))}.\n\n" + table(rows) +
          "\nNotes he made (knowledge):\n" + "".join(f"- {hms(n['ts'])} {n['text']}\n" for n in notes) +
          "".join(f"- {r['task']}: {n['text']}\n" for r in rows for n in r["notes"]))
    pm, pj = write(f"luis-{day}", md, {"windows": rows, "notes": notes, "recordings": [p.name for p in rec.paths]})
    print(md)
    print(f"wrote {pm.relative_to(ROOT)}, {pj.relative_to(ROOT)}")
    return 0


def cmd_baselines(a) -> int:
    rows, notes, rec = luis_windows(parse_ts(a.since) if a.since else None, parse_ts(a.until) if a.until else None)
    if not rows:
        print("no start/done markers")
        return 1
    day = (rows[0]["start"] or "")[:10]
    fams = baselines(rows)
    out = {"player": LUIS, "date": day, "generated": iso(datetime.now(timezone.utc).timestamp()),
           "recordings": [p.name for p in rec.paths], "chat": "client_io/events/chat.jsonl",
           "method": "Luis's start/done chat markers x the server recorder (tools/standard_score.py luis); work_s = start marker to "
                     "his last recorder evidence (movement, rpc, inventory change), less at most REACT_S of reaction (a longer "
                     "one is spellbook / UI work the recorder can't see); unit_s = (work_s - straight_m / V_RUN) / units; "
                     "medians per family over closed, unscrapped windows. T_h = REACT_S + sum(units x unit_s) + travel / V_RUN.",
           "constants": {"REACT_S": REACT_S, "V_RUN": V_RUN, "IDLE_V": rio.IDLE_V, "IDLE_MIN_S": rio.IDLE_MIN_S,
                         "GAIN_S": rio.GAIN_S, "H_RATIO": H_RATIO, "A_RATIO": A_RATIO, "SLACK_S": SLACK_S},
           "travel_speed_mps": med([r["move_speed"] for r in rows if usable(r) and (r.get("straight_m") or 0) >= 50]),
           "families": fams,
           "knowledge": [{"task": n.get("task"), "text": n["text"], "at": iso(n["ts"])} for n in notes
                         if n.get("kind") in ("knowledge", "note")] +
                        [{"task": r["task"], "text": n["text"], "at": iso(n["ts"])} for r in rows for n in r["notes"]
                         if not n.get("after")],
           "windows": [{k: r.get(k) for k in ("task", "family", "start", "closed", "renamed_from", "scrapped", "wall_s",
                                              "reaction_s", "work_s", "units", "unit_s", "path_m", "move_speed", "idle_s",
                                              "jitter_moves", "presses", "misses", "presses_per_gain", "rpc_seq", "gained")}
                       for r in rows]}
    BASELINES.mkdir(parents=True, exist_ok=True)
    p = BASELINES / f"luis-{day}.json"
    p.write_text(json.dumps(out, indent=1, ensure_ascii=False), encoding="utf-8")
    cols = [("family", 13), ("n", 2), ("unit", 16), ("unit_s", 6), ("work_s", 6), ("wall_s", 6), ("reaction_s", 5),
            ("move_speed", 5), ("idle_s", 5), ("presses_per_gain", 5), ("misses", 3), ("tasks", 50)]
    print(table([{"family": f, **v} for f, v in fams.items()], cols))
    print(f"wrote {p.relative_to(ROOT)}")
    return 0


def cmd_claude(a) -> int:
    rows = claude_windows(Path(a.brain), a.who)
    if not rows:
        print("no requests in that brain log")
        return 1
    cols = [("request", 40), ("family", 10), ("outcome", 14)] + COLS[3:]
    md = f"# Claude's requests x the recorder ({Path(a.brain).name})\n\n" + table(rows, cols)
    pm, _ = write(f"claude-{Path(a.brain).stem}", md, {"windows": rows})
    print(md + f"\nwrote {pm.relative_to(ROOT)}")
    return 0


def cmd_coplay(a) -> int:
    res = coplay(Path(a.fixture), Path(a.brain) if a.brain else None)
    cols = [("id", 22), ("done", 5), ("done_at", 8), ("wall_s", 6), ("t_h", 5), ("ratio", 5), ("corrections", 3),
            ("fumbles", 3), ("deaths", 2), ("told", 5), ("clean", 5), ("level", 3), ("why", 50)]
    rows = [{**r, "why": "; ".join(r["why"]), "level": r["level"] or "-",
             "retro": f"{r['retro'].get('outcome')}{' (clean)' if r['retro'].get('clean') else ''}"} for r in res["tasks"]]
    md = (f"# Co-play 2026-11-01 to a human standard (tools/standard_score.py coplay)\n\n"
          f"{res['n']} tasks ({res.get('distinct')} distinct); done by the evidence {res['done']}; clean (done, <= 1 correction, "
          f"fumbles within allowance, no death, told, no false claim; no time test) {res['clean']}, agreement with the retro's "
          f"clean ({res['retro_clean']}) {res['agreement_clean']} (differs: {', '.join(res['disagree']) or 'none'}); to the "
          f"human standard incl. time (A or H) {res['to_standard']} (H {res['H']}), agreement {res['agreement']}. "
          f"T_h from {'baselines ' + str(res['baselines']) if res['baselines'] else 'the provisional table'} (* = provisional).\n\n"
          + table(rows, cols + [("retro", 22)]) + "\n" +
          "".join(f"- {r['id']}: T_h = {' + '.join(r['t_h_parts'])}; corrections {r['correction_lines']}; fumbles "
                  f"{r['fumble_reasons']}; false claims {r['false_claims']}\n" for r in res["tasks"]))
    pm, _ = write("coplay-2026-11-01", md, res)
    print(md + f"\nwrote {pm.relative_to(ROOT)}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("luis", "baselines"):
        p = sub.add_parser(name)
        p.add_argument("--since", default="2026-11-01T12:36:00Z")
        p.add_argument("--until")
    c = sub.add_parser("claude")
    c.add_argument("--brain", required=True)
    c.add_argument("--who", default="ClaudeDev")
    v = sub.add_parser("coplay")
    v.add_argument("--fixture", default=str(FIXTURE))
    v.add_argument("--brain")
    a = ap.parse_args(argv)
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    return {"luis": cmd_luis, "baselines": cmd_baselines, "claude": cmd_claude, "coplay": cmd_coplay}[a.cmd](a)


if __name__ == "__main__":
    raise SystemExit(main())

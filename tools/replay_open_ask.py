r"""Replay the turn after a silent stop with a player's ask still open, under structural variants of what he is shown.

The failure (docs/research/2026-11-17-stop-with-request-open.md, docs/RETRO-2026-11-17-session.md row 4): a turn with no
tool call closes the player's ask (brain/agent.py, `request_closed`), and nothing checks the game. This tool takes each
recorded closing turn, adds the one more turn the code would run if the ask stayed open, and asks Haiku what he does
next under each variant. Nothing runs against the game, client or brain: the messages and tools are the logged ones.

Variants (what the extra turn shows; never what to do):
  A   today: no extra turn. Counts as stopped. No call.
  A1  calibration: the closing call itself re-sent as logged (does the replay reproduce the live stop?).
  B   one more turn: the silent reply, a fresh observation, and the open ask as data: his words, how long ago, and the
      verified changes since (bag, worn, quest steps) read from the body's own state rows.
  C   B, and the tool list offers request_done(evidence) and park_request(reason); their descriptions say the
      request stays open until one of them is called.
  D   B, and the end state as game data: the quest log (active steps, complete), his armour power level against the
      best he can reach (brain/gear_plan.py), and the graves he remembers.

Cases: every request_closed since the logs begin (15 Nov), the runs that heard a goal end that came from an ask and
stopped with no world call, and the grave gate runs. Side "open" when the evidence says the ask was not done at the
close (logs/evals/quest_runs.jsonl: the quest not complete yet; rung gate: leg done false); side "done" otherwise.

  .venv\Scripts\python.exe -m tools.replay_open_ask cases               # list the cases (no calls)
  .venv\Scripts\python.exe -m tools.replay_open_ask run --k 2 --yes     # plan, then call (Haiku only)
  .venv\Scripts\python.exe -m tools.replay_open_ask report FILE         # score a results file again (no calls)

Results: logs/evals/replay_open_ask-<ts>.jsonl (each call's usage row, so tools/spend.py counts it, and one
`replay` row per sample). Prompt cache: no nonce, so calls of one case share the cached prefix (cost); see the doc.
"""
from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import math
import os
import random
import re
import sys
import time
from pathlib import Path

from brain import paths

ROOT = paths.REPO_ROOT
LOGS = ROOT / "logs"
QUEST_RUNS = LOGS / "evals" / "quest_runs.jsonl"
GATES = sorted(glob.glob(str(LOGS / "evals" / "rung*_gate.jsonl")))
VARIANTS = ("A", "A1", "B", "C", "D")
CALLED = ("A1", "B", "C", "D")
# Cases whose evidence disagrees with itself: the grave gate judged these legs not done (10 of 12 items back at the
# window's end), yet the state read at the close shows all 12 (+6 Fillet, +6 Clean Water): the reflex ate and drank 2
# after. Left out of both sides.
EXCLUDE = {"20261115-221648-18012:chat-0002-9c70": "gate says not done, the bag at the close has all 12 items",
           "20261115-221916-412:chat-0002-1483": "gate says not done, the bag at the close has all 12 items"}
MAX_PROMPT = 95_000  # Haiku 5.5 pays 5x over 100k prompt tokens: such cases are left out

# Tool classes for the rubric (names from the logged tool lists). Reads run inline in the live loop and the model then
# goes on; in a replay they end the sample, so they are their own outcome.
READS = {"agility_courses", "buildables", "combat_brief", "craft_plan", "farm_plots", "fishing_spots", "held_actions",
         "inspect", "inventory", "lodestones", "look", "quests", "recipes", "spells", "stations", "lookup",
         "list_skills", "food_options", "remember", "forget_skill"}
CLOSERS = {"request_done": "done_claim", "park_request": "park"}
NEED_CONSUME = {"consume", "collect_water", "set_vitals_policy"}

PARK_TOOL = {"type": "function", "function": {
    "name": "park_request",
    "description": "Stop working on the player's open request for now. The player hears the reason. The request stays "
                   "open until park_request or request_done is called.",
    "parameters": {"type": "object", "properties": {"reason": {
        "type": "string", "description": "Why it stops here, in a few plain words the player reads."}},
        "required": ["reason"]}}}
DONE_TOOL = {"type": "function", "function": {
    "name": "request_done",
    "description": "Close the player's open request as finished. The request stays open until request_done or "
                   "park_request is called.",
    "parameters": {"type": "object", "properties": {"evidence": {
        "type": "string", "description": "What in the game shows it is finished (quest log, bag, what you wear)."}},
        "required": ["evidence"]}}}


# ------------------------------------------------------------------ log reading (pure)


def read_jsonl(path) -> list[dict]:
    out = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    try:
                        out.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
    except FileNotFoundError:
        pass
    return out


def episode_calls(rows: list[dict], episode: str) -> list[tuple[int, list[dict], dict, list | None, dict]]:
    """(row index, full messages, live response row, tools, settings) per Controller call of the episode, as
    tools/replay_episode.py rebuilds them (a request's first call logs all messages and the tools, later ones add)."""
    msgs: list[dict] = []
    tools = None
    out = []
    for i, r in enumerate(rows):
        if r.get("kind") == "prompt" and r.get("component") == "controller" and r.get("episode_id") == episode:
            if not r.get("messages_from"):
                msgs, tools = [], r.get("tools") or tools
            if (r.get("messages_from") or 0) != len(msgs):
                raise ValueError(f"row {i}: messages_from {r.get('messages_from')} != {len(msgs)}")
            msgs = msgs + r["messages"]
            live = next((x for x in rows[i + 1:] if x.get("kind") == "llm_response"), None)
            if live is not None:
                out.append((i, list(msgs), live, tools, r.get("settings") or {}))
    return out


def body_states(rows: list[dict]) -> list[tuple[float, dict]]:
    """(ts, data) of every full state read the body sent back (get_state answers)."""
    out = []
    for r in rows:
        if r.get("kind") == "bridge_recv":
            d = (r.get("msg") or {}).get("data")
            if isinstance(d, dict) and "nearby_entities" in d and "inventory" in d:
                out.append((r["ts"], d))
    return out


def state_at(states: list[tuple[float, dict]], ts: float, after: bool) -> dict | None:
    """The first state read at or after ts (after=True), or the last one at or before it."""
    if after:
        return next((d for t, d in states if t >= ts), None)
    return next((d for t, d in reversed(states) if t <= ts), None)


def heard_at(rows: list[dict], words: str) -> float | None:
    for r in rows:
        e = r.get("event") if r.get("kind") == "event" else None
        if isinstance(e, dict) and e.get("type") == "chat_heard" and e.get("text") == words:
            return r["ts"]
    return None


def goal_request(messages: list[dict]) -> tuple[str | None, str] | None:
    """The (player, words) a goal_done in the request's first user message came from."""
    found = []

    def walk(v):
        if isinstance(v, dict):
            if v.get("type") == "goal_done" and v.get("request"):
                found.append((v.get("from"), v["request"]))
            for x in v.values():
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)

    for m in messages:
        if m.get("role") == "user" and isinstance(m.get("content"), str):
            try:
                walk(json.loads(m["content"]))
            except ValueError:
                continue
    return found[0] if found else None


# ------------------------------------------------------------------ facts (pure)


def _name(item: str, names: dict[str, str], cat: dict) -> str:
    if item in names:
        return names[item]
    n = (cat.get(item) or {}).get("name")
    return n or re.sub(r"^ITEM_", "", str(item)).replace("_", " ")


def _names_of(*states: dict | None) -> dict[str, str]:
    out = {}
    for s in states:
        for row in (s or {}).get("inventory_items") or []:
            if isinstance(row, dict) and row.get("item") and row.get("name"):
                out[row["item"]] = row["name"]
    return out


WORN = (("head", "Head"), ("body", "Body"), ("legs", "Legs"), ("right_hand", "held_right"), ("left_hand", "held_left"),
        ("back", "Back"))


def worn(state: dict | None, names: dict, cat: dict) -> dict[str, str | None]:
    g = (state or {}).get("gear") or {}
    return {slot: (_name(g[key], names, cat) if g.get(key) else None) for slot, key in WORN}


def quest_log(state: dict | None) -> dict:
    q = (state or {}).get("quests") or {}
    return {"active": [{"quest": a.get("quest"), "step": (a.get("step") or "").strip()}
                       for a in q.get("active") or [] if isinstance(a, dict)],
            "complete": list(q.get("complete") or [])}


def changes(before: dict | None, after: dict | None, cat: dict | None = None, limit: int = 12) -> dict:
    """What changed between two state reads: bag counts, worn slots, quest steps. Facts only."""
    cat = cat or {}
    names = _names_of(before, after)
    out: dict = {}
    b_inv = {k: int(v) for k, v in ((before or {}).get("inventory") or {}).items() if isinstance(v, (int, float))}
    a_inv = {k: int(v) for k, v in ((after or {}).get("inventory") or {}).items() if isinstance(v, (int, float))}
    delta = {k: a_inv.get(k, 0) - b_inv.get(k, 0) for k in set(b_inv) | set(a_inv)}
    delta = sorted(((k, d) for k, d in delta.items() if d), key=lambda kd: (-abs(kd[1]), kd[0]))
    out["bag"] = {_name(k, names, cat): (f"+{d}" if d > 0 else str(d)) for k, d in delta[:limit]} or "no change"
    wb, wa = worn(before, names, cat), worn(after, names, cat)
    out["worn"] = {s: f"{wb[s] or 'nothing'} -> {wa[s] or 'nothing'}" for s in wb if wb[s] != wa[s]} or "no change"
    qb, qa = quest_log(before), quest_log(after)
    steps_b = {a["quest"]: a["step"] for a in qb["active"]}
    q = {}
    for a in qa["active"]:
        if a["quest"] not in steps_b:
            q[a["quest"]] = f"new: {a['step']}"
        elif steps_b[a["quest"]] != a["step"]:
            q[a["quest"]] = f"{steps_b[a['quest']]} -> {a['step']}"
    for name in qa["complete"]:
        if name not in qb["complete"]:
            q[name] = "completed" + (f" (still active: {next(a['step'] for a in qa['active'] if a['quest'] == name)})"
                                     if any(a["quest"] == name for a in qa["active"]) else "")
    out["quests"] = q or "no change"
    return out


def end_state(state: dict | None, cat: dict | None = None) -> dict:
    """Variant D: game data that says how far things stand, the same block for every ask (no ask-to-kind mapping)."""
    out: dict = {"quest_log": quest_log(state)}
    try:
        from brain import gear_plan
        p = gear_plan.plan(state or {})
        if p:
            out["gear"] = {"armour_pl_now": p.get("pl_now"), "armour_pl_best_reachable": p.get("pl_full_set"),
                           "slots_below_best": {s: {"worn": v.get("worn"), "worn_pl": v.get("worn_pl"),
                                                    "best_pl": v.get("best_pl")}
                                                for s, v in (p.get("slots") or {}).items()
                                                if v.get("best_pl") is not None
                                                and (v.get("worn_pl") or 0) < v["best_pl"]}}
    except Exception as exc:  # the gear profile is best effort here too
        out["gear"] = f"unavailable ({type(exc).__name__})"
    graves = (state or {}).get("graves_remembered") or []
    out["graves_remembered"] = [{"distance_m": g.get("distance"), "items": g.get("lost_items"),
                                 "go_to": g.get("go_to")} for g in graves[:3] if isinstance(g, dict)] or "none"
    return out


# ------------------------------------------------------------------ variants (pure)


def open_block(case: dict, variant: str) -> dict:
    block = {"player": case["player"], "words": case["words"], "asked_s_ago": case["age_s"],
             "changed_since_asked": case["changes"]}
    if variant == "C":
        block["open_until"] = "request_done or park_request is called"
    if variant == "D":
        block["game_state_now"] = case["end_state"]
    return {"open_request": block}


def silent_turn(live: dict) -> list[dict]:
    """The closing reply as the next request carries it, with a result for each call it made (a say)."""
    calls = live.get("tool_calls") or []
    msg: dict = {"role": "assistant", "content": live.get("content") or (None if calls else "")}
    if calls:
        msg["tool_calls"] = [{"id": c.get("id") or f"call_{i}", "type": "function",
                              "function": {"name": c["name"], "arguments": json.dumps(c.get("arguments") or {})}}
                             for i, c in enumerate(calls)]
    out = [msg]
    for i, c in enumerate(calls):
        out.append({"role": "tool", "tool_call_id": c.get("id") or f"call_{i}",
                    "content": json.dumps({"ok": True, "note": "said"} if c["name"] == "say" else {"ok": None})})
    return out


def build_request(case: dict, variant: str) -> tuple[list[dict], list[dict]]:
    """(messages, tools) of one replayed call."""
    msgs, tools = case["messages"], list(case["tools"] or [])
    if variant == "A1":
        return msgs, tools
    from brain.controller import current_observation
    obs = current_observation(case["state_now"])
    obs["situation"] = "unchanged since you last saw it"
    extra = [*silent_turn(case["live"]),
             {"role": "user", "content": "Current observation: " + json.dumps(obs, ensure_ascii=False)},
             {"role": "user", "content": "Open request: " + json.dumps(open_block(case, variant), ensure_ascii=False)}]
    if variant == "C":
        tools = tools + [DONE_TOOL, PARK_TOOL]
    return msgs + extra, tools


# ------------------------------------------------------------------ rubric (pure; blind to the variant)


def is_need(name: str, args: dict) -> bool:
    """A call for his own needs (food, water, rest), not work on an ask."""
    a = json.dumps(args or {}).lower()
    if name in NEED_CONSUME:
        return True
    if name == "cast" and "shelter" in a:
        return True
    if name == "interact" and any(w in a for w in ("shelter", "bed", "bedroll")):
        return True
    if name == "craft" and any(w in a for w in ("clean water", "dirty water")):
        return True
    return False


def outcome(calls: list[dict], text: str | None) -> str:
    """One of: world (a body call on work), need, read, done_claim, park, say, empty."""
    names = [(c["name"], c.get("arguments") or {}) for c in calls]
    if any(n in CLOSERS for n, _ in names):
        return CLOSERS[next(n for n, _ in names if n in CLOSERS)]
    work = [(n, a) for n, a in names if n != "say" and n not in READS]
    if work:
        return "need" if all(is_need(n, a) for n, a in work) else "world"
    if any(n in READS for n, _ in names):
        return "read"
    if names or (text or "").strip():
        return "say"
    return "empty"


def passed(side: str, out: str, lenient: bool = False) -> bool:
    """Open ask: a call that works on it passes (lenient: a read toward it too). Done ask: no new work passes."""
    if side == "open":
        return out == "world" or (lenient and out == "read")
    return out != "world"


# ------------------------------------------------------------------ cases (log scan)


def _quest_runs() -> dict[str, dict]:
    return {r["brain_log"]: r for r in read_jsonl(QUEST_RUNS) if r.get("brain_log")}


def _gates() -> dict[str, tuple[str, dict]]:
    out = {}
    for f in GATES:
        for r in read_jsonl(f):
            if r.get("brain_log"):
                out[r["brain_log"]] = (Path(f).stem, r)
    return out


def _utc(run: str) -> float:
    return dt.datetime.strptime(run, "%Y%m%d-%H%M%S").replace(tzinfo=dt.timezone.utc).timestamp()


def find_cases(since: str = "20261110", logs: Path = LOGS) -> list[dict]:
    """Every closing turn with the evidence of whether the ask was done then (see the module doc)."""
    qr, gates = _quest_runs(), _gates()
    cat = {}
    try:
        from brain import item_stats
        cat = item_stats.catalog()
    except Exception:
        pass
    cases = []
    for f in sorted(logs.glob("brain-live-*.jsonl")):
        if f.name[len("brain-live-"):] < since or (f.name not in qr and f.name not in gates):
            continue
        rows = read_jsonl(f)
        if f.name in qr:
            q = qr[f.name]
            comp = [s["t"] for s in q.get("steps") or [] if s.get("state") == "complete"]
            t_done = _utc(q["run"]) + comp[0] if comp else math.inf
            source, item = "quest", q["quest"]
        else:
            stem, g = gates[f.name]
            if g.get("item") not in ("grave", "gear_up"):
                continue  # chop/mine/spells: no game end state beyond the bag (variant D would equal B)
            leg = (g.get("legs") or [{}])[0]
            t_done = -math.inf if leg.get("done") else math.inf  # a gate leg's silent end comes after its done
            source, item = stem, g["item"]
        closes = []  # (episode, close row ts, why)
        for i, r in enumerate(rows):
            if r.get("kind") == "request_closed":
                closes.append((r.get("episode_id"), r["ts"], "request_closed"))
        if source == "quest":  # a run that heard a goal from an ask end and stopped with no world call
            firsts = {}
            for r in rows:
                if (r.get("kind") == "prompt" and r.get("component") == "controller" and not r.get("messages_from")
                        and "goal_done" in json.dumps(r.get("messages") or [], ensure_ascii=False)):
                    firsts.setdefault(r.get("episode_id"), r["ts"])
            for ep in firsts:
                if any(c[0] == ep for c in closes):
                    continue
                resp = [x for x in rows if x.get("kind") == "llm_response" and x.get("episode_id") == ep
                        and x.get("component") == "controller"]
                if resp and not ({c["name"] for c in resp[-1].get("tool_calls") or []} - {"say"} - READS):
                    closes.append((ep, resp[-1]["ts"] + 0.001, "goal_done_silent"))
        else:  # gate runs before request_closed existed: the request ended done with no world call
            for i, r in enumerate(rows):
                if r.get("kind") == "request_state" and r.get("ended") == "done" and \
                        (r.get("episode_id") or "").startswith("chat-") and not any(c[0] == r.get("episode_id")
                                                                                   for c in closes):
                    resp = [x for x in rows[:i] if x.get("kind") == "llm_response"
                            and x.get("episode_id") == r.get("episode_id") and x.get("component") == "controller"]
                    if resp and not ({c["name"] for c in resp[-1].get("tool_calls") or []} - {"say"} - READS):
                        closes.append((r.get("episode_id"), r["ts"], "request_state_done"))
        states = body_states(rows)
        for ep, ts, why in closes:
            try:
                calls = [c for c in episode_calls(rows, ep) if c[2]["ts"] <= ts]
            except ValueError:
                continue
            if not calls:
                continue
            _, msgs, live, tools, settings = calls[-1]
            if (live.get("usage") or {}).get("prompt", 0) > MAX_PROMPT or not tools:
                continue
            if {c["name"] for c in live.get("tool_calls") or []} - {"say"}:
                continue  # not a silent close (a read or work call ended the episode)
            asked = goal_request(msgs[:2]) if not ep.startswith("chat-") else None
            if ep.startswith("chat-"):
                words = next((json.loads(m["content"])["command"]["text"] for m in msgs[1:2]
                              if m.get("role") == "user"), None)
                player = next((json.loads(m["content"])["command"]["player"] for m in msgs[1:2]), None)
            elif asked:
                player, words = asked
            else:  # a goal_done from before it carried its request (16 Nov): the run's own line was the ask
                r = next((x for x in rows if x.get("kind") == "request_closed" and x.get("episode_id") == ep), {})
                line = ((qr.get(f.name) or {}).get("lines") or [{}])[0].get("line")
                player, words = None, r.get("request") or line
            if not words or f"{f.stem[len('brain-live-'):]}:{ep}" in EXCLUDE:
                continue
            t_ask = heard_at(rows, words) or calls[0][2]["ts"]
            now = state_at(states, live["ts"], after=False)
            if now and now.get("dead"):
                continue  # dead and respawning: no call could work on anything
            before = state_at(states, t_ask, after=True)
            player = player or (json.loads(msgs[1]["content"]).get("command") or {}).get("player") or "Tester"
            cases.append({
                "id": f"{f.stem[len('brain-live-'):]}:{ep}", "log": f.name, "episode": ep, "why": why,
                "source": source, "item": item, "side": "done" if live["ts"] >= t_done else "open",
                "player": player, "words": words, "age_s": round(live["ts"] - t_ask),
                "changes": changes(before, now, cat), "end_state": end_state(now, cat), "state_now": now or {},
                "messages": msgs, "live": live, "tools": tools, "settings": settings,
                "live_prompt_tokens": (live.get("usage") or {}).get("prompt"),
                "live_outcome": outcome(live.get("tool_calls") or [], live.get("content")),
            })
    return cases


def pick(cases: list[dict], done_max: int = 18, seed: int = 17) -> list[dict]:
    """All open cases; done cases spread over items and episode kinds, then a seeded sample, up to done_max."""
    open_ = [c for c in cases if c["side"] == "open"]
    done = [c for c in cases if c["side"] == "done"]
    rng = random.Random(seed)
    groups: dict[tuple, list] = {}
    for c in done:
        groups.setdefault((c["item"], c["episode"].split("-")[0]), []).append(c)
    for g in groups.values():
        rng.shuffle(g)
    out = []
    while len(out) < done_max and any(groups.values()):
        for key in sorted(groups):
            if groups[key] and len(out) < done_max:
                out.append(groups[key].pop())
    return open_ + sorted(out, key=lambda c: c["id"])


# ------------------------------------------------------------------ stats (pure)


def tally(samples: list[dict], lenient: bool = False) -> dict:
    """{variant: {side: (k passed, n)}}; variant A from the case list (no call: always stopped)."""
    from collections import defaultdict
    t: dict = defaultdict(lambda: defaultdict(lambda: [0, 0]))
    for s in samples:
        cell = t[s["variant"]][s["side"]]
        cell[0] += passed(s["side"], s["outcome"], lenient)
        cell[1] += 1
    return {v: {side: tuple(kn) for side, kn in sides.items()} for v, sides in t.items()}


def baseline_rows(cases: list[dict], k: int) -> list[dict]:
    """Variant A: the extra turn never runs; the ask is closed as he stopped (k rows per case to match the others)."""
    return [{"case": c["id"], "side": c["side"], "variant": "A", "outcome": "empty", "rep": r}
            for c in cases for r in range(k)]


def table(samples: list[dict], lenient: bool = False) -> list[dict]:
    from tools import ab
    t = tally(samples, lenient)
    rows = []
    for v in VARIANTS:
        if v not in t:
            continue
        row = {"variant": v}
        for side in ("open", "done"):
            k, n = t[v].get(side, (0, 0))
            lo, hi = ab.wilson(k, n)
            row[side] = {"k": k, "n": n, "lo": round(lo, 2), "hi": round(hi, 2)}
            for ref in ("A", "B"):
                if ref != v and ref in t and side in t[ref]:
                    rk, rn = t[ref][side]
                    row[side][f"p_vs_{ref}"] = round(ab.fisher(k, n, rk, rn), 4)
        rows.append(row)
    return rows


# ------------------------------------------------------------------ calls


def _effort(settings: dict) -> str | None:
    return ((settings or {}).get("output_config") or {}).get("effort")


def run(cases: list[dict], k: int, max_calls: int, max_usd: float, out: Path, yes: bool) -> list[dict]:
    from brain.jsonl_log import JsonlLogger
    from brain.llm import controller_llm
    from tools import spend
    plan_calls = len(cases) * (1 + 3 * k)
    llm = controller_llm()
    print(f"plan: {len(cases)} cases ({sum(c['side'] == 'open' for c in cases)} open, "
          f"{sum(c['side'] == 'done' for c in cases)} done) x (A1 once + B, C, D x {k}) = {plan_calls} calls of "
          f"{llm.model}; caps {max_calls} calls, ${max_usd:.2f}", flush=True)
    today = spend.spend_today()["spent_usd"]
    print(f"spend today before: ${today:.4f}", flush=True)
    if today > 8.0:
        print("refused: more than $8 spent today")
        return []
    if not yes:
        print("dry run: add --yes to call")
        return []
    log = JsonlLogger(out)
    samples, calls, usd = [], 0, 0.0
    for c in cases:
        for variant in CALLED:
            for rep in range(1 if variant == "A1" else k):
                if calls >= max_calls or usd >= max_usd:
                    print(f"stopped at the cap: {calls} calls, ${usd:.4f}")
                    return samples
                msgs, tools = build_request(c, variant)
                eff = _effort(c["settings"])
                try:
                    resp = llm.complete(msgs, tools=tools, effort=eff) if eff else llm.complete(msgs, tools=tools)
                except Exception as exc:
                    log.log("replay_error", case=c["id"], variant=variant, rep=rep, error=repr(exc)[:400])
                    print(f"  {c['id']} {variant} error {exc!r}"[:300], flush=True)
                    calls += 1
                    continue
                calls += 1
                usd += float((resp.usage or {}).get("cost_usd") or 0.0)
                log.log("llm_response", component="controller", model=llm.model, step="replay_open_ask",
                        usage=resp.usage)
                tc = [{"name": t.name, "arguments": t.arguments} for t in resp.tool_calls]
                s = {"case": c["id"], "side": c["side"], "item": c["item"], "variant": variant, "rep": rep,
                     "outcome": outcome(tc, resp.content), "calls": tc, "text": resp.content}
                samples.append(s)
                log.log("replay", **s)
                print(f"  {c['side']:4} {c['id'][:40]:40} {variant:2} {s['outcome']:10} "
                      f"{json.dumps(tc, ensure_ascii=False)[:150]}", flush=True)
    print(f"done: {calls} calls, ${usd:.4f}")
    return samples


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("cases")
    r = sub.add_parser("run")
    r.add_argument("--k", type=int, default=2)
    r.add_argument("--done-max", type=int, default=18)
    r.add_argument("--max-calls", type=int, default=290)
    r.add_argument("--max-usd", type=float, default=0.55)
    r.add_argument("--only", default="", help="comma-separated case ids")
    r.add_argument("--yes", action="store_true")
    rp = sub.add_parser("report")
    rp.add_argument("file")
    a = ap.parse_args(argv)
    if a.cmd == "cases":
        cs = find_cases()
        for c in cs:
            print(f"{c['side']:4} {c['id']:44} {c['item']:15} {c['why']:18} age {c['age_s']:4}s live {c['live_outcome']:5} "
                  f"{c['live_prompt_tokens']} | {c['words'][:50]}")
        print(f"{sum(c['side'] == 'open' for c in cs)} open, {sum(c['side'] == 'done' for c in cs)} done")
        return 0
    if a.cmd == "run":
        cs = pick(find_cases(), a.done_max)
        if a.only:
            keep = set(a.only.split(","))
            cs = [c for c in cs if c["id"] in keep]
        out = LOGS / "evals" / f"replay_open_ask-{time.strftime('%Y%m%d-%H%M%S')}.jsonl"
        samples = run(cs, a.k, a.max_calls, a.max_usd, out, a.yes)
        if samples:
            print(f"results: {out}")
            report(samples + baseline_rows(cs, a.k))
        return 0
    rows = [r for r in read_jsonl(a.file) if r.get("kind") == "replay"]
    ids = {r["case"]: r["side"] for r in rows}
    k = max((r["rep"] for r in rows if r["variant"] != "A1"), default=0) + 1
    base = [{"case": c, "side": s, "variant": "A", "outcome": "empty", "rep": i} for c, s in ids.items()
            for i in range(k)]
    report(rows + base)
    return 0


def report(samples: list[dict]) -> None:
    for lenient in (False, True):
        print("lenient (a read counts as going on)" if lenient else "strict (a world call on the ask)")
        for row in table(samples, lenient):
            print("  " + row["variant"].ljust(3) + "  ".join(
                f"{side} {row[side]['k']}/{row[side]['n']} [{row[side]['lo']:.2f}-{row[side]['hi']:.2f}]"
                + "".join(f" p{x[5:]}={row[side][x]}" for x in row[side] if x.startswith("p_vs"))
                for side in ("open", "done") if side in row))


if __name__ == "__main__":
    sys.exit(main())

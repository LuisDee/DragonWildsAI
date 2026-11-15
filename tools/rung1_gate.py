r"""Rung 1 gate (docs/GOAL-2026-11-01.md): the seven basics live on the dev world, each graded against the 4 bars.

Items (in run order; grave last because its setup kills him):
  split_drop  "split 10 stone off" then "drop 5 stone" (and "give <player> 3 stone" when --target-player is visible)
  pickup      a natural patch where Luis picked (tools/pickup_ladder.LEGS), "grab the N sticks around you"
  fight_back  a Goblin Runt spawned 6 m from him (dev fixture); no line: the hit is the request
  eat_drink   food and water set to 12 % (dev fixture set_stat, no supply top-up); no line
  rest        rest (the game's endurance) set to 5 % (set_stat); no line: he must decide to rest and say so
  come_follow "come over to me" + "follow me": needs a visible player (--target-player). Without one the
              model-free ghost-leader follow (tools/travel_ladder.run_follow) runs as a proxy and the item is BLOCKED
  grave       teleported 150-200 m from the respawn, killed (set_health 0), "go get your stuff from your grave"

Every request goes in chat from the dev sender "Tester" (tools/chat_ladder) to a brain this tool starts for the item
(Director off); the brain decides, no phrase->skill mapping anywhere. Per item, the 4 bars of the goal:
  time    wall from the request (or the fixture that made the need) to the verified result <= 1.5 x T_h, T_h = Luis's
          own recorded time for the task (evals/baselines/luis_20261101_tasks.json) or his per-unit family time
          (data/baselines/luis-2026-11-01.json) + reaction 1.5 s
  misses  <= 1 per item (pickups: <= 1 per item picked; presses with no gain, from the server recorder); elsewhere the
          body's failed actions that were not interruptions; a read-only lookup (craft_plan, recipes, inventory, look,
          stations, buildables, ...) that answers ambiguous_target or not-found is no miss (it changes nothing and its
          time is in the time bar); a still_running collision and any failed world action are
  stand   no stand > 5 s (server recorder, v < 0.3 m/s) without work (an rpc or inventory change, the item's own work:
          a fight on, rest rising, a stat rising) or a line he said in it
  truth   every report true (tools/truth_judge.py: LLM judge against the check's facts and the recordings), and he
          told the player something (communication is part of each item)
A run passes an item when it is done and all 4 bars hold. The rung passes when every item passes 3 runs in a row.

    .venv\Scripts\python.exe -m tools.rung1_gate plan
    .venv\Scripts\python.exe -m tools.rung1_gate run --confirm [--only fight_back,rest] [--runs 3]
    .venv\Scripts\python.exe -m tools.rung1_gate report

The live lock ("rung1") is held per item and released between items. Rows: logs/evals/rung1_gate.jsonl (one per
item per run). Live guards are chat_ladder's (dev server only, no hold file, no other brain, nobody else driving).
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
import time
from datetime import datetime, timezone

from tools import chat_ladder as cl
from tools import coplay_ladder as cp
from tools import live_lock, obs, spend
from tools import standard_score as ss
from tools import truth_judge as tj

ROOT = cp.ROOT
OUT = ROOT / "logs" / "evals" / "rung1_gate.jsonl"
WHO = "ClaudeDev"            # Claude's character on the dev server (the recorder's name)
H_RATIO, STAND_S, POLL_S = 1.5, 5.0, 1.0
WORLD = "dev_rung1"
STONE = "ITEM_Resources_Stone"
RUNT = "BP_AI_RuntGoblin_Character_C"
KIT = ("ITEM_Sword_Bronze", "ITEM_Shield_Bronze")  # his fighting kit in the 12:36 runt fights (DISCOVERIES)
MELEE_RX = r"^ITEM_(Sword|GreatSword|Mace|Dagger|Battleaxe|Scimitar|Spear|Staff|Club|Hammer|Warhammer)_"
ENGAGE_M = 3.0  # the runt this close, or his HP dropping = the fight is on (the clock of "fight back when hit")
# One food or drink use locks the next of its kind for the use animation (DISCOVERIES consumables #9). Measured on the
# server recorder (his consumptions, the same item back to back, 31 pairs 2026-11-01): min 5.12 s, p10 5.41 s,
# median 6.08 s. No human eats faster than the game's animation (coordinator decision 2026-11-01: T_h = reaction +
# uses needed x this; Luis has no eat/drink recording to time).
USE_S = 6.1
BOTH_KINDS_S = 0.8  # the lock is per kind: food and drink overlap (coordinator decision 2026-11-01, strict human bar)
FOOD_VALUES = ROOT / "data" / "food_values_26161880.json"
LUIS_SLEEP = [101.24, 1868.4, -30.69]  # Luis said "sleep" here (recorder 1793537212); shelter at [98.1, 1858.7]
AUDIENCE_M = 40.0  # a player this close can be told (the Tester sender has no pawn: no audience on the dev world)
GRAVE_SPOTS = [[249.91, 1790.78, -39.79], [181.73, 1815.94, -28.99],  # travel_ladder P southeast / east_stone,
               [151.83, 1788.53, -26.34], [155.18, 1914.83, -30.47]]  # vannaka / pond_south (spares: a spot with debris is skipped)
GRAVE_CLEAN_M, GRAVE_SETTLE_S, GRAVE_MAP_WAIT_S = 15.0, 3.0, 12.0
ITEMS = ["split_drop", "pickup", "fight_back", "eat_drink", "rest", "come_follow", "grave"]
NOUNS = {"sticks": ("sticks", r"ash|log|branch|wood"), "loose_stones": ("stones", r"stone"), "cabbage": ("cabbages", r"cabbage"),
         "flax": ("flax", r"flax"), "redberries": ("berries", r"berr")}


def luis_task_s(name: str) -> float | None:
    return ss.t_human_task(name)


def unit(fam: str) -> float:
    return ss.unit_s(fam)[0]


# ------------------------------------------------------------------ samples -> checks (registered in coplay_ladder)
def _stat_series(rec: dict, stat: str) -> list[tuple[float, float]]:
    return [(t, s[stat]) for t, s in rec.get("stats") or [] if isinstance(s.get(stat), (int, float))]


def check_stat(rec: dict, rows: list[dict]):
    """eat_drink: every stat in rec.stats_want back to >= its pct; rest: endurance rising (resting) or back to the pct."""
    want, how, when, m = rec["target"]["want"], [], [], {}
    for stat, pct in want.items():
        xs = _stat_series(rec, stat)
        # from the first sample that shows the harness's value (live 17:01Z: the first read was still the old 53 %, and
        # 53 >= low 5 + 8 scored a rest done at 0.3 s)
        set_pct = (rec["target"].get("set") or {}).get(stat)
        if set_pct is not None:
            i = next((i for i, (_, v) in enumerate(xs) if v <= set_pct + 3), None)
            set_at = (rec["target"].get("set_at") or {}).get(stat)
            if i is None and set_at:
                # the set_stat fixture's own server read-back is the start sample: the body ate/drank within one
                # sampler period of the set (live 17:46Z: water set to 12 and drunk to 37 between two 1.1 s samples)
                xs = [(float(set_at[0]), float(set_at[1]))] + [(t, v) for t, v in xs if t > float(set_at[0])]
            else:
                xs = xs[i:] if i is not None else []
        if not xs:
            return False, f"no {stat} samples at the harness's value", None, {}
        lo = min(v for _, v in xs)
        m[stat] = {"start": round(xs[0][1], 1), "low": round(lo, 1), "end": round(xs[-1][1], 1)}
        hit = next((t for t, v in xs if v >= pct), None)
        if rec["kind"] == "r1_rest" and hit is None:  # resting = the bar climbing at a nap's +1/s (or a sleep's jump)
            hit = next((t for t, v in xs if v >= lo + rec["target"].get("rising", 8.0)), None)
            m[stat]["resting"] = hit is not None
        how.append(f"{stat} {xs[0][1]:.0f} -> {xs[-1][1]:.0f} % (low {lo:.0f}, wanted >= {pct:.0f} %)")
        when.append(hit)
    ok = all(w is not None for w in when)
    return ok, "; ".join(how), (max(when) if ok else None), m


def _stacks(rec: dict, name_rx: str) -> list[tuple[float, list[int]]]:
    rx = re.compile(name_rx, re.I)
    return [(t, sorted((int(r.get("count") or 1) for r in rows if rx.search(str(r.get("name") or r.get("item")))), reverse=True))
            for t, rows in rec.get("stacks") or []]


def check_split(rec: dict, rows: list[dict]):
    tg = rec["target"]
    xs = _stacks(rec, tg["rx"])
    if not xs:
        return False, "no inventory samples", None, {}
    s0, n = xs[0][1], tg["n"]
    for t, s in xs[1:]:
        if len(s) == len(s0) + 1 and sum(s) == sum(s0) and n in s:
            return True, f"{tg['name']} stacks {s0} -> {s} (a new stack of {n}, total {sum(s)} kept)", t, {"stacks": s}
    return False, f"{tg['name']} stacks {s0} -> {xs[-1][1]} (wanted a new stack of {n}, total {sum(s0)} kept)", None, \
        {"stacks": xs[-1][1]}


def check_drop(rec: dict, rows: list[dict]):
    tg = rec["target"]
    xs = _stacks(rec, tg["rx"])
    if not xs:
        return False, "no inventory samples", None, {}
    b, n = sum(xs[0][1]), tg["n"]
    for t, s in xs[1:]:
        if sum(s) == b - n:
            return True, f"{tg['name']} {b} -> {sum(s)} (dropped exactly {n})", t, {}
    return False, f"{tg['name']} {b} -> {sum(xs[-1][1])} (wanted exactly {n} fewer)", None, {}


def check_gain(rec: dict, rows: list[dict]):
    tg = rec["target"]
    rx = re.compile(tg["rx"], re.I)
    inv = rec.get("inv") or []
    base = inv[0][1] if inv else {}
    for t, c in inv[1:]:
        got = sum(v - base.get(k, 0) for k, v in c.items() if rx.search(k) and v > base.get(k, 0))
        if got >= tg["n"]:
            return True, f"picked up {got} {tg['name']} (asked {tg['n']})", t, {"gained": got}
    got = sum(v - base.get(k, 0) for k, v in (inv[-1][1] if inv else {}).items() if rx.search(k) and v > base.get(k, 0))
    return False, f"picked up {got} of {tg['n']} {tg['name']}", None, {"gained": got}


def check_fight(rec: dict, rows: list[dict]):
    done, how, when, m = cp.check({**rec, "kind": "kill"}, rows)
    hp = [s[5] for s in rec.get("me") or [] if len(s) > 5 and isinstance(s[5], (int, float))]
    if hp:
        m["my_hp"] = [round(hp[0]), round(min(hp)), round(hp[-1])]
        how += f"; his HP {hp[0]:.0f} -> low {min(hp):.0f} -> {hp[-1]:.0f}"
    first = next((s[0] for s in rec.get("seen") or [] if s[1] in ("alive", "dead")), None)
    if first:
        how += f"; the runt was spawned {rec['target'].get('spawn_m', '?')} m from him"
    return done, how, when, m


def grave_lost(carried: dict, kept: dict) -> dict:
    """What his bag lost when he died (what the grave holds): carried, minus what stayed on him through the respawn."""
    return {k: v - kept.get(k, 0) for k, v in carried.items() if v - kept.get(k, 0) > 0}


def item_words(d: dict) -> str:
    return ", ".join(f"{v} {k}" for k, v in sorted(d.items()))


def grave_check_text(went: dict, dist_m: float) -> str:
    return (f"everything his bag lost when he died went into his grave: {item_words(went)} ({sum(went.values())} items, "
            f"nothing else was in it). The check: >= 90 % of those are back in his bag (his newest grave is {dist_m:.0f} m away)")


def check_grave(rec: dict, rows: list[dict]):
    """What went INTO the grave (carried at death minus what he kept through the respawn: runes stay on him, 8537 of
    8746 items, so a whole-bag count passed at 3.6 s, live 20:59Z) is >= 90 % back in his bag. What he ate or drank
    of it since counts as back (2026-11-15: he arrives hungry, the stay-fed reflex uses a Fillet and a Clean Water the
    second they are his again, and a bag sample after that read 10 of 12 = fail; before it, 11 or 12 = pass)."""
    tg = rec["target"]
    inv = rec.get("inv") or []
    if not inv:
        return False, "no inventory samples", None, {}
    want, kept = tg["carried"], inv[0][1]
    lost = grave_lost(want, kept)
    n_lost = sum(lost.values())
    if not n_lost:
        return False, f"nothing went into the grave (he kept all {sum(want.values())} items through the respawn)", None, {}

    uses = []  # (ts, name): the reflex's own report of each use (brain log `event` rows)
    for r in rows or []:
        ev = r.get("event") if r.get("kind") == "event" else None
        if isinstance(ev, dict) and ev.get("kind") == "reflex_use" and ev.get("ok") and ev.get("name") in lost:
            uses.append((float(ev.get("ts") or r.get("ts") or 0), ev["name"]))

    def back_of(c, t=None):
        used = {}
        for ts, name in uses:
            if t is None or ts <= t:
                used[name] = used.get(name, 0) + 1
        return sum(min(max(c.get(k, 0) + used.get(k, 0) - kept.get(k, 0), 0), v) for k, v in lost.items())
    # the bag is sampled every ~2 s: the things were his from the moment the body reported the take that this sample
    # confirms (r1-20261115T223115Z: Take All's result at 31.6 s, the sample at 33.1 s)
    # (only the press itself: r1-20261115T223958Z had go_to's result at 17.4 s in the window, the take at 19.3 s)
    took = [float(r["ts"]) for r in rows or [] if r.get("kind") == "tool_result" and r.get("tool") == "interact"
            and (r.get("result") or {}).get("ok") and isinstance(r.get("ts"), (int, float))]
    for (t_prev, _), (t, c) in zip(inv, inv[1:]):
        if back_of(c, t) >= 0.9 * n_lost:
            t = max((x for x in took if t_prev < x <= t), default=t)
            return True, f"{back_of(c)} of the {n_lost} items that went into his grave ({item_words(lost)}) are back in his bag", t,                 {"back": back_of(c, t), "lost": n_lost}
    return False, f"{back_of(inv[-1][1])} of the {n_lost} items that went into his grave ({item_words(lost)}) are back", None,         {"back": back_of(inv[-1][1]), "lost": n_lost}


cp.CHECK_HOOKS.update({"r1_stat": check_stat, "r1_rest": check_stat, "r1_split": check_split, "r1_drop": check_drop,
                       "r1_gain": check_gain, "r1_fight": check_fight, "r1_grave": check_grave})


# ------------------------------------------------------------------ the 4 bars
def stand_bar(t0: float, t1: float, says: list[float], work=None) -> tuple[float, list[dict]]:
    """Longest stand > STAND_S in [t0, t1] on the server recorder with no rpc / inventory change of his (recorder_io's
    explained), no line he said in it (or 2 s before) and no item work (work(a, b) -> bool). (seconds, stands)."""
    from tools import recorder_io as rio
    try:
        rec = rio.load(since=t0 - 2, until=t1 + 2)
    except Exception as exc:  # noqa: BLE001
        return -1.0, [{"error": f"recorder: {exc!r}"}]
    who = rec.canon(WHO)
    if not who:
        return -1.0, [{"error": "Claude is not in the recorder (re-arm it: player_recorder)"}]
    out = []
    for s in rec.still_segments(who, t0, t1, min_s=STAND_S):
        said = any(s["start"] - 2 <= x <= s["end"] for x in says)
        busy = bool(work and work(s["start"], s["end"]))
        out.append({"s": s["s"], "from": round(s["start"] - t0, 1), "explained": s["explained"], "said": said, "work": busy})
    bad = [x["s"] for x in out if not (x["explained"] or x["said"] or x["work"])]
    return (max(bad) if bad else 0.0), out


def grade(item: str, legs: list[dict], t_h: float | None, misses: int, allowed: int, stand_s: float,
          need_told: bool = True, audience: bool = True, extra: dict | None = None) -> dict:
    """The item against the 4 bars: done, time, misses, stand, truth (+ told, when a player was near to be told:
    with nobody near, the persona's "with nobody around ... stay quiet" is the right call, so told is n/a)."""
    done = bool(legs) and all(x.get("done") for x in legs)
    wall = round(sum(x.get("done_s") if x.get("done") else x.get("wall_s") or 0 for x in legs), 1)
    told = any(x.get("told") for x in legs)
    truthful = all(x.get("truthful") for x in legs)
    bars = {"done": done,
            "time": bool(done and t_h and wall <= H_RATIO * t_h),
            "misses": misses <= allowed,
            "stand": 0 <= stand_s <= STAND_S,
            "truth": truthful and (told or not need_told or not audience)}
    bars.update(extra or {})
    why = [k for k, v in bars.items() if not v]
    if stand_s < 0:  # the recorder had nothing for him: an unmeasured stand bar is infra, not his failure
        why = [k for k in why if k != "stand"] + ["infra"]
    return {"item": item, "pass": not why, "bars": bars, "fails": why, "wall_s": wall, "t_h": t_h,
            "ratio": round(wall / t_h, 2) if t_h else None, "misses": misses, "misses_allowed": allowed,
            "longest_stand_s": stand_s, "told": told if (audience or not need_told) else f"{told} (n/a: nobody near)",
            "truthful": truthful}


# ------------------------------------------------------------------ one leg: send (or not), sample, score
class Ctx:
    def __init__(self, a, cli, brain_file, run_id: str):
        self.a, self.cli, self.brain_file, self.run_id = a, cli, brain_file, run_id
        self.haiku = 0

    def me(self) -> dict:
        return cl.me(self.cli) or {}

    def stacks(self) -> list[dict]:
        return cp.inv_rows(cp.inventory(self.cli))


def _pct(me: dict) -> dict:
    out = {k: 100.0 * v[0] / v[1] for k, v in (me.get("survival") or {}).items()
           if isinstance(v, list) and len(v) == 2 and v[1]}
    if me.get("max_health"):
        out["health"] = 100.0 * float(me.get("health") or 0) / float(me["max_health"])
    return out


def slim(rows: list[dict]) -> list[dict]:
    return [{k: r.get(k) for k in ("name", "item", "count", "slot")} for r in rows]


def run_leg(ctx: Ctx, req: dict, line: str | None, target: dict, deadline_s: float, t0: float | None = None,
            sample=("me",), creature: str | None = None, settled=None) -> dict:
    """Send `line` (None: the fixture already made the need), sample until done and quiet / the deadline, score with
    coplay_ladder.score (truth judge, calls, deaths)."""
    from tools import m1_session
    cli, a = ctx.cli, ctx.a
    t0 = t0 or time.time()
    if line:
        ok, detail = m1_session.send_speech_direct(line)
        if not ok:
            return {"request": req["id"], "kind": req["kind"], "skipped": True, "why": f"line not sent: {detail[-160:]}"}
    rec = {"request": req["id"], "kind": req["kind"], "line": line, "lead": None, "target": target, "t0": t0,
           "check_text": req.get("check_text"), "me": [], "other": [], "seen": [], "inv": [], "stats": [], "stacks": []}
    last_census = last_inv = 0.0
    last_pos, last_move, why = None, t0, None
    while True:
        now = time.time()
        m = ctx.me()
        if p := obs._xyz(m.get("position")):
            rec["me"].append([round(now, 2), *p, bool(m.get("dead")), m.get("health")])
            rec["stats"].append([round(now, 2), _pct(m)])
            if last_pos is None or obs.hdist(p, last_pos) > 0.5:
                last_move, last_pos = now, p
        if "inv" in sample and now - last_inv >= 2.0:
            last_inv = now
            rows = ctx.stacks()
            if rows:
                rec["inv"].append([round(now, 2), cp.counts({"bag": rows})])
                if req["kind"] in ("r1_split", "r1_drop"):
                    rec["stacks"].append([round(now, 2), slim(rows)])
        if creature and now - last_census >= 1.5:
            last_census = now
            cs = cp.census(cli, radius_m=40, max=40, kinds={"creatures": True}, foliage=False).get("creatures") or []
            r = next((x for x in cs if x.get("id") == target.get("id")), None)
            rec["seen"].append([round(now, 2), "gone" if r is None else ("dead" if not cp._alive(r) else "alive"),
                                (r or {}).get("health"), (r or {}).get("distance")])
        if target.get("player") and now - last_census >= 2.0:
            last_census = now
            pl = cp.census(cli, radius_m=150, max=10, kinds={"players": True}, foliage=False).get("players") or []
            q = next((obs._xyz(x.get("position")) for x in pl if x.get("name") == target["player"]), None)
            if q:
                rec["other"].append([round(now, 2), *q])
        rows = cl.brain_rows([ctx.brain_file], t0 - 1, now + 1)
        rec["heard_at"] = rec.get("heard_at") or (cp._heard(rows, line) if line else t0)
        calls = cl.model_calls(rows)
        open_prompt, open_tools, quiet = cp._busy(rows, t0, now)
        rec["t1"] = now
        done = cp.check(rec, rows)[0]
        if line and rec["heard_at"] is None and now - t0 > cl.HEARD_S:
            why = "never heard"
        elif ctx.haiku + calls["haiku"] > a.max_haiku:
            why = "haiku call cap"
        elif done and quiet >= 6 and not open_prompt and (settled is None or settled(rows) or now - t0 > deadline_s):
            why = "done and quiet"
        elif line and calls["calls"] and not open_prompt and not open_tools and quiet >= cl.QUIET_S \
                and now - last_move >= cl.STILL_S and not done:
            why = "quiet"
        elif getattr(ctx, "abort", None):
            why = ctx.abort  # a harness guard ended the window (rung4 gear_up: a fall near a known drop)
        elif now - t0 > deadline_s:
            why = "deadline"
        if why:
            break
        time.sleep(POLL_S)
    if "inv" in sample and (rows_ := ctx.stacks()):
        rec["inv"].append([round(time.time(), 2), cp.counts({"bag": rows_})])
        if req["kind"] in ("r1_split", "r1_drop"):
            rec["stacks"].append([round(time.time(), 2), slim(rows_)])
    rec["t1"], rec["ended"] = time.time(), why
    rec["audience"] = audience(ctx)
    row = cp.score(rec, judge=a.judge)
    ctx.haiku += row.get("haiku_calls") or 0
    brain = cl.brain_rows([ctx.brain_file], t0 - 1, rec["t1"] + 1)
    _, _, done_at, _ = cp.check(rec, brain)
    says = [r["ts"] for r in brain if r.get("kind") == "say"]
    row.update(done_s=round(done_at - t0, 1) if done_at else None, told=bool(says), say_ts=says,
               says=[obs.short(r.get("text"), 160) for r in brain if r.get("kind") == "say"][:6],
               fumbles=count_fumbles(brain),
               tools=[f"{r.get('tool')}{'' if (r.get('result') or {}).get('ok') else ':' + str((r.get('result') or {}).get('reason'))}"
                      for r in brain if r.get("kind") == "tool_result"][:12])
    return row


READ_ONLY_TOOLS, NO_MISS_REASONS, count_fumbles = ss.READ_ONLY_TOOLS, ss.NO_MISS_REASONS, ss.count_fumbles


def audience(ctx: Ctx) -> list[str]:
    """Other players within AUDIENCE_M of him (census): someone he could tell. The dev sender Tester is chat-only."""
    pl = cp.census(ctx.cli, radius_m=AUDIENCE_M, max=10, kinds={"players": True}, foliage=False).get("players") or []
    return [str(x.get("name")) for x in pl if x.get("name") and str(x.get("name")) not in (WHO, "Claude")
            and (x.get("distance") is None or float(x.get("distance")) <= AUDIENCE_M)]


# ------------------------------------------------------------------ the items
def it_split_drop(ctx: Ctx) -> dict:
    dev = cl._dev()
    have = sum(int(r.get("count") or 1) for r in ctx.stacks() if r.get("item") == STONE)
    if have < 20:
        dev.setup("grant", purpose="rung1 gate split/drop stock", item=STONE, count=30 - have)
    rx = r"^stone$"
    legs = []
    legs.append(run_leg(ctx, {"id": "split", "kind": "r1_split", "check_text": "a new Stone stack of exactly 10 appears in his "
                              "bag and the total Stone count is unchanged"},
                        "claude split 10 stone off into a separate stack", {"name": "Stone", "rx": rx, "n": 10},
                        deadline_s=60, sample=("me", "inv")))
    legs.append(run_leg(ctx, {"id": "drop", "kind": "r1_drop", "check_text": "his Stone total goes down by exactly 5"},
                        "claude drop 5 stone", {"name": "Stone", "rx": rx, "n": 5}, deadline_s=60, sample=("me", "inv")))
    if ctx.a.target_player:
        legs.append(run_leg(ctx, {"id": "give", "kind": "give"}, f"claude give {ctx.a.target_player} 3 stone",
                            {"name": "Stone", "player": ctx.a.target_player}, deadline_s=90, sample=("me", "inv")))
    t_h = luis_task_s("split")  # his split_put + drop, 10 s
    t_h = (t_h or 10.0) + (1.5 + unit("drop") if ctx.a.target_player else 0.0)
    return finish(ctx, "split_drop", legs, t_h, allowed=1,
                  note=None if ctx.a.target_player else "give not run: no visible player to give to (needs Luis or a Tester pawn)")


def it_pickup(ctx: Ctx) -> dict:
    from tools import pickup_ladder as pl, travel_ladder as tl
    dev = cl._dev()
    legs_order = pl.LEGS[ctx.a.run_index % len(pl.LEGS):] + pl.LEGS[:ctx.a.run_index % len(pl.LEGS)]
    for leg in legs_order:
        tl.place(dev, ctx.cli, leg["start"], harness_brain=True)
        avail = pl.available_here(ctx.cli, leg["match"])
        if len(avail) >= leg.get("min", 3):
            break
    else:
        return {"item": "pickup", "pass": False, "fails": ["setup"], "why": "no patch with 3+ available"}
    n = min(leg["count"], len(avail))
    noun, rx = NOUNS[leg["resource"]]
    time.sleep(2.0)
    row = run_leg(ctx, {"id": "pickup", "kind": "r1_gain", "check_text": f"he picks up {n} {noun} (inventory gain)"},
                  f"claude grab the {n} {noun} around you", {"name": noun, "rx": rx, "n": n, "patch": leg["id"]},
                  deadline_s=90, sample=("me", "inv"))
    end = row["rec"]["t0"] + (row.get("done_s") or row["wall_s"])
    time.sleep(2.5)  # the recorder's press-outcome window
    sc = pl.score(row["rec"]["t0"], end)
    row["recorder"] = {k: sc.get(k) for k in ("items", "presses", "hits", "misses", "presses_per_item", "on_move_share",
                                              "s_item", "longest_stand_s")}
    t_h = 1.5 + n * unit("pickup")
    return finish(ctx, "pickup", [row], t_h, allowed=max(1, row["recorder"].get("items") or n),
                  misses=row["recorder"].get("misses") or 0, note=f"patch {leg['id']}, {len(avail)} available")


def it_fight_back(ctx: Ctx) -> dict:
    dev = cl._dev()
    kit = None
    # on open ground by the base: a runt spawned beside him at the grave by the world-edge drop fell to its death in
    # 2.4 s and scored a PASS with no hit of his (r1-20261101T222647Z, T224315Z)
    from tools import travel_ladder as tl
    tl.place(dev, ctx.cli, LUIS_SLEEP, harness_brain=True)
    if not any(re.match(MELEE_RX, str(r.get("item") or "")) for r in ctx.stacks()):
        # he lost his sword to an earlier death (live 16:04Z: bare hands, 34 damage in 38 s, died): the harness gives
        # his kit back, like the food top-up; he draws it himself (combat's equip phase)
        have = {str(r.get("item")) for r in ctx.stacks()}
        kit = [it for it in KIT if it not in have]  # never a second copy of gear he carries (his bag filled up: 18:3xZ)
        for it in kit:
            dev.setup("grant", purpose="rung1 gate fight: his kit (lost to an earlier death)", item=it, count=1)
    m = ctx.me()
    if (m.get("health") or 0) < (m.get("max_health") or 100):
        dev.setup("set_health", purpose="rung1 gate fight: full HP", value=float(m.get("max_health") or 100))
    before = {x.get("id") for x in cp.census(ctx.cli, radius_m=40, max=40, kinds={"creatures": True}, foliage=False).get("creatures") or []}
    t0 = time.time()
    res = dev.setup("spawn", purpose="rung1 gate: a hostile beside him", **{"class": RUNT, "offset_m": [6, 0, 0]})
    target = {"name": "Goblin Runt", "spawn_m": 6, "server_id": res.get("id")}
    for _ in range(8):  # its client census row (client actor ids differ from the server's)
        time.sleep(0.5)
        cs = cp.census(ctx.cli, radius_m=20, max=40, kinds={"creatures": True}, foliage=False).get("creatures") or []
        new = [x for x in cs if x.get("id") not in before and re.search("runt", str(x.get("name")), re.I)]
        if new:
            target.update(id=new[0]["id"], name=new[0].get("name"))
            break
    row = run_leg(ctx, {"id": "fight_back", "kind": "r1_fight", "check_text": "the Goblin Runt spawned beside him reads dead "
                        "(or vanished after a kill the body reported)"}, None, target, deadline_s=150, t0=t0,
                  creature=target.get("id"),
                  # the body's combat_end (then the model's turn on it) comes a few s after the kill: what he says about
                  # the fight is part of the item (live 17:00Z: the leg ended on the kill, before his news reached the model)
                  settled=lambda rows: any(r.get("kind") == "event" and (r.get("event") or {}).get("kind") == "combat_end"
                                           for r in rows))
    seen = row["rec"].get("seen") or []
    if seen and seen[-1][1] == "alive" and res.get("id"):  # the harness's runt is the harness's to remove (bench cleanup)
        k = cl._server_client().request("debug_run", {"module": "bench_creatures", "args": {
            "action": "kill", "character_guid": dev.character_guid, "ids": [res["id"]]}}, timeout=30)
        row["cleanup"] = ((k.get("data") or {}).get("result") or {}).get("ok")
    near = [(s[0], s[3]) for s in seen if s[1] == "alive" and isinstance(s[3], (int, float))]
    hp = [(s[0], s[5]) for s in row["rec"].get("me") or [] if len(s) > 5 and isinstance(s[5], (int, float))]

    def work(a_, b_):  # trading blows: the runt alive within 4 m, or his HP changing
        return any(a_ <= t <= b_ and d <= 4.0 for t, d in near) or any(a_ <= t <= b_ and abs(h - hp[0][1]) > 0 for t, h in hp)
    first_hit = next((t for t, h in hp if h < hp[0][1]), None) if hp else None
    row["first_hit_s"] = round(first_hit - t0, 1) if first_hit else None
    # the item's clock starts when the fight is on (the runt within ENGAGE_M or his HP dropping), not at the spawn:
    # a runt that wanders off first is no request yet (live 16:04Z: it strolled to 13 m and came back 20 s later)
    close = next((t for t, d in near if d <= ENGAGE_M), None)
    t_eng = min([x for x in (close, first_hit) if x] or [t0])
    row["rec"]["t_start"], row["engaged_s"] = t_eng, round(t_eng - t0, 1)
    if row.get("done_s") is not None:
        row["done_s"] = round(max(0.0, row["done_s"] - (t_eng - t0)), 1)
    row["wall_s"] = round(max(0.0, (row.get("wall_s") or 0) - (t_eng - t0)), 1)
    brain = cl.brain_rows([ctx.brain_file], t0 - 1, time.time() + 1)
    started = next((r["ts"] for r in brain if r.get("kind") == "event" and (r.get("event") or {}).get("kind") ==
                    "combat_started"), None)
    row["response_s"] = round(started - t_eng, 1) if started else None  # engaged -> the body's fight began
    row["kit"] = kit
    t_h = 1.5 + unit("kill")
    out = finish(ctx, "fight_back", [row], t_h, allowed=1, work=work,
                 note=f"spawn {res.get('id')}" + (f"; kit granted {kit}" if kit else ""))
    ends = [r.get("event") or {} for r in brain if r.get("kind") == "event" and (r.get("event") or {}).get("kind") == "combat_end"]
    mine = any((e.get("kills") or 0) >= 1 or (e.get("presses") or 0) >= 1 for e in ends)
    if seen and seen[-1][1] != "alive" and not mine:  # it died, but not in a fight of his: no request was answered
        out.update(**{"pass": False, "fails": ["setup"],
                      "why": f"the runt died without a fight of his (combat_end rows {len(ends)}, no press or kill)"})
    return out


MY_PIECES = ROOT / "data" / "skills" / "dev" / "my_pieces.json"  # what he built (build telemetry): his crates
ROOM_SLOTS = 6


def bag_free(cli) -> tuple[int | None, dict]:
    """Free slots of his bag's item page (InventoryItems): runes and ammo have pages of their own, so they never fill
    it (raw inventory 18:4xZ: InventoryItems:32, InventoryRunes:32, InventoryAmmunition:32)."""
    r = cli.request("inventory", {"raw": True}, timeout=20)
    d = (r or {}).get("data") or {}
    n = sum(int(str(x).split(":")[1]) for x in d.get("pages") or [] if str(x).startswith("InventoryItems:"))
    used = sum(1 for x in d.get("bag") or [] if isinstance(x, dict) and x.get("slot_type") == "InventoryItems")
    return (n - used if n else None), d


def my_crates(cli) -> list[dict]:
    """His own crates in sight (storage rows within 1.5 m of a crate in my_pieces.json), newest built first."""
    try:
        mine = [x for x in json.loads(MY_PIECES.read_text(encoding="utf-8")).get("pieces") or []
                if "Crate" in str(x.get("name")) or "Chest" in str(x.get("name"))]
    except (OSError, ValueError):
        return []
    mine.sort(key=lambda x: str(x.get("noted") or ""), reverse=True)
    rows = [x for x in cp.census(cli, radius_m=40, max=40, kinds={"interactables": True}, foliage=False).get("interactables") or []
            if x.get("kind") == "storage" and obs._xyz(x.get("position"))]
    out = []
    for m in mine:
        for x in rows:
            if obs.hdist(x["position"], m["at"]) < 1.5 and x not in out:
                out.append(x)
    return out


CLEANUP_LOG = ROOT / "logs" / "state" / "rung1_fixture_cleanup.jsonl"  # what make_room put away of the gate's own grants
CARRY_MAX_KG = 400.0
# what the next item still wants of a granted thing: his kit once, the eat/drink options, the supply top-up's 6 + 6
KEEP = {**{it: 1 for it in KIT}, "ITEM_Consumable_Meat_Fillet": 6, "ITEM_Consumable_Water_Clean": 6,
        "ITEM_Consumable_Water_Dirty": 3, "ITEM_Resources_Raw_Stringy_Meat": 2, "ITEM_Consumable_Fruit_Redberry": 4}


def fixture_surplus(carried: dict[str, int], setup_log=None, cleanup_log=None, gear=()) -> dict[str, int]:
    """What the harness fixtures added that he still carries beyond what the next item needs: every grant in the
    fixture setup log (this gate's: his kit after a grave death, the split/drop stone, the food top-ups, the eat/drink
    options; and the other gates' stock on the same dev character, which they grant again when they need it),
    less what make_room already put away (CLEANUP_LOG), capped by what he carries now less KEEP. His own things
    (crafted, gathered, looted) are never in it, nor the last copy of a piece of gear (`gear`: his only axe or bow
    stays on him whoever granted it). -> {item: count}"""
    if setup_log is None:
        from evals.bench.devtarget import SETUP_LOG as setup_log
    granted: dict[str, int] = {}
    for path, sign in ((setup_log, 1), (cleanup_log or CLEANUP_LOG, -1)):
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for ln in lines:
            try:
                r = json.loads(ln)
            except ValueError:
                continue
            if not r.get("ok") or (sign > 0 and r.get("verb") != "grant"):
                continue
            a = r.get("args") or r
            it = str(a.get("item") or "")
            granted[it] = granted.get(it, 0) + sign * int(a.get("count") or 1)
    out = {}
    for it, g in granted.items():
        n = min(g, carried.get(it, 0) - KEEP.get(it, 1 if it in gear else 0))
        if n > 0:
            out[it] = n
    return out


def make_room(ctx: Ctx, need: int = ROOM_SLOTS) -> dict:
    """At least `need` free bag slots and under his carry limit, the way a player makes room: what the gate's own
    fixtures added (fixture_surplus) goes into his own crate by his own store skill, the most slots freed first. His
    own things stay on him. Nothing is dropped or destroyed. He must be by the base (his crates).
    -> {free_before, free, kg_before, kg, stored, why?}"""
    free, d = bag_free(ctx.cli)
    kg = float(d.get("carry") or d.get("weight") or 0) or None
    out: dict = {"free_before": free, "free": free, "kg_before": kg, "kg": kg, "stored": []}

    def short() -> bool:
        return free is None or free < need or (kg is not None and kg >= CARRY_MAX_KG)
    if not short():
        return out
    carried: dict[str, int] = {}
    rows_of: dict[str, int] = {}
    stack: set[str] = set()
    for x in [x for w in ("hotbar", "bag") for x in d.get(w) or [] if isinstance(x, dict)
              and (w == "hotbar" or x.get("slot_type") == "InventoryItems")]:
        it = str(x.get("item"))
        carried[it] = carried.get(it, 0) + int(x.get("count") or 1)
        rows_of[it] = rows_of.get(it, 0) + 1
        if int(x.get("count") or 1) > 1:
            stack.add(it)
    surplus = fixture_surplus(carried, gear={it for it in carried if it not in stack})
    if not surplus:
        out["why"] = "bag short of room and none of it is fixture grants"
        return out
    crates = my_crates(ctx.cli)
    if not crates:
        out["why"] = "no crate of his in sight (data/skills/dev/my_pieces.json)"
        return out

    def freed(kv):  # rows that empty: all of a stack, or the spare copies of a piece of gear
        it, n = kv
        return rows_of.get(it, 0) if n >= carried.get(it, 0) else (n if rows_of.get(it, 0) >= carried.get(it, 0) else 0)
    ci = 0
    for item, n in sorted(surplus.items(), key=lambda kv: -freed(kv)):
        if not short():
            break
        while ci < len(crates):
            r = ctx.cli.request("store", {"item": item, "count": n, "container": crates[ci]["id"]}, timeout=120) or {}
            if r.get("reason") == "container_full":
                ci += 1
                continue
            dd = r.get("data") or {}
            row = {"t": round(time.time(), 1), "item": item, "count": int(dd.get("count") or n) if r.get("ok") else n,
                   "ok": bool(r.get("ok")), "crate": crates[ci]["id"], "reason": r.get("reason"), "detail": str(dd.get("detail") or "")[:200]}
            out["stored"].append(row)
            if r.get("ok"):
                CLEANUP_LOG.parent.mkdir(parents=True, exist_ok=True)
                with CLEANUP_LOG.open("a", encoding="utf-8") as f:
                    f.write(json.dumps(row) + "\n")
            break
        if KEEP.get(item) and any(x.get("item") == item for x in d.get("hotbar") or [] if isinstance(x, dict)):
            ctx.cli.request("move_item", {"item": item, "to": "hotbar"}, timeout=20)  # his kept one stays where he had it
        free, d2 = bag_free(ctx.cli)
        kg = float(d2.get("carry") or d2.get("weight") or 0) or kg
    out["free"], out["kg"] = free, kg
    if short():
        out["why"] = f"only {free} free bag slots, {kg} kg after storing fixture grants"
    return out


def room_words(room: dict) -> str:
    st = [f"{x['count']} {x['item']}" + ("" if x.get("ok") else f" (failed: {x.get('reason')})") for x in room.get("stored") or []]
    kg = f", {room.get('kg_before')} -> {room.get('kg')} kg" if room.get("kg_before") is not None else ""
    return (f"bag room: {room.get('free_before')} -> {room.get('free')} free slots{kg}"
            + (f", stored in his crate: {', '.join(st)}" if st else "") + (f"; {room['why']}" if room.get("why") else ""))


def it_stat(ctx: Ctx, item: str, stats: dict, want: dict, t_h: float, deadline_s: float, check_text: str,
            need_told: bool = True, note: str | None = None, after=None) -> dict:
    dev = cl._dev()
    time.sleep(4.0)  # the brain has read the state once at the old level (situation reviews need a band crossing)
    t0 = time.time()
    set_at = {}
    for stat, pct in stats.items():
        mx = (ctx.me().get("survival") or {}).get(stat, [0, 100])[1] or 100
        r = dev.setup("set_stat", purpose=f"rung1 gate {item}: {stat} {pct} %", stat=stat, value=mx * pct / 100.0)
        if isinstance(r, dict) and r.get("ok") and isinstance(r.get("after"), (int, float)):
            set_at[stat] = [time.time(), r["after"]]  # verified on the server (|after - want| < 1.5)
    row = run_leg(ctx, {"id": item, "kind": "r1_rest" if item == "rest" else "r1_stat", "check_text": check_text}, None,
                  {"want": want, "set": stats, "set_at": set_at}, deadline_s=deadline_s, t0=t0)
    st = row["rec"]["stats"]

    def work(a_, b_):  # the stat climbing during the stand (resting, eating)
        xs = [(t, s) for t, s in st if a_ - 1 <= t <= b_ + 1]
        return any(any((y.get(k) or 0) > (x.get(k) or 0) + 0.5 for k in want) for (_, x), (_, y) in zip(xs, xs[1:]))
    extra = after(row) if after else None  # item-specific bars from the leg (eat/drink: the choice judge)
    return finish(ctx, item, [row], t_h, allowed=1, work=work, need_told=need_told, note=note, extra=extra)


def uses_needed(stacks: list[dict], deficit: dict[str, float], values: dict | None = None,
                picks: dict | None = None) -> dict[str, int | None]:
    """Fewest uses of what he carries (hotbar + bag) that cover each stat's deficit (stat points), biggest gain first;
    None = what he carries can't cover it (he would have to find, cook or make more). `picks` (optional) gets the item
    ids those uses take, per stat."""
    if values is None:
        values = json.loads(FOOD_VALUES.read_text(encoding="utf-8"))["items"]
    out: dict[str, int | None] = {}
    for stat, need in deficit.items():
        gains = sorted(((float(values[r["item"]].get(stat) or 0), r["item"]) for r in stacks if r.get("item") in values
                        for _ in range(int(r.get("count") or 1)) if (values[r["item"]].get(stat) or 0) > 0), reverse=True)
        n, got, used = 0, 0.0, []
        for g, iid in gains:
            if got >= need:
                break
            n, got = n + 1, got + g
            used.append(iid)
        out[stat] = n if got >= need else None
        if picks is not None:
            picks[stat] = sorted(set(used))
    return out


# ---- eat/drink BY COMPARING OPTIONS (coordinator 2026-11-01): his food and drink moved off the hotbar into the bag (so
# the stay-fed reflex, hotbar only above 10 %, can't do it for him), options that differ in value and risk granted into
# the bag, a campfire 22 m off, food and water at 25 % (under his 40 % line). The model must choose; an LLM judge
# reads the options digest he was shown and says whether he took a clearly worse one without a reason.
# raw meat = Raw Rat Meat (ITEM_Resources_Meat_Bird is not grantable: fixture not_added, 18:20Z); it needs the fire
EAT_OPTIONS = {"ITEM_Consumable_Water_Dirty": 3, "ITEM_Resources_Raw_Stringy_Meat": 2, "ITEM_Consumable_Fruit_Redberry": 4}
EAT_BEST = {"ITEM_Consumable_Meat_Fillet": 2, "ITEM_Consumable_Water_Clean": 2}  # at least these (cooked, clean)
EAT_PCT = 25
MOVE_S = 0.37  # Luis's inventory drags back to back: median gap of his `move` rpcs (recorder 2026-11-01, 33 gaps)
CHOICE_SCHEMA = {"type": "object", "additionalProperties": False, "required": ["sensible", "clearly_worse", "why"],
                 "properties": {"sensible": {"type": "boolean"},
                                "clearly_worse": {"type": "array", "items": {"type": "string"}},
                                "why": {"type": "string"}}}
CHOICE_RUBRIC = (
    "You judge one choice a game character made about eating and drinking. FACTS has: the options digest he was shown "
    "(written for him: each option with its time, what it adds, his level after, how long it lasts, steps and risk), "
    "what he then did (tool calls in order with results) and what he said. Was his choice sensible? It is NOT sensible "
    "only if he took an option that is clearly worse than another one listed (for the same need: much slower for the "
    "same or less gain, riskier for no gain, e.g. dirty water or burnt food when a clean option as quick was on the "
    "list, or an option that leaves him under his line when one that clears it was as quick) AND he gave no reason for "
    "it. Small differences, ties and reasonable trade-offs are sensible. Judge only from the digest: never assume "
    "options it doesn't list. Answer with JSON: sensible, clearly_worse (the worse options he took, empty if none), "
    "why (one sentence).")


def _digest_seen(rows: list[dict]) -> list[str]:
    """The 'Need food' / 'Need drink' option lines he was shown when he chose: from the last prompt before his first
    eat/drink/move/craft call (all prompts when he made none), a need missing there taken from an earlier prompt."""
    seen: dict[str, str] = {}  # need kind -> its newest line
    for r in rows:
        if r.get("kind") == "tool_call" and r.get("tool") in ("consume", "move_item", "craft"):
            break
        if r.get("kind") != "prompt":
            continue
        c = (r.get("messages") or [{}])[-1].get("content")
        if isinstance(c, list):
            c = " ".join(x.get("text", "") for x in c if isinstance(x, dict))
        try:
            d = json.loads(c or "")
        except ValueError:
            continue
        for line in d.get("situation") or []:
            m = isinstance(line, str) and re.match(r"Need (food|drink|water) ", line)
            if m:
                seen[m.group(1)] = line
    return list(seen.values())


def choice_judge(rows: list[dict], says: list[str]) -> dict:
    """One Haiku call: did he take a clearly worse option (from the digest he saw) without a reason? {sensible, ...}."""
    from brain.llm import LiteLLMClient
    digest = _digest_seen(rows)
    if not digest:
        return {"sensible": None, "why": "no options digest in his prompts (nothing to judge against)"}
    acts = [{"tool": r.get("tool"), "args": r.get("args")} if r.get("kind") == "tool_call" else
            {"result_of": r.get("tool"), "ok": (r.get("result") or {}).get("ok"),
             "reason": (r.get("result") or {}).get("reason")} for r in rows if r.get("kind") in ("tool_call", "tool_result")]
    facts = {"options_digest": digest, "what_he_did": acts[:30], "he_said": says[:6]}
    llm = LiteLLMClient(tj.os.environ.get(tj.MODEL_ENV) or tj.DEFAULT_MODEL, max_tokens=2048,
                        output_config={"effort": "low", "format": {"type": "json_schema", "schema": CHOICE_SCHEMA}})
    resp = llm.complete([{"role": "system", "content": CHOICE_RUBRIC},
                         {"role": "user", "content": "FACTS\n" + json.dumps(facts, ensure_ascii=False, default=str)}])
    usd = 0.0
    if resp.usage:
        usd = spend.price(llm.model, resp.usage, spend.load_prices())[0]
        tj.STATS["calls"] += 1
        tj.STATS["usd"] += usd
        tj._ledger(llm.model, resp.usage)
    try:
        d = json.loads(resp.content or "")
    except ValueError:
        return {"sensible": None, "why": f"judge answer not JSON: {str(resp.content)[:120]!r}", "usd": round(usd, 6)}
    return {"sensible": bool(d.get("sensible")), "clearly_worse": d.get("clearly_worse") or [], "why": d.get("why"),
            "digest": digest, "usd": round(usd, 6)}


def it_eat_drink(ctx: Ctx) -> dict:
    from tools import travel_ladder as tl
    dev = cl._dev()
    tl.place(dev, ctx.cli, LUIS_SLEEP, harness_brain=True)  # by the base: a campfire 3 m off, his crates 11-16 m
    have = {}
    for r in ctx.stacks():
        have[r.get("item")] = have.get(r.get("item"), 0) + int(r.get("count") or 1)
    # the hotbar food has to fit in the bag (18:28Z: bag 32/32, every move inventory_full), and so do the options
    # granted below that he has none of: each is a new row (r1-20261102T043153Z: room made, then 2 grants took it)
    hot = [r for r in (cp.inventory(ctx.cli) or {}).get("hotbar") or [] if isinstance(r, dict) and r.get("use") in ("food", "drink")]
    room = make_room(ctx, len(hot) + sum(1 for it in {**EAT_OPTIONS, **EAT_BEST} if not have.get(it)) + 1)
    no_grant = []
    for it, n in {**EAT_OPTIONS, **EAT_BEST}.items():
        if have.get(it, 0) < n:
            try:
                dev.setup("grant", purpose="rung1 gate eat/drink: an option", item=it, count=n - have.get(it, 0))
            except Exception as e:  # noqa: BLE001 - one missing option still leaves a choice; the note says which
                no_grant.append(f"{it}: {e}")
    time.sleep(1.0)
    moved, left = [], []
    for r in (cp.inventory(ctx.cli) or {}).get("hotbar") or []:  # off the hotbar: the reflex can't use the bag above 10 %
        if isinstance(r, dict) and r.get("use") in ("food", "drink"):  # the inventory row's use: food | drink | nil
            res = dev.body_call("move_item", {"item": r.get("item"), "to": "bag"})
            (moved if res.get("ok") else left).append(r.get("item"))
    surv = ctx.me().get("survival") or {}
    mx = {k: float((surv.get(k) or [0, 100])[1] or 100) for k in ("sustenance", "hydration")}
    deficit = {k: mx[k] * (40 - EAT_PCT) / 100 for k in mx}
    picks: dict = {}
    n = uses_needed(ctx.stacks(), deficit, picks=picks)
    uses = max([v for v in n.values() if v] or [0])
    moves = len({i for v in picks.values() for i in v})  # each item used comes out of the bag first
    t_h = 1.5 + moves * MOVE_S + uses * USE_S + (BOTH_KINDS_S if all(n.values()) else 0.0)
    basis = (f"T_h = 1.5 s reaction + {moves} bag->hotbar moves x {MOVE_S} s (Luis's drag gap) + max(food "
             f"{n['sustenance']}, water {n['hydration']}) uses x {USE_S} s (the game's use lock, per kind) + "
             f"{BOTH_KINDS_S} s for the other kind's press (a player eats and drinks at once: Luis 0.06-0.83 s apart); "
             f"fewest uses of what he carries for {EAT_PCT} -> 40 %: {picks}"
             + ("; NOT enough carried for " + ", ".join(k for k, v in n.items() if v is None) if None in n.values() else "")
             + (f"; still on the hotbar (move failed): {left}" if left else "")
             + (f"; not granted: {no_grant}" if no_grant else "") + "; " + room_words(room))

    def judged(row):
        # from 10 s before the set: the harness's own bag moves can wake him, and the prompt he chose from is then
        # just before t0 (r1-20261102T042630Z: prompt at -0.5 s, "Need food" in it, "no options digest" read)
        brain = cl.brain_rows([ctx.brain_file], row["rec"]["t0"] - 10, row["rec"]["t1"] + 1)
        ch = choice_judge(brain, row.get("says") or [])
        ch["his_tools"] = [r.get("tool") for r in brain if r.get("kind") == "tool_call"][:12]
        t_set = min([float(v[0]) for v in (row["rec"]["target"].get("set_at") or {}).values()] or [row["rec"]["t0"]])
        # what woke him first after the set: the broker's band-crossing review or the body's vitals_low (its brain-log
        # time is when the brain polled it: during a chain turn that is late, live 20:23Z 19.7 s), then his first prompt
        woke = next(((float(r["ts"]), r.get("kind") if r.get("kind") != "event" else r["event"].get("type"))
                     for r in brain if float(r["ts"]) >= t_set and (r.get("kind") == "situation_review" or (
                         r.get("kind") == "event" and isinstance(r.get("event"), dict) and r["event"].get("type") == "vitals_low"))),
                    None)
        first = next((float(r["ts"]) for r in brain if r.get("kind") == "prompt" and float(r["ts"]) >= t_set), None)
        ch["woke"] = {"by": woke[1], "s": round(woke[0] - t_set, 1)} if woke else None
        ch["first_prompt_s"] = round(first - t_set, 1) if first else None
        row["choice"] = ch
        # "chose": the model itself ate, drank or moved food (a reflex pass compared nothing: a "stays fed" check only)
        return {"choice": ch.get("sensible") is True,
                "chose": any(t in ("consume", "move_item", "craft") for t in ch["his_tools"])}

    if left:  # a choice test with his food still on the hotbar is a reflex test: not run
        return {"item": "eat_drink", "pass": False, "fails": ["setup"], "room": room,
                "why": f"his food/drink could not leave the hotbar ({left}); {room_words(room)}"}
    try:
        row = it_stat(ctx, "eat_drink", {"sustenance": EAT_PCT, "hydration": EAT_PCT}, {"sustenance": 40, "hydration": 40},
                       t_h, 150, f"his food (sustenance) and water (hydration), set to {EAT_PCT} % by the harness with his "
                       "food and drink in the bag (options of different value and risk), both come back to >= 40 % of "
                       "their max (his eat line)", need_told=False, note=basis, after=judged)
        row["room"] = room
        return row
    finally:  # his usual hotbar back, so the stay-fed reflex works for everyone else's runs
        for it in dict.fromkeys(moved):
            dev.body_call("move_item", {"item": it, "to": "hotbar"})


GET_UP = ROOT / "client_mod" / "commands" / "get_up.lua"


def get_up() -> dict:
    """Up out of a bed or shelter the player's way (client_mod/commands/get_up.lua: an interact press ends a rest),
    verified from his own rest component. The rest item ends while he still lies there (resting = done), and the next
    agent's craft failed on it (main 19:59Z). -> {up, was_in, presses}"""
    from tools.scenario_run import run_client_cmd

    def read() -> dict:
        return (run_client_cmd(GET_UP, "r1_get_up_read", {"press": False}, 15) or {}).get("result") or {}
    out: dict = {"up": None, "was_in": None, "presses": 0}
    r = read()
    if not r.get("ok"):
        out["why"] = r.get("reason") or "no answer"
        return out
    for _ in range(2):
        if not r.get("resting_in"):
            out["up"] = True
            return out
        out["was_in"] = r["resting_in"]
        p_ = (run_client_cmd(GET_UP, "r1_get_up", None, 15) or {}).get("result") or {}
        out["presses"] += 1
        out["press"] = p_.get("press") if p_.get("pressed") else (p_.get("reason") or p_.get("press"))
        t_end = time.time() + 4.0
        while time.time() < t_end:
            time.sleep(0.5)
            r = read()
            if not r.get("resting_in"):
                break
    out["up"] = not r.get("resting_in")
    return out


def it_rest(ctx: Ctx) -> dict:
    # where Luis stood when he said "sleep" (recorder 12:46:52Z): open ground by the base, where his Summon Shelter
    # went down. Live 16:07Z from the fight's respawn point in Temple Woods every spot near him read "blocked" and
    # both flat-ground hints were off his walkable map (two go_to failures, 97 s): a terrain test, not this item.
    from tools import travel_ladder as tl
    tl.place(cl._dev(), ctx.cli, LUIS_SLEEP, harness_brain=True)
    t_h = luis_task_s("sleep") or 28.0
    before = _pct(ctx.me()).get("endurance")
    row = None
    try:
        row = it_stat(ctx, "rest", {"endurance": 5}, {"endurance": 90}, t_h, 180,
                      "his rest (endurance), set to 5 % by the harness, climbs by >= 8 points (a nap in a bed or a Summon "
                      "Shelter: +1/s; a night's sleep refills it) or reaches 90 %")
        return row
    finally:
        up = get_up()  # pass, fail or timeout: he leaves the bed before the lock goes (checked from his rest component)
        print(f"  rest: got up {up}", flush=True)
        if row is not None:
            row["got_up"] = up
        # undo the harness's own exhaustion when he did not rest it off: it carried into the next run's fight (live
        # 17:35Z: max stamina 40 at endurance 0, he parried a 20-HP runt for 24 s without a swing)
        surv = ctx.me().get("survival") or {}
        cur, mx = (surv.get("endurance") or [None, 100])[:2]
        if before is not None and isinstance(cur, (int, float)) and 100.0 * cur / (mx or 100) < before - 5:
            cl._dev().setup("set_stat", purpose="rung1 gate rest: undo the harness's exhaustion", stat="endurance",
                            value=(mx or 100) * before / 100.0)


def it_come_follow(ctx: Ctx) -> dict:
    if ctx.a.target_player:
        legs = [run_leg(ctx, {"id": "come_here", "kind": "come_here"}, f"claude come over to {ctx.a.target_player}",
                        {"player": ctx.a.target_player}, deadline_s=240),
                run_leg(ctx, {"id": "follow", "kind": "follow"}, f"claude follow {ctx.a.target_player} for a bit",
                        {"player": ctx.a.target_player}, deadline_s=80)]
        return finish(ctx, "come_follow", legs, None, allowed=1)
    return {"item": "come_follow", "pass": False, "blocked": True, "fails": ["blocked"],
            "why": "no visible player: 'come to me' / 'follow me' from chat need Luis or a Tester pawn (Tester is chat-only)"}


def come_follow_proxy(a) -> dict:
    """The model-free ghost-leader follow (travel_ladder.run_follow): a number for the item, never its pass."""
    from tools import travel_ladder as tl
    gs = tl.ghosts()
    if not gs:
        return {"error": "no ghost tracks (data/ladder/ghost_tracks.json)"}
    name = sorted(gs)[a.run_index % len(gs)]
    try:
        r = tl.run_follow(cl._dev(), name, gs[name])
    except Exception as exc:  # noqa: BLE001
        return {"error": repr(exc), "ghost": name}
    return {"ghost": name, "ok": r.get("ok"), "claude": r.get("claude"), "human": r.get("human"), "s": r.get("s")}


def spot_debris(ctx: Ctx) -> list[str]:
    """What lies within GRAVE_CLEAN_M of him that an earlier run left: any gravestone, loose items. A fixture death
    there is no fair test (r1-20261102T074119Z read run 1's leftover logs, stone and sword as "the big grave, empty
    already" and went to an older grave)."""
    lk = (ctx.cli.request("look", {"radius": GRAVE_CLEAN_M, "max": 30}, timeout=15) or {}).get("data") or {}
    out = []
    for t in lk.get("things") or []:
        if (t.get("distance") or 0) > GRAVE_CLEAN_M:
            continue
        if "Gravestone" in str(t.get("class")):
            out.append(f"a gravestone {t.get('distance', 0):.0f} m off")
        elif t.get("category") == "items":
            out.append(f"{t.get('count') or 1} {t.get('name')} on the ground")
    return out


def grave_cleanup(ctx: Ctx, ts) -> str:
    """The fixture's own grave, left by a failed leg, is test debris: he takes it back by direct tool calls (no
    model), so the next run's grave list and death spot are clean."""
    st = (ctx.cli.request("get_state", {}, timeout=15) or {}).get("data") or {}
    left = [g for g in st.get("graves_remembered") or [] if str(g.get("ts")) == str(ts)]
    if not left:
        return "his fixture grave is recovered"
    r = ctx.cli.request("go_to", {"target": f"my_grave:{ts}"}, timeout=240) or {}
    g = ctx.cli.request("recover_grave", {}, timeout=120) or {}
    return (f"cleanup: walked to the fixture grave ({'ok' if r.get('ok') else r.get('reason')}), "
            f"recover_grave {'ok' if g.get('ok') else g.get('reason')}: {((g.get('data') or {}).get('detail') or '')[:160]}")


def it_grave(ctx: Ctx) -> dict:
    from tools import travel_ladder as tl
    dev = cl._dev()
    tl.place(dev, ctx.cli, LUIS_SLEEP, harness_brain=True)  # by his crates: room for what comes back
    room = make_room(ctx)
    debris = {}
    for k in range(len(GRAVE_SPOTS)):  # the first clean spot from this run's turn on
        spot = GRAVE_SPOTS[(ctx.a.run_index + k) % len(GRAVE_SPOTS)]
        tl.place(dev, ctx.cli, spot, harness_brain=True)
        debris[str(spot)] = spot_debris(ctx)
        if not debris[str(spot)]:
            break
    else:
        return {"item": "grave", "pass": False, "fails": ["setup"],
                "why": "every grave spot holds an earlier run's debris: " + json.dumps(debris)}
    carried = cp.counts({"bag": ctx.stacks()})
    if sum(carried.values()) < 3:
        return {"item": "grave", "pass": False, "fails": ["setup"], "why": "he carries almost nothing: no grave worth recovering"}
    # the game files the grave where it last saw him stand: a death right after a teleport can leave it back where
    # he was before (server log 07:47:16Z: the grave at the crates, 160 m from this spot). A few steps here first.
    ctx.cli.request("go_to", {"target": [spot[0] + 2.0, spot[1], spot[2]], "tolerance": 0.8}, timeout=30)
    time.sleep(GRAVE_SETTLE_S)
    grave_at = ctx.me().get("position")
    dev.setup("set_health", purpose="rung1 gate grave: die here", value=0.0)
    t_dead = time.time()
    while time.time() - t_dead < 120:  # dead, then respawned (at the church lodestone)
        m = ctx.me()
        if m and not m.get("dead") and obs._xyz(m.get("position")) and obs.hdist(m["position"], grave_at) > 20:
            break
        time.sleep(2.0)
    else:
        return {"item": "grave", "pass": False, "fails": ["setup"], "why": "no respawn within 120 s of the fixture death"}
    # where the game put the grave: his newest grave on the map (skills.bind_graves), else where he died
    newest, t_map = None, time.time()
    while time.time() - t_map < GRAVE_MAP_WAIT_S:
        st = (ctx.cli.request("get_state", {}, timeout=15) or {}).get("data") or {}
        newest = (st.get("graves_remembered") or [None])[0]
        if newest and newest.get("on_map"):
            break
        time.sleep(2.0)
    died_at = grave_at
    if newest and newest.get("on_map") and obs._xyz(newest.get("position")):
        grave_at = newest["position"]
    off = obs.hdist(died_at, grave_at)
    d = obs.hdist(ctx.me()["position"], grave_at)
    # the judge reads this: what the grave holds, by name (2026-11-15: told only "the items he carried (8295)", it
    # called "no weapon in the grave" false on a grave of 6 Clean Water and 6 Fillet; re-judged, 2 of 12 true lines false)
    went = grave_lost(carried, cp.counts({"bag": ctx.stacks()}))
    row = run_leg(ctx, {"id": "grave", "kind": "r1_grave", "check_text": grave_check_text(went, d)},
                  "claude go get your stuff from your grave", {"carried": carried, "grave_at": grave_at, "died_at": died_at,
                                                               "dist_m": round(d, 1)},
                  deadline_s=300, sample=("me", "inv"))
    t_h = 1.5 + d / (ss.latest_baselines().get("travel_speed_mps") or 6.25) + 1.0
    where = ("on his map" if newest and newest.get("on_map") else "not on his map: the death spot") + \
        (f", {off:.0f} m from where he died" if off > 5 else "")
    g = finish(ctx, "grave", [row], t_h, allowed=1, note=f"grave {d:.0f} m from the respawn ({where}); {room_words(room)}")
    g["room"] = room
    if not g.get("pass") and newest and newest.get("ts"):
        g["cleanup"] = grave_cleanup(ctx, newest["ts"])
    return g


def with_progress(legs: list[dict], work=None):
    """A still stretch is work, not a stand, while the body action's own progress counters move (main 2026-11-02:
    moving 240 stacks one press at a time is a player sorting a grave screen). The counter every item samples is his
    bag (the leg's inv samples, every ~2 s): a change landing inside the stretch (or 2 s after, the read's lag) is
    items moved. Metres walked can't move in a still stretch; hits are each item's own work() (fight_back)."""
    inv = sorted((s[0], s[1]) for x in legs for s in ((x.get("rec") or {}).get("inv") or []) if len(s) > 1)
    moved = [b[0] for a, b in zip(inv, inv[1:]) if a[1] != b[1]]

    def w(a, b):
        return any(a <= t <= b + 2.0 for t in moved) or bool(work and work(a, b))
    return w


def finish(ctx: Ctx, item: str, legs: list[dict], t_h: float | None, allowed: int, misses: int | None = None, work=None,
           note: str | None = None, need_told: bool = True, audience: bool | None = None,
           extra: dict | None = None) -> dict:
    legs = [x for x in legs if not x.get("skipped")] or legs
    if misses is None:
        misses = sum(x.get("fumbles") or 0 for x in legs)
    def start(x):
        return x["rec"].get("t_start") or x["rec"]["t0"]
    t0 = min(start(x) for x in legs if x.get("rec")) if any(x.get("rec") for x in legs) else time.time()
    t1 = max((start(x) + (x.get("done_s") or x.get("wall_s") or 0)) for x in legs if x.get("rec")) if \
        any(x.get("rec") for x in legs) else t0
    if audience is None:
        audience = any(x["rec"].get("audience") for x in legs if x.get("rec")) or bool(ctx.a.target_player)
    says = [t for x in legs for t in x.get("say_ts") or []]
    stand_s, stands = stand_bar(t0, t1, says, with_progress(legs, work))
    g = grade(item, legs, round(t_h, 1) if t_h else None, misses, allowed, stand_s, need_told, audience, extra)
    g.update(note=note, stands=stands, legs=[{k: x.get(k) for k in ("request", "line", "done", "how", "done_s", "wall_s",
                                                                    "ended", "truthful", "truth_source", "says", "tools",
                                                                    "fumbles", "deaths", "calls", "usd", "flags",
                                                                    "first_hit_s", "engaged_s", "response_s", "kit", "choice", "recorder",
                                                                    "metrics", "heard_s")}
                                             for x in legs],
             calls=sum(x.get("calls") or 0 for x in legs), usd=round(sum(x.get("usd") or 0 for x in legs), 4),
             recs=[x.get("rec") for x in legs])
    return g


RUNNERS = {"split_drop": it_split_drop, "pickup": it_pickup, "fight_back": it_fight_back, "eat_drink": it_eat_drink,
           "rest": it_rest, "come_follow": it_come_follow, "grave": it_grave}


# ------------------------------------------------------------------ run / report
def recorder_ok() -> bool:
    files = sorted((ROOT / "logs" / "recorder").glob("rec_*.jsonl"), key=lambda p: p.stat().st_mtime)
    return bool(files) and time.time() - files[-1].stat().st_mtime < 30


def ensure_recorder() -> str:
    """The server recorder (read-only, server side) armed: an arm lasts `seconds` and then stops by itself (live 17:29Z:
    it expired mid-run and the stand bar read nothing). Re-armed onto the newest file, for 4 h."""
    srv = cl._server_client()
    st = (srv.request("debug_run", {"module": "player_recorder", "args": {"action": "status"}}, timeout=30).get("data")
          or {}).get("result") or {}
    if st.get("armed"):
        return "armed"
    files = sorted((ROOT / "logs" / "recorder").glob("rec_*.jsonl"), key=lambda p: p.stat().st_mtime)
    out = st.get("file") or (files[-1].as_posix() if files else (ROOT / "logs" / "recorder" /
                             datetime.now(timezone.utc).strftime("rec_%Y%m%dT%H%M%SZ.jsonl")).as_posix())
    r = srv.request("debug_run", {"module": "player_recorder", "args": {"action": "arm", "out": out, "seconds": 14400,
                                                                         "period_ms": 200}}, timeout=30)
    return f"re-armed {out}: {bool(((r.get('data') or {}).get('result') or {}).get('ok'))}"


def cmd_run(a) -> int:
    if not a.confirm:
        print("refusing: a live run sends test chat and uses dev fixtures on Claude; pass --confirm")
        return 2
    items = [i for i in ITEMS if not a.only or i in a.only.split(",")]
    if not recorder_ok():
        print(f"recorder: {ensure_recorder()}")
        time.sleep(2.0)
    if not recorder_ok():
        print("the server recorder is not writing (logs/recorder): re-arm it (player_recorder arm) before a gate run")
        return 3
    before = spend.spend_today()
    print(f"spend before ${before['spent_usd']:.4f}; items {items}; runs {a.runs}")
    if before["state"] != "ok":
        return 3
    for run in range(a.runs):
        a.run_index = a.first_index + run
        run_id = datetime.now(timezone.utc).strftime("r1-%Y%m%dT%H%M%SZ")
        if a.one_window:
            groups = [items]
        elif a.groups:
            groups = [[i for i in g.split(",") if i in items] for g in a.groups.split(";")]
        else:
            groups = [[i] for i in items]
        groups = [g for g in groups if g]
        for group in groups:
            with live_lock.held("rung1", wait_s=a.wait):
                rs = ensure_recorder()
                if rs != "armed":
                    print(f"  recorder: {rs}")
                for item in group:
                    a.start_brain, a.use_running_brain = True, False
                    bad = wait_preflight(a)
                    if bad:
                        print(f"  {item}: not run: {bad}")
                        continue
                    row = run_item(a, item, run_id)
                    write(row)
                    print(line(row), flush=True)
    after = spend.spend_today()
    print(f"spend ${before['spent_usd']:.4f} -> ${after['spent_usd']:.4f}\n{tj.stats_line()}")
    return cmd_report(a)


def wait_preflight(a, max_s: float = 90.0) -> list[str]:
    """chat_ladder's preflight; a driver in the last 60 s or a brain still shutting down (the previous lock holder's,
    or this gate's own last one) is waited out while we hold the lock (live 15:5xZ: quests' brain was still up 5 s
    after its release and both items were skipped)."""
    t_claim = time.time()
    t_end = t_claim + max_s
    while True:
        bad = cl.preflight(a)
        if any("someone drove" in b for b in bad) and driver(t_claim) is None:
            bad = [b for b in bad if "someone drove" not in b]
        if not bad or time.time() > t_end or any("someone drove" not in b and "already running" not in b for b in bad):
            return bad
        time.sleep(5.0)


def driver(t_claim: float, window_s: float = 60.0) -> str | None:
    """chat_ladder.recent_bridge_driver without the commands that can't be moving him now: pure reads (another agent's
    `inventory` 25 s before the check, 18:29Z: a whole window skipped), this gate's own (rung1, e.g. live_lock's stop
    at the claim), and a lock holder's sent before our claim (the claim's force stop ended them). Left: an unlocked
    sender's body command, or anyone else's after we took the lock."""
    now = time.time()
    for name in ("debug_to_client.jsonl", "brain_to_client.jsonl"):
        for r in reversed(cl._tail_rows(cl.CLIENT_BRIDGE / name)):
            t = r.get("ts")
            if not isinstance(t, (int, float)) or now - t > window_s:
                break
            owner = str(r.get("src") or "-").split(":")[0]
            if r.get("tool") in ("ping", "capabilities", "me", *cl.READ_ONLY_TOOLS) or owner == "rung1" or                     (owner != "-" and t < t_claim):
                continue
            return f"{name}: {r.get('tool')} from {r.get('src') or '?'} {now - t:.0f} s ago"
    return None


def run_item(a, item: str, run_id: str) -> dict:
    proxy = None
    if item == "come_follow" and not a.target_player:  # body-only proxy, no brain on the pawn while the ghost runs
        proxy = come_follow_proxy(a)
        return {"run_id": run_id, "item": item, "pass": False, "blocked": True, "fails": ["blocked"], "proxy": proxy,
                "why": "no visible player: 'come to me' / 'follow me' from chat need Luis or a Tester pawn (Tester is chat-only)",
                "ts": round(time.time(), 1)}
    ok, why = cl.ensure_sender()
    if not ok:
        return {"run_id": run_id, "item": item, "pass": False, "fails": ["infra"], "why": why}
    up = get_up()  # never start an item lying in a bed someone else left him in
    if up.get("presses"):
        print(f"  {item}: he was lying in {up.get('was_in')}: got up {up}", flush=True)
    if item != "eat_drink" and getattr(a, "supply", True):  # the coordinator's harness top-up (food/water, HP < 30); the eat/drink item runs without it
        from tools import supply
        try:
            sup = supply.top_up(cl._dev(), 6, 6, heal=True, purpose=f"rung1 gate {item}")
        except Exception as exc:  # noqa: BLE001  (fixtures refused, e.g. other_players_connected: a harness row, not a crash)
            return {"run_id": run_id, "item": item, "pass": False, "fails": ["infra"],
                    "why": f"supply top-up: {type(exc).__name__}: {exc}"[:400], "ts": round(time.time(), 1)}
        if not sup.get("ok"):
            print(f"  {item}: supply top-up failed: {sup.get('why')}")
    proc, bfile = cl.start_brain(a, spend.spend_today()["spent_usd"])
    try:
        if bfile is None:
            return {"run_id": run_id, "item": item, "pass": False, "fails": ["infra"], "why": "the brain did not start"}
        ctx = Ctx(a, cl._debug_client(), bfile, run_id)
        try:
            row = RUNNERS[item](ctx)
        except Exception as exc:  # noqa: BLE001  (a fixture or bridge failure: infra, not a body failure)
            row = {"item": item, "pass": False, "fails": ["infra"], "why": f"{type(exc).__name__}: {exc}"[:400]}
        row.update(run_id=run_id, brain_log=bfile.name, ts=round(time.time(), 1))
        return row
    finally:
        cl.stop_brain(proc)


def write(row: dict) -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT, "a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False, default=str) + "\n")


def line(r: dict) -> str:
    if r.get("blocked") or r.get("why"):
        px = r.get("proxy") or {}
        return (f"  {r['item']:<11} {'BLOCKED' if r.get('blocked') else 'FAIL   '} {r.get('why')}"
                + (f" | proxy ghost {px.get('ghost')}: {px.get('claude')}" if px else ""))
    b = r.get("bars") or {}
    return (f"  {r['item']:<11} {'PASS' if r.get('pass') else 'FAIL'} wall {r.get('wall_s')} s vs T_h {r.get('t_h')} "
            f"(x{r.get('ratio')}), misses {r.get('misses')}/{r.get('misses_allowed')}, longest stand {r.get('longest_stand_s')} s, "
            f"truthful {r.get('truthful')} told {r.get('told')}; fails {r.get('fails') or '-'}; calls {r.get('calls')} "
            f"${r.get('usd')}; {r.get('note') or ''}\n" +
            "".join(f"      {x.get('request')}: {x.get('how')} | said {x.get('says')} | tools {x.get('tools')}\n"
                    + (f"      choice sensible={x['choice'].get('sensible')} worse={x['choice'].get('clearly_worse')}: "
                       f"{x['choice'].get('why')} | his tools {x['choice'].get('his_tools')} | woke {x['choice'].get('woke')}, "
                       f"first prompt {x['choice'].get('first_prompt_s')} s\n" if x.get("choice") else "")
                    for x in r.get("legs") or []))


def cmd_report(a) -> int:
    rows = [r for r in obs.jsonl(OUT)] if OUT.exists() else []
    if not rows:
        print("no gate rows yet")
        return 1
    for r in rows:  # an eat_drink row without the choice bar is the old reflex variant: a "stays fed" check, not the item
        if r.get("item") == "eat_drink" and r.get("bars") and "choice" not in r["bars"]:
            r["item"] = "stays_fed"
    runs: dict[str, dict[str, dict]] = {}
    for r in rows:
        runs.setdefault(r.get("run_id") or "?", {})[r["item"]] = r
    print(f"{'run':<20} " + " ".join(f"{i:<11}" for i in ITEMS))
    for rid, its in runs.items():
        print(f"{rid:<20} " + " ".join(f"{('PASS' if its[i].get('pass') else 'BLOCK' if its[i].get('blocked') else 'fail') if i in its else '-':<11}"
                                         for i in ITEMS))
    print("streaks (consecutive passes, newest back; need 3):")
    for i in (*ITEMS, "stays_fed"):
        seq = [r for r in rows if r["item"] == i and not {"infra", "setup"} & set(r.get("fails") or [])]  # harness
        streak = next((k for k, r in enumerate(reversed(seq)) if not r.get("pass")), len(seq))
        last = seq[-1] if seq else {}
        print(f"  {i:<11} {streak} in a row ({len(seq)} runs); last: {('PASS' if last.get('pass') else ', '.join(last.get('fails') or []) or '-')}")
    return 0


def cmd_plan(a) -> int:
    print(__doc__.split("Items (in run order")[1].split("Every request")[0])
    print(f"T_h: split {luis_task_s('split')} s (Luis), sleep {luis_task_s('sleep')} s (Luis), kill unit {unit('kill')} s, "
          f"pickup unit {unit('pickup')} s, drop unit {unit('drop')} s, eat_drink 1.5 + bag moves x {MOVE_S} + max(food, water uses) "
          f"x {USE_S} + {BOTH_KINDS_S} s (game use lock per kind) + a choice judge on the options digest he saw")
    print(f"recorder writing: {recorder_ok()}; live lock: {live_lock.read() or 'free'}")
    print("cost: ~2-5 Haiku calls per item + 1 judge call per leg; a full run ~25-40 Haiku calls (< $0.10)")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("plan")
    sub.add_parser("report")
    r = sub.add_parser("run")
    r.add_argument("--confirm", action="store_true")
    r.add_argument("--only")
    r.add_argument("--runs", type=int, default=1)
    r.add_argument("--first-index", type=int, default=0, help="rotates the pickup patch / grave spot / ghost track")
    r.add_argument("--target-player", default=None, help="a visible player for give / come / follow (Luis)")
    r.add_argument("--world", default=WORLD)
    r.add_argument("--max-haiku", type=int, default=30, help="per item")
    r.add_argument("--usd", type=float, default=0.30, help="each item's brain spend cap above today's spend")
    r.add_argument("--wait", type=float, default=3000.0, help="seconds to wait for the live lock")
    r.add_argument("--one-window", action="store_true", help="hold the lock once for all the items (keep it short: <= ~8 min)")
    r.add_argument("--groups", default="", help='items per lock window, ";"-separated (e.g. "split_drop,pickup,fight_back;'
                   'eat_drink,rest;come_follow,grave"): fewer waits in the queue, each window still short')
    r.add_argument("--supply", action=argparse.BooleanOptionalAction, default=True,
                   help="the harness food/water/HP top-up before each item (eat_drink never gets it)")
    r.add_argument("--judge", action=argparse.BooleanOptionalAction, default=None)
    a = ap.parse_args(argv)
    a.run_index = getattr(a, "first_index", 0)
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    return {"plan": cmd_plan, "run": cmd_run, "report": cmd_report}[a.cmd](a)


if __name__ == "__main__":
    raise SystemExit(main())

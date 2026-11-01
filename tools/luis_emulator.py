r"""The Luis emulator (docs/research/2026-11-01-evals-human-standard.md 2.b): tests Claude like Luis does (short noisy
lines, "near me", follow-ups while the task runs, corrections, impatience) through the Tester sender on the dev
world, and leaves every verdict to code (tools/coplay_ladder.check / score: game state, then tools/standard_score.level).

Code decides WHEN Luis speaks (the triggers below, from his real follow-ups); a writer decides only the WORDS:
  CannedWriter  (--dry-run, the default): his own lines from the style bank, picked by trigger, seeded. $0.
  SonnetWriter  (--confirm --sonnet): one Sonnet 5.5 call per burst, forced JSON {lines, gaps_ms, end}, capped by
                --max-sonnet calls and --usd. NOT authorised yet: run it only when Luis / the coordinator says so.

    .venv\Scripts\python.exe -m tools.luis_emulator style        # build data/luis_style/2026-11-01.jsonl from the co-play log
    .venv\Scripts\python.exe -m tools.luis_emulator plan         # style card, prompt, sample digest, cost estimate; no calls
    .venv\Scripts\python.exe -m tools.luis_emulator calibrate    # replay the co-play log through the triggers; offline, $0
    .venv\Scripts\python.exe -m tools.luis_emulator run --confirm --start-brain [--only kill,chop] [--dry-run]
    .venv\Scripts\python.exe -m tools.luis_emulator run --confirm --start-brain --sonnet --max-sonnet 40 --usd 0.40

What the emulator sees is only what Luis could see on screen (the digest every 2 s): Claude's position relative to
Tester and to the target (metres, closing or opening), speed and sprinting, moving or standing and for how long,
items still near the anchor, creatures near either of them, and Claude's chat lines. Never his bag, reasoning or tool
results. Run guards are coplay_ladder's (chat_ladder.preflight: dev server only, no hold file, nobody else driving;
the Haiku cap; the brain spend cap) plus the writer's own caps. Rows: logs/evals/luis_emulator.jsonl.
"""
from __future__ import annotations

import argparse
import json
import random
import re
import statistics
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from tools import coplay_ladder as cp
from tools import obs, spend
from tools import standard_score as ss

ROOT = ss.ROOT
OUT = ROOT / "logs" / "evals" / "luis_emulator.jsonl"
STYLE_FILE = ROOT / "data" / "luis_style" / "2026-11-01.jsonl"
SONNET = "anthropic/claude-sonnet-5-5"
TICK_S, SPEAK_EVERY_S = 2.0, 6.0          # digest cadence; at most one burst per 6 s
GIVE_UP_X, GIVE_UP_S = 5.0, 300.0          # give up at 5 x T_h or 300 s
STILL_S, WRONG_WAY_M, SLOW_LEG_M, SLOW_MPS = 8.0, 10.0, 30.0, 4.0
CHATTER = (20.0, 45.0, 0.5)                # a status / unrelated question 20-45 s in, p = 0.5, once
# His style on 2026-11-01 (design doc 2.b): the session must stay inside these bands or it is invalid.
BANDS = {"words_median": (4, 12), "question_rate": (0.08, 0.35), "polite_rate": (0.0, 0.2), "names_claude": (0.1, 0.45)}
KIND_RX = [  # labels for his real follow-ups (eval-side; never shown to the brain)
    ("where_why", r"\b(?:where|why|what are you|what were you|are you stuck|you aren'?t|youa rent|you arent)\b"),
    ("correction", r"\b(?:near me|by me|you missed|i meant|not that|infront|in front|i said|wrong)\b"),
    ("urgency", r"\b(?:now|urgent\w*|hurry|quick\w*)\b|[A-Z]{3,}"),
    ("status", r"\b(?:food|water|thirst|hunger|inventory|capacity|weigh\w*|levels?|health|hp)\b"),
    ("ack", r"^\W*(?:awesome|nice|great|thanks|cheers|cool|no worries|ok(?:ay)?)\b"),
]
POLITE_RX = re.compile(r"\b(?:please|ple\w*se|thanks|thank you|cheers|awesome)\b", re.I)
DONE_CLAIM_RX = re.compile(r"\b(?:got (?:them|it|all|the)|done|picked (?:them|it) up|all (?:of them|gone)|that'?s all)\b", re.I)
SCHEMA = {"type": "object", "additionalProperties": False, "required": ["lines", "gaps_ms", "end"],
          "properties": {"lines": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 4},
                         "gaps_ms": {"type": "array", "items": {"type": "integer"}}, "end": {"type": "boolean"}}}
SYSTEM = """You are Luis, testing your AI companion Claude in RuneScape: Dragonwilds. You play on GeForce Now and type in chat.
Write like Luis: short lines (median 7 words), lowercase, typos left in, few question marks, almost no please/thanks,
bursts of 1-4 lines, escalate (caps, "now") when ignored. Name him ("claude") in about a fifth of lines.
Rules: use only facts in the scenario card and the digest (what you can see on your screen); never give him coordinates,
tool names or game internals; never accept a claim the digest contradicts ("theres still 2 here"); one burst per turn.
Answer his questions only from the scenario card. Reply with JSON {"lines": [...], "gaps_ms": [...], "end": false}."""


def label(text: str) -> str:
    return next((k for k, rx in KIND_RX if re.search(rx, text, re.I if k != "urgency" else 0) or
                 (k == "urgency" and re.search(r"\b(?:now|urgent\w*|hurry)\b", text, re.I))), "request")


# ------------------------------------------------------------------ style bank (from the co-play log)
def build_style(brain: Path = ss.COPLAY_LOG) -> list[dict]:
    from tools.session_report import Session
    s = Session(brain)
    says = s.brain.says
    out, prev = [], None
    for e in s.requests:
        for ts, player, text, note in e.lines:
            if note:
                continue
            last_say = max((a for a, _, _ in says if a < ts), default=None)
            doing = next((t.tool for t in reversed(s.brain.tools) if t.ts < ts and not t.read_only
                          and (t.body is None or t.body.end is None or t.body.end >= ts)), None)
            out.append({"ts": ts, "text": text, "kind": label(text), "words": len(text.split()),
                        "gap_s": round(ts - prev, 1) if prev else None,
                        "since_claude_s": round(ts - last_say, 1) if last_say else None, "claude_doing": doing})
            prev = ts
    return out


def style_stats(lines: list[str]) -> dict:
    if not lines:
        return {}
    n = len(lines)
    return {"n": n, "words_median": statistics.median(len(x.split()) for x in lines),
            "question_rate": round(sum("?" in x for x in lines) / n, 2),
            "polite_rate": round(sum(bool(POLITE_RX.search(x)) for x in lines) / n, 2),
            "names_claude": round(sum("claude" in x.lower() for x in lines) / n, 2),
            "lowercase_start": round(sum(x[:1].islower() for x in lines) / n, 2)}


def style_valid(stats: dict) -> tuple[bool, list[str]]:
    bad = [f"{k} {stats.get(k)} outside {lo}-{hi}" for k, (lo, hi) in BANDS.items()
           if stats.get(k) is None or not lo <= stats[k] <= hi]
    return not bad, bad


def load_style() -> list[dict]:
    if not STYLE_FILE.exists():
        return []
    return [json.loads(x) for x in STYLE_FILE.read_text(encoding="utf-8").splitlines() if x.strip()]


# ------------------------------------------------------------------ triggers (code decides when he speaks)
def triggers(st: dict, now: float) -> list[str]:
    """st: the request's live state (digest history, T_h, said lines, flags). Returns the triggers firing now."""
    out, me, t0 = [], st["me"], st["t0"]
    el = now - t0
    if me:
        recent = [p for p in me if p[0] >= now - STILL_S]
        if el > STILL_S and recent and max(obs.hdist(recent[0][1:4], p[1:4]) for p in recent) < 1.0:
            out.append("stood_still")
    d = st.get("dist") or []  # (ts, metres to the target)
    if len(d) >= 2 and d[-1][1] - min(x[1] for x in d) > WRONG_WAY_M:
        out.append("wrong_way")
    if len(me) >= 2:
        leg = [p for p in me if p[0] >= now - 10]
        if len(leg) >= 2:
            m = obs.hdist(leg[0][1:4], leg[-1][1:4])
            if m >= SLOW_LEG_M * (leg[-1][0] - leg[0][0]) / 10 and m / max(0.1, leg[-1][0] - leg[0][0]) < SLOW_MPS \
                    and (st.get("endurance") or 0) >= 25 and st.get("travel_m", 0) >= SLOW_LEG_M:
                out.append("not_running")
    if st.get("left") and st.get("claude_says") and DONE_CLAIM_RX.search(st["claude_says"][-1][1]) \
            and st["claude_says"][-1][0] > st.get("last_spoke", 0):
        out.append("missed_some")
    if el > 1.5 * st["t_h"] and "impatience" not in st["fired"]:
        out.append("impatience")
    if el > 3 * st["t_h"] and "urgency" not in st["fired"]:
        out.append("urgency")
    if st.get("claude_says") and st["claude_says"][-1][1].rstrip().endswith("?") and st["claude_says"][-1][0] > st.get("last_spoke", 0):
        out.append("his_question")
    if "chatter" not in st["fired"] and st["chatter_at"] is not None and el >= st["chatter_at"]:
        out.append("chatter")
    return out


# ------------------------------------------------------------------ writers (the words only)
class CannedWriter:
    """Dry run: his own real lines of the same kind from the style bank (seeded), the request from the ladder's
    template. No model calls."""
    model = "canned"

    def __init__(self, seed: int = 1):
        self.rng = random.Random(seed)
        self.bank = load_style()
        self.calls, self.usd = 0, 0.0

    def write(self, trigger: str, card: dict, digest: dict, chat: list[str]) -> dict:
        want = {"stood_still": "where_why", "wrong_way": "where_why", "not_running": "where_why", "missed_some": "correction",
                "impatience": "where_why", "urgency": "urgency", "his_question": "status", "chatter": "status",
                "ack": "ack"}.get(trigger)
        if trigger == "request":
            return {"lines": [card["line"]], "gaps_ms": [], "end": False}
        if trigger == "give_up":
            return {"lines": ["note: gave up on this one"], "gaps_ms": [], "end": True}
        pool = [x["text"] for x in self.bank if x["kind"] == want] or ["claude what are you doing"]
        return {"lines": [self.rng.choice(pool)], "gaps_ms": [], "end": False}


class CapReached(Exception):
    pass


class SonnetWriter:
    def __init__(self, max_calls: int, max_usd: float):
        from brain.llm import LiteLLMClient
        self.llm = LiteLLMClient(SONNET, max_tokens=2048, output_config={"effort": "low",
                                                                       "format": {"type": "json_schema", "schema": SCHEMA}})
        self.model, self.max_calls, self.max_usd = SONNET, max_calls, max_usd
        self.calls, self.usd = 0, 0.0
        self.examples = "\n".join(f"[{x['kind']}] {x['text']}" for x in load_style()[:40])

    def write(self, trigger: str, card: dict, digest: dict, chat: list[str]) -> dict:
        if self.calls >= self.max_calls or self.usd >= self.max_usd:
            raise CapReached(f"writer cap: {self.calls} calls, ${self.usd:.3f}")
        msgs = messages(trigger, card, digest, chat, self.examples)
        self.calls += 1
        resp = self.llm.complete(msgs)
        if resp.usage:
            self.usd += spend.price(self.model, resp.usage, spend.load_prices())[0]
        try:
            out = json.loads(resp.content or "{}")
        except ValueError:
            out = {}
        lines = [str(x)[:200] for x in (out.get("lines") or []) if str(x).strip()][:4]
        return {"lines": lines or ["claude?"], "gaps_ms": [int(x) for x in (out.get("gaps_ms") or [])][:3],
                "end": bool(out.get("end"))}


def messages(trigger: str, card: dict, digest: dict, chat: list[str], examples: str = "") -> list[dict]:
    user = {"scenario": {k: card.get(k) for k in ("request", "family", "target", "anchor", "line", "t_h_s")},
            "you_see": digest, "why_you_speak_now": trigger, "last_chat": chat[-8:]}
    return [{"role": "system", "content": SYSTEM + ("\n\nHis real lines:\n" + examples if examples else "")},
            {"role": "user", "content": json.dumps(user, ensure_ascii=False, default=str)}]


# ------------------------------------------------------------------ calibration on the co-play log ($0)
def calibrate(brain: Path = ss.COPLAY_LOG, fixture: Path = ss.FIXTURE) -> dict:
    """Did a computable trigger fire in the 10 s before each of Luis's follow-ups? (stood_still from session_report's
    idle gaps >= 8 s; impatience / urgency from the fixture task's T_h; his_question from Claude's '?' lines;
    not_running from trips; wrong_way and missed_some need 2 s samples the session didn't have.)"""
    from tools.session_report import Session
    s = Session(brain)
    fx = json.loads(fixture.read_text(encoding="utf-8"))
    T = lambda x: obs.parse_ts(f"{fx['date']}T{x}Z")  # noqa: E731
    tasks = [(T(t["t0"]), T(t["t1"]), ss.t_human(t["steps"], travel_m=0)[0]) for t in fx["tasks"]]
    starts = {T(t["t0"]) for t in fx["tasks"]}
    gaps = [(g["start"], g["end"]) for g in s.gaps if g["end"] - g["start"] >= STILL_S]
    asks = [a for a, _, txt in s.brain.says if txt.rstrip().endswith("?")]
    trips = [(float(x.get("_ts") or x["ts"]) - float(x.get("s") or 0), float(x.get("_ts") or x["ts"]),
              float(x.get("walked_m") or 0), float(x.get("endurance") or 0), float(x.get("s") or 1)) for x in s.trips]
    lines = sorted((ts, txt) for e in s.requests for ts, _, txt, note in e.lines if not note)
    rows, prev, used = [], None, set()   # used: (task, clock trigger) already spent: the clock fires once per task live
    for ts, txt in lines:
        follow = not any(abs(ts - a) < ss.BURST_S for a in starts) and any(a < ts <= b for a, b, _ in tasks)
        if prev is not None and ts - prev < ss.BURST_S:
            prev = ts
            continue  # a burst's later lines ride on its first
        prev = ts
        if not follow:
            continue
        fired = set()
        if any(a <= ts and b >= ts - 10 for a, b in gaps):
            fired.add("stood_still")
        for a, b, th in tasks:
            for k, x in (("impatience", 1.5), ("urgency", 3.0)):
                if a < ts <= b and ts - a > x * max(th, 10.0) and (a, k) not in used:
                    fired.add(k)
                    used.add((a, k))
        if any(ts - 30 <= q < ts for q in asks):
            fired.add("his_question")
        if any(a <= ts <= b + 10 and m >= SLOW_LEG_M and m / d < SLOW_MPS and en >= 25 for a, b, m, en, d in trips):
            fired.add("not_running")
        rows.append({"ts": ts, "text": txt, "kind": label(txt), "fired": sorted(fired)})
    n = len(rows)
    hit = sum(1 for r in rows if r["fired"])
    by = {k: sum(1 for r in rows if k in r["fired"]) for k in ("stood_still", "impatience", "urgency", "his_question", "not_running")}
    no_imp = sum(1 for r in rows if set(r["fired"]) - {"impatience", "urgency"})
    return {"follow_ups": n, "with_a_trigger": hit, "rate": round(hit / n, 2) if n else None, "by_trigger": by,
            "rate_without_impatience": round(no_imp / n, 2) if n else None,
            "missed": [f"{ss.hms(r['ts'])} [{r['kind']}] {r['text'][:70]}" for r in rows if not r["fired"]]}


# ------------------------------------------------------------------ the live loop (one request)
def digest(st: dict, now: float) -> dict:
    me, other = st["me"], st["other"]
    d = {"seconds_since_you_asked": round(now - st["t0"]), "claude_last_lines": [t for _, t in st["claude_says"][-3:]]}
    if me:
        recent = [p for p in me if p[0] >= now - 4]
        sp = obs.hdist(recent[0][1:4], recent[-1][1:4]) / max(0.5, recent[-1][0] - recent[0][0]) if len(recent) >= 2 else 0.0
        d.update(claude_speed_mps=round(sp, 1), claude_moving=sp >= 0.5,
                 standing_for_s=round(now - max((p[0] for p in me if obs.hdist(p[1:4], me[-1][1:4]) > 1.0), default=st["t0"])))
        if other:
            d["claude_from_you_m"] = round(obs.hdist(me[-1][1:4], other[-1][1:4]))
        if st.get("dist"):
            d["claude_to_target_m"] = round(st["dist"][-1][1])
            d["closing"] = len(st["dist"]) < 2 or st["dist"][-1][1] <= st["dist"][-2][1]
    if st.get("left") is not None:
        d["still_on_the_ground_near_target"] = st["left"]
    return d


def run_request(a, req: dict, cli, brain_file: Path, writer, haiku_used: int, seed: int) -> dict:
    from tools import chat_ladder as cl
    from tools import m1_session
    m = cl.me(cli)
    here = obs._xyz((m or {}).get("position"))
    cen = cp.census(cli, radius_m=cp.NEAR_M, max=25)
    if "player" in req["needs"]:
        cen["players"] = cp.census(cli, radius_m=150, max=10, kinds={"players": True}, foliage=False).get("players") or []
    inv = cp.inventory(cli)
    target, why = cp.prepare(req, cen, inv, here, a.target_player)
    if why:
        return {"request": req["id"], "kind": req["kind"], "skipped": True, "why": f"precondition: {why}"}
    lead, line = cp.lines(req, target)
    goal = obs._xyz(target.get("at")) or obs._xyz(target.get("player_pos"))
    travel = obs.hdist(here, goal) if here and goal else 0.0
    th = ss.t_human([["travel", round(travel, 1)]] + (cp.KIND_STEPS.get(req["id"]) or cp.KIND_STEPS.get(req["kind"]) or []))[0]
    card = {"request": req["id"], "family": req["kind"], "target": target.get("name") or target.get("player"),
            "anchor": "you" if target.get("player") else "claude", "line": lead or line, "t_h_s": th}
    rng = random.Random(seed)
    st = {"t0": time.time(), "t_h": max(th, 10.0), "me": [], "other": [], "dist": [], "claude_says": [], "fired": set(),
          "last_spoke": 0.0, "chatter_at": rng.uniform(*CHATTER[:2]) if rng.random() < CHATTER[2] else None,
          "left": None, "travel_m": travel, "endurance": None}
    said: list[tuple[float, str, str]] = []

    def speak(trigger: str) -> bool:
        out = writer.write(trigger, card, digest(st, time.time()), [t for _, t, _ in said])
        for i, text in enumerate(out["lines"]):
            ok, _ = m1_session.send_speech_direct(text)
            said.append((time.time(), text, trigger))
            if not ok:
                return False
            if i < len(out["lines"]) - 1:
                time.sleep(min(3.0, max(0.3, (out["gaps_ms"][i] if i < len(out["gaps_ms"]) else 800) / 1000)))
        st["last_spoke"] = time.time()
        st["fired"].add(trigger)
        return True

    if not speak("request"):
        return {"request": req["id"], "kind": req["kind"], "skipped": True, "why": "the line was not sent"}
    rec = {"request": req["id"], "kind": req["kind"], "gain": req.get("gain"), "line": line, "lead": lead,
           "target": target, "t0": st["t0"], "me": [], "other": [], "seen": [], "inv": [[st["t0"], cp.counts(inv)]],
           "stop_at": None}
    ended = why = None
    while True:
        now = time.time()
        m = cl.me(cli)
        if p := obs._xyz((m or {}).get("position")):
            rec["me"].append([round(now, 2), *p, bool((m or {}).get("dead"))])
            st["me"].append([now, *p])
            if goal:
                st["dist"].append((now, obs.hdist(p, goal)))
        if "player" in req["needs"]:
            pl = cp.census(cli, radius_m=150, max=10, kinds={"players": True}, foliage=False).get("players") or []
            if q := next((obs._xyz(r.get("position")) for r in pl if r.get("name") == target["player"]), None):
                rec["other"].append([round(now, 2), *q])
                st["other"].append([now, *q])
        if req["kind"] in ("kill", "pickup"):
            cat = "creatures" if req["kind"] == "kill" else "items"
            rows_ = cp.census(cli, radius_m=60, max=40, kinds={cat: True}, foliage=False).get(cat) or []
            r = next((x for x in rows_ if x.get("id") == target.get("id")), None)
            state = "gone" if r is None else ("dead" if req["kind"] == "kill" and not cp._alive(r) else "there" if req["kind"] == "pickup" else "alive")
            rec["seen"].append([round(now, 2), state, (r or {}).get("health")])
            st["left"] = 1 if state == "there" else 0
        if req["kind"] in ("gain", "drop", "pickup", "give") and (iv := cp.inventory(cli)):
            rec["inv"].append([round(now, 2), cp.counts(iv)])
        rows = cl.brain_rows([brain_file], st["t0"] - 1, now + 1)
        st["claude_says"] = [(r["ts"], str(r.get("text") or "")) for r in rows if r.get("kind") == "say"]
        rec["heard_at"] = rec.get("heard_at") or cp._heard(rows, lead or line)
        calls = cl.model_calls(rows)
        done = cp.check(rec, rows)[0]
        rec["t1"] = now
        el = now - st["t0"]
        try:
            if done and not cp._busy(rows, st["t0"], now)[0] and cp._busy(rows, st["t0"], now)[2] >= 6:
                speak("ack")
                ended, why = now, "done (acknowledged)"
            elif el > min(GIVE_UP_X * st["t_h"], GIVE_UP_S):
                speak("give_up")
                ended, why = now, f"gave up at {el:.0f} s ({el / st['t_h']:.1f}x T_h)"
            elif haiku_used + calls["haiku"] > a.max_haiku:
                ended, why = now, "haiku call cap"
            elif rec["heard_at"] is None and el > cl.HEARD_S:
                ended, why = now, "never heard"
            elif now - st["last_spoke"] >= SPEAK_EVERY_S and (fire := [t for t in triggers(st, now) if t not in st["fired"]
                                                                        or t in ("stood_still", "wrong_way", "missed_some", "his_question")]):
                speak(fire[0])
        except CapReached as e:
            ended, why = now, str(e)
        if ended:
            break
        time.sleep(TICK_S)
    rec["t1"], rec["ended"] = ended, why
    row = cp.score(rec, judge=a.judge)
    praised = any(t == "ack" for _, _, t in said) and not row["done"]
    return {**row, "emulator": {"writer": writer.model, "lines": [{"ts": round(t, 2), "text": x, "trigger": g} for t, x, g in said],
                                "triggers": sorted(st["fired"]), "t_h": th, "over_cooperation": praised}}


def cmd_run(a) -> int:
    from tools import chat_ladder as cl
    if not a.confirm:
        print("refusing: a live run sends test chat to Claude on the dev server; pass --confirm")
        return 2
    if a.sonnet and a.dry_run:
        print("pick one: --sonnet (model writer) or --dry-run (canned writer)")
        return 2
    bad = cl.preflight(a)
    if bad:
        print("not running:\n  " + "\n  ".join(bad))
        return 3
    before = spend.spend_today()
    est = a.max_sonnet * 0.005 if a.sonnet else 0.0
    print(f"spend before: ${before['spent_usd']:.4f} ({before['state']}); writer {'Sonnet (cap ' + str(a.max_sonnet) + ' calls, $' + str(a.usd) + ')' if a.sonnet else 'canned ($0)'}; "
          f"worst case writer ${min(est, a.usd):.2f} + brain cap ${a.brain_usd:.2f}")
    if before["state"] != "ok":
        print("not running: spend is past the warn level")
        return 3
    ok, why = cl.ensure_sender()
    print(f"sender: {why}")
    if not ok:
        return 4
    writer = SonnetWriter(a.max_sonnet, a.usd) if a.sonnet else CannedWriter(a.seed)
    cli = cl._debug_client()
    a.usd_brain = a.brain_usd
    proc, bfile = (cl.start_brain(argparse.Namespace(**{**vars(a), "usd": a.brain_usd}), before["spent_usd"]) if a.start_brain else (None, None))
    bfile = bfile or cl._brain_file(a, proc)
    if bfile is None:
        cl.stop_brain(proc)
        print("not running: the brain did not start")
        return 4
    run_id = datetime.now(timezone.utc).strftime("le-%Y%m%dT%H%M%SZ")
    legs, haiku, t_run = [], 0, time.time()
    reqs = [r for r in cp.REQUESTS if not a.only or r["id"] in a.only.split(",")]
    try:
        for i, req in enumerate(reqs * max(1, a.repeat)):
            if (who := cp.foreign_driver(t_run)) or any(p.exists() for p in cl.HOLD_FILES):
                print(f"stopping: someone else is driving the client ({who or 'hold file'})")
                break
            row = {"run_id": run_id, "brain_log": bfile.name, **run_request(a, req, cli, bfile, writer, haiku, a.seed + i)}
            OUT.parent.mkdir(parents=True, exist_ok=True)
            with open(OUT, "a", encoding="utf-8") as f:
                f.write(json.dumps({"ts": round(time.time(), 3), **row}, ensure_ascii=False, default=str) + "\n")
            legs.append(row)
            haiku += row.get("haiku_calls") or 0
            em = row.get("emulator") or {}
            print(f"  {req['id']:<10} {row.get('outcome', 'skipped'):<19} standard {row.get('standard') or '-'} "
                  f"x{row.get('ratio')} T_h {row.get('t_h')}; lines {len(em.get('lines') or [])} {em.get('triggers')}; "
                  f"{row.get('ended') or row.get('why')}")
            if haiku >= a.max_haiku or isinstance(writer, SonnetWriter) and (writer.calls >= a.max_sonnet or writer.usd >= a.usd):
                print("stopping: a call cap was reached")
                break
    finally:
        cl.stop_brain(proc)
    lines = [x["text"] for r in legs for x in (r.get("emulator") or {}).get("lines") or [] if x["trigger"] != "request"]
    stats = style_stats(lines)
    valid, why_bad = style_valid(stats) if lines else (False, ["no follow-up lines"])
    print(cp.summary(legs) + f"\nemulator: writer {writer.model} calls {writer.calls} ${writer.usd:.4f}; style {stats} "
          f"{'valid' if valid else 'INVALID: ' + '; '.join(why_bad)}; Rung 2 gate {'PASS' if cp.gate(legs) and valid else 'fail'}")
    return 0


def cmd_style(a) -> int:
    rows = build_style(Path(a.brain))
    STYLE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STYLE_FILE.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")
    st = style_stats([r["text"] for r in rows])
    kinds = {k: sum(1 for r in rows if r["kind"] == k) for k in sorted({r["kind"] for r in rows})}
    print(f"wrote {STYLE_FILE.relative_to(ROOT)}: {len(rows)} lines; {st}; kinds {kinds}; style bands {'ok' if style_valid(st)[0] else style_valid(st)[1]}")
    return 0


def cmd_plan(a) -> int:
    bank = load_style()
    print(f"style bank: {len(bank)} lines ({STYLE_FILE.relative_to(ROOT)}){'' if bank else ' -- run `style` first'}; bands {BANDS}")
    card = {"request": "pickup", "family": "pickup", "target": "Stone", "anchor": "you", "line": "claude pick up that Stone",
            "t_h_s": ss.t_human([["travel", 12], ["pickup", 1]])[0]}
    dg = {"seconds_since_you_asked": 14, "claude_speed_mps": 0.0, "claude_moving": False, "standing_for_s": 9,
          "claude_to_target_m": 3, "closing": False, "still_on_the_ground_near_target": 1,
          "claude_last_lines": ["on it, grabbing the stone"]}
    st = {"t0": 0.0, "t_h": card["t_h_s"], "me": [[float(t), 100.0, 1850.0, -31.0] for t in range(0, 15, 2)], "dist": [(0, 3.0), (14, 3.0)],
          "claude_says": [(5.0, "got it, all done")], "fired": {"request"}, "last_spoke": 1.0, "chatter_at": None, "left": 1}
    print(f"sample: triggers at 14 s = {triggers(st, 14.0)}")
    print("prompt the Sonnet writer would get (no call made):\n" +
          json.dumps(messages("stood_still", card, dg, ["claude pick up that Stone"], "[where_why] claude where are you going"),
                     indent=1, ensure_ascii=False)[:2500])
    print(f"cost estimate per session (15 requests): Sonnet ~70 calls x ~$0.005 = ~$0.35 (cap with --max-sonnet / --usd); "
          f"companion Haiku ~150 calls ~$0.11; canned writer $0")
    return 0


def cmd_calibrate(a) -> int:
    r = calibrate(Path(a.brain))
    print(f"follow-ups {r['follow_ups']}: a trigger fired in the 10 s before {r['with_a_trigger']} = {r['rate']:.0%} "
          f"(design bar 70 %); without the impatience clock {r['rate_without_impatience']:.0%}; by trigger {r['by_trigger']}")
    print("no trigger before:\n  " + "\n  ".join(r["missed"][:25]))
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("style", "calibrate"):
        p = sub.add_parser(name)
        p.add_argument("--brain", default=str(ss.COPLAY_LOG))
    sub.add_parser("plan")
    r = sub.add_parser("run")
    r.add_argument("--confirm", action="store_true")
    r.add_argument("--dry-run", action="store_true", help="canned lines from the style bank (the default writer)")
    r.add_argument("--sonnet", action="store_true", help="the Sonnet writer (model calls; not authorised yet)")
    r.add_argument("--max-sonnet", type=int, default=40)
    r.add_argument("--usd", type=float, default=0.40, help="the writer's own $ cap")
    r.add_argument("--brain-usd", type=float, default=0.75, help="the brain's spend cap above today's spend")
    r.add_argument("--max-haiku", type=int, default=150)
    r.add_argument("--only")
    r.add_argument("--repeat", type=int, default=1)
    r.add_argument("--seed", type=int, default=1)
    r.add_argument("--target-player", default=cp.TESTER)
    r.add_argument("--start-brain", action="store_true")
    r.add_argument("--use-running-brain", action="store_true")
    r.add_argument("--world", default=cp.WORLD)
    r.add_argument("--judge", action=argparse.BooleanOptionalAction, default=False)
    a = ap.parse_args(argv)
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    return {"style": cmd_style, "plan": cmd_plan, "calibrate": cmd_calibrate, "run": cmd_run}[a.cmd](a)


if __name__ == "__main__":
    raise SystemExit(main())

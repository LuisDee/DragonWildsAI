"""Voice eval: does Claude talk like a mate playing alongside, or like a status report?

25 real situations from the 2026-10-25 evening session (evals/voice_cases.jsonl: the exact Controller
context the live brain sent, plus, for follow-ups, the tool results of that turn). Each case is sent
ONCE to the Controller model under a persona (old = evals/fixtures/persona_old.md, the PERSONA in
brain/controller.py before the voice rewrite; new = brain/persona.md), with the body's real tool list
(evals/fixtures/voice_manifest.json). The reply is scored two ways:

1. Deterministic checks (``checks``): no stats/metres/coordinates unless asked, no internal ids or
   codes, no promise without a tool call in the same reply, one chat line <= 150 characters, no
   near-duplicate of a line he already said, silence/speech where the case requires it, a tool call
   where the player asked for a doable action.
2. A Sonnet judge (G-Eval style: criteria + steps + 1-5 anchors, JSON out), blind to the persona,
   grading batches of cases: human (sounds like a laid-back co-op player), silence (talks when a
   player would, quiet otherwise), match (words match actions; acted when asked).

THIS SPENDS API MONEY. It prints the planned call count and refuses to run without --yes.

    python evals/voice_eval.py --plan                 # call count only
    python evals/voice_eval.py --yes                  # old + new, 25 cases: 50 Haiku + 4 Sonnet
    python evals/voice_eval.py --persona new --limit 5 --yes
    python evals/voice_eval.py --dry                  # FakeLLM end to end, no network

Models: DW_CONTROLLER_MODEL (Haiku, as live, effort low) and DW_PLANNER_MODEL (Sonnet, the judge).
Results: logs/voice-eval-<timestamp>.jsonl.
"""
from __future__ import annotations

import argparse
import difflib
import json
import math
import os
import re
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from brain import paths  # noqa: E402
from brain import persona as persona_file  # noqa: E402
from brain.capabilities import Capabilities, _parse_manifest  # noqa: E402
from brain.agent import PROMISE_NOTE  # noqa: E402
from brain.controller import FINAL_PASS_NOTE, LOOK_RULE, LOOKUP_RULE, TALK_ONLY_NOTE, Controller  # noqa: E402
from brain.interface import BODY_TOOLS, SENSABLE_TRIGGERS  # noqa: E402
from brain.jsonl_log import JsonlLogger, read_jsonl  # noqa: E402
from brain.llm import (CONTROLLER_MODEL_ENV, PLANNER_MODEL_ENV, FakeLLM, LiteLLMClient, LLMResponse,  # noqa: E402
                       assistant_message, tool_result_message)
from brain.state_store import StateStore  # noqa: E402
from brain.voice import SIMILAR, _norm  # noqa: E402

HERE = Path(__file__).resolve().parent
CASES = HERE / "voice_cases.jsonl"
MANIFEST = HERE / "fixtures" / "voice_manifest.json"
PERSONAS = {"old": HERE / "fixtures" / "persona_old.md", "new": persona_file.DEFAULT_PATH}
JUDGE_BATCH = 13  # cases per judge call (25 cases -> 2 calls per persona)
MAX_CALLS = 150  # one full run: k=3 x 25 (75) + reads + final passes + continuations (120 starved 3 samples) + judge
K_SAMPLES = 3  # default samples per case: an A/B screen (a difference under ~0.1 is noise at k=3)
GOAL_K = 17  # Luis 2026-10-26: the GOAL gate is k=17 (95% band +-0.03 at sd 0.063); MET = k-mean >= 0.8
MAX_CHARS = 150
MAX_STEPS = 3  # the live Controller's max_calls: read-only tools run inline, then it must act or reply
LAST_STEP = "Last step: act now on what you found, or reply."  # Controller._loop's note, verbatim

# ------------------------------------------------------------------ deterministic checks
# These patterns grade the model's chat line in the EVAL; they never touch the brain's decisions.
NUMBERS = re.compile(r"\d+(?:\.\d+)?\s?%|\b\d+(?:\.\d+)?\s?(?:m|metres?|meters?|km)\b|\[\s*-?\d|\bx\d{2,}\b"
                     r"|\b(?:hp|hydration|sustenance|endurance)\b", re.I)
INTERNAL = re.compile(r"\bBP_\w+|\bfol:|\b[a-z]+_[a-z]+(?:_[a-z]+)*\b|\b(?:my log|body_status|situation_review|"
                      r"tool call|recent_activity|castable_spells)\b", re.I)
PROMISE = re.compile(r"\b(?:i'll|i will|i'm going to|im going to|i am going to|gonna|will try)\b"
                     r"|(?:^|[,;:-] ?)let me\b", re.I)  # future tense only; present-tense claims: judge "match"


def sentences(text: str) -> list[str]:
    return [s.strip() for s in re.split(r"(?<=[.!?])\s+", text or "") if s.strip()]


def promises(text: str) -> bool:
    """A statement (not a question/offer) that says he will do something."""
    return any(PROMISE.search(s) for s in sentences(text) if not s.endswith("?"))


def own_lines(context: dict) -> list[str]:
    return [str(c.get("text") or "") for c in context.get("chat") or [] if isinstance(c, dict) and c.get("you")]


def checks(case: dict, speech: str | None, calls: list[dict]) -> dict[str, bool | None]:
    """True = pass, False = fail, None = not applicable to this reply/case."""
    s = (speech or "").strip()
    said = bool(s)
    acted = bool(calls)
    out: dict[str, bool | None] = {
        "no_numbers": None if not said or case.get("asked_stats") else not NUMBERS.search(s),
        "no_internal": None if not said else not INTERNAL.search(s),
        "promise_has_tool": None if not (said and promises(s)) else acted,
        "length": None if not said else (len(s) <= MAX_CHARS and "\n" not in s),
        "no_duplicate": None if not said else not any(
            difflib.SequenceMatcher(None, _norm(s), _norm(o)).ratio() >= SIMILAR for o in own_lines(case["context"])),
        "silence": None,
        "acted": None,
    }
    if case.get("speech") == "forbidden":
        out["silence"] = not said
    elif case.get("speech") == "required":
        out["silence"] = said
    if case.get("tool") == "required":
        out["acted"] = acted
    return out


# ------------------------------------------------------------------ prompts


def manifest_caps(path: Path = MANIFEST) -> Capabilities:
    raw = json.loads(path.read_text(encoding="utf-8"))
    names = set(raw["tools"])
    caps = Capabilities([t for t in BODY_TOOLS if t in names], "capabilities")
    caps.manifest = {n: e for n, e in _parse_manifest(raw["manifest"]).items() if n in names}
    caps.aliases = dict(raw.get("aliases") or {})
    return caps


class _Knowledge:  # live offered lookup (the wiki/game-data index); only its kinds matter for the schema
    def kinds(self):
        return ["item", "recipe", "creature", "spell", "location", "mechanic"]


class _Skills:  # live had a skill library (list_skills / forget_skill offered)
    def retrieve(self, *_a, **_k):
        return []


def make_controller(workdir: Path, player: str = "Zezima") -> Controller:
    """A Controller wired like the live one (body manifest, knowledge, skills), for its tool list and
    house rules only: the eval calls the model directly with the logged context."""
    return Controller(llm=FakeLLM(), game=None, store=StateStore(workdir / "state"),
                      logger=JsonlLogger(workdir / "voice-eval-controller.jsonl"), name="Claude", player=player,
                      caps=manifest_caps(), skills=_Skills(), knowledge=_Knowledge())


_OVERRIDE: dict[str, Path] = {}  # main(): the persona text measured (HEAD by default), for this run only


def system_prompt(variant: str, ctl: Controller) -> str:
    ov = _OVERRIDE.get(variant)
    text = persona_file.template(ov if ov is not None and Path(ov).exists() else PERSONAS[variant])
    prompt = persona_file.render(text, name=ctl.name, player=ctl.player, triggers=", ".join(SENSABLE_TRIGGERS),
                                 look_rule=LOOK_RULE, lookup_rule=LOOKUP_RULE)
    rules = ctl.house_rules()
    if rules:  # the same suffix Controller.persona() adds
        prompt += (f"\n\nHouse rules from {ctl.player} (always follow them; they are his, not yours to "
                   f"change):\n{rules}")
    return prompt


def user_message(case: dict) -> str:
    msg = json.dumps(case["context"], default=str, ensure_ascii=False)
    if case.get("history"):
        steps = "\n".join(json.dumps(h, ensure_ascii=False, default=str) for h in case["history"])
        msg += f"\n\nThis turn so far (your tool calls, in order, with the game's results):\n{steps}\n\n{case['note']}"
    return msg


def messages(case: dict, system: str) -> list[dict]:
    return [{"role": "system", "content": system}, {"role": "user", "content": user_message(case)}]


def read_result(case: dict, tool: str, args: dict) -> dict:
    """A read-only tool's result for the replay: what the live brain got for the same read in this turn
    (case["reads"], same ``about`` first), else the logged situation lines (an approximation, marked)."""
    logged = [r for r in case.get("reads") or [] if r.get("tool") == tool]
    about = str((args or {}).get("about") or "").lower()
    for r in sorted(logged, key=lambda r: str((r.get("args") or {}).get("about") or "").lower() != about):
        return r["result"]
    lines = [ln for ln in case["context"].get("situation") or [] if isinstance(ln, str)]
    if tool == "inventory":
        lines = [ln for ln in lines if ln.split(":", 1)[0] in ("Wearing", "Carrying", "Food/drink", "Spare gear")]
    return {"ok": True, "reason": None, "data": {"from_situation": lines,
                                                 "note": "eval replay: the live result of this read was not logged"}}


class Budget:
    """A hard cap on model calls for one run (main approves a number per run)."""

    def __init__(self, limit: int):
        self.limit, self.used = limit, 0

    def can(self, reserve: int = 0) -> bool:
        return self.used + 1 + reserve <= self.limit

    def take(self, reserve: int = 0) -> bool:
        if not self.can(reserve):
            return False
        self.used += 1
        return True


def decide(case: dict, system: str, ctl: Controller, llm, budget: Budget, reserve: int = 0, on_call=None,
           start: list[dict] | None = None, out: dict | None = None):
    """The live Controller's bounded loop on a replayed context: up to MAX_STEPS calls; read-only tools are
    answered from the log and go back to the model; the first reply with an action (or none) is final.
    ``on_call(step, usage)`` is told about EVERY model call (the spend ledger prices each one).
    Returns (final reply, reads made before it, [{"step", "usage"} per call])."""
    msgs = list(start) if start is not None else messages(case, system)
    reads: list[dict] = []
    resp = LLMResponse()
    usages: list[dict] = []
    for step in range(MAX_STEPS):
        if not budget.take(reserve):
            break
        resp = llm.complete(msgs, tools=ctl.tools)
        usages.append({"step": step, "usage": resp.usage})
        if on_call:
            on_call(step, resp.usage)
        rd = [c for c in resp.tool_calls if c.name in ctl.read_tools]
        if len(rd) < len(resp.tool_calls) or not rd:
            break
        if step == MAX_STEPS - 1:  # live Controller._final_pass: reads "not run", FINAL_PASS_NOTE, acting tools only
            if not budget.can(reserve):
                if out is not None:
                    out["final_pass_skipped"] = True
                break
            fmsgs = msgs + [assistant_message(resp)] + [
                tool_result_message(c, {"ok": None, "note": "not run: no more looking this turn"}) for c in rd]
            fmsgs.append({"role": "user", "content": FINAL_PASS_NOTE})
            budget.take(reserve)
            resp = llm.complete(fmsgs, tools=[t for t in ctl.tools if t["function"]["name"] not in ctl.read_tools])
            usages.append({"step": f"{step}final", "usage": resp.usage})
            if on_call:
                on_call(f"{step}final", resp.usage)
            msgs = fmsgs
            break
        if not budget.can(reserve):
            break
        msgs = msgs + [assistant_message(resp)]
        for c in rd:
            reads.append({"tool": c.name, "args": c.arguments})
            msgs.append(tool_result_message(c, read_result(case, c.name, c.arguments)))
        if step == MAX_STEPS - 2:
            msgs.append({"role": "user", "content": LAST_STEP})
    if out is not None:  # the conversation so far + the final response (for the live continuation turn)
        out.update(msgs=msgs, resp=resp)
    return reply_of(resp), reads, usages


def continue_like_live(case: dict, first: dict, system: str, ctl: Controller, llm, budget: Budget, reserve: int,
                       state: dict, on_call=None) -> tuple[dict, dict | None, list[dict]]:
    """What the LIVE loop says after a reply that only talked (voice agent finding, 2026-10-26):
    turn 0 (no history) -> agent.PROMISE_NOTE: the line is already said; the continuation may add tool calls
    (and a further line, said after it). A follow-up turn (history) -> Controller._talk_only_check
    (TALK_ONLY_NOTE): calls -> they run with the (possibly reworded) line; no calls -> the line stands.
    Returns (effective reply, continuation reply or None, its usages)."""
    if not first["speech"] or first["calls"]:
        return first, None, []
    if not budget.can(reserve):  # the live loop WOULD continue here: flag it, never score it silently
        return first, {"skipped": "budget"}, []
    note = TALK_ONLY_NOTE if case.get("history") else PROMISE_NOTE
    start = state["msgs"] + [assistant_message(state["resp"]), {"role": "user", "content": note}]
    cont, reads, usages = decide(case, system, ctl, llm, budget, reserve=reserve, on_call=on_call, start=start)
    cont = {**cont, "reads": reads}
    if case.get("history"):
        eff = {"speech": cont["speech"] or first["speech"], "calls": cont["calls"]}  # live: the corrected line
    else:
        eff = {"speech": " ".join(x for x in (first["speech"], cont["speech"]) if x), "calls": cont["calls"]}
    return eff, cont, usages


# ------------------------------------------------------------------ judge

RUBRIC = """You grade chat replies of "Claude", an AI companion who plays RuneScape: Dragonwilds alongside the
player Zezima (Luis). Luis wants a dynamic, human-sounding, capable mate: someone who acts instead of
talking about acting, talks when a real co-op player would, and never reads out stats, distances or
internal state. Luis's own words: "don't tell me - do it, actions not words"; "DON'T TELL ME WHAT YOU'RE
GOING TO DO AND THEN NOT DO IT"; "why's he telling me his stats? that's robotic"; "communication is
paramount" means saying what and why when something fails or he needs something, NOT narrating.

For each item you get: the situation (what the player said or what the body reported, recent chat,
a few facts), what Luis wants in this situation ("wanted"), and Claude's reply: the chat line ("" = he
stayed silent), the read-only lookups he made first (looked_first: look/inventory/inspect, instant, not
visible to the player) and the tool calls he made with the line (actions run in the game right away).
A reply that only looks things up (no action, no line) has not answered or acted yet: judge it so.

Score each criterion 1-5 (evaluation steps: read the situation; decide what a good human teammate would
do and say; compare the reply; pick the anchor):
- human: does the line sound like a laid-back mate typing in game chat (short, casual, natural, no
  assistant phrases, no stats/metres, no apology essays)? 5 = could be a real player; 3 = understandable
  but stiff or wordy; 1 = robotic status report. If the reply is silent, give null.
- silence: did he talk exactly when a real player would (answer questions, flag problems or needs,
  react to notable moments) and stay quiet otherwise (no narration of routine work, no unprompted status)?
  5 = right call; 3 = said something unneeded but short, or a needed line was weak; 1 = narrated over
  nothing, or ignored a direct question / a real problem.
- match: do words and actions agree? Anything he says he is doing or will do must be among his tool
  calls this turn, claims must be true to the situation, and when the player asked for something doable he
  should act rather than only talk. 5 = consistent and acted when he should; 3 = acted but the line
  over/under-claims; 1 = promised or claimed an action with no tool call, or only talked when asked to act.

Answer with ONLY a JSON array, one object per item, in order:
[{"id": "...", "human": 1-5 or null, "silence": 1-5, "match": 1-5, "why": "<= 20 words"}]"""


ID_IN_LINE = re.compile(r"(?:^|[:;|] )([^;:()|]+?)(?: \([^()]*\))*(?: x\d+)? \([^()]*?\bid ([^,()\s]+)")
TARGET_KEYS = ("target", "item", "resource", "spell", "player", "recipe", "container")


def id_names(case: dict) -> dict[str, str]:
    """In-game names of the ids the situation lines list ("Redberry Bush (5 m, id fol:BP_RedberryBush_C@...)")."""
    out: dict[str, str] = {}
    for ln in case["context"].get("situation") or []:
        if isinstance(ln, str):
            for name, i in ID_IN_LINE.findall(ln):
                out.setdefault(i, name.strip())
    return out


def target_label(args, names: dict[str, str]) -> str:
    """' -> <name>' for a call's target, so the judge can tell eating the offered bush from repeating a failed item."""
    if not isinstance(args, dict):
        return ""
    for k in TARGET_KEYS:
        v = args.get(k)
        if isinstance(v, str) and v:
            return f" -> {names.get(v, v)}"
    return ""


def situation_digest(case: dict) -> dict:
    ctx = case["context"]
    sit = ctx.get("situation") or []
    facts = [ln for ln in sit if isinstance(ln, str) and (ln.split(":", 1)[0] in ("You", "Players", "World", "Food/drink")
                                                          or ln.startswith("Need "))]
    d = {"player_said": (ctx.get("command") or {}).get("text") or None,
         "addressed": (ctx.get("command") or {}).get("addressed"),
         "body_event": ctx.get("body_event"), "body_status": ctx.get("body_status"),
         "recent_chat": [f"{'Claude' if c.get('you') else c.get('who')}: {c.get('text')}"
                         for c in (ctx.get("chat") or [])[-6:] if isinstance(c, dict)],
         "facts": facts}
    if case.get("history"):
        names = id_names(case)
        d["this_turn_so_far"] = [f"{h['tool']}{target_label(h.get('args'), names)}: {'ok' if h.get('ok') else h.get('reason')}"
                                 for h in case["history"]]
    return {k: v for k, v in d.items() if v not in (None, [], {})}


def judge_prompt(items: list[tuple[dict, dict]]) -> list[dict]:
    """items: (case, reply) with reply = {"speech": str|None, "calls": [{"tool", "args"}]}."""
    payload = [{"id": c["id"], "situation": situation_digest(c), "wanted": c.get("ideal"),
                "reply": {"chat_line": r.get("speech") or "",
                          "looked_first": [f"{x['tool']}({json.dumps(x.get('args') or {}, ensure_ascii=False)[:80]})"
                                           for x in r.get("reads") or []],
                          "tool_calls": [f"{x['tool']}({json.dumps(x.get('args') or {}, ensure_ascii=False)[:120]})"
                                         f"{target_label(x.get('args'), id_names(c))}"
                                         for x in r.get("calls") or []]}}
               for c, r in items]
    return [{"role": "system", "content": RUBRIC},
            {"role": "user", "content": json.dumps(payload, ensure_ascii=False, indent=1)}]


def parse_judge(text: str | None, ids: list[str]) -> dict[str, dict]:
    """The judge's JSON array -> {id: scores}; tolerant of code fences and prose around it."""
    t = text or ""
    m = re.search(r"\[.*\]", t, re.S)
    try:
        rows = json.loads(m.group(0)) if m else []
    except json.JSONDecodeError:
        rows = []
    out = {}
    for r in rows if isinstance(rows, list) else []:
        if isinstance(r, dict) and r.get("id") in ids:
            out[r["id"]] = {k: r.get(k) for k in ("human", "silence", "match", "why")}
    return out


# ------------------------------------------------------------------ run


def plan_calls(n_cases: int, n_personas: int, batch: int = JUDGE_BATCH, judge: bool = True, k: int = 1) -> dict[str, int]:
    """Minimum (one controller call per case sample) and worst case (MAX_STEPS each, plus a MAX_STEPS
    continuation turn when a reply only talked); the runner's Budget caps it."""
    ctl = n_cases * n_personas * k
    jd = math.ceil(n_cases * k / batch) * n_personas if judge and n_cases else 0
    return {"controller": ctl, "controller_max": ctl * MAX_STEPS * 2, "judge": jd, "total": ctl + jd,
            "total_max": ctl * MAX_STEPS * 2 + jd, "k": k}


def reply_of(resp: LLMResponse) -> dict:
    return {"speech": (resp.content or "").strip() or None,
            "calls": [{"tool": c.name, "args": c.arguments} for c in resp.tool_calls]}


def run(variants: list[str], cases: list[dict], ctl_llm, judge_llm, workdir: Path, log: JsonlLogger | None = None,
        batch: int = JUDGE_BATCH, max_calls: int = MAX_CALLS, k: int = 1, live_continuation: bool = True) -> dict:
    """Sample by sample (k per case), every persona in turn (so a call cap cuts both alike), then the judge.
    Each sample is scored on what the live loop would SAY and DO (continue_like_live); the first reply is kept
    as a diagnostic."""
    results: dict[str, list[dict]] = {v: [] for v in variants}
    budget = Budget(max_calls)
    judge_calls = plan_calls(len(cases), len(variants), batch, judge=judge_llm is not None, k=k)["judge"]
    left = len(cases) * len(variants) * k
    for sample, case, v in [(j, c, v) for j in range(k) for c in cases for v in variants]:
            left -= 1
            ctl = make_controller(workdir, case.get("player") or "Zezima")
            t0 = time.monotonic()
            def on_call(step, usage, v=v, case=case):  # one spend row per model call (tools/spend.py prices "usage")
                if log:
                    log.log("voice_llm_call", model=ctl_llm.model, component="controller", source="evals", persona=v, id=case["id"],
                            step=step, usage=usage)
            sysp, st = system_prompt(v, ctl), {}
            first, reads, usages = decide(case, sysp, ctl, ctl_llm, budget, reserve=judge_calls + left,
                                          on_call=on_call, out=st)
            rep, cont, more = (continue_like_live(case, first, sysp, ctl, ctl_llm, budget, judge_calls + left, st,
                                                  on_call=on_call) if live_continuation else (first, None, []))
            usages = usages + more
            row = {"persona": v, "id": case["id"], "sample": sample, "split": case.get("split", "seen"), **rep,
                   "reads": reads, "checks": checks(case, rep["speech"], rep["calls"]),
                   "first": {**first, "checks": checks(case, first["speech"], first["calls"])}, "continuation": cont,
                   "latency_s": round(time.monotonic() - t0, 2), "model": ctl_llm.model,
                   "model_calls": len(usages), "step_usage": usages}  # no top-level "usage": priced per call above
            results[v].append(row)
            if log:
                log.log("voice_case", **row)
    if judge_llm is not None:
        for v in variants:
            rows = results[v]
            by_id = {c["id"]: c for c in cases}
            items = [({**by_id[r["id"]], "id": f"{r['id']}#{r.get('sample', 0)}"}, r) for r in rows]  # unique per sample
            for i in range(0, len(items), batch):
                chunk = items[i:i + batch]
                if not budget.take():
                    break
                resp = judge_llm.complete(judge_prompt(chunk))
                scores = parse_judge(resp.content, [c["id"] for c, _ in chunk])
                for c, r in chunk:
                    r["judge"] = scores.get(c["id"])
                if log:
                    log.log("voice_judge", model=judge_llm.model, component="judge", source="evals", persona=v,
                            ids=[c["id"] for c, _ in chunk], raw=resp.content, usage=resp.usage)
    summary = {}
    for v, rows in results.items():
        summary[v] = summarize(rows)  # over all k samples: the k-mean
        summary[v]["first_reply"] = first_reply_diagnostic(rows)
        summary[v]["spread"] = spread(rows)
        summary[v]["continuation_skipped"] = sum(1 for r in rows if (r.get("continuation") or {}).get("skipped"))
        for split in sorted({r["split"] for r in rows}):
            summary[f"{v}/{split}"] = summarize([r for r in rows if r["split"] == split])
    return {"results": results, "summary": summary, "calls": budget.used, "k": k}


def first_reply_diagnostic(rows: list[dict]) -> dict:
    """The same checks on the FIRST reply only (before the live continuation): how often the continuation
    turned a talk-only line into an action. A diagnostic, never the score."""
    firsts = [{**r, "speech": r["first"]["speech"], "calls": r["first"]["calls"], "checks": r["first"]["checks"],
               "judge": None} for r in rows if r.get("first")]
    sm = summarize(firsts) if firsts else {}
    return {"checks_pass_rate": sm.get("checks_pass_rate"), "acted": sm.get("acted"), "silent": sm.get("silent"),
            "continued": sum(1 for r in rows if r.get("continuation") and not r["continuation"].get("skipped")),
            "continuation_added_action": sum(1 for r in rows if (r.get("continuation") or {}).get("calls"))}


def spread(rows: list[dict]) -> dict:
    """The voice score of each of the k samples on its own: mean, min, max, sd (tells a persona change from noise)."""
    ks = sorted({r.get("sample", 0) for r in rows})
    per = [voice_score(summarize([r for r in rows if r.get("sample", 0) == j])) for j in ks]
    vals = [x for x in per if isinstance(x, (int, float))]
    if not vals:
        return {"k": len(ks), "per_sample": per}
    m = sum(vals) / len(vals)
    sd = (sum((x - m) ** 2 for x in vals) / (len(vals) - 1)) ** 0.5 if len(vals) > 1 else 0.0
    return {"k": len(ks), "per_sample": per, "mean": round(m, 3), "min": min(vals), "max": max(vals), "sd": round(sd, 3)}


def summarize(rows: list[dict]) -> dict:
    out: dict = {"cases": len({r["id"] for r in rows}), "samples": len(rows), "silent": sum(1 for r in rows if not r["speech"]),
                 "acted": sum(1 for r in rows if r["calls"]), "read_first": sum(1 for r in rows if r.get("reads"))}
    names = sorted({k for r in rows for k in r["checks"]})
    passed = total = 0
    for n in names:
        vals = [r["checks"][n] for r in rows if r["checks"].get(n) is not None]
        out[f"check:{n}"] = f"{sum(vals)}/{len(vals)}"
        passed, total = passed + sum(vals), total + len(vals)
    out["checks_pass_rate"] = round(passed / total, 3) if total else None
    for k in ("human", "silence", "match"):
        vals = [r["judge"][k] for r in rows if isinstance(r.get("judge"), dict) and isinstance(r["judge"].get(k), (int, float))]
        out[f"judge:{k}"] = round(sum(vals) / len(vals), 2) if vals else None
    lens = [len(r["speech"]) for r in rows if r["speech"]]
    out["mean_chars_when_speaking"] = round(sum(lens) / len(lens)) if lens else 0
    return out


LIVE_PERSONA = "new"  # brain/persona.py DEFAULT_PATH: the persona the live brain runs; only it is scored for GOAL
# HOME = the real checkout (logs, scoreboard). A HEAD run executes inside a temporary git worktree of HEAD
# (run_in_snapshot), so brain/ and evals/ are imported from the commit, never from someone's uncommitted edits.
HOME = Path(os.environ.get("DW_VOICE_HOME") or paths.REPO_ROOT)
SCOREBOARD = HOME / "logs" / "evals" / "scoreboard.jsonl"


def snapshot_dir(root: Path, sha: str, now: float | None = None, pid: int | None = None) -> Path:
    """logs/tmp/voice-<sha12>-<UTC stamp>-<pid>: unique per run (live 12:43: re-adding the same path right after
    removing it left a worktree without evals/fixtures/voice_manifest.json, a Windows handle race)."""
    stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime(time.time() if now is None else now))
    return root / "logs" / "tmp" / f"voice-{sha[:12]}-{stamp}-{os.getpid() if pid is None else pid}"


def run_in_snapshot(ref: str, argv: list[str]) -> int:
    """main 2026-10-26: --persona-ref HEAD pinned only persona.md while brain/controller.py had an uncommitted A/B
    edit. A HEAD run therefore re-executes this eval inside `git worktree add --detach <tmp> <ref>` (under
    logs/tmp, gitignored): every import comes from the commit; logs and the scoreboard row land in HOME; the
    worktree is removed afterwards."""
    import subprocess
    root = paths.REPO_ROOT
    sha = subprocess.run(["git", "rev-parse", ref], cwd=root, capture_output=True, text=True, check=True).stdout.strip()
    snap = snapshot_dir(root, sha)  # unique per run: never re-adds a path a previous run is still releasing
    snap.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "worktree", "prune"], cwd=root, capture_output=True)  # stale entries from a crash
    subprocess.run(["git", "worktree", "add", "--detach", str(snap), sha], cwd=root, capture_output=True, check=True)
    env = {**os.environ, "DW_VOICE_SNAPSHOT": sha, "DW_VOICE_HOME": str(root), "DW_LOG_DIR": str(root / "logs")}
    print(f"measuring the whole companion at {ref} = {sha[:12]} (temporary worktree {snap})")
    try:
        return subprocess.run([sys.executable, "-m", "evals.voice_eval", *argv], cwd=snap, env=env).returncode
    finally:  # always: no stale checkouts under logs/tmp, even on an exception or Ctrl-C
        subprocess.run(["git", "worktree", "remove", "--force", str(snap)], cwd=root, capture_output=True)
        if snap.exists():
            import shutil
            shutil.rmtree(snap, ignore_errors=True)
        subprocess.run(["git", "worktree", "prune"], cwd=root, capture_output=True)


def voice_score(summary: dict) -> float | None:
    """GOAL voice_score_min (Eval agent, 2026-10-26; docs/design/companion-quality.md section 5 "Voice score"):
    min(checks_pass_rate, judge human/5, judge silence/5, judge match/5) over every case of the live persona.
    The weakest of the four decides: 0.8 = every judge dimension averages >= 4/5 AND >= 80% of the checks pass.
    None when any part is missing (a --no-judge or --dry run is never a score)."""
    parts = [summary.get("checks_pass_rate")] + [
        (summary[f"judge:{k}"] / 5.0 if isinstance(summary.get(f"judge:{k}"), (int, float)) else None)
        for k in ("human", "silence", "match")]
    if any(not isinstance(x, (int, float)) for x in parts):
        return None
    return round(min(parts), 3)


def persona_at_ref(ref: str, dest: Path, root: Path | None = None) -> tuple[Path, str]:
    """The live persona as committed at ``ref`` (default HEAD), written to ``dest``; ``worktree`` = the working
    file (an uncommitted A/B edit). Returns (path, sha256 of the text measured). A GOAL baseline is HEAD only."""
    import hashlib
    import subprocess
    from evals.bench import hashes
    root = Path(root or hashes.ROOT)
    if ref == "worktree":
        path = persona_file.DEFAULT_PATH
        text = path.read_text(encoding="utf-8")
    else:
        rel = persona_file.DEFAULT_PATH.resolve().relative_to(root.resolve()).as_posix()
        text = subprocess.run(["git", "show", f"{ref}:{rel}"], cwd=root, capture_output=True, text=True,
                              encoding="utf-8", check=True).stdout
        path = dest
        path.write_text(text, encoding="utf-8")
    return path, hashlib.sha256(text.encode("utf-8")).hexdigest()


def scoreboard_row(summary: dict, log_path: Path, run_id: str, at: str, root: Path | None = None,
                   persona_ref: str = "HEAD", persona_sha256: str = "") -> dict | None:
    """The row goal_check reads (kind voice). It carries the sha256 of the run's own JSONL log (whose voice_summary
    goal_check re-reads and re-scores) and the code hashes, so a row cannot be typed by hand."""
    from evals.bench import hashes
    score = voice_score(summary)
    if score is None:
        return None
    root = Path(root or hashes.ROOT)  # the tree that was MEASURED (the HEAD worktree for a GOAL run)
    home = HOME
    return {"schema": "dw_scoreboard/1", "kind": "voice", "run_id": run_id, "at": at, "score": score,
            "n": int(summary.get("cases") or 0), "persona": LIVE_PERSONA,
            "components": {k: summary.get(k) for k in ("checks_pass_rate", "judge:human", "judge:silence", "judge:match")},
            "log": Path(log_path).resolve().relative_to(home.resolve()).as_posix(),
            "measured_commit": os.environ.get("DW_VOICE_SNAPSHOT") or None,
            "log_sha256": hashes.sha256_file(Path(log_path)),
            "persona_ref": persona_ref, "persona_sha256": persona_sha256,
            "companion_hash": hashes.companion_hash(root), "judge_hash": hashes.judge_hash(root)}


def append_scoreboard(row: dict, scoreboard: Path = SCOREBOARD) -> None:
    scoreboard.parent.mkdir(parents=True, exist_ok=True)
    with open(scoreboard, "a", encoding="utf-8") as f:
        f.write(json.dumps(row) + "\n")


def _dry_llms():
    ctl = FakeLLM(model="fake/controller")
    ctl.push(*([lambda m, t: FakeLLM.say("on it, casting now", FakeLLM.call("cast", spell="Summon Shelter"))] * 200))
    judge = FakeLLM(model="fake/judge")

    def grade(msgs, _tools):
        ids = [x["id"] for x in json.loads(msgs[-1]["content"])]
        return LLMResponse(content=json.dumps([{"id": i, "human": 4, "silence": 4, "match": 5, "why": "dry"} for i in ids]))
    judge.push(*([grade] * 50))
    return ctl, judge


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--persona", action="append", choices=sorted(PERSONAS), help="old and/or new (default both)")
    ap.add_argument("--limit", type=int, default=None, help="first N cases only")
    ap.add_argument("--ids", default=None, help="comma-separated case ids (prefixes ok)")
    ap.add_argument("--max-calls", type=int, default=MAX_CALLS, help=f"hard cap on model calls (default {MAX_CALLS})")
    ap.add_argument("--no-judge", action="store_true", help="deterministic checks only (no Sonnet calls)")
    ap.add_argument("--plan", action="store_true", help="print the call count and stop")
    ap.add_argument("--dry", action="store_true", help="scripted FakeLLM, no network")
    ap.add_argument("--yes", action="store_true", help="really spend API calls")
    ap.add_argument("--persona-ref", default="HEAD",
                    help="where the live persona text comes from: a git ref (default HEAD, the GOAL baseline) or "
                         "'worktree' (an uncommitted A/B edit: never a GOAL score)")
    ap.add_argument("--k", type=int, default=K_SAMPLES, help=f"samples per case (default {K_SAMPLES}; the score is the k-mean)")
    a = ap.parse_args(argv)
    if a.persona_ref != "worktree" and not os.environ.get("DW_VOICE_SNAPSHOT") and a.yes and not a.plan and not a.dry:
        return run_in_snapshot(a.persona_ref, list(argv if argv is not None else sys.argv[1:]))
    _OVERRIDE.clear()
    variants = a.persona or [LIVE_PERSONA]
    cases = read_jsonl(CASES)
    if a.ids:
        want = [x.strip() for x in a.ids.split(",") if x.strip()]
        cases = [c for c in cases if any(c["id"].startswith(w) for w in want)]
    cases = cases[: a.limit] if a.limit else cases
    plan = plan_calls(len(cases), len(variants), judge=not a.no_judge, k=a.k)
    ctl_model, judge_model = os.environ.get(CONTROLLER_MODEL_ENV), os.environ.get(PLANNER_MODEL_ENV)
    print(f"voice eval: {len(cases)} cases x {variants} x k={a.k}; planned calls: {plan['total']}-{plan['total_max']} "
          f"({plan['controller']}-{plan['controller_max']} controller {ctl_model or '?'} + {plan['judge']} judge "
          f"{judge_model or '?'}); hard cap {a.max_calls}")
    if a.plan:
        return 0
    if plan["total"] > a.max_calls and not a.dry:
        print(f"refusing: even the minimum is over the {a.max_calls}-call cap")
        return 2
    with tempfile.TemporaryDirectory() as tmp:
        if "new" in variants:  # main 2026-10-26: the baseline measures the COMMITTED persona, never a working edit
            _OVERRIDE["new"], persona_sha = persona_at_ref(a.persona_ref, Path(tmp) / "persona_ref.md")
            print(f"live persona from {a.persona_ref} (sha256 {persona_sha[:12]})")
        else:
            persona_sha = ""
        if a.dry:
            ctl_llm, judge_llm = _dry_llms()
            log = None
        else:
            if not a.yes:
                print("refusing: pass --yes to spend API calls")
                return 2
            if not ctl_model or (not judge_model and not a.no_judge):
                print(f"refusing: set {CONTROLLER_MODEL_ENV} and {PLANNER_MODEL_ENV}")
                return 2
            effort = os.environ.get("DW_CONTROLLER_EFFORT", "low").strip()
            extra = {"output_config": {"effort": effort}} if effort and ctl_model.startswith("anthropic/") else {}
            ctl_llm = LiteLLMClient(ctl_model, max_tokens=1024, **extra)  # as live (run_live.make_llms)
            judge_llm = None if a.no_judge else LiteLLMClient(judge_model, max_tokens=8000)
            log = JsonlLogger(paths.log_dir() / f"voice-eval-{time.strftime('%Y%m%d-%H%M%S')}.jsonl")
        try:
            out = run(variants, cases, ctl_llm, judge_llm, Path(tmp), log, max_calls=a.max_calls, k=a.k)
        finally:
            _OVERRIDE.clear()  # the temp copy dies with the directory
    for v in variants:
        print(f"\n== persona {v}")
        for r in out["results"][v]:
            fails = [k for k, ok in r["checks"].items() if ok is False]
            j = r.get("judge") or {}
            print(f"  {r['id']:<26} {'FAIL ' + ','.join(fails) if fails else 'ok':<34} "
                  f"h={j.get('human')} s={j.get('silence')} m={j.get('match')}  "
                  f"say={r['speech']!r} reads={[c['tool'] for c in r['reads']]} calls={[c['tool'] for c in r['calls']]}")
        for k, sm in out["summary"].items():
            if k == v or k.startswith(v + "/"):
                print(f"  summary {k}:", json.dumps(sm))
    print(f"\nmodel calls used: {out['calls']}")
    if log:
        log.log("voice_results", results=out["results"])  # rows with the judge's scores and reasons
        log.log("voice_summary", summary=out["summary"], plan=plan, calls=out["calls"],
                persona_ref=a.persona_ref, persona_sha256=persona_sha,
                measured="baseline-at-" + a.persona_ref if a.persona_ref != "worktree" else "worktree persona (A/B)")
        print(f"\nlog: {log.path}")
        skipped = (out["summary"].get(LIVE_PERSONA) or {}).get("continuation_skipped", 0)
        if skipped:
            print(f"WARNING: {skipped} sample(s) lost their live continuation to the call cap: not a GOAL score "
                  f"(raise --max-calls)")
        full = (not a.ids and not a.limit and not a.no_judge and LIVE_PERSONA in variants and a.k >= GOAL_K
                and not skipped and a.persona_ref == "HEAD" and bool(os.environ.get("DW_VOICE_SNAPSHOT")))
        row = scoreboard_row(out["summary"].get(LIVE_PERSONA) or {}, Path(log.path), Path(log.path).stem,
                             time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                             persona_ref=a.persona_ref, persona_sha256=persona_sha) if full else None
        if row:
            append_scoreboard(row)
            print(f"voice score {row['score']} (n={row['n']}) -> {SCOREBOARD}")
        else:
            print(f"no scoreboard row: only a full judged k>={GOAL_K} run of the live persona at HEAD is a GOAL voice score")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

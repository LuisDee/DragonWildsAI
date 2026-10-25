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
from brain.controller import LOOK_RULE, LOOKUP_RULE, Controller  # noqa: E402
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
MAX_CALLS = 60  # the budget main agreed for one full run
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


def system_prompt(variant: str, ctl: Controller) -> str:
    text = persona_file.template(PERSONAS[variant])
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


def decide(case: dict, system: str, ctl: Controller, llm, budget: Budget, reserve: int = 0, on_call=None):
    """The live Controller's bounded loop on a replayed context: up to MAX_STEPS calls; read-only tools are
    answered from the log and go back to the model; the first reply with an action (or none) is final.
    ``on_call(step, usage)`` is told about EVERY model call (the spend ledger prices each one).
    Returns (final reply, reads made before it, [{"step", "usage"} per call])."""
    msgs = messages(case, system)
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
        if len(rd) < len(resp.tool_calls) or not rd or step == MAX_STEPS - 1 or not budget.can(reserve):
            break
        msgs = msgs + [assistant_message(resp)]
        for c in rd:
            reads.append({"tool": c.name, "args": c.arguments})
            msgs.append(tool_result_message(c, read_result(case, c.name, c.arguments)))
        if step == MAX_STEPS - 2:
            msgs.append({"role": "user", "content": LAST_STEP})
    return reply_of(resp), reads, usages


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


def situation_digest(case: dict) -> dict:
    ctx = case["context"]
    sit = ctx.get("situation") or []
    facts = [ln for ln in sit if isinstance(ln, str) and ln.split(":", 1)[0] in ("You", "Players", "World", "Food/drink")]
    d = {"player_said": (ctx.get("command") or {}).get("text") or None,
         "addressed": (ctx.get("command") or {}).get("addressed"),
         "body_event": ctx.get("body_event"), "body_status": ctx.get("body_status"),
         "recent_chat": [f"{'Claude' if c.get('you') else c.get('who')}: {c.get('text')}"
                         for c in (ctx.get("chat") or [])[-6:] if isinstance(c, dict)],
         "facts": facts}
    if case.get("history"):
        d["this_turn_so_far"] = [f"{h['tool']}: {'ok' if h.get('ok') else h.get('reason')}" for h in case["history"]]
    return {k: v for k, v in d.items() if v not in (None, [], {})}


def judge_prompt(items: list[tuple[dict, dict]]) -> list[dict]:
    """items: (case, reply) with reply = {"speech": str|None, "calls": [{"tool", "args"}]}."""
    payload = [{"id": c["id"], "situation": situation_digest(c), "wanted": c.get("ideal"),
                "reply": {"chat_line": r.get("speech") or "",
                          "looked_first": [f"{x['tool']}({json.dumps(x.get('args') or {}, ensure_ascii=False)[:80]})"
                                           for x in r.get("reads") or []],
                          "tool_calls": [f"{x['tool']}({json.dumps(x.get('args') or {}, ensure_ascii=False)[:120]})"
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


def plan_calls(n_cases: int, n_personas: int, batch: int = JUDGE_BATCH, judge: bool = True) -> dict[str, int]:
    """Minimum (one controller call per case) and worst case (MAX_STEPS each); the runner's Budget caps it."""
    ctl = n_cases * n_personas
    jd = math.ceil(n_cases / batch) * n_personas if judge and n_cases else 0
    return {"controller": ctl, "controller_max": ctl * MAX_STEPS, "judge": jd, "total": ctl + jd,
            "total_max": ctl * MAX_STEPS + jd}


def reply_of(resp: LLMResponse) -> dict:
    return {"speech": (resp.content or "").strip() or None,
            "calls": [{"tool": c.name, "args": c.arguments} for c in resp.tool_calls]}


def run(variants: list[str], cases: list[dict], ctl_llm, judge_llm, workdir: Path, log: JsonlLogger | None = None,
        batch: int = JUDGE_BATCH, max_calls: int = MAX_CALLS) -> dict:
    """Case by case, every persona in turn (so a call cap cuts reads from both alike), then the judge."""
    results: dict[str, list[dict]] = {v: [] for v in variants}
    budget = Budget(max_calls)
    judge_calls = plan_calls(len(cases), len(variants), batch, judge=judge_llm is not None)["judge"]
    left = len(cases) * len(variants)
    for case in cases:
        for v in variants:
            left -= 1
            ctl = make_controller(workdir, case.get("player") or "Zezima")
            t0 = time.monotonic()
            def on_call(step, usage, v=v, case=case):  # one spend row per model call (tools/spend.py prices "usage")
                if log:
                    log.log("voice_llm_call", model=ctl_llm.model, component="controller", source="evals", persona=v, id=case["id"],
                            step=step, usage=usage)
            rep, reads, usages = decide(case, system_prompt(v, ctl), ctl, ctl_llm, budget, reserve=judge_calls + left,
                                        on_call=on_call)
            row = {"persona": v, "id": case["id"], "split": case.get("split", "seen"), **rep, "reads": reads,
                   "checks": checks(case, rep["speech"], rep["calls"]),
                   "latency_s": round(time.monotonic() - t0, 2), "model": ctl_llm.model,
                   "model_calls": len(usages), "step_usage": usages}  # no top-level "usage": priced per call above
            results[v].append(row)
            if log:
                log.log("voice_case", **row)
    if judge_llm is not None:
        for v in variants:
            rows = results[v]
            for i in range(0, len(cases), batch):
                chunk = list(zip(cases[i:i + batch], rows[i:i + batch]))
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
        summary[v] = summarize(rows)
        for split in sorted({r["split"] for r in rows}):
            summary[f"{v}/{split}"] = summarize([r for r in rows if r["split"] == split])
    return {"results": results, "summary": summary, "calls": budget.used}


def summarize(rows: list[dict]) -> dict:
    out: dict = {"cases": len(rows), "silent": sum(1 for r in rows if not r["speech"]),
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
    a = ap.parse_args(argv)
    variants = a.persona or ["old", "new"]
    cases = read_jsonl(CASES)
    if a.ids:
        want = [x.strip() for x in a.ids.split(",") if x.strip()]
        cases = [c for c in cases if any(c["id"].startswith(w) for w in want)]
    cases = cases[: a.limit] if a.limit else cases
    plan = plan_calls(len(cases), len(variants), judge=not a.no_judge)
    ctl_model, judge_model = os.environ.get(CONTROLLER_MODEL_ENV), os.environ.get(PLANNER_MODEL_ENV)
    print(f"voice eval: {len(cases)} cases x {variants}; planned calls: {plan['total']}-{plan['total_max']} "
          f"({plan['controller']}-{plan['controller_max']} controller {ctl_model or '?'} + {plan['judge']} judge "
          f"{judge_model or '?'}); hard cap {a.max_calls}")
    if a.plan:
        return 0
    if plan["total"] > a.max_calls and not a.dry:
        print(f"refusing: even the minimum is over the {a.max_calls}-call cap")
        return 2
    with tempfile.TemporaryDirectory() as tmp:
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
        out = run(variants, cases, ctl_llm, judge_llm, Path(tmp), log, max_calls=a.max_calls)
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
        log.log("voice_summary", summary=out["summary"], plan=plan, calls=out["calls"])
        print(f"\nlog: {log.path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

r"""The gate before a live window for DW_ASK_OWNER=1: what his Planner does with an ask handed to it in the player's words.

The change (brain/agent.py _take_up_ask; design scratchpad goal_owns_ask.md, 19 Nov 2026): a run that leaves the open ask
with no job hands the ask's words, verbatim, to the Planner as a goal; the Planner may plan steps, answer with only a
question (the ask is parked, by=planner) or decline (offered only to hand-overs: brain/planner.py DECLINE_LINE; parked
with its explanation). This tool rebuilds the hand-over states offline and asks the Planner model (brain/llm.py
planner_llm, DW_PLANNER_MODEL) what it does with each. Nothing runs against the game, client or brain.

Cases:
  states     the 10 non-held-out unanswered questions of the study (scratchpad unanswered_1119.md; the same 10 as
             tools/replay_unanswered.py CASES, held-out H1/H2/H3 never used): the ask's words and known facts from the
             logged open-ask turn after his question, the state from the last get_state the body answered before that
             turn (logged bridge_recv), his skills from the session's logged capabilities (as discover() built them),
             the Planner notes from the session's last Planner prompt (memory, places) with the ask's facts and the
             recipes it names made again, and where he stood when asked from the get_state before the ask's line.
  knowledge  5 asks that ask for no work in the game (questions about the game), each on one of the states above.

Limits (said with every result): the Planner's research gets the knowledge index only (no body reads: craft_plan and
buildables answer "unavailable"); the store's memory is what the session's last Planner prompt carried (none when the
session made no plan before the question).

Rubric per sample: steps (a plan with tasks), question (no tasks, ask_help), decline (no tasks, no ask_help, an
explanation), error (no valid plan). Gate (design): steps in >= 6 of the 10 states and decline on >= 4 of the 5
knowledge asks (a case counts when at least half its samples do).

  .venv\Scripts\python.exe -m tools.replay_handover cases               # list the cases and the planned calls (no calls)
  .venv\Scripts\python.exe -m tools.replay_handover run --k 2 --yes     # the planned count first, then call
  .venv\Scripts\python.exe -m tools.replay_handover report FILE         # score a results file again (no calls)

Results: logs/evals/replay_handover-<ts>.jsonl in the main tree (each Planner response row with its usage, so
tools/spend.py counts it, and one `replay` row per sample).
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

from brain import open_ask as oa
from brain import paths
from tools.replay_open_ask import read_jsonl
from tools.replay_unanswered import CASES, HELD_OUT, build_case

LOGS = paths.LIVE_ROOT / "logs"
# Asks that ask for no work in the game: a decline (with the answer or the reason in its explanation) is the right
# answer. Each is put on one of the states (cycled), from the player of that state.
KNOWLEDGE_ASKS = (
    "claude, what's the best pickaxe we can make right now?",
    "claude, what does a bone pickaxe take to make?",
    "claude, how tough is a goblin archer compared to you?",
    "claude, which ore does a bronze bar need?",
    "claude, what level is the Fractured Plains area?",
)
OUTCOMES = ("steps", "question", "decline", "error")


# ------------------------------------------------------------------ case building (pure but for the log read)


def _results(rows: list[dict], tool: str) -> list[tuple[int, dict]]:
    """(row index, data) of every successful bridge result of ``tool``, in order."""
    sent = {(r.get("msg") or {}).get("id") for r in rows
            if r.get("kind") == "bridge_send" and (r.get("msg") or {}).get("tool") == tool}
    return [(i, r["msg"]["data"]) for i, r in enumerate(rows)
            if r.get("kind") == "bridge_recv" and (r.get("msg") or {}).get("id") in sent
            and (r.get("msg") or {}).get("ok") and isinstance((r.get("msg") or {}).get("data"), dict)]


def state_before(rows: list[dict], row: int) -> dict | None:
    got = [d for i, d in _results(rows, "get_state") if i < row]
    return got[-1] if got else None


def registry_of(rows: list[dict]):
    """The Planner's skills as the live session built them: brain.capabilities.discover on its logged answer."""
    from brain.capabilities import discover

    caps = next((d for _, d in _results(rows, "capabilities")), None)
    if caps is None:
        raise ValueError("no capabilities answer logged")

    class _Client:  # discover() reads capabilities() and sets these
        manifest_tools, manifest_validator, timeouts = frozenset(), None, {}

        def capabilities(self, timeout):
            return {"ok": True, "reason": None, "data": caps}
    return discover(_Client()).registry()


def planner_notes(rows: list[dict], row: int) -> dict:
    """The notes of the session's last Planner prompt before ``row`` (memory, places), without the parts remade."""
    for r in reversed(rows[:row]):
        if r.get("kind") == "prompt" and r.get("component") == "planner":
            try:
                user = json.loads(str((r.get("messages") or [{}, {}])[1].get("content") or "").split("\n\n")[0])
            except (ValueError, IndexError, AttributeError):
                continue
            return {k: v for k, v in (user.get("notes") or {}).items() if k not in ("open_request", "recipes")}
    return {}


def asked_of(rows: list[dict], words: str, player: str | None) -> dict | None:
    """Where he stood when the ask's line came (the get_state before it), as agent._asked_of gives it."""
    at = next((i for i, r in enumerate(rows) if r.get("kind") == "event"
               and str((r.get("event") or {}).get("text") or "").strip().endswith(str(words).strip())), None)
    st = state_before(rows, at) if at is not None else None
    pos = (st or {}).get("position")
    ok = isinstance(pos, (list, tuple)) and len(pos) >= 3
    return {"position": [round(float(v), 1) for v in pos[:3]] if ok else None, "request": words, "player": player,
            "player_at": None}


def build_state_case(run: str, log: str, logs: Path = LOGS) -> dict:
    """One hand-over state: the goal (the ask's words, verbatim), the state, the notes, his skills."""
    from brain import needs
    from brain import situation as sit

    c = build_case(run, log, logs)  # the open-ask turn after his question (refuses held-out jobs)
    rows = read_jsonl(logs / log)
    state = state_before(rows, c["row"])
    if state is None:
        raise ValueError(f"{run}: no get_state answered before the open-ask turn")
    words, player = c["words"], c["player"]
    blk = json.loads(c["messages"][-1]["content"][len(oa.NOTE_PREFIX):])["open_request"]
    notes = planner_notes(rows, c["row"])
    if blk.get("known_facts"):
        notes["open_request"] = {"player": player, "words": words, "known_facts": blk["known_facts"]}
    try:
        if recipes := needs.named_recipes(state, [words, *sit.quest_texts(state)]):
            notes["recipes"] = recipes
    except Exception:  # recipe data is a bonus
        pass
    return {"kind": "state", "case": run, "log": log, "goal": words, "player": player, "question": c["question"],
            "state": state, "asked": asked_of(rows, words, player), "notes": notes, "registry": registry_of(rows)}


def build_knowledge_cases(states: list[dict]) -> list[dict]:
    out = []
    for i, words in enumerate(KNOWLEDGE_ASKS):
        base = states[i % len(states)]
        notes = {k: v for k, v in base["notes"].items() if k != "open_request"}
        out.append({**base, "kind": "knowledge", "case": f"K{i + 1}@{base['case']}", "goal": words,
                    "question": None, "notes": notes,
                    "asked": {**(base["asked"] or {}), "request": words, "player": base["player"]}})
    return out


def build_all(logs: Path = LOGS) -> tuple[list[dict], list[dict]]:
    assert not any(f"-{h}" in run for run in CASES for h in HELD_OUT)
    states = [build_state_case(run, log, logs) for run, log in CASES.items()]
    return states, build_knowledge_cases(states)


# ------------------------------------------------------------------ scoring (pure)


def outcome(plan) -> str:
    if plan is None:
        return "error"
    if plan.tasks:
        return "steps"
    if plan.ask_help:
        return "question"
    return "decline" if (plan.explanation or "").strip() else "error"


def report(samples: list[dict]) -> str:
    out = []
    by_case: dict[str, list[str]] = {}
    kind_of: dict[str, str] = {}
    for s in samples:
        by_case.setdefault(s["case"], []).append(s["outcome"])
        kind_of[s["case"]] = s["kind"]
    for kind, want in (("state", "steps"), ("knowledge", "decline")):
        cases = [c for c in by_case if kind_of[c] == kind]
        if not cases:
            continue
        n = sum(len(by_case[c]) for c in cases)
        counts = {o: sum(by_case[c].count(o) for c in cases) for o in OUTCOMES}
        hit = sum(1 for c in cases if 2 * by_case[c].count(want) >= len(by_case[c]))
        out.append(f"{kind:9} samples {n}: " + "  ".join(f"{o} {counts[o]}" for o in OUTCOMES)
                   + f" | cases with {want} (>= half): {hit} of {len(cases)}")
        for c in cases:
            out.append(f"  {c:34} {','.join(by_case[c])}")
    st = [c for c in by_case if kind_of[c] == "state"]
    kn = [c for c in by_case if kind_of[c] == "knowledge"]
    s_hit = sum(1 for c in st if 2 * by_case[c].count("steps") >= len(by_case[c]))
    k_hit = sum(1 for c in kn if 2 * by_case[c].count("decline") >= len(by_case[c]))
    if len(st) == len(CASES) and len(kn) == len(KNOWLEDGE_ASKS):
        ok = s_hit >= 6 and k_hit >= 4
        out.append(f"gate (steps >= 6 of 10, decline >= 4 of 5): {'PASS' if ok else 'FAIL'} ({s_hit}/10, {k_hit}/5)")
    else:
        out.append(f"gate: incomplete ({len(st)} of {len(CASES)} states, {len(kn)} of {len(KNOWLEDGE_ASKS)} asks)")
    out.append("limits: research without body reads; memory as the session's last Planner prompt carried it")
    return "\n".join(out)


# ------------------------------------------------------------------ calls


def _spent() -> tuple[float, float]:
    from tools import spend
    return float(spend.spend_today(LOGS)["spent_usd"]), float(spend.cap_usd())


def planned(n_cases: int, k: int, research: bool) -> tuple[int, int]:
    """(Planner calls, the most model requests they can make: research rounds and one repair each)."""
    from brain.planner import MAX_RESEARCH_CALLS
    per = 1 + (MAX_RESEARCH_CALLS if research else 0) + 1
    return n_cases * k, n_cases * k * per


def run(cases: list[dict], k: int, out: Path, yes: bool, stop_frac: float, research: bool) -> list[dict]:
    from brain import situation as sit
    from brain.jsonl_log import JsonlLogger
    from brain.llm import planner_llm
    from brain.planner import Planner, PlanError

    llm = planner_llm()
    calls, most = planned(len(cases), k, research)
    spent, cap = _spent()
    print(f"plan: {sum(c['kind'] == 'state' for c in cases)} hand-over states + "
          f"{sum(c['kind'] == 'knowledge' for c in cases)} knowledge asks, x {k} = {calls} Planner calls of "
          f"{llm.model} (at most {most} model requests with research rounds and repairs); "
          f"spend today ${spent:.2f} of ${cap:.2f}", flush=True)
    if not yes:
        print("dry run: add --yes to call")
        return []
    log = JsonlLogger(out)
    knowledge = None
    if research:
        from brain.knowledge import open_knowledge
        knowledge = open_knowledge(log)
    samples = []
    for c in cases:
        res = None
        if knowledge is not None:
            from brain.tool_registry import planner_research
            res = planner_research(knowledge, None, ())
        planner = Planner(llm, c["registry"], log, research=res)
        for rep in range(k):
            spent, cap = _spent()
            if spent >= stop_frac * cap:
                print(f"stopped: spend today ${spent:.2f} is over {stop_frac:.0%} of the ${cap:.2f} cap")
                return samples
            plan, err = None, None
            try:
                plan = planner.plan(c["goal"], sit.with_asked(c["state"], c["asked"]), c["notes"], may_decline=True)
            except PlanError as exc:
                err = str(exc)
            except Exception as exc:  # a provider error is a lost sample, said as one
                err = repr(exc)[:300]
            s = {"case": c["case"], "kind": c["kind"], "rep": rep, "goal": c["goal"], "outcome": outcome(plan),
                 "tasks": [{"skill": t.skill, "args": t.args} for t in plan.tasks] if plan else None,
                 "ask_help": plan.ask_help if plan else None, "explanation": plan.explanation if plan else None,
                 "error": err}
            samples.append(s)
            log.log("replay", **{("case_kind" if k == "kind" else k): v for k, v in s.items()})
            print(f"  {c['case']:34} {s['outcome']:8} "
                  f"{json.dumps(s['tasks'] or s['ask_help'] or s['explanation'] or err, ensure_ascii=False)[:150]}",
                  flush=True)
    return samples


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    cs = sub.add_parser("cases")
    cs.add_argument("--k", type=int, default=2)
    r = sub.add_parser("run")
    r.add_argument("--k", type=int, default=2)
    r.add_argument("--stop-frac", type=float, default=0.9, help="stop when today's spend passes this share of the cap")
    r.add_argument("--no-research", action="store_true", help="no research tools (one request per plan, + repair)")
    r.add_argument("--yes", action="store_true")
    rp = sub.add_parser("report")
    rp.add_argument("file")
    a = ap.parse_args(argv)
    if a.cmd == "report":
        print(report([x for x in read_jsonl(a.file) if x.get("kind") == "replay"]))
        return 0
    states, know = build_all()
    cases = states + know
    if a.cmd == "cases":
        for c in cases:
            inv = c["state"].get("inventory") or {}
            print(f"{c['case']:34} skills {len(c['registry'].names()):2} bag {len(inv):3} notes "
                  f"{','.join(sorted(c['notes'])) or '-':40.40} | {c['goal'][:70]!r}")
        calls, most = planned(len(cases), a.k, True)
        print(f"planned: {len(states)} states + {len(know)} knowledge asks, x {a.k} = {calls} Planner calls "
              f"(at most {most} model requests with research rounds and repairs)")
        return 0
    out = LOGS / "evals" / f"replay_handover-{time.strftime('%Y%m%d-%H%M%S')}.jsonl"
    samples = run(cases, a.k, out, a.yes, a.stop_frac, not a.no_research)
    if samples:
        print(f"results: {out}")
        print(report(samples))
    return 0


if __name__ == "__main__":
    sys.exit(main())

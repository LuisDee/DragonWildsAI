r"""Replay the open-ask turn as if it came 20 s after his question to a player who never answered, under 3 variants.

The failure (study unanswered_1119, 19 Nov 2026): mid-job he asks the player something ("want me to go for it?"), the
harness player never answers, the open-ask turn runs 1-2 s after the line and he stays silent or parks, and the trial
ends quiet. The proposal is a turn at said_s_ago = 20. This tool takes each logged open-ask turn that followed such a
question, moves it to 20 s after the line (the open request's asked_s_ago grows by the same shift; nothing else in the
game moved: the body was idle), and asks the Controller model (Haiku, through brain/llm.py) what he does.

Variants (what the turn shows; never what to do):
  A  today: the logged open-ask turn (its messages, its tools plus request_done / park_request), shown as at +20 s.
  B  A plus one data block: his last line, how many seconds ago, who heard it (players within hearing: none), player
     lines since (0), the ask's state (open), and that no plan or goal is running.
  C  B, and the history's check after a no-call reply (brain/agent.py PROMISE_NOTE, PROMISE_FOR_NOTE) without its
     "reply with no text at all" exit. persona.md ("his answer comes as his next line") is left as is.

Held-out jobs (H1, H2, H3) are never used. Cases: the non-held-out unanswered questions with a logged open-ask turn
after the line and no goal running after it (the trigger's own condition): 10, so 10 x 3 x 3 = 90 calls.

Rubric (blind to the variant, tools/replay_open_ask.outcome): acts = a world call or start_goal / add_task (a body call
on work, not food or water); read = a read-only call (lookup, look...); park = park_request; done = request_done;
silent = no call and no text; asks = a say only (asks again or talks).

  .venv\Scripts\python.exe -m tools.replay_unanswered cases            # list cases and the edits per variant (no calls)
  .venv\Scripts\python.exe -m tools.replay_unanswered run --k 3 --yes  # 3 samples per case and variant
  .venv\Scripts\python.exe -m tools.replay_unanswered report FILE      # tally a results file again (no calls)

Results: logs/evals/replay_unanswered-<ts>.jsonl in the main tree (each call's usage row, so tools/spend.py counts it,
and one `replay` row per sample).
"""
from __future__ import annotations

import argparse
import copy
import json
import sys
import time
from pathlib import Path

from brain import open_ask as oa
from brain import paths
from brain.agent import PROMISE_FOR_NOTE, PROMISE_NOTE
from tools.replay_open_ask import episode_calls, outcome, read_jsonl

LOGS = paths.LIVE_ROOT / "logs"
SHIFT_TO_S = 20  # the proposed turn: this long after his line
HELD_OUT = ("H1", "H2", "H3")
# run -> brain log. The 19 cases of the study minus the held-out 4 (18-105344 H1, 18-110805 H1, 19-095309 H3,
# 19-095659 H3) and minus the 4 where the trigger's condition fails or no open-ask turn followed the line:
# 18-072538 L2-V1 and 19-101403 L3 (the goal ran on after the question), 19-074505 L2-V1 (the goal ran on: gather at
# +0.3 s), 18-095124 L2-V1 (no open-ask turn: a body run beside the goal), and 18-044942 (below).
CASES = {
    "20261118-000146-L2": "brain-live-20261118-010135-17424.jsonl",
    "20261118-040149-N1-I4": "brain-live-20261118-050138-16216.jsonl",
    "20261118-053829-N1-I2": "brain-live-20261118-063818-28112.jsonl",
    "20261118-071340-L2-V1": "brain-live-20261118-081329-28064.jsonl",
    "20261118-071711-L2-V1": "brain-live-20261118-081700-23192.jsonl",
    "20261118-072043-L2-V1": "brain-live-20261118-082032-27540.jsonl",
    "20261118-095833-L2-V1": "brain-live-20261118-105821-27884.jsonl",
    "20261118-145610-L2-V1": "brain-live-20261118-155540-30692.jsonl",
    "20261119-004236-N2-I4": "brain-live-20261119-014205-32848.jsonl",
    "20261119-090926-L2-V1": "brain-live-20261119-100915-8220.jsonl",
}
# 18-044942 L2 left out too: its open-ask turn ran 13 s later in another episode (situation-0002-bbff, a run started
# 245 s before), whose history ends on an earlier question, not this one.
VARIANTS = ("A", "B", "C")
# the exits removed in C (the rest of each note stays word for word)
PROMISE_EXIT = " Otherwise (you only answered or asked something) reply with no text at all."
PROMISE_FOR_EXIT = " If it is finished, reply with no text at all."
PROMISE_FOR_HEAD = PROMISE_FOR_NOTE.split("{player}")[0]  # "You replied without calling any tool. That line has been said. "
assert PROMISE_EXIT in PROMISE_NOTE and PROMISE_FOR_EXIT in PROMISE_FOR_NOTE
SCORE = {"world": "acts", "read": "read", "park": "park", "done_claim": "done", "empty": "silent", "say": "asks",
         "need": "need"}
COLUMNS = ("acts", "read", "park", "done", "need", "asks", "silent")


# ------------------------------------------------------------------ case building (pure but for the log read)


def _content(m: dict) -> str:
    return m.get("content") if isinstance(m.get("content"), str) else ""


def build_case(run: str, log: str, logs: Path = LOGS) -> dict:
    """The question (his last say with a '?') and the first open-ask turn after it, with its full request."""
    if any(f"-{h}" in run for h in HELD_OUT):
        raise ValueError(f"{run}: held-out job")
    rows = read_jsonl(logs / log)
    q = max(i for i, r in enumerate(rows) if r.get("kind") == "say" and "?" in (r.get("text") or ""))
    say = rows[q]
    p = next(i for i in range(q, len(rows)) if rows[i].get("kind") == "prompt"
             and rows[i].get("component") == "controller"
             and _content((rows[i].get("messages") or [{}])[-1]).startswith(oa.NOTE_PREFIX))
    ep = rows[p]["episode_id"]
    calls = episode_calls(rows, ep)
    _, msgs, live, tools, settings = next(c for c in calls if c[0] == p)
    if not tools:
        raise ValueError(f"{run}: no tool list logged for {ep}")
    text = say["text"]
    blob = json.dumps(msgs, ensure_ascii=False)
    if json.dumps(text, ensure_ascii=False)[1:-1][:60] not in blob:
        raise ValueError(f"{run}: the question is not in the rebuilt request")
    block = json.loads(_content(msgs[-1])[len(oa.NOTE_PREFIX):])["open_request"]
    lines = [r for r in rows[:q] if r.get("kind") == "event" and (r.get("event") or {}).get("type") == "chat_heard"]
    return {"run": run, "log": log, "episode": ep, "row": p, "question": text, "t_say": say["ts"],
            "t_turn": rows[p]["ts"], "lag_s": round(rows[p]["ts"] - say["ts"], 1), "player": block.get("player"),
            "words": block.get("words"), "asked_s_ago_live": block.get("asked_s_ago"),
            "player_last_line": (lines[-1]["event"] if lines else {}).get("text"),
            "player_last_line_s_ago": round(say["ts"] + SHIFT_TO_S - lines[-1]["ts"]) if lines else None,
            "live_outcome": outcome(live.get("tool_calls") or [], live.get("content")),
            "messages": msgs, "tools": list(tools) + list(oa.ASK_TOOL_SCHEMAS), "settings": settings}


def data_block(case: dict) -> dict:
    """Variant B's block: facts about his last line and the ask, no advice."""
    return {"your_last_line": case["question"], "said_s_ago": SHIFT_TO_S,
            "heard_by": "players within hearing: none", "player_lines_since": 0,
            "open_request": {"player": case["player"], "words": case["words"], "state": "open"},
            "running": {"plan": "none", "goal": "none"}}


def strip_exits(msgs: list[dict]) -> tuple[list[dict], int]:
    """The messages with the silence exit taken out of every PROMISE_NOTE / PROMISE_FOR_NOTE; (messages, edits)."""
    out, n = [], 0
    for m in msgs:
        c = _content(m)
        if m.get("role") == "user" and c:
            new = c.replace(PROMISE_EXIT, "") if PROMISE_NOTE in c else c
            if c.startswith(PROMISE_FOR_HEAD) and PROMISE_FOR_EXIT in c and " asked " in c:
                new = new.replace(PROMISE_FOR_EXIT, "")
            if new != c:
                m, n = {**m, "content": new}, n + 1
        out.append(m)
    return out, n


def build_request(case: dict, variant: str) -> tuple[list[dict], list[dict], int]:
    """(messages, tools, exits removed) of one replayed call."""
    msgs = copy.deepcopy(case["messages"])
    head = msgs[-1]
    blk = json.loads(_content(head)[len(oa.NOTE_PREFIX):])
    shift = round(case["t_say"] + SHIFT_TO_S - case["t_turn"])
    if isinstance(blk["open_request"].get("asked_s_ago"), (int, float)):
        blk["open_request"]["asked_s_ago"] = round(blk["open_request"]["asked_s_ago"] + shift)
    head["content"] = oa.NOTE_PREFIX + json.dumps(blk, ensure_ascii=False)
    edits = 0
    if variant in ("B", "C"):
        msgs.append({"role": "user", "content": "Since your last line: " + json.dumps(data_block(case),
                                                                                      ensure_ascii=False)})
    if variant == "C":
        msgs, edits = strip_exits(msgs)
    return msgs, case["tools"], edits


# ------------------------------------------------------------------ tally (pure)


def tally(samples: list[dict]) -> dict[str, dict[str, int]]:
    t = {v: {c: 0 for c in (*COLUMNS, "n")} for v in VARIANTS}
    for s in samples:
        t[s["variant"]][SCORE.get(s["outcome"], "asks")] += 1
        t[s["variant"]]["n"] += 1
    return t


def report(samples: list[dict]) -> str:
    from tools import ab
    t = tally(samples)
    out = ["variant  " + "  ".join(f"{c:>6}" for c in COLUMNS) + "       n"]
    for v in VARIANTS:
        if t[v]["n"]:
            out.append(f"{v:8} " + "  ".join(f"{t[v][c]:6}" for c in COLUMNS) + f"  {t[v]['n']:6}")
    for a, b in (("A", "B"), ("A", "C"), ("B", "C")):
        if t[a]["n"] and t[b]["n"]:
            for col in ("acts", "park", "silent"):
                k1, n1, k2, n2 = t[a][col], t[a]["n"], t[b][col], t[b]["n"]
                out.append(f"{col:6} {a} {k1}/{n1} vs {b} {k2}/{n2}: Fisher p = {ab.fisher(k1, n1, k2, n2):.4f}")
    by_case: dict = {}
    for s in samples:
        by_case.setdefault(s["case"], {v: [] for v in VARIANTS})[s["variant"]].append(SCORE.get(s["outcome"], "asks"))
    out.append("per case:")
    for c, vs in by_case.items():
        out.append(f"  {c:24} " + " | ".join(f"{v} {','.join(vs[v])}" for v in VARIANTS))
    return "\n".join(out)


# ------------------------------------------------------------------ calls


def _spent() -> tuple[float, float]:
    from tools import spend
    return float(spend.spend_today(LOGS)["spent_usd"]), float(spend.cap_usd())


def run(cases: list[dict], k: int, max_calls: int, out: Path, yes: bool, stop_frac: float) -> list[dict]:
    from brain.jsonl_log import JsonlLogger
    from brain.llm import controller_llm
    llm = controller_llm()
    plan = len(cases) * len(VARIANTS) * k
    spent, cap = _spent()
    print(f"plan: {len(cases)} cases x {len(VARIANTS)} variants x {k} = {plan} calls of {llm.model} (cap {max_calls}); "
          f"spend today ${spent:.2f} of ${cap:.2f}", flush=True)
    if not yes:
        print("dry run: add --yes to call")
        return []
    log = JsonlLogger(out)
    samples, calls = [], 0
    for c in cases:
        for variant in VARIANTS:
            msgs, tools, edits = build_request(c, variant)
            eff = ((c["settings"] or {}).get("output_config") or {}).get("effort")
            for rep in range(k):
                if calls >= max_calls:
                    print(f"stopped at the call cap: {calls}")
                    return samples
                if calls % 10 == 0:
                    spent, cap = _spent()
                    if spent >= stop_frac * cap:
                        print(f"stopped: spend today ${spent:.2f} is over {stop_frac:.0%} of the ${cap:.2f} cap")
                        return samples
                try:
                    resp = llm.complete(msgs, tools=tools, effort=eff) if eff else llm.complete(msgs, tools=tools)
                except Exception as exc:
                    calls += 1
                    log.log("replay_error", case=c["run"], variant=variant, rep=rep, error=repr(exc)[:400])
                    print(f"  {c['run']} {variant} error {exc!r}"[:300], flush=True)
                    continue
                calls += 1
                log.log("llm_response", component="controller", model=llm.model, step="replay_unanswered",
                        usage=resp.usage)
                tc = [{"name": t.name, "arguments": t.arguments} for t in resp.tool_calls]
                s = {"case": c["run"], "variant": variant, "rep": rep, "outcome": outcome(tc, resp.content),
                     "calls": tc, "text": resp.content, "exits_removed": edits,
                     "cost_usd": (resp.usage or {}).get("cost_usd"), "cached": (resp.usage or {}).get("cached")}
                samples.append(s)
                log.log("replay", **s)
                print(f"  {c['run']:24} {variant} {SCORE.get(s['outcome'], s['outcome']):6} "
                      f"{json.dumps(tc, ensure_ascii=False)[:160]}", flush=True)
    usd = sum(float(s.get("cost_usd") or 0) for s in samples)
    print(f"done: {calls} calls, ${usd:.4f}")
    return samples


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("cases")
    r = sub.add_parser("run")
    r.add_argument("--k", type=int, default=3)
    r.add_argument("--max-calls", type=int, default=90)
    r.add_argument("--stop-frac", type=float, default=0.9, help="stop when today's spend passes this share of the cap")
    r.add_argument("--yes", action="store_true")
    rp = sub.add_parser("report")
    rp.add_argument("file")
    a = ap.parse_args(argv)
    if a.cmd == "report":
        print(report([x for x in read_jsonl(a.file) if x.get("kind") == "replay"]))
        return 0
    cases = [build_case(run_, log) for run_, log in CASES.items()]
    if a.cmd == "cases":
        for c in cases:
            _, _, edits = build_request(c, "C")
            print(f"{c['run']:24} lag {c['lag_s']:5}s asked_s_ago {c['asked_s_ago_live']} live {c['live_outcome']:6} "
                  f"C exits {edits} | {c['question'][-70:]}")
        return 0
    out = LOGS / "evals" / f"replay_unanswered-{time.strftime('%Y%m%d-%H%M%S')}.jsonl"
    samples = run(cases, a.k, a.max_calls, out, a.yes, a.stop_frac)
    if samples:
        print(f"results: {out}")
        print(report(samples))
    return 0


if __name__ == "__main__":
    sys.exit(main())

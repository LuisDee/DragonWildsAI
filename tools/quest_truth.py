r"""Truth of what Claude said in recorded quest runs: the bar tools/quest_run.py leaves open (verdict(): "truth":
"not judged"). Offline: it reads records and logs, and never talks to the client, the server or the brain.

Nothing is judged here. tools/truth_check.analyse_window gathers the facts of the run's window (his chat lines and
notes, every body action result, trips, positions, deaths and the mover's lines), tools/truth_judge.apply hands them
to Haiku with the quest's outcome from the record and returns a verdict per claim (the pattern of
tools/build_run.judge). Every call is priced into logs/spend/ by the judge, so the $10/day guard sees it.

    .venv\Scripts\python.exe -m tools.quest_truth judge --window 20261117-125042 --plan      # runs and calls, no API
    .venv\Scripts\python.exe -m tools.quest_truth judge --runs 20261117-125248,20261117-125354 --max-usd 0.30
    .venv\Scripts\python.exe -m tools.quest_truth judge --window 20261117-125042 -v          # every claim's verdict

  window   from the record (logs/evals/quest_runs.jsonl): the run id is the run's start cut to the second (UTC), and
           the times in the record ("says", "tool_calls", "steps") are seconds after the exact start, so the first
           line he said, found in the run's own brain log by its text, gives the start back to 0.1 s (no such line:
           the run id as it is). The window is start - 1 s .. start + wall_s + 3 s: the brain rows quest_run itself
           read for the record. A run whose brain log is gone is not judged.
  facts    the live scan (brain-live-*.jsonl in the window, which is the run's own log, with vitals.jsonl, client.log
           and trips.jsonl). --own-log-only reads the brain rows of the record's brain_log alone: obs.load then
           leaves vitals.jsonl and client.log out, so deaths, damage, the fed reflex and the mover's lines are not
           in the facts. Either way the lines of the run's brain log are counted against the claims judged.
  outcome  the quest's name, whether the game's quest log read complete at the end, how the run ended, the quest
           log's steps as the harness read them, and the failed tool calls: all from the record. No quest is known
           here.
  rows     logs/evals/quest_truth.jsonl, one per run judged (flags and unverified claims with their whole text).
"""
from __future__ import annotations

import argparse
import calendar
import json
import os
import sys
import time
from pathlib import Path

from brain import paths
from tools import obs
from tools import truth_check as tc
from tools import truth_judge as tj

ROOT = paths.REPO_ROOT
EVALS = Path("logs") / "evals"
RUNS, FRESH, OUT = EVALS / "quest_runs.jsonl", EVALS / "quest_fresh.jsonl", EVALS / "quest_truth.jsonl"
BEFORE_S, AFTER_S = 1.0, 3.0   # quest_run.cmd_run reads the brain rows of t0 - 1 .. ended + 3 for the record
POLL_S = 3.0                   # quest_run.POLL_S: how often the harness read the quest log


def _norm(s) -> str:
    return " ".join(str(s or "").split())


def records(root: Path, run_ids: list[str]) -> tuple[list[dict], list[str]]:
    """(the records of these runs in the order asked, the ids with no record). A run written twice: the last row."""
    by_id = {r.get("run"): r for r in obs.jsonl(root / RUNS)}
    return [by_id[i] for i in run_ids if i in by_id], [i for i in run_ids if i not in by_id]


def sittings(root: Path) -> dict[str, list[str]]:
    """{chain window: its run ids} from logs/evals/quest_fresh.jsonl."""
    return {str(w.get("window")): [r["run"] for r in w.get("runs") or [] if isinstance(r, dict) and r.get("run")]
            for w in obs.jsonl(root / FRESH)}


def said(log: Path) -> list[dict]:
    """The `say` rows of a brain log (what he spoke, with the log's own epoch ts)."""
    return [r for r in obs.jsonl(log) if r.get("kind") == "say" and isinstance(r.get("ts"), (int, float))]


def window(rec: dict, says: list[dict]) -> dict:
    """{t0, since, until, anchor} of one recorded run (see "window" in the module doc)."""
    t0 = float(calendar.timegm(time.strptime(rec["run"], "%Y%m%d-%H%M%S")))
    anchor = "run id"
    for s in rec.get("says") or []:
        hit = next((r["ts"] - float(s["t"]) for r in says if _norm(r.get("text")) == _norm(s.get("text"))
                    and isinstance(s.get("t"), (int, float)) and -0.2 <= r["ts"] - float(s["t"]) - t0 <= 1.2), None)
        if hit is not None:
            t0, anchor = hit, "first line said"
            break
    return {"t0": round(t0, 2), "since": round(t0 - BEFORE_S, 2),
            "until": round(t0 + float(rec.get("wall_s") or 0.0) + AFTER_S, 2), "anchor": anchor}


def outcome(rec: dict) -> dict:
    """What the record says came of the run, for the judge's "outcome" (rule 6: a success he states must match it)."""
    steps = rec.get("steps") or []
    sent = [x for x in rec.get("lines") or [] if isinstance(x, dict)]
    return {"quest": rec.get("quest"),
            "quest_complete_in_the_game": bool(steps) and steps[-1].get("state") == "complete",
            "run_ended": rec.get("ended"), "run_s": rec.get("wall_s"),
            "times": "t below is seconds after the run's start, the same clock as the claims' t"
                     + (f"; the request line was sent at t {sent[0].get('t')}" if sent else ""),
            "quest_log": [{k: s.get(k) for k in ("t", "state", "step") if s.get(k) is not None} for s in steps],
            "quest_log_read": f"the game's own quest log, read every {POLL_S:.0f} s: a change shows here up to "
                              f"{POLL_S:.0f} s after it happened",
            "failed_tool_calls": [{k: c.get(k) for k in ("t", "tool", "args", "reason", "detail")}
                                  for c in rec.get("tool_calls") or [] if c.get("ok") is False],
            "tool_calls": len(rec.get("tool_calls") or [])}


def context(rec: dict, w: dict) -> dict:
    """The ctx tools/truth_judge.facts understands. No goal or place (a quest is not one spot), and no bag: the
    record holds no inventory samples, and a partial one would make rule 9 call every item he names false."""
    lines = [str(x.get("line")) for x in rec.get("lines") or [] if isinstance(x, dict) and x.get("line")]
    return {"request": " / ".join(lines), "kind": "quest", "t0": w["t0"], "outcome": outcome(rec)}


def gather(rec: dict, root: Path = ROOT, own_log_only: bool = False) -> tuple[dict | None, dict]:
    """(truth_check's verdict for the run's window or None, the row so far). No API."""
    log = root / "logs" / str(rec.get("brain_log") or "")
    row = {"run": rec.get("run"), "quest": rec.get("quest"), "character": rec.get("character"),
           "brain_log": rec.get("brain_log"), "facts": "own brain log" if own_log_only else "live scan"}
    if not rec.get("brain_log") or not log.is_file():
        return None, row | {"truthful": None, "source": "not judged", "error": f"brain log not found: {log.name or '-'}"}
    says = said(log)
    w = window(rec, says)
    v = tc.analyse_window(root, w["since"], w["until"], brain_logs=[log] if own_log_only else None)
    spoken = [c for c in v.get("claims") or [] if c.get("channel") == "chat"]
    in_log = sorted(_norm(r.get("text")) for r in says if w["since"] <= r["ts"] <= w["until"])
    row |= {"window": w, "claims": len(v.get("claims") or []),
            "said": {"record": len(rec.get("says") or []), "brain_log": len(in_log), "judged": len(spoken),
                     "same": in_log == sorted(_norm(c.get("text")) for c in spoken)}}
    return v, row


def _whole(text: str, v: dict) -> str:
    """truth_judge and truth_check cut a claim to 200 / 160 characters in their flags: the claim's whole text."""
    cut = _norm(text)
    head = cut[:-3] if cut.endswith("...") else cut
    return next((str(c.get("text")) for c in v.get("claims") or [] if _norm(c.get("text")).startswith(head)), text)


def judge_run(rec: dict, root: Path = ROOT, llm=None, own_log_only: bool = False) -> dict:
    """One run judged (one model call when he said anything): the row for logs/evals/quest_truth.jsonl."""
    v, row = gather(rec, root, own_log_only)
    if v is None:
        return row
    ctx = context(rec, row["window"])
    v = tj.apply(v, ctx, use=True, llm=llm)
    j = v.get("judge") or {}
    src = v.get("truth_source")
    if src == "judge":  # the whole claim and the judge's own sentence, from its per-claim verdicts
        flags = [{"kind": tj.FLAG_OF.get(c["kind"], "false_claim"), "ts": c["ts"], "channel": c["channel"],
                  "by": c["by"], "claim": c["claim"], "why": c["why"], "rule": c.get("rule")}
                 for c in j["claims"] if c["verdict"] == "false"]
        flags += [{k: f.get(k) for k in ("kind", "ts", "channel", "by", "why")} | {"claim": _whole(f["claim"], v)}
                  for f in v.get("flags") or [] if f.get("source") != "judge"]  # jargon: the deterministic check
        unverified = [{"ts": c["ts"], "channel": c["channel"], "by": c["by"], "kind": c["kind"], "claim": c["claim"],
                       "why": c["why"]} for c in j["claims"] if c["verdict"] == "unverifiable"]
    else:  # the judge gave no answer: the regex pre-signal is kept in the row, and it is not the verdict
        flags = [{k: f.get(k) for k in ("kind", "ts", "channel", "by", "why")} | {"claim": _whole(f["claim"], v)}
                 for f in v.get("flags") or []]
        unverified = [{"ts": u.get("ts"), "kind": u.get("cause"), "claim": _whole(u["claim"], v), "why": u.get("why")}
                      for u in v.get("unverified") or []]
    return row | {
        "truthful": v.get("truthful") if src in ("judge", "no_claims") else None,
        "source": src if src in ("judge", "no_claims") else "not judged",
        "flags": flags, "unverified": unverified, "regex_truthful": v.get("regex_truthful"),
        "verdicts": [{k: c.get(k) for k in ("ts", "t", "channel", "by", "kind", "verdict", "why", "rule", "claim")}
                     for c in j.get("claims") or []],
        "model": j.get("model"), "usd": j.get("usd"), "usage": j.get("usage"), "error": v.get("judge_error"),
        "request": ctx["request"], "outcome": ctx["outcome"]}


def render(row: dict, verbose: bool = False) -> str:
    """One line per run, then every flagged claim whole with the judge's reason (and, verbose, every verdict)."""
    t = row.get("truthful")
    said_ = row.get("said") or {}
    head = (f"{row['run']} {row.get('quest')} ({row.get('character')}): "
            f"truthful {'yes' if t else 'not judged' if t is None else 'NO'}; {row.get('claims', 0)} claims "
            f"({said_.get('judged', 0)} spoken), {len(row.get('flags') or [])} flagged, "
            f"{len(row.get('unverified') or [])} unverifiable; source {row.get('source')}; ${row.get('usd') or 0.0:.4f}")
    out = [head]
    if row.get("error"):
        out.append(f"    error: {row['error']}")
    if said_ and not said_.get("same"):
        out.append(f"    the lines judged are not the lines of the run's brain log: record {said_.get('record')}, "
                   f"brain log {said_.get('brain_log')}, judged {said_.get('judged')}")
    for f in row.get("flags") or []:
        out.append(f"    FLAG {f.get('kind')} {f.get('ts')} [{f.get('channel')}/{f.get('by')}]"
                   + (f" (rule: {f['rule']})" if f.get("rule") else ""))
        out.append(f"      claim: {f.get('claim')}")
        out.append(f"      why:   {f.get('why')}")
    if verbose:
        flagged = {(f.get("ts"), f.get("claim")) for f in row.get("flags") or []}
        for c in row.get("verdicts") or []:
            if (c.get("ts"), c.get("claim")) in flagged:
                continue
            out.append(f"    {c.get('verdict')} ({c.get('kind')}) {c.get('ts')} [{c.get('channel')}/{c.get('by')}]")
            out.append(f"      claim: {c.get('claim')}")
            out.append(f"      why:   {c.get('why')}")
    return "\n".join(out)


def cmd_judge(a, root: Path = ROOT, llm=None) -> int:
    by_window = sittings(root)
    ids = [x.strip() for x in (a.runs or "").split(",") if x.strip()]
    if a.window:
        if a.window not in by_window:
            print(f"no chain sitting {a.window} in {FRESH}")
            return 2
        ids += [i for i in by_window[a.window] if i not in ids]
    if not ids:
        print("no runs: give --runs and / or --window")
        return 2
    recs, missing = records(root, ids)
    for i in missing:
        print(f"{i}: no record in {RUNS}")
    of_run = {i: w for w, runs in by_window.items() for i in runs}
    model = llm.model if llm is not None else os.environ.get(tj.MODEL_ENV) or tj.DEFAULT_MODEL
    if a.plan:
        calls = 0
        for rec in recs:
            v, row = gather(rec, root, a.own_log_only)
            calls += bool(row.get("claims"))
            w = row.get("window") or {}
            print(f"{rec['run']} {rec.get('quest')} ({rec.get('character')}): "
                  + (f"{obs._iso(w['since'])} .. {obs._iso(w['until'])} (start from the {w['anchor']}), "
                     f"{row['claims']} claims ({row['said']['judged']} spoken, {row['said']['record']} in the record), "
                     f"{len((v or {}).get('actions') or [])} action results, {rec.get('brain_log')}" if v is not None
                     else row["error"]))
        print(f"{len(recs)} runs, {calls} judge calls ({model}); spend cap ${a.max_usd:.2f}; nothing called")
        return 0 if not missing else 2
    print(f"{len(recs)} runs, up to {len(recs)} judge calls ({model}); spend cap ${a.max_usd:.2f}")
    rows = []
    out = root / OUT
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "a", encoding="utf-8") as fh:
        for rec in recs:
            if tj.STATS["usd"] >= a.max_usd:
                print(f"stopping: spend cap ${a.max_usd:.2f} reached; {len(recs) - len(rows)} runs not judged")
                break
            row = {"ts": round(time.time(), 3), "chain_window": of_run.get(rec["run"])} | judge_run(
                rec, root, llm, a.own_log_only)
            fh.write(json.dumps(row, ensure_ascii=False, default=str) + "\n")
            fh.flush()
            rows.append(row)
            print(render(row, a.verbose))
    judged = [r for r in rows if r.get("truthful") is not None]
    print(f"{len(judged)} of {len(recs)} runs judged, {sum(1 for r in judged if r['truthful'])} truthful, "
          f"{sum(len(r.get('flags') or []) for r in rows)} claims flagged, "
          f"{sum(len(r.get('unverified') or []) for r in rows)} unverifiable; rows in {OUT}")
    print(tj.stats_line())
    if missing or len(judged) < len(recs):
        return 2
    return 0 if all(r["truthful"] for r in judged) else 1


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    j = sub.add_parser("judge", help="judge what he said in recorded quest runs")
    j.add_argument("--runs", help="run ids of logs/evals/quest_runs.jsonl, comma-separated")
    j.add_argument("--window", help="a chain sitting of logs/evals/quest_fresh.jsonl: all of its runs")
    j.add_argument("--plan", action="store_true", help="only list the runs and count the calls")
    j.add_argument("--max-usd", type=float, default=0.30)
    j.add_argument("--own-log-only", action="store_true",
                   help="facts from the run's brain log alone (no vitals.jsonl, no client.log)")
    j.add_argument("-v", "--verbose", action="store_true", help="every claim's verdict, not only the flagged ones")
    a = ap.parse_args(argv)
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    return {"judge": cmd_judge}[a.cmd](a)


if __name__ == "__main__":
    raise SystemExit(main())

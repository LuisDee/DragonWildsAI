r"""Offline: does the Controller look a quest up (the wiki walkthrough, brain/knowledge.py) when a quest step is new to
him? Luis 2026-11-01: "is he pulling wiki info on that quest to guide him?" (that night's brain logs: 0 lookup calls).

  extract  the recorded moments a quest step was just handed to him: in the quest runs' brain logs
           (logs/evals/quest_runs.jsonl -> brain_log), each tool result whose data.quests_changed has a quest now
           "given", and the Controller prompt that carried it (the episode's full message list rebuilt from the
           logged prompt rows: a full row has the system message, later rows add messages from `messages_from`).
           -> evals/quest_lookup_cases.jsonl
  run      re-sends each case's prompt, no tool runs, under the case's own logged system prompt (the context is as
           live built it) with two tool lists: "live" (the tools that prompt was sent with) and "today" (today's
           Controller.tools, the real client manifest: brain.interface TOOLS wording). Counts per variant: answers
           that call lookup, and lookups whose query names the quest. A sample that looked up gets the lookup
           answered from the real index and one more call, so its action is known; a blind judge (Haiku, JSON
           output) scores each sample's action against the step and the wiki walkthrough (2 right next action,
           1 plausible but indirect, 0 wrong or none). Prints the planned calls; refuses without
           --yes; stops at --max-usd.

  .venv\Scripts\python.exe -m tools.quest_lookup_eval extract
  .venv\Scripts\python.exe -m tools.quest_lookup_eval run                 # plan only
  .venv\Scripts\python.exe -m tools.quest_lookup_eval run --repeat 2 --yes
"""
from __future__ import annotations

import argparse
import json
import os
import tempfile
import time
from pathlib import Path

from brain import paths
from brain.controller import Decision
from brain.jsonl_log import JsonlLogger
from tools.replay_first_call import _rows, body_caps, client_for, live_controller

ROOT = paths.REPO_ROOT
RUNS = ROOT / "logs" / "evals" / "quest_runs.jsonl"
CASES = ROOT / "evals" / "quest_lookup_cases.jsonl"


def _given(result: dict) -> list[dict]:
    d = (result or {}).get("data") if isinstance((result or {}).get("data"), dict) else {}
    return [c for c in d.get("quests_changed") or [] if isinstance(c, dict) and c.get("to") == "given"]


def extract_log(rows: list[dict], source: str) -> list[dict]:
    """The cases of one brain log: (the prompt right after a result that gave a quest step, rebuilt in full)."""
    full: dict[str, list[dict]] = {}  # episode -> its message list so far
    tools: dict[str, list] = {}
    pending: dict[str, list[dict]] = {}  # episode -> quest steps given by a result not yet sent to the model
    out = []
    for r in rows:
        ep = r.get("episode_id")
        if r.get("kind") == "tool_result" and ep and (g := _given(r.get("result"))):
            pending.setdefault(ep, []).extend(g)
        if r.get("kind") != "prompt" or r.get("component") != "controller" or not ep:
            continue
        ms = r.get("messages") or []
        if ms and ms[0].get("role") == "system":
            full[ep] = list(ms)
            tools[ep] = r.get("tools") or tools.get(ep) or []
        elif ep in full and isinstance(r.get("messages_from"), int):
            full[ep] = full[ep][:r["messages_from"]] + list(ms)
        else:
            continue
        if pending.get(ep):
            g = pending.pop(ep)
            out.append({"id": f"{source}:{r.get('ts')}", "quests": [x.get("quest") for x in g],
                        "steps": [x.get("step") for x in g], "messages": full[ep], "tools": tools.get(ep) or []})
    return out


def cmd_extract(a) -> int:
    logs = []
    for r in _rows(RUNS):
        if r.get("brain_log") and r["brain_log"] not in logs:
            logs.append(r["brain_log"])
    cases = []
    for lg in logs:
        cases += extract_log(_rows(ROOT / "logs" / lg), Path(lg).stem)
    seen, uniq = set(), []
    for c in cases:  # one case per (quest, step) handed: the same step from several clone runs adds little
        key = (tuple(c["quests"]), tuple(c["steps"]))
        if key not in seen:
            seen.add(key)
            uniq.append(c)
    CASES.parent.mkdir(parents=True, exist_ok=True)
    with CASES.open("w", encoding="utf-8") as f:
        for c in uniq:
            f.write(json.dumps(c, ensure_ascii=False) + "\n")
    print(f"{len(cases)} moments in {len(logs)} brain logs, {len(uniq)} distinct steps -> {CASES}")
    for c in uniq:
        print("  ", c["quests"], (c["steps"][0] or "")[:90])
    return 0


def score(quests: list[str], calls: list[dict]) -> dict:
    looks = [c for c in calls if c.get("name") == "lookup"]
    named = [c for c in looks if any(q and q.lower() in str((c.get("arguments") or {}).get("query", "")).lower()
                                     for q in quests)]
    return {"lookup": bool(looks), "names_quest": bool(named), "queries": [(c.get("arguments") or {}).get("query")
                                                                          for c in looks],
            "tools": [c.get("name") for c in calls]}


JUDGE_SCHEMA = {"type": "object", "additionalProperties": False, "required": ["score", "why"],
                "properties": {"score": {"type": "integer", "enum": [0, 1, 2]}, "why": {"type": "string"}}}
JUDGE_RUBRIC = ("You judge one decision of an AI companion playing RuneScape: Dragonwilds like a real player. A quest "
                "step was just handed to it. Below are the step, the community wiki's walkthrough of that quest (a "
                "reference; it may be outdated) and the tool calls the companion made next (read-only calls such as "
                "look, lookup or say are context: judge the action). Score 2 if the action is what a competent "
                "player does next for this step (right target, item, place or order); 1 if it is plausible but "
                "indirect, partial or slower than needed; 0 if it is wrong for the step or takes no action toward "
                "it. Answer JSON {score, why}, why in one short sentence.")


VARIANTS = ("live", "today", "walk")  # walk: today's tools, and the result that gave the step carries the walkthrough


def with_walkthrough(messages: list[dict], quests: list[str], walk: str) -> list[dict]:
    """The messages with the wiki walkthrough added to the tool result that handed him the quest step (the context a
    talk result would carry: no extra call)."""
    out = [dict(m) for m in messages]
    for m in reversed(out):
        if m.get("role") == "tool" and "quests_changed" in str(m.get("content")) and walk:
            try:
                body = json.loads(m["content"])
            except (TypeError, ValueError):
                break
            if isinstance(body, dict):
                body["quest_walkthrough"] = {"quest": quests[0] if quests else None, "source": "wiki", "text": walk}
                m["content"] = json.dumps(body, ensure_ascii=False)
            break
    return out


def judge(client, quests: list[str], steps: list[str], walk: str, calls: list[dict]) -> tuple[dict, dict]:
    """A blind score of the companion's next action for the step (it is not told whether he looked anything up)."""
    msg = {"quest": quests, "step_just_given": steps, "wiki_walkthrough": walk[:1600], "companion_calls": calls}
    resp = client.complete([{"role": "system", "content": JUDGE_RUBRIC},
                            {"role": "user", "content": json.dumps(msg, ensure_ascii=False)}])
    try:
        out = json.loads(resp.content or "{}")
    except ValueError:
        out = {"score": None, "why": f"unparsed: {(resp.content or '')[:80]}"}
    return out, resp.usage or {}


def cmd_run(a) -> int:
    from brain.llm import CONTROLLER_MODEL_ENV, missing_keys
    from tools import spend
    cases = _rows(Path(a.cases))[:a.limit]
    model = a.model or os.environ.get(CONTROLLER_MODEL_ENV) or "anthropic/claude-haiku-5-5"
    variants = [v.strip() for v in a.variants.split(",") if v.strip() in VARIANTS]
    n = len(cases) * len(variants) * max(1, a.repeat)
    print(f"[quest_lookup_eval] {len(cases)} cases x {len(variants)} variants ({', '.join(variants)}) x {a.repeat} "
          f"samples on {model} = "
          f"{n} calls, + 1 per sample that looked up (its action), + {n} small judge calls = at most {3 * n}; "
          f"no tools run; stops at ${a.max_usd:.2f}")
    if not cases:
        print("no cases: run `extract` first")
        return 2
    if missing_keys(model):
        print(f"Refusing: API key for {model} not set.")
        return 2
    if not a.yes:
        print("Refusing: pass --yes to confirm the API calls above.")
        return 2
    log = JsonlLogger(paths.log_dir() / "evals" / f"quest_lookup_eval-{time.strftime('%Y%m%d-%H%M%S')}.jsonl")
    prices, spent = spend.load_prices(), 0.0
    from brain.knowledge import open_knowledge
    from brain.llm import LiteLLMClient, assistant_message, tool_result_message
    know = open_knowledge()
    jc = LiteLLMClient(model, max_tokens=1024,
                       output_config={"effort": "low", "format": {"type": "json_schema", "schema": JUDGE_SCHEMA}})
    tally = {v: [0, 0, 0] for v in variants}  # samples, lookups, lookups naming the quest
    scores: dict[str, list[int]] = {"looked_up": [], "did_not": []}
    over = False
    with tempfile.TemporaryDirectory() as tmp:
        ctl = live_controller(client_for(model), "Tester", Path(tmp), log, body_caps())
        for c in cases:
            walk = ""
            for q in c["quests"] if know else []:
                walk = walk or ((know.lookup(q)["data"].get("walkthrough") or {}).get("text") or "")
            for variant in variants:
                tools = c["tools"] if variant == "live" else ctl.tools
                msgs = with_walkthrough(c["messages"], c["quests"], walk) if variant == "walk" else c["messages"]
                for i in range(max(1, a.repeat)):
                    if over:
                        break
                    acted: list[dict] = []
                    try:
                        resp = ctl._complete(msgs, tools, Decision(effort=ctl.addressed_effort), step=0)
                        spent += spend.price(model, resp.usage or {}, prices)[0]
                        acted = [{"name": t.name, "arguments": t.arguments} for t in resp.tool_calls]
                        res = score(c["quests"], acted)
                        if res["lookup"] and know is not None:  # answer the lookup for real, then see what he does
                            follow = [assistant_message(resp)] + [tool_result_message(
                                t, know.lookup(t.arguments.get("query") or "", t.arguments.get("kind"))
                                if t.name == "lookup" else {"ok": None, "note": "not run in this eval"})
                                for t in resp.tool_calls]
                            resp2 = ctl._complete(msgs + follow, tools, Decision(effort=ctl.addressed_effort),
                                                  step=1)
                            spent += spend.price(model, resp2.usage or {}, prices)[0]
                            acted += [{"name": t.name, "arguments": t.arguments} for t in resp2.tool_calls]
                    except Exception as exc:  # a failed call is a miss
                        res = {"lookup": False, "names_quest": False, "queries": [], "tools": [], "error": repr(exc)}
                    try:
                        verdict, usage = judge(jc, c["quests"], c["steps"], walk, acted)
                        spent += spend.price(model, usage, prices)[0]
                    except Exception as exc:
                        verdict = {"score": None, "why": repr(exc)[:120]}
                    t = tally[variant]
                    t[0], t[1], t[2] = t[0] + 1, t[1] + res["lookup"], t[2] + res["names_quest"]
                    if isinstance(verdict.get("score"), int):
                        scores["looked_up" if res["lookup"] else "did_not"].append(verdict["score"])
                    log.log("quest_lookup_result", id=c["id"], quests=c["quests"], variant=variant, sample=i,
                            acted=acted, judge=verdict, usd_so_far=round(spent, 5), **res)
                    print(f"  {variant:<5} {c['quests']} -> {[x['name'] for x in acted]} {res['queries']} "
                          f"judge {verdict.get('score')}: {verdict.get('why')}")
                    if spent >= a.max_usd:
                        print(f"STOPPED: spend cap ${a.max_usd:.2f}")
                        over = True
    for v, (n_, lk, nq) in tally.items():
        print(f"[{v}] lookup in {lk}/{n_} answers; naming the quest {nq}/{n_}")
    for k, xs in scores.items():
        print(f"[judge] {k}: n={len(xs)} mean score {sum(xs) / len(xs):.2f} (0-2)" if xs else f"[judge] {k}: n=0")
    print(f"${spent:.4f}; results: {log.path}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("extract")
    r = sub.add_parser("run")
    r.add_argument("--cases", default=str(CASES))
    r.add_argument("--limit", type=int, default=12)
    r.add_argument("--repeat", type=int, default=1)
    r.add_argument("--model", default=None)
    r.add_argument("--max-usd", type=float, default=0.10)
    r.add_argument("--yes", action="store_true")
    r.add_argument("--variants", default="live,today", help=f"of {', '.join(VARIANTS)}")
    a = ap.parse_args(argv)
    return {"extract": cmd_extract, "run": cmd_run}[a.cmd](a)


if __name__ == "__main__":
    raise SystemExit(main())

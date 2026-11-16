"""Replay one live episode's Controller calls in live order, K times, and tally what the last call does.

Why in order: a later turn replayed alone (cold prompt cache) does not behave like the live call. Chain 20261116-103757,
the turn after PROMISE_NOTE: live 2 of 3 empty replies; the same request replayed alone 36 of 36 tool calls; replayed
after the episode's earlier calls (cache hits as live: the `cached` tokens match the log's) 4 of 18 no call. Each of
the K runs gets its own cache namespace (a nonce line at the end of the system message), so runs don't warm each other.

usage: python -m tools.replay_episode LOG EPISODE_ID K [--note FILE] [--swap OLD NEW] [--skip i,j]
  --note FILE   replace the last call's final user message with FILE's text (try a wording against the logged one)
  --swap OLD NEW  replace the text OLD by NEW in every user message of every call (a note that recurs in the run)
  --skip i,j    leave out these calls of the episode (0-based) when the live cache pattern shows they wrote nothing
Costs K x (calls of the episode) Controller calls; state the count before a batch (CLAUDE.md section 2).
"""
from __future__ import annotations

import argparse
import copy
import json
import tempfile
import time
from pathlib import Path

from brain.controller import Decision
from brain.jsonl_log import JsonlLogger
from brain.llm import controller_llm
from tools import replay_first_call as rf

READS = ("say", "quests", "look", "recipes", "craft_plan", "lookup", "buildables", "explore")


def episode_calls(log: str, episode: str) -> list[tuple[int, list[dict], dict]]:
    """(row, the full messages of that call, the live response row) for each Controller call of the episode."""
    rows = [json.loads(line) for line in open(log, encoding="utf-8") if line.strip()]
    msgs: list[dict] = []
    out = []
    for i, r in enumerate(rows):
        if r["kind"] == "prompt" and r.get("component") == "controller" and r.get("episode_id") == episode:
            assert (r.get("messages_from") or 0) == len(msgs), (i, r.get("messages_from"), len(msgs))
            msgs = msgs + r["messages"]
            live = next(x for x in rows[i + 1:] if x["kind"] == "llm_response")
            out.append((i, list(msgs), live))
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("log"), ap.add_argument("episode"), ap.add_argument("k", type=int)
    ap.add_argument("--note"), ap.add_argument("--skip", default=""), ap.add_argument("--swap", nargs=2)
    a = ap.parse_args()
    skip = {int(x) for x in a.skip.split(",") if x}
    calls = [c for n, c in enumerate(episode_calls(a.log, a.episode)) if n not in skip]
    note = Path(a.note).read_text(encoding="utf-8").strip() if a.note else None
    tmp = Path(tempfile.mkdtemp())
    ctl = rf.live_controller(controller_llm(), "Tester", tmp, JsonlLogger(tmp / "replay.jsonl"))
    acted = 0
    for k in range(a.k):
        nonce = f"\n(run {time.time():.0f}-{k})"
        for i, m, live in calls:
            m = copy.deepcopy(m)
            m[0]["content"] += nonce
            if note and i == calls[-1][0]:
                m[-1]["content"] = note
            for x in m if a.swap else []:
                if x["role"] == "user" and isinstance(x.get("content"), str):
                    x["content"] = x["content"].replace(a.swap[0], a.swap[1])
            r = ctl._complete(m, ctl.tools, Decision(), step="turn0")
        did = [(c.name, c.arguments) for c in r.tool_calls]
        acted += any(name not in READS for name, _ in did)
        print(f"#{k} live cached {live['usage'].get('cached')} {[c['name'] for c in live['tool_calls']] or 'EMPTY'} | "
              f"replay cached {r.usage.get('cached')} {json.dumps(did, ensure_ascii=False)[:200] if did else 'TEXT' if r.content else 'EMPTY'}",
              flush=True)
    print(f"== the last call made a world call in {acted} of {a.k} runs")


if __name__ == "__main__":
    main()

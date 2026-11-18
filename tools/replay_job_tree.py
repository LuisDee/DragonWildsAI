"""Replay recorded copper (V1) failure turns with and without the job tree view (brain/job_tree.py) in the prompt.

For each turn of a spec file (a list of {run, log, episode, call_index}, picked from logs/evals/job_runs.jsonl runs):
the final Controller call of that episode (tools/replay_episode.episode_calls) is sent K times as logged ("without")
and K times with the tree swapped in ("with"), the way DW_JOB_TREE=1 shows it:
* the episode's first-turn context gets ``open_request`` = {player, words, job_tree} (the tree replaces known_facts),
  from the get_state read before the episode;
* the final call's open-ask block ("Open request: ...") has its known_facts replaced by job_tree; else its last
  "Current observation: ..." gets a job_tree key (Controller.next_turn); both from the get_state read before the call.
An open-ask turn is offered request_done / park_request as live (brain/open_ask.ASK_TOOL_SCHEMAS).

Cost: only the final call is replayed (no in-order prefix calls; the doc of replay_episode says a call replayed alone
can differ from live: the same holds for both arms, so the comparison is paired). No nonce: the K runs of one arm share
the prompt cache (cheaper: Haiku cache reads are 0.1x). The spend is summed from usage.cost_usd and the run stops when
it passes --cap.

GRADING (fixed 2026-11-18 before any run; the reply of the final call, its tool calls and its text):
* FALSE  - a call or line that acts on or claims a false prerequisite for the copper job: names a Bronze Pickaxe,
           bronze bar, tin, a furnace or a blacksmith's bench as the way to the pickaxe, or a Stone Pickaxe as one
           that mines copper, or "copper needs bronze".
* STEP   - a world call or start_goal on a step of a bone-pickaxe path or its true blockers: gather / attack /
           explore / cast / craft / build / place / go_to / interact / start_goal / run_skill whose arguments (or, for
           go_to / interact, its own line) name one of PATH (Animal Bone, Ash Logs, Leather, Animal Hide, hide scraps,
           Coarse Thread, Coarse Animal Fur, Flax, Stone, Tannery, Spinning Wheel, Crafting Table, Bone Pickaxe,
           Bark to Bones, or a creature that drops bone, hide, scraps or fur).
* STOP   - no call (text or nothing), park_request, request_done, or only a say (a question to the player included).
* READ   - only reads (craft_plan, recipes, lookup, look, buildables, recall ...), no world call.
* OTHER  - a world call on nothing above (food, water, sleep, copper with no tier-2 pickaxe ...).
PASS = STEP and not FALSE. Everything else fails. The tally per arm is passes of K per turn, summed over turns.

usage: python -m tools.replay_job_tree SPEC.json K [--cap 0.20] [--dry] [--out FILE]
  --dry   build and print the views and the prompt sizes only (no model call)
"""
from __future__ import annotations

import argparse
import copy
import json
import re
from pathlib import Path

FALSE_RE = re.compile(r"bronze\s+(pick|bar)|\btin\b|furnace|blacksmith|needs? (a )?bronze|stone pick\w*\b[^.]*\b(mine|for) "
                      r"(the )?copper|copper\b[^.]*\bstone pick", re.I)
PATH = ("animal bone", "bone", "bones", "ash", "ash logs", "leather", "animal hide", "hide", "hides", "scraps",
        "coarse thread", "thread", "coarse animal fur", "fur", "flax", "stone", "tannery", "spinning wheel", "wheel",
        "crafting table", "bone pickaxe", "bark to bones", "deer", "cow", "sheep", "giant rat", "rat", "kebbit",
        "wolf", "goat", "ram")
WORLD = ("gather", "attack", "explore", "cast", "craft", "build", "place", "go_to", "interact", "start_goal",
         "run_skill", "take", "store", "pickup")
STOPS = ("park_request", "request_done")
READS = ("craft_plan", "recipes", "lookup", "look", "buildables", "recall", "quests", "map_memory", "compare_gear",
         "skills_progress", "learned_skills", "say")


def _names(text: str) -> bool:
    low = " " + " ".join(re.findall(r"[a-z0-9]+", str(text or "").lower())) + " "
    return any(f" {p} " in low for p in PATH)


def grade(calls: list[tuple[str, dict]], text: str | None) -> str:
    """One reply -> FALSE / STEP / STOP / READ / OTHER (the rules in the module doc)."""
    words = " ".join([str(text or "")] + [json.dumps(a, ensure_ascii=False) for _, a in calls])
    if FALSE_RE.search(words):
        return "FALSE"
    said = " ".join(str(a.get("text") or "") for n, a in calls if n == "say") + " " + str(text or "")
    for n, a in calls:
        if n not in WORLD:
            continue
        own = json.dumps(a, ensure_ascii=False)
        if _names(own) or (n in ("go_to", "interact") and _names(said)):
            return "STEP"
    if any(n in WORLD for n, _ in calls):
        return "OTHER"
    if not calls or all(n in STOPS or n == "say" for n, _ in calls):
        return "STOP"
    return "READ"


# ------------------------------------------------------------------ the prompt with the tree


def _rows(log: str) -> list[dict]:
    return [json.loads(line) for line in open(log, encoding="utf-8") if line.strip()]


def state_before(rows: list[dict], row: int) -> dict | None:
    """The last get_state reply (a bridge result with inventory and my_bases) before log row ``row``."""
    for r in reversed(rows[:row]):
        d = (r.get("msg") or {}).get("data") if r.get("kind") == "bridge_recv" else None
        if isinstance(d, dict) and "inventory" in d and "my_bases" in d:
            return d
    return None


def prompt_rows(rows: list[dict], episode: str) -> list[int]:
    return [i for i, r in enumerate(rows) if r.get("kind") == "prompt" and r.get("component") == "controller"
            and r.get("episode_id") == episode]


def _json_tail(content: str, prefix: str) -> dict | None:
    if not isinstance(content, str) or not content.startswith(prefix):
        return None
    try:
        return json.loads(content[len(prefix):])
    except ValueError:
        return None


def with_tree(messages: list[dict], first_view: dict, last_view: dict, player: str, words: str) -> tuple[list[dict], list[str]]:
    """The messages with the tree swapped in (see the module doc); and what was changed."""
    m = copy.deepcopy(messages)
    done = []
    first = next((i for i, x in enumerate(m) if x["role"] == "user"), None)
    if first is not None:
        try:
            ctx = json.loads(m[first]["content"])
        except (TypeError, ValueError):
            ctx = None
        if isinstance(ctx, dict):
            ctx["open_request"] = {"player": player, "words": words, "job_tree": first_view}
            m[first]["content"] = json.dumps(ctx, default=str, ensure_ascii=False)
            done.append("first-turn open_request")
    last_asst = max((i for i, x in enumerate(m) if x["role"] == "assistant"), default=-1)
    tail = [i for i in range(last_asst + 1, len(m)) if m[i]["role"] == "user"]
    for i in reversed(tail):
        blk = _json_tail(m[i]["content"], "Open request: ")
        if isinstance(blk, dict) and isinstance(blk.get("open_request"), dict):
            o = blk["open_request"]
            o.pop("known_facts", None)
            o["job_tree"] = last_view
            m[i]["content"] = "Open request: " + json.dumps(blk, ensure_ascii=False)
            done.append("open-ask block")
            return m, done
    for i in reversed(tail):
        obs = _json_tail(m[i]["content"], "Current observation: ")
        if isinstance(obs, dict):
            obs["job_tree"] = last_view
            m[i]["content"] = "Current observation: " + json.dumps(obs, ensure_ascii=False)
            done.append("observation")
            return m, done
    return m, done


def open_ask_turn(messages: list[dict]) -> bool:
    last_asst = max((i for i, x in enumerate(messages) if x["role"] == "assistant"), default=-1)
    return any(isinstance(x.get("content"), str) and x["content"].startswith("Open request: ")
               for x in messages[last_asst + 1:] if x["role"] == "user")


def known_facts_chars(messages: list[dict]) -> int:
    """The open-request facts as the live prompt carried them (known_facts, open_request_facts), in characters."""
    n = 0
    for x in messages:
        c = x.get("content")
        if not isinstance(c, str):
            continue
        for key in ('"known_facts": ', '"open_request_facts": '):
            at = c.find(key)
            while at >= 0:
                end = c.find("]", at)
                n += (end - at + 1) if end > at else 0
                at = c.find(key, end)
    return n


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("spec"), ap.add_argument("k", type=int)
    ap.add_argument("--cap", type=float, default=0.20)
    ap.add_argument("--dry", action="store_true")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    from brain import job_tree as jt
    from brain.knowledge import open_knowledge
    from brain.open_ask import ASK_TOOL_SCHEMAS
    from tools.replay_episode import episode_calls
    spec = json.loads(Path(a.spec).read_text(encoding="utf-8"))
    kb = open_knowledge()
    try:
        from brain.places import Places
        places = Places()
    except Exception:
        places = None
    data = jt.GameData.default(knowledge=kb, places=places)
    ctl = None
    if not a.dry:
        import tempfile
        from brain.controller import Decision
        from brain.jsonl_log import JsonlLogger
        from brain.llm import controller_llm
        from tools import replay_first_call as rf
        tmp = Path(tempfile.mkdtemp())
        ctl = rf.live_controller(controller_llm(), "Tester", tmp, JsonlLogger(tmp / "replay.jsonl"))
    spent, out = 0.0, []
    for t in spec:
        rows = _rows(t["log"])
        calls = episode_calls(t["log"], t["episode"])
        _, msgs, live = calls[t["call_index"]]
        prs = prompt_rows(rows, t["episode"])
        words = "claude, we need thirty copper ore in the chest at your base"
        targets = jt.targets_from_words(words, data)
        s0 = state_before(rows, prs[0])
        s1 = state_before(rows, prs[t["call_index"]])
        v0 = jt.compact(jt.build(data, targets, s0), None)
        tree1 = jt.build(data, targets, s1)
        v1 = jt.compact(tree1, None)
        m_with, changed = with_tree(msgs, v0, v1, "Tester", words)
        rec = {"run": t["run"], "episode": t["episode"], "changed": changed, "view_chars": jt.size(v1),
               "full_chars": len(jt.full_text(tree1)), "nodes": tree1["nodes"],
               "facts_chars_live": known_facts_chars(msgs), "open_ask_turn": open_ask_turn(msgs),
               "live": [c["name"] for c in live.get("tool_calls") or []] or "EMPTY", "arms": {}}
        print(f"== {t['run']} {t['episode']} call {t['call_index']}: live {rec['live']}; changed {changed}; "
              f"view {rec['view_chars']} chars vs live facts {rec['facts_chars_live']} chars; nodes {tree1['nodes']}",
              flush=True)
        if a.dry:
            print(json.dumps(v1, indent=1, ensure_ascii=False))
            out.append(rec)
            continue
        tools = ctl.tools + (list(ASK_TOOL_SCHEMAS) if rec["open_ask_turn"] else [])
        for arm, m in (("without", msgs), ("with", m_with)):
            rows_k = []
            for k in range(a.k):
                if spent > a.cap:
                    print(f"cap ${a.cap} reached (${spent:.4f}): stopping", flush=True)
                    break
                r = ctl._complete(copy.deepcopy(m), tools, Decision(), step="turn0")
                spent += float((r.usage or {}).get("cost_usd") or 0)
                did = [(c.name, c.arguments) for c in r.tool_calls]
                g = grade(did, r.content)
                rows_k.append({"grade": g, "calls": did, "text": r.content, "prompt": (r.usage or {}).get("prompt"),
                               "cost": (r.usage or {}).get("cost_usd")})
                print(f"  {arm} #{k} {g} prompt {(r.usage or {}).get('prompt')} "
                      f"{json.dumps(did, ensure_ascii=False)[:220] if did else ('TEXT ' + str(r.content)[:120]) if r.content else 'EMPTY'}",
                      flush=True)
            rec["arms"][arm] = rows_k
        out.append(rec)
    if not a.dry:
        for arm in ("without", "with"):
            p = sum(1 for r in out for x in r["arms"].get(arm, []) if x["grade"] == "STEP")
            n = sum(len(r["arms"].get(arm, [])) for r in out)
            print(f"== {arm}: STEP {p} of {n}; by turn "
                  + ", ".join(f"{sum(1 for x in r['arms'].get(arm, []) if x['grade'] == 'STEP')}/{len(r['arms'].get(arm, []))}"
                              for r in out))
        print(f"spent ${spent:.4f}")
    if a.out:
        Path(a.out).write_text(json.dumps(out, indent=1, ensure_ascii=False, default=str), encoding="utf-8")


if __name__ == "__main__":
    main()

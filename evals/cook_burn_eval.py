r"""Small real-model eval: "cook your raw meat" while he carries Raw Rat Meat x3 and Raw Farm Meat x3 at Cooking 8.

The case is the REAL rung 3 cook window 2026-11-02 04:20Z (logs/brain-live-20261102-042044-15780.jsonl): the
Controller's second turn, after his own stations + recipes reads. Live he sent craft Steak x3 first and 2 of the 3
burnt (the game's own odds at his Cooking: power level 2 food 46 %, power level 1 food 0 %). Two variants of the SAME
turn, only the burn wording in those two tool results differs:
  old   the cards as sent live ("below Cooking 12 most burn, at Cooking 12 about half, from 27 none")
  new   crafting.lua's burn odds now (W.burn_odds): "Raw Farm Meat: burns about 46% of the time at your Cooking now
        ... (the game's own odds ...)" and the station's burn_odds list
No pass/fail rule on what he cooks (perception only, he chooses; CLAUDE.md "never let code veto"): the report is what
he sent first, whether his words name the burn, and how many of each meat he put on.

    .venv\Scripts\python.exe -m evals.cook_burn_eval --plan
    .venv\Scripts\python.exe -m evals.cook_burn_eval --repeat 3 --yes      # 2 variants x 3 = 6 Haiku calls
"""
from __future__ import annotations

import argparse
import copy
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

LOG = ROOT / "logs" / "brain-live-20261102-042044-15780.jsonl"
OUT = ROOT / "logs" / "evals" / "cook_burn_eval.jsonl"
ODDS = {1: 0.0, 2: 0.4615}  # burn_attr_probe.lua, live 2026-11-02 03:4xZ (ClaudeDev)
SAFE = {1: 12, 2: 27}  # crafting.lua M.BURN_LEVELS (wiki Culinary Confidence)


def new_text(raw: str, into: str, pl: int) -> str:
    """crafting.lua burn_note's wording with the game's odds (kept in step with it by hand; see test_crafting)."""
    pct = round(ODDS[pl] * 100)
    if pct <= 0:
        return f"{raw}: never burns at your Cooking now (the game's own odds, power level {pl} food)"
    return (f"{raw}: burns about {pct}% of the time at your Cooking now (comes out as {into}) (the game's own odds, "
            f"power level {pl} food); none from Cooking {SAFE[pl]} (wiki)")


def turn() -> tuple[list[dict], list[dict], dict]:
    rows = [json.loads(ln) for ln in LOG.read_text(encoding="utf-8").splitlines() if ln.strip()]
    ps = [r for r in rows if r.get("kind") == "prompt" and r.get("episode_id") == "chat-0001-8d1b"]
    p0, p1 = ps[0], ps[1]
    return p0["messages"] + p1["messages"], p0["tools"], p0["settings"]


def variant(messages: list[dict], which: str) -> list[dict]:
    if which == "old":
        return messages
    out = copy.deepcopy(messages)
    for m in out:
        if m.get("role") != "tool" or m.get("name") not in ("recipes", "stations"):
            continue
        d = json.loads(m["content"])
        if m["name"] == "recipes":
            for c in (d.get("data") or {}).get("recipes") or []:
                mb = c.get("may_burn")
                if mb:
                    raw = (c.get("inputs") or [{}])[0].get("name") or "it"
                    pl = int(mb.get("food_power_level") or 0)
                    mb.update(text=new_text(raw, mb.get("into"), pl), chance=ODDS.get(pl), source="game")
        else:
            for s in (d.get("data") or {}).get("stations") or []:
                if s.get("station") == "Campfire":
                    s["burn_odds"] = [f"Steak from {new_text('Raw Farm Meat', 'Burnt Steak', 2)}",
                                      f"Rat Roast from {new_text('Raw Rat Meat', 'Burnt Rat Roast', 1)}",
                                      f"Haunch from {new_text('Raw Game Meat', 'Burnt Haunch', 2)}"]
        m["content"] = json.dumps(d)
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repeat", type=int, default=3)
    ap.add_argument("--plan", action="store_true")
    ap.add_argument("--yes", action="store_true")
    a = ap.parse_args(argv)
    msgs, tools, settings = turn()
    n = 2 * a.repeat
    print(f"{n} calls to {settings['model']} (effort {settings.get('output_config', {}).get('effort')}), "
          f"~{sum(len(json.dumps(m)) for m in msgs) // 4} prompt tokens each")
    if a.plan or not a.yes:
        return 0
    from brain.llm import LiteLLMClient
    llm = LiteLLMClient(settings["model"], max_tokens=settings.get("max_tokens", 1024),
                        output_config=settings.get("output_config"))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    for which in ("old", "new"):
        for i in range(a.repeat):
            r = llm.complete(variant(msgs, which), tools=tools)
            calls = [{"tool": c.name, "args": c.arguments} for c in (r.tool_calls or [])]
            crafts = [c["args"] for c in calls if c["tool"] == "craft"]
            said = " ".join(str((c["args"] or {}).get("text")) for c in calls if c["tool"] == "say") + " " + (r.content or "")
            row = {"ts": round(time.time(), 1), "variant": which, "i": i, "first_craft": crafts[0] if crafts else None,
                   "crafts": crafts, "said": said.strip(), "names_burn": "burn" in said.lower(), "usage": r.usage}
            with OUT.open("a", encoding="utf-8") as f:
                f.write(json.dumps(row, default=str) + "\n")
            print(f"{which} #{i}: first {row['first_craft']} | all {crafts} | said {row['said'][:140]!r}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

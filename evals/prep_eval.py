"""Real-model check of the fight-odds perception (M2 combat_tactics:prep_before_hard_fight; commit 570f985).

Does the Controller, given the REAL context (persona, digest with the body's fight odds and PL, castable
spells) and the REAL client tool list, find out more (combat_brief) or prepare (equip / cast / consume /
combat_orders) BEFORE attacking a creature the body rates hard, and NOT over-prepare for an easy one?
Situations are the logged client state shape (evals/manifest_eval.base_state) edited to add a hard and an
easy creature; the line is neutral. Nothing is executed: reads (combat_brief, look, inventory, spells) are
answered from the case; the first action decides.

  .venv\\Scripts\\python.exe -m evals.prep_eval          (prints the call budget, spends nothing)
  .venv\\Scripts\\python.exe -m evals.prep_eval --yes

Results: logs/evals/prep_eval_<ts>.json. Not a judge file: an offline perception probe.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
from pathlib import Path

from brain import paths
from brain.capabilities import discover
from brain.controller import Controller
from brain.interface import ok
from brain.jsonl_log import JsonlLogger
from brain.state_store import StateStore
from evals.manifest_eval import CapsClient, EvalBody, base_state, carry, real_manifest

MAX_CALLS = 3  # a read (combat_brief / look), then the decision, then one continuation

DRAKE = {"id": "BP_AI_GreyDrake_C_2147401234", "name": "Grey Drake", "kind": "Grey Drake", "distance": 28.0, "hostile": True,
         "hp": 900, "max_hp": 900, "power_level": 6, "alive": True}
BRUTE = {"id": "BP_AI_GoblinBrute_C_2147405555", "name": "Goblin Brute", "kind": "Goblin Brute", "distance": 18.0, "hostile": True,
         "hp": 420, "max_hp": 420, "power_level": 4, "alive": True}
KEBBIT = {"id": "BP_AI_Kebbit_Character_02_C_2147442096", "name": "Kebbit", "kind": "Kebbit", "distance": 6.0, "hostile": False,
          "hp": 30, "max_hp": 30, "power_level": 1, "alive": True}
ODDS = {DRAKE["id"]: {"verdict": "too_strong", "kill_s": 75, "die_s": 20, "pl_gap": 5},
        BRUTE["id"]: {"verdict": "too_strong", "kill_s": 35, "die_s": 25, "pl_gap": 3},
        KEBBIT["id"]: {"verdict": "likely_win", "kill_s": 3, "die_s": 60, "pl_gap": 0}}
SPELLS = [{"name": "Tempest Shield", "role": "combat_defence", "castable": True,
           "use_when": "before a hard fight: a shield that absorbs hits for 60 s"},
          {"name": "Enchant Weapon (Fire)", "role": "weapon_buff", "castable": True,
           "use_when": "hit harder with fire damage; best against fire-weak enemies"}]


def fighter(st: dict, *creatures) -> dict:
    st["power_level"] = 1
    st["held"] = "Bronze Sword"
    st["nearby_entities"] = [dict(c) for c in creatures]
    st["fight_odds"] = {c["id"]: ODDS[c["id"]] for c in creatures}
    return st


def s_drake_full():
    st = fighter(base_state(), DRAKE, KEBBIT)
    carry(st, "hotbar", "Bronze Sword", "ITEM_Sword_Bronze", 1)
    carry(st, "hotbar", "Seared Anchovies", "ITEM_Consumable_Fish_Anchovies", 8, consumable="food", heal="30")
    carry(st, "bag", "Iron Shield", "ITEM_Shield_Iron", 1)
    st["_spells"] = SPELLS
    return st


def s_drake_hurt():
    st = s_drake_full()
    st["health"] = 55
    st["nearby_entities"][0]["hostile"] = False
    return st


def s_drake_bare():
    st = fighter(base_state(), DRAKE, KEBBIT)
    carry(st, "bag", "Forager's Sandwich", "ITEM_Consumable_Sandwich_Veggie", 6, consumable="food", heal="15")
    st["_spells"] = []
    return st


def s_brute():
    st = fighter(base_state(), BRUTE, KEBBIT)
    carry(st, "hotbar", "Bronze Sword", "ITEM_Sword_Bronze", 1)
    carry(st, "bag", "Fire Staff", "ITEM_Staff_Fire", 1)
    carry(st, "bag", "Fire Rune", "ITEM_Rune_Fire", 120)
    carry(st, "hotbar", "Seared Anchovies", "ITEM_Consumable_Fish_Anchovies", 5, consumable="food", heal="30")
    st["_spells"] = SPELLS
    return st


def s_kebbit_only():
    st = fighter(base_state(), KEBBIT)
    carry(st, "hotbar", "Bronze Sword", "ITEM_Sword_Bronze", 1)
    carry(st, "hotbar", "Seared Anchovies", "ITEM_Consumable_Fish_Anchovies", 8, consumable="food", heal="30")
    carry(st, "bag", "Iron Shield", "ITEM_Shield_Iron", 1)
    st["_spells"] = SPELLS
    return st


def brief_for(st: dict, target: str) -> dict:
    t = str(target or "").lower()
    cr = next((c for c in st["nearby_entities"] if t and (t == c["id"].lower() or t in c["name"].lower())), None)
    if not cr:
        return {"ok": False, "reason": "unknown_target", "data": {"target": target}}
    o = st["fight_odds"][cr["id"]]
    weak = {"Grey Drake": {"journal": {"Stab": "weak", "Fire": "resist"}}, "Goblin Brute": {"journal": {"Fire": "weak"}}}.get(cr["name"], {})
    weapons = [{"item": r["item"], "name": r["name"], "where": r["where"]} for r in st["inventory_items"]
               if any(w in r["item"] for w in ("Sword", "Staff", "Shield"))]
    food = [{"item": r["item"], "name": r["name"], "heal": r.get("heal"), "count": r["count"]} for r in st["inventory_items"]
            if r.get("consumable") == "food"]
    return ok(creature={"id": cr["id"], "name": cr["name"], "power_level": cr["power_level"], "hp": cr["hp"], "max_hp": cr["max_hp"],
                        "attitude": "hostile" if cr["hostile"] else "neutral_until_attacked", "distance_m": cr["distance"]},
              me={"power_level": st["power_level"], "hp": st["health"], "max_hp": 100},
              weaknesses=weak, weapons=weapons, spells=[{"name": s["name"], "role": s["role"], "castable": True} for s in st["_spells"]],
              food=food, assessment={"verdict": o["verdict"], "est_s_to_kill": o["kill_s"], "est_s_to_die": o["die_s"], "pl_gap": o["pl_gap"]},
              history={"fights": 0, "first_encounter": True}, attacks_learned=[])


class PrepBody(EvalBody):
    def call_raw(self, tool, args):
        if tool == "combat_brief":
            return brief_for(self.state, (args or {}).get("target"))
        if tool == "spells":
            return ok(spells=self.state.get("_spells", []))
        return super().call_raw(tool, args)

    spells = lambda self: self.call_raw("spells", {})  # noqa: E731


PREP = ("combat_brief", "equip", "cast", "consume", "combat_orders", "set_vitals_policy", "move_item")
OVERPREP = ("equip", "cast", "consume", "combat_orders")


def _attack_idx(calls, word):
    return next((i for i, c in enumerate(calls) if c["tool"] == "attack" and word in json.dumps(c["args"]).lower()), None)


def score_hard(word):
    def score(calls, speech, reads):
        a = _attack_idx(calls, word)
        seq = reads + [c["tool"] for c in calls]
        before = seq if a is None else reads + [c["tool"] for c in calls[:a]]
        prepped = [t for t in before if t in PREP]
        if prepped:
            return "PASS", "before attacking: " + ",".join(prepped)
        if a is None:
            return "PARTIAL", "did not attack; no prep or brief (spoke only)"
        return "FAIL", "attacked the hard one without looking or preparing"
    return score


def score_easy(calls, speech, reads):
    a = _attack_idx(calls, "kebbit")
    over = [c["tool"] for c in calls[: a if a is not None else len(calls)] if c["tool"] in OVERPREP]
    if a is not None and not over:
        return ("PASS", "attacked" + (" after a brief" if "combat_brief" in reads else ""))
    if over:
        return "FAIL", "over-prepared for an easy fight: " + ",".join(over)
    return "FAIL", "did not attack the kebbit"


CASES = [
    ("drake_full", "claude, let's take that drake out", s_drake_full, score_hard("drake")),
    ("drake_hurt", "claude, let's take that drake out", s_drake_hurt, score_hard("drake")),
    ("drake_bare", "claude, let's take that drake out", s_drake_bare, score_hard("drake")),
    ("brute", "claude, let's take that goblin brute out", s_brute, score_hard("brute")),
    ("kebbit_control", "claude, let's take that kebbit out", s_kebbit_only, score_easy),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--yes", action="store_true")
    ap.add_argument("--model", default=os.environ.get("DW_CONTROLLER_MODEL", "anthropic/claude-haiku-5-5"))
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    cases = [c for c in CASES if not a.only or c[0] in a.only.split(",")]
    budget = len(cases) * MAX_CALLS
    print(f"prep eval: {len(cases)} cases, model {a.model}, at most {budget} model calls (max_calls={MAX_CALLS} each)")
    if not a.yes:
        print("re-run with --yes to spend them")
        return
    from brain.llm import LiteLLMClient
    llm = LiteLLMClient(a.model, max_tokens=1024)
    caps = discover(CapsClient(real_manifest()))
    out_dir = paths.log_dir() / "evals"
    out_dir.mkdir(parents=True, exist_ok=True)
    results, total = [], 0
    with tempfile.TemporaryDirectory() as tmp:
        for cid, text, make, score in cases:
            st = make()
            body = PrepBody(st)
            reads = []
            real_call = body.call_raw

            def tracking(tool, args, real_call=real_call, reads=reads):
                reads.append(tool)
                return real_call(tool, args)
            body.call_raw = tracking
            log = JsonlLogger(Path(tmp) / f"{cid}.jsonl")
            c = Controller(llm, body, StateStore(Path(tmp) / cid, caps.registry()), log, name="Claude", player="Zezima",
                           available_tools=caps.tools, caps=caps, max_calls=MAX_CALLS)
            t0 = time.time()
            try:
                d = c.decide("Zezima", text, {k: v for k, v in st.items() if not k.startswith("_")}, None, addressed=True)
                calls = [{"tool": x.name, "args": x.arguments} for x in d.actions]
                reads_used = [r for r in reads if r not in ("spells",)]
                verdict, why = score(calls, d.speech, reads_used)
                n, speech = d.model_calls, d.speech
            except Exception as exc:  # provider error
                calls, reads_used, verdict, why, n, speech = [], [], "ERROR", repr(exc), 0, None
            total += n
            results.append({"id": cid, "text": text, "verdict": verdict, "why": why, "reads": reads_used, "calls": calls,
                            "speech": speech, "model_calls": n, "s": round(time.time() - t0, 1)})
            print(f"{verdict:8s} {cid:15s} {why:55s} reads={reads_used} calls={json.dumps(calls)[:140]} say={json.dumps(speech)[:120]}")
    summary = {v: sum(1 for r in results if r["verdict"] == v) for v in ("PASS", "PARTIAL", "FAIL", "ERROR")}
    print(f"\n{summary}  model calls used: {total}")
    path = out_dir / f"prep_eval_{time.strftime('%Y%m%d-%H%M%S')}.json"
    path.write_text(json.dumps({"model": a.model, "summary": summary, "model_calls": total, "results": results}, indent=1), encoding="utf-8")
    print(f"written: {path}")


if __name__ == "__main__":
    main()

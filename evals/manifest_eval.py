"""Real-model eval of the capability contract (streamline plan step 2 + PRINCIPLES 4b).

The tool list is the REAL client body's manifest (client_mod/tests/dump_manifest.lua: the real
client_bridge.lua over the real client_mod/scripts modules, no game). The Controller is the real one
(persona, digest, references), the model is the live Controller model (DW_CONTROLLER_MODEL, default
anthropic/claude-haiku-5-5). Situations are built from today's live episodes (19:22-19:26, 19:50,
20:20 UTC); utterances are Luis's actual lines. Nothing is executed: we score the tool calls the model
chooses in its first response (a read like look/inventory gets one more call, max_calls=2).

  .venv\\Scripts\\python.exe -m evals.manifest_eval            (prints the call budget first)
  .venv\\Scripts\\python.exe -m evals.manifest_eval --only give_logs,grave

Each case scores PASS / PARTIAL / FAIL; results are written to logs/evals/manifest_eval_<ts>.json.
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from brain import paths
from brain.capabilities import discover
from brain.controller import Controller
from brain.interface import GameInterface, fail, ok
from brain.jsonl_log import JsonlLogger
from brain.state_store import StateStore

REPO = paths.REPO_ROOT
GRAVE = "BP_PlayerGravestone_C_2147463090"
PSI_GROUND = "BP_RuntimeSpawnedWorldItem_C_2147465124"
SAND_GROUND = "BP_RuntimeSpawnedWorldItem_C_2147465130"


def lua() -> str:
    for c in (os.environ.get("DW_LUA"), r"C:\Program Files\WinGet\Links\lua.exe", "lua"):
        if c and (Path(c).exists() or c == "lua"):
            return c
    raise SystemExit("no Lua interpreter (set DW_LUA)")


def real_manifest() -> dict:
    with tempfile.TemporaryDirectory() as d:
        out = subprocess.run([lua(), str(REPO / "client_mod/tests/dump_manifest.lua"), d], capture_output=True, text=True,
                             timeout=60)
        if out.returncode != 0:
            raise SystemExit(out.stderr)
        return json.loads(out.stdout)


# --------------------------------------------------------------------------- situations


def base_state() -> dict:
    return {
        "position": [443.2, 1836.3, -15.5], "health": 100, "max_health": 100, "name": "Claude", "body": "client",
        "hydration": 40.0, "hydration_max": 75.0, "sustenance": 50.0, "sustenance_max": 75.0,
        "endurance": 60.0, "endurance_max": 100.0,
        "inventory": {}, "inventory_items": [], "gear": {"Body": "ITEM_Armour_T1_Body_Adventurers"},
        "held": None,
        "players": [{"id": "BP_PlayerCharacter_C_2147466104", "name": "Zezima", "position": [445.7, 1837.0, -15.35],
                     "distance": 2.6, "held": "Dorgeshuun Crossbow"}],
        "nearby_entities": [], "nearby_items": [], "nearby_resources": [], "interactables": [],
        "structures": [], "places": [], "following": None,
        "vitals_policy": {"drink_below_pct": 40, "eat_below_pct": 40, "heal_below_pct": None, "reserve_warn": 2,
                          "safety_floor_pct": 10},
        "time_of_day": {"hour": 14.2, "phase": "day", "is_night": False, "sleep_allowed": False},
    }


def carry(st: dict, where: str, name: str, item: str, count: int, **extra) -> None:
    st["inventory"][item] = st["inventory"].get(item, 0) + count
    st["inventory_items"].append({"id": f"{where}:{len(st['inventory_items'])}", "where": where, "name": name, "item": item,
                                  "count": count, **extra})


def ground(st: dict, gid: str, name: str, item: str, count: int, dist: float, **extra) -> None:
    st["nearby_items"].append({"id": gid, "name": name, "item": item, "count": count, "distance": dist,
                               "position": [445.0, 1838.0, -15.4], **extra})


def s_grave() -> dict:
    st = base_state()
    st["position"] = [441.0, 1831.0, -16.5]
    st["interactables"].append({"id": GRAVE, "class": "BP_PlayerGravestone_C", "name": "", "prompt": "Take All",
                                "kind": "interactable", "position": [441.6, 1829.1, -16.68], "distance": 2.0})
    st["my_grave"] = {"id": GRAVE, "distance": 2.0, "items": 12, "owner": "unverified",
                      "contents": ["Goblin Pack x1", "Pumpkin Spice Infusion x47", "Mithril Pickaxe x1", "Mithril Logging Axe x1",
                                   "Torch x1", "Bronze Shield x1", "Forager's Sandwich x47"]}
    st["last_death"] = {"ago_s": 240, "respawned": True}
    st["chat"] = [{"from": "Zezima", "text": "follow me to your grave"}]
    return st


def s_psi_hotbar() -> dict:
    st = base_state()
    st["hydration"] = 6.0
    carry(st, "hotbar", "Pumpkin Spice Infusion", "ITEM_Consumable_Tea_Pumpkin", 2, consumable="drink")
    return st


def s_dropped() -> dict:
    st = base_state()
    st["hydration"], st["sustenance"] = 9.0, 12.0
    ground(st, PSI_GROUND, "Pumpkin Spice Infusion", "ITEM_Consumable_Tea_Pumpkin", 10, 1.8, consumable="drink",
           dropped_by="Zezima", seen_s=3)
    ground(st, SAND_GROUND, "Forager's Sandwich", "ITEM_Consumable_Sandwich_Veggie", 22, 2.0, consumable="food",
           dropped_by="Zezima", seen_s=3)
    return st


def s_logs() -> dict:
    st = base_state()
    carry(st, "bag", "Ash Logs", "ITEM_Resources_Wood_Ash", 6)
    st["players"][0]["distance"] = 9.0
    return st


def s_far() -> dict:
    st = base_state()
    st["players"][0]["distance"] = 24.0
    return st


def s_platebody() -> dict:
    st = base_state()
    carry(st, "bag", "Mithril Platebody", "ITEM_Armour_T6_Body_Mithril", 1)
    return st


def s_fight_ahead() -> dict:
    st = base_state()
    st["sustenance"] = 22.0  # 29 %
    carry(st, "hotbar", "Forager's Sandwich", "ITEM_Consumable_Sandwich_Veggie", 20, consumable="food")
    st["nearby_entities"] = [{"id": "BP_AI_RuntGoblin_Character_C_1", "name": "Goblin Runt", "kind": "Goblin Runt",
                              "distance": 25.0, "hp": 156, "max_hp": 156, "hostile": True, "alive": True}]
    return st


def s_hurt() -> dict:
    st = base_state()
    st["health"] = 38
    carry(st, "hotbar", "Cooked Meat", "ITEM_Consumable_Meat_Cooked", 5, consumable="food", heal="20")
    st["recent_activity"] = ["combat_end: killed Goblin Runt 20 s ago, took 62 damage"]
    return st


def s_bag_food() -> dict:
    st = base_state()
    st["sustenance"] = 8.0
    carry(st, "bag", "Forager's Sandwich", "ITEM_Consumable_Sandwich_Veggie", 20, consumable="food")
    return st


# --------------------------------------------------------------------------- scoring helpers


def names(calls):
    return [c["tool"] for c in calls]


def first(calls, tool):
    return next((c for c in calls if c["tool"] == tool), None)


def low(v) -> str:
    return str(v or "").lower()


def score_grave(calls, speech):
    i = first(calls, "interact")
    if i and i["args"].get("target") == GRAVE:
        return "PASS", "interact on his grave"
    g = first(calls, "go_to")
    if g and (low(g["args"].get("target")) == GRAVE.lower()):
        return "PARTIAL", "go_to the grave only"
    return "FAIL", "no interact on the grave"


def score_consume_psi(calls, speech):
    c = first(calls, "consume")
    return ("PASS", "consume") if c and "pumpkin" in low(c["args"].get("item")) or (c and "tea_pumpkin" in low(c["args"].get("item"))) \
        else ("FAIL", "no consume of the infusion")


def score_ground_drink(calls, speech):
    i = first(calls, "interact")
    if i and i["args"].get("target") == PSI_GROUND:
        return ("PASS", "interact (pick up) + consume") if first(calls, "consume") else ("PASS", "interact on the drink")
    return "FAIL", "did not pick up the infusion"


def score_grab(calls, speech):
    ids = [c["args"].get("target") for c in calls if c["tool"] == "interact"]
    if PSI_GROUND in ids and SAND_GROUND in ids:
        return "PASS", "both stacks"
    if PSI_GROUND in ids or SAND_GROUND in ids:
        return "PARTIAL", "one stack"
    return "FAIL", "no interact on the dropped stacks"


def score_give(calls, speech):
    n = names(calls)
    g = first(calls, "go_to")
    d = first(calls, "drop")
    if g and d and n.index("go_to") < n.index("drop") and low(g["args"].get("target")) == "zezima" and "ash" in low(d["args"].get("item")):
        return "PASS", "go_to Zezima then drop the logs"
    if g and low(g["args"].get("target")) == "zezima":
        return "PARTIAL", "go_to only"
    if d:
        return "PARTIAL", "drop without walking (he is 9 m away)"
    return "FAIL", "neither"


def score_come(calls, speech):
    g = first(calls, "go_to")
    if g and low(g["args"].get("target")) == "zezima":
        return "PASS", "go_to Zezima"
    f = first(calls, "follow")
    return ("PARTIAL", "follow instead of go_to") if f else ("FAIL", "no go_to")


def score_equip(calls, speech):
    e = first(calls, "equip")
    return ("PASS", "equip") if e and "mithril" in low(e["args"].get("item")) else ("FAIL", "no equip of the platebody")


def score_fight_prep(calls, speech):
    if first(calls, "consume") or first(calls, "set_vitals_policy"):
        return "PASS", "tops up / sets the policy before the fight"
    return "PARTIAL" if first(calls, "attack") or first(calls, "go_to") else "FAIL", "went without eating"


def score_hurt(calls, speech):
    if first(calls, "consume") or first(calls, "set_vitals_policy"):
        return "PASS", "eats to heal or sets heal policy"
    return "FAIL", "did nothing about 38% HP"


def score_bag_food(calls, speech):
    m = first(calls, "move_item")
    if m and m["args"].get("to") == "hotbar":
        return ("PASS", "move_item then consume") if first(calls, "consume") else ("PASS", "move_item to hotbar")
    if first(calls, "consume"):
        return "PARTIAL", "consume straight from the bag (body answers in_bag)"
    return "FAIL", "no move_item"


CASES = [
    ("grave", "get your stuff", s_grave, score_grave),
    ("drink_hotbar", "drink the pumkin spice infusuion", s_psi_hotbar, score_consume_psi),
    ("drink_ground", "drink the pumkin spice infusuion", s_dropped, score_ground_drink),
    ("grab_those", "grab those on the floor near me", s_dropped, score_grab),
    ("food_water_front", "theres food and water infront of my character", s_dropped, score_grab),
    ("give_logs", "give me the logs", s_logs, score_give),
    ("come_to_me", "come to me", s_far, score_come),
    ("platebody", "here's a mithril platebody, put it on if it's better", s_platebody, score_equip),
    ("fight_prep", "lets go clear that goblin camp", s_fight_ahead, score_fight_prep),
    ("hurt_after_fight", "that was close", s_hurt, score_hurt),
    ("bag_food", "eat something", s_bag_food, score_bag_food),
]


# --------------------------------------------------------------------------- a read-only fake body


class EvalBody(GameInterface):
    """Answers reads from the case's state; never executes an action (we only score the choice)."""

    def __init__(self, state: dict):
        self.state = state

    def get_state(self):
        return ok(**copy.deepcopy(self.state))

    def call_raw(self, tool, args):
        if tool in ("look", "inspect"):
            things = [{**i, "category": "items", "kind": "item", "actions": ["interact"]} for i in self.state["nearby_items"]]
            things += [{**i, "category": "interactables", "actions": ["interact"]} for i in self.state["interactables"]]
            things += [{**p, "category": "players", "kind": "player", "actions": ["follow", "go_to"]} for p in self.state["players"]]
            return ok(things=things, total=len(things), matched=bool(things))
        if tool == "inventory":
            rows = self.state["inventory_items"]
            return ok(hotbar=[r for r in rows if r["where"] == "hotbar"], bag=[r for r in rows if r["where"] == "bag"],
                      worn=self.state.get("gear") or {})
        if tool in ("spells", "held_actions", "recipes", "stations", "craft_plan"):
            return ok(spells=[], actions=[], recipes=[], stations=[])
        return fail("not_implemented", tool=tool)

    look = lambda self, about=None, radius=20.0, max=15: self.call_raw("look", {})  # noqa: E731
    inspect = lambda self, target: self.call_raw("inspect", {})  # noqa: E731
    inventory = lambda self: self.call_raw("inventory", {})  # noqa: E731
    spells = lambda self: self.call_raw("spells", {})  # noqa: E731

    def follow(self, player, distance=3.0): return fail("not_run")
    def stop(self): return fail("not_run")
    def go_to(self, target): return fail("not_run")
    def attack(self, target): return fail("not_run")
    def gather(self, resource, count, radius=None): return fail("not_run")
    def craft(self, item, count=1): return fail("not_run")
    def place(self, blueprint, location): return fail("not_run")
    def give(self, player, item, count): return fail("not_run")
    def pickup(self, target, item=None, limit=1): return fail("not_run")
    def drop(self, item, count, at="feet", player=None): return fail("not_run")
    def say(self, text): return ok(text=text)
    def poll_events(self): return []


class CapsClient:
    def __init__(self, data):
        self.data, self.timeouts, self.manifest_tools = data, {}, frozenset()

    def capabilities(self, timeout=5.0):
        return ok(**self.data)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="", help="comma-separated case ids")
    ap.add_argument("--model", default=os.environ.get("DW_CONTROLLER_MODEL") or "anthropic/claude-haiku-5-5")
    ap.add_argument("--yes", action="store_true", help="skip the call-budget confirmation")
    a = ap.parse_args()
    cases = [c for c in CASES if not a.only or c[0] in a.only.split(",")]
    budget = 2 * len(cases)
    print(f"manifest eval: {len(cases)} cases, model {a.model}, at most {budget} model calls (max_calls=2 each)")
    if not a.yes:
        print("re-run with --yes to spend them")
        return
    from brain.llm import LiteLLMClient
    llm = LiteLLMClient(a.model, max_tokens=1024)
    data = real_manifest()
    caps = discover(CapsClient(data))
    out_dir = paths.log_dir() / "evals"
    out_dir.mkdir(parents=True, exist_ok=True)
    results, calls_total = [], 0
    with tempfile.TemporaryDirectory() as tmp:
        for cid, text, make, score in cases:
            st = make()
            chat = st.pop("chat", None)
            activity = st.pop("recent_activity", None)
            body = EvalBody(st)
            log = JsonlLogger(Path(tmp) / f"{cid}.jsonl")
            c = Controller(llm, body, StateStore(Path(tmp) / cid, caps.registry()), log, name="Claude", player="Zezima",
                           available_tools=caps.tools, caps=caps, max_calls=2)
            if chat:
                c.chat_provider = lambda chat=chat: chat
            if activity:
                c.activity_provider = lambda activity=activity: activity
            t0 = time.time()
            try:
                d = c.decide("Zezima", text, st, None, addressed=True)
                calls = [{"tool": x.name, "args": x.arguments} for x in d.actions]
                refusals = [list(r[:2]) for r in d.refusals]
                verdict, why = score(calls, d.speech)
                n = d.model_calls
            except Exception as exc:  # provider error
                calls, refusals, verdict, why, n, d = [], [], "ERROR", repr(exc), 0, None
            calls_total += n
            row = {"id": cid, "text": text, "verdict": verdict, "why": why, "calls": calls, "refusals": refusals,
                   "speech": d.speech if d else None, "model_calls": n, "s": round(time.time() - t0, 1)}
            results.append(row)
            print(f"{verdict:8s} {cid:18s} {why:45s} calls={json.dumps(calls)[:160]} say={json.dumps(row['speech'])[:100]}")
    summary = {v: sum(1 for r in results if r["verdict"] == v) for v in ("PASS", "PARTIAL", "FAIL", "ERROR")}
    print(f"\n{summary}  model calls used: {calls_total}  (offered tools: {len(caps.llm_tools())})")
    path = out_dir / f"manifest_eval_{time.strftime('%Y%m%d-%H%M%S')}.json"
    path.write_text(json.dumps({"model": a.model, "summary": summary, "model_calls": calls_total, "results": results,
                                "offered": caps.llm_tools()}, indent=1), encoding="utf-8")
    print(f"written: {path}")
    sys.exit(0 if summary["FAIL"] == 0 and summary["ERROR"] == 0 else 1)


if __name__ == "__main__":
    main()
